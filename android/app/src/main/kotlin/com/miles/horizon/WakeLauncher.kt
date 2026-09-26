package com.miles.horizon

import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.os.Build
import android.os.Bundle
import android.os.Handler
import android.os.Looper

/**
 * Brings Horizon Voice to the front after the wake word was heard with the
 * app in the background.
 *
 * Android blocks apps from opening an activity from the background, and a
 * foreground service doesn't change that. So, in order:
 *
 *  1. If Horizon is the device's digital assistant, ask its
 *     VoiceInteractionService for a session — exactly what the power-button
 *     long press does, and the one background launch Android grants an app
 *     by design.
 *  2. Otherwise try starting the activity anyway; some builds allow it (and
 *     "display over other apps" makes it allowed).
 *  3. If the activity still isn't in front shortly after, post a heads-up
 *     notification to tap — the wake word was heard; it just can't open the
 *     screen by itself.
 */
object WakeLauncher {
    private const val CHANNEL_ID = "horizon_wake"
    private const val NOTIFICATION_ID = 7031

    /** Set by MainActivity so a launch can be confirmed. */
    @Volatile
    var activityResumed = false

    fun open(context: Context): String {
        val app = context.applicationContext

        HorizonVoiceInteractionService.instance?.let { service ->
            try {
                service.showSession(Bundle(), 0)
                return "assistant"
            } catch (_: Throwable) {
                // Fall through to a plain launch.
            }
        }

        try {
            app.startActivity(assistIntent(app))
        } catch (_: Throwable) {
        }

        Handler(Looper.getMainLooper()).postDelayed({
            if (!activityResumed) notify(app)
        }, 900)
        return "activity"
    }

    /** Clears the tap-to-talk notification once the screen is up. */
    fun clear(context: Context) {
        val manager =
            context.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        manager.cancel(NOTIFICATION_ID)
    }

    private fun assistIntent(context: Context) =
        Intent(context, MainActivity::class.java).apply {
            action = MainActivity.ACTION_HORIZON_ASSIST
            addFlags(
                Intent.FLAG_ACTIVITY_NEW_TASK or
                    Intent.FLAG_ACTIVITY_CLEAR_TOP or
                    Intent.FLAG_ACTIVITY_SINGLE_TOP
            )
        }

    private fun notify(context: Context) {
        val manager =
            context.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            manager.createNotificationChannel(
                NotificationChannel(
                    CHANNEL_ID,
                    "Wake word",
                    NotificationManager.IMPORTANCE_HIGH,
                ).apply {
                    description = "Tap to talk after \"Hey Horizon\" was heard."
                }
            )
        }
        val tap = PendingIntent.getActivity(
            context,
            0,
            assistIntent(context),
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )
        val builder = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            android.app.Notification.Builder(context, CHANNEL_ID)
        } else {
            @Suppress("DEPRECATION")
            android.app.Notification.Builder(context)
                .setPriority(android.app.Notification.PRIORITY_HIGH)
        }
        val notification = builder
            .setSmallIcon(context.applicationInfo.icon)
            .setContentTitle("Horizon Voice")
            .setContentText("I heard you — tap to talk.")
            .setContentIntent(tap)
            .setAutoCancel(true)
            .setTimeoutAfter(15_000)
            .setCategory(android.app.Notification.CATEGORY_CALL)
            .build()
        try {
            manager.notify(NOTIFICATION_ID, notification)
        } catch (_: SecurityException) {
            // Notifications denied; nothing more this can do.
        }
    }
}
