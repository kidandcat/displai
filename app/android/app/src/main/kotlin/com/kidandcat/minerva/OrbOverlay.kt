package com.kidandcat.minerva

import android.annotation.SuppressLint
import android.content.Context
import android.content.Intent
import android.graphics.Point
import android.graphics.PixelFormat
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.os.SystemClock
import android.provider.Settings
import android.view.Gravity
import android.view.MotionEvent
import android.view.View
import android.view.ViewConfiguration
import android.view.WindowManager
import android.widget.FrameLayout
import io.flutter.FlutterInjector
import io.flutter.embedding.android.FlutterSurfaceView
import io.flutter.embedding.android.FlutterView
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.embedding.engine.dart.DartExecutor
import io.flutter.plugin.common.MethodChannel
import kotlin.math.abs

/**
 * Minerva's orb over every app while the phone is linked to the desktop and the user left
 * Minerva: the same orb as on the Mac, drawn by a second Flutter engine (`orbMain` in
 * lib/main.dart, lib/remote/phone_orb.dart) on a transparent window. Tap: back to Minerva; drag:
 * move it. The window is an app overlay: it needs "display over other apps" ([allowed]).
 */
@SuppressLint("StaticFieldLeak")
object OrbOverlay {
    private const val SIZE_DP = 88
    private const val MARGIN_DP = 12

    private val main = Handler(Looper.getMainLooper())
    private var engine: FlutterEngine? = null
    private var channel: MethodChannel? = null
    private var frame: FrameLayout? = null
    private var view: FlutterView? = null
    private var params: WindowManager.LayoutParams? = null
    private var wm: WindowManager? = null

    /** The phone is linked to the desktop (from Dart, with the orb's state). */
    private var connected = false

    /** Minerva's own screen is on top. */
    private var appVisible = false
    private var state: Map<*, *> = emptyMap<String, Any>()
    private var lastOut = 0L
    private var position: Pair<Int, Int>? = null

    fun setState(context: Context, m: Map<*, *>) {
        state = m
        connected = m["connected"] == true
        channel?.invokeMethod("state", m)
        update(context)
    }

    fun appVisible(context: Context, visible: Boolean) {
        appVisible = visible
        update(context)
    }

    /** The app may draw over other apps. */
    fun allowed(context: Context): Boolean = Build.VERSION.SDK_INT < 23 || Settings.canDrawOverlays(context)

    fun update(context: Context) {
        val want = connected && !appVisible && allowed(context)
        if (want) show(context) else hide()
        if (!connected) release()
    }

    private fun show(context: Context) {
        if (frame != null) return
        val owner: Context = context.applicationContext
        val type = if (Build.VERSION.SDK_INT >= 26) {
            WindowManager.LayoutParams.TYPE_APPLICATION_OVERLAY
        } else {
            @Suppress("DEPRECATION") WindowManager.LayoutParams.TYPE_PHONE
        }
        val manager = owner.getSystemService(Context.WINDOW_SERVICE) as WindowManager
        val eng = engine ?: createEngine(context.applicationContext)
        val density = owner.resources.displayMetrics.density
        val size = (SIZE_DP * density).toInt()
        val margin = (MARGIN_DP * density).toInt()
        val screenW = screenWidth(manager)
        val statusId = owner.resources.getIdentifier("status_bar_height", "dimen", "android")
        val statusBar = if (statusId > 0) owner.resources.getDimensionPixelSize(statusId) else 0
        val (x, y) = position ?: (screenW - size - margin to statusBar + margin)
        val p = WindowManager.LayoutParams(
            size, size, type,
            WindowManager.LayoutParams.FLAG_NOT_FOCUSABLE or WindowManager.LayoutParams.FLAG_NOT_TOUCH_MODAL or
                WindowManager.LayoutParams.FLAG_LAYOUT_NO_LIMITS,
            PixelFormat.TRANSLUCENT,
        ).apply {
            gravity = Gravity.TOP or Gravity.START
            this.x = x
            this.y = y
        }
        val flutter = FlutterView(owner, FlutterSurfaceView(owner, true))
        val f = object : FrameLayout(owner) {
            // The orb takes the touches itself (tap and drag); Flutter only draws.
            override fun onInterceptTouchEvent(ev: MotionEvent) = true

            @SuppressLint("ClickableViewAccessibility")
            override fun onTouchEvent(ev: MotionEvent) = touch(owner, ev)
        }
        f.addView(flutter, FrameLayout.LayoutParams(FrameLayout.LayoutParams.MATCH_PARENT, FrameLayout.LayoutParams.MATCH_PARENT))
        try {
            manager.addView(f, p)
        } catch (e: Exception) {
            return
        }
        flutter.attachToFlutterEngine(eng)
        eng.lifecycleChannel.appIsResumed()
        wm = manager
        frame = f
        view = flutter
        params = p
        channel?.invokeMethod("state", state)
    }

