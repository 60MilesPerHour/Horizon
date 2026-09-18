package com.miles.horizon

import android.content.ActivityNotFoundException
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.provider.Settings
import android.text.TextUtils

/**
 * Helpers for the "digital assistant app" role.
 *
 * Android has no API to request this role — [android.app.role.RoleManager]
 * deliberately excludes the assistant — so all an app can do is declare a
 * [android.service.voice.VoiceInteractionService], report whether it was
 * chosen, and take the user to the right settings screen.
 */
object AssistantRole {

    /**
     * Whether Horizon is the selected assistant.
     *
     * `Settings.Secure.assistant` holds a flattened ComponentName of the
     * chosen VoiceInteractionService, or is empty/absent when the role is
     * unset. Reading a Secure setting needs no permission; writing it does,
     * which is exactly why the app can't set this itself.
     */
    fun isDefaultAssistant(context: Context): Boolean {
        val current = try {
            Settings.Secure.getString(context.contentResolver, "assistant")
        } catch (_: Throwable) {
            null
        }
        if (TextUtils.isEmpty(current)) return false

        val component = ComponentName.unflattenFromString(current!!) ?: return false
        return component.packageName == context.packageName
    }

    /**
     * Opens the screen where the assistant is chosen, trying the most specific
     * destination first. OEMs move this around, so each fallback is a step
     * further out: assistant picker, then default-apps, then app settings.
     */
    fun openAssistantSettings(context: Context): Boolean {
        val candidates = listOf(
            // AOSP / Pixel / LineageOS: the assistant + voice input screen.
            Intent("android.settings.VOICE_INPUT_SETTINGS"),
            Intent(Settings.ACTION_MANAGE_DEFAULT_APPS_SETTINGS),
            Intent(Settings.ACTION_APPLICATION_SETTINGS),
        )

        for (intent in candidates) {
            intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            try {
                context.startActivity(intent)
                return true
            } catch (_: ActivityNotFoundException) {
                continue
            } catch (_: SecurityException) {
                continue
            }
        }
        return false
    }
}
