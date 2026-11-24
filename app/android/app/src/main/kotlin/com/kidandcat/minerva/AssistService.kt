package com.kidandcat.minerva

import android.content.Context
import android.content.Intent
import android.os.Build
import android.os.Bundle
import android.service.voice.VoiceInteractionService
import android.service.voice.VoiceInteractionSession
import android.service.voice.VoiceInteractionSessionService
import android.speech.RecognitionService
import android.speech.SpeechRecognizer

/**
 * Minerva as the phone's digital assistant (Settings > Default apps > Digital assistant app).
 * A long press on home or the assistant button shows [AssistSession], which opens
 * [MainActivity] with [MainActivity.EXTRA_ASSIST] so it starts listening right away.
 * Config: res/xml/assist_service.xml.
 */
class AssistService : VoiceInteractionService()

class AssistSessionService : VoiceInteractionSessionService() {
    override fun onNewSession(args: Bundle?): VoiceInteractionSession = AssistSession(this)
}

class AssistSession(context: Context) : VoiceInteractionSession(context) {
    override fun onShow(args: Bundle?, showFlags: Int) {
        super.onShow(args, showFlags)
        val intent = Intent(context, MainActivity::class.java)
            .putExtra(MainActivity.EXTRA_ASSIST, true)
            .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_SINGLE_TOP)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            startAssistantActivity(intent)
        } else {
            context.startActivity(intent)
        }
        // Minerva has no overlay of its own: the app is the assistant UI.
        hide()
    }
}

/**
 * The system only lists a voice interaction service that names a recognition service.
 * Speech recognition runs on the desktop, so this one just declines other apps' requests.
 */
class AssistRecognitionService : RecognitionService() {
    override fun onStartListening(recognizerIntent: Intent?, listener: Callback?) {
        listener?.error(SpeechRecognizer.ERROR_RECOGNIZER_BUSY)
    }

    override fun onStopListening(listener: Callback?) {}

    override fun onCancel(listener: Callback?) {}
}
