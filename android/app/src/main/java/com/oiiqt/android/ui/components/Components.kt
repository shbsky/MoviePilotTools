package com.oiiqt.android.ui.components

import androidx.compose.animation.animateColorAsState
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.gestures.detectTapGestures
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.imePadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.rounded.ArrowBack
import androidx.compose.material.icons.rounded.ArrowDownward
import androidx.compose.material.icons.rounded.ArrowUpward
import androidx.compose.material.icons.rounded.ChevronRight
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.drawBehind
import androidx.compose.ui.draw.shadow
import androidx.compose.ui.geometry.CornerRadius
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.RoundRect
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.Path
import androidx.compose.ui.graphics.Shape
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.compose.ui.window.DialogProperties
import com.oiiqt.android.data.ServerType
import com.oiiqt.android.ui.theme.GLASS_MASK
import com.oiiqt.android.ui.theme.LocalOiiColors
import com.oiiqt.android.ui.theme.Metrics
import com.oiiqt.android.ui.theme.Palette
import com.oiiqt.android.ui.theme.ghostFill
import com.oiiqt.android.ui.theme.glassBorder
import com.oiiqt.android.ui.theme.glassCard

@Composable
fun OiiCard(
    modifier: Modifier = Modifier,
    padding: androidx.compose.ui.unit.Dp = 14.dp,
    content: @Composable ColumnScopeAlias.() -> Unit
) {
    val colors = LocalOiiColors.current
    Column(
        modifier = modifier
            .clip(RoundedCornerShape(Metrics.tileRadius))
            .background(colors.card)
            .padding(padding),
        content = content
    )
}

/**
 * 立体悬浮卡片（仪表盘专用）：玻璃渐变底 + 渐变高光描边 + 双层柔阴影 + 可选彩色光斑。
 *
 * 不启用背景模糊：卡片背后是纯色页面，真模糊看不出差别还费帧；鸿蒙端
 * backgroundBlurStyle 在尺寸不受限的 Stack 里还会 native 崩溃。
 * 立体感全部由静态绘制完成，滚动时不重算。
 *
 * @param accent 非 null 时，在卡片左上角叠一枚同色柔光斑（大卡用，小卡不传）
 */
/**
 * 柔和投影（自绘，不依赖 Modifier.shadow —— 后者对半透明渐变底投不出影）。
 *
 * @param intensity 强度倍率：1f = 仪表盘标准悬浮；0.5f ≈ 一半（站点 / 种子列表用）；0f 不画
 */
fun Modifier.softShadow(
    cornerRadius: Dp,
    intensity: Float = 1f,
    isDark: Boolean = false
): Modifier {
    if (intensity <= 0f) return this
    return this.drawBehind {
        val layers = (12 * intensity).toInt().coerceAtLeast(4)
        val stepPx = 1.3.dp.toPx() * intensity
        val offsetY = 7.dp.toPx() * intensity
        val baseAlpha = (if (isDark) 0.075f else 0.052f) * intensity
        val shadowColor = if (isDark) Color.Black else Color(0xFF3B4C70)
        val r = cornerRadius.toPx()
        for (i in 0 until layers) {
            val spread = i * stepPx
            val alpha = baseAlpha * (1f - i / layers.toFloat())
            val rr = RoundRect(
                -spread,
                -spread + offsetY,
                size.width + spread,
                size.height + spread + offsetY,
                CornerRadius(r + spread)
            )
            drawPath(Path().apply { addRoundRect(rr) }, shadowColor.copy(alpha = alpha))
        }
    }
}

