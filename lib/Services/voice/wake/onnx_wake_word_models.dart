import 'dart:typed_data';

import 'package:flutter/services.dart';
import 'package:onnxruntime/onnxruntime.dart';

import 'package:horizon/Services/voice/wake/wake_word_detector.dart';

/// openWakeWord's networks on ONNX Runtime.
///
/// The mel and embedding models are openWakeWord's own, shared by every wake
/// phrase; only the small head is trained per phrase. All three are a few
/// milliseconds per 80 ms chunk on a phone, so this runs inline rather than
/// in an isolate.
class OnnxWakeWordModels implements WakeWordModels {
  OnnxWakeWordModels._(this._mel, this._embedding, this._head, this.phrase);

  final OrtSession _mel;
  final OrtSession _embedding;
  final OrtSession _head;

  /// What the loaded head listens for, for the settings screen to show.
  final String phrase;

  static const String _dir = 'assets/wakeword';

  /// Heads in order of preference, with the phrase each one hears.
  static const List<(String, String)> heads = [
    ('hey_horizon.onnx', 'Hey Horizon'),
    ('hey_astral.onnx', 'Hey Astral'),
  ];

  static bool _envReady = false;

  /// Loads from bundled assets. Null if no wake model is bundled, or the
  /// runtime is unavailable on this platform.
  static Future<OnnxWakeWordModels?> load() async {
    try {
      for (final (file, phrase) in heads) {
        final ByteData head;
        try {
          head = await rootBundle.load('$_dir/$file');
        } catch (_) {
          continue;
        }
        return fromBytes(
          mel: (await rootBundle.load('$_dir/melspectrogram.onnx'))
              .buffer
              .asUint8List(),
          embedding: (await rootBundle.load('$_dir/embedding_model.onnx'))
              .buffer
              .asUint8List(),
          head: head.buffer.asUint8List(),
          phrase: phrase,
        );
      }
    } catch (_) {}
    return null;
  }

  /// From model bytes directly — what [load] uses, and what a test uses to
  /// run the real networks without an asset bundle.
  static OnnxWakeWordModels fromBytes({
    required Uint8List mel,
    required Uint8List embedding,
    required Uint8List head,
    required String phrase,
  }) {
    if (!_envReady) {
      OrtEnv.instance.init();
      _envReady = true;
    }
    final options = OrtSessionOptions()
      ..setIntraOpNumThreads(1)
      ..setInterOpNumThreads(1);
    return OnnxWakeWordModels._(
      OrtSession.fromBuffer(mel, options),
      OrtSession.fromBuffer(embedding, options),
      OrtSession.fromBuffer(head, options),
      phrase,
    );
  }

  Float32List _run(OrtSession session, Float32List data, List<int> shape) {
    final input = OrtValueTensor.createTensorWithDataList(data, shape);
    final runOptions = OrtRunOptions();
    try {
      final outputs =
          session.run(runOptions, {session.inputNames.first: input});
      final value = outputs.first?.value;
      for (final output in outputs) {
        output?.release();
      }
      return Float32List.fromList(_flatten(value));
    } finally {
      input.release();
      runOptions.release();
    }
  }

  static List<double> _flatten(Object? value) {
    if (value is num) return [value.toDouble()];
    if (value is List) return [for (final v in value) ..._flatten(v)];
    return const [];
  }

  @override
  Float32List melspectrogram(Float32List samples) {
    final spec = _run(_mel, samples, [1, samples.length]);
    for (var i = 0; i < spec.length; i++) {
      spec[i] = spec[i] / 10 + 2;
    }
    return spec;
  }

  @override
  Float32List embed(Float32List mel) =>
      _run(_embedding, mel, [1, 76, 32, 1]);

  @override
  double score(Float32List embeddings) {
    final out = _run(_head, embeddings, [1, 16, 96]);
    return out.isEmpty ? 0 : out.first;
  }

  @override
  void dispose() {
    _mel.release();
    _embedding.release();
    _head.release();
  }
}
