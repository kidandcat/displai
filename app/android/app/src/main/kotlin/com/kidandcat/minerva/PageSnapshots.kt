package com.kidandcat.minerva

import android.app.Activity
import android.graphics.Bitmap
import android.graphics.Canvas
import android.graphics.Rect
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.view.PixelCopy
import android.view.SurfaceView
import android.view.View
import android.view.ViewGroup
import android.webkit.WebView
import io.flutter.embedding.android.FlutterView
import java.io.ByteArrayOutputStream

/**
 * Snapshots of the custom pages (WebViews) on the display: Flutter cannot capture platform
 * views, so the display's snapshot tool draws these over its own capture (channel
 * minerva/webview, the same contract as on macOS).
 *
 * Pages are copied from the pixels on screen (PixelCopy), not drawn again: a page's canvas
 * and WebGL are drawn by the GPU, and View.draw into a bitmap leaves them blank.
 */
object PageSnapshots {
    /** Replies [{x, y, w, h, png}], frames in logical pixels from the top-left of the Flutter view. */
    fun capture(activity: Activity, reply: (List<Map<String, Any>>) -> Unit) {
        val root = activity.window.decorView
        val pages = mutableListOf<WebView>()
        var flutter: View? = null
        var surface: SurfaceView? = null
        fun walk(v: View) {
            if (v is FlutterView && flutter == null) flutter = v
            // Flutter's own surface, where the pages are composited (texture layer composition).
            if (v is SurfaceView && surface == null && flutter != null) surface = v
            if (v is WebView) {
                if (v.isShown && v.width > 0 && v.height > 0) pages.add(v)
                return
            }
            if (v is ViewGroup) for (i in 0 until v.childCount) walk(v.getChildAt(i))
        }
        walk(root)
        if (pages.isEmpty()) return reply(emptyList())
        val origin = IntArray(2)
        (flutter ?: root).getLocationInWindow(origin)
        val density = activity.resources.displayMetrics.density.toDouble()
        val out = mutableListOf<Map<String, Any>>()
        val main = Handler(Looper.getMainLooper())

        fun add(page: WebView, at: IntArray, bitmap: Bitmap) {
            val png = ByteArrayOutputStream()
            bitmap.compress(Bitmap.CompressFormat.PNG, 100, png)
            bitmap.recycle()
            out.add(
                mapOf(
                    "x" to (at[0] - origin[0]) / density,
                    "y" to (at[1] - origin[1]) / density,
                    "w" to page.width / density,
                    "h" to page.height / density,
                    "png" to png.toByteArray(),
                ),
            )
        }

        fun next(i: Int) {
            if (i == pages.size) return reply(out)
            val page = pages[i]
            val at = IntArray(2)
            page.getLocationInWindow(at)
            val bitmap = Bitmap.createBitmap(page.width, page.height, Bitmap.Config.ARGB_8888)
            fun drawn() {
                page.draw(Canvas(bitmap))
                add(page, at, bitmap)
                next(i + 1)
            }
            if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return drawn()
            val done = PixelCopy.OnPixelCopyFinishedListener { result ->
                if (result == PixelCopy.SUCCESS) {
                    add(page, at, bitmap)
                    next(i + 1)
                } else {
                    drawn()
                }
            }
            val s = surface
            try {
                if (s != null && s.holder.surface.isValid) {
                    val so = IntArray(2)
                    s.getLocationInWindow(so)
                    val src = Rect(at[0] - so[0], at[1] - so[1], 0, 0)
                    src.right = src.left + page.width
                    src.bottom = src.top + page.height
                    PixelCopy.request(s, src, bitmap, done, main)
                } else {
                    val src = Rect(at[0], at[1], at[0] + page.width, at[1] + page.height)
                    PixelCopy.request(activity.window, src, bitmap, done, main)
                }
            } catch (e: IllegalArgumentException) {
                drawn()
            }
        }
        next(0)
    }
}
