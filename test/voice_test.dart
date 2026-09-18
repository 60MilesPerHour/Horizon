import 'package:flutter_test/flutter_test.dart';

import 'package:horizon/Services/voice/speech_synthesis_service.dart';
import 'package:horizon/Services/voice/voice_session_controller.dart';

void main() {
  // FlutterTts installs a method-call handler in its constructor, which needs
  // a binding even though nothing here actually speaks.
  TestWidgetsFlutterBinding.ensureInitialized();

  group('sentence chunking', () {
    int boundary(String text, {int from = 0}) =>
        VoiceSessionController.sentenceBoundary(text, from: from);

    test('waits for a complete sentence before speaking anything', () {
      // Speaking "The" on its own is a stutter, and on ElevenLabs it is also
      // a billed request.
      expect(boundary('The'), 0);
      expect(boundary('The answer is'), 0);
    });

    test('splits once a long enough sentence is complete', () {
      const text = 'Reins shipped version 2.3 today. It adds on-device models';
      final end = boundary(text);
      expect(text.substring(0, end).trim(),
          'Reins shipped version 2.3 today.');
    });

    test('does not split on a decimal point mid-number', () {
      // "version 2.3" must not become "version 2." — the terminator only
      // counts when whitespace follows.
      const text = 'It went from version 2.3 to version 2.4 in one release';
      expect(boundary(text), 0);
    });

    test('takes every complete sentence available in one chunk', () {
      // Several sentences arriving in one streaming tick are spoken as one
      // utterance, so nothing is left behind for a second call.
      const text = 'First sentence here, quite long. Second sentence follows.';
      final first = boundary(text);
      expect(first, text.length);
      expect(boundary(text, from: first), first);
    });

    test('speaks a finished sentence while the next one is still arriving', () {
      const text = 'First sentence here, quite long. Second sentence is par';
      final end = boundary(text);
      expect(text.substring(0, end).trim(),
          'First sentence here, quite long.');
    });

    test('treats a newline as a sentence end', () {
      const text = 'Here are the three things you asked about\nThe first one';
      final end = boundary(text);
      expect(text.substring(0, end).trim(),
          'Here are the three things you asked about');
    });

    test('handles question and exclamation marks', () {
      const text = 'Did you mean the Ollama server on horizon? I can check.';
      final end = boundary(text);
      expect(
        text.substring(0, end).trim(),
        'Did you mean the Ollama server on horizon? I can check.',
      );
    });
  });

  group('cleanForSpeech', () {
    test('drops code blocks instead of reading them aloud', () {
      final spoken = SpeechSynthesisService.cleanForSpeech(
        'Run this:\n```bash\nsudo systemctl restart ollama\n```\nThen retry.',
      );
      expect(spoken, contains('code block omitted'));
      expect(spoken, isNot(contains('systemctl')));
      expect(spoken, contains('Then retry.'));
    });

    test('keeps a link label and does not spell out the URL', () {
      final spoken = SpeechSynthesisService.cleanForSpeech(
        'See [the release notes](https://github.com/ibrahimcetin/reins) first.',
      );
      expect(spoken, 'See the release notes first.');
    });

    test('replaces a bare URL with something sayable', () {
      final spoken = SpeechSynthesisService.cleanForSpeech(
        'Check https://openrouter.ai/models for pricing.',
      );
      expect(spoken, 'Check a link for pricing.');
    });

    test('strips emphasis rather than reading asterisks', () {
      final spoken = SpeechSynthesisService.cleanForSpeech(
        'This is **important** and _urgent_.',
      );
      expect(spoken, 'This is important and urgent.');
    });

    test('strips headings, bullets and citation markers', () {
      final spoken = SpeechSynthesisService.cleanForSpeech(
        '## Summary\n- Reins is now paid [1]\n- The repo is frozen [2]',
      );
      expect(spoken, isNot(contains('#')));
      expect(spoken, isNot(contains('[1]')));
      expect(spoken, contains('Reins is now paid'));
      expect(spoken, contains('The repo is frozen'));
    });

    test('inline code keeps its content', () {
      expect(
        SpeechSynthesisService.cleanForSpeech('Set `OLLAMA_HOST` first.'),
        'Set OLLAMA_HOST first.',
      );
    });

    test('whitespace-only input produces nothing to say', () {
      expect(SpeechSynthesisService.cleanForSpeech('   \n  '), '');
      expect(SpeechSynthesisService.cleanForSpeech('**'), '');
    });
  });

  group('SpeechEngine', () {
    test('round-trips through its stored value', () {
      for (final engine in SpeechEngine.values) {
        expect(SpeechEngine.fromString(engine.storageValue), engine);
      }
    });

    test('an unknown or absent stored value falls back to the device voice',
        () {
      expect(SpeechEngine.fromString(null), SpeechEngine.system);
      expect(SpeechEngine.fromString('azure'), SpeechEngine.system);
    });
  });

  group('engine fallback', () {
    test('ElevenLabs without a key reports the device voice as effective', () {
      final service = SpeechSynthesisService(engine: SpeechEngine.elevenLabs);
      expect(service.isElevenLabsConfigured, isFalse);
      // Otherwise a missing key means silence rather than a robotic voice.
      expect(service.effectiveEngine, SpeechEngine.system);
    });

    test('ElevenLabs with a key is used', () {
      final service = SpeechSynthesisService(
        engine: SpeechEngine.elevenLabs,
        elevenLabsKey: 'sk_test',
      );
      expect(service.effectiveEngine, SpeechEngine.elevenLabs);
    });
  });
}
