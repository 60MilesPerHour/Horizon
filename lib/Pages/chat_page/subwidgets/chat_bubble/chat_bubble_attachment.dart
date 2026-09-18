import 'package:flutter/material.dart';

import 'package:horizon/Models/attachment.dart';

/// Chip for a document attached to a message.
///
/// Used both in the transcript (read-only) and above the prompt field before
/// sending, where [onRemove] supplies the dismiss affordance. Tapping opens a
/// sheet with the exact text that was extracted — the model's view of the
/// file, which is the only way to tell "the PDF says nothing about that" from
/// "the extractor missed a column".
class AttachmentChip extends StatelessWidget {
  final Attachment attachment;
  final VoidCallback? onRemove;

  const AttachmentChip({
    super.key,
    required this.attachment,
    this.onRemove,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Container(
      constraints: const BoxConstraints(maxWidth: 260.0),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHigh,
        borderRadius: BorderRadius.circular(8.0),
        border: Border.all(color: theme.colorScheme.outlineVariant, width: 0.5),
      ),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: () => _showExtractedText(context),
        child: Padding(
          padding: EdgeInsets.fromLTRB(10.0, 8.0, onRemove == null ? 10.0 : 2.0, 8.0),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                _iconFor(attachment.kind),
                size: 20.0,
                color: theme.colorScheme.primary,
              ),
              const SizedBox(width: 8.0),
              Flexible(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      attachment.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.bodySmall,
                    ),
                    Text(
                      attachment.truncated
                          ? '${attachment.subtitle} · truncated'
                          : attachment.subtitle,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.labelSmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
              if (onRemove != null)
                IconButton(
                  onPressed: onRemove,
                  visualDensity: VisualDensity.compact,
                  iconSize: 16.0,
                  tooltip: 'Remove',
                  icon: const Icon(Icons.close),
                ),
            ],
          ),
        ),
      ),
    );
  }

  void _showExtractedText(BuildContext context) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (context) => DraggableScrollableSheet(
        expand: false,
        initialChildSize: 0.7,
        maxChildSize: 0.95,
        builder: (context, controller) => Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 20.0),
              child: Text(
                attachment.name,
                style: Theme.of(context).textTheme.titleMedium,
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(20.0, 2.0, 20.0, 8.0),
              child: Text(
                'Text sent to the model${attachment.truncated ? ' (truncated)' : ''}',
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                    ),
              ),
            ),
            const Divider(height: 1),
            Expanded(
              child: SingleChildScrollView(
                controller: controller,
                padding: const EdgeInsets.all(20.0),
                child: SelectableText(
                  attachment.text,
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        fontFamily: 'monospace',
                      ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  static IconData _iconFor(AttachmentKind kind) {
    switch (kind) {
      case AttachmentKind.pdf:
        return Icons.picture_as_pdf_outlined;
      case AttachmentKind.csv:
        return Icons.table_chart_outlined;
      case AttachmentKind.json:
        return Icons.data_object;
      case AttachmentKind.code:
        return Icons.code;
      case AttachmentKind.text:
        return Icons.description_outlined;
    }
  }
}
