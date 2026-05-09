## 2024-05-09 - Avoid creating deep copies or new objects in loops for bytes arrays in Dart

**Learning:** Slicing `Uint8List` using `.sublist()` creates an expensive deep copy. In tight loops (like audio frame processing), passing it as a string to `String.fromCharCodes` or passing to a byte decoding method produces a lot of memory overhead. `ByteData.sublistView(Uint8List.fromList(data.sublist(...)))` creates a new `Uint8List` and a new `ByteData` view per call.

**Action:** Pass `data` natively using positional arguments `String.fromCharCodes(data, start, end)` to read without copying memory. Also, hoist a single `ByteData.sublistView(data)` outside the loop and read values directly using offset-based methods like `bd.getUint32(offset)`.
