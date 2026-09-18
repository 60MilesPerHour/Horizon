package com.miles.horizon

import android.content.Intent
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

/**
 * Single Flutter activity for the whole app, including voice mode.
 *
 * Voice mode deliberately shares this activity rather than getting its own
 * FlutterActivity: a second activity means a second Flutter engine, hence a
 * second isolate with its own ChatProvider, Hive boxes and database handle.
 * Two copies of that state diverge, and the cold start costs a second.
 *
 * So the launch intent picks the initial route, and a later assist gesture
 * against an already-running process arrives at [onNewIntent] and is pushed
 * over a method channel instead.
 */
class MainActivity : FlutterActivity() {
    private var channel: MethodChannel? = null

    /**
     * Route the engine opens on. Flutter reads this once, before the first
     * frame, which is why the assist path has to be decided here rather than
     * after startup.
     */
    override fun getInitialRoute(): String {
        return if (isAssistIntent(intent)) ASSIST_ROUTE else "/"
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        channel = MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            CHANNEL_NAME,
        ).apply {
            setMethodCallHandler { call, result ->
                // Qualified: inside apply { } and the handler lambda, a bare
                // `this` is the MethodChannel, not the Activity.
                val context = this@MainActivity
                when (call.method) {
                    // Lets the Flutter side ask whether Horizon currently holds
                    // the assistant role, so Settings can show the real state
                    // instead of a link and a guess.
                    "isDefaultAssistant" -> result.success(
                        AssistantRole.isDefaultAssistant(context)
                    )
                    "openAssistantSettings" -> {
                        result.success(
                            AssistantRole.openAssistantSettings(context)
                        )
                    }
                    else -> result.notImplemented()
                }
            }
        }
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        // singleTop: the assist gesture reuses the running activity, so the
        // route has to be pushed rather than returned from getInitialRoute.
        if (isAssistIntent(intent)) {
            channel?.invokeMethod("openAssistant", null)
        }
    }

    private fun isAssistIntent(intent: Intent?): Boolean {
        return when (intent?.action) {
            Intent.ACTION_ASSIST,
            Intent.ACTION_VOICE_COMMAND,
            ACTION_HORIZON_ASSIST -> true
            else -> false
        }
    }

    companion object {
        const val CHANNEL_NAME = "com.miles.horizon/assistant"
        const val ASSIST_ROUTE = "/assistant?autostart=1"

        /**
         * Used by the voice interaction session to open this activity, since
         * ACTION_ASSIST from within our own process is ambiguous.
         */
        const val ACTION_HORIZON_ASSIST = "com.miles.horizon.action.ASSIST"
    }
}
