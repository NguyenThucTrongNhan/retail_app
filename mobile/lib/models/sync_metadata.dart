import 'package:isar/isar.dart';

part 'sync_metadata.g.dart';

@collection
class SyncMetadata {
  Id isarId = Isar.autoIncrement;

  @Index(unique: true, replace: true)
  late String key;

  late String value;
}