@Composable
fun ElevatedCard(
    modifier: Modifier = Modifier,
    padding: Dp = 14.dp,
    accent: Color? = null,
    /** true = 弱悬浮（约仪表盘的一半），给站点 / 种子这类长列表用，避免整屏阴影太重 */
    subtle: Boolean = false,
    /** 圆角（dp）：仪表盘 / MP 用默认 22，设置页这种紧凑分组用 18 */
    corner: Dp = 22.dp,
    content: @Composable ColumnScopeAlias.() -> Unit
) {
    val colors = LocalOiiColors.current
    val isDark = colors.isDark
    // 浅色走冷调：上近白、下浅蓝灰，配蓝灰投影，才有参考图那种「浮起来」的通透厚实感
    val top = if (isDark) Color(0xFF2B2B32) else Color(0xFFFCFDFF)
    val bottom = if (isDark) Color(0xFF202026) else Color(0xFFE3EBF8)
    val rimTop = if (isDark) Color.White.copy(alpha = 0.20f) else Color.White
    val rimBottom = if (isDark) Color.Black.copy(alpha = 0.50f) else Color(0xFF93A4C0).copy(alpha = 0.42f)
    val cardCorner = corner
    Column(
        modifier = modifier
            // 1) 柔和投影：多层向下偏移、由内到外渐淡的圆角矩形叠出「底部浓、四周淡」。
            //    Modifier.shadow 对半透明渐变底几乎投不出影，所以这里自己画，纯 Compose 全版本一致。
            .softShadow(cardCorner, if (subtle) 0.5f else 1f, isDark)
            .drawBehind {
                val r = cardCorner.toPx()
                // 2) 卡片本体：竖向渐变 + 顶部中心的柔光反光
                val card = Path().apply {
                    addRoundRect(RoundRect(0f, 0f, size.width, size.height, CornerRadius(r)))
                }
                drawPath(card, Brush.verticalGradient(listOf(top, bottom)))
                drawPath(
                    card,
                    brush = Brush.radialGradient(
                        colors = listOf(
                            Color.White.copy(
                                alpha = when {
                                    isDark -> 0.06f
                                    subtle -> 0.32f
                                    else -> 0.55f
                                }
                            ),
                            Color.Transparent
                        ),
                        center = Offset(size.width * 0.5f, 0f),
                        radius = size.width * 0.9f
                    )
                )
                if (accent != null) {
                    drawPath(
                        path = card,
                        brush = Brush.radialGradient(
                            colors = listOf(
                                accent.copy(alpha = if (isDark) 0.16f else 0.14f),
                                Color.Transparent
                            ),
                            center = Offset(size.width * 0.16f, 0f),
                            radius = size.width * 0.72f
                        )
                    )
                }
                // 3) 高光描边：顶亮底暗，玻璃边缘的关键
                drawPath(
                    path = card,
                    brush = Brush.verticalGradient(listOf(rimTop, Color.Transparent, rimBottom)),
                    style = Stroke(width = (if (subtle) 0.9f else 1.2f).dp.toPx())
                )
            }
            .padding(padding),
        content = content
    )
}

// 让调用方少写一层 Column，同时保留语义
typealias ColumnScopeAlias = androidx.compose.foundation.layout.ColumnScope

@Composable
fun SectionHeader(title: String, trailing: (@Composable () -> Unit)? = null) {
    val colors = LocalOiiColors.current
    Row(
        modifier = Modifier.fillMaxWidth(),
        verticalAlignment = Alignment.CenterVertically
    ) {
        Text(
            text = title,
            fontSize = 17.sp,
            fontWeight = FontWeight.SemiBold,
            color = colors.textPrimary,
            modifier = Modifier.weight(1f)
        )
        trailing?.invoke()
    }
}

@Composable
fun StatTile(
    icon: ImageVector,
    iconTint: Color,
    value: String,
    unit: String = "",
    caption: String = "",
    modifier: Modifier = Modifier
) {
    val colors = LocalOiiColors.current
    ElevatedCard(modifier = modifier, padding = 14.dp) {
        Icon(icon, contentDescription = null, tint = iconTint, modifier = Modifier.size(20.dp))
        Spacer(Modifier.height(10.dp))
        Row(verticalAlignment = Alignment.Bottom) {
            Text(
                value,
                fontSize = 22.sp,
                fontWeight = FontWeight.SemiBold,
                color = colors.textPrimary,
                maxLines = 1,
                overflow = TextOverflow.Ellipsis
            )
            if (unit.isNotEmpty()) {
                Spacer(Modifier.width(3.dp))
                Text(unit, fontSize = 12.sp, color = colors.textSecondary)
            }
        }
        if (caption.isNotEmpty()) {
            Spacer(Modifier.height(6.dp))
            Text(
                caption,
                fontSize = 12.sp,
                color = colors.textSecondary,
                maxLines = 1,
                overflow = TextOverflow.Ellipsis
            )
        }
    }
}

@Composable
fun ServerBadge(type: ServerType, size: Int = 22) {
    val bg = if (type == ServerType.QBITTORRENT) Color(0xFF2F6FED) else Color(0xFF8E44AD)
    Box(
        modifier = Modifier
            .size(size.dp)
            .clip(CircleShape)
            .background(bg),
        contentAlignment = Alignment.Center
    ) {
        Text(
            text = type.shortLabel,
            color = Color.White,
            fontSize = (size * 0.42f).sp,
            fontWeight = FontWeight.Bold
        )
    }
}

