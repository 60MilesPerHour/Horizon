import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

import 'package:horizon/Services/voice/wake/onnx_wake_word_models.dart';
import 'package:horizon/Services/voice/wake/wake_word_detector.dart';

/// Runs the real openWakeWord networks through the Dart pipeline. Skipped
/// where ONNX Runtime can't load (it needs its native library on the path),
/// and where the test clips haven't been generated.
void main() {
  OnnxWakeWordModels? models;
  try {
    models = OnnxWakeWordModels.fromBytes(
      mel: File('assets/wakeword/melspectrogram.onnx').readAsBytesSync(),
      embedding: File('assets/wakeword/embedding_model.onnx').readAsBytesSync(),
      head: File('assets/wakeword/hey_horizon.onnx').readAsBytesSync(),
      phrase: 'Hey Horizon',
    );
  } catch (_) {}
  final clips = Directory('/tmp/oww');
  final skip = models == null || !clips.existsSync()
      ? 'ONNX Runtime or test clips unavailable'
      : null;

  (double, bool) run(String name, {int sustain = WakeWordDetector.strictSustain}) {
    final detector = WakeWordDetector(models!, sustain: sustain)..reset();
    final pcm = File('${clips.path}/$name.pcm').readAsBytesSync();
    final int16 = Int16List.view(pcm.buffer, 0, pcm.length ~/ 2);
    final audio = Float32List(16000 + int16.length + 16000);
    for (var i = 0; i < int16.length; i++) {
      audio[16000 + i] = int16[i] / 32767.0;
    }
    var peak = 0.0;
    var woke = false;
    // Delivered in phone-sized pieces, not neat 80 ms chunks, the way the
    // microphone actually hands them over.
    for (var i = 0; i < audio.length; i += 1000) {
      final end = (i + 1000).clamp(0, audio.length);
      if (detector.add(Float32List.sublistView(audio, i, end))) woke = true;
      if (detector.lastScore > peak) peak = detector.lastScore;
    }
    return (peak, woke);
  }

  for (final voice in ['am_michael', 'af_heart', 'bm_george']) {
    test('wakes on "Hey Horizon" ($voice)', () {
      expect(run('heyhorizon_$voice').$2, isTrue);
      expect(run('heyhorizon_$voice', sustain: WakeWordDetector.balancedSustain).$2, isTrue);
    }, skip: skip);

    test('balanced still ignores a sentence starting with "hey" ($voice)', () {
      expect(run('heywhattimeisit_$voice', sustain: WakeWordDetector.balancedSustain).$2, isFalse);
    }, skip: skip);

    test('wakes on the phrase followed by a request ($voice)', () {
      expect(run('heyhorizonwhatstheweather_$voice').$2, isTrue);
    }, skip: skip);

    // The ones that matter for an app named after an ordinary word.
    for (final miss in ['horizon', 'heyharrison', 'thehorizonlooksbeautifultonight', 'heywhattimeisit']) {
      test('ignores "$miss" ($voice)', () {
        final (peak, woke) = run('${miss}_$voice');
        expect(woke, isFalse, reason: 'peak $peak');
      }, skip: skip);
    }
  }
}
