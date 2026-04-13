## 2024-04-13 - Optimize BytesBuilder allocation
**Learning:** In Dart, calling `BytesBuilder.toBytes()` creates a copy of the buffer. If the intent is to immediately empty the buffer after extracting the bytes (e.g. by calling `clear()`), this creates unnecessary memory churn.
**Action:** Always prefer `BytesBuilder.takeBytes()` over `toBytes()` followed by `clear()`. `takeBytes()` returns the internal buffer and clears the builder simultaneously, avoiding the allocation of a duplicate array.
