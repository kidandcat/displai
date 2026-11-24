package com.kidandcat.minerva

import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.graphics.Bitmap
import android.graphics.Point
import android.net.Uri
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.provider.Settings
import android.view.WindowManager
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.ByteArrayOutputStream
import java.util.concurrent.Executors
import kotlin.math.max
import kotlin.math.min
import kotlin.math.roundToInt

/**
 * The brain's phone tools (channel minerva/phone, see lib/remote/phone_control.dart): the desktop
 * sends phone_* tool calls over the link, and they run here with [PhoneControlService] (and
 * [ScreenCapture] for screenshots before Android 11). Also the setup's status and the orb's state.
 *
 * Every result is {text, error?, png?}. x,y the brain passes and the bounds it reads are pixels
 * of the screenshot image, which is the screen scaled to at most [MAX_SIDE] on its long side.
 */
class PhoneControl(private val context: Context) : MethodChannel.MethodCallHandler {
    private val main = Handler(Looper.getMainLooper())
    private val worker = Executors.newSingleThreadExecutor()

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "status" -> result.success(status(context))
            "openAccessibilitySettings" -> {
                open(Intent(Settings.ACTION_ACCESSIBILITY_SETTINGS))
                result.success(null)
            }
            "openOverlaySettings" -> {
                if (Build.VERSION.SDK_INT >= 23) {
                    open(Intent(Settings.ACTION_MANAGE_OVERLAY_PERMISSION, Uri.parse("package:${context.packageName}")))
                }
                result.success(null)
            }
            "openAppInfo" -> {
                // Android 13+: sideloaded apps need "Allow restricted settings" here first.
                open(Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS, Uri.parse("package:${context.packageName}")))
                result.success(null)
            }
            "front" -> {
                try {
                    OrbOverlay.front(context)
                } catch (_: Exception) {
                }
                result.success(null)
            }
            "orb" -> {
                OrbOverlay.setState(context, call.arguments as? Map<*, *> ?: emptyMap<String, Any>())
                result.success(null)
            }
            "run" -> {
                val name = call.argument<String>("name") ?: ""
                val args = call.argument<Map<String, Any?>>("args") ?: emptyMap()
                var answered = false
                val reply = { text: String, png: ByteArray? ->
                    if (!answered) {
                        answered = true
                        main.post {
                            result.success(mapOf("text" to text, "error" to text.startsWith("error:"), "png" to png))
                        }
                    }
                }
                try {
                    run(name, args, reply)
                } catch (e: PhoneError) {
                    reply("error: ${e.message}", null)
                } catch (e: Exception) {
                    reply("error: $e", null)
                }
            }
            else -> result.notImplemented()
        }
    }

    private fun open(intent: Intent) = context.startActivity(intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))

    private fun service(): PhoneControlService = PhoneControlService.instance
        ?: throw PhoneError(
            "Minerva's accessibility service is off on the phone. Ask the user to turn it on: " +
                "Minerva app > settings > Phone control (Android Settings > Accessibility > Minerva)."
        )

    private fun run(name: String, args: Map<String, Any?>, reply: (String, ByteArray?) -> Unit) {
        val s = scale(context)
        fun px(key: String): Float? = (args[key] as? Number)?.toFloat()?.let { it / s.toFloat() }
        fun int(key: String): Int? = when (val v = args[key]) {
            is Number -> v.toInt()
            is String -> v.toIntOrNull()
            else -> null
        }
        when (name) {
            "phone_ui_tree" -> {
                val (text, count) = service().tree(args["all"] == true)
                val hint = if (count < 5) "\n(few accessible elements: use phone_screen and x,y)" else ""
                reply(text + hint, null)
            }
            "phone_click" -> {
                val svc = service()
                val long = args["long"] == true
                val index = int("index")
                if (index != null) {
                    svc.clickIndex(index, long) { reply(it, null) }
                    return
                }
                val x = px("x")
                val y = px("y")
                if (x == null || y == null) throw PhoneError("Give index (from phone_ui_tree) or x,y (pixels of the phone_screen image).")
                svc.tap(x, y, long) { ok ->
                    reply(
                        if (ok) "${if (long) "long-pressed" else "tapped"} image (${(x * s).roundToInt()},${(y * s).roundToInt()})"
                        else "error: the tap was cancelled",
                        null,
                    )
                }
            }
            "phone_type" -> {
                val text = args["text"] as? String ?: throw PhoneError("text is required")
                reply(service().type(text, int("index"), args["append"] == true), null)
            }
            "phone_key" -> reply(service().key(args["key"] as? String ?: throw PhoneError("key is required")), null)
            "phone_scroll" -> {
                val direction = args["direction"] as? String ?: "down"
                service().scroll(direction, int("index"), px("x"), px("y")) { reply(it, null) }
            }
            "phone_swipe" -> {
                val x1 = px("x1")
                val y1 = px("y1")
                val x2 = px("x2")
                val y2 = px("y2")
                if (x1 == null || y1 == null || x2 == null || y2 == null) throw PhoneError("x1, y1, x2 and y2 are required")
                val ms = (args["ms"] as? Number)?.toLong() ?: 300L
                service().swipe(x1, y1, x2, y2, ms) { ok -> reply(if (ok) "swiped" else "error: the swipe was cancelled", null) }
            }
            "phone_apps" -> reply(apps(), null)
            "phone_open" -> reply(openTarget(args), null)
            "phone_screen" -> screenshot(reply)
            else -> throw PhoneError("unknown phone tool $name")
        }
    }

    // ---------------------------------------------------------------- apps

    private fun launchable(): List<Pair<String, String>> {
        val pm = context.packageManager
        val intent = Intent(Intent.ACTION_MAIN).addCategory(Intent.CATEGORY_LAUNCHER)
        return pm.queryIntentActivities(intent, 0)
            .map { it.loadLabel(pm).toString() to it.activityInfo.packageName }
            .distinctBy { it.second }
            .sortedBy { it.first.lowercase() }
    }

    private fun label(pkg: String): String = try {
        val pm = context.packageManager
        pm.getApplicationLabel(pm.getApplicationInfo(pkg, 0)).toString()
    } catch (e: Exception) {
        pkg
    }

    private fun apps(): String {
        val sb = StringBuilder()
        val svc = PhoneControlService.instance
        val front = svc?.frontPackage()
        if (front != null) sb.append("In front: ${label(front)} ($front)\n")
        val recent = synchronized(PhoneControlService.recent) { PhoneControlService.recent.keys.toList().reversed() }
        if (svc == null) {
            sb.append("Recently used: unknown (the accessibility service is off)\n")
        } else if (recent.isNotEmpty()) {
            sb.append("Recently used (seen in front since the service started, newest first):\n")
            for (p in recent) sb.append("  ${label(p)} ($p)\n")
        }
        val all = launchable()
        sb.append("Installed apps (${all.size}):\n")
        for ((name, pkg) in all) sb.append("  $name ($pkg)\n")
        return sb.toString().trimEnd()
    }

    /** Opens an app (name or package), a URL or URI, or an intent; see the phone_open tool. */
    private fun openTarget(args: Map<String, Any?>): String {
        val target = (args["target"] as? String)?.trim().orEmpty()
        val action = (args["action"] as? String)?.trim()?.ifEmpty { null }
        val data = (args["data"] as? String)?.trim()?.ifEmpty { null }
        val pkg = (args["package"] as? String)?.trim()?.ifEmpty { null }
        val pm = context.packageManager
        val intent: Intent
        val what: String
        if (action != null || data != null) {
            intent = Intent(action?.let { if (it.contains('.')) it else "android.intent.action.$it" } ?: Intent.ACTION_VIEW)
            if (data != null) intent.data = Uri.parse(data)
            if (pkg != null) intent.setPackage(pkg)
            (args["extras"] as? Map<*, *>)?.forEach { (k, v) ->
                when (v) {
                    is Boolean -> intent.putExtra("$k", v)
                    is Int -> intent.putExtra("$k", v)
                    is Long -> intent.putExtra("$k", v)
                    is Double -> intent.putExtra("$k", v)
                    else -> intent.putExtra("$k", "$v")
                }
            }
            what = "intent ${intent.action}${if (data != null) " $data" else ""}"
        } else if (target.isEmpty()) {
            throw PhoneError("Give target (an app, a URL) or action/data.")
        } else if (target.startsWith("intent:")) {
            intent = Intent.parseUri(target, Intent.URI_INTENT_SCHEME)
            what = target
        } else if (pm.getLaunchIntentForPackage(target) != null) {
            intent = pm.getLaunchIntentForPackage(target)!!
            what = "${label(target)} ($target)"
        } else if (Regex("^[a-zA-Z][a-zA-Z0-9+.-]*:").containsMatchIn(target)) {
            intent = Intent(Intent.ACTION_VIEW, Uri.parse(target))
            what = target
        } else {
            val apps = launchable()
            val t = target.lowercase()
            val app = apps.firstOrNull { it.first.lowercase() == t }
                ?: apps.firstOrNull { it.first.lowercase().startsWith(t) }
                ?: apps.firstOrNull { it.first.lowercase().contains(t) }
            if (app != null) {
                intent = pm.getLaunchIntentForPackage(app.second)!!
                what = "${app.first} (${app.second})"
            } else if (target.contains('.') && !target.contains(' ')) {
                intent = Intent(Intent.ACTION_VIEW, Uri.parse("https://$target"))
                what = "https://$target"
            } else {
                throw PhoneError("No app called $target: see phone_apps.")
            }
        }
        intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        // From the service when it is on: it may start activities while Minerva is behind.
        val from: Context = PhoneControlService.instance ?: context
        try {
            from.startActivity(intent)
        } catch (e: android.content.ActivityNotFoundException) {
            throw PhoneError("Nothing on the phone opens $what.")
        }
        val handler = intent.resolveActivity(pm)?.let { c: ComponentName -> " with ${label(c.packageName)}" }.orEmpty()
        return "opened $what$handler"
    }

    // ---------------------------------------------------------------- screenshots

    private fun screenshot(reply: (String, ByteArray?) -> Unit) {
        val svc = PhoneControlService.instance
        val got = { bitmap: Bitmap?, error: String? ->
            OrbOverlay.hidden(false)
            if (bitmap == null) {
                reply("error: ${error ?: "no screenshot"}", null)
            } else {
                worker.execute {
                    val s = scale(context)
                    val w = max(1, (bitmap.width * s).roundToInt())
                    val h = max(1, (bitmap.height * s).roundToInt())
                    val small = if (w == bitmap.width) bitmap else Bitmap.createScaledBitmap(bitmap, w, h, true)
                    val out = ByteArrayOutputStream()
                    small.compress(Bitmap.CompressFormat.PNG, 100, out)
                    reply("Screenshot of the phone, $w×$h px. Pass x,y in these pixels to phone_click/phone_scroll/phone_swipe.", out.toByteArray())
                }
            }
        }
        // The orb stays out of the picture.
        OrbOverlay.hidden(true)
        main.postDelayed({
            if (svc != null && Build.VERSION.SDK_INT >= 30) {
                svc.screenshot(got)
            } else {
                ScreenCapture.capture(context, got)
            }
        }, 120)
    }

    companion object {
        /** The long side of the screenshot images, in pixels. */
        private const val MAX_SIDE = 1280.0

        fun screenSize(context: Context): Pair<Float, Float> {
            val wm = context.getSystemService(Context.WINDOW_SERVICE) as WindowManager
            return if (Build.VERSION.SDK_INT >= 30) {
                val b = wm.currentWindowMetrics.bounds
                b.width().toFloat() to b.height().toFloat()
            } else {
                val p = Point()
                @Suppress("DEPRECATION")
                wm.defaultDisplay.getRealSize(p)
                p.x.toFloat() to p.y.toFloat()
            }
        }

        /** Image pixels per screen pixel. */
        fun scale(context: Context): Double {
            val (w, h) = screenSize(context)
            return min(1.0, MAX_SIDE / max(w, h))
        }

        fun accessibilityOn(context: Context): Boolean {
            if (PhoneControlService.instance != null) return true
            val enabled = Settings.Secure.getString(context.contentResolver, Settings.Secure.ENABLED_ACCESSIBILITY_SERVICES).orEmpty()
            val me = ComponentName(context, PhoneControlService::class.java).flattenToString()
            return enabled.split(':').any { it.equals(me, ignoreCase = true) }
        }

        fun overlayOn(context: Context): Boolean = Build.VERSION.SDK_INT < 23 || Settings.canDrawOverlays(context)

        fun status(context: Context): Map<String, Any> = mapOf(
            "accessibility" to accessibilityOn(context),
            "running" to (PhoneControlService.instance != null),
            "overlay" to overlayOn(context),
            "screenshots" to when {
                Build.VERSION.SDK_INT >= 30 -> "accessibility"
                ScreenCapture.ready -> "projection"
                else -> "ask"
            },
            "sdk" to Build.VERSION.SDK_INT,
        )
    }
}
