import 'package:isar/isar.dart';

part 'category.g.dart';

@collection
class Category {
  Id isarId = Isar.autoIncrement;

  @Index(unique: true, replace: true)
  late String id;

  late String name;
  late String updatedAt;
  bool isDeleted = false;

  factory Category.fromJson(Map<String, dynamic> j) => Category()
    ..id = j['id'] as String
    ..name = j['name'] as String
    ..updatedAt = j['updated_at'] as String
    ..isDeleted = (j['is_deleted'] as bool?) ?? false;
}
