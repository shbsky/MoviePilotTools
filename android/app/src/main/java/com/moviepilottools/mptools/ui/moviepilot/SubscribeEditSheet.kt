package com.moviepilottools.mptools.ui.moviepilot

import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
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
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.interaction.MutableInteractionSource
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.rounded.ArrowBack
import androidx.compose.material.icons.rounded.ExpandMore
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Icon
import androidx.compose.material3.Surface
import androidx.compose.material3.Switch
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalFocusManager
import androidx.compose.ui.platform.LocalSoftwareKeyboardController
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.compose.ui.window.Dialog
import androidx.compose.ui.window.DialogProperties
import com.moviepilottools.mptools.ui.components.OiiAlertDialog
import com.moviepilottools.mptools.data.MpSite
import com.moviepilottools.mptools.data.MpSubscribe
import com.moviepilottools.mptools.data.SubscribeOptions
import com.moviepilottools.mptools.ui.components.BasicField
import com.moviepilottools.mptools.ui.components.BasicFieldMulti
import com.moviepilottools.mptools.ui.components.FieldLabel
import com.moviepilottools.mptools.ui.theme.LocalMptColors
import com.moviepilottools.mptools.ui.theme.Palette

/** 用系统设置里的默认值：下载器 / 保存路径都靠空字符串表示「自动」 */
private const val AUTO = ""

/**
 * 订阅设置页，照着 MoviePilot 网页的「编辑订阅」做。
 *
 * 整页铺满（不是半屏小窗）：字段多，半屏还得来回滚半天。
 * 分两段（基础 / 进阶），控件全部是「点开选一项」或「填一行」，
 * 不做自由输入正则 —— 质量、分辨率、特效用的就是 MP 那套预设值，改完在网页上看完全一致。
 * 危险操作（取消订阅）二次确认，符合项目一贯的约定。
 */