@Composable
fun TagPill(
    text: String,
    tint: Color = LocalOiiColors.current.textSecondary,
    background: Color = LocalOiiColors.current.separator,
    fontSize: Int = 11
) {
    Box(
        modifier = Modifier
            .clip(RoundedCornerShape(7.dp))
            .background(background)
            .padding(horizontal = 7.dp, vertical = 3.dp)
    ) {
        Text(text, color = tint, fontSize = fontSize.sp, maxLines = 1)
    }
}

@Composable
fun SelectablePill(
    text: String,
    selected: Boolean,
    onClick: () -> Unit
) {
    val colors = LocalOiiColors.current
    val bg by animateColorAsState(
        if (selected) colors.accent else colors.card,
        label = "pill-bg"
    )
    val fg by animateColorAsState(
        if (selected) Color.White else colors.textSecondary,
        label = "pill-fg"
    )
    Box(
        modifier = Modifier
            .clip(RoundedCornerShape(18.dp))
            .background(bg)
            .border(0.5.dp, if (selected) Color.Transparent else colors.separator, RoundedCornerShape(18.dp))
            .clickable(onClick = onClick)
            .padding(horizontal = 15.dp, vertical = 8.dp)
    ) {
        Text(text, color = fg, fontSize = 13.sp, fontWeight = if (selected) FontWeight.Medium else FontWeight.Normal)
    }
}

@Composable
fun SpeedPair(download: Long, upload: Long, divider: Boolean = true) {
    val colors = LocalOiiColors.current
    Row(verticalAlignment = Alignment.CenterVertically) {
        Icon(
            Icons.Rounded.ArrowDownward,
            contentDescription = null,
            tint = PaletteArrowDown,
            modifier = Modifier.size(12.dp)
        )
        Text(
            " ${com.oiiqt.android.data.formatBytes(download)}/s",
            fontSize = 12.sp,
            color = colors.textSecondary
        )
        Spacer(Modifier.width(8.dp))
        Icon(
            Icons.Rounded.ArrowUpward,
            contentDescription = null,
            tint = PaletteArrowUp,
            modifier = Modifier.size(12.dp)
        )
        Text(
            " ${com.oiiqt.android.data.formatBytes(upload)}/s",
            fontSize = 12.sp,
            color = colors.textSecondary
        )
    }
}

val PaletteArrowDown = Color(0xFF0A84FF)
val PaletteArrowUp = Color(0xFF34C759)

@Composable
fun ThinProgress(
    progress: Float,
    color: Color,
    modifier: Modifier = Modifier,
    height: Int = 3
) {
    val colors = LocalOiiColors.current
    Box(
        modifier = modifier
            .fillMaxWidth()
            .height(height.dp)
            .clip(RoundedCornerShape(height.dp))
            .background(colors.separator)
    ) {
        Box(
            modifier = Modifier
                .fillMaxWidth(progress.coerceIn(0f, 1f))
                .height(height.dp)
                .clip(RoundedCornerShape(height.dp))
                .background(color)
        )
    }
}

@Composable
fun Dot(color: Color, size: Int = 8) {
    Box(Modifier.size(size.dp).clip(CircleShape).background(color))
}

@Composable
fun EmptyHint(text: String, modifier: Modifier = Modifier) {
    val colors = LocalOiiColors.current
    Box(
        modifier = modifier.fillMaxWidth().padding(vertical = 40.dp),
        contentAlignment = Alignment.Center
    ) {
        Text(text, color = colors.textSecondary, fontSize = 14.sp)
    }
}

@Composable
fun DividerLine(modifier: Modifier = Modifier) {
    val colors = LocalOiiColors.current
    Box(modifier.fillMaxWidth().height(0.5.dp).background(colors.separator))
}

@Composable
fun IconValue(
    icon: ImageVector,
    value: String,
    tint: Color,
    fontSize: Int = 12
) {
    val colors = LocalOiiColors.current
    Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.Start) {
        Icon(icon, contentDescription = null, tint = tint, modifier = Modifier.size(12.dp))
        Spacer(Modifier.width(3.dp))
        Text(value, fontSize = fontSize.sp, color = colors.textSecondary, maxLines = 1)
    }
}

@Composable
fun TinyPill(text: String, background: Color, foreground: Color, fontSize: Int = 10) {
    Box(
        modifier = Modifier
            .clip(RoundedCornerShape(6.dp))
            .background(background)
            .padding(horizontal = 6.dp, vertical = 2.dp)
    ) {
        Text(text, color = foreground, fontSize = fontSize.sp, maxLines = 1)
    }
}

