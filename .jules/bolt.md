## 2024-05-15 - Prevent Deep Copies in String.fromCharCodes

**Learning:** In Dart, using `String.fromCharCodes(data.sublist(start, end))` creates an expensive deep copy of the underlying byte list because `.sublist()` allocates a new array. When this pattern is used inside tight loops or processing large files (like audio parsing), it causes unnecessary memory allocation overhead and performance degradation.
**Action:** Instead, pass the original data directly and use the native positional arguments `String.fromCharCodes(data, start, end)`. This reads the bytes natively without making a copy of memory.
