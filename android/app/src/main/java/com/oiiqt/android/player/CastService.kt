package com.oiiqt.android.player

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.IBinder
import androidx.core.app.NotificationCompat
import androidx.core.app.ServiceCompat
import com.oiiqt.android.MainActivity
import com.oiiqt.android.vm.CastController
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.launch

/**
 * 投送前台服务：DLNA 连播的「保活锁」。
 *
 * 投送是音箱在出声，手机上唯一的活是 [CastController] 的轮询协程 ——
 * 它每 2.5 秒问一次音箱「这首放完没有」，放完就推下一首。
 * 以前没有前台服务，一锁屏 MIUI/Doze 就把整个进程冻结，轮询停摆，
 * 于是「锁屏后一首放完就断，下一首不接」。
 *
 * 这个服务只负责：投送期间挂一个前台通知（顺便给个停止/切歌的入口），
 * 让系统别冻结进程。通知内容跟着 [CastController.state] 走，
 * 投送一停（casting=false）服务自己退出。
 */
class CastService : Service() {

    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate)

    override fun onCreate() {
        super.onCreate()
        createChannel()
        scope.launch {
            CastController.state.collect { st ->
                if (!st.casting) {
                    stopSelf()
                } else {
                    notify(buildNotification(st))
                }
            }
        }
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        goForeground()
        when (intent?.action) {
            ACTION_PREV -> CastController.previous()
            ACTION_NEXT -> CastController.next()
            ACTION_STOP -> CastController.stopCasting()
        }
        return START_NOT_STICKY
    }

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onDestroy() {
        scope.cancel()
        super.onDestroy()
    }

    // ------------------------------------------------------------ 内部

    private fun goForeground() {
        val notification = buildNotification(CastController.state.value)
        ServiceCompat.startForeground(
            this,
            NOTIFICATION_ID,
            notification,
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q)
                ServiceInfo.FOREGROUND_SERVICE_TYPE_MEDIA_PLAYBACK
            else 0
        )
    }

    private fun buildNotification(st: CastController.CastState): Notification {
        val device = st.active?.name ?: "设备"
        val song = st.title.ifBlank { "准备投送…" }
        val contentIntent = PendingIntent.getActivity(
            this, 0,
            Intent(this, MainActivity::class.java).apply {
                addFlags(Intent.FLAG_ACTIVITY_SINGLE_TOP)
            },
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT
        )
        return NotificationCompat.Builder(this, CHANNEL_ID)
            .setSmallIcon(com.oiiqt.android.R.drawable.ic_stat_moviepilot)
            .setContentTitle("正在投送到「$device」")
            .setContentText(song)
            .setContentIntent(contentIntent)
            .setOngoing(true)
            .setOnlyAlertOnce(true)
            .setSilent(true)
            .setCategory(NotificationCompat.CATEGORY_TRANSPORT)
            .addAction(0, "上一首", action(ACTION_PREV))
            .addAction(0, "下一首", action(ACTION_NEXT))
            .addAction(0, "停止", action(ACTION_STOP))
            .build()
    }

    private fun action(action: String): PendingIntent = PendingIntent.getService(
        this, action.hashCode(),
        Intent(this, CastService::class.java).setAction(action),
        PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT
    )

    private fun notify(notification: Notification) {
        runCatching {
            (getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager)
                .notify(NOTIFICATION_ID, notification)
        }
    }

    private fun createChannel() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val channel = NotificationChannel(
                CHANNEL_ID, "DLNA 投送", NotificationManager.IMPORTANCE_LOW
            ).apply { description = "投送音箱时显示的常驻通知" }
            (getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager)
                .createNotificationChannel(channel)
        }
    }

    private companion object {
        const val CHANNEL_ID = "dlna_cast"
        const val NOTIFICATION_ID = 42
        const val ACTION_PREV = "com.oiiqt.android.cast.PREV"
        const val ACTION_NEXT = "com.oiiqt.android.cast.NEXT"
        const val ACTION_STOP = "com.oiiqt.android.cast.STOP"
    }
}
