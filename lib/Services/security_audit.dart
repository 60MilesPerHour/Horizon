import 'dart:io' show Platform;

/// Where a destination sits relative to hardware the user controls.
enum EgressTrust {
  /// Never leaves the device.
  onDevice('On device', 'Stays on this device'),

  /// A machine the user runs, reached over their own network.
  yourHardware('Your hardware', 'A server you run'),

  /// Someone else's server.
  thirdParty('Third party', "Someone else's servers");

  const EgressTrust(this.label, this.description);

  final String label;
  final String description;
}

enum EgressStatus {
  /// Configured and in use right now.
  active('Active'),

  /// Set up but switched off, or not the selected backend.
  inactive('Configured, not in use'),

  /// Nothing configured — this path sends nothing.
  unconfigured('Not configured');

  const EgressStatus(this.label);

  final String label;
}

/// One destination data can leave for, or one place it is kept.
class EgressEntry {
  const EgressEntry({
    required this.name,
    required this.trust,
    required this.status,
    required this.sends,
    this.host,
    this.credential,
    this.note,
  });

  /// What the destination is called.
  final String name;

  final EgressTrust trust;
  final EgressStatus status;

  /// Plain-language list of what actually goes there.
  final String sends;

  /// The configured host, when there is one. Shown so it can be checked
  /// against what the user thinks it is.
  final String? host;

  /// Where the credential for it is stored.
  final String? credential;

  /// Anything that changes how the line should be read.
  final String? note;

  bool get isActive => status == EgressStatus.active;
}

/// Everything the audit needs, as plain values rather than services, so the
/// classification can be tested without constructing half the app.
class SecurityAuditInputs {
  const SecurityAuditInputs({
    required this.ollamaAddress,
    required this.ollamaBackupAddress,
    required this.ollamaUsingBackup,
    required this.ollamaHasToken,
    required this.ollamaHasCloudflareAccess,
    required this.openRouterEnabled,
    required this.openRouterHasKey,
    required this.webSearchBackend,
    required this.serpApiConfigured,
    required this.searxngUrl,
    required this.sttBackend,
    required this.whisperUrl,
    required this.elevenLabsConfigured,
    required this.ttsEngine,
    required this.ttsUrl,
    required this.homeAssistantUrl,
    required this.homeAssistantConfigured,
    required this.sharedChatCount,
    required this.sharedCloudChatCount,
  });

  final String ollamaAddress;
  final String ollamaBackupAddress;
  final bool ollamaUsingBackup;
  final bool ollamaHasToken;
  final bool ollamaHasCloudflareAccess;

  final bool openRouterEnabled;
  final bool openRouterHasKey;

  /// 'off', 'serpapi' or 'searxng'.
  final String webSearchBackend;
  final bool serpApiConfigured;
  final String searxngUrl;

  /// 'device', 'whisper' or 'elevenlabs'.
  final String sttBackend;
  final String whisperUrl;
  final bool elevenLabsConfigured;

  /// 'system', 'selfhosted' or 'elevenlabs'.
  final String ttsEngine;
  final String ttsUrl;

  final String homeAssistantUrl;
  final bool homeAssistantConfigured;

  /// How many chats are opted in to `search_chats`.
  final int sharedChatCount;

  /// How many of those run on a hosted model, and are therefore the only ones
  /// a hosted chat is allowed to search.
  final int sharedCloudChatCount;
}

/// Builds the "what goes where" list for the Security & Privacy page.
///
/// Derived from live configuration rather than written by hand, because a
/// hand-written privacy page is a claim and this is a reading. Every remote
/// destination the app can reach appears exactly once, and each says what
/// leaves for it and whether that is happening now.
class SecurityAudit {
  const SecurityAudit._();

