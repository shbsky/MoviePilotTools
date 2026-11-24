package com.moviepilottools.mptools.data

import kotlinx.serialization.Serializable

/**
 * 首屏 Hero 海报轮播的精简缓存条目。
 *
 * 只存轮播卡真正用得到的字段（标题/年份/类型/简介/海报图 + 媒体id），
 * 不直接序列化整个 MpMedia——那个 model 还有几十个搜索/详情专用字段，存进去纯浪费。
 * 图片本身交给 Coil 的磁盘缓存（全局 ImageLoader 已带），这里只缓存「片单」。
 */
@Serializable
data class HeroCacheItem(
    val mediaId: String = "",
    val title: String = "",
    val year: String = "",
    val type: String = "",
    val source: String = "",
    val overview: String = "",
    val posterUrl: String = "",
    val backdropUrl: String = "",
    val vote: Double = 0.0,
    val genres: List<String> = emptyList()
)

/** 记下属于哪台 MP 服务器，切服务器后不复用旧片单。 */
@Serializable
data class HeroCache(
    val serverKey: String = "",
    val fetchedAt: Long = 0L,
    val items: List<HeroCacheItem> = emptyList()
)

/** MpMedia → 精简缓存条目（只挑轮播卡需要的字段）。 */
fun MpMedia.toHeroCacheItem(): HeroCacheItem = HeroCacheItem(
    mediaId = mediaId,
    title = title,
    year = year,
    type = type,
    source = source,
    overview = overview,
    posterUrl = posterUrl,
    backdropUrl = backdropUrl,
    vote = vote,
    genres = genres
)

/** 缓存条目 → MpMedia（缺失字段给默认值，够轮播卡展示 + 打开详情用）。 */
fun HeroCacheItem.toMpMedia(): MpMedia = MpMedia(
    mediaId = mediaId,
    source = source,
    type = type,
    title = title,
    year = year,
    season = null,
    tmdbId = null,
    doubanId = null,
    bangumiId = null,
    posterUrl = posterUrl,
    backdropUrl = backdropUrl,
    overview = overview,
    vote = vote,
    genres = genres,
    directors = emptyList(),
    cast = emptyList(),
    releaseDate = "",
    category = ""
)
