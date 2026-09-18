import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'package:horizon/Models/appearance.dart';
import 'package:horizon/Services/appearance_controller.dart';
import 'package:horizon/Widgets/frosted_surface.dart';

/// Appearance settings.
///
/// Everything here applies the moment it's touched and the preview at the top
/// shows it against real chat furniture, because "Vibrant + true black at
/// radius 4" is not a thing anyone can picture from a label. The old page
/// offered six seed colours and an unlabelled icon button that cycled
/// light → dark → auto with no indication of which state it was in.
class AppearanceSettingsPage extends StatelessWidget {
  const AppearanceSettingsPage({super.key});

  @override
  Widget build(BuildContext context) {
    final controller = context.watch<AppearanceController>();
    final appearance = controller.appearance;
    final theme = Theme.of(context);

    return Scaffold(
      appBar: AppBar(
        title: const Text('Appearance'),
        flexibleSpace: const FrostedSurface(),
        actions: [
          IconButton(
            icon: const Icon(Icons.restart_alt),
            tooltip: 'Reset to defaults',
            onPressed: () => _confirmReset(context, controller),
          ),
        ],
      ),
      body: ListView(
        physics: const BouncingScrollPhysics(),
        padding: const EdgeInsets.all(16),
        children: [
          const _Preview(),
          const SizedBox(height: 24),

          _SectionTitle('Theme'),
          SegmentedButton<ThemeMode>(
            segments: const [
              ButtonSegment(value: ThemeMode.system, icon: Icon(Icons.brightness_auto_outlined), label: Text('System')),
              ButtonSegment(value: ThemeMode.light, icon: Icon(Icons.light_mode_outlined), label: Text('Light')),
              ButtonSegment(value: ThemeMode.dark, icon: Icon(Icons.dark_mode_outlined), label: Text('Dark')),
            ],
            selected: {appearance.themeMode},
            onSelectionChanged: (s) => controller.setThemeMode(s.first),
          ),
          const SizedBox(height: 8),
          // Only meaningful when a dark theme can actually appear.
          if (appearance.themeMode != ThemeMode.light)
            _EnumTiles<DarkFlavor>(
              values: DarkFlavor.values,
              selected: appearance.darkFlavor,
              labelOf: (v) => v.label,
              descriptionOf: (v) => v.description,
              onChanged: controller.setDarkFlavor,
            ),

          const SizedBox(height: 16),
          _SectionTitle('Accent colour'),
          Text('The whole palette is generated from this one colour.', style: theme.textTheme.bodySmall),
          const SizedBox(height: 12),
          _AccentPicker(selected: appearance.seedColor, onChanged: controller.setSeedColor),
          const SizedBox(height: 8),
          OutlinedButton.icon(
            icon: const Icon(Icons.colorize),
            label: const Text('Custom colour'),
            onPressed: () => _openCustomColour(context, controller),
          ),

          const SizedBox(height: 16),
          _SectionTitle('Palette style'),
          Text('How strongly your colour is pushed through the interface.', style: theme.textTheme.bodySmall),
          const SizedBox(height: 8),
          _EnumTiles<DynamicSchemeVariant>(
            values: kSchemeVariantLabels.keys.toList(),
            selected: appearance.schemeVariant,
            labelOf: (v) => kSchemeVariantLabels[v]!,
            descriptionOf: (v) => kSchemeVariantDescriptions[v]!,
            onChanged: controller.setSchemeVariant,
          ),

          const SizedBox(height: 16),
          _SectionTitle('Surfaces'),
          _EnumTiles<SurfaceStyle>(
            values: SurfaceStyle.values,
            selected: appearance.surfaceStyle,
            labelOf: (v) => v.label,
            descriptionOf: (v) => v.description,
            onChanged: controller.setSurfaceStyle,
          ),

          const SizedBox(height: 16),
          _SectionTitle('Shape & size'),
          _SliderTile(
            label: 'Corner radius',
            value: appearance.cornerRadius,
            min: Appearance.minCornerRadius,
            max: Appearance.maxCornerRadius,
            divisions: 14,
            valueLabel: '${appearance.cornerRadius.round()} px',
            onChanged: controller.setCornerRadius,
          ),
          _SliderTile(
            label: 'Text size',
            value: appearance.textScale,
            min: Appearance.minTextScale,
            max: Appearance.maxTextScale,
            divisions: 10,
            valueLabel: '${(appearance.textScale * 100).round()}%',
            onChanged: controller.setTextScale,
          ),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('Compact density'),
            subtitle: const Text('Tighter rows and controls throughout'),
            value: appearance.compact,
            onChanged: controller.setCompact,
          ),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('Bubble your messages'),
            subtitle: const Text('Off puts your text flush with the reply, like a transcript'),
            value: appearance.userBubbles,
            onChanged: controller.setUserBubbles,
          ),
          const SizedBox(height: 32),
        ],
      ),
    );
  }

  Future<void> _confirmReset(BuildContext context, AppearanceController controller) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Reset appearance?'),
        content: const Text(
          'Theme, colour, shape and density go back to the defaults. Nothing '
          'else in Settings is touched.',
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('Reset')),
        ],
      ),
    );
    if (confirmed == true) await controller.resetToDefaults();
  }

  Future<void> _openCustomColour(BuildContext context, AppearanceController controller) {
    return showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (_) => _CustomColourSheet(initial: controller.appearance.seedColor, onPicked: controller.setSeedColor),
    );
  }
}