  /// Hosts that are unambiguously on the user's own network, so a server there
  /// can be called "your hardware" without qualification.
  ///
  /// Everything else typed by the user is reported as "your hardware, reached
  /// over the internet" rather than assumed private — a hostname alone can't
  /// tell us whether it resolves inside the LAN, and quietly guessing "local"
  /// on a page whose whole job is honesty would be the one unacceptable bug.
  static bool isPrivateHost(String host) {
    final h = host.toLowerCase().trim();
    if (h.isEmpty) return false;
    if (h == 'localhost' || h == '127.0.0.1' || h == '::1') return true;
    if (h.endsWith('.local') || h.endsWith('.lan') || h.endsWith('.home') ||
        h.endsWith('.internal')) {
      return true;
    }
    // Tailscale / Headscale tailnets.
    if (h.endsWith('.ts.net')) return true;

    final octets = h.split('.');
    if (octets.length == 4 && octets.every((o) => int.tryParse(o) != null)) {
      final a = int.parse(octets[0]);
      final b = int.parse(octets[1]);
      if (a == 10 || a == 127) return true;
      if (a == 192 && b == 168) return true;
      if (a == 172 && b >= 16 && b <= 31) return true;
      // Tailscale's CGNAT range.
      if (a == 100 && b >= 64 && b <= 127) return true;
      if (a == 169 && b == 254) return true;
    }
    return false;
  }

  static String? hostOf(String url) {
    var raw = url.trim();
    if (raw.isEmpty) return null;
    if (!raw.startsWith('http://') && !raw.startsWith('https://')) {
      raw = 'http://$raw';
    }
    final host = Uri.tryParse(raw)?.host;
    return (host == null || host.isEmpty) ? null : host;
  }

  /// Ollama and the other self-hostable endpoints: the user's own server if
  /// the host is private, their own server over the internet otherwise — and
  /// genuinely third-party for the hosted services that share the endpoint
  /// shape (Ollama Cloud, OpenAI, Groq).
  static EgressTrust trustForSelfHostable(String? host) {
    if (host == null) return EgressTrust.yourHardware;
    const hostedServices = [
      'ollama.com',
      'api.openai.com',
      'api.groq.com',
      'openai.azure.com',
    ];
    if (hostedServices.any((h) => host == h || host.endsWith('.$h'))) {
      return EgressTrust.thirdParty;
    }
    return EgressTrust.yourHardware;
  }

