package com.miles.horizon

import android.content.ComponentName
import android.content.Intent
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.speech.RecognitionListener
import android.speech.RecognitionService
import android.speech.SpeechRecognizer

/**
 * A recognition service that forwards to whichever real recogniser the device
 * already has.
 *
 * It exists because `android:recognitionService` is a required attribute of a
 * voice-interaction service: AOSP's VoiceInteractionServiceInfo rejects the
 * whole service without it, and Horizon then never appears in the assistant
 * picker at all.
 *
 * Horizon doesn't implement speech recognition — voice mode calls the
 * platform recogniser through the Flutter plugin. The naive stub for this
 * situation is one that always errors, but if anything ever routes the
 * system's default recogniser here (a user picking "Horizon" under voice
 * input, or an OEM tying voice input to the assistant role) that stub would
 * silently break dictation everywhere, including Horizon's own voice mode.
 * Delegating makes it harmless instead.
 */
class HorizonRecognitionService : RecognitionService() {
    private val handler = Handler(Looper.getMainLooper())
    private var delegate: SpeechRecognizer? = null

    override fun onStartListening(recognizerIntent: Intent, listener: Callback) {
        handler.post {
            val target = findDelegateComponent()
            if (target == null) {
                listener.safeError(SpeechRecognizer.ERROR_CLIENT)
                return@post
            }

            releaseDelegate()
            val recognizer = try {
                SpeechRecognizer.createSpeechRecognizer(this, target)
            } catch (_: Throwable) {
                null
            }
            if (recognizer == null) {
                listener.safeError(SpeechRecognizer.ERROR_CLIENT)
                return@post
            }

            delegate = recognizer
            recognizer.setRecognitionListener(ForwardingListener(listener))
            try {
                recognizer.startListening(recognizerIntent)
            } catch (_: Throwable) {
                listener.safeError(SpeechRecognizer.ERROR_CLIENT)
            }
        }
    }

    override fun onStopListening(listener: Callback) {
        handler.post {
            try {
                delegate?.stopListening()
            } catch (_: Throwable) {
                // Nothing useful to report; results or an error will follow.
            }
        }
    }

    override fun onCancel(listener: Callback) {
        handler.post {
            try {
                delegate?.cancel()
            } catch (_: Throwable) {
            }
            releaseDelegate()
        }
    }

    override fun onDestroy() {
        handler.post { releaseDelegate() }
        super.onDestroy()
    }

    private fun releaseDelegate() {
        try {
            delegate?.destroy()
        } catch (_: Throwable) {
        }
        delegate = null
    }

    /**
     * First installed recognition service that isn't this one. Skipping our
     * own package is the part that matters — without it, delegation would
     * recurse into this service until the stack gave out.
     */
    private fun findDelegateComponent(): ComponentName? {
        val intent = Intent(RecognitionService.SERVICE_INTERFACE)
        val services = try {
            packageManager.queryIntentServices(intent, 0)
        } catch (_: Throwable) {
            return null
        }

        for (info in services) {
            val serviceInfo = info.serviceInfo ?: continue
            if (serviceInfo.packageName == packageName) continue
            return ComponentName(serviceInfo.packageName, serviceInfo.name)
        }
        return null
    }

    /** Callback methods declare RemoteException; a dead client isn't fatal. */
    private fun Callback.safeError(code: Int) {
        try {
            error(code)
        } catch (_: Throwable) {
        }
    }

    /** Passes every event from the delegate straight back to our caller. */
    private class ForwardingListener(private val callback: Callback) :
        RecognitionListener {

        private inline fun forward(block: () -> Unit) {
            try {
                block()
            } catch (_: Throwable) {
            }
        }

        override fun onReadyForSpeech(params: Bundle?) =
            forward { callback.readyForSpeech(params) }

        override fun onBeginningOfSpeech() =
            forward { callback.beginningOfSpeech() }

        override fun onRmsChanged(rmsdB: Float) =
            forward { callback.rmsChanged(rmsdB) }

        override fun onBufferReceived(buffer: ByteArray?) =
            forward { callback.bufferReceived(buffer) }

        override fun onEndOfSpeech() = forward { callback.endOfSpeech() }

        override fun onError(error: Int) = forward { callback.error(error) }

        override fun onResults(results: Bundle?) =
            forward { callback.results(results) }

        override fun onPartialResults(partialResults: Bundle?) =
            forward { callback.partialResults(partialResults) }

        override fun onEvent(eventType: Int, params: Bundle?) = Unit
    }
}
