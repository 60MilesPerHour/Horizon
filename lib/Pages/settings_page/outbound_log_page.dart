import 'package:flutter/material.dart';

import 'package:horizon/Services/outbound_log.dart';
import 'package:horizon/Utils/horizon_http.dart';
import 'package:horizon/Widgets/frosted_surface.dart';

/// Every HTTP request Horizon has made this session.
///
/// The companion to the destinations list: that page says what the current
/// configuration *would* send, this one says what actually went out. A
/// destinations page derived from app state agrees with a bug that sends
/// something else; a transport log doesn't.
///
/// What it deliberately does not hold: request bodies, response bodies, and
/// header values. Sizes and the names of credential headers are enough to
/// spot "why did that go there", and a log with bodies in it would be a
/// second copy of every conversation — the exact thing the privacy page warns
/// about elsewhere.
class OutboundLogPage extends StatefulWidget {
  const OutboundLogPage({super.key});

  @override
  State<OutboundLogPage> createState() => _OutboundLogPageState();
}

class _OutboundLogPageState extends State<OutboundLogPage> {
  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final log = HorizonHttp.log;
    final entries = log.entries;
    final hosts = log.hostCounts;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Outbound requests'),
        flexibleSpace: const FrostedSurface(),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            tooltip: 'Refresh',
            onPressed: () => setState(() {}),
          ),
          IconButton(
            icon: const Icon(Icons.delete_outline),
            tooltip: 'Clear',
            onPressed: () => setState(log.clear),
          ),
        ],
      ),
      body: entries.isEmpty
          ? Center(
              child: Padding(
                padding: const EdgeInsets.all(32),
                child: Text(
                  'Nothing has been sent yet this session.',
                  textAlign: TextAlign.center,
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ),
            )
          : ListView(
              physics: const BouncingScrollPhysics(),
              padding: const EdgeInsets.all(16),
              children: [
                Card(
                  margin: EdgeInsets.zero,
                  child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          '${entries.length} request'
                          '${entries.length == 1 ? '' : 's'} to '
                          '${hosts.length} host${hosts.length == 1 ? '' : 's'}',
                          style: theme.textTheme.titleMedium?.copyWith(
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                        const SizedBox(height: 6),
                        for (final host in (hosts.keys.toList()
                          ..sort((a, b) => hosts[b]!.compareTo(hosts[a]!))))
                          Text(
                            '${hosts[host]} × $host',
                            style: theme.textTheme.bodySmall,
                          ),
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: 12),
                Text(
                  'This session only, held in memory, capped at '
                  '${log.capacity} requests and never written to disk. '
                  'Bodies and header values are not recorded.',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
                const SizedBox(height: 12),
                for (final entry in entries) _RequestTile(entry: entry),
                const SizedBox(height: 32),
              ],
            ),
    );
  }
}

class _RequestTile extends StatelessWidget {
  const _RequestTile({required this.entry});

  final OutboundRequest entry;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colour = entry.isFailure
        ? theme.colorScheme.error
        : theme.colorScheme.onSurfaceVariant;

    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Text(
                  entry.method,
                  style: theme.textTheme.labelMedium?.copyWith(
                    fontWeight: FontWeight.bold,
                    fontFamily: 'monospace',
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    entry.host,
                    style: theme.textTheme.titleSmall,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                Text(
                  entry.error != null
                      ? 'failed'
                      : (entry.statusCode?.toString() ?? '…'),
                  style: theme.textTheme.labelMedium?.copyWith(color: colour),
                ),
              ],
            ),
            const SizedBox(height: 2),
            Text(
              entry.path,
              style: theme.textTheme.bodySmall?.copyWith(
                fontFamily: 'monospace',
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 4),
            Text(
              [
                _time(entry.startedAt),
                if (entry.requestBytes > 0) '↑ ${_size(entry.requestBytes)}',
                if (entry.responseBytes > 0) '↓ ${_size(entry.responseBytes)}',
                if (entry.duration != null) '${entry.duration!.inMilliseconds} ms',
                if (entry.hasCredential)
                  'auth: ${entry.authHeaders.join(', ')}',
              ].join('  ·  '),
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
            if (entry.error != null) ...[
              const SizedBox(height: 4),
              Text(
                entry.error!,
                style: theme.textTheme.bodySmall
                    ?.copyWith(color: theme.colorScheme.error),
              ),
            ],
          ],
        ),
      ),
    );
  }

  static String _time(DateTime when) =>
      '${when.hour.toString().padLeft(2, '0')}:'
      '${when.minute.toString().padLeft(2, '0')}:'
      '${when.second.toString().padLeft(2, '0')}';

  /// Streamed responses report no content length, so a 0 here means "unknown"
  /// rather than "empty" — which is why zero sizes are omitted entirely
  /// rather than printed as 0 B.
  static String _size(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} kB';
    return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
  }
}
