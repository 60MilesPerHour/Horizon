import 'package:flutter/material.dart';

import 'package:horizon/Services/hermes_service.dart';
import 'package:horizon/Widgets/horizon_brand.dart';

/// A command the Hermes agent is holding until you answer, shown over the
/// composer: what it wants to run, why it was flagged, and the answers Hermes
/// will accept.
class HermesApprovalCard extends StatelessWidget {
  final HermesApproval approval;
  final void Function(String choice) onChoice;

  const HermesApprovalCard({
    super.key,
    required this.approval,
    required this.onChoice,
  });

  static const _labels = {
    'once': 'Allow once',
    'session': 'Allow for this chat',
    'always': 'Always allow',
  };

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final accent = HorizonBrand.accent(context);
    final allows = approval.choices.where(_labels.containsKey).toList();

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
      child: Card(
        margin: EdgeInsets.zero,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(16),
          side: BorderSide(color: accent.withValues(alpha: 0.6)),
        ),
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Icon(Icons.shield_outlined, size: 18, color: accent),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      'The agent wants to run this',
                      style: theme.textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w600),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 4),
              Text(
                approval.description,
                style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant),
              ),
              if (approval.command.isNotEmpty) ...[
                const SizedBox(height: 10),
                Container(
                  width: double.infinity,
                  constraints: const BoxConstraints(maxHeight: 140),
                  padding: const EdgeInsets.all(10),
                  decoration: BoxDecoration(
                    color: theme.colorScheme.surfaceContainerHighest,
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: SingleChildScrollView(
                    child: SelectableText(
                      approval.command,
                      style: const TextStyle(fontFamily: 'Source Code Pro', fontSize: 13),
                    ),
                  ),
                ),
              ],
              const SizedBox(height: 12),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  if (approval.choices.contains('deny'))
                    OutlinedButton(
                      onPressed: () => onChoice('deny'),
                      child: const Text('Deny'),
                    ),
                  for (final choice in allows)
                    choice == 'once'
                        ? FilledButton(
                            style: FilledButton.styleFrom(backgroundColor: accent),
                            onPressed: () => onChoice(choice),
                            child: Text(_labels[choice]!),
                          )
                        : TextButton(
                            onPressed: () => onChoice(choice),
                            child: Text(_labels[choice]!),
                          ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}
