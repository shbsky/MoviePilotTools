package com.oiiqt.android.ui.dashboard

import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.gestures.detectHorizontalDragGestures
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.Shadow
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import coil.imageLoader
import coil.request.ImageRequest
import coil.compose.rememberAsyncImagePainter
import com.oiiqt.android.data.MpMedia
import com.oiiqt.android.ui.components.softShadow
import com.oiiqt.android.ui.moviepilot.posterFallback
import com.oiiqt.android.ui.theme.LocalOiiColors
import kotlinx.coroutines.delay

/**
 * 首屏 Hero 海报轮播（对齐鸿蒙 HeroCarousel）。
 *
 * - 5 秒自动切下一张，循环播放；
 * - 左右滑动手动切换；底部小横条指示点可点；
 * - 海报按宽度铺满、居中裁切（Cover）；贴底渐变遮罩 + 左下叠字；
 * - 右上圆形按钮打开当前海报详情。
 *
 * 图片加载交给 Coil：全局 ImageLoader 已带磁盘缓存 + 豆瓣 Referer 拦截器，
 * 所以离线/弱网开 App 直接命中缓存、不空白；片单由 MpViewModel 落盘。
 *
 * 不引入 HorizontalPager（foundation-pager 未在离线依赖里），用 pointerInput 自己做横向滑动。
 */
