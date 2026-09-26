package com.miles.horizon

import android.content.Context
import io.flutter.app.FlutterApplication
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.embedding.engine.FlutterEngineCache
import io.flutter.embedding.engine.dart.DartExecutor
import io.flutter.plugin.common.MethodChannel

/**
 * Owns the Flutter engine for the life of the process, not the activity.
 *
 * With the default arrangement the engine belongs to MainActivity, so
 * swiping Horizon out of recents destroyed it — and with it the Dart isolate
 * running "Hey Horizon". The microphone service kept the process alive with
 * nothing left inside it to listen. Created here instead, the engine outlives
 * the window: the activity attaches to it and detaches from it, and the wake
 * word keeps running for as long as its foreground service does.
 *
 * The assistant channel lives here too, bound to the application context,
 * so a wake heard with no window open can still bring the voice screen up.
 */
class HorizonApplication : FlutterApplication() {
    override fun onCreate() {
        super.onCreate()
        val engine = FlutterEngine(this)
        engine.dartExecutor.executeDartEntrypoint(DartExecutor.DartEntrypoint.createDefault())
        FlutterEngineCache.getInstance().put(ENGINE_ID, engine)
        channel = MethodChannel(engine.dartExecutor.binaryMessenger, MainActivity.CHANNEL_NAME).apply {
            setMethodCallHandler { call, result ->
                val context: Context = this@HorizonApplication
                when (call.method) {
                    "isDefaultAssistant" -> result.success(AssistantRole.isDefaultAssistant(context))
                    "openAssistantSettings" -> result.success(AssistantRole.openAssistantSettings(context))
                    // The wake word heard its phrase with the app behind
                    // something else, or with no window at all.
                    "openVoiceFromBackground" -> result.success(WakeLauncher.open(context))
                    // Dart asks once it is ready: an assist launch that
                    // arrived before the isolate could hear about it.
                    "takePendingAssist" -> {
                        dartReady = true
                        result.success(pendingAssist.also { pendingAssist = false })
                    }
                    else -> result.notImplemented()
                }
            }
        }
    }

    companion object {
        const val ENGINE_ID = "horizon_main"

        @Volatile
        var channel: MethodChannel? = null

        @Volatile
        private var dartReady = false

        @Volatile
        private var pendingAssist = false

        /** Opens the voice screen now if Dart is listening, or when it is. */
        fun requestAssist() {
            val ch = channel
            if (dartReady && ch != null) {
                ch.invokeMethod("openAssistant", null)
            } else {
                pendingAssist = true
            }
        }
    }
}
