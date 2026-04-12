import 'dart:async';
import 'dart:io';

import 'package:flutter_sound/flutter_sound.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mockito/mockito.dart';
import 'package:omi/services/wals.dart';
import 'package:omi/utils/audio_player_utils.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:plugin_platform_interface/plugin_platform_interface.dart';

import 'test_mocks.mocks.dart';

class MockPathProviderPlatform extends Fake with MockPlatformInterfaceMixin implements PathProviderPlatform {
  @override
  Future<String?> getTemporaryPath() async {
    return Directory.systemTemp.path;
  }
}

void main() {
  group('AudioPlayerUtils core functionality', () {
    late AudioPlayerUtils utils;
    late MockFlutterSoundPlayer mockPlayer;
    late StreamController<PlaybackDisposition> progressController;

    setUpAll(() {
      PathProviderPlatform.instance = MockPathProviderPlatform();
    });

    setUp(() {
      utils = AudioPlayerUtils();
      mockPlayer = MockFlutterSoundPlayer();
      utils.audioPlayerMock = mockPlayer;
      progressController = StreamController<PlaybackDisposition>.broadcast();

      when(mockPlayer.startPlayer(
        fromURI: anyNamed('fromURI'),
        codec: anyNamed('codec'),
        whenFinished: anyNamed('whenFinished'),
      )).thenAnswer((_) async => null);

      when(mockPlayer.stopPlayer()).thenAnswer((_) async => null);
      when(mockPlayer.seekToPlayer(any)).thenAnswer((_) async => null);
      when(mockPlayer.isOpen()).thenReturn(true);
      when(mockPlayer.isPlaying).thenReturn(true);
      when(mockPlayer.onProgress).thenAnswer((_) => progressController.stream);
    });

    tearDown(() {
      progressController.close();
      utils.audioPlayerMock = null;
      utils.stopPlaybackForTesting();
    });

    test('singleton instance is the same', () {
      final instance1 = AudioPlayerUtils.instance;
      final instance2 = AudioPlayerUtils();
      final instance3 = AudioPlayerUtils.instance;

      expect(identical(instance1, instance2), isTrue);
      expect(identical(instance1, instance3), isTrue);
    });

    test('initial state is correct', () {
      expect(utils.currentPlayingId, isNull);
      expect(utils.isProcessingAudio, isFalse);
      expect(utils.currentPosition, Duration.zero);
      expect(utils.totalDuration, Duration.zero);
      expect(utils.playbackProgress, 0.0);
    });

    group('isPlaying', () {
      test('returns true only for matching id', () {
        expect(utils.isPlaying('some_id'), isFalse);
        expect(utils.isPlaying('123'), isFalse);
      });
    });

    final validWalMap = {
      'codec': 'pcm16',
      'channel': 1,
      'device': 'test_device',
      'fileNum': 1,
      'storageOffset': 0,
      'storageTotalBytes': 1000,
      'timerStart': 0,
      'storage': 'local',
      'status': 'synced',
    };

    group('canPlayOrShare', () {
      test('returns true when filePath is not empty', () {
        final walMap = Map<String, dynamic>.from(validWalMap);
        walMap['filePath'] = '/path/to/file.wav';

        final wal = Wal.fromJson(walMap);
        expect(utils.canPlayOrShare(wal), isTrue);
      });

      test('returns true when data is not empty', () {
        final walMap = Map<String, dynamic>.from(validWalMap);
        final wal = Wal.fromJson(walMap);
        wal.data = [1, 2, 3];

        expect(utils.canPlayOrShare(wal), isTrue);
      });

      test('returns true when storage is sdcard', () {
        final walMap = Map<String, dynamic>.from(validWalMap);
        walMap['storage'] = 'sdcard';

        final wal = Wal.fromJson(walMap);
        expect(utils.canPlayOrShare(wal), isTrue);
      });

      test('returns false when no valid source is available', () {
        final walMap = Map<String, dynamic>.from(validWalMap);
        walMap['storage'] = 'local';

        final wal = Wal.fromJson(walMap);
        wal.data = null;
        wal.filePath = null;
        expect(utils.canPlayOrShare(wal), isFalse);
      });
    });

    group('shareAsAudio', () {
      test('throws if file cannot be shared', () async {
        final walMap = Map<String, dynamic>.from(validWalMap);
        walMap['storage'] = 'local';
        final wal = Wal.fromJson(walMap);
        wal.data = null;
        wal.filePath = null;

        expect(
          () => utils.shareAsAudio(wal),
          throwsA(isA<Exception>().having((e) => e.toString(), 'message', contains('Audio file not available for sharing'))),
        );
      });
    });

    test('togglePlayback starts playback when stopped', () async {
      final wal = Wal.fromJson(Map<String, dynamic>.from(validWalMap));
      final validPcmFile = File('${Directory.systemTemp.path}/valid.pcm');
      await validPcmFile.writeAsBytes([4, 0, 0, 0, 1, 2, 3, 4]);
      wal.filePath = validPcmFile.path;

      expect(utils.isPlaying(wal.id), isFalse);

      await utils.togglePlayback(wal);

      expect(utils.isPlaying(wal.id), isTrue);
      expect(utils.currentPlayingId, wal.id);
      expect(utils.isProcessingAudio, isFalse);

      verify(mockPlayer.startPlayer(
        fromURI: anyNamed('fromURI'),
        whenFinished: anyNamed('whenFinished'),
      )).called(1);

      await validPcmFile.delete();
    });

    test('togglePlayback stops playback if already playing same id', () async {
      final wal = Wal.fromJson(Map<String, dynamic>.from(validWalMap));
      final validPcmFile = File('${Directory.systemTemp.path}/valid2.pcm');
      await validPcmFile.writeAsBytes([4, 0, 0, 0, 1, 2, 3, 4]);
      wal.filePath = validPcmFile.path;

      await utils.stopPlaybackForTesting();

      await utils.togglePlayback(wal);
      expect(utils.isPlaying(wal.id), isTrue);

      await utils.togglePlayback(wal);
      expect(utils.isPlaying(wal.id), isFalse);
      expect(utils.currentPlayingId, isNull);

      verify(mockPlayer.stopPlayer()).called(1);

      await validPcmFile.delete();
    });

    test('seekToPosition delegates to player', () async {
      final wal = Wal.fromJson(Map<String, dynamic>.from(validWalMap));
      final validPcmFile = File('${Directory.systemTemp.path}/valid3.pcm');
      await validPcmFile.writeAsBytes([4, 0, 0, 0, 1, 2, 3, 4]);
      wal.filePath = validPcmFile.path;

      await utils.stopPlaybackForTesting();

      await utils.togglePlayback(wal);

      await utils.seekToPosition(const Duration(seconds: 5));

      verify(mockPlayer.seekToPlayer(const Duration(seconds: 5))).called(1);
      expect(utils.currentPosition, const Duration(seconds: 5));

      await validPcmFile.delete();
    });

    test('skipForward and skipBackward bounds clamping', () async {
      final wal = Wal.fromJson(Map<String, dynamic>.from(validWalMap));
      wal.seconds = 20; // total duration 20s
      final validPcmFile = File('${Directory.systemTemp.path}/valid4.pcm');
      await validPcmFile.writeAsBytes([4, 0, 0, 0, 1, 2, 3, 4]);
      wal.filePath = validPcmFile.path;

      await utils.stopPlaybackForTesting();
      await utils.togglePlayback(wal);

      // give time for position tracking setup
      await Future.delayed(const Duration(milliseconds: 50));
      expect(utils.totalDuration, const Duration(seconds: 20));

      await utils.skipForward(duration: const Duration(seconds: 15));
      expect(utils.currentPosition, const Duration(seconds: 15));

      // Skip beyond duration
      await utils.skipForward(duration: const Duration(seconds: 10));
      expect(utils.currentPosition, const Duration(seconds: 20)); // Clamped to 20

      await utils.skipBackward(duration: const Duration(seconds: 25));
      expect(utils.currentPosition, Duration.zero); // Clamped to 0

      await validPcmFile.delete();
    });
  });
}