  static List<EgressEntry> build(SecurityAuditInputs input) {
    final entries = <EgressEntry>[];

    // ---------------- On device ----------------
    entries.add(const EgressEntry(
      name: 'Chats, messages and attachments',
      trust: EgressTrust.onDevice,
      status: EgressStatus.active,
      sends: 'Every message, image and document you attach is stored in a '
          'SQLite database in the app\'s own directory. Nothing syncs it '
          'anywhere.',
      note: 'Deleting a chat deletes its files from disk too.',
    ));

    entries.add(const EgressEntry(
      name: 'API keys and tokens',
      trust: EgressTrust.onDevice,
      status: EgressStatus.active,
      sends: 'Held in the operating system keystore, not in app settings.',
      note: 'Backup & Restore exports them to a file in PLAINTEXT, by design '
          're-entering them is the point. Treat that file as a secret.',
    ));

    // ---------------- Ollama ----------------
    final ollamaHost = hostOf(input.ollamaAddress);
    final ollamaConfigured = ollamaHost != null;
    entries.add(EgressEntry(
      name: 'Ollama server',
      host: ollamaHost,
      trust: trustForSelfHostable(ollamaHost),
      status: ollamaConfigured ? EgressStatus.active : EgressStatus.unconfigured,
      sends: 'The full conversation — system prompt, every message, images, '
          'and extracted attachment text — for any chat using a local model.',
      credential: input.ollamaHasToken ? 'Bearer token in the keystore' : null,
      note: [
        if (ollamaHost != null && !isPrivateHost(ollamaHost))
          'This address is not a private one, so requests leave your network '
              'to reach it.',
        if (input.ollamaHasCloudflareAccess)
          'Cloudflare Access headers are attached, so requests pass through '
              'Cloudflare.',
      ].join(' ').trimOrNull(),
    ));

    final backupHost = hostOf(input.ollamaBackupAddress);
    if (backupHost != null) {
      entries.add(EgressEntry(
        name: 'Ollama backup server',
        host: backupHost,
        trust: trustForSelfHostable(backupHost),
        status: input.ollamaUsingBackup
            ? EgressStatus.active
            : EgressStatus.inactive,
        sends: 'The same as the primary, whenever the primary is unreachable.',
        note: isPrivateHost(backupHost)
            ? null
            : 'Not a private address — traffic to it leaves your network.',
      ));
    }

    // ---------------- OpenRouter ----------------
    entries.add(EgressEntry(
      name: 'OpenRouter',
      host: 'openrouter.ai',
      trust: EgressTrust.thirdParty,
      status: input.openRouterEnabled && input.openRouterHasKey
          ? EgressStatus.active
          : (input.openRouterHasKey
              ? EgressStatus.inactive
              : EgressStatus.unconfigured),
      sends: 'The full conversation for any chat using a hosted model, '
          'including images and attachment text.',
      credential: input.openRouterHasKey ? 'API key in the keystore' : null,
      note: 'OpenRouter forwards each request to whoever serves the model you '
          'picked — Anthropic, OpenAI, Google, Meta, and so on — so that '
          "company sees the conversation too, under OpenRouter's terms with "
          'them, not yours.',
    ));

    // ---------------- Web search ----------------
    entries.add(EgressEntry(
      name: 'SerpAPI',
      host: 'serpapi.com',
      trust: EgressTrust.thirdParty,
      status: input.webSearchBackend == 'serpapi' && input.serpApiConfigured
          ? EgressStatus.active
          : (input.serpApiConfigured
              ? EgressStatus.inactive
              : EgressStatus.unconfigured),
      sends: 'Search queries only — written by the model, not your message '
          'verbatim, though it usually contains your words.',
      credential: input.serpApiConfigured ? 'API key in the keystore' : null,
    ));

    final searxngHost = hostOf(input.searxngUrl);
    if (searxngHost != null) {
      entries.add(EgressEntry(
        name: 'SearXNG',
        host: searxngHost,
        trust: EgressTrust.yourHardware,
        status: input.webSearchBackend == 'searxng'
            ? EgressStatus.active
            : EgressStatus.inactive,
        sends: 'Search queries. Your instance then queries the upstream '
            'engines it is configured for.',
        note: isPrivateHost(searxngHost)
            ? null
            : 'Not a private address — queries leave your network to reach it.',
      ));
    }

    entries.add(const EgressEntry(
      name: 'Web pages the model reads',
      trust: EgressTrust.thirdParty,
      status: EgressStatus.active,
      sends: 'A plain GET to whatever URL the model fetches, from your IP '
          'address. No message content is sent — but the site sees the '
          'request.',
      note: 'Only ever a URL that came from a search result or from you.',
    ));

    // ---------------- Speech in ----------------
    entries.add(EgressEntry(
      name: 'Device speech recognition',
      trust: EgressTrust.onDevice,
      status:
          input.sttBackend == 'device' ? EgressStatus.active : EgressStatus.inactive,
      sends: 'Your voice, to the platform recogniser.',
      note: Platform.isAndroid
          ? 'On Android this is Google\'s recogniser: unless an offline '
              'language pack is installed, the audio goes to Google. "On '
              'device" here means Horizon does not send it anywhere — the OS '
              'may.'
          : 'Handled by the operating system. Horizon never uploads the audio '
              'itself.',
    ));

    final whisperHost = hostOf(input.whisperUrl);
    if (whisperHost != null) {
      entries.add(EgressEntry(
        name: 'Whisper transcription server',
        host: whisperHost,
        trust: trustForSelfHostable(whisperHost),
        status: input.sttBackend == 'whisper'
            ? EgressStatus.active
            : EgressStatus.inactive,
        sends: 'A recording of everything you say in voice mode, as a WAV '
            'upload.',
        note: isPrivateHost(whisperHost)
            ? null
            : 'Not a private address — your recorded audio leaves your '
                'network to reach it.',
      ));
    }

    entries.add(EgressEntry(
      name: 'ElevenLabs',
      host: 'api.elevenlabs.io',
      trust: EgressTrust.thirdParty,
      status: (input.sttBackend == 'elevenlabs' ||
              input.ttsEngine == 'elevenlabs')
          ? EgressStatus.active
          : (input.elevenLabsConfigured
              ? EgressStatus.inactive
              : EgressStatus.unconfigured),
      sends: [
        if (input.sttBackend == 'elevenlabs')
          'recordings of what you say (transcription)',
        if (input.ttsEngine == 'elevenlabs')
          'the text of every reply that gets spoken aloud',
        if (input.sttBackend != 'elevenlabs' &&
            input.ttsEngine != 'elevenlabs')
          'nothing while neither transcription nor speech is set to it',
      ].join(', and '),
      credential: input.elevenLabsConfigured ? 'API key in the keystore' : null,
    ));

    // ---------------- Speech out ----------------
    entries.add(EgressEntry(
      name: 'Device text-to-speech',
      trust: EgressTrust.onDevice,
      status:
          input.ttsEngine == 'system' ? EgressStatus.active : EgressStatus.inactive,
      sends: 'Reply text, to the platform voice.',
      note: 'Some platform voices are cloud-backed; that is the OS\'s choice, '
          'not Horizon\'s.',
    ));

    final ttsHost = hostOf(input.ttsUrl);
    if (ttsHost != null) {
      entries.add(EgressEntry(
        name: 'Self-hosted speech server',
        host: ttsHost,
        trust: trustForSelfHostable(ttsHost),
        status: input.ttsEngine == 'selfhosted'
            ? EgressStatus.active
            : EgressStatus.inactive,
        sends: 'The text of every reply that gets spoken aloud.',
        note: isPrivateHost(ttsHost)
            ? null
            : 'Not a private address — reply text leaves your network to '
                'reach it.',
      ));
    }

    // ---------------- Home ----------------
    final haHost = hostOf(input.homeAssistantUrl);
    entries.add(EgressEntry(
      name: 'Home Assistant',
      host: haHost,
      trust: EgressTrust.yourHardware,
      status: input.homeAssistantConfigured
          ? EgressStatus.active
          : EgressStatus.unconfigured,
      sends: 'Entity queries and service calls. Entity names and states come '
          'back into the conversation, which means they are then sent to '
          'whichever model is answering.',
      credential: input.homeAssistantConfigured
          ? 'Long-lived token in the keystore'
          : null,
      note: haHost != null && !isPrivateHost(haHost)
          ? 'Not a private address — requests leave your network to reach it.'
          : null,
    ));

    // ---------------- Cross-chat ----------------
    final localShared = input.sharedChatCount - input.sharedCloudChatCount;
    entries.add(EgressEntry(
      name: 'Shared conversations',
      trust: EgressTrust.onDevice,
      status: input.sharedChatCount > 0
          ? EgressStatus.active
          : EgressStatus.unconfigured,
      sends: input.sharedChatCount == 0
          ? 'No chat is shared, so search_chats is not offered to any model.'
          : '${input.sharedChatCount} chat'
              '${input.sharedChatCount == 1 ? '' : 's'} can be searched by the '
              'assistant: $localShared on a local model, '
              '${input.sharedCloudChatCount} on a hosted one. The search runs '
              'locally, but an excerpt it returns becomes part of the request '
              "to that chat's model.",
      note: input.sharedCloudChatCount > 0 || localShared > 0
          ? 'A chat on a hosted model can only search other hosted chats — '
              'your local conversations are never excerpted into a request '
              'that leaves the device. Set per chat, in Configure Chat → '
              'Share with assistant.'
          : 'Per chat, in Configure Chat → Share with assistant.',
    ));

    return entries;
  }
}

extension on String {
  String? trimOrNull() {
    final t = trim();
    return t.isEmpty ? null : t;
  }
}