class _SectionTitle extends StatelessWidget {
  const _SectionTitle(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Text(text, style: Theme.of(context).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.bold)),
    );
  }
}

/// Radio-style list for a small enum. Shows every option with what it does,
/// rather than a dropdown that hides the alternatives behind a tap.
class _EnumTiles<T> extends StatelessWidget {
  const _EnumTiles({
    required this.values,
    required this.selected,
    required this.labelOf,
    required this.descriptionOf,
    required this.onChanged,
  });

  final List<T> values;
  final T selected;
  final String Function(T) labelOf;
  final String Function(T) descriptionOf;
  final void Function(T) onChanged;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      children: [
        for (final value in values)
          ListTile(
            contentPadding: EdgeInsets.zero,
            leading: Icon(
              value == selected ? Icons.radio_button_checked : Icons.radio_button_off,
              color: value == selected ? theme.colorScheme.primary : null,
            ),
            title: Text(labelOf(value)),
            subtitle: Text(descriptionOf(value), style: theme.textTheme.bodySmall),
            onTap: () => onChanged(value),
          ),
      ],
    );
  }
}

class _SliderTile extends StatelessWidget {
  const _SliderTile({
    required this.label,
    required this.value,
    required this.min,
    required this.max,
    required this.divisions,
    required this.valueLabel,
    required this.onChanged,
  });

  final String label;
  final double value;
  final double min;
  final double max;
  final int divisions;
  final String valueLabel;
  final void Function(double) onChanged;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(child: Text(label)),
            Text(valueLabel, style: theme.textTheme.bodySmall),
          ],
        ),
        Slider(
          value: value.clamp(min, max),
          min: min,
          max: max,
          divisions: divisions,
          label: valueLabel,
          onChanged: onChanged,
        ),
      ],
    );
  }
}

class _AccentPicker extends StatelessWidget {
  const _AccentPicker({required this.selected, required this.onChanged});

  final Color selected;
  final void Function(Color) onChanged;

  @override
  Widget build(BuildContext context) {
    return Wrap(
      spacing: 12,
      runSpacing: 12,
      children: [
        for (final color in Appearance.accentPresets)
          _Swatch(
            color: color,
            // Compared by ARGB, not identity: a colour restored from the box
            // is a plain Color, never the same object as the MaterialColor
            // constant it came from.
            isSelected: color.toARGB32() == selected.toARGB32(),
            onTap: () => onChanged(color),
          ),
        // A custom colour isn't in the preset row, so it gets its own swatch
        // — otherwise nothing on screen shows what's actually selected.
        if (!Appearance.accentPresets.any((c) => c.toARGB32() == selected.toARGB32()))
          _Swatch(color: selected, isSelected: true, onTap: () {}),
      ],
    );
  }
}

class _Swatch extends StatelessWidget {
  const _Swatch({required this.color, required this.isSelected, required this.onTap});

  final Color color;
  final bool isSelected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return InkWell(
      onTap: onTap,
      customBorder: const CircleBorder(),
      child: Container(
        width: 44,
        height: 44,
        decoration: BoxDecoration(
          color: color,
          shape: BoxShape.circle,
          border: Border.all(
            color: isSelected ? theme.colorScheme.onSurface : theme.colorScheme.outlineVariant,
            width: isSelected ? 3 : 1,
          ),
        ),
        child: isSelected
            ? Icon(
                Icons.check,
                size: 20,
                color: ThemeData.estimateBrightnessForColor(color) == Brightness.dark ? Colors.white : Colors.black,
              )
            : null,
      ),
    );
  }
}

