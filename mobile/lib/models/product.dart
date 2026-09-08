import 'package:isar/isar.dart';

part 'product.g.dart';

@collection
class Product {
  Id isarId = Isar.autoIncrement;

  /// UUID from the backend server — used as the upsert key via putAllByIndex.
  @Index(unique: true, replace: true)
  late String id;

  @Index()
  late String sku;

  /// Indexed for fast case-insensitive contains() search across 5,000 items.
  @Index(type: IndexType.value, caseSensitive: false)
  late String name;

  String? categoryId;
  late double price;
  late int stockQuantity;

  @Index()
  String? barcode;

  String? imageUrl;
  late int version;
  late String updatedAt;

  factory Product.fromJson(Map<String, dynamic> j) => Product()
    ..id = j['id'] as String
    ..sku = j['sku'] as String
    ..name = j['name'] as String
    ..categoryId = j['category_id'] as String?
    ..price = (j['price'] as num).toDouble()
    ..stockQuantity = j['stock_quantity'] as int
    ..barcode = j['barcode'] as String?
    ..imageUrl = j['image_url'] as String?
    ..version = j['version'] as int
    ..updatedAt = j['updated_at'] as String;
}
