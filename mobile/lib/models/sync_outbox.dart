import 'package:isar/isar.dart';

part 'sync_outbox.g.dart';

/// Queues local price/stock edits made while offline.
/// Processed and flushed to the server on the next successful sync.
@collection
class SyncOutbox {
  Id isarId = Isar.autoIncrement;

  late String productId;
  double? newPrice;
  int? newStockQuantity;
  late DateTime createdAt;

  /// Incremented each time the push attempt fails. Capped at 3.
  int retries = 0;

  /// Set true when retries reaches 3 — excluded from future processing.
  bool failed = false;
}
