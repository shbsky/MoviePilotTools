package com.oiiqt.android.ui.components

import android.graphics.Paint
import android.graphics.Typeface
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.Path
import androidx.compose.ui.graphics.PathEffect
import androidx.compose.ui.graphics.StrokeCap
import androidx.compose.ui.graphics.StrokeJoin
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.graphics.nativeCanvas
import androidx.compose.ui.graphics.toArgb
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp

/**
 * 一条折线。
 * [filled] = 折线下方是否铺一层竖向渐变（MP 的 CPU 曲线、内存「已使用」都是这种画法）。
 */
data class LineSeries(
    val points: List<Float>,
    val color: Color,
    val filled: Boolean = false
)

/**
 * 零依赖多序列折线图（Compose Canvas）。
 *
 * 不引第三方图表库（离线 Gradle 缓存里没有），画法对齐 MoviePilot 网页仪表盘：
 * 左侧 Y 轴刻度文字 + 虚线网格 + 2dp 圆头折线 + 可选面积渐变。
 *
 * [yMax] 由调用方给（CPU 按峰值取整档、内存给总容量），保证两次采样尺度一致，
 * 不会每来一个点就把曲线重新拉伸。
 * [yLabels] 从上到下排列，数量应与 gridLines + 1 对齐；留空则不画 Y 轴文字（曲线占满宽度）。
 */
@Composable
fun MultiLineChart(
    series: List<LineSeries>,
    modifier: Modifier = Modifier,
    yMax: Float = 100f,
    gridLines: Int = 2,
    gridColor: Color = Color.Gray.copy(alpha = 0.25f),
    yLabels: List<String> = emptyList(),
    labelColor: Color = Color.Gray,
    chartHeight: Dp = 78.dp
) {
    Canvas(modifier = modifier.fillMaxWidth().height(chartHeight)) {
        val labelPx = 9.sp.toPx()
        val gutter = if (yLabels.isEmpty()) 0f else 26.dp.toPx()
        val left = gutter
        val right = size.width
        val top = 8.dp.toPx()
        val bottom = size.height - 6.dp.toPx()
        val plotHeight = (bottom - top).coerceAtLeast(1f)
        val max = yMax.coerceAtLeast(1f)

        // ---- 虚线网格 + 左侧刻度 ----
        val dash = PathEffect.dashPathEffect(floatArrayOf(4.dp.toPx(), 4.dp.toPx()), 0f)
        val labelPaint = if (yLabels.isEmpty()) null else Paint().apply {
            isAntiAlias = true
            textSize = labelPx
            color = labelColor.toArgb()
            typeface = Typeface.create(Typeface.DEFAULT, Typeface.NORMAL)
            textAlign = Paint.Align.RIGHT
        }
        for (i in 0..gridLines) {
            val y = top + plotHeight * i / gridLines
            drawLine(
                color = gridColor,
                start = Offset(left, y),
                end = Offset(right, y),
                strokeWidth = 1f,
                pathEffect = dash
            )
            val label = yLabels.getOrNull(i)
            if (label != null && labelPaint != null) {
                drawContext.canvas.nativeCanvas.drawText(
                    label,
                    left - 5.dp.toPx(),
                    y + labelPx * 0.36f,
                    labelPaint
                )
            }
        }

        val maxPoints = series.maxOfOrNull { it.points.size } ?: 0
        if (maxPoints < 2) return@Canvas

        fun xOf(index: Int): Float =
            if (maxPoints <= 1) left else left + index * (right - left) / (maxPoints - 1).toFloat()

        fun yOf(value: Float): Float =
            bottom - (value.coerceIn(0f, max) / max) * plotHeight

        series.forEach { line ->
            if (line.points.size < 2) return@forEach
            val path = Path().apply {
                line.points.forEachIndexed { index, value ->
                    if (index == 0) moveTo(xOf(index), yOf(value))
                    else lineTo(xOf(index), yOf(value))
                }
            }
            if (line.filled) {
                // 面积：把折线首尾接到基线上闭合，再用竖向渐变淡出
                val area = Path().apply {
                    addPath(path)
                    lineTo(xOf(line.points.size - 1), bottom)
                    lineTo(xOf(0), bottom)
                    close()
                }
                drawPath(
                    path = area,
                    brush = Brush.verticalGradient(
                        colors = listOf(line.color.copy(alpha = 0.30f), line.color.copy(alpha = 0.02f)),
                        startY = top,
                        endY = bottom
                    )
                )
            }
            drawPath(
                path = path,
                color = line.color,
                style = Stroke(
                    width = 2.dp.toPx(),
                    cap = StrokeCap.Round,
                    join = StrokeJoin.Round
                )
            )
        }
    }
}
