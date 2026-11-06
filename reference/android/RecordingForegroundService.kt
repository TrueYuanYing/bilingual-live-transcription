package com.classmate.classmate

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.Service
import android.content.Intent
import android.os.Build
import android.os.IBinder
import android.os.PowerManager
import android.app.PendingIntent

/**
 * 录音期间提高进程存活优先级的轻量前台服务。
 * 实际 PCM 采集仍由 Flutter record 插件完成，服务只负责 Android 生命周期保活。
 */
class RecordingForegroundService : Service() {
    private var wakeLock: PowerManager.WakeLock? = null
    companion object {
        const val CHANNEL_ID = "iko_listening"
        private const val NOTIFICATION_ID = 1001
        var onStartResult: ((Exception?) -> Unit)? = null
    }

    override fun onCreate() {
        super.onCreate()
        createChannel()
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        val callback = onStartResult
        onStartResult = null
        try {
            startForeground(NOTIFICATION_ID, buildNotification())
            if (wakeLock == null) acquireWakeLock()
            callback?.invoke(null)
        } catch (error: Exception) {
            android.util.Log.w("IKORecording", "Microphone service rejected", error)
            stopSelf()
            callback?.invoke(error)
        }
        return START_NOT_STICKY
    }

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onDestroy() {
        wakeLock?.let { if (it.isHeld) it.release() }
        wakeLock = null
        super.onDestroy()
    }

    private fun acquireWakeLock() {
        try {
            val power = getSystemService(POWER_SERVICE) as PowerManager
            wakeLock = power.newWakeLock(
                PowerManager.PARTIAL_WAKE_LOCK,
                "classmate:iko-listening",
            ).apply { acquire(10 * 60 * 60 * 1000L) }
        } catch (_: Exception) {
            wakeLock = null
        }
    }

    private fun createChannel() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
        val manager = getSystemService(NotificationManager::class.java)
        manager.createNotificationChannel(
            NotificationChannel(
                CHANNEL_ID,
                "IKO 听写状态",
                NotificationManager.IMPORTANCE_LOW,
            ).apply {
                description = "听写进行时保持后台运行"
                setShowBadge(false)
            },
        )
    }

    private fun buildNotification(): Notification {
        val builder = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            Notification.Builder(this, CHANNEL_ID)
        } else {
            Notification.Builder(this)
        }
        return builder
            .setSmallIcon(android.R.drawable.ic_btn_speak_now)
            .setContentTitle("IKO 正在听写")
            .setContentText("课堂预警已开启，返回 IKO 查看实时字幕")
            .setContentIntent(
                PendingIntent.getActivity(
                    this,
                    0,
                    Intent(this, MainActivity::class.java),
                    PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
                ),
            )
            .setOngoing(true)
            .setCategory(Notification.CATEGORY_SERVICE)
            .build()
    }
}
