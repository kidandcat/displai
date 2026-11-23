package com.kidandcat.minerva

import android.Manifest
import android.content.Intent
import android.content.pm.PackageManager
import android.os.Bundle
import android.view.WindowManager
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel

/**
 * Minerva on a phone is the remote of a desktop that does all the processing. This activity
 * gives Flutter the phone's echo-cancelled mic and its speaker ([VoiceAudio], channel
 * minerva/audio, the same contract as the macOS engine) and the pairing links it is opened
 * with (channel minerva/link).
 */
class MainActivity : FlutterActivity() {
    private var audio: VoiceAudio? = null
    private var links: MethodChannel? = null
    private var initialLink: String? = null
    private var pendingStart: Pair<Int, MethodChannel.Result>? = null

    override fun onCreate(savedInstanceState: Bundle?) {
        initialLink = intent?.takeIf { it.action == Intent.ACTION_VIEW }?.dataString
        super.onCreate(savedInstanceState)
        // A remote on the table: keep the screen on while Minerva is open.
        window.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        val messenger = flutterEngine.dartExecutor.binaryMessenger
        val voice = VoiceAudio(this)
        audio = voice
        EventChannel(messenger, "minerva/audio_events").setStreamHandler(voice)
        MethodChannel(messenger, "minerva/audio").setMethodCallHandler { call, result ->
            when (call.method) {
                "start" -> {
                    val rate = call.argument<Int>("playRate") ?: 44100
                    if (checkSelfPermission(Manifest.permission.RECORD_AUDIO) == PackageManager.PERMISSION_GRANTED) {
                        startAudio(rate, result)
                    } else {
                        pendingStart?.second?.error("superseded", "a newer start call", null)
                        pendingStart = rate to result
                        requestPermissions(arrayOf(Manifest.permission.RECORD_AUDIO), MIC_REQUEST)
                    }
                }
                "play" -> {
                    val samples = call.arguments as? FloatArray
                    if (samples != null) voice.play(samples)
                    result.success(null)
                }
                "stop" -> {
                    voice.stop()
                    result.success(null)
                }
                else -> result.notImplemented()
            }
        }
        links = MethodChannel(messenger, "minerva/link").also { ch ->
            ch.setMethodCallHandler { call, result ->
                if (call.method == "initial") {
                    result.success(initialLink)
                    initialLink = null
                } else {
                    result.notImplemented()
                }
            }
        }
    }

    private fun startAudio(rate: Int, result: MethodChannel.Result) {
        try {
            result.success(audio!!.start(rate))
        } catch (e: Exception) {
            result.error("audio", e.message, null)
        }
    }

    override fun onRequestPermissionsResult(requestCode: Int, permissions: Array<out String>, grantResults: IntArray) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        if (requestCode != MIC_REQUEST) return
        val (rate, result) = pendingStart ?: return
        pendingStart = null
        if (grantResults.firstOrNull() == PackageManager.PERMISSION_GRANTED) {
            startAudio(rate, result)
        } else {
            result.error("permission", "microphone permission denied", null)
        }
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        if (intent.action == Intent.ACTION_VIEW) intent.dataString?.let { links?.invokeMethod("link", it) }
    }

    override fun onDestroy() {
        audio?.release()
        audio = null
        super.onDestroy()
    }

    private companion object {
        const val MIC_REQUEST = 7
    }
}
