package com.oiiqt.android.data

/**
 * 订阅设置里的固定选项表，取值与 MoviePilot 前端 `api/constants.ts` 一致。
 *
 * MP 存的是**正则字符串**（例如质量「蓝光原盘」= `Blu-?Ray.+VC-?1|...`），
 * 界面上只显示中文名，提交时把值原样带回去，两边数据完全通用。
 */
object SubscribeOptions {

    data class Option(val label: String, val value: String)

    private fun all(): Option = Option("全部", "")

    val quality: List<Option> = listOf(
        all(),
        Option("蓝光原盘", "Blu-?Ray.+VC-?1|Blu-?Ray.+AVC|UHD.+blu-?ray.+HEVC|MiniBD"),
        Option("Remux", "Remux"),
        Option("BluRay", "Blu-?Ray"),
        Option("UHD", "UHD|UltraHD"),
        Option("WEB-DL", "WEB-?DL|WEB-?RIP"),
        Option("HDTV", "HDTV"),
        Option("H265", "[Hx].?265|HEVC"),
        Option("H264", "[Hx].?264|AVC")
    )

    val resolution: List<Option> = listOf(
        all(),
        Option("4k", "4K|2160p|x2160"),
        Option("1080p", "1080[pi]|x1080"),
        Option("720p", "720[pi]|x720")
    )

    val effect: List<Option> = listOf(
        all(),
        Option("杜比视界", "Dolby[\\s.]+Vision|DOVI|[\\s.]+DV[\\s.]+"),
        Option("杜比全景声", "Dolby[\\s.]*\\+?Atmos|Atmos"),
        Option("HDR", "[\\s.]+HDR[\\s.]+|HDR10|HDR10\\+"),
        Option("SDR", "[\\s.]+SDR[\\s.]+")
    )

    /** 界面显示名：认不出的自定义值原样显示（MP 网页里手填过的老数据） */
    fun labelOf(options: List<Option>, value: String): String =
        options.firstOrNull { it.value == value }?.label ?: if (value.isBlank()) "全部" else value
}
