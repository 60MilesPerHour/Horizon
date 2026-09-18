import 'package:flutter/material.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:share_plus/share_plus.dart';
import 'package:url_launcher/url_launcher_string.dart';

import 'package:horizon/Constants/app_constants.dart';
import 'package:horizon/Widgets/flexible_text.dart';

/// About page.
///
/// Every outbound link here used to point at upstream Reins — its repo, its
/// website, and its App Store id behind the review prompt — because the page
/// was inherited wholesale and only the visible strings were renamed. They now
/// point at Horizon, with upstream credited explicitly instead of
/// accidentally: Horizon is a GPL-3.0 fork, so the attribution belongs on the
/// page, just not on the buttons that say "this project".
class HorizonSettings extends StatelessWidget {
  const HorizonSettings({super.key});

  static const String _repoUrl = 'https://github.com/60MilesPerHour/Horizon';
  static const String _releasesUrl = '$_repoUrl/releases';
  static const String _issuesUrl = '$_repoUrl/issues';
  static const String _upstreamUrl = 'https://github.com/ibrahimcetin/reins';

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          AppConstants.appName,
          style: theme.textTheme.titleLarge?.copyWith(
            fontWeight: FontWeight.bold,
          ),
        ),
        const _VersionTile(),
        const Divider(height: 24),
        ListTile(
          contentPadding: EdgeInsets.zero,
          leading: const Icon(Icons.code),
          title: const Text('Source code'),
          subtitle: const Text('60MilesPerHour/Horizon on GitHub'),
          onTap: () => launchUrlString(_repoUrl),
        ),
        ListTile(
          contentPadding: EdgeInsets.zero,
          leading: const Icon(Icons.bug_report_outlined),
          title: const Text('Report a problem'),
          subtitle: const Text('Open an issue'),
          onTap: () => launchUrlString(_issuesUrl),
        ),
        ListTile(
          contentPadding: EdgeInsets.zero,
          leading: const Icon(Icons.download_outlined),
          title: const Text('Other platforms'),
          subtitle: const Text(
            'Android, macOS, Windows, Debian/Ubuntu, and Linux tarball',
          ),
          onTap: () => launchUrlString(_releasesUrl),
        ),
        Builder(
          builder: (builderContext) => ListTile(
            contentPadding: EdgeInsets.zero,
            leading: const Icon(Icons.share),
            title: const Text('Share Horizon'),
            subtitle: const Text('Send someone the download link'),
            onTap: () => _openShareSheet(builderContext),
          ),
        ),
        const Divider(height: 24),
        ListTile(
          contentPadding: EdgeInsets.zero,
          leading: const Icon(Icons.balance_outlined),
          title: const Text('Licence'),
          subtitle: const Text('GNU General Public License v3.0'),
          onTap: () => launchUrlString('$_repoUrl/blob/main/LICENSE'),
        ),
        ListTile(
          contentPadding: EdgeInsets.zero,
          leading: const Icon(Icons.call_split),
          title: const Text('Based on Reins'),
          subtitle: const Text(
            'Horizon is a GPL-3.0 fork of Reins by Ibrahim Çetin',
          ),
          onTap: () => launchUrlString(_upstreamUrl),
        ),
        const SizedBox(height: 16),
        const Row(
          mainAxisAlignment: MainAxisAlignment.center,
          spacing: 5,
          children: [
            Icon(Icons.favorite, color: Colors.red, size: 16),
            FlexibleText(
              'Thanks for using Horizon!',
              textAlign: TextAlign.center,
            ),
          ],
        ),
      ],
    );
  }

  void _openShareSheet(BuildContext context) {
    final box = context.findRenderObject() as RenderBox?;
    if (box != null) {
      SharePlus.instance.share(
        ShareParams(
          text: 'Check out Horizon: $_repoUrl',
          sharePositionOrigin: box.localToGlobal(Offset.zero) & box.size,
        ),
      );
    }
  }
}

/// Reads the version out of the bundle rather than a constant, so it can't
/// drift from what was actually shipped — the number in a bug report is only
/// useful if it's the real one.
class _VersionTile extends StatefulWidget {
  const _VersionTile();

  @override
  State<_VersionTile> createState() => _VersionTileState();
}

class _VersionTileState extends State<_VersionTile> {
  String? _version;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final info = await PackageInfo.fromPlatform();
      if (!mounted) return;
      setState(() => _version = 'Version ${info.version} (${info.buildNumber})');
    } catch (_) {
      // Not fatal — the rest of the page is still useful without it.
    }
  }

  @override
  Widget build(BuildContext context) {
    return Text(
      _version ?? 'Version —',
      style: Theme.of(context).textTheme.bodySmall,
    );
  }
}
