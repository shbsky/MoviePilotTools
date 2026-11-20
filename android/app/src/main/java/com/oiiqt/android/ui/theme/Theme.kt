package com.oiiqt.android.ui.theme

import androidx.compose.foundation.isSystemInDarkTheme
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Typography
import androidx.compose.material3.darkColorScheme
import androidx.compose.material3.lightColorScheme
import androidx.compose.runtime.Composable
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.runtime.staticCompositionLocalOf
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.material3.LocalTextStyle
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp

object Palette {
    val bgLight = Color(0xFFF2F2F7)
    val cardLight = Color(0xFFFFFFFF)
    val bgDark = Color(0xFF101014)
    val cardDark = Color(0xFF1C1C1E)

    val blue = Color(0xFF0A84FF)
    val green = Color(0xFF34C759)
    val orange = Color(0xFFFF9500)
    val red = Color(0xFFFF3B30)
    val purple = Color(0xFFAF52DE)
    val indigo = Color(0xFF5E5CE6)
    val mint = Color(0xFF00C7BE)
    val pink = Color(0xFFFF2D55)
    val gray = Color(0xFF8E8E93)

    val textLight = Color(0xFF1C1C1E)
    val secondaryLight = Color(0xFF8A8A8E)
    val separatorLight = Color(0xFFE6E6EB)

    val textDark = Color(0xFFF2F2F7)
    val secondaryDark = Color(0xFF9A9AA0)
    val separatorDark = Color(0xFF2C2C30)
}

data class OiiColors(
    val background: Color,
    val card: Color,
    val textPrimary: Color,
    val textSecondary: Color,
    val separator: Color,
    val accent: Color,
    val isDark: Boolean
)

val LocalOiiColors = staticCompositionLocalOf {
    OiiColors(
        background = Palette.bgLight,
        card = Palette.cardLight,
        textPrimary = Palette.textLight,
        textSecondary = Palette.secondaryLight,
        separator = Palette.separatorLight,
        accent = Palette.blue,
        isDark = false
    )
}

@Composable
fun OiiTheme(
    darkTheme: Boolean = isSystemInDarkTheme(),
    content: @Composable () -> Unit
) {
    val colors = if (darkTheme) {
        OiiColors(
            background = Palette.bgDark,
            card = Palette.cardDark,
            textPrimary = Palette.textDark,
            textSecondary = Palette.secondaryDark,
            separator = Palette.separatorDark,
            accent = Palette.blue,
            isDark = true
        )
    } else {
        OiiColors(
            background = Palette.bgLight,
            card = Palette.cardLight,
            textPrimary = Palette.textLight,
            textSecondary = Palette.secondaryLight,
            separator = Palette.separatorLight,
            accent = Palette.blue,
            isDark = false
        )
    }

    val scheme = if (darkTheme) {
        darkColorScheme(
            primary = Palette.blue,
            background = colors.background,
            surface = colors.card,
            onSurface = colors.textPrimary,
            onBackground = colors.textPrimary,
            error = Palette.red
        )
    } else {
        lightColorScheme(
            primary = Palette.blue,
            background = colors.background,
            surface = colors.card,
            onSurface = colors.textPrimary,
            onBackground = colors.textPrimary,
            error = Palette.red
        )
    }

    CompositionLocalProvider(LocalOiiColors provides colors) {
        MaterialTheme(
            colorScheme = scheme,
            typography = OiiTypography
        ) {
            // 全局默认字重提到 Medium：Roboto Regular 在卡片小字号上偏细，
            // 各页面大量 Text 没显式写 fontWeight，靠这一层统一加粗，不用逐处改。
            CompositionLocalProvider(
                LocalTextStyle provides OiiTypography.bodyLarge.copy(fontWeight = FontWeight.Medium),
                content = content
            )
        }
    }
}

private val OiiTypography = Typography().let { base ->
    base.copy(
        displayLarge = TextStyle(fontSize = 34.sp, fontWeight = FontWeight.Bold, letterSpacing = 0.2.sp),
        titleLarge = TextStyle(fontSize = 20.sp, fontWeight = FontWeight.SemiBold),
        titleMedium = TextStyle(fontSize = 17.sp, fontWeight = FontWeight.SemiBold),
        titleSmall = TextStyle(fontSize = 15.sp, fontWeight = FontWeight.Medium),
        bodyLarge = TextStyle(fontSize = 15.sp),
        bodyMedium = TextStyle(fontSize = 14.sp),
        bodySmall = TextStyle(fontSize = 12.sp),
        labelLarge = TextStyle(fontSize = 13.sp, fontWeight = FontWeight.Medium),
        labelMedium = TextStyle(fontSize = 12.sp),
        labelSmall = TextStyle(fontSize = 11.sp)
    )
}

object Metrics {
    val cardRadius = 18.dp
    val tileRadius = 16.dp
    val pagePadding = 16.dp
    val cardGap = 12.dp
}

/**
 * 弹窗遮罩（对齐鸿蒙 GLASS_MASK = rgba(0,0,0,0.46)）。
 * 遮罩太浅时，底下页面的正文、进度条会透上来跟弹窗文字糊在一起。
 */
val GLASS_MASK = Color.Black.copy(alpha = 0.46f)

/**
 * 「准毛玻璃」卡片底色：卡片色 98% 不透明。
 * Compose 里也能上真正的模糊（Modifier.blur 会连内容一起糊，需要 RenderEffect + 单独图层），
 * 但在弹窗这种尺寸上收益很小、还容易出兼容问题；这里靠「半透明 + 描边 + 大投影」做出玻璃观感，
 * 与鸿蒙端的做法保持一致。
 */
fun glassCard(card: Color): Color = card.copy(alpha = 0.98f)

/** 次要按钮底色：文字色 6%（深色主题下自动变成淡白） */
fun ghostFill(color: Color): Color = color.copy(alpha = 0.08f)

/** 弹窗边缘的高光描边 */
fun glassBorder(color: Color): Color = color.copy(alpha = 0.08f)
