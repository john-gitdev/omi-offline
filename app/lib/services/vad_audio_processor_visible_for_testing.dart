part of 'vad_audio_processor.dart';

extension VadAudioProcessorTesting on VadAudioProcessor {
  Future<String?> saveRecordingTest(List<FrameRef> refs, DateTime startTime) {
    return _saveRecording(refs, startTime);
  }
}
