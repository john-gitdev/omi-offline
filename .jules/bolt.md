## 2024-11-19 - String.fromCharCodes memory allocation
**Learning:** Using `String.fromCharCodes(data.sublist(start, end))` creates an expensive deep copy of the array just to create the string. Passing the arguments natively with `String.fromCharCodes(data, start, end)` avoids copying memory and improves performance in loops parsing audio and BLE data payloads.
**Action:** Use native positional arguments of `fromCharCodes` to read strings from bytes without copying memory.
