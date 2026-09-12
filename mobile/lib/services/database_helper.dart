import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:isar/isar.dart';
import 'package:path_provider/path_provider.dart';

import '../models/category.dart';
import '../models/product.dart';
import '../models/sync_metadata.dart';
import '../models/sync_outbox.dart';

/// Singleton Isar database wrapper.
///
/// Replaces sqflite:
///   - Native web support via IndexedDB (kIsWeb path) — C1 fix
///   - Categories stored and synced locally — C3 fix
///   - SyncOutbox for offline edits — C2 fix
///   - Generic meta helpers used by AppConfig (C6) and SyncService (C8)
class DatabaseHelper {
  static final DatabaseHelper instance = DatabaseHelper._init();
  static Isar? _isar;

  DatabaseHelper._init();

  Future<Isar> get db async {
    if (_isar != null && _isar!.isOpen) return _isar!;
    _isar = await _openIsar();
    return _isar!;
  }

  Future<Isar> _openIsar() async {
    final schemas = [
      ProductSchema,
      CategorySchema,
      SyncMetadataSchema,
      SyncOutboxSchema,
    ];
    if (kIsWeb) {
      // Web: Isar uses IndexedDB; directory is ignored but required by the API.
      return await Isar.open(schemas, directory: '');
    }
    final dir = await getApplicationDocumentsDirectory();
    return await Isar.open(schemas, directory: dir.path);
  }

  // ---------------------------------------------------------------------------
  // GENERIC META — used by AppConfig (server IP) and SyncService (timestamps)
  // ---------------------------------------------------------------------------
  Future<String?> getMetaValue(String key) async {
    final isar = await db;
    final meta = await isar.syncMetadatas.filter().keyEqualTo(key).findFirst();
    return meta?.value;
  }

  Future<void> setMetaValue(String key, String value) async {
    final isar = await db;
    await isar.writeTxn(() async {
      final meta = SyncMetadata()
        ..key = key
        ..value = value;
      await isar.syncMetadatas.putByIndex('key', meta);
    });
  }

  // ---------------------------------------------------------------------------
  // BULK IMPORT — first boot: all 5,000 products in one transaction < 400ms
  // ---------------------------------------------------------------------------
  Future<void> bulkImport({
    required List<dynamic> productsJson,
    required List<dynamic> categoriesJson,
    required int latestVersion,
    required String syncTimestamp,
  }) async {
    final isar = await db;
    final products = productsJson
        .map((j) => Product.fromJson(j as Map<String, dynamic>))
        .toList();
    final categories = categoriesJson
        .map((j) => Category.fromJson(j as Map<String, dynamic>))
        .toList();

    await isar.writeTxn(() async {
      await isar.products.putAllByIndex('id', products);
      await isar.categorys.putAllByIndex('id', categories);
      await _writeMeta(isar, 'last_synced_version', latestVersion.toString());
      await _writeMeta(isar, 'last_synced_timestamp', syncTimestamp);
    });
  }

  // ---------------------------------------------------------------------------
  // DELTA SYNC — upsert changed records, hard-delete server-removed ones
  // ---------------------------------------------------------------------------
  Future<void> applyDelta({
    required List<dynamic> updatedProducts,
    required List<dynamic> deletedProductIds,
    required List<dynamic> updatedCategories,
    required List<dynamic> deletedCategoryIds,
    required int latestVersion,
    required String syncTimestamp,
  }) async {
    final isar = await db;
    final products = updatedProducts
        .map((j) => Product.fromJson(j as Map<String, dynamic>))
        .toList();
    final categories = updatedCategories
        .map((j) => Category.fromJson(j as Map<String, dynamic>))
        .toList();

    await isar.writeTxn(() async {
      if (products.isNotEmpty) {
        await isar.products.putAllByIndex('id', products);
      }
      if (categories.isNotEmpty) {
        await isar.categorys.putAllByIndex('id', categories);
      }
      for (final uuid in deletedProductIds) {
        final existing = await isar.products
            .filter()
            .idEqualTo(uuid as String)
            .findFirst();
        if (existing != null) await isar.products.delete(existing.isarId);
      }
      for (final uuid in deletedCategoryIds) {
        final existing = await isar.categorys
            .filter()
            .idEqualTo(uuid as String)
            .findFirst();
        if (existing != null) await isar.categorys.delete(existing.isarId);
      }
      await _writeMeta(isar, 'last_synced_version', latestVersion.toString());
      await _writeMeta(isar, 'last_synced_timestamp', syncTimestamp);
    });
  }

