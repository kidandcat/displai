package com.kidandcat.minerva

import android.accessibilityservice.AccessibilityService
import android.accessibilityservice.GestureDescription
import android.graphics.Bitmap
import android.graphics.Path
import android.graphics.Rect
import android.os.Build
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.view.Display
import android.view.accessibility.AccessibilityEvent
import android.view.accessibility.AccessibilityNodeInfo
import android.view.accessibility.AccessibilityWindowInfo

/**
 * Minerva's hands on the phone (Settings > Accessibility > Minerva): reads the UI of the app in
 * front, taps, types, presses the global keys, scrolls and swipes, and takes screenshots
 * (Android 11+; [ScreenCapture] before). [PhoneControl] runs the brain's phone tools with it.
 *
 * Coordinates the brain sees and passes are pixels of the phone's screenshot image ([scale] of
 * the screen), in phone_ui_tree too, so it never deals with the screen's density.
 * Config: res/xml/phone_control.xml.
 */
class PhoneControlService : AccessibilityService() {
    private val main = Handler(Looper.getMainLooper())

    /** Elements of the last tree, by index (1-based, as on the Mac). */
    private val nodes = ArrayList<AccessibilityNodeInfo>()

    override fun onServiceConnected() {
        super.onServiceConnected()
        instance = this
        OrbOverlay.update(this)
    }

    override fun onUnbind(intent: android.content.Intent?): Boolean {
        instance = null
        OrbOverlay.update(this)
        return super.onUnbind(intent)
    }

    override fun onDestroy() {
        instance = null
        super.onDestroy()
    }

    override fun onAccessibilityEvent(event: AccessibilityEvent?) {
        if (event?.eventType != AccessibilityEvent.TYPE_WINDOW_STATE_CHANGED) return
        val pkg = event.packageName?.toString() ?: return
        if (pkg == packageName || pkg == "com.android.systemui") return
        synchronized(recent) {
            recent.remove(pkg)
            recent[pkg] = System.currentTimeMillis()
            while (recent.size > 30) recent.remove(recent.keys.first())
        }
    }

    override fun onInterrupt() {}

    // ---------------------------------------------------------------- reading

    /** The app in front: its package, or null. */
    fun frontPackage(): String? = activeRoot()?.packageName?.toString()

    private fun activeRoot(): AccessibilityNodeInfo? =
        rootInActiveWindow ?: windows.firstOrNull { it.isActive && it.type == AccessibilityWindowInfo.TYPE_APPLICATION }?.root

    /**
     * The UI of the app in front (or of every window on screen with [all]): lines
     * `[n] Role "label" = "value" flags (x,y w×h)` in image pixels, indented by depth.
     */
    fun tree(all: Boolean): Pair<String, Int> {
        nodes.clear()
        val s = PhoneControl.scale(this)
        val lines = ArrayList<String>()
        val roots = if (all) {
            windows.sortedByDescending { it.layer }
                .filter { it.type != AccessibilityWindowInfo.TYPE_ACCESSIBILITY_OVERLAY }
                .mapNotNull { w -> w.root?.let { it to windowName(w, it) } }
        } else {
            listOfNotNull(activeRoot()?.let { it to appName(it.packageName?.toString()) })
        }
        if (roots.isEmpty()) return "No window in front to read (the screen may be locked)." to 0
        var truncated = false
        fun walk(n: AccessibilityNodeInfo, depth: Int) {
            if (nodes.size >= MAX_NODES) {
                truncated = true
                return
            }
            if (!n.isVisibleToUser) return
            val show = interesting(n)
            if (show) {
                nodes.add(n)
                lines.add("  ".repeat(depth) + "[${nodes.size}] " + describe(n, s))
            }
            for (i in 0 until n.childCount) {
                n.getChild(i)?.let { walk(it, if (show) depth + 1 else depth) }
            }
        }
        for ((root, name) in roots) {
            lines.add(name)
            walk(root, 1)
        }
        if (truncated) lines.add("… (truncated at ${nodes.size} elements)")
        return lines.joinToString("\n") to nodes.size
    }

