import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:hive/hive.dart';

/// Back up and restore Horizon's configuration — API keys and server settings —
/// to a single JSON file so the user doesn't have to re-enter everything by hand
/// on a fresh install or a second device.
///
/// SECURITY NOTE: the exported file contains API keys in PLAINTEXT. It is a
/// secrets file by design (re-entering keys is the whole point), so the UI warns
/// the user to keep it somewhere safe. We never bundle it anywhere automatically.
class ConfigBackupService {
  ConfigBackupService({
    FlutterSecureStorage? storage,
    Box? settingsBox,
  })  : _storage = storage ?? const FlutterSecureStorage(),
        _settingsBox = settingsBox ?? Hive.box('settings');

  final FlutterSecureStorage _storage;
  final Box _settingsBox;

  /// Bump when the file shape changes incompatibly.
  static const int schemaVersion = 1;

  /// Secure-storage keys holding secrets. Order is display order.
  static const List<String> _secureKeys = [
    'anthropic_api_key',
    'openai_api_key',
    'openai_base_url',
    'google_api_key',
    'ollama_api_token',
  ];

  /// Hive 'settings' keys that are safe, useful config (not secrets, not
  /// transient bookkeeping like launchCount/lastReviewRequest).
  static const List<String> _settingKeys = [
    'serverAddress',
    'serverAddressBackup',
    'serverUseBackup',
  ];

  /// Read everything into a portable JSON string.
  Future<String> exportToJson() async {
    final providers = <String, dynamic>{};
    for (final key in _secureKeys) {
      String? value;
      try {
        value = await _storage.read(key: key);
      } catch (_) {
        // Keystore may be unavailable (e.g. Linux without a keyring) — skip.
      }
      if (value != null && value.isNotEmpty) providers[key] = value;
    }

    final server = <String, dynamic>{};
    for (final key in _settingKeys) {
      final value = _settingsBox.get(key);
      if (value != null) server[key] = value;
    }

    final payload = {
      'horizon_config': schemaVersion,
      'exported_at': DateTime.now().toUtc().toIso8601String(),
      'providers': providers,
      'server': server,
    };
    return const JsonEncoder.withIndent('  ').convert(payload);
  }

  /// Restore from a JSON string produced by [exportToJson].
  ///
  /// Only keys present in the file are written; absent keys are left untouched
  /// so importing a partial backup never wipes settings it doesn't mention.
  /// Returns a summary of what was applied for the UI to surface.
  Future<ConfigImportResult> importFromJson(String content) async {
    final Map<String, dynamic> data;
    try {
      final decoded = json.decode(content);
      if (decoded is! Map<String, dynamic>) {
        throw const FormatException('Root is not a JSON object.');
      }
      data = decoded;
    } catch (e) {
      throw FormatException('Not a valid Horizon config file: $e');
    }

    if (!data.containsKey('horizon_config')) {
      throw const FormatException(
        "This doesn't look like a Horizon config backup.",
      );
    }

    final providers = (data['providers'] as Map?)?.cast<String, dynamic>() ?? {};
    final server = (data['server'] as Map?)?.cast<String, dynamic>() ?? {};

    final applied = <String>{};

    for (final key in _secureKeys) {
      if (!providers.containsKey(key)) continue;
      final value = providers[key]?.toString() ?? '';
      try {
        if (value.isEmpty) {
          await _storage.delete(key: key);
        } else {
          await _storage.write(key: key, value: value);
        }
        applied.add(key);
      } catch (_) {
        // Tolerate keystore failures per-key rather than aborting the import.
      }
    }

    for (final key in _settingKeys) {
      if (!server.containsKey(key)) continue;
      await _settingsBox.put(key, server[key]);
      applied.add(key);
    }

    return ConfigImportResult(
      appliedKeys: applied,
      providers: {
        for (final k in _secureKeys)
          if (applied.contains(k)) k: (providers[k]?.toString() ?? ''),
      },
    );
  }
}

/// What an import actually changed, so callers can push values into the live
/// services and tell the user what landed.
class ConfigImportResult {
  const ConfigImportResult({
    required this.appliedKeys,
    required this.providers,
  });

  /// Every storage/setting key that was written.
  final Set<String> appliedKeys;

  /// The provider secrets that were applied, keyed by secure-storage key.
  /// Used to update the running services without an app restart.
  final Map<String, String> providers;

  bool get isEmpty => appliedKeys.isEmpty;
  int get count => appliedKeys.length;
}
