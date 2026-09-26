import 'package:flutter/material.dart';
import 'package:hive_flutter/hive_flutter.dart';

import 'package:horizon/Models/chat_preset.dart';
import 'package:horizon/Widgets/horizon_brand.dart';

/// The home screen: a greeting, a horizon, and a few quiet suggestions.
///
/// Mostly light and space — the warmth is the name in orange and the glow on
/// the horizon line. Replaces the old centred "Select a model to start"
/// button and the row of preset cards that sat over the composer.
class HorizonHome extends StatelessWidget {
  /// Up to three, shown as plain lines.
  final List<ChatPreset> suggestions;
  final void Function(ChatPreset preset) onSuggestion;

  /// Shown instead of suggestions when there's nothing to talk to yet.
  final Widget? notice;

  const HorizonHome({
    super.key,
    required this.suggestions,
    required this.onSuggestion,
    this.notice,
  });

  static const String nameKey = 'user_display_name';

  static String _partOfDay(int hour) {
    if (hour < 5) return 'night';
    if (hour < 12) return 'morning';
    if (hour < 17) return 'afternoon';
    if (hour < 22) return 'evening';
    return 'night';
  }

  static const List<String> _weekdays = [
    'Monday', 'Tuesday', 'Wednesday', 'Thursday', 'Friday', 'Saturday', 'Sunday',
  ];

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final now = DateTime.now();
    final part = _partOfDay(now.hour);
    final name = (Hive.box('settings').get(nameKey) as String? ?? '').trim();
    final soft = theme.colorScheme.onSurfaceVariant;
    // "Good night" is a goodbye, not a greeting — late hours just say hello.
    final greeting = part == 'night' ? 'Hello' : 'Good $part';

    final headline = theme.textTheme.displaySmall?.copyWith(
      fontWeight: FontWeight.w300,
      letterSpacing: -0.6,
      height: 1.15,
      color: theme.colorScheme.onSurface,
    );

    return LayoutBuilder(
      builder: (context, constraints) => SingleChildScrollView(
        child: ConstrainedBox(
          constraints: BoxConstraints(minHeight: constraints.maxHeight),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(32, 24, 32, 24),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '${_weekdays[now.weekday - 1]} $part'.toUpperCase(),
                  style: theme.textTheme.labelMedium?.copyWith(
                    letterSpacing: 1.8,
                    color: soft.withValues(alpha: .7),
                  ),
                ),
                const SizedBox(height: 12),
                if (name.isEmpty)
                  Text('$greeting.', style: headline)
                else ...[
                  Text('$greeting,', style: headline),
                  ShaderMask(
                    shaderCallback: HorizonBrand.nameGradient.createShader,
                    child: Text(
                      '$name.',
                      style: headline?.copyWith(color: Colors.white, fontWeight: FontWeight.w400),
                    ),
                  ),
                ],
                const SizedBox(height: 32),
                const HorizonLine(glow: true),
                const SizedBox(height: 28),
                if (notice != null)
                  notice!
                else
                  for (final preset in suggestions.take(3))
                    InkWell(
                      onTap: () => onSuggestion(preset),
                      borderRadius: BorderRadius.circular(8),
                      child: Padding(
                        padding: const EdgeInsets.symmetric(vertical: 9),
                        child: Row(
                          children: [
                            Expanded(
                              child: Text(
                                preset.title,
                                style: theme.textTheme.bodyLarge?.copyWith(
                                  fontWeight: FontWeight.w300,
                                  color: soft,
                                ),
                              ),
                            ),
                            Icon(Icons.arrow_forward, size: 16, color: soft.withValues(alpha: .6)),
                          ],
                        ),
                      ),
                    ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
