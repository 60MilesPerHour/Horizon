import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher_string.dart';

import 'package:horizon/Constants/app_constants.dart';

/// Where Horizon comes from.
///
/// Replaces a one-line "Based on Reins" tile. The credit isn't optional —
/// Horizon still carries Reins code, and GPL-3.0 wants its notices shown in
/// the app — but it can be said properly rather than left as a label. The
/// same note is ORIGINS.md in the repository; keep the two in step.
class OriginsPage extends StatelessWidget {
  const OriginsPage({super.key});

  static const String reinsUrl = 'https://github.com/ibrahimcetin/reins';
  static const String licenceUrl =
      'https://github.com/60MilesPerHour/Horizon/blob/main/LICENSE';

  static const List<String> _note = [
    'Horizon was born out of the love I held for its origin, Reins, '
        'developed by İbrahim Çetin. If it weren\'t for you, İbrahim, none '
        'of this would exist today.',
    'Horizon builds upon the legacy of Reins by introducing cloud '
        'models alongside local ones, tools that search and read the web, '
        'control of your home through Home Assistant, a voice you can '
        'simply talk to — one that listens for "Hey Horizon" — and a '
        'version that runs on the web.',
    'You can still see Reins throughout Horizon\'s evolution: in the '
        'way a conversation opens, the model picker that slides up from the'
        ' bottom, the settings each chat carries. Every version since has '
        'been built on the shape it gave me.',
    'Horizon is its own thing now, and it\'s mine. But it didn\'t start'
        ' from nothing, and I never want to pretend it did.',
    'Thank you, İbrahim, for building Reins, for releasing it in the '
        'open, and for inspiring me to build Horizon.',
  ];

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final body = theme.textTheme.bodyLarge?.copyWith(height: 1.6);
    return Scaffold(
      appBar: AppBar(title: const Text('Where Horizon comes from')),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(24, 8, 24, 32),
        children: [
          Center(
            child: Image.asset(AppConstants.appIconPng, height: 72),
          ),
          const SizedBox(height: 24),
          for (final (i, paragraph) in _note.indexed) ...[
            Text(paragraph, style: i == 0 ? body?.copyWith(fontWeight: FontWeight.w500) : body),
            const SizedBox(height: 16),
          ],
          Text('— Miles', style: body?.copyWith(fontStyle: FontStyle.italic)),
          const SizedBox(height: 28),
          const Divider(),
          const SizedBox(height: 12),
          Text(
            'Horizon is free software: you can share and modify it under the '
            'terms of the GNU General Public License v3.0. Portions derived '
            'from Reins, © 2024–2026 İbrahim Çetin, '
            'also under GPL-3.0. Modifications and additions © 2026 Miles '
            'Oldenburger. There is no warranty; see the licence for details.',
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
              height: 1.5,
            ),
          ),
          const SizedBox(height: 12),
          Wrap(
            spacing: 8,
            children: [
              OutlinedButton.icon(
                onPressed: () => launchUrlString(reinsUrl),
                icon: const Icon(Icons.open_in_new, size: 18),
                label: const Text('Reins on GitHub'),
              ),
              OutlinedButton.icon(
                onPressed: () => launchUrlString(licenceUrl),
                icon: const Icon(Icons.balance_outlined, size: 18),
                label: const Text('Licence'),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
