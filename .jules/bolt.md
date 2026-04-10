## 2024-05-24 - [Avoid Uint8List.fromList wrapping]
**Learning:** BytesBuilder.toBytes() in Dart inherently returns a Uint8List. Wrapping its output in Uint8List.fromList() causes unnecessary O(n) array copying and extra memory allocation.
**Action:** Always pass the result of BytesBuilder.toBytes() directly to APIs expecting Uint8List to improve performance and reduce memory pressure.
