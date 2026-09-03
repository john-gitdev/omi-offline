import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:omi/backend/preferences.dart';
import 'package:omi/services/vad_audio_processor.dart';
import 'package:opus_dart/opus_dart.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:plugin_platform_interface/plugin_platform_interface.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Drives the production parser over **bytes a real Omi actually wrote**.
///
/// Every other bin in this suite is synthesised by the test writing headers and frame
/// headers by hand — using the same model of the format the parser uses. A shared
/// misunderstanding of what the firmware really emits is therefore invisible to all of
/// them, by construction. These two fixtures are the only thing that breaks that circle:
/// they came off a device (app 0.35.6, capture 2026-08-29) and nothing in this repo
/// produced them.
///
/// **What this file cannot express.** It says nothing about audio. `opus_dart` is FFI over
/// libopus and `VadAudioProcessor` only builds a decoder on iOS/Android, so on the host
/// every real Opus payload decodes to whatever the injected stand-in returns: no real PCM,
/// no meaningful VAD verdicts, no recordings. A green run here is evidence about *framing*
/// — where frames and markers begin and end — and about nothing downstream of the decoder.
/// Do not read it as coverage of VAD, splitting or stitching; those stay with the synthetic
/// fixtures, which can script speech and silence deliberately.
///
/// Fixtures (both tiny, so they can be asserted exhaustively):
///  - `1787938578_4261367757.bin` — 476 B. Metadata header, four audio frames, one
///    `0xFFFFFFFD` VAD-resume, and the firmware's block padding. First bin of its boot,
///    hence a session id of its own.
///  - `1788031307_1193025564.bin` — 36 B. Metadata header and nothing else: the empty-bin
///    rotation, i.e. a rotate that landed where nothing was being written.
class _MockPathProvider extends Fake with MockPlatformInterfaceMixin implements PathProviderPlatform {
  late String tempPath;
  @override
  Future<String?> getApplicationDocumentsPath() async => tempPath;
  @override
  Future<String?> getTemporaryPath() async => tempPath;
  @override
  Future<String?> getApplicationSupportPath() async => tempPath;
}

/// Counts what the production parser hands it. Real Opus payloads cannot be decoded here,
/// so the PCM is a constant — the count is the whole point: it is the parser's own tally
/// of audio frames in bytes it did not author.
class _CountingDecoder extends Fake implements SimpleOpusDecoder {
  int framesDecoded = 0;
  int shortestPayload = 1000000;
  int longestPayload = 0;

  @override
  bool destroyed = false;

  @override
  void destroy() => destroyed = true;

  @override
  Int16List decode({Uint8List? input, bool fec = false, int? loss}) {
    framesDecoded++;
    final n = input?.length ?? 0;
    if (n < shortestPayload) shortestPayload = n;
    if (n > longestPayload) longestPayload = n;
    return Int16List(320);
  }
}

ProcessingSettings _settings() => const ProcessingSettings(
      vadEnabled: true,
      speechThreshold: 0.5,
      silenceDurationToSplitMs: 120000,
      minDurationMs: 0,
      minSpeechMs: 0,
      maxChunkMs: 3600000,
      deviceId: 'test-device',
      audioSaveFormat: 'm4a',
      omiEnabled: false,
      priorityRecordCapMinutes: 0,
    );

File _fixture(String name) {
  final f = File('test/fixtures/bins/$name');
  if (!f.existsSync()) throw StateError('fixture missing: ${f.path}');
  return f;
}

