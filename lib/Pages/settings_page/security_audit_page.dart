import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:provider/provider.dart';

import 'package:horizon/Services/chat_history_search.dart';
import 'package:horizon/Services/home_assistant_service.dart';
import 'package:horizon/Pages/settings_page/outbound_log_page.dart';
import 'package:horizon/Services/openrouter_service.dart';
import 'package:horizon/Services/security_audit.dart';
import 'package:horizon/Services/web_search_service.dart';
import 'package:horizon/Widgets/frosted_surface.dart';

/// "What goes where": every destination Horizon can send data to, read from
/// the live configuration.
///
/// Read rather than written: a privacy page maintained by hand is a promise,
/// and this is a measurement. Each row says what actually leaves, for whom,
/// whether that is happening right now, and where the credential lives — and
/// it is deliberately blunt about the two places where "on device" is weaker
/// than it sounds (the platform speech recogniser, and the plaintext config
/// backup).
class SecurityAuditPage extends StatefulWidget {
  const SecurityAuditPage({super.key});

  @override
  State<SecurityAuditPage> createState() => _SecurityAuditPageState();
}

class _SecurityAuditPageState extends State<SecurityAuditPage> {
  static const _storage = FlutterSecureStorage();

  List<EgressEntry>? _entries;

  @override
  void initState() {
    super.initState();
    _load();
  }

  /// Key *presence* only — the values are never read into the page, so a
  /// screenshot of this screen can't leak one.
  Future<bool> _hasSecret(String key) async {
    try {
      final value = await _storage.read(key: key);
      return value != null && value.isNotEmpty;
    } catch (_) {
      return false;
    }
  }

  Future<void> _load() async {
    final box = Hive.box('settings');
    final openRouter = context.read<OpenRouterService>();
    final webSearch = context.read<WebSearchService>();
    final homeAssistant = context.read<HomeAssistantService>();
    final chatSearch = context.read<ChatHistorySearch>();

    final entries = SecurityAudit.build(SecurityAuditInputs(
      ollamaAddress: (box.get('serverAddress') as String?) ?? '',
      ollamaBackupAddress: (box.get('serverAddressBackup') as String?) ?? '',
      ollamaUsingBackup: box.get('serverUseBackup', defaultValue: false) as bool,
      ollamaHasToken: await _hasSecret('ollama_api_token'),
      ollamaHasCloudflareAccess: await _hasSecret('cf_access_client_id'),
      openRouterEnabled: openRouter.enabled,
      openRouterHasKey: await _hasSecret('openrouter_api_key'),
      webSearchBackend: webSearch.backend.name,
      serpApiConfigured: await _hasSecret('serpapi_api_key'),
      searxngUrl: webSearch.searxngUrl,
      sttBackend: (box.get('stt_backend') as String?) ?? 'device',
      whisperUrl: (box.get('whisper_base_url') as String?) ?? '',
      elevenLabsConfigured: await _hasSecret('elevenlabs_api_key'),
      ttsEngine: (box.get('voice_engine') as String?) ?? 'system',
      ttsUrl: (box.get('tts_base_url') as String?) ?? '',
      homeAssistantUrl: homeAssistant.baseUrl,
      homeAssistantConfigured: homeAssistant.isConfigured,
      sharedChatCount: chatSearch.bridgedChats.length,
      sharedCloudChatCount: chatSearch.bridgedChats
          .where((chat) => !ChatHistorySearch.isLocalProvider(chat.provider))
          .length,
    ));

    if (mounted) setState(() => _entries = entries);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final entries = _entries;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Security & Privacy'),
        flexibleSpace: const FrostedSurface(),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            tooltip: 'Re-read configuration',
            onPressed: _load,
          ),
        ],
      ),
      body: entries == null
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              physics: const BouncingScrollPhysics(),
              padding: const EdgeInsets.all(16),
              children: [
                _Summary(entries: entries),
                const SizedBox(height: 8),
                // The list below is what the configuration says. This is what
                // actually went over the wire — the two disagreeing is the
                // most useful thing this page could ever show anyone.
                Card(
                  margin: EdgeInsets.zero,
                  child: ListTile(
                    leading: const Icon(Icons.receipt_long_outlined),
                    title: const Text('Outbound requests'),
                    subtitle: Text(
                      'Every request made this session, recorded at the '
                      'transport rather than inferred from settings',
                      style: theme.textTheme.bodySmall,
                    ),
                    trailing: const Icon(Icons.chevron_right),
                    onTap: () => Navigator.of(context).push(
                      MaterialPageRoute(
                        builder: (_) => const OutboundLogPage(),
                      ),
                    ),
                  ),
                ),
                const SizedBox(height: 16),
                for (final trust in EgressTrust.values)
                  ..._section(context, trust, entries),
                const SizedBox(height: 24),
                Text(
                  'Read from your current settings each time this page opens. '
                  'Nothing here is a claim about what a destination does with '
                  'what it receives — only about what Horizon sends it.',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
                const SizedBox(height: 32),
              ],
            ),
    );
  }

  List<Widget> _section(
    BuildContext context,
    EgressTrust trust,
    List<EgressEntry> entries,
  ) {
    final theme = Theme.of(context);
    final matching = entries.where((e) => e.trust == trust).toList();
    if (matching.isEmpty) return const [];

    return [
      Padding(
        padding: const EdgeInsets.only(top: 8, bottom: 8),
        child: Row(
          children: [
            Icon(_iconFor(trust), size: 18, color: _colourFor(context, trust)),
            const SizedBox(width: 8),
            Text(
              trust.label,
              style: theme.textTheme.titleMedium
                  ?.copyWith(fontWeight: FontWeight.bold),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                trust.description,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ),
          ],
        ),
      ),
      for (final entry in matching) _EntryCard(entry: entry),
      const SizedBox(height: 8),
    ];
  }

  static IconData _iconFor(EgressTrust trust) {
    switch (trust) {
      case EgressTrust.onDevice:
        return Icons.phone_android;
      case EgressTrust.yourHardware:
        return Icons.dns_outlined;
      case EgressTrust.thirdParty:
        return Icons.cloud_outlined;
    }
  }

  static Color _colourFor(BuildContext context, EgressTrust trust) {
    final scheme = Theme.of(context).colorScheme;
    switch (trust) {
      case EgressTrust.onDevice:
        return scheme.primary;
      case EgressTrust.yourHardware:
        return scheme.tertiary;
      case EgressTrust.thirdParty:
        return scheme.error;
    }
  }
}