@Composable
fun SubscribeEditSheet(
    sub: MpSubscribe,
    sites: List<MpSite>,
    /** MP「系统设置 → 订阅 → 订阅站点」里勾选的站点；null = 这台 MP 没这项设置（不限制） */
    allowedSiteIds: Set<Int>?,
    downloaders: List<String>,
    savePaths: List<String>,
    ruleGroups: List<String>,
    onDismiss: () -> Unit,
    /** 保存：交回父层执行，成功后父层关页面；失败时回调 false 让按钮恢复可点 */
    onSave: (MpSubscribe, (Boolean) -> Unit) -> Unit,
    onDelete: () -> Unit
) {
    val colors = LocalMptColors.current
    val focusManager = LocalFocusManager.current
    val keyboard = LocalSoftwareKeyboardController.current

    // 订阅只能挑系统设置里勾过的站点；已选中的老站点也留着，否则一保存就被清掉
    val siteOptions = remember(sites, allowedSiteIds, sub.id) {
        if (allowedSiteIds == null) sites
        else sites.filter { it.id in allowedSiteIds || it.id in sub.sites }
    }

    var keyword by remember(sub.id) { mutableStateOf(sub.keyword) }
    var quality by remember(sub.id) { mutableStateOf(sub.quality) }
    var resolution by remember(sub.id) { mutableStateOf(sub.resolution) }
    var effect by remember(sub.id) { mutableStateOf(sub.effect) }
    var siteIds by remember(sub.id) { mutableStateOf(sub.sites.toSet()) }
    var customInterval by remember(sub.id) { mutableStateOf(sub.searchInterval != null) }
    var intervalHours by remember(sub.id) { mutableStateOf((sub.searchInterval ?: 24).toString()) }
    var downloader by remember(sub.id) { mutableStateOf(sub.downloader) }
    var savePath by remember(sub.id) { mutableStateOf(sub.savePath) }
    var bestVersion by remember(sub.id) { mutableStateOf(sub.bestVersion) }
    var searchImdbId by remember(sub.id) { mutableStateOf(sub.searchImdbId) }
    var include by remember(sub.id) { mutableStateOf(sub.include) }
    var exclude by remember(sub.id) { mutableStateOf(sub.exclude) }
    var ruleGroupSet by remember(sub.id) { mutableStateOf(sub.filterGroups.toSet()) }
    var mediaCategory by remember(sub.id) { mutableStateOf(sub.mediaCategory) }
    var customWords by remember(sub.id) { mutableStateOf(sub.customWords) }

    var tab by remember(sub.id) { mutableStateOf(0) }
    var picker by remember { mutableStateOf<Picker?>(null) }
    var confirmDelete by remember { mutableStateOf(false) }
    var submitting by remember(sub.id) { mutableStateOf(false) }

    /** 选完值就收键盘，不然下一层的选择框会被输入法压住 */
    fun hideKeyboard() {
        focusManager.clearFocus()
        keyboard?.hide()
    }

    /*
     * 全屏覆盖层，照 MpServerEditScreen 的写法直接铺在调用处，不再套 Dialog。
     * 之前用全屏 Dialog 装这一页，坑在窗口高度：Dialog 窗口是 WRAP_CONTENT，
     * 靠 setLayout(MATCH_PARENT) 强行拉满并不保证生效（机型/系统时序不同），
     * 一旦没生效，中间那段的 weight(1f) 就分不到高度，内容按自然高度往下排，
     * 底部「取消订阅 / 保存」直接被顶出屏幕，而且整页还滚不动。
     * 铺在 Activity 内容区里高度由父级决定，weight 一定成立。
     * 返回键由 MoviePilotScreen 的 BackHandler 统一处理，这里不必再拦。
     */
    // 这一页是铺在订阅列表之上的普通 Composable，不是 Dialog：
    // 空 clickable 不显示水波纹，只负责把落到空白处的触摸吃掉，别让下层的列表跟着滚。
    val absorbTouch = remember { MutableInteractionSource() }
    Surface(
        Modifier
            .fillMaxSize()
            .clickable(interactionSource = absorbTouch, indication = null) {},
        color = colors.background
    ) {
        Column(
            Modifier
                .fillMaxSize()
                // 外层是内容区 Box（已在状态栏之下、Tab 栏之上），这里不能再加
                // statusBarsPadding / navigationBarsPadding，否则上下各多出一截留白
                .imePadding()
                .padding(horizontal = 16.dp)
        ) {
            // 顶部：返回 + 标题（半屏小窗没有返回，铺满后必须有）
            Row(verticalAlignment = Alignment.CenterVertically) {
                Icon(
                    Icons.Rounded.ArrowBack,
                    "返回",
                    tint = colors.textPrimary,
                    modifier = Modifier
                        .size(24.dp)
                        .clickable { hideKeyboard(); onDismiss() }
                )
                Spacer(Modifier.width(10.dp))
                Column(Modifier.weight(1f)) {
                    Text("编辑订阅", fontSize = 17.sp, fontWeight = FontWeight.SemiBold, color = colors.textPrimary)
                    Text(
                        sub.name + if (sub.season != null && sub.season > 0) " S${sub.season}" else "",
                        fontSize = 11.sp,
                        color = colors.textSecondary,
                        maxLines = 1,
                        overflow = TextOverflow.Ellipsis
                    )
                }
            }

            // 分页：和 MP 网页一样「基础 / 进阶」
            Row(Modifier.padding(top = 12.dp), horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                TabChip("基础", tab == 0) { hideKeyboard(); tab = 0 }
                TabChip("进阶", tab == 1) { hideKeyboard(); tab = 1 }
            }

            // 字段区：占满剩余高度，自己滚；键盘弹出时仍能滚到当前输入框
            Column(
                Modifier
                    .weight(1f)
                    .verticalScroll(rememberScrollState())
            ) {
                if (tab == 0) {
                    Spacer(Modifier.height(9.dp))
                    FieldLabel("搜索关键词")
                    Spacer(Modifier.height(6.dp))
                    BasicField(keyword, "留空用订阅名称搜索") { keyword = it }
                    Hint("指定搜索站点时使用的关键词")

                    Spacer(Modifier.height(9.dp))
                    Row(horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                        Column(Modifier.weight(1f)) {
                            FieldLabel("质量")
                            Spacer(Modifier.height(6.dp))
                            PickerField(SubscribeOptions.labelOf(SubscribeOptions.quality, quality)) {
                                hideKeyboard()
                                picker = Picker(
                                    title = "质量",
                                    options = SubscribeOptions.quality.map { it.label to it.value },
                                    selected = listOf(quality)
                                ) { values -> quality = values.firstOrNull().orEmpty() }
                            }
                        }
                        Column(Modifier.weight(1f)) {
                            FieldLabel("分辨率")
                            Spacer(Modifier.height(6.dp))
                            PickerField(SubscribeOptions.labelOf(SubscribeOptions.resolution, resolution)) {
                                hideKeyboard()
                                picker = Picker(
                                    title = "分辨率",
                                    options = SubscribeOptions.resolution.map { it.label to it.value },
                                    selected = listOf(resolution)
                                ) { values -> resolution = values.firstOrNull().orEmpty() }
                            }
                        }
                    }

                    Spacer(Modifier.height(9.dp))
                    FieldLabel("特效")
                    Spacer(Modifier.height(6.dp))
                    PickerField(SubscribeOptions.labelOf(SubscribeOptions.effect, effect)) {
                        hideKeyboard()
                        picker = Picker(
                            title = "特效",
                            options = SubscribeOptions.effect.map { it.label to it.value },
                            selected = listOf(effect)
                        ) { values -> effect = values.firstOrNull().orEmpty() }
                    }
                    Hint("不选表示不限")

                    Spacer(Modifier.height(9.dp))
                    FieldLabel("订阅站点")
                    Spacer(Modifier.height(6.dp))
                    PickerField(
                        when {
                            siteOptions.isEmpty() -> "系统设置里未勾选订阅站点"
                            siteIds.isEmpty() -> "不选使用系统设置"
                            // 带个数：一眼确认多选真的生效（鸿蒙那边同款文案）
                            else -> {
                                val names = siteIds.mapNotNull { id ->
                                    siteOptions.firstOrNull { it.id == id }?.name
                                }.joinToString("、")
                                if (names.isBlank()) "已选 ${siteIds.size} 个站点"
                                else "已选 ${siteIds.size} 个：$names"
                            }
                        }
                    ) {
                        hideKeyboard()
                        picker = Picker(
                            title = "订阅站点",
                            options = siteOptions.map { it.name to it.id.toString() },
                            selected = siteIds.map { it.toString() },
                            multi = true,
                            searchable = true
                        ) { values -> siteIds = values.mapNotNull { it.toIntOrNull() }.toSet() }
                    }
                    Hint(
                        if (siteOptions.isEmpty()) {
                            "先去 MoviePilot 网页「系统设置 → 订阅 → 订阅站点」勾选站点"
                        } else {
                            "只列出系统设置里勾选的订阅站点"
                        }
                    )

                    Spacer(Modifier.height(9.dp))
                    FieldLabel("搜索周期")
                    Spacer(Modifier.height(6.dp))
                    PickerField(if (customInterval) "自定义" else "跟随系统") {
                        hideKeyboard()
                        picker = Picker(
                            title = "搜索周期",
                            options = listOf("跟随系统" to "system", "自定义" to "custom"),
                            selected = listOf(if (customInterval) "custom" else "system")
                        ) { values ->
                            customInterval = values.firstOrNull() == "custom"
                        }
                    }
                    if (customInterval) {
                        Spacer(Modifier.height(8.dp))
                        BasicField(
                            intervalHours,
                            "每隔多少小时搜索一次",
                            keyboardType = KeyboardType.Number
                        ) { intervalHours = it.filter { ch -> ch.isDigit() }.take(4) }
                    }
                    Hint("仅在开启定时搜索时生效，手动搜索和 RSS 刷新不受影响")

                    Spacer(Modifier.height(9.dp))
                    FieldLabel("下载器 / 保存路径")
                    Spacer(Modifier.height(6.dp))
                    Row(horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                        Column(Modifier.weight(1f)) {
                            PickerField(downloader.ifBlank { "自动" }) {
                                hideKeyboard()
                                picker = Picker(
                                    title = "下载器",
                                    options = listOf("自动（用系统设置）" to AUTO) +
                                        downloaders.map { it to it },
                                    selected = listOf(downloader)
                                ) { values -> downloader = values.firstOrNull().orEmpty() }
                            }
                        }
                        Column(Modifier.weight(1f)) {
                            PickerField(savePath.ifBlank { "自动" }) {
                                hideKeyboard()
                                picker = Picker(
                                    title = "保存路径",
                                    options = listOf("自动（用系统设置）" to AUTO) + savePaths.map { it to it },
                                    selected = listOf(savePath)
                                ) { values -> savePath = values.firstOrNull().orEmpty() }
                            }
                        }
                    }

                    Spacer(Modifier.height(10.dp))
                    SwitchRow("洗版", "按洗版优先级进行过滤订阅", bestVersion) { bestVersion = it }
                    SwitchRow("使用 IMDbID 搜索", "开启后引用 IMDbID 精确搜索资源", searchImdbId) { searchImdbId = it }
                } else {
                    Spacer(Modifier.height(9.dp))
                    FieldLabel("包含")
                    Spacer(Modifier.height(6.dp))
                    BasicField(include, "关键字或正则，命中才下载") { include = it }
                    Hint("多个关键字用 | 分隔，支持正则表达式")

                    Spacer(Modifier.height(9.dp))
                    FieldLabel("排除")
                    Spacer(Modifier.height(6.dp))
                    BasicField(exclude, "关键字或正则，命中就跳过") { exclude = it }
                    Hint("多个关键字用 | 分隔，支持正则表达式")

                    Spacer(Modifier.height(9.dp))
                    FieldLabel("优先级规则组")
                    Spacer(Modifier.height(6.dp))
                    PickerField(
                        when {
                            ruleGroups.isEmpty() -> "未配置规则组"
                            ruleGroupSet.isEmpty() -> "不选使用系统设置"
                            else -> ruleGroupSet.joinToString("、")
                        }
                    ) {
                        hideKeyboard()
                        picker = Picker(
                            title = "优先级规则组",
                            options = ruleGroups.map { it to it },
                            selected = ruleGroupSet.toList(),
                            multi = true
                        ) { values -> ruleGroupSet = values.toSet() }
                    }
                    Hint("按选定的过滤规则组对订阅进行过滤")

                    Spacer(Modifier.height(9.dp))
                    FieldLabel("自定义类别")
                    Spacer(Modifier.height(6.dp))
                    BasicField(mediaCategory, "留空自动识别") { mediaCategory = it }
                    Hint("指定类别名称，留空自动识别")

                    Spacer(Modifier.height(9.dp))
                    FieldLabel("自定义识别词")
                    Spacer(Modifier.height(6.dp))
                    BasicFieldMulti(customWords, "只对这条订阅生效的识别词", minLines = 3) { customWords = it }
                    Hint("替换词：前置词 <=> 替换词；被替换词 <=> 替换词 & 前定位词 <=> 后定位词 & 集数偏移（EP）。替换词支持 {imdbid/doubanid/bangumiid/animelistid=xxx&type=movie/tv&g=xxxxx&e=xxxxx} 直接指定媒体数据源 ID，其中 g 为剧集组编号，s、e 为季数和集数（均可选）。只对这条订阅生效。")
                }
                Spacer(Modifier.height(10.dp))

                // 底部操作条：跟内容一起滚，滚到底就能看到，不再单独分层（少了割裂感）
                // 字段间距已整体收紧，常见屏高下基础页一屏可见；小屏仍可滚动。
            Row(
                Modifier
                    .padding(top = 10.dp, bottom = 12.dp),
                verticalAlignment = Alignment.CenterVertically
            ) {
                Box(
                    Modifier
                        .weight(1f)
                        .clip(RoundedCornerShape(13.dp))
                        .background(Palette.red.copy(alpha = 0.12f))
                        .clickable { hideKeyboard(); confirmDelete = true }
                        .padding(vertical = 13.dp),
                    contentAlignment = Alignment.Center
                ) {
                    Text("取消订阅", fontSize = 13.sp, color = Palette.red, fontWeight = FontWeight.Medium)
                }
                Spacer(Modifier.width(10.dp))
                Box(
                    Modifier
                        .weight(1f)
                        .clip(RoundedCornerShape(13.dp))
                        .background(if (submitting) Palette.blue.copy(alpha = 0.5f) else Palette.blue)
                        .clickable(enabled = !submitting) {
                            hideKeyboard()
                            submitting = true
                            val hours = intervalHours.toIntOrNull()
                            onSave(
                                sub.copy(
                                    keyword = keyword.trim(),
                                    quality = quality,
                                    resolution = resolution,
                                    effect = effect,
                                    sites = siteIds.toList().sorted(),
                                    searchInterval = if (customInterval) hours?.takeIf { it > 0 } else null,
                                    downloader = downloader,
                                    savePath = savePath,
                                    bestVersion = bestVersion,
                                    searchImdbId = searchImdbId,
                                    include = include.trim(),
                                    exclude = exclude.trim(),
                                    filterGroups = ruleGroupSet.toList(),
                                    mediaCategory = mediaCategory.trim(),
                                    customWords = customWords.trim()
                                )
                            ) {
                                // 成功也把按钮恢复可点：现在保存后**留在本页**（用户要求），
                                // 不重置 submitting 会一直停在「保存中…」且点不动
                                submitting = false
                            }
                        }
                        .padding(vertical = 13.dp),
                    contentAlignment = Alignment.Center
                ) {
                    Text(
                        if (submitting) "保存中…" else "保存",
                        fontSize = 14.sp,
                        color = Color.White,
                        fontWeight = FontWeight.Medium
                    )
                }
            }
            }
        }
    }

    picker?.let { current ->
        OptionPickerDialog(
            picker = current,
            onDismiss = { picker = null },
            onConfirm = { values ->
                current.onConfirm(values)
                picker = null
            }
        )
    }

    if (confirmDelete) {
        OiiAlertDialog(
            onDismissRequest = { confirmDelete = false },
            shape = RoundedCornerShape(14.dp),
            title = { Text("取消订阅", fontSize = 17.sp) },
            text = {
                Text(
                    "从 MoviePilot 里删除《${sub.name}》这条订阅？已下载的文件不受影响。",
                    fontSize = 13.sp,
                    color = colors.textPrimary
                )
            },
            confirmButton = {
                TextButton(onClick = {
                    confirmDelete = false
                    onDelete()
                }) { Text("确认取消", color = Palette.red) }
            },
            dismissButton = {
                TextButton(onClick = { confirmDelete = false }) { Text("再想想") }
            }
        )
    }
}

