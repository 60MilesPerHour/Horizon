import 'package:flutter/material.dart';
import 'package:hive/hive.dart';

import 'package:horizon/Models/appearance.dart';

/// Holds the live [Appearance] and persists every change to the Hive
/// `settings` box.
///
/// A ChangeNotifier rather than a set of `ValueListenableBuilder`s on Hive
/// keys: the app root needs to rebuild on any appearance change, and listing
/// every key by hand there is how `dark_flavor` would have ended up applied
/// only after a restart.
class AppearanceController extends ChangeNotifier {
  AppearanceController({Box? settingsBox}) : _box = settingsBox ?? Hive.box('settings') {
    _appearance = _read();
  }

  final Box _box;
  late Appearance _appearance;

  Appearance get appearance => _appearance;

  // Storage keys. `color` and `brightness` predate this class and are still
  // read so an existing install keeps the theme it already had.
  static const String _keySeedLegacy = 'color';
  static const String _keyBrightnessLegacy = 'brightness';
  static const String _keySeedArgb = 'accent_argb';
  static const String _keyThemeMode = 'theme_mode';
  static const String _keySchemeVariant = 'scheme_variant';
  static const String _keyDarkFlavor = 'dark_flavor';
  static const String _keySurfaceStyle = 'surface_style';
  static const String _keyTextScale = 'text_scale';
  static const String _keyCornerRadius = 'corner_radius';
  static const String _keyCompact = 'compact_density';
  static const String _keyUserBubbles = 'user_bubbles';

  Appearance _read() {
    return Appearance(
      themeMode: _readThemeMode(),
      seedColor: _readSeedColor(),
      schemeVariant: _readSchemeVariant(),
      darkFlavor: DarkFlavor.fromString(_box.get(_keyDarkFlavor) as String?),
      surfaceStyle: SurfaceStyle.fromString(_box.get(_keySurfaceStyle) as String?),
      textScale: (_box.get(_keyTextScale) as num?)?.toDouble() ?? 1.0,
      cornerRadius: (_box.get(_keyCornerRadius) as num?)?.toDouble() ?? 10.0,
      compact: _box.get(_keyCompact, defaultValue: false) as bool,
      userBubbles: _box.get(_keyUserBubbles, defaultValue: true) as bool,
    );
  }

  /// `theme_mode` wins; falling back to the old `brightness` int (1 = light,
  /// 0 = dark, null = system) so nobody's theme flips on upgrade.
  ThemeMode _readThemeMode() {
    switch (_box.get(_keyThemeMode) as String?) {
      case 'light':
        return ThemeMode.light;
      case 'dark':
        return ThemeMode.dark;
      case 'system':
        return ThemeMode.system;
    }
    final legacy = _box.get(_keyBrightnessLegacy);
    if (legacy == 1) return ThemeMode.light;
    if (legacy == 0) return ThemeMode.dark;
    return ThemeMode.system;
  }

  /// An arbitrary accent is stored as an ARGB int under `accent_argb`. The old
  /// `color` key held a MaterialColor through a Hive TypeAdapter that resolves
  /// by matching `Colors.primaries`, so it can only ever round-trip one of
  /// those swatches — which is exactly why the custom picker writes an int
  /// instead of extending it.
  Color _readSeedColor() {
    final argb = _box.get(_keySeedArgb);
    if (argb is int) return Color(argb);
    final legacy = _box.get(_keySeedLegacy);
    if (legacy is Color) return legacy;
    return Colors.grey;
  }

  DynamicSchemeVariant _readSchemeVariant() {
    final stored = _box.get(_keySchemeVariant) as String?;
    for (final variant in kSchemeVariantLabels.keys) {
      if (variant.name == stored) return variant;
    }
    return DynamicSchemeVariant.neutral;
  }

  Future<void> _apply(Appearance next, String key, Object? value) async {
    _appearance = next;
    notifyListeners();
    await _box.put(key, value);
  }

  Future<void> setThemeMode(ThemeMode mode) async {
    // The legacy key is kept in step: nothing reads it any more, but a config
    // backup restored onto an older build otherwise resurrects the old theme.
    await _box.put(_keyBrightnessLegacy, mode == ThemeMode.light ? 1 : (mode == ThemeMode.dark ? 0 : null));
    await _apply(_appearance.copyWith(themeMode: mode), _keyThemeMode, mode.name);
  }

  Future<void> setSeedColor(Color color) =>
      _apply(_appearance.copyWith(seedColor: color), _keySeedArgb, color.toARGB32());

  Future<void> setSchemeVariant(DynamicSchemeVariant variant) =>
      _apply(_appearance.copyWith(schemeVariant: variant), _keySchemeVariant, variant.name);

  Future<void> setDarkFlavor(DarkFlavor flavor) =>
      _apply(_appearance.copyWith(darkFlavor: flavor), _keyDarkFlavor, flavor.storageValue);

  Future<void> setSurfaceStyle(SurfaceStyle style) =>
      _apply(_appearance.copyWith(surfaceStyle: style), _keySurfaceStyle, style.storageValue);

  Future<void> setTextScale(double scale) => _apply(_appearance.copyWith(textScale: scale), _keyTextScale, scale);

  Future<void> setCornerRadius(double radius) =>
      _apply(_appearance.copyWith(cornerRadius: radius), _keyCornerRadius, radius);

  Future<void> setCompact(bool compact) => _apply(_appearance.copyWith(compact: compact), _keyCompact, compact);

  Future<void> setUserBubbles(bool enabled) =>
      _apply(_appearance.copyWith(userBubbles: enabled), _keyUserBubbles, enabled);

  /// Back to the shipped defaults, without touching anything else in the box.
  Future<void> resetToDefaults() async {
    _appearance = const Appearance();
    notifyListeners();
    await _box.deleteAll([
      _keyThemeMode,
      _keyBrightnessLegacy,
      _keySeedArgb,
      _keySeedLegacy,
      _keySchemeVariant,
      _keyDarkFlavor,
      _keySurfaceStyle,
      _keyTextScale,
      _keyCornerRadius,
      _keyCompact,
      _keyUserBubbles,
    ]);
  }
}
