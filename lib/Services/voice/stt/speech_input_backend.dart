/// Which engine turns speech into text.
enum SttBackend {
  /// The platform recogniser via `speech_to_text`. Free, no key, no network
  /// once a language pack is downloaded, and gives live partial results.
  /// The default for that reason.
  device,

  /// A self-hosted Whisper server over the OpenAI-compatible
  /// `/v1/audio/transcriptions` endpoint — faster-whisper-server, Speaches,
  /// whisper.cpp's server, LocalAI. Also reaches OpenAI or Groq by pointing
  /// the base URL at them. Best accuracy if you have a GPU to spare.
  whisper,

  /// ElevenLabs Scribe. Paid per hour, very accurate, no hardware needed.
  elevenLabs;

  static SttBackend fromString(String? value) {
    switch (value) {
      case 'whisper':
        return SttBackend.whisper;
      case 'elevenlabs':
        return SttBackend.elevenLabs;
      default:
        return SttBackend.device;
    }
  }

  String get storageValue {
    switch (this) {
      case SttBackend.device:
        return 'device';
      case SttBackend.whisper:
        return 'whisper';
      case SttBackend.elevenLabs:
        return 'elevenlabs';
    }
  }

  String get label {
    switch (this) {
      case SttBackend.device:
        return 'Device';
      case SttBackend.whisper:
        return 'Whisper server';
      case SttBackend.elevenLabs:
        return 'ElevenLabs';
    }
  }

  /// Whether this backend streams partial text as the user speaks. Only the
  /// platform recogniser does; the others transcribe a finished clip, so the
  /// UI has to show a level meter instead of words appearing.
  bool get hasPartialResults => this == SttBackend.device;

  /// Whether this backend needs audio captured and uploaded, which is what
  /// makes endpointing our problem rather than the recogniser's.
  bool get needsRecording => this != SttBackend.device;
}

/// What a transcription attempt produced.
class SttResult {
  final String text;

  /// User-facing failure reason, or null on success. Set alongside an empty
  /// [text] — never thrown, because a failed transcription should put a
  /// message on screen, not take the session down.
  final String? error;

  const SttResult(this.text) : error = null;
  const SttResult.failure(this.error) : text = '';

  bool get isEmpty => text.trim().isEmpty;
}

/// A backend that transcribes a recorded audio file.
///
/// Only the remote backends implement this; the device recogniser has its own
/// streaming path and never produces a file.
abstract class RecordedAudioTranscriber {
  /// True when this backend has the configuration it needs (URL, key).
  bool get isConfigured;

  /// Why it isn't usable, for the settings UI. Null when [isConfigured].
  String? get configurationHint;

  /// Transcribes the WAV file at [path]. Never throws.
  Future<SttResult> transcribe(String path, {String? languageCode});
}
