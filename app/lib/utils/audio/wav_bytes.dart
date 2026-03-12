import 'dart:typed_data';

import 'package:opus_dart/opus_dart.dart';

import 'package:omi/backend/schema/bt_device/bt_device.dart';

/// A class to handle WAV file format conversion
class WavBytes {
  final Uint8List _pcmData;
  final int _sampleRate;
  final int _numChannels;
  final int _bitsPerSample = 16; // PCM is typically 16-bit

  WavBytes._(this._pcmData, this._sampleRate, this._numChannels);

  /// Create a WAV bytes object from PCM data
  factory WavBytes.fromPcm(
    Uint8List pcmData, {
    required int sampleRate,
    required int numChannels,
  }) {
    return WavBytes._(pcmData, sampleRate, numChannels);
  }

  /// Convert to WAV format bytes
  Uint8List asBytes() {
    // Calculate sizes
    final int byteRate = _sampleRate * _numChannels * _bitsPerSample ~/ 8;
    final int blockAlign = _numChannels * _bitsPerSample ~/ 8;
    final int subchunk2Size = _pcmData.length;
    final int chunkSize = 36 + subchunk2Size;

    // Create a buffer for the WAV header (44 bytes) + PCM data
    final ByteData wavData = ByteData(44 + _pcmData.length);

    // Write WAV header
    // "RIFF" chunk descriptor
    wavData.setUint8(0, 0x52); // 'R'
    wavData.setUint8(1, 0x49); // 'I'
    wavData.setUint8(2, 0x46); // 'F'
    wavData.setUint8(3, 0x46); // 'F'
    wavData.setUint32(4, chunkSize, Endian.little); // Chunk size
    wavData.setUint8(8, 0x57); // 'W'
    wavData.setUint8(9, 0x41); // 'A'
    wavData.setUint8(10, 0x56); // 'V'
    wavData.setUint8(11, 0x45); // 'E'

    // "fmt " sub-chunk
    wavData.setUint8(12, 0x66); // 'f'
    wavData.setUint8(13, 0x6D); // 'm'
    wavData.setUint8(14, 0x74); // 't'
    wavData.setUint8(15, 0x20); // ' '
    wavData.setUint32(16, 16, Endian.little); // Subchunk1Size (16 for PCM)
    wavData.setUint16(20, 1, Endian.little); // AudioFormat (1 for PCM)
    wavData.setUint16(22, _numChannels, Endian.little); // NumChannels
    wavData.setUint32(24, _sampleRate, Endian.little); // SampleRate
    wavData.setUint32(28, byteRate, Endian.little); // ByteRate
    wavData.setUint16(32, blockAlign, Endian.little); // BlockAlign
    wavData.setUint16(34, _bitsPerSample, Endian.little); // BitsPerSample

    // "data" sub-chunk
    wavData.setUint8(36, 0x64); // 'd'
    wavData.setUint8(37, 0x61); // 'a'
    wavData.setUint8(38, 0x74); // 't'
    wavData.setUint8(39, 0x61); // 'a'
    wavData.setUint32(40, subchunk2Size, Endian.little); // Subchunk2Size

    // Copy PCM data
    for (int i = 0; i < _pcmData.length; i++) {
      wavData.setUint8(44 + i, _pcmData[i]);
    }

    return wavData.buffer.asUint8List();
  }
}

class WavBytesUtil {
  BleAudioCodec codec;
  int framesPerSecond;
  List<List<int>> frames = [];
  List<List<int>> rawPackets = [];
  final SimpleOpusDecoder opusDecoder = SimpleOpusDecoder(sampleRate: 16000, channels: 1);

  WavBytesUtil({required this.codec, required this.framesPerSecond});

  // needed variables for `storeFramePacket`
  int lastPacketIndex = -1;
  int lastFrameId = -1;
  List<int> pending = [];
  int lost = 0;

  void storeFramePacket(dynamic value) {
    if (value is List<int>) {
      rawPackets.add(value);
      if (codec.isOpusSupported()) {
        _handleOpusPacket(value);
      } else {
        _handlePcmPacket(value);
      }
    }
  }

  void _handleOpusPacket(List<int> value) {
    if (value.length < 3) return;
    int packetIndex = value[0];
    if (lastPacketIndex != -1 && (packetIndex - lastPacketIndex) % 256 > 1) {
      lost += (packetIndex - lastPacketIndex) % 256 - 1;
    }
    lastPacketIndex = packetIndex;
    frames.add(value.sublist(2));
  }

  void _handlePcmPacket(List<int> value) {
    frames.add(value);
  }

  Uint8List exportWav() {
    final List<int> pcmData = [];
    if (codec.isOpusSupported()) {
      for (var frame in frames) {
        try {
          final decoded = opusDecoder.decode(input: Uint8List.fromList(frame));
          pcmData.addAll(decoded);
        } catch (e) {
          // skip
        }
      }
    } else {
      for (var frame in frames) {
        pcmData.addAll(frame);
      }
    }

    return WavBytes.fromPcm(
      Uint8List.fromList(pcmData),
      sampleRate: 16000,
      numChannels: 1,
    ).asBytes();
  }

  Uint8List getUInt8ListBytes() {
    return exportWav();
  }

  void clear() {
    frames.clear();
    rawPackets.clear();
    lastPacketIndex = -1;
    lost = 0;
  }
}
