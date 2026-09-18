import 'package:flutter/material.dart';

/// Everything the user can change about how Horizon looks, in one immutable
/// value.
///
/// Appearance used to be two Hive keys read directly by `main.dart` — a seed
/// colour and a tri-state `brightness` int toggled by an unlabelled icon
/// button. Collecting it here means a setting is declared once, the theme is
/// built from one place, and adding another knob doesn't mean another
/// `ValueListenableBuilder` key in the app root.
@immutable
class Appearance {
  /// Light, dark, or follow the system.
  final ThemeMode themeMode;

  /// Seed colour the whole Material scheme is generated from.
  final Color seedColor;

  /// How Material derives the scheme from [seedColor]. `neutral` is Horizon's
  /// long-standing look (desaturated, the colour shows up mostly in accents);
  /// the others range up to `vibrant`, which pushes the seed through the whole
  /// surface stack.
  final DynamicSchemeVariant schemeVariant;

  /// Whether dark mode is true black. Black is what an OLED panel wants and
  /// has been Horizon's dark default since v3; dim is the Material grey, which
  /// is easier on an LCD and keeps elevation readable.
  final DarkFlavor darkFlavor;

  /// Whether the chrome — app bar, drawer, sheets — is opaque or translucent
  /// with a blur behind it.
  final SurfaceStyle surfaceStyle;

  /// Multiplier applied on top of the platform text scale.
  final double textScale;

  /// Corner radius for bubbles, cards and sheets.
  final double cornerRadius;

  /// Row/control density.
  final bool compact;

  /// Whether the user's own messages sit in a filled bubble, or run flush with
  /// the assistant's text.
  final bool userBubbles;

  const Appearance({
    this.themeMode = ThemeMode.system,
    this.seedColor = Colors.grey,
    this.schemeVariant = DynamicSchemeVariant.neutral,
    this.darkFlavor = DarkFlavor.black,
    this.surfaceStyle = SurfaceStyle.solid,
    this.textScale = 1.0,
    this.cornerRadius = 10.0,
    this.compact = false,
    this.userBubbles = true,
  });

  Appearance copyWith({
    ThemeMode? themeMode,
    Color? seedColor,
    DynamicSchemeVariant? schemeVariant,
    DarkFlavor? darkFlavor,
    SurfaceStyle? surfaceStyle,
    double? textScale,
    double? cornerRadius,
    bool? compact,
    bool? userBubbles,
  }) {
    return Appearance(
      themeMode: themeMode ?? this.themeMode,
      seedColor: seedColor ?? this.seedColor,
      schemeVariant: schemeVariant ?? this.schemeVariant,
      darkFlavor: darkFlavor ?? this.darkFlavor,
      surfaceStyle: surfaceStyle ?? this.surfaceStyle,
      textScale: textScale ?? this.textScale,
      cornerRadius: cornerRadius ?? this.cornerRadius,
      compact: compact ?? this.compact,
      userBubbles: userBubbles ?? this.userBubbles,
    );
  }

  bool get isFrosted => surfaceStyle == SurfaceStyle.frosted;

  /// Presets offered in the accent picker. A custom colour is stored as an
  /// ARGB int, so this list is a starting point rather than the limit.
  static const List<Color> accentPresets = [
    Colors.grey,
    Colors.blueGrey,
    Colors.red,
    Colors.deepOrange,
    Colors.amber,
    Colors.green,
    Colors.teal,
    Colors.cyan,
    Colors.blue,
    Colors.indigo,
    Colors.deepPurple,
    Colors.pink,
  ];

  static const double minTextScale = 0.85;
  static const double maxTextScale = 1.35;
  static const double minCornerRadius = 0.0;
  static const double maxCornerRadius = 28.0;
}

enum DarkFlavor {
  /// Pure #000000 surfaces.
  black('True black', 'Pure black surfaces — best on OLED'),

  /// Material's dark grey, with visible elevation.
  dim('Dim', 'Material dark grey, softer on an LCD');

  const DarkFlavor(this.label, this.description);

  final String label;
  final String description;

  static DarkFlavor fromString(String? value) => value == 'dim' ? DarkFlavor.dim : DarkFlavor.black;

  String get storageValue => name;
}

enum SurfaceStyle {
  solid('Solid', 'Opaque app bar, drawer and sheets'),

  /// Translucent chrome with a blur behind it. Done in-app with a
  /// BackdropFilter rather than by making the OS window transparent, so it
  /// behaves identically on all five platforms — the trade-off is that it
  /// blurs Horizon's own content, not the desktop behind it.
  frosted('Frosted', 'Translucent chrome, blurred over the content behind it');

  const SurfaceStyle(this.label, this.description);

  final String label;
  final String description;

  static SurfaceStyle fromString(String? value) => value == 'frosted' ? SurfaceStyle.frosted : SurfaceStyle.solid;

  String get storageValue => name;
}

/// Labels for the scheme variants worth exposing. Material defines more, but
/// several are near-indistinguishable at a glance and a picker that offers
/// nine barely-different options is worse than one that offers four real ones.
const Map<DynamicSchemeVariant, String> kSchemeVariantLabels = {
  DynamicSchemeVariant.neutral: 'Neutral',
  DynamicSchemeVariant.tonalSpot: 'Tonal',
  DynamicSchemeVariant.vibrant: 'Vibrant',
  DynamicSchemeVariant.expressive: 'Expressive',
  DynamicSchemeVariant.content: 'Faithful',
};

const Map<DynamicSchemeVariant, String> kSchemeVariantDescriptions = {
  DynamicSchemeVariant.neutral: 'Desaturated — colour only in the accents',
  DynamicSchemeVariant.tonalSpot: 'Material You default, gentle tint',
  DynamicSchemeVariant.vibrant: 'Saturated, colour through the surfaces',
  DynamicSchemeVariant.expressive: 'Shifted hues for more contrast',
  DynamicSchemeVariant.content: 'Keeps your colour exactly as picked',
};