/**
 * 统一弹窗（对应鸿蒙端 ui/components/Common.ets 的 DialogHost）。
 *
 * 规格照「设置 → 音乐服务」那颗：
 * - 居中卡片，宽 92%，圆角 20，18dp 内边距
 * - 标题 17 + 可选副标题 11（最多 2 行）
 * - 内容区最高 [maxHeight]，超出自己滚（列表多的弹窗不会把卡片顶出屏幕）
 * - 底部「取消 / 确认」等宽两键：取消是淡灰底，确认是实心主色 + 白字；
 *   不可点时确认键变灰底灰字（不用整体降透明度，否则白字会糊成一片）
 * - 遮罩点一下就关；[busy] 时遮罩和按钮都不响应（防止提交中误触关掉）
 *
 * 为什么不用 M3 的 AlertDialog：它自带的白底 + 系统圆角跟 App 其它弹窗不是一个体系，
 * 而且不能自定义内容区最大高度，表单类弹窗会被撑满整屏。
 */
@Composable
fun OiiDialog(
    title: String,
    onDismiss: () -> Unit,
    onConfirm: () -> Unit = onDismiss,
    subtitle: String? = null,
    confirmText: String = "关闭",
    cancelText: String? = "取消",
    confirmEnabled: Boolean = true,
    destructive: Boolean = false,
    busy: Boolean = false,
    maxHeight: androidx.compose.ui.unit.Dp = 420.dp,
    content: @Composable ColumnScopeAlias.() -> Unit
) {
    val colors = LocalOiiColors.current
    val shape = RoundedCornerShape(20.dp)

    Box(Modifier.fillMaxSize()) {
        // 遮罩：点空白关闭（提交中不响应，免得进度看不见了）
        Box(
            Modifier
                .fillMaxSize()
                .background(GLASS_MASK)
                .pointerInput(busy) {
                    detectTapGestures { if (!busy) onDismiss() }
                }
        )

        Box(
            Modifier
                .fillMaxSize()
                .imePadding()
                .padding(horizontal = 16.dp),
            contentAlignment = Alignment.Center
        ) {
            Column(
                modifier = Modifier
                    .fillMaxWidth(0.92f)
                    .shadow(18.dp, shape)
                    .clip(shape)
                    .background(glassCard(colors.card))
                    .border(0.5.dp, glassBorder(colors.textPrimary), shape)
                    // 吃掉卡片上的点击，别透给遮罩把弹窗关了
                    .pointerInput(Unit) { detectTapGestures { } }
                    .padding(18.dp)
            ) {
                Text(
                    title,
                    fontSize = 17.sp,
                    fontWeight = FontWeight.Medium,
                    color = colors.textPrimary
                )
                if (!subtitle.isNullOrBlank()) {
                    Spacer(Modifier.height(4.dp))
                    Text(
                        subtitle,
                        fontSize = 11.sp,
                        color = colors.textSecondary,
                        maxLines = 2,
                        overflow = TextOverflow.Ellipsis,
                        lineHeight = 16.sp
                    )
                }
                Spacer(Modifier.height(12.dp))

                Column(
                    Modifier
                        .fillMaxWidth()
                        .heightIn(max = maxHeight)
                        .verticalScroll(rememberScrollState()),
                    content = content
                )

                Spacer(Modifier.height(16.dp))
                Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
                    if (cancelText != null) {
                        Box(
                            Modifier
                                .weight(1f)
                                .height(40.dp)
                                .clip(RoundedCornerShape(10.dp))
                                .background(ghostFill(colors.textPrimary))
                                .clickable(enabled = !busy) { onDismiss() },
                            contentAlignment = Alignment.Center
                        ) {
                            Text(cancelText, fontSize = 14.sp, color = colors.textPrimary)
                        }
                        Spacer(Modifier.width(8.dp))
                    }
                    val solid = confirmEnabled && !busy
                    Box(
                        Modifier
                            .weight(1f)
                            .height(40.dp)
                            .clip(RoundedCornerShape(10.dp))
                            .background(
                                when {
                                    !confirmEnabled -> ghostFill(colors.textPrimary)
                                    destructive -> Palette.red
                                    else -> colors.accent
                                }
                            )
                            .clickable(enabled = confirmEnabled && !busy) { onConfirm() },
                        contentAlignment = Alignment.Center
                    ) {
                        Row(verticalAlignment = Alignment.CenterVertically) {
                            if (busy) {
                                CircularProgressIndicator(
                                    color = Color.White,
                                    strokeWidth = 2.dp,
                                    modifier = Modifier.size(14.dp)
                                )
                                Spacer(Modifier.width(6.dp))
                            }
                            Text(
                                confirmText,
                                fontSize = 14.sp,
                                fontWeight = FontWeight.Medium,
                                color = if (solid) Color.White else colors.textSecondary
                            )
                        }
                    }
                }
            }
        }
    }
}

