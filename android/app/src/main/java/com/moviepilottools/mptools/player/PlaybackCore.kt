package com.moviepilottools.mptools.player

import android.content.Context
import androidx.media3.common.AudioAttributes
import androidx.media3.common.C
import androidx.media3.exoplayer.ExoPlayer

/**
 * 进程级唯一的播放器实例。
 *
 * 前台播放服务（[MusicService]）和界面（[MusicPlayer]）必须用**同一个** ExoPlayer：
 * 锁屏通知上的暂停/下一首直接操作它，界面上的进度条也读它，两边才不会打架。
 */
object PlaybackCore {

    @Volatile
    private var instance: ExoPlayer? = null

    fun peek(): ExoPlayer? = instance

    fun player(context: Context): ExoPlayer {
        instance?.let { return it }
        synchronized(this) {
            instance?.let { return it }
            val exo = ExoPlayer.Builder(context.applicationContext).build()
            exo.setAudioAttributes(
                AudioAttributes.Builder()
                    .setUsage(C.USAGE_MEDIA)
                    .setContentType(C.AUDIO_CONTENT_TYPE_MUSIC)
                    .build(),
                /* handleAudioFocus = */ true
            )
            // 锁屏后继续播：网络唤醒锁由 ExoPlayer 自己管
            exo.setWakeMode(C.WAKE_MODE_NETWORK)
            instance = exo
            return exo
        }
    }

    fun release() {
        synchronized(this) {
            runCatching { instance?.release() }
            instance = null
        }
    }
}
