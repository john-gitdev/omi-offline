## 2024-10-24 - Dart Uint8List memory allocations
**Learning:** `Uint8List.sublist()` in Dart creates a new array and copies memory. When decoding audio frames in a tight loop in `vad_audio_processor.dart`, this creates significant unnecessary allocations. `Uint8List.sublistView()` creates a zero-copy pointer.
**Action:** Replace `bytes.sublist()` with `Uint8List.sublistView()` when taking brief slices of bytes to feed to the opus decoder.
