import 'package:flutter/material.dart';

import 'package:horizon/Models/appearance.dart';

/// Builds Horizon's [ThemeData] from an [Appearance].
///
/// One place, two entry points (light and dark), so a new appearance knob is
/// wired once rather than in every widget that happens to care. Anything a
/// widget needs at paint time that isn't expressible as ThemeData — the
/// frosted blur, the bubble shape — reads the [Appearance] directly.
class HorizonTheme {
  const HorizonTheme._();

  /// Opacity of the chrome when frosted. High enough that text on the app bar
  /// stays legible over a bright message behind it, low enough to read as
  /// translucent.
  static const double frostedOpacity = 0.72;

  /// Blur sigma behind frosted chrome.
  static const double frostedBlur = 24.0;

  static ThemeData light(Appearance appearance) => _build(appearance, Brightness.light);

  static ThemeData dark(Appearance appearance) => _build(appearance, Brightness.dark);

  static ThemeData _build(Appearance appearance, Brightness brightness) {
    final isDark = brightness == Brightness.dark;
    final trueBlack = isDark && appearance.darkFlavor == DarkFlavor.black;

    var scheme = ColorScheme.fromSeed(
      brightness: brightness,
      dynamicSchemeVariant: appearance.schemeVariant,
      seedColor: appearance.seedColor,
    );

    if (trueBlack) {
      // Pure black surface with the container steps pulled down to match.
      // Overriding `surface` alone leaves cards and sheets floating on visibly
      // lighter grey, which is what made the old OLED theme look patchy.
      scheme = scheme.copyWith(
        surface: const Color(0xFF000000),
        surfaceContainerLowest: const Color(0xFF000000),
        surfaceContainerLow: const Color(0xFF0A0A0A),
        surfaceContainer: const Color(0xFF121212),
        surfaceContainerHigh: const Color(0xFF1A1A1A),
        surfaceContainerHighest: const Color(0xFF222222),
      );
    }

    final radius = BorderRadius.circular(appearance.cornerRadius);
    final shape = RoundedRectangleBorder(borderRadius: radius);

    final chromeColor = appearance.isFrosted ? scheme.surface.withValues(alpha: frostedOpacity) : scheme.surface;

    return ThemeData(
      colorScheme: scheme,
      useMaterial3: true,
      scaffoldBackgroundColor: trueBlack ? const Color(0xFF000000) : null,
      visualDensity: appearance.compact ? VisualDensity.compact : VisualDensity.standard,
      appBarTheme: AppBarTheme(
        centerTitle: true,
        // Transparent so the blur painted into `flexibleSpace` shows through;
        // the surface tint is what would otherwise re-opaque it on scroll.
        backgroundColor: appearance.isFrosted ? Colors.transparent : null,
        surfaceTintColor: appearance.isFrosted ? Colors.transparent : null,
        scrolledUnderElevation: appearance.isFrosted ? 0 : null,
      ),
      drawerTheme: DrawerThemeData(
        backgroundColor: chromeColor,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.only(topRight: radius.topRight, bottomRight: radius.bottomRight),
        ),
      ),
      bottomSheetTheme: BottomSheetThemeData(
        backgroundColor: chromeColor,
        surfaceTintColor: appearance.isFrosted ? Colors.transparent : null,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: radius.topLeft)),
      ),
      dialogTheme: DialogThemeData(shape: shape),
      cardTheme: CardThemeData(shape: shape),
      popupMenuTheme: PopupMenuThemeData(shape: shape),
      inputDecorationTheme: InputDecorationTheme(
        border: OutlineInputBorder(borderRadius: radius),
        enabledBorder: OutlineInputBorder(borderRadius: radius),
        focusedBorder: OutlineInputBorder(borderRadius: radius),
      ),
      filledButtonTheme: FilledButtonThemeData(style: FilledButton.styleFrom(shape: shape)),
      elevatedButtonTheme: ElevatedButtonThemeData(style: ElevatedButton.styleFrom(shape: shape)),
      outlinedButtonTheme: OutlinedButtonThemeData(style: OutlinedButton.styleFrom(shape: shape)),
      listTileTheme: ListTileThemeData(shape: shape),
      snackBarTheme: SnackBarThemeData(behavior: SnackBarBehavior.floating, shape: shape),
    );
  }
}
