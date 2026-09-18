package com.miles.horizon

import android.content.Intent
import android.os.Bundle
import android.service.voice.VoiceInteractionService
import android.service.voice.VoiceInteractionSession
import android.service.voice.VoiceInteractionSessionService

/**
 * Declaring this is what makes Horizon eligible to be the device's digital
 * assistant — the system only lists apps that expose a
 * VoiceInteractionService in the assistant picker, and only the chosen one
 * receives the power-button long press and the corner swipe.
 */
class HorizonVoiceInteractionService : VoiceInteractionService() {
    override fun onReady() {
        super.onReady()
        // Nothing to warm up: sessions are cheap because they just hand off to
        // the activity. Hotword detection is deliberately not implemented —
        // always-on listening is a large privacy cost for an app whose point
        // is that inference stays on your own hardware.
    }
}

/** Creates a session per invocation. */
class HorizonVoiceSessionService : VoiceInteractionSessionService() {
    override fun onNewSession(args: Bundle?): VoiceInteractionSession {
        return HorizonVoiceSession(this)
    }
}

/**
 * Opens Horizon's voice UI and gets out of the way.
 *
 * The session could render its own window, but that would mean a second
 * Flutter engine (or a native UI duplicating the Dart one) for no gain. It
 * launches the activity with a plain startActivity rather than
 * startVoiceActivity: voice-interaction mode changes activity lifecycle
 * behaviour and is inconsistently implemented across OEM ROMs, and none of
 * its features are used here.
 */
class HorizonVoiceSession(service: HorizonVoiceSessionService) :
    VoiceInteractionSession(service) {

    override fun onShow(args: Bundle?, showFlags: Int) {
        super.onShow(args, showFlags)

        val intent = Intent(context, MainActivity::class.java).apply {
            action = MainActivity.ACTION_HORIZON_ASSIST
            addFlags(
                Intent.FLAG_ACTIVITY_NEW_TASK or
                    Intent.FLAG_ACTIVITY_CLEAR_TOP or
                    Intent.FLAG_ACTIVITY_SINGLE_TOP
            )
        }

        try {
            context.startActivity(intent)
        } finally {
            // Dismiss the (empty) session window immediately, or it sits over
            // the activity swallowing touches.
            hide()
        }
    }
}
