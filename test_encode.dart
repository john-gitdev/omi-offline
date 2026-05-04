import 'dart:io';
import 'dart:typed_data';
import 'package:opus_dart/opus_dart.dart';

void main() async {
  final encoder = SimpleOpusEncoder(sampleRate: 16000, channels: 1, application: Application.voip);
  final pcm = Int16List(320); // 20ms of silence
  final packet = encoder.encode(input: pcm);
  print(packet.map((b) => b.toRadixString(16).padLeft(2, '0')).join(', '));
  encoder.destroy();
}