/** 弹窗里的一行可点操作（图标 + 文案 + 可选 chevron） */
@Composable
fun DialogActionRow(
    icon: ImageVector,
    label: String,
    tint: Color,
    arrow: Boolean = false,
    danger: Boolean = false,
    onClick: () -> Unit
) {
    val colors = LocalOiiColors.current
    Row(
        Modifier
            .fillMaxWidth()
            .clickable(onClick = onClick)
            .padding(horizontal = 12.dp, vertical = 12.dp),
        verticalAlignment = Alignment.CenterVertically
    ) {
        Icon(icon, contentDescription = null, tint = tint, modifier = Modifier.size(19.dp))
        Spacer(Modifier.width(12.dp))
        Text(
            label,
            fontSize = 14.sp,
            color = if (danger) Palette.red else colors.textPrimary,
            modifier = Modifier.weight(1f)
        )
        if (arrow) {
            Icon(
                Icons.Rounded.ChevronRight,
                contentDescription = null,
                tint = colors.textSecondary,
                modifier = Modifier.size(17.dp)
            )
        }
    }
}

/**
 * 与 M3 `AlertDialog` 同签名的毛玻璃版本。
 *
 * 为什么不是全都换成 [OiiDialog]：这两种弹窗的用途不同——
 * OiiDialog 是「标题 + 可滚内容 + 取消/确认」的表单弹窗，
 * 而这里是「一句话 + 一到两个按钮」的确认框。后者用 AlertDialog 的骨架最省事，
 * 但要跟上「所有弹窗统一毛玻璃」的要求，就把容器统一成
 * 半透明卡片色 + 0.5dp 高光描边 + 20dp 圆角（原来是纯白卡片 + 系统圆角）。
 *
 * 调用方只要把 `AlertDialog(` 换成 `OiiAlertDialog(`，参数一个都不用改。
 */
@Composable
fun OiiAlertDialog(
    onDismissRequest: () -> Unit,
    confirmButton: @Composable () -> Unit,
    modifier: Modifier = Modifier,
    dismissButton: (@Composable () -> Unit)? = null,
    icon: (@Composable () -> Unit)? = null,
    title: (@Composable () -> Unit)? = null,
    text: (@Composable () -> Unit)? = null,
    shape: Shape = RoundedCornerShape(20.dp),
    containerColor: Color = Color.Unspecified,
    tonalElevation: androidx.compose.ui.unit.Dp = 0.dp,
    properties: DialogProperties = DialogProperties()
) {
    val colors = LocalOiiColors.current
    AlertDialog(
        onDismissRequest = onDismissRequest,
        confirmButton = confirmButton,
        modifier = modifier.border(0.5.dp, glassBorder(colors.textPrimary), shape),
        dismissButton = dismissButton,
        icon = icon,
        title = title,
        text = text,
        shape = shape,
        containerColor = if (containerColor == Color.Unspecified) glassCard(colors.card) else containerColor,
        tonalElevation = tonalElevation,
        properties = properties
    )
}

/**
 * 整页顶栏：圆形返回钮 + 标题 + 副标题。
 *
 * 下载器的「任务详情」「种子操作」从弹窗改回整页后共用它，
 * 尺寸与站点详情页顶栏一致（34dp 圆钮 / 17sp 标题 / 11sp 副标题），避免两个页面各长一个样。
 */
@Composable
fun PageHeader(title: String, subtitle: String = "", onBack: () -> Unit) {
    val colors = LocalOiiColors.current
    Row(
        Modifier
            .fillMaxWidth()
            .padding(horizontal = Metrics.pagePadding, vertical = 8.dp),
        verticalAlignment = Alignment.CenterVertically
    ) {
        Box(
            Modifier
                .size(34.dp)
                .clip(CircleShape)
                .background(colors.card)
                .clickable(onClick = onBack),
            contentAlignment = Alignment.Center
        ) {
            Icon(
                Icons.Rounded.ArrowBack,
                contentDescription = "返回",
                tint = colors.textPrimary,
                modifier = Modifier.size(19.dp)
            )
        }
        Spacer(Modifier.width(10.dp))
        Column(Modifier.weight(1f)) {
            Text(
                title,
                fontSize = 17.sp,
                fontWeight = FontWeight.SemiBold,
                color = colors.textPrimary,
                maxLines = 1,
                overflow = TextOverflow.Ellipsis
            )
            if (subtitle.isNotBlank()) {
                Text(
                    subtitle,
                    fontSize = 11.sp,
                    color = colors.textSecondary,
                    maxLines = 1,
                    overflow = TextOverflow.Ellipsis
                )
            }
        }
    }
}
