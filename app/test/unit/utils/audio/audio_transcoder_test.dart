import 'package:flutter_test/flutter_test.dart';
import 'package:omi/backend/schema/bt_device/bt_device.dart';
import 'package:omi/utils/audio/audio_transcoder.dart';

void main() {
  group('AudioTranscoderFactory', () {
    group('getTranscoder', () {
      test(
        'returns OpusToRawPcmTranscoder for opus -> pcm16',
        () {
          final transcoder = AudioTranscoderFactory.getTranscoder(BleAudioCodec.opus, BleAudioCodec.pcm16);
          expect(transcoder, isA<OpusToRawPcmTranscoder>());
        },
        skip: 'OpusToRawPcmTranscoder throws LateInitializationError if FFI opus lib is not loaded in test environment',
      );

      test('returns PassThroughTranscoder for opus -> opus', () {
        final transcoder = AudioTranscoderFactory.getTranscoder(BleAudioCodec.opus, BleAudioCodec.opus);
        expect(transcoder, isA<PassThroughTranscoder>());
      });

      test('returns PassThroughTranscoder for opus -> opusFS320', () {
        final transcoder = AudioTranscoderFactory.getTranscoder(BleAudioCodec.opus, BleAudioCodec.opusFS320);
        expect(transcoder, isA<PassThroughTranscoder>());
      });

      test('returns PassThroughTranscoder for fallback (e.g. unknown -> pcm16)', () {
        final transcoder = AudioTranscoderFactory.getTranscoder(BleAudioCodec.unknown, BleAudioCodec.pcm16);
        expect(transcoder, isA<PassThroughTranscoder>());
      });
    });

    group('createToWav', () {
      test('returns PcmToWavTranscoder for PCM8', () {
        final transcoder = AudioTranscoderFactory.createToWav(sourceCodec: BleAudioCodec.pcm8, sampleRate: 8000);
        expect(transcoder, isA<PcmToWavTranscoder>());
      });

      test('returns PcmToWavTranscoder for PCM16', () {
        final transcoder = AudioTranscoderFactory.createToWav(sourceCodec: BleAudioCodec.pcm16, sampleRate: 16000);
        expect(transcoder, isA<PcmToWavTranscoder>());
      });

      test(
        'returns OpusToWavTranscoder for Opus',
        () {
          final transcoder = AudioTranscoderFactory.createToWav(sourceCodec: BleAudioCodec.opus, sampleRate: 16000);
          expect(transcoder, isA<OpusToWavTranscoder>());
        },
        skip: 'OpusToWavTranscoder throws LateInitializationError if FFI opus lib is not loaded in test environment',
      );

      test(
        'returns OpusToWavTranscoder for OpusFS320',
        () {
          final transcoder = AudioTranscoderFactory.createToWav(sourceCodec: BleAudioCodec.opusFS320, sampleRate: 16000);
          expect(transcoder, isA<OpusToWavTranscoder>());
        },
        skip: 'OpusToWavTranscoder throws LateInitializationError if FFI opus lib is not loaded in test environment',
      );

      test('returns PcmToWavTranscoder for unknown codec (default case)', () {
        final transcoder = AudioTranscoderFactory.createToWav(sourceCodec: BleAudioCodec.unknown, sampleRate: 16000);
        expect(transcoder, isA<PcmToWavTranscoder>());
      });

      test('returns PcmToWavTranscoder for mulaw8 codec (default case)', () {
        final transcoder = AudioTranscoderFactory.createToWav(sourceCodec: BleAudioCodec.mulaw8, sampleRate: 16000);
        expect(transcoder, isA<PcmToWavTranscoder>());
      });

      test('returns PcmToWavTranscoder for mulaw16 codec (default case)', () {
        final transcoder = AudioTranscoderFactory.createToWav(sourceCodec: BleAudioCodec.mulaw16, sampleRate: 16000);
        expect(transcoder, isA<PcmToWavTranscoder>());
      });
    });

    group('createToRawPcm', () {
      test('returns RawPcmTranscoder for PCM8', () {
        final transcoder = AudioTranscoderFactory.createToRawPcm(sourceCodec: BleAudioCodec.pcm8, sampleRate: 8000);
        expect(transcoder, isA<RawPcmTranscoder>());
      });

      test('returns RawPcmTranscoder for PCM16', () {
        final transcoder = AudioTranscoderFactory.createToRawPcm(sourceCodec: BleAudioCodec.pcm16, sampleRate: 16000);
        expect(transcoder, isA<RawPcmTranscoder>());
      });

      test(
        'returns OpusToRawPcmTranscoder for Opus',
        () {
          final transcoder = AudioTranscoderFactory.createToRawPcm(sourceCodec: BleAudioCodec.opus, sampleRate: 16000);
          expect(transcoder, isA<OpusToRawPcmTranscoder>());
        },
        skip: 'OpusToRawPcmTranscoder throws LateInitializationError if FFI opus lib is not loaded in test environment',
      );

      test(
        'returns OpusToRawPcmTranscoder for OpusFS320',
        () {
          final transcoder = AudioTranscoderFactory.createToRawPcm(
            sourceCodec: BleAudioCodec.opusFS320,
            sampleRate: 16000,
          );
          expect(transcoder, isA<OpusToRawPcmTranscoder>());
        },
        skip: 'OpusToRawPcmTranscoder throws LateInitializationError if FFI opus lib is not loaded in test environment',
      );

      test('returns RawPcmTranscoder for unknown codec (default case)', () {
        final transcoder = AudioTranscoderFactory.createToRawPcm(sourceCodec: BleAudioCodec.unknown, sampleRate: 16000);
        expect(transcoder, isA<RawPcmTranscoder>());
      });

      test('returns RawPcmTranscoder for mulaw8 codec (default case)', () {
        final transcoder = AudioTranscoderFactory.createToRawPcm(sourceCodec: BleAudioCodec.mulaw8, sampleRate: 16000);
        expect(transcoder, isA<RawPcmTranscoder>());
      });

      test('returns RawPcmTranscoder for mulaw16 codec (default case)', () {
        final transcoder = AudioTranscoderFactory.createToRawPcm(sourceCodec: BleAudioCodec.mulaw16, sampleRate: 16000);
        expect(transcoder, isA<RawPcmTranscoder>());
      });
    });
  });
}
