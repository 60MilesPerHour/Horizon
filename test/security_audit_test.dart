import 'package:flutter_test/flutter_test.dart';

import 'package:horizon/Services/security_audit.dart';

SecurityAuditInputs inputs({
  String ollamaAddress = 'http://192.168.1.10:11434',
  String ollamaBackupAddress = '',
  bool ollamaUsingBackup = false,
  bool ollamaHasToken = false,
  bool ollamaHasCloudflareAccess = false,
  bool openRouterEnabled = false,
  bool openRouterHasKey = false,
  String webSearchBackend = 'off',
  bool serpApiConfigured = false,
  String searxngUrl = '',
  String sttBackend = 'device',
  String whisperUrl = '',
  bool elevenLabsConfigured = false,
  String ttsEngine = 'system',
  String ttsUrl = '',
  String homeAssistantUrl = '',
  bool homeAssistantConfigured = false,
  int sharedChatCount = 0,
  int sharedCloudChatCount = 0,
}) {
  return SecurityAuditInputs(
    ollamaAddress: ollamaAddress,
    ollamaBackupAddress: ollamaBackupAddress,
    ollamaUsingBackup: ollamaUsingBackup,
    ollamaHasToken: ollamaHasToken,
    ollamaHasCloudflareAccess: ollamaHasCloudflareAccess,
    openRouterEnabled: openRouterEnabled,
    openRouterHasKey: openRouterHasKey,
    webSearchBackend: webSearchBackend,
    serpApiConfigured: serpApiConfigured,
    searxngUrl: searxngUrl,
    sttBackend: sttBackend,
    whisperUrl: whisperUrl,
    elevenLabsConfigured: elevenLabsConfigured,
    ttsEngine: ttsEngine,
    ttsUrl: ttsUrl,
    homeAssistantUrl: homeAssistantUrl,
    homeAssistantConfigured: homeAssistantConfigured,
    sharedChatCount: sharedChatCount,
    sharedCloudChatCount: sharedCloudChatCount,
  );
}

EgressEntry entryNamed(List<EgressEntry> entries, String name) =>
    entries.firstWhere((e) => e.name == name);

