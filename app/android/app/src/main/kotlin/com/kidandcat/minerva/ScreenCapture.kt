package com.kidandcat.minerva

import android.app.Activity
import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.graphics.Bitmap
import android.graphics.PixelFormat
import android.hardware.display.DisplayManager
import android.hardware.display.VirtualDisplay
import android.media.Image
import android.media.ImageReader
import android.media.projection.MediaProjection
import android.media.projection.MediaProjectionManager
import android.os.Build
import android.os.Bundle
import android.os.Handler
import android.os.IBinder
import android.os.Looper

/**
 * Screenshots before Android 11, where the accessibility service cannot take them: the screen
 * is mirrored into an [ImageReader] through MediaProjection. The user allows it once per run
 * ([CaptureActivity] shows the system's prompt; up to Android 9 it has "don't show again"), and
 * [CaptureService] holds the projection, as Android 10+ requires.
 */
object ScreenCapture {
    private val main = Handler(Looper.getMainLooper())
    private var projection: MediaProjection? = null
    private var display: VirtualDisplay? = null
    private var reader: ImageReader? = null
    private var latest: Image? = null
    private var asking = false
    private val waiting = ArrayList<(Bitmap?, String?) -> Unit>()

    /** The prompt went unanswered. */
    private val unanswered = Runnable { fail("the user did not allow screen capture on the phone (yet): ask them, then retry") }

    val ready get() = projection != null

    fun capture(context: Context, done: (Bitmap?, String?) -> Unit) {
        if (projection != null) {
            done(grab(), null)
            return
        }
        waiting.add(done)
        if (asking) return
        asking = true
        context.startActivity(
            Intent(context, CaptureActivity::class.java)
                .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_NO_ANIMATION),
        )
        main.postDelayed(unanswered, 60_000)
    }

    private fun fail(why: String) {
        asking = false
        val w = waiting.toList()
        waiting.clear()
        for (cb in w) cb(null, why)
    }

    /** The user answered the system prompt. */
    fun onConsent(context: Context, code: Int, data: Intent?) {
        main.removeCallbacks(unanswered)
        if (code != Activity.RESULT_OK || data == null) {
            fail("the user declined screen capture on the phone")
            return
        }
        val intent = Intent(context, CaptureService::class.java)
            .putExtra("code", code)
            .putExtra("data", data)
        if (Build.VERSION.SDK_INT >= 26) context.startForegroundService(intent) else context.startService(intent)
    }

    /** Called by [CaptureService] once it is in the foreground. */
    fun begin(context: Context, code: Int, data: Intent) {
        val mpm = context.getSystemService(Context.MEDIA_PROJECTION_SERVICE) as MediaProjectionManager
        val p = try {
            mpm.getMediaProjection(code, data)
        } catch (e: Exception) {
            null
        }
        if (p == null) {
            fail("the screen capture could not start")
            return
        }
        val (w, h) = PhoneControl.screenSize(context)
        val dpi = context.resources.displayMetrics.densityDpi
        val r = ImageReader.newInstance(w.toInt(), h.toInt(), PixelFormat.RGBA_8888, 3)
        r.setOnImageAvailableListener({ ir ->
            val img = try {
                ir.acquireLatestImage()
            } catch (e: Exception) {
                null
            } ?: return@setOnImageAvailableListener
            latest?.close()
            latest = img
        }, main)
        p.registerCallback(object : MediaProjection.Callback() {
            override fun onStop() = stop(context)
        }, main)
        projection = p
        reader = r
        display = p.createVirtualDisplay(
            "minerva-screen", w.toInt(), h.toInt(), dpi,
            DisplayManager.VIRTUAL_DISPLAY_FLAG_AUTO_MIRROR, r.surface, null, main,
        )
        // Let the first frame arrive.
        main.postDelayed({
            asking = false
            val w2 = waiting.toList()
            waiting.clear()
            for (cb in w2) cb(grab(), null)
        }, 500)
    }

    private fun grab(): Bitmap? {
        val img = latest ?: return null
        val plane = img.planes[0]
        val pixelStride = plane.pixelStride
        val rowPadding = plane.rowStride - pixelStride * img.width
        val padded = Bitmap.createBitmap(img.width + rowPadding / pixelStride, img.height, Bitmap.Config.ARGB_8888)
        plane.buffer.rewind()
        padded.copyPixelsFromBuffer(plane.buffer)
        return if (rowPadding == 0) padded else Bitmap.createBitmap(padded, 0, 0, img.width, img.height)
    }

    fun stop(context: Context) {
        display?.release()
        display = null
        latest?.close()
        latest = null
        reader?.close()
        reader = null
        val p = projection
        projection = null
        p?.stop()
        context.stopService(Intent(context, CaptureService::class.java))
    }
}

/** Shows the system's screen capture prompt and hands the answer to [ScreenCapture]. */
class CaptureActivity : Activity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        val mpm = getSystemService(Context.MEDIA_PROJECTION_SERVICE) as MediaProjectionManager
        @Suppress("DEPRECATION")
        startActivityForResult(mpm.createScreenCaptureIntent(), 1)
    }

    @Deprecated("Deprecated in Java")
    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        @Suppress("DEPRECATION")
        super.onActivityResult(requestCode, resultCode, data)
        ScreenCapture.onConsent(applicationContext, resultCode, data)
        finish()
    }
}

/** Holds the screen capture in the foreground (required from Android 10 on). */
class CaptureService : Service() {
    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        val n = notification(this, "minerva_capture", "Minerva", "Minerva can see the screen")
        if (Build.VERSION.SDK_INT >= 29) {
            startForeground(2, n, ServiceInfo.FOREGROUND_SERVICE_TYPE_MEDIA_PROJECTION)
        } else {
            startForeground(2, n)
        }
        val code = intent?.getIntExtra("code", 0) ?: 0
        @Suppress("DEPRECATION")
        val data = intent?.getParcelableExtra<Intent>("data")
        if (data != null) ScreenCapture.begin(applicationContext, code, data)
        return START_NOT_STICKY
    }

    companion object {
        fun notification(context: Context, channel: String, name: String, text: String): Notification {
            if (Build.VERSION.SDK_INT >= 26) {
                val nm = context.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
                nm.createNotificationChannel(NotificationChannel(channel, name, NotificationManager.IMPORTANCE_LOW))
            }
            val open = android.app.PendingIntent.getActivity(
                context, 0,
                Intent(context, MainActivity::class.java).addFlags(Intent.FLAG_ACTIVITY_REORDER_TO_FRONT),
                android.app.PendingIntent.FLAG_IMMUTABLE,
            )
            val b = if (Build.VERSION.SDK_INT >= 26) Notification.Builder(context, channel) else {
                @Suppress("DEPRECATION")
                Notification.Builder(context)
            }
            return b.setSmallIcon(android.R.drawable.ic_btn_speak_now)
                .setContentTitle(name)
                .setContentText(text)
                .setContentIntent(open)
                .setOngoing(true)
                .build()
        }
    }
}
