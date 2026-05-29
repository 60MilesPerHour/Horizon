import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:horizon/Models/ollama_health.dart';
import 'package:horizon/Services/ollama_service.dart';

/// Live Ollama reachability monitor.
///
/// Polls `/api/tags` on a low frequency so the chat UI can show whether the
/// home server is currently reachable (and whether we're on the backup URL,
/// e.g. via Tailscale/ZeroTier). Real requests piggyback through
/// [OllamaService.onRequestComplete] so a successful chat call updates the
/// dot immediately without waiting for the next poll.
class OllamaHealthMonitor extends ChangeNotifier {
  final OllamaService _ollama;
  Timer? _timer;
  bool _disposed = false;
  bool _inFlight = false;

  OllamaHealth _status = OllamaHealth.unknown;
  String? _activeUrl;
  DateTime? _lastCheck;
  Object? _lastError;

  OllamaHealthMonitor(this._ollama) {
    _ollama.onRequestComplete = _onActivity;
    // Probe immediately so the indicator isn't stuck on "unknown" while we
    // wait for the first poll tick.
    scheduleMicrotask(_check);
    _timer = Timer.periodic(const Duration(seconds: 20), (_) => _check());
  }

  OllamaHealth get status => _status;
  String? get activeUrl => _activeUrl;
  DateTime? get lastCheck => _lastCheck;
  Object? get lastError => _lastError;

  /// Forces a probe right now. The chat UI calls this when the user taps
  /// the status dot, so a refresh feels instant.
  Future<void> refresh() => _check();

  Future<void> _check() async {
    if (_disposed || _inFlight) return;
    if (!_ollama.isConfigured) {
      _update(OllamaHealth.unknown, null, null);
      return;
    }
    _inFlight = true;
    try {
      await _ollama.ping();
      _update(
        _ollama.isOnBackup ? OllamaHealth.degraded : OllamaHealth.healthy,
        _ollama.baseUrl,
        null,
      );
    } catch (e) {
      _update(OllamaHealth.down, null, e);
    } finally {
      _inFlight = false;
    }
  }

  /// Called by OllamaService after a real request finishes. Cheaper than
  /// polling — when the user is actively chatting we already know the
  /// server is reachable, so we just mirror that fact.
  void _onActivity(bool success) {
    if (_disposed) return;
    if (success) {
      _update(
        _ollama.isOnBackup ? OllamaHealth.degraded : OllamaHealth.healthy,
        _ollama.baseUrl,
        null,
      );
    } else if (_ollama.isConfigured) {
      _update(OllamaHealth.down, null, _lastError);
    }
  }

  void _update(OllamaHealth s, String? url, Object? error) {
    final changed = s != _status || url != _activeUrl;
    _status = s;
    _activeUrl = url;
    _lastError = error;
    _lastCheck = DateTime.now();
    if (changed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _timer?.cancel();
    _ollama.onRequestComplete = null;
    super.dispose();
  }
}
