package com.kidandcat.minerva

import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.IBinder

/**
 * Keeps the mic and the link to the desktop alive while Minerva is behind other apps (when it
 * acts on the phone, or the user leaves it): a foreground service of type microphone, started
 * with the audio (while the app is in front, as Android requires) and stopped with it.
 */
class LinkService : Service() {
    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        val n = CaptureService.notification(this, "minerva_link", "Minerva", "Minerva is listening")
        try {
            if (Build.VERSION.SDK_INT >= 30) {
                startForeground(1, n, ServiceInfo.FOREGROUND_SERVICE_TYPE_MICROPHONE)
            } else {
                startForeground(1, n)
            }
        } catch (e: Exception) {
            // Not allowed now (started from the background): the app works while it is in front.
            stopSelf()
        }
        return START_NOT_STICKY
    }

    companion object {
        fun start(context: Context) {
            val intent = Intent(context, LinkService::class.java)
            try {
                if (Build.VERSION.SDK_INT >= 26) context.startForegroundService(intent) else context.startService(intent)
            } catch (e: Exception) {
                // Background start refused: the next start from the front will do.
            }
        }

        fun stop(context: Context) {
            context.stopService(Intent(context, LinkService::class.java))
        }
    }
}