/** 一次选择请求：标题 + 可选项（显示名 → 提交值）+ 已选值 */
private data class Picker(
    val title: String,
    val options: List<Pair<String, String>>,
    val selected: List<String>,
    val multi: Boolean = false,
    val searchable: Boolean = false,
    val onConfirm: (List<String>) -> Unit
)

@Composable
private fun TabChip(text: String, active: Boolean, onClick: () -> Unit) {
    val colors = LocalMptColors.current
    Box(
        Modifier
            .clip(RoundedCornerShape(9.dp))
            .background(if (active) Palette.purple.copy(alpha = 0.15f) else colors.card)
            .clickable(onClick = onClick)
            .padding(horizontal = 16.dp, vertical = 7.dp)
    ) {
        Text(
            text,
            fontSize = 13.sp,
            color = if (active) Palette.purple else colors.textSecondary,
            fontWeight = if (active) FontWeight.Medium else FontWeight.Normal
        )
    }
}

/** 只读样式的选择框：外形和 [BasicField] 一致，点一下弹选择器 */
@Composable
private fun PickerField(value: String, onClick: () -> Unit) {
    val colors = LocalMptColors.current
    val border = colors.textSecondary.copy(alpha = 0.28f)
    val shape = RoundedCornerShape(9.dp)
    Row(
        Modifier
            .fillMaxWidth()
            .height(38.dp)
            .clip(shape)
            .background(colors.background)
            .border(1.dp, border, shape)
            .clickable(onClick = onClick)
            .padding(horizontal = 10.dp),
        verticalAlignment = Alignment.CenterVertically
    ) {
        Text(
            value,
            fontSize = 13.sp,
            color = if (value.isBlank() || value == "null") colors.textSecondary else colors.textPrimary,
            maxLines = 1,
            overflow = TextOverflow.Ellipsis,
            modifier = Modifier.weight(1f)
        )
        Icon(Icons.Rounded.ExpandMore, null, tint = colors.textSecondary, modifier = Modifier.size(18.dp))
    }
}

