package com.moviepilottools.mptools.work

import android.Manifest
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.os.Build
import androidx.core.app.NotificationCompat
import androidx.core.app.NotificationManagerCompat
import androidx.core.content.ContextCompat
import androidx.work.Constraints
import androidx.work.CoroutineWorker
import androidx.work.ExistingPeriodicWorkPolicy
import androidx.work.NetworkType
import androidx.work.PeriodicWorkRequestBuilder
import androidx.work.WorkManager
import androidx.work.WorkerParameters
import com.moviepilottools.mptools.MainActivity
import com.moviepilottools.mptools.R
import com.moviepilottools.mptools.data.AppSettings
import com.moviepilottools.mptools.data.RssRepository
import java.util.concurrent.TimeUnit

/** 后台定时检查所有 RSS 源，命中规则就自动推送下载 */
class RssWorker(context: Context, params: WorkerParameters) : CoroutineWorker(context, params) {

    override suspend fun doWork(): Result {
        val repo = RssRepository(applicationContext)
        val sources = repo.loadSources().filter { it.enabled }
        if (sources.isEmpty()) return Result.success()

        val settings = repo.loadSettings()
        val outcomes = repo.refreshAll(sources)

        if (settings.rssNotify) {
            RssNotifications.post(applicationContext, outcomes, settings)
        }
        return Result.success()
    }
}

object RssScheduler {

    private const val WORK_NAME = "moviepilottools_rss_periodic"

    /** 按设置重建后台任务；关闭后台刷新时取消已有任务 */
    fun ensure(context: Context, settings: AppSettings) {
        val manager = WorkManager.getInstance(context)
        val minutes = settings.rssRefreshMinutes
        if (!settings.rssBackground || minutes <= 0) {
            manager.cancelUniqueWork(WORK_NAME)
            return
        }

        val network = if (settings.rssWifiOnly) NetworkType.UNMETERED else NetworkType.CONNECTED
        val constraints = Constraints.Builder()
            .setRequiredNetworkType(network)
            .setRequiresCharging(settings.rssChargingOnly)
            .build()

        val request = PeriodicWorkRequestBuilder<RssWorker>(
            minutes.coerceAtLeast(15).toLong(), TimeUnit.MINUTES
        )
            .setConstraints(constraints)
            .build()

        manager.enqueueUniquePeriodicWork(
            WORK_NAME,
            ExistingPeriodicWorkPolicy.UPDATE,
            request
        )
    }

    fun cancel(context: Context) {
        WorkManager.getInstance(context).cancelUniqueWork(WORK_NAME)
    }
}

object RssNotifications {

    private const val CHANNEL_ID = "moviepilottools_rss"

    fun ensureChannel(context: Context) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
        val manager = context.getSystemService(NotificationManager::class.java) ?: return
        if (manager.getNotificationChannel(CHANNEL_ID) != null) return
        manager.createNotificationChannel(
            NotificationChannel(CHANNEL_ID, "RSS 自动下载", NotificationManager.IMPORTANCE_DEFAULT).apply {
                description = "RSS 源发现新资源并自动推送到下载器时提醒"
            }
        )
    }

    fun post(context: Context, outcomes: List<RssRepository.RefreshOutcome>, settings: AppSettings) {
        val pushed = outcomes.flatMap { it.pushed }
        val failed = outcomes.flatMap { it.failed }
        val newCount = outcomes.sumOf { it.newCount }
        if (pushed.isEmpty() && failed.isEmpty() && newCount == 0) return

        if (Build.VERSION.SDK_INT >= 33 &&
            ContextCompat.checkSelfPermission(context, Manifest.permission.POST_NOTIFICATIONS) !=
            PackageManager.PERMISSION_GRANTED
        ) return

        ensureChannel(context)

        val title = when {
            pushed.isNotEmpty() -> "已自动推送 ${pushed.size} 个资源"
            failed.isNotEmpty() -> "自动推送失败 ${failed.size} 个"
            else -> "发现 $newCount 条新资源"
        }
        val text = when {
            pushed.isNotEmpty() -> pushed.take(2).joinToString("\n") +
                if (pushed.size > 2) "\n…等 ${pushed.size} 个" else ""

            failed.isNotEmpty() -> failed.first()
            else -> outcomes.filter { it.newCount > 0 }
                .joinToString("、") { "${it.sourceName} ${it.newCount}" }
        }

        val intent = Intent(context, MainActivity::class.java).apply {
            flags = Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TOP
            putExtra("open_tab", "automation")
        }
        val pending = PendingIntent.getActivity(
            context, 1001, intent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        )

        val notification = NotificationCompat.Builder(context, CHANNEL_ID)
            .setSmallIcon(R.drawable.ic_stat_moviepilot)
            .setContentTitle(title)
            .setContentText(text.replace("\n", " "))
            .setStyle(NotificationCompat.BigTextStyle().bigText(text))
            .setAutoCancel(true)
            .setContentIntent(pending)
            .build()

        runCatching {
            NotificationManagerCompat.from(context).notify(2001, notification)
        }
    }
}