@Composable
fun HeroCarousel(
    items: List<MpMedia>,
    onOpenDetail: (MpMedia) -> Unit,
    modifier: Modifier = Modifier
) {
    var current by remember { mutableIntStateOf(0) }
    val count = items.size
    val context = LocalContext.current
    val imageLoader = context.imageLoader

    // 鸿蒙版是 Swiper 一次性把 8 张都挂上、并行下载；这里如果只加载当前一张，
    // 弱网下一张图没下载完就已经轮到下一张，请求被取消，结果永远空白。
    // 所以片单到手后先把 backdrop + poster 全部入队预热，命中 Coil 内存/磁盘缓存即可秒显。
    LaunchedEffect(items) {
        items.asSequence()
            .flatMap { sequenceOf(it.backdropUrl, it.posterUrl) }
            .filter { it.isNotBlank() }
            .distinct()
            .forEach { url ->
                imageLoader.enqueue(ImageRequest.Builder(context).data(url).build())
            }
    }

    // count 变化（换服务器/刷新）时把下标收回合法范围
    LaunchedEffect(count) {
        if (current >= count) current = 0
    }
    // 5 秒自动轮播（多于一张才转）
    LaunchedEffect(count, current) {
        if (count > 1) {
            delay(5000L)
            current = (current + 1) % count
        }
    }

    if (count == 0) return

    val media = items[current.coerceIn(0, count - 1)]
    val primaryUrl = media.backdropUrl.ifBlank { media.posterUrl }
    // 横图（backdrop）加载失败时退到竖版海报；两者都失败才落彩色渐变。
    var usePoster by remember(media.mediaId) { mutableStateOf(false) }
    val imageUrl = if (usePoster && media.posterUrl.isNotBlank() && media.posterUrl != primaryUrl) {
        media.posterUrl
    } else {
        primaryUrl
    }
    // onError 里从横图退到竖版海报；两者都失败时下面彩色渐变兜底。
    val painter = rememberAsyncImagePainter(
        model = imageUrl,
        onError = {
            if (!usePoster && media.posterUrl.isNotBlank() && media.posterUrl != primaryUrl) {
                usePoster = true
            }
        }
    )

    val palette = LocalOiiColors.current
    Box(
        modifier
            .fillMaxWidth()
            .height(190.dp)
            // 和卡片同一套层叠柔光投影，比 Modifier.shadow 明显得多；
            // 必须在 clip 之前画，否则阴影会被圆角裁掉
            .softShadow(22.dp, intensity = 1.2f, isDark = palette.isDark)
            .clip(RoundedCornerShape(22.dp))
            .pointerInput(count) {
                // 累计水平位移，松手时按方向翻一页：比逐帧判断稳，不会一拖连翻好几张
                var totalDrag = 0f
                detectHorizontalDragGestures(
                    onDragStart = { totalDrag = 0f },
                    onDragEnd = {
                        if (count >= 2) {
                            if (totalDrag > 60f) {
                                current = (current - 1 + count) % count
                            } else if (totalDrag < -60f) {
                                current = (current + 1) % count
                            }
                        }
                        totalDrag = 0f
                    },
                    onDragCancel = { totalDrag = 0f }
                ) { _, dragAmount ->
                    totalDrag += dragAmount
                }
            }
    ) {
        // ---- 1) 海报铺满 ----
        // 底色永远先铺彩色渐变：加载中 / 失败 / 无图都不会再出现「白卡 + 黑遮罩」。
        // 图片成功后覆盖在上面，弱网首帧也不会空白。
        Box(Modifier.fillMaxSize().background(posterFallback(media.title))) {
            if (imageUrl.isNotBlank()) {
                Image(
                    painter = painter,
                    contentDescription = media.title,
                    contentScale = ContentScale.Crop,
                    modifier = Modifier.fillMaxSize()
                )
            }
        }

        // ---- 2) 贴底渐变遮罩（只压底部文字区，上半部海报保持清晰）----
        Box(
            Modifier
                .fillMaxWidth()
                .align(Alignment.BottomCenter)
                .height(120.dp)
                .background(
                    Brush.verticalGradient(
                        0f to Color.Transparent,
                        0.45f to Color(0x8C000000),
                        1f to Color(0xCC000000)
                    )
                )
        )

        // ---- 3) 左下叠字 ----
        Column(
            Modifier
                .align(Alignment.BottomStart)
                .fillMaxWidth()
                .padding(start = 18.dp, end = 56.dp, bottom = 24.dp)
        ) {
            Text(
                media.title,
                color = Color.White,
                fontSize = 18.sp,
                fontWeight = FontWeight.Bold,
                maxLines = 1,
                overflow = TextOverflow.Ellipsis,
                style = TextStyle(shadow = Shadow(Color(0x99000000), blurRadius = 6f))
            )
            Text(
                subtitleOf(media),
                color = Color(0xE6FFFFFF),
                fontSize = 11.sp,
                maxLines = 1,
                overflow = TextOverflow.Ellipsis,
                style = TextStyle(shadow = Shadow(Color(0x99000000), blurRadius = 4f))
            )
            Text(
                media.overview,
                color = Color(0xD9FFFFFF),
                fontSize = 10.sp,
                lineHeight = 14.sp,
                maxLines = 3,
                overflow = TextOverflow.Ellipsis,
                style = TextStyle(shadow = Shadow(Color(0x99000000), blurRadius = 4f))
            )
        }

        // ---- 4) 底部指示点（可点击切换）----
        Row(
            Modifier
                .align(Alignment.BottomCenter)
                .padding(bottom = 10.dp)
                .fillMaxWidth(),
            horizontalArrangement = Arrangement.Center
        ) {
            repeat(count) { idx ->
                Box(
                    Modifier
                        .width(if (idx == current) 14.dp else 6.dp)
                        .height(2.dp)
                        .clip(RoundedCornerShape(1.dp))
                        .background(if (idx == current) Color.White else Color(0x66FFFFFF))
                        .clickable { current = idx }
                )
                if (idx < count - 1) Spacer(Modifier.width(4.dp))
            }
        }

        // ---- 5) 右上圆形详情按钮 ----
        if (count > 0) {
            Box(
                Modifier
                    .align(Alignment.TopEnd)
                    .padding(top = 12.dp, end = 12.dp)
                    .size(30.dp)
                    .clip(CircleShape)
                    .background(Color(0x66000000))
                    .clickable { onOpenDetail(media) },
                contentAlignment = Alignment.Center
            ) {
                Text("›", color = Color.White, fontSize = 22.sp, fontWeight = FontWeight.Medium)
            }
        }
    }
}

private fun subtitleOf(m: MpMedia): String {
    val genre = m.genres.firstOrNull() ?: m.typeLabel
    return if (m.yearLabel.isNotBlank()) "${m.yearLabel} · $genre" else genre
}
