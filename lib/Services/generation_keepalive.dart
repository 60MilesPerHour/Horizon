import 'dart:io';

import 'package:flutter_foreground_task/flutter_foreground_task.dart';

/// Holds Android foreground-service state for the two things that need to
/// outlive the app being on screen: a streaming reply, and the wake word.
///
/// One service for both, because Android gives an app one foreground service
/// notification and flutter_foreground_task one service — two owners starting
/// and stopping it independently would have one pull it out from under the
/// other. Each reason is counted separately, and the service stops only when
/// neither holds it.
///
/// The service does no work of its own. The streaming and the listening both
/// happen in the main isolate; the service is what keeps the process alive
/// and, for the wake word, what makes Android allow the microphone while the
/// app isn't visible.
class GenerationKeepalive {
  GenerationKeepalive._();

  static bool _initialized = false;
  static int _generations = 0;
  static bool _wakeWord = false;

  static const int _serviceId = 257;

  static void _ensureInit() {
    if (_initialized) return;
    _initialized = true;
    FlutterForegroundTask.init(
      androidNotificationOptions: AndroidNotificationOptions(
        channelId: 'horizon_generation',
        channelName: 'Horizon in the background',
        channelDescription:
            'Shown while a reply is streaming, or while Horizon is listening '
            'for its wake word, so Android keeps it running.',
        channelImportance: NotificationChannelImportance.LOW,
        priority: NotificationPriority.LOW,
        onlyAlertOnce: true,
      ),
      iosNotificationOptions: const IOSNotificationOptions(
        showNotification: false,
        playSound: false,
      ),
      foregroundTaskOptions: ForegroundTaskOptions(
        // No periodic work — the service exists purely to hold foreground
        // state. The actual streaming happens in the main isolate.
        eventAction: ForegroundTaskEventAction.nothing(),
        autoRunOnBoot: false,
        autoRunOnMyPackageReplaced: false,
        allowWakeLock: true,
        allowWifiLock: true,
      ),
    );
  }

  static String get _text => _wakeWord
      ? (_generations > 0
          ? 'Generating response… · listening for its wake word'
          : 'Listening for its wake word')
      : 'Generating response…';

  /// Call when a stream starts. Best-effort: a failure to start the service
  /// (e.g. notifications fully disabled by the OS) must never break the send.
  static Future<void> acquire() async {
    if (!Platform.isAndroid) return;
    _generations++;
    await _sync();
  }

  /// Call when a stream finishes (success, error, or cancel).
  static Future<void> release() async {
    if (!Platform.isAndroid) return;
    if (_generations > 0) _generations--;
    await _sync();
  }

  /// Holds the service for the wake word. Must be called while the app is
  /// on screen: Android only lets a microphone service start from the
  /// foreground. Returns whether the service is running with the microphone
  /// allowed, i.e. whether listening can carry on in the background.
  static Future<bool> holdForWakeWord(bool hold) async {
    if (!Platform.isAndroid) return false;
    final changed = _wakeWord != hold;
    _wakeWord = hold;
    if (!changed) {
      if (!hold) return false;
      // Already wanted; if an earlier start failed, this is the retry.
      try {
        if (await FlutterForegroundTask.isRunningService) return true;
      } catch (_) {}
      return await _sync();
    }
    // The service's type is fixed when it starts, so gaining or losing the
    // microphone means starting it again.
    try {
      if (await FlutterForegroundTask.isRunningService) {
        await FlutterForegroundTask.stopService();
      }
    } catch (_) {}
    return await _sync();
  }

  /// Whether the service is up *now* with the microphone allowed — asked of
  /// Android at the moment it matters, rather than trusting what a start
  /// call returned during app launch, which reported failure for a service
  /// that was in fact running.
  static Future<bool> holdsMicrophone() async {
    if (!Platform.isAndroid || !_wakeWord) return false;
    try {
      return await FlutterForegroundTask.isRunningService;
    } catch (_) {
      return false;
    }
  }

  static Future<bool> _sync() async {
    final wanted = _wakeWord || _generations > 0;
    try {
      _ensureInit();
      final running = await FlutterForegroundTask.isRunningService;
      if (!wanted) {
        if (running) await FlutterForegroundTask.stopService();
        return false;
      }
      if (running) {
        await FlutterForegroundTask.updateService(
          notificationTitle: 'Horizon',
          notificationText: _text,
        );
        return true;
      }
      final result = await FlutterForegroundTask.startService(
        // Microphone alone while the wake word holds it. dataSync services
        // get about six hours a day on Android 15+, after which the whole
        // service — microphone included — is stopped; a microphone service
        // has no such limit, and keeps the process alive for a streaming
        // reply just the same.
        serviceTypes: [
          _wakeWord ? ForegroundServiceTypes.microphone : ForegroundServiceTypes.dataSync,
        ],
        serviceId: _serviceId,
        notificationTitle: 'Horizon',
        notificationText: _text,
      );
      return result is ServiceRequestSuccess || await FlutterForegroundTask.isRunningService;
    } catch (_) {
      // Best-effort — generation continues either way; it just loses
      // background protection.
      return false;
    }
  }
}