/// The audit page's whole value is that it's derived from real configuration,
/// so the tests that matter are the ones proving it can't overstate privacy:
/// nothing may be reported inactive while it's in use, and nothing on a public
/// address may be reported as "your hardware" without saying so.
void main() {
  group('host classification', () {
    test('RFC1918, loopback, mDNS and tailnets are private', () {
      for (final host in [
        '192.168.1.10',
        '10.0.0.5',
        '172.16.4.2',
        '172.31.255.1',
        '127.0.0.1',
        'localhost',
        'homeassistant.local',
        'box.lan',
        'nas.internal',
        'horizon.tail1234.ts.net',
        '100.101.102.103',
      ]) {
        expect(SecurityAudit.isPrivateHost(host), isTrue, reason: host);
      }
    });

    test('public addresses are not private', () {
      for (final host in [
        'openrouter.ai',
        '8.8.8.8',
        'ollama.example.com',
        '172.32.0.1', // Just outside the 172.16/12 block.
        '192.169.1.1', // Just outside 192.168/16.
      ]) {
        expect(SecurityAudit.isPrivateHost(host), isFalse, reason: host);
      }
    });

    test('hosted services that share a self-hosted shape are third party', () {
      expect(SecurityAudit.trustForSelfHostable('ollama.com'),
          EgressTrust.thirdParty);
      expect(SecurityAudit.trustForSelfHostable('api.openai.com'),
          EgressTrust.thirdParty);
      expect(SecurityAudit.trustForSelfHostable('api.groq.com'),
          EgressTrust.thirdParty);
      expect(SecurityAudit.trustForSelfHostable('192.168.1.10'),
          EgressTrust.yourHardware);
    });

    test('a URL with no scheme still yields a host', () {
      expect(SecurityAudit.hostOf('homeassistant.local:8123'),
          'homeassistant.local');
      expect(SecurityAudit.hostOf(''), isNull);
      expect(SecurityAudit.hostOf('   '), isNull);
    });
  });

  group('Ollama', () {
    test('a LAN server is your hardware with no warning', () {
      final entry = entryNamed(
        SecurityAudit.build(inputs()),
        'Ollama server',
      );
      expect(entry.trust, EgressTrust.yourHardware);
      expect(entry.status, EgressStatus.active);
      expect(entry.note, isNull);
    });

    test('a public address says traffic leaves the network', () {
      final entry = entryNamed(
        SecurityAudit.build(
          inputs(ollamaAddress: 'https://ollama.example.com'),
        ),
        'Ollama server',
      );
      expect(entry.trust, EgressTrust.yourHardware);
      expect(entry.note, contains('leave your network'));
    });

    test('Ollama Cloud is reported as a third party, not your hardware', () {
      final entry = entryNamed(
        SecurityAudit.build(inputs(ollamaAddress: 'https://ollama.com')),
        'Ollama server',
      );
      expect(entry.trust, EgressTrust.thirdParty);
    });

    test('Cloudflare Access is disclosed', () {
      final entry = entryNamed(
        SecurityAudit.build(inputs(ollamaHasCloudflareAccess: true)),
        'Ollama server',
      );
      expect(entry.note, contains('Cloudflare'));
    });

    test('no server configured means the path sends nothing', () {
      final entry = entryNamed(
        SecurityAudit.build(inputs(ollamaAddress: '')),
        'Ollama server',
      );
      expect(entry.status, EgressStatus.unconfigured);
    });

    test('the backup server is listed only when one exists', () {
      expect(
        SecurityAudit.build(inputs()).any((e) => e.name.contains('backup')),
        isFalse,
      );
      final withBackup = SecurityAudit.build(
        inputs(ollamaBackupAddress: 'http://10.0.0.9:11434'),
      );
      expect(entryNamed(withBackup, 'Ollama backup server').status,
          EgressStatus.inactive);
    });
  });

  group('OpenRouter', () {
    test('is inactive without a key and active with one', () {
      expect(
        entryNamed(SecurityAudit.build(inputs()), 'OpenRouter').status,
        EgressStatus.unconfigured,
      );
      expect(
        entryNamed(
          SecurityAudit.build(
            inputs(openRouterEnabled: true, openRouterHasKey: true),
          ),
          'OpenRouter',
        ).status,
        EgressStatus.active,
      );
    });

    test('a key with the provider switched off is not active', () {
      expect(
        entryNamed(
          SecurityAudit.build(inputs(openRouterHasKey: true)),
          'OpenRouter',
        ).status,
        EgressStatus.inactive,
      );
    });

    test('discloses that OpenRouter forwards to the model vendor', () {
      final entry = entryNamed(SecurityAudit.build(inputs()), 'OpenRouter');
      expect(entry.note, contains('forwards'));
      expect(entry.trust, EgressTrust.thirdParty);
    });
  });

  group('voice', () {
    test('ElevenLabs names transcription and speech separately', () {
      final stt = entryNamed(
        SecurityAudit.build(inputs(sttBackend: 'elevenlabs')),
        'ElevenLabs',
      );
      expect(stt.status, EgressStatus.active);
      expect(stt.sends, contains('recordings'));

      final tts = entryNamed(
        SecurityAudit.build(inputs(ttsEngine: 'elevenlabs')),
        'ElevenLabs',
      );
      expect(tts.sends, contains('spoken aloud'));
      expect(tts.sends, isNot(contains('recordings')));
    });

    test('a public Whisper server warns that audio leaves the network', () {
      final entry = entryNamed(
        SecurityAudit.build(
          inputs(sttBackend: 'whisper', whisperUrl: 'https://stt.example.com'),
        ),
        'Whisper transcription server',
      );
      expect(entry.status, EgressStatus.active);
      expect(entry.note, contains('audio leaves your network'));
    });

    test('a Whisper URL pointed at OpenAI is a third party', () {
      final entry = entryNamed(
        SecurityAudit.build(
          inputs(sttBackend: 'whisper', whisperUrl: 'https://api.openai.com'),
        ),
        'Whisper transcription server',
      );
      expect(entry.trust, EgressTrust.thirdParty);
    });
  });

  group('shared conversations', () {
    test('says nothing is shared when nothing is', () {
      final entry = entryNamed(
        SecurityAudit.build(inputs()),
        'Shared conversations',
      );
      expect(entry.status, EgressStatus.unconfigured);
      expect(entry.sends, contains('No chat is shared'));
    });

    test('counts them, split by where they run', () {
      final entry = entryNamed(
        SecurityAudit.build(
          inputs(sharedChatCount: 3, sharedCloudChatCount: 1),
        ),
        'Shared conversations',
      );
      expect(entry.status, EgressStatus.active);
      expect(entry.sends, contains('3 chats'));
      expect(entry.sends, contains('2 on a local model'));
      expect(entry.sends, contains('1 on a hosted one'));
    });

    test('states the rule that keeps local chats off the wire', () {
      final entry = entryNamed(
        SecurityAudit.build(inputs(sharedChatCount: 2)),
        'Shared conversations',
      );
      expect(entry.note, contains('can only search other hosted chats'));
    });
  });

  group('the honest bits', () {
    test('the plaintext config backup is called out', () {
      final entry = entryNamed(
        SecurityAudit.build(inputs()),
        'API keys and tokens',
      );
      expect(entry.note, contains('PLAINTEXT'));
    });

    test('device speech recognition does not overclaim', () {
      final entry = entryNamed(
        SecurityAudit.build(inputs()),
        'Device speech recognition',
      );
      // On Android the OS ships the audio to Google; the page has to say so
      // even though the trust level is "on device" from Horizon's side.
      expect(entry.trust, EgressTrust.onDevice);
      expect(entry.note, isNotNull);
    });

    test('a default install has no active third party', () {
      final active = SecurityAudit.build(inputs())
          .where((e) => e.trust == EgressTrust.thirdParty && e.isActive)
          .map((e) => e.name)
          .toList();
      // Except the one that is unavoidable: fetching a page the model was
      // given hits that site directly.
      expect(active, ['Web pages the model reads']);
    });
  });
}
