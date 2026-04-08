import 'package:flutter_test/flutter_test.dart';
import 'package:vad/vad.dart';

void main() {
  test('inspect vad', () async {
    final vad = await VadIterator.create(
      isDebug: false,
      sampleRate: 16000,
      frameSamples: 320,
      positiveSpeechThreshold: 0.5,
      negativeSpeechThreshold: 0.35,
      redemptionFrames: 0,
      preSpeechPadFrames: 0,
      minSpeechFrames: 0,
      model: 'silero_vad.onnx',
    );
    print(vad);
  });
}
