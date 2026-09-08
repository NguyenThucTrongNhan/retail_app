import 'dart:convert';
import 'package:http/http.dart' as http;

import '../models/sync_outbox.dart';
import 'database_helper.dart';

class SyncResult {
  final int itemsReceived;
  final int outboxFlushed;
  final int latestVersion;
  final bool wasInitialImport;

  const SyncResult({
    required this.itemsReceived,
    required this.outboxFlushed,
    required this.latestVersion,
    required this.wasInitialImport,
  });
}

/// Orchestrates pull/push delta sync between Fastify backend and local Isar DB.
///
/// C2: offline edits stored in SyncOutbox are flushed at end of every sync.
/// C8: passes since_timestamp so the backend can filter categories correctly.
class SyncService {
  final String baseUrl; // e.g. 'http://192.168.1.50:8080/api/v1'

  const SyncService({required this.baseUrl});

  Future<SyncResult> performSync() async {
    final db = DatabaseHelper.instance;
    final lastVersion = await db.getLastSyncedVersion();
    final lastTimestamp = await db.getLastSyncedTimestamp(); // C8

    // Build pull URL — include since_timestamp so category query is accurate (C8)
    final queryParams = {
      'since_version': '$lastVersion',
      if (lastTimestamp != null) 'since_timestamp': lastTimestamp,
    };
    final uri = Uri.parse('$baseUrl/sync/pull')
        .replace(queryParameters: queryParams);

    final response =
        await http.get(uri).timeout(const Duration(seconds: 30));

    if (response.statusCode != 200) {
      throw Exception('Pull failed — HTTP ${response.statusCode}');
    }

    final data = jsonDecode(response.body) as Map<String, dynamic>;
    final latestVersion = data['latest_version'] as int;
    final syncTimestamp = data['sync_timestamp'] as String; // save for C8

    final changes = data['changes'] as Map<String, dynamic>;
    final productsSection = changes['products'] as Map<String, dynamic>;
    final categoriesSection = changes['categories'] as Map<String, dynamic>;

    final updatedProducts = List<dynamic>.from(productsSection['updated']);
    final deletedProductIds = List<dynamic>.from(productsSection['deleted_ids']);
    final updatedCategories = List<dynamic>.from(categoriesSection['updated']);
    final deletedCategoryIds =
        List<dynamic>.from(categoriesSection['deleted_ids']);

    if (lastVersion == 0) {
      await db.bulkImport(
        productsJson: updatedProducts,
        categoriesJson: updatedCategories,
        latestVersion: latestVersion,
        syncTimestamp: syncTimestamp,
      );
    } else {
      await db.applyDelta(
        updatedProducts: updatedProducts,
        deletedProductIds: deletedProductIds,
        updatedCategories: updatedCategories,
        deletedCategoryIds: deletedCategoryIds,
        latestVersion: latestVersion,
        syncTimestamp: syncTimestamp,
      );
    }

    final flushed = await _flushOutbox();

    return SyncResult(
      itemsReceived: updatedProducts.length,
      outboxFlushed: flushed,
      latestVersion: latestVersion,
      wasInitialImport: lastVersion == 0,
    );
  }

  /// Sends all pending offline edits as one batch push.
  /// Deduplicates: keeps only the latest edit per product (highest isarId = newest).
  Future<int> _flushOutbox() async {
    final db = DatabaseHelper.instance;
    final pending = await db.getPendingOutbox();
    if (pending.isEmpty) return 0;

    // B3 fix: use typed Map<String, SyncOutbox>, not Map<String, dynamic>
    final Map<String, SyncOutbox> latestByProduct = {};
    for (final item in pending) {
      latestByProduct[item.productId] = item; // ascending order → last = newest
    }

    final payload = {
      'client_id': 'pos-mobile-01',
      'changes': {
        'products': latestByProduct.values.map((item) {
          final m = <String, dynamic>{'id': item.productId};
          if (item.newPrice != null) m['price'] = item.newPrice;
          if (item.newStockQuantity != null) {
            m['stock_quantity'] = item.newStockQuantity;
          }
          return m;
        }).toList(),
      },
    };

    try {
      final response = await http
          .post(
            Uri.parse('$baseUrl/sync/push'),
            headers: {'Content-Type': 'application/json'},
            body: jsonEncode(payload),
          )
          .timeout(const Duration(seconds: 15));

      if (response.statusCode == 200) {
        await db.clearOutboxItems(pending.map((i) => i.isarId).toList());
        return pending.length;
      }
      for (final item in pending) {
        await db.incrementOutboxRetry(item.isarId);
      }
      return 0;
    } catch (_) {
      for (final item in pending) {
        await db.incrementOutboxRetry(item.isarId);
      }
      return 0;
    }
  }
}
