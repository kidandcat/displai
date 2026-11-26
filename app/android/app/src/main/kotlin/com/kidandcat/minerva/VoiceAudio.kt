package com.kidandcat.minerva

import android.content.Context
import android.media.AudioAttributes
import android.media.AudioFormat
import android.media.AudioManager
import android.media.AudioRecord
import android.media.AudioTrack
import android.media.MediaRecorder
import android.media.audiofx.AcousticEchoCanceler
import android.media.audiofx.NoiseSuppressor
import android.os.Handler
import android.os.Looper
import android.os.SystemClock
import io.flutter.plugin.common.EventChannel
import java.util.concurrent.LinkedBlockingQueue
import java.util.concurrent.TimeUnit
import kotlin.math.max

/**
 * The phone's voice engine, with the same contract as the macOS one (MainFlutterWindow.swift):
 * echo-cancelled 16 kHz mic chunks ("mic"), the samples being played ("out", for the presence
 * animation) and "idle" when the playback queue drains or is stopped.
 *
 * Voice-communication mode on the loudspeaker turns on the phone's echo canceller, so the user
 * can talk over the assistant as on the desktop.
 */
class VoiceAudio(context: Context) : EventChannel.StreamHandler {
    private val audioManager = context.getSystemService(Context.AUDIO_SERVICE) as AudioManager
    private val main = Handler(Looper.getMainLooper())
    private var sink: EventChannel.EventSink? = null

    private var record: AudioRecord? = null
    private var track: AudioTrack? = null
    private var aec: AcousticEchoCanceler? = null
    private var ns: NoiseSuppressor? = null
    private var playRate = 0
    private var micThread: Thread? = null
    private var playThread: Thread? = null
    @Volatile private var running = false

    private val queue = LinkedBlockingQueue<FloatArray>()
    @Volatile private var generation = 0
    @Volatile private var playing = false

    /** When what was written to the track so far will have been heard (elapsedRealtime, ms). */
    @Volatile private var playEndsAt = 0L

    override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
        sink = events
    }

    override fun onCancel(arguments: Any?) {
        sink = null
    }

    private fun emit(event: Map<String, Any>) = main.post {
        sink?.success(event)
    }

    /** Starts (or restarts with a new playback rate) and describes the audio path. */
    @Synchronized
    fun start(rate: Int): String {
        if (running && rate == playRate) return describe()
        release()
        playRate = rate
        audioManager.mode = AudioManager.MODE_IN_COMMUNICATION
        @Suppress("DEPRECATION")
        audioManager.isSpeakerphoneOn = true

        val minRec = AudioRecord.getMinBufferSize(MIC_RATE, AudioFormat.CHANNEL_IN_MONO, AudioFormat.ENCODING_PCM_FLOAT)
        val rec = AudioRecord(
            MediaRecorder.AudioSource.VOICE_COMMUNICATION, MIC_RATE, AudioFormat.CHANNEL_IN_MONO,
            AudioFormat.ENCODING_PCM_FLOAT, max(minRec, MIC_CHUNK * 4 * 4),
        )
        if (rec.state != AudioRecord.STATE_INITIALIZED) {
            rec.release()
            throw IllegalStateException("the microphone could not be opened")
        }
        record = rec
        if (AcousticEchoCanceler.isAvailable()) {
            aec = AcousticEchoCanceler.create(rec.audioSessionId)?.also { it.enabled = true }
        }
        if (NoiseSuppressor.isAvailable()) {
            ns = NoiseSuppressor.create(rec.audioSessionId)?.also { it.enabled = true }
        }

        val format = AudioFormat.Builder()
            .setEncoding(AudioFormat.ENCODING_PCM_FLOAT)
            .setSampleRate(rate)
            .setChannelMask(AudioFormat.CHANNEL_OUT_MONO)
            .build()
        val attributes = AudioAttributes.Builder()
            .setUsage(AudioAttributes.USAGE_VOICE_COMMUNICATION)
            .setContentType(AudioAttributes.CONTENT_TYPE_SPEECH)
            .build()
        val minPlay = AudioTrack.getMinBufferSize(rate, AudioFormat.CHANNEL_OUT_MONO, AudioFormat.ENCODING_PCM_FLOAT)
        track = AudioTrack(attributes, format, max(minPlay, rate / 5 * 4), AudioTrack.MODE_STREAM, rec.audioSessionId)
            .also { it.play() }

        running = true
        rec.startRecording()
        micThread = Thread(::micLoop, "minerva-mic").also { it.start() }
        playThread = Thread(::playLoop, "minerva-play").also { it.start() }
        return describe()
    }

    private fun describe() =
        "android mic ${MIC_RATE}Hz voice-communication aec=${aec?.enabled == true} ns=${ns?.enabled == true}, " +
            "play ${playRate}Hz loudspeaker"

    private fun micLoop() {
        val rec = record ?: return
        val buf = FloatArray(MIC_CHUNK)
        while (running) {
            val n = rec.read(buf, 0, buf.size, AudioRecord.READ_BLOCKING)
            if (n <= 0) continue
            emit(mapOf("t" to "mic", "d" to buf.copyOf(n)))
        }
    }

    private fun playLoop() {
        while (running) {
            val samples = queue.poll(30, TimeUnit.MILLISECONDS)
            if (samples == null) {
                if (playing && queue.isEmpty() && SystemClock.elapsedRealtime() >= playEndsAt) {
                    playing = false
                    emit(mapOf("t" to "idle"))
                }
                continue
            }
            val gen = generation
            val t = track ?: continue
            var offset = 0
            // Small slices, so a stop() takes effect at once.
            while (offset < samples.size && running && gen == generation) {
                val n = minOf(PLAY_SLICE, samples.size - offset)
                val slice = samples.copyOfRange(offset, offset + n)
                val written = t.write(slice, 0, n, AudioTrack.WRITE_BLOCKING)
                if (written <= 0) break
                offset += written
                if (gen != generation) break
                val now = SystemClock.elapsedRealtime()
                playEndsAt = max(playEndsAt, now) + written * 1000L / playRate
                emit(mapOf("t" to "out", "d" to slice, "sr" to playRate))
            }
        }
    }

    fun play(samples: FloatArray) {
        if (!running || samples.isEmpty()) return
        playing = true
        queue.offer(samples)
    }

    /** Drops everything queued or playing (barge-in). */
    fun stop() {
        generation++
        queue.clear()
        track?.let {
            it.pause()
            it.flush()
            it.play()
        }
        playEndsAt = 0
        playing = false
        emit(mapOf("t" to "idle"))
    }

    @Synchronized
    fun release() {
        running = false
        micThread?.join(500)
        playThread?.join(500)
        micThread = null
        playThread = null
        queue.clear()
        record?.let {
            try {
                it.stop()
            } catch (_: IllegalStateException) {
            }
            it.release()
        }
        record = null
        aec?.release()
        ns?.release()
        aec = null
        ns = null
        track?.let {
            it.pause()
            it.flush()
            it.release()
        }
        track = null
        @Suppress("DEPRECATION")
        audioManager.isSpeakerphoneOn = false
        audioManager.mode = AudioManager.MODE_NORMAL
    }

    private companion object {
        const val MIC_RATE = 16000
        const val MIC_CHUNK = 512 // 32 ms
        const val PLAY_SLICE = 2048
    }
}
