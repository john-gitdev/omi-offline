## 2026-04-17 - Optimize ByteData creation in loops
**Learning:** In Dart, calling `ByteData.sublistView(Uint8List.fromList(data.sublist(...)))` inside tight loops (such as parsing BLE packets, WAV headers, or PCM/Opus frames) creates multiple unnecessary intermediate allocations (`Uint8List`, `List`, and `ByteData` views) which can significantly degrade performance, especially on large files.
**Action:** Always hoist a single `ByteData.sublistView(data)` instance outside the loop and use offset-based access methods like `bd.getUint32(offset)` to improve parsing performance.