/// The one-line answer: how many outside parties are live right now.
class _Summary extends StatelessWidget {
  const _Summary({required this.entries});

  final List<EgressEntry> entries;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final thirdParty = entries
        .where((e) => e.trust == EgressTrust.thirdParty && e.isActive)
        .toList();
    final yourHardware = entries
        .where((e) => e.trust == EgressTrust.yourHardware && e.isActive)
        .toList();

    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              thirdParty.isEmpty
                  ? 'Nothing is being sent to a third party'
                  : '${thirdParty.length} third-party '
                      'destination${thirdParty.length == 1 ? '' : 's'} active',
              style: theme.textTheme.titleMedium?.copyWith(
                fontWeight: FontWeight.bold,
                color: thirdParty.isEmpty
                    ? theme.colorScheme.primary
                    : theme.colorScheme.error,
              ),
            ),
            const SizedBox(height: 4),
            Text(
              thirdParty.isEmpty
                  ? 'Every active path is either on this device or a server '
                      'you run.'
                  : thirdParty.map((e) => e.name).join(', '),
              style: theme.textTheme.bodyMedium,
            ),
            if (yourHardware.isNotEmpty) ...[
              const SizedBox(height: 8),
              Text(
                'On your own hardware: '
                '${yourHardware.map((e) => e.name).join(', ')}',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _EntryCard extends StatelessWidget {
  const _EntryCard({required this.entry});

  final EgressEntry entry;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    // An inactive path is still worth listing — it's what would happen if the
    // switch were flipped — but it shouldn't compete with what's live.
    final dimmed = !entry.isActive;

    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    entry.name,
                    style: theme.textTheme.titleSmall?.copyWith(
                      fontWeight: FontWeight.bold,
                      color: dimmed ? theme.colorScheme.onSurfaceVariant : null,
                    ),
                  ),
                ),
                _StatusChip(status: entry.status),
              ],
            ),
            if (entry.host != null) ...[
              const SizedBox(height: 2),
              Text(
                entry.host!,
                style: theme.textTheme.bodySmall?.copyWith(
                  fontFamily: 'monospace',
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ],
            const SizedBox(height: 6),
            Text(entry.sends, style: theme.textTheme.bodySmall),
            if (entry.credential != null) ...[
              const SizedBox(height: 6),
              Row(
                children: [
                  Icon(Icons.key_outlined,
                      size: 14, color: theme.colorScheme.onSurfaceVariant),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      entry.credential!,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ),
                ],
              ),
            ],
            if (entry.note != null) ...[
              const SizedBox(height: 6),
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Icon(Icons.info_outline,
                      size: 14, color: theme.colorScheme.tertiary),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      entry.note!,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.tertiary,
                      ),
                    ),
                  ),
                ],
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _StatusChip extends StatelessWidget {
  const _StatusChip({required this.status});

  final EgressStatus status;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final (background, foreground) = switch (status) {
      EgressStatus.active => (scheme.primaryContainer, scheme.onPrimaryContainer),
      EgressStatus.inactive => (scheme.surfaceContainerHighest, scheme.onSurfaceVariant),
      EgressStatus.unconfigured => (scheme.surfaceContainerHigh, scheme.onSurfaceVariant),
    };

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(
        color: background,
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(
        status.label,
        style: Theme.of(context)
            .textTheme
            .labelSmall
            ?.copyWith(color: foreground),
      ),
    );
  }
}
