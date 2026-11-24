package com.moviepilottools.mptools.player

import android.app.PendingIntent
import android.content.Intent
import androidx.media3.session.MediaSession
import androidx.media3.session.MediaSessionService
import com.moviepilottools.mptools.MainActivity

/**
 * 音乐前台服务：把 [PlaybackCore] 里的 ExoPlayer 挂到 MediaSession 上。
 *
 * 作用有两个：
 *  1. 锁屏 / 通知栏出现播放控制（上一首 / 播放暂停 / 下一首 / 进度），
 *     系统不会在息屏后把播放掐掉；
 *  2. 其它蓝牙设备（耳机、车机）的播放键也能控制。
 *
 * 播放器本身不在这里释放 —— 它是进程级的单例，服务重启后继续复用。
 */
class MusicService : MediaSessionService() {

    private var session: MediaSession? = null

    override fun onCreate() {
        super.onCreate()
        val player = PlaybackCore.player(this)
        val contentIntent = PendingIntent.getActivity(
            this,
            0,
            Intent(this, MainActivity::class.java).apply {
                addFlags(Intent.FLAG_ACTIVITY_SINGLE_TOP)
            },
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT
        )
        session = MediaSession.Builder(this, player)
            .setSessionActivity(contentIntent)
            .build()
    }

    override fun onGetSession(controllerInfo: MediaSession.ControllerInfo): MediaSession? = session

    /** 从最近任务里划掉 App 时不要停播（投送/后台听歌都是常见场景） */
    override fun onTaskRemoved(rootIntent: Intent?) = Unit

    override fun onDestroy() {
        session?.release()
        session = null
        super.onDestroy()
    }
}