/// Hue + saturation + value sliders.
///
/// Three sliders rather than a colour wheel: a wheel means a gesture-tracking
/// custom painter (or a dependency) to pick a seed colour the scheme generator
/// is going to re-derive anyway.
class _CustomColourSheet extends StatefulWidget {
  const _CustomColourSheet({required this.initial, required this.onPicked});

  final Color initial;
  final void Function(Color) onPicked;

  @override
  State<_CustomColourSheet> createState() => _CustomColourSheetState();
}

class _CustomColourSheetState extends State<_CustomColourSheet> {
  late HSVColor _hsv;

  @override
  void initState() {
    super.initState();
    _hsv = HSVColor.fromColor(widget.initial);
  }

  void _update(HSVColor next) {
    setState(() => _hsv = next);
    // Applied live, so the sheet is its own preview.
    widget.onPicked(next.toColor());
  }

  @override
  Widget build(BuildContext context) {
    final color = _hsv.toColor();
    return Padding(
      padding: EdgeInsets.fromLTRB(16, 16, 16, 16 + MediaQuery.of(context).viewInsets.bottom),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                width: 40,
                height: 40,
                decoration: BoxDecoration(color: color, shape: BoxShape.circle),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  '#${color.toARGB32().toRadixString(16).padLeft(8, '0').substring(2).toUpperCase()}',
                  style: Theme.of(context).textTheme.titleMedium,
                ),
              ),
              TextButton(onPressed: () => Navigator.pop(context), child: const Text('Done')),
            ],
          ),
          const SizedBox(height: 8),
          _labelled('Hue', _hsv.hue, 0, 360, (v) => _update(_hsv.withHue(v))),
          _labelled('Saturation', _hsv.saturation, 0, 1, (v) => _update(_hsv.withSaturation(v))),
          _labelled('Brightness', _hsv.value, 0, 1, (v) => _update(_hsv.withValue(v))),
        ],
      ),
    );
  }

  Widget _labelled(String label, double value, double min, double max, void Function(double) onChanged) {
    return Row(
      children: [
        SizedBox(width: 92, child: Text(label)),
        Expanded(
          child: Slider(value: value.clamp(min, max), min: min, max: max, onChanged: onChanged),
        ),
      ],
    );
  }
}

/// A miniature chat, so a change can be judged against the thing it affects.
class _Preview extends StatelessWidget {
  const _Preview();

  @override
  Widget build(BuildContext context) {
    final appearance = context.watch<AppearanceController>().appearance;
    final theme = Theme.of(context);
    final radius = BorderRadius.circular(appearance.cornerRadius);

    return Card(
      margin: EdgeInsets.zero,
      clipBehavior: Clip.antiAlias,
      child: Column(
        children: [
          // Stand-in for the app bar, frosted style included.
          Stack(
            children: [
              Container(height: 44, color: theme.colorScheme.surfaceContainerHighest),
              Positioned.fill(child: const FrostedSurface()),
              SizedBox(
                height: 44,
                child: Center(child: Text('qwen3.6:27b', style: theme.textTheme.titleSmall)),
              ),
            ],
          ),
          Padding(
            padding: const EdgeInsets.all(12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Container(
                  padding: appearance.userBubbles ? const EdgeInsets.all(10) : EdgeInsets.zero,
                  decoration: BoxDecoration(
                    color: appearance.userBubbles ? theme.colorScheme.primaryContainer : null,
                    borderRadius: radius,
                  ),
                  child: const Text('what does this look like?'),
                ),
                const SizedBox(height: 8),
                Align(
                  alignment: Alignment.centerLeft,
                  child: Text(
                    'Like this. Accent, shape, density and text size all '
                    'apply here first.',
                    style: theme.textTheme.bodyMedium,
                  ),
                ),
                const SizedBox(height: 8),
                Align(
                  alignment: Alignment.centerLeft,
                  child: Wrap(
                    spacing: 8,
                    children: [
                      FilledButton(onPressed: () {}, child: const Text('Send')),
                      OutlinedButton(onPressed: () {}, child: const Text('Cancel')),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