void main() {
  late Directory tempDir;

  setUp(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    tempDir = Directory.systemTemp.createTempSync('real_bin_format_test');
    PathProviderPlatform.instance = _MockPathProvider()..tempPath = tempDir.path;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
      const MethodChannel('plugins.it_nomads.com/flutter_secure_storage'),
      (MethodCall call) async => call.method == 'readAll' ? <String, String>{} : null,
    );
    SharedPreferences.setMockInitialValues({});
    await SharedPreferencesUtil.init();
  });

  tearDown(() => tempDir.deleteSync(recursive: true));

  group('real firmware bin — framing', () {
    test('the parser walks a real bin and finds exactly its four audio frames', () async {
      final decoder = _CountingDecoder();
      final processor = VadAudioProcessor.fromSettings(
        settings: _settings(),
        outputDir: tempDir.path,
        decoder: decoder,
      );

      await processor.processSegmentFile(
        _fixture('1787938578_4261367757.bin'),
        DateTime.fromMillisecondsSinceEpoch(1787938578 * 1000),
      );

      // Four is verifiable by hand from the file: a 36-byte metadata header, a 71-byte
      // frame at 36, the VAD-resume at 112, then three more frames. If the frame-advance
      // rule (4 + length rounded up to a 4-byte boundary) were wrong, the walk would
      // desync at the first frame and every later offset would be garbage — the count is
      // what detects that.
      expect(decoder.framesDecoded, 4);

      // Real Opus at 16 kHz VBR. The point is that these are NOT the fixed 40- or 80-byte
      // frames the codec table quotes for the BLE streaming path — SD-stored frames vary
      // per frame, so anything assuming a constant stride is wrong about real data.
      expect(decoder.shortestPayload, greaterThanOrEqualTo(40));
      expect(decoder.longestPayload, greaterThan(decoder.shortestPayload));

      await processor.destroy();
    });

    test('an empty-rotation bin is a metadata header and nothing else', () async {
      final decoder = _CountingDecoder();
      final processor = VadAudioProcessor.fromSettings(
        settings: _settings(),
        outputDir: tempDir.path,
        decoder: decoder,
      );

      await processor.processSegmentFile(
        _fixture('1788031307_1193025564.bin'),
        DateTime.fromMillisecondsSinceEpoch(1788031307 * 1000),
      );

      // Not an error case: an explicit rotate on an idle device closes a bin holding
      // nothing. It must parse cleanly and contribute no audio.
      expect(decoder.framesDecoded, 0);
      expect(_fixture('1788031307_1193025564.bin').lengthSync(), 36);

      await processor.destroy();
    });
  });

  group('real firmware bin — header fields against external ground truth', () {
    // These compare the bytes to something the parser had no hand in: the names the WAL
    // layer gave the file and its folder. A format misread would have to be wrong in
    // exactly the same way twice to survive.
    test('the metadata header carries the session id that names the file', () {
      final bytes = _fixture('1787938578_4261367757.bin').readAsBytesSync();
      final bd = ByteData.sublistView(bytes);

      expect(bd.getUint32(0, Endian.little), 0xFFFFFFFB, reason: 'metadata tag');
      expect(bd.getUint32(4, Endian.little), 28, reason: 'declared payload length (36 B total)');
      expect(bd.getUint32(28, Endian.little), 4261367757, reason: 'session id, as in the filename');
    });

    test('the VAD-resume marker uses seconds and has no session id', () {
      // CLAUDE.md flags this layout as the odd one out: utc_s (u32) + uptime_ms (u32) +
      // 8 zero bytes, where every other marker carries utc_ms (u64) + uptime + session id.
      // Reading it as the common layout would put the recording tens of thousands of years
      // out, so it is worth pinning against real bytes rather than a fixture written to
      // match our own understanding.
      final bytes = _fixture('1787938578_4261367757.bin').readAsBytesSync();
      final bd = ByteData.sublistView(bytes);

      expect(bd.getUint32(112, Endian.little), 0xFFFFFFFD, reason: 'VAD-resume tag');

      final utcSeconds = bd.getUint32(116, Endian.little);
      // The folder this bin came from is named 1787938578 — the firmware's own timerStart.
      // A resume inside it must sit within the bin's own span, not decades away.
      expect(utcSeconds, closeTo(1787938578, 600));

      expect(bd.getUint32(120, Endian.little), greaterThan(0), reason: 'uptime ms');
      for (var i = 124; i < 132; i++) {
        expect(bytes[i], 0, reason: 'byte $i of the 8-byte zero tail');
      }
    });
  });
}
