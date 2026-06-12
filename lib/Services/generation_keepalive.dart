import 'dart:io';

import 'package:flutter_foreground_task/flutter_foreground_task.dart';

/// Holds an Android foreground service while a response is streaming.
///
/// Without this, modern Android (and especially GrapheneOS) freezes the app
/// process via the cached-app freezer within seconds of the user switching
/// away — the in-flight HTTP connection dies and the response is cut off
/// mid-sentence. A dataSync foreground service exempts the process from
/// freezing for exactly as long as generation is running.
///
/// Ref-counted: multiple concurrent streams share one service; the service
/// (and its notification) disappears when the last stream finishes. No-op on
/// every platform except Android — desktop OSes don't freeze backgrounded
/// processes.
class GenerationKeepalive {
  GenerationKeepalive._();

  static bool _initialized = false;
  static int _holders = 0;

  static void _ensureInit() {
    if (_initialized) return;
    _initialized = true;
    FlutterForegroundTask.init(
      androidNotificationOptions: AndroidNotificationOptions(
        channelId: 'horizon_generation',
        channelName: 'Active generation',
        channelDescription:
            'Shown while a response is streaming so Android keeps the connection alive.',
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

  /// Call when a stream starts. Best-effort: a failure to start the service
  /// (e.g. notifications fully disabled by the OS) must never break the send.
  static Future<void> acquire() async {
    if (!Platform.isAndroid) return;
    _holders++;
    if (_holders > 1) return;
    try {
      _ensureInit();
      if (!await FlutterForegroundTask.isRunningService) {
        await FlutterForegroundTask.startService(
          serviceTypes: const [ForegroundServiceTypes.dataSync],
          serviceId: 257,
          notificationTitle: 'Horizon',
          notificationText: 'Generating response…',
        );
      }
    } catch (_) {
      // Best-effort — generation continues either way; it just loses
      // background protection.
    }
  }

  /// Call when a stream finishes (success, error, or cancel).
  static Future<void> release() async {
    if (!Platform.isAndroid) return;
    if (_holders > 0) _holders--;
    if (_holders > 0) return;
    try {
      if (await FlutterForegroundTask.isRunningService) {
        await FlutterForegroundTask.stopService();
      }
    } catch (_) {}
  }
}
