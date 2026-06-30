import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:omi/services/omi_api_client.dart';

void main() {
  group('OmiApiClient testConnection', () {
    test('returns false when refreshToken is empty', () async {
      final result = await OmiApiClient.testConnection(
        refreshToken: '',
        apiKey: 'test_key',
      );
      expect(result, isFalse);
    });

    test('returns false when apiKey is empty', () async {
      final result = await OmiApiClient.testConnection(
        refreshToken: 'test_token',
        apiKey: '',
      );
      expect(result, isFalse);
    });

    test('returns true on 200 success', () async {
      final mockClient = MockClient((request) async {
        return http.Response('', 200);
      });

      await http.runWithClient(() async {
        final result = await OmiApiClient.testConnection(
          refreshToken: 'test_token',
          apiKey: 'test_key',
        );
        expect(result, isTrue);
      }, () => mockClient);
    });

    test('returns false on non-200 response', () async {
      final mockClient = MockClient((request) async {
        return http.Response('', 401);
      });

      await http.runWithClient(() async {
        final result = await OmiApiClient.testConnection(
          refreshToken: 'test_token',
          apiKey: 'test_key',
        );
        expect(result, isFalse);
      }, () => mockClient);
    });

    test('returns false on TimeoutException', () async {
      final mockClient = MockClient((request) async {
        throw TimeoutException('Timeout');
      });

      await http.runWithClient(() async {
        final result = await OmiApiClient.testConnection(
          refreshToken: 'test_token',
          apiKey: 'test_key',
        );
        expect(result, isFalse);
      }, () => mockClient);
    });

    test('returns false on SocketException', () async {
      final mockClient = MockClient((request) async {
        throw const SocketException('No network connection');
      });

      await http.runWithClient(() async {
        final result = await OmiApiClient.testConnection(
          refreshToken: 'test_token',
          apiKey: 'test_key',
        );
        expect(result, isFalse);
      }, () => mockClient);
    });

    test('returns false on generic exception', () async {
      final mockClient = MockClient((request) async {
        throw Exception('Generic error');
      });

      await http.runWithClient(() async {
        final result = await OmiApiClient.testConnection(
          refreshToken: 'test_token',
          apiKey: 'test_key',
        );
        expect(result, isFalse);
      }, () => mockClient);
    });
  });

  group('OmiApiClient._readOpusFrameChunks marker skipping', () {
    late Directory tempDir;

    setUp(() {
      tempDir = Directory.systemTemp.createTempSync('omi_api_chunks');
    });
    tearDown(() {
      if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
    });

    void addLe32(BytesBuilder b, int v) {
      final d = ByteData(4)..setUint32(0, v, Endian.little);
      b.add(d.buffer.asUint8List());
    }

    // A real opus frame: 4-byte little-endian length prefix + length payload bytes.
    void addFrame(BytesBuilder b, int len) {
      addLe32(b, len);
      b.add(List.filled(len, 0));
    }

    Future<File> writeBin(String name, void Function(BytesBuilder) build) async {
      final b = BytesBuilder();
      build(b);
      final f = File('${tempDir.path}/$name');
      await f.writeAsBytes(b.toBytes());
      return f;
    }

    test('skips all 20-byte markers (F8/F9/FA/FC/FE), 16-byte FD, 36-byte FB, and keeps real frames', () async {
      final file = await writeBin('markers.bin', (b) {
        // Metadata header (0xFFFFFFFB): 4-byte header + 32 bytes payload = 36 total.
        addLe32(b, 0xFFFFFFFB);
        b.add(List.filled(32, 0));
        addFrame(b, 40); // real frame 1
        // 20-byte markers (4-byte header + 16-byte payload):
        for (final m in [0xFFFFFFF8, 0xFFFFFFF9, 0xFFFFFFFA, 0xFFFFFFFC, 0xFFFFFFFE]) {
          addLe32(b, m);
          b.add(List.filled(16, 0));
        }
        addFrame(b, 40); // real frame 2
        // VAD-resume (0xFFFFFFFD): 4-byte header + 12-byte payload = 16 total.
        addLe32(b, 0xFFFFFFFD);
        b.add(List.filled(12, 0));
        addFrame(b, 40); // real frame 3
      });

      final chunks = await OmiApiClient.readOpusFrameChunksForTest(file);

      // All three real frames survive in a single chunk; markers are stripped and
      // must not desync the stream (each is consumed at its exact byte width).
      expect(chunks.length, 1);
      final out = chunks.first;
      // 3 frames × (4-byte prefix + 40-byte payload) = 132 bytes, nothing else.
      expect(out.length, 3 * (4 + 40));
    });

    test('a priority-start marker (0xFFFFFFF8) between two frames does not corrupt them', () async {
      final file = await writeBin('priority.bin', (b) {
        addFrame(b, 40);
        addLe32(b, 0xFFFFFFF8);
        b.add(List.filled(16, 0));
        addFrame(b, 40);
      });

      final chunks = await OmiApiClient.readOpusFrameChunksForTest(file);
      expect(chunks.length, 1);
      expect(chunks.first.length, 2 * (4 + 40));
    });
  });
}