    private fun hide() {
        val f = frame ?: return
        view?.detachFromFlutterEngine()
        try {
            wm?.removeView(f)
        } catch (_: Exception) {
        }
        engine?.lifecycleChannel?.appIsPaused()
        frame = null
        view = null
        params = null
        wm = null
    }

    /** The orb's engine goes away with the link. */
    private fun release() {
        hide()
        engine?.destroy()
        engine = null
        channel = null
    }

    private fun createEngine(context: Context): FlutterEngine {
        val loader = FlutterInjector.instance().flutterLoader()
        if (!loader.initialized()) {
            loader.startInitialization(context)
            loader.ensureInitializationComplete(context, null)
        }
        val e = FlutterEngine(context)
        e.dartExecutor.executeDartEntrypoint(DartExecutor.DartEntrypoint(loader.findAppBundlePath(), "orbMain"))
        channel = MethodChannel(e.dartExecutor.binaryMessenger, "minerva/orb")
        engine = e
        return e
    }

    // ---------------------------------------------------------------- touch

    private var downX = 0f
    private var downY = 0f
    private var startX = 0
    private var startY = 0
    private var moved = false

    private fun touch(context: Context, ev: MotionEvent): Boolean {
        val p = params ?: return false
        when (ev.actionMasked) {
            MotionEvent.ACTION_DOWN -> {
                downX = ev.rawX
                downY = ev.rawY
                startX = p.x
                startY = p.y
                moved = false
            }
            MotionEvent.ACTION_MOVE -> {
                val dx = ev.rawX - downX
                val dy = ev.rawY - downY
                val slop = ViewConfiguration.get(context).scaledTouchSlop
                if (abs(dx) > slop || abs(dy) > slop) moved = true
                if (moved) {
                    p.x = startX + dx.toInt()
                    p.y = startY + dy.toInt()
                    try {
                        wm?.updateViewLayout(frame, p)
                    } catch (_: Exception) {
                    }
                }
            }
            MotionEvent.ACTION_UP -> {
                if (moved) {
                    position = p.x to p.y
                } else {
                    front(context)
                }
            }
        }
        return true
    }

    private fun screenWidth(wm: WindowManager): Int = if (Build.VERSION.SDK_INT >= 30) {
        wm.currentWindowMetrics.bounds.width()
    } else {
        val p = Point()
        @Suppress("DEPRECATION")
        wm.defaultDisplay.getRealSize(p)
        p.x
    }

    /**
     * Brings Minerva's app back to the front. From the background this needs the overlay
     * permission.
     */
    fun front(context: Context) {
        context.startActivity(
            Intent(context, MainActivity::class.java)
                .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_REORDER_TO_FRONT),
        )
    }

    /** The voice engine's events ([VoiceAudio]), so the orb moves with the voices. */
    fun audio(event: Map<String, Any>) {
        val ch = channel ?: return
        if (frame == null) return
        when (event["t"]) {
            "out" -> {
                lastOut = SystemClock.elapsedRealtime()
                ch.invokeMethod("audio", mapOf("d" to event["d"], "sr" to event["sr"]))
            }
            "mic" -> {
                // The user's voice, while Minerva's is not playing.
                if (SystemClock.elapsedRealtime() - lastOut > 300 && state["muted"] != true) {
                    ch.invokeMethod("audio", mapOf("d" to event["d"], "sr" to 16000))
                }
            }
        }
    }
}