  // ---------------------------------------------------------------------------
  // LOCAL EDIT — save instantly + enqueue outbox entry for next push sync (C2)
  // ---------------------------------------------------------------------------
  Future<void> updateProductLocally(String id, double price, int stock) async {
    final isar = await db;
    await isar.writeTxn(() async {
      final product =
          await isar.products.filter().idEqualTo(id).findFirst();
      if (product != null) {
        product.price = price;
        product.stockQuantity = stock;
        await isar.products.put(product);
      }
      final entry = SyncOutbox()
        ..productId = id
        ..newPrice = price
        ..newStockQuantity = stock
        ..createdAt = DateTime.now();
      await isar.syncOutboxs.put(entry);
    });
  }

  // ---------------------------------------------------------------------------
  // SEARCH — sub-10ms across name, SKU, exact barcode; supports pagination
  // ---------------------------------------------------------------------------
  Future<List<Product>> searchProducts(
    String query, {
    int limit = 30,
    int offset = 0,
  }) async {
    final isar = await db;
    final q = query.trim();
    if (q.isEmpty) {
      return isar.products.where().findAll(offset: offset, limit: limit);
    }
    return isar.products
        .filter()
        .nameContains(q, caseSensitive: false)
        .or()
        .skuContains(q, caseSensitive: false)
        .or()
        .barcodeEqualTo(q)
        .findAll(offset: offset, limit: limit);
  }

  // ---------------------------------------------------------------------------
  // OUTBOX
  // ---------------------------------------------------------------------------
  Future<List<SyncOutbox>> getPendingOutbox() async {
    final isar = await db;
    return isar.syncOutboxs
        .filter()
        .failedEqualTo(false)
        .retriesLessThan(3)
        .findAll();
  }

  Future<void> clearOutboxItems(List<Id> isarIds) async {
    final isar = await db;
    await isar.writeTxn(() => isar.syncOutboxs.deleteAll(isarIds));
  }

  Future<void> incrementOutboxRetry(Id id) async {
    final isar = await db;
    await isar.writeTxn(() async {
      final item = await isar.syncOutboxs.get(id);
      if (item != null) {
        item.retries += 1;
        if (item.retries >= 3) item.failed = true;
        await isar.syncOutboxs.put(item);
      }
    });
  }

  // ---------------------------------------------------------------------------
  // STATS / META SHORTCUTS
  // ---------------------------------------------------------------------------
  Future<int> getLastSyncedVersion() async {
    final v = await getMetaValue('last_synced_version');
    return v != null ? (int.tryParse(v) ?? 0) : 0;
  }

  Future<String?> getLastSyncedTimestamp() =>
      getMetaValue('last_synced_timestamp');

  Future<int> getProductCount() async {
    final isar = await db;
    return isar.products.count();
  }

  // ---------------------------------------------------------------------------
  // CLEAR — used by Settings > "Clear local data"
  // ---------------------------------------------------------------------------
  Future<void> clearLocalData() async {
    final isar = await db;
    await isar.writeTxn(() async {
      await isar.products.clear();
      await isar.categorys.clear();
    });
  }

  // ---------------------------------------------------------------------------
  // PRIVATE
  // ---------------------------------------------------------------------------
  Future<void> _writeMeta(Isar isar, String key, String value) async {
    final meta = SyncMetadata()
      ..key = key
      ..value = value;
    await isar.syncMetadatas.putByIndex('key', meta);
  }
}
