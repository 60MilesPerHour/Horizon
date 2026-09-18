import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:path/path.dart' as path;

import 'package:horizon/Constants/horizon_theme.dart';
import 'package:horizon/Models/appearance.dart';
import 'package:horizon/Services/appearance_controller.dart';
import 'package:horizon/Utils/material_color_adapter.dart';

/// Appearance is read from the Hive box that every existing install already
/// has, under keys written by older builds. The tests that matter are the ones
/// proving an upgrade doesn't silently change how the app looks.
void main() {
  late Box box;

  setUpAll(() async {
    Hive.init(path.join(Directory.current.path, 'test', 'assets'));
    if (!Hive.isAdapterRegistered(0)) {
      Hive.registerAdapter(MaterialColorAdapter());
    }
  });

  setUp(() async {
    box = await Hive.openBox('appearance_test');
    await box.clear();
  });

  tearDown(() async => box.close());

  group('legacy keys', () {
    test('brightness 1 and 0 map to light and dark', () async {
      await box.put('brightness', 1);
      expect(AppearanceController(settingsBox: box).appearance.themeMode,
          ThemeMode.light);

      await box.put('brightness', 0);
      expect(AppearanceController(settingsBox: box).appearance.themeMode,
          ThemeMode.dark);
    });

    test('a missing brightness is system, not light', () async {
      expect(AppearanceController(settingsBox: box).appearance.themeMode,
          ThemeMode.system);
    });

    test('theme_mode wins over the legacy key', () async {
      await box.put('brightness', 1);
      await box.put('theme_mode', 'dark');
      expect(AppearanceController(settingsBox: box).appearance.themeMode,
          ThemeMode.dark);
    });

    test('the old MaterialColor seed is still honoured', () async {
      await box.put('color', Colors.indigo);
      expect(AppearanceController(settingsBox: box).appearance.seedColor,
          Colors.indigo);
    });

    test('an ARGB accent takes precedence over the old swatch', () async {
      await box.put('color', Colors.indigo);
      await box.put('accent_argb', 0xFF123456);
      expect(
        AppearanceController(settingsBox: box).appearance.seedColor.toARGB32(),
        0xFF123456,
      );
    });

    test('defaults match what v3 shipped: grey seed, neutral, true black',
        () async {
      final appearance = AppearanceController(settingsBox: box).appearance;
      expect(appearance.seedColor, Colors.grey);
      expect(appearance.schemeVariant, DynamicSchemeVariant.neutral);
      expect(appearance.darkFlavor, DarkFlavor.black);
      expect(appearance.surfaceStyle, SurfaceStyle.solid);
    });
  });

  group('persistence', () {
    test('a custom colour round-trips as an int', () async {
      final controller = AppearanceController(settingsBox: box);
      await controller.setSeedColor(const Color(0xFF00BFA5));

      // Through the box, not the in-memory value: the MaterialColor adapter
      // can only store swatches from Colors.primaries, which is why an
      // arbitrary colour goes to its own key.
      expect(box.get('accent_argb'), 0xFF00BFA5);
      expect(
        AppearanceController(settingsBox: box).appearance.seedColor.toARGB32(),
        0xFF00BFA5,
      );
    });

    test('theme mode keeps the legacy key in step', () async {
      final controller = AppearanceController(settingsBox: box);
      await controller.setThemeMode(ThemeMode.dark);
      expect(box.get('brightness'), 0);

      await controller.setThemeMode(ThemeMode.system);
      expect(box.get('brightness'), isNull);
    });

    test('reset clears every key it owns', () async {
      final controller = AppearanceController(settingsBox: box);
      await controller.setSeedColor(const Color(0xFF00BFA5));
      await controller.setCompact(true);
      await controller.setSurfaceStyle(SurfaceStyle.frosted);

      await controller.resetToDefaults();

      expect(controller.appearance, const Appearance());
      expect(box.get('accent_argb'), isNull);
      expect(box.get('compact_density'), isNull);
      expect(box.get('surface_style'), isNull);
    });

    test('notifies listeners on change', () async {
      final controller = AppearanceController(settingsBox: box);
      var notified = 0;
      controller.addListener(() => notified++);

      await controller.setCornerRadius(20);
      await controller.setCompact(true);

      expect(notified, 2);
      expect(controller.appearance.cornerRadius, 20);
    });
  });

  group('HorizonTheme', () {
    test('true black pulls the container steps down too', () {
      final theme = HorizonTheme.dark(const Appearance());
      // Overriding `surface` alone left cards visibly lighter than the
      // background, which is what made the old OLED theme look patchy.
      expect(theme.colorScheme.surface, const Color(0xFF000000));
      expect(theme.colorScheme.surfaceContainerLowest, const Color(0xFF000000));
      expect(theme.scaffoldBackgroundColor, const Color(0xFF000000));
    });

    test('dim dark keeps Material\'s own surfaces', () {
      final theme = HorizonTheme.dark(
        const Appearance(darkFlavor: DarkFlavor.dim),
      );
      expect(theme.colorScheme.surface, isNot(const Color(0xFF000000)));
    });

    test('light mode is never blacked out', () {
      final theme = HorizonTheme.light(const Appearance());
      expect(theme.colorScheme.surface, isNot(const Color(0xFF000000)));
      // ThemeData fills scaffoldBackgroundColor in from the scheme when it's
      // left null, so the assertion is "not black", not "unset".
      expect(theme.scaffoldBackgroundColor, isNot(const Color(0xFF000000)));
    });

    test('frosted makes the app bar transparent so the blur shows', () {
      final solid = HorizonTheme.dark(const Appearance());
      final frosted = HorizonTheme.dark(
        const Appearance(surfaceStyle: SurfaceStyle.frosted),
      );
      expect(solid.appBarTheme.backgroundColor, isNull);
      expect(frosted.appBarTheme.backgroundColor, Colors.transparent);
      expect(frosted.appBarTheme.scrolledUnderElevation, 0);
    });

    test('corner radius reaches the shared shapes', () {
      final theme = HorizonTheme.light(const Appearance(cornerRadius: 24));
      final shape = theme.cardTheme.shape as RoundedRectangleBorder;
      expect(
        (shape.borderRadius as BorderRadius).topLeft,
        const Radius.circular(24),
      );
    });

    test('compact density is applied', () {
      expect(
        HorizonTheme.light(const Appearance(compact: true)).visualDensity,
        VisualDensity.compact,
      );
    });
  });
}
