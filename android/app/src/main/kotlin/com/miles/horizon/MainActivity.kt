package com.miles.horizon

import android.content.Context
import android.content.Intent
import android.os.Bundle
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.embedding.engine.FlutterEngineCache

/**
 * Single Flutter activity for the whole app, including voice mode.
 *
 * Voice mode deliberately shares this activity rather than getting its own
 * FlutterActivity: a second activity means a second Flutter engine, hence a
 * second isolate with its own ChatProvider, Hive boxes and database handle.
 *
 * The engine itself belongs to [HorizonApplication] so it survives this
 * window being swiped away. An assist launch — the gesture, or the wake word
 * bringing the app forward — is handed to Dart through
 * [HorizonApplication.requestAssist], which holds it until Dart is ready.
 */
class MainActivity : FlutterActivity() {
    /**
     * The process-wide engine from [HorizonApplication], not one of our own:
     * this window comes and goes, the engine — and the wake word running in
     * it — stays. Not destroyed with the activity, for the same reason.
     */
    override fun provideFlutterEngine(context: Context): FlutterEngine? =
        FlutterEngineCache.getInstance().get(HorizonApplication.ENGINE_ID)

    override fun shouldDestroyEngineWithHost(): Boolean = false

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        // The engine was started with "/" before this window existed, so an
        // assist launch is passed on rather than read as the initial route.
        if (isAssistIntent(intent)) HorizonApplication.requestAssist()
    }

    override fun onResume() {
        super.onResume()
        WakeLauncher.activityResumed = true
        WakeLauncher.clear(this)
    }

    override fun onPause() {
        WakeLauncher.activityResumed = false
        super.onPause()
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        // singleTop: the assist gesture reuses the running activity.
        if (isAssistIntent(intent)) HorizonApplication.requestAssist()
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

        /**
         * Used by the voice interaction session to open this activity, since
         * ACTION_ASSIST from within our own process is ambiguous.
         */
        const val ACTION_HORIZON_ASSIST = "com.miles.horizon.action.ASSIST"
    }
}