    private fun windowName(w: AccessibilityWindowInfo, root: AccessibilityNodeInfo): String {
        val kind = when (w.type) {
            AccessibilityWindowInfo.TYPE_INPUT_METHOD -> "keyboard"
            AccessibilityWindowInfo.TYPE_SYSTEM -> "system"
            else -> "app"
        }
        val title = if (Build.VERSION.SDK_INT >= 24) w.title?.toString().orEmpty() else ""
        return "Window ($kind) ${appName(root.packageName?.toString())}${if (title.isNotEmpty()) " \"$title\"" else ""}"
    }

    private fun appName(pkg: String?): String {
        if (pkg == null) return "App"
        val label = try {
            packageManager.getApplicationLabel(packageManager.getApplicationInfo(pkg, 0)).toString()
        } catch (e: Exception) {
            pkg
        }
        return "App $label ($pkg)"
    }

    private fun interesting(n: AccessibilityNodeInfo): Boolean =
        !n.text.isNullOrBlank() || !n.contentDescription.isNullOrBlank() || hint(n).isNotEmpty() ||
            n.isClickable || n.isLongClickable || n.isEditable || n.isCheckable || n.isScrollable

    private fun hint(n: AccessibilityNodeInfo): String =
        if (Build.VERSION.SDK_INT >= 26) clip(n.hintText) else ""

    private fun describe(n: AccessibilityNodeInfo, s: Double): String {
        val role = n.className?.toString()?.substringAfterLast('.')?.ifEmpty { null } ?: "View"
        val text = clip(n.text)
        val desc = clip(n.contentDescription)
        val hint = hint(n)
        val label = desc.ifEmpty { if (n.isEditable) hint else text.ifEmpty { hint } }
        val value = when {
            n.isEditable -> if (text != hint) text else ""
            desc.isNotEmpty() && text != desc -> text
            else -> ""
        }
        val sb = StringBuilder(role)
        if (label.isNotEmpty()) sb.append(" \"").append(label).append('"')
        if (value.isNotEmpty()) sb.append(" = \"").append(value).append('"')
        if (label.isEmpty()) {
            n.viewIdResourceName?.substringAfter(":id/")?.let { sb.append(" #").append(it) }
        }
        val flags = ArrayList<String>()
        if (n.isClickable) flags.add("clickable")
        if (n.isEditable) flags.add("editable")
        if (n.isCheckable) flags.add(if (n.isChecked) "checked" else "unchecked")
        if (n.isSelected) flags.add("selected")
        if (n.isFocused) flags.add("focused")
        if (n.isScrollable) flags.add("scrollable")
        if (!n.isEnabled) flags.add("disabled")
        if (flags.isNotEmpty()) sb.append(' ').append(flags.joinToString(" "))
        val r = Rect()
        n.getBoundsInScreen(r)
        sb.append(" (${(r.left * s).toInt()},${(r.top * s).toInt()} ${(r.width() * s).toInt()}×${(r.height() * s).toInt()})")
        return sb.toString()
    }

    private fun clip(t: CharSequence?): String {
        val s = t?.toString()?.replace(Regex("\\s+"), " ")?.trim().orEmpty()
        return if (s.length > 80) s.take(79) + "…" else s
    }

    /** The element [index] of the last tree, still on screen. */
    private fun node(index: Int): AccessibilityNodeInfo {
        val n = nodes.getOrNull(index - 1) ?: throw PhoneError("Unknown element [$index]: call phone_ui_tree first.")
        if (!n.refresh() || !n.isVisibleToUser) throw PhoneError("Element [$index] is no longer on screen: call phone_ui_tree again.")
        return n
    }

    // ---------------------------------------------------------------- actions

    /** Taps (or long-presses) element [index]: its action when it has one, else a tap on it. */
    fun clickIndex(index: Int, long: Boolean, done: (String) -> Unit) {
        val n = node(index)
        val action = if (long) AccessibilityNodeInfo.ACTION_LONG_CLICK else AccessibilityNodeInfo.ACTION_CLICK
        var target: AccessibilityNodeInfo? = n
        var hops = 0
        while (target != null && hops < 4 && !(if (long) target.isLongClickable else target.isClickable)) {
            target = target.parent
            hops++
        }
        val what = describe(n, PhoneControl.scale(this))
        if (target != null && (if (long) target.isLongClickable else target.isClickable) && target.performAction(action)) {
            done("${if (long) "long-pressed" else "clicked"} [$index] $what")
            return
        }
        val r = Rect()
        n.getBoundsInScreen(r)
        tap(r.exactCenterX(), r.exactCenterY(), long) { ok ->
            done(if (ok) "${if (long) "long-pressed" else "tapped"} [$index] $what" else "error: the tap on [$index] was cancelled")
        }
    }

    /** A tap (or long press) at screen pixel [x],[y]. */
    fun tap(x: Float, y: Float, long: Boolean, done: (Boolean) -> Unit) {
        val path = Path().apply { moveTo(x, y) }
        gesture(path, if (long) 800 else 60, done)
    }

    /** A swipe between screen pixels. */
    fun swipe(x1: Float, y1: Float, x2: Float, y2: Float, ms: Long, done: (Boolean) -> Unit) {
        val path = Path().apply {
            moveTo(x1, y1)
            lineTo(x2, y2)
        }
        gesture(path, ms.coerceIn(50, 5000), done)
    }

    private fun gesture(path: Path, ms: Long, done: (Boolean) -> Unit) {
        // The orb takes no touches meanwhile, so the gesture reaches the app under it.
        OrbOverlay.passTouches(true)
        var finished = false
        fun finish(ok: Boolean) {
            if (finished) return
            finished = true
            main.postDelayed({ OrbOverlay.passTouches(false) }, 150)
            done(ok)
        }
        val g = GestureDescription.Builder()
            .addStroke(GestureDescription.StrokeDescription(path, 0, ms))
            .build()
        val sent = dispatchGesture(g, object : GestureResultCallback() {
            override fun onCompleted(gestureDescription: GestureDescription?) = finish(true)
            override fun onCancelled(gestureDescription: GestureDescription?) = finish(false)
        }, main)
        if (!sent) finish(false)
    }

    /** Puts [text] in element [index] or the focused field; a final "\n" presses the IME action. */
    fun type(text: String, index: Int?, append: Boolean): String {
        val field = if (index != null) {
            node(index)
        } else {
            findFocus(AccessibilityNodeInfo.FOCUS_INPUT)
                ?: throw PhoneError("No text field has the focus: pass index of a field from phone_ui_tree.")
        }
        var n = field
        if (!n.isEditable) {
            n = editableIn(n) ?: throw PhoneError("[${index ?: "focus"}] is not a text field.")
        }
        if (!n.isFocused) n.performAction(AccessibilityNodeInfo.ACTION_FOCUS)
        val enter = text.endsWith("\n")
        val body = text.trimEnd('\n')
        val current = n.text?.toString().orEmpty().takeIf { append && n.text != hintOf(n) }.orEmpty()
        val args = Bundle().apply {
            putCharSequence(AccessibilityNodeInfo.ACTION_ARGUMENT_SET_TEXT_CHARSEQUENCE, current + body)
        }
        if (!n.performAction(AccessibilityNodeInfo.ACTION_SET_TEXT, args)) {
            throw PhoneError("The field did not take the text.")
        }
        var note = ""
        if (enter) {
            note = if (Build.VERSION.SDK_INT >= 30 &&
                n.performAction(AccessibilityNodeInfo.AccessibilityAction.ACTION_IME_ENTER.id)
            ) {
                ", then pressed enter"
            } else {
                " (enter is not available here: click the send or search button)"
            }
        }
        return "typed ${body.length} characters into ${describe(n, PhoneControl.scale(this))}$note"
    }

    private fun hintOf(n: AccessibilityNodeInfo): CharSequence? = if (Build.VERSION.SDK_INT >= 26) n.hintText else null

    private fun editableIn(n: AccessibilityNodeInfo, depth: Int = 0): AccessibilityNodeInfo? {
        if (n.isEditable) return n
        if (depth > 4) return null
        for (i in 0 until n.childCount) {
            n.getChild(i)?.let { c -> editableIn(c, depth + 1)?.let { return it } }
        }
        return null
    }

    /** A global key: back, home, recents, notifications, quick_settings, power, lock, enter. */
    fun key(key: String): String {
        val k = key.trim().lowercase().replace(' ', '_')
        if (k == "enter" || k == "return" || k == "search" || k == "send") {
            val f = findFocus(AccessibilityNodeInfo.FOCUS_INPUT) ?: throw PhoneError("No text field has the focus.")
            if (Build.VERSION.SDK_INT < 30) throw PhoneError("Enter needs Android 11: click the send or search button instead.")
            if (!f.performAction(AccessibilityNodeInfo.AccessibilityAction.ACTION_IME_ENTER.id)) throw PhoneError("The field did not take enter.")
            return "pressed enter"
        }
        val action = when (k) {
            "back" -> GLOBAL_ACTION_BACK
            "home" -> GLOBAL_ACTION_HOME
            "recents", "recent_apps", "overview" -> GLOBAL_ACTION_RECENTS
            "notifications" -> GLOBAL_ACTION_NOTIFICATIONS
            "quick_settings" -> GLOBAL_ACTION_QUICK_SETTINGS
            "power", "power_dialog" -> GLOBAL_ACTION_POWER_DIALOG
            "lock", "lock_screen" -> if (Build.VERSION.SDK_INT >= 28) GLOBAL_ACTION_LOCK_SCREEN else -1
            "split_screen" -> GLOBAL_ACTION_TOGGLE_SPLIT_SCREEN
            else -> throw PhoneError("Unknown key $key: use back, home, recents, notifications, quick_settings, power, lock or enter.")
        }
        if (action < 0) throw PhoneError("$key needs a newer Android.")
        if (!performGlobalAction(action)) throw PhoneError("The phone did not take $key.")
        return "pressed $k"
    }

    /**
     * Scrolls element [index] (or the scrollable around it) by its accessibility action; without
     * one, swipes over the screen (or around x,y screen pixels). [direction]: which way the content
     * moves into view (down shows what is below).
     */
    fun scroll(direction: String, index: Int?, x: Float?, y: Float?, done: (String) -> Unit) {
        val dir = direction.lowercase()
        if (dir !in setOf("up", "down", "left", "right")) throw PhoneError("direction must be up, down, left or right")
        if (index != null) {
            var n: AccessibilityNodeInfo? = node(index)
            var hops = 0
            while (n != null && !n.isScrollable && hops < 6) {
                n = n.parent
                hops++
            }
            if (n != null && n.isScrollable) {
                val specific = if (Build.VERSION.SDK_INT >= 23) when (dir) {
                    "up" -> AccessibilityNodeInfo.AccessibilityAction.ACTION_SCROLL_UP.id
                    "down" -> AccessibilityNodeInfo.AccessibilityAction.ACTION_SCROLL_DOWN.id
                    "left" -> AccessibilityNodeInfo.AccessibilityAction.ACTION_SCROLL_LEFT.id
                    else -> AccessibilityNodeInfo.AccessibilityAction.ACTION_SCROLL_RIGHT.id
                } else 0
                val generic = if (dir == "down" || dir == "right") AccessibilityNodeInfo.ACTION_SCROLL_FORWARD
                else AccessibilityNodeInfo.ACTION_SCROLL_BACKWARD
                if ((specific != 0 && n.performAction(specific)) || n.performAction(generic)) {
                    done("scrolled $dir [$index]")
                    return
                }
            }
        }
        val (w, h) = PhoneControl.screenSize(this)
        var cx = x ?: (w / 2f)
        var cy = y ?: (h / 2f)
        if (index != null && x == null) {
            val r = Rect()
            nodes[index - 1].getBoundsInScreen(r)
            cx = r.exactCenterX()
            cy = r.exactCenterY()
        }
        val dy = h * 0.25f
        val dx = w * 0.3f
        // The finger moves against the content: to see what is below, it goes up.
        val (x1, y1, x2, y2) = when (dir) {
            "down" -> listOf(cx, cy + dy, cx, cy - dy)
            "up" -> listOf(cx, cy - dy, cx, cy + dy)
            "right" -> listOf(cx + dx, cy, cx - dx, cy)
            else -> listOf(cx - dx, cy, cx + dx, cy)
        }
        swipe(x1.coerceIn(1f, w - 1f), y1.coerceIn(1f, h - 1f), x2.coerceIn(1f, w - 1f), y2.coerceIn(1f, h - 1f), 350) { ok ->
            done(if (ok) "scrolled $dir by a swipe" else "error: the swipe was cancelled")
        }
    }

    // ---------------------------------------------------------------- screenshots

    /** Android 11+: a screenshot of the default display, without the orb. */
    fun screenshot(done: (Bitmap?, String?) -> Unit) {
        if (Build.VERSION.SDK_INT < 30) {
            done(null, "screenshots through accessibility need Android 11")
            return
        }
        shoot(done, retry = true)
    }

    private fun shoot(done: (Bitmap?, String?) -> Unit, retry: Boolean) {
        if (Build.VERSION.SDK_INT < 30) return
        takeScreenshot(Display.DEFAULT_DISPLAY, mainExecutor, object : TakeScreenshotCallback {
            override fun onSuccess(screenshot: ScreenshotResult) {
                val buffer = screenshot.hardwareBuffer
                val bitmap = Bitmap.wrapHardwareBuffer(buffer, screenshot.colorSpace)?.copy(Bitmap.Config.ARGB_8888, false)
                buffer.close()
                done(bitmap, if (bitmap == null) "the screenshot could not be read" else null)
            }

            override fun onFailure(errorCode: Int) {
                // At most one screenshot a second.
                if (retry && errorCode == ERROR_TAKE_SCREENSHOT_INTERVAL_TIME_SHORT) {
                    main.postDelayed({ shoot(done, retry = false) }, 1100)
                } else {
                    done(null, "the phone refused the screenshot (code $errorCode)")
                }
            }
        })
    }

    companion object {
        @Volatile
        var instance: PhoneControlService? = null

        /** Apps seen in front since the service started, oldest first. */
        val recent = LinkedHashMap<String, Long>()

        private const val MAX_NODES = 400
    }
}

class PhoneError(message: String) : Exception(message)