@Composable
private fun SwitchRow(title: String, hint: String, checked: Boolean, onChange: (Boolean) -> Unit) {
    val colors = LocalMptColors.current
    Row(
        Modifier.fillMaxWidth().padding(top = 10.dp),
        verticalAlignment = Alignment.CenterVertically
    ) {
        Column(Modifier.weight(1f)) {
            Text(title, fontSize = 13.sp, color = colors.textPrimary)
            Text(hint, fontSize = 10.sp, color = colors.textSecondary)
        }
        Switch(checked = checked, onCheckedChange = onChange)
    }
}

@Composable
private fun Hint(text: String) {
    Text(
        text,
        fontSize = 10.sp,
        color = LocalMptColors.current.textSecondary,
        modifier = Modifier.padding(top = 5.dp)
    )
}

/** 单选 / 多选选择器；多选带「清空」入口，站点多时可按名称过滤 */
@Composable
private fun OptionPickerDialog(
    picker: Picker,
    onDismiss: () -> Unit,
    onConfirm: (List<String>) -> Unit
) {
    val colors = LocalMptColors.current
    val focusManager = LocalFocusManager.current
    val keyboard = LocalSoftwareKeyboardController.current
    var query by remember { mutableStateOf("") }
    var picked by remember(picker) { mutableStateOf(picker.selected.toSet()) }

    val visible = picker.options.filter {
        query.isBlank() || it.first.contains(query, ignoreCase = true)
    }

    /** 关弹窗时先收键盘：搜索框里还有焦点，直接 dismiss 键盘会留在屏幕上 */
    fun close(after: () -> Unit) {
        focusManager.clearFocus()
        keyboard?.hide()
        after()
    }

    /*
     * 不用 M3 AlertDialog：它的 text 槽自带内边距、又会吃掉剩余空间，
     * 选项只有三五个时卡片下半截就是一大块空白。这里自绘按内容收缩的紧凑卡片，
     * 结构对齐鸿蒙端：标题 → 选项列表（最多 6 行半，超出才滚）→ 右下角按钮。
     */
    Dialog(
        onDismissRequest = { close(onDismiss) },
        properties = DialogProperties(usePlatformDefaultWidth = false)
    ) {
        Box(Modifier.fillMaxWidth(), contentAlignment = Alignment.Center) {
            Column(
                Modifier
                    .fillMaxWidth(0.86f)
                    .clip(RoundedCornerShape(14.dp))
                    .background(colors.card)
                    .padding(16.dp)
            ) {
                Text(
                    picker.title,
                    fontSize = 16.sp,
                    fontWeight = FontWeight.Medium,
                    color = colors.textPrimary
                )

                if (picker.searchable) {
                    Spacer(Modifier.height(10.dp))
                    BasicField(query, "搜索…") { query = it }
                }

                Spacer(Modifier.height(6.dp))
                Column(
                    Modifier
                        .fillMaxWidth()
                        .heightIn(max = 264.dp)
                        .verticalScroll(rememberScrollState())
                ) {
                    visible.forEach { (label, value) ->
                        val isOn = picked.contains(value)
                        Row(
                            Modifier
                                .fillMaxWidth()
                                .clip(RoundedCornerShape(9.dp))
                                .clickable {
                                    picked = if (picker.multi) {
                                        if (isOn) picked - value else picked + value
                                    } else {
                                        setOf(value)
                                    }
                                }
                                .padding(horizontal = 8.dp, vertical = 11.dp),
                            verticalAlignment = Alignment.CenterVertically
                        ) {
                            Text(
                                label,
                                fontSize = 14.sp,
                                color = colors.textPrimary,
                                modifier = Modifier.weight(1f),
                                maxLines = 1,
                                overflow = TextOverflow.Ellipsis
                            )
                            if (isOn) {
                                Text(
                                    "✓",
                                    fontSize = 14.sp,
                                    color = Palette.purple,
                                    fontWeight = FontWeight.SemiBold
                                )
                            }
                        }
                    }
                }

                // 操作区靠右下：次操作在左、主操作在右，和 App 内其它弹窗一致
                Row(
                    Modifier
                        .fillMaxWidth()
                        .padding(top = 10.dp),
                    verticalAlignment = Alignment.CenterVertically
                ) {
                    if (picker.multi && picked.isNotEmpty()) {
                        Text(
                            "清空选择",
                            fontSize = 12.sp,
                            color = Palette.red,
                            modifier = Modifier
                                .clip(RoundedCornerShape(9.dp))
                                .clickable { picked = emptySet() }
                                .padding(horizontal = 4.dp, vertical = 6.dp)
                        )
                    }
                    Spacer(Modifier.weight(1f))
                    Text(
                        if (picker.multi) "取消" else "关闭",
                        fontSize = 14.sp,
                        color = colors.textSecondary,
                        modifier = Modifier
                            .clip(RoundedCornerShape(9.dp))
                            .clickable { close(onDismiss) }
                            .padding(horizontal = 14.dp, vertical = 8.dp)
                    )
                    Spacer(Modifier.width(6.dp))
                    Box(
                        Modifier
                            .clip(RoundedCornerShape(9.dp))
                            .background(colors.accent.copy(alpha = 0.12f))
                            .clickable {
                                // 保持选项顺序，避免每次保存顺序乱跳
                                val values = picker.options.map { it.second }.filter { picked.contains(it) }
                                close { onConfirm(values) }
                            }
                            .padding(horizontal = 18.dp, vertical = 8.dp)
                    ) {
                        Text(
                            "确定",
                            fontSize = 14.sp,
                            color = colors.accent,
                            fontWeight = FontWeight.Medium
                        )
                    }
                }
            }
        }
    }
}
