package com.moviepilottools.mptools.ui.transfers

import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.statusBarsPadding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.BasicTextField
import androidx.compose.foundation.text.KeyboardActions
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.rounded.AutoMode
import androidx.compose.material.icons.rounded.Bolt
import androidx.compose.material.icons.rounded.Campaign
import androidx.compose.material.icons.rounded.Category
import androidx.compose.material.icons.rounded.Check
import androidx.compose.material.icons.rounded.ChevronRight
import androidx.compose.material.icons.rounded.Delete
import androidx.compose.material.icons.rounded.DriveFileMove
import androidx.compose.material.icons.rounded.Edit
import androidx.compose.material.icons.rounded.FactCheck
import androidx.compose.material.icons.rounded.Label
import androidx.compose.material.icons.rounded.PauseCircleOutline
import androidx.compose.material.icons.rounded.PlayArrow
import androidx.compose.material.icons.rounded.Public
import androidx.compose.material.icons.rounded.Restore
import androidx.compose.material.icons.rounded.Speed
import androidx.compose.material.icons.rounded.TrendingUp
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.shadow
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.SolidColor
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.platform.LocalFocusManager
import androidx.compose.ui.platform.LocalSoftwareKeyboardController
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.moviepilottools.mptools.data.TorrentStatus
import com.moviepilottools.mptools.data.TorrentTask
import com.moviepilottools.mptools.data.breakableName
import com.moviepilottools.mptools.ui.components.OiiDialog
import com.moviepilottools.mptools.ui.components.PageHeader
import com.moviepilottools.mptools.ui.theme.LocalMptColors
import com.moviepilottools.mptools.ui.theme.Metrics
import com.moviepilottools.mptools.ui.theme.Palette
import com.moviepilottools.mptools.vm.TaskEditMode
import com.moviepilottools.mptools.vm.TorrentAction

/** 底部面板统一的小圆角：M3 默认的 28dp 在手机上看太圆，顶部像被人啃掉一大块 */
val SheetShape = RoundedCornerShape(topStart = 12.dp, topEnd = 12.dp)

private data class ActionRow(
    val label: String,
    val icon: ImageVector,
    val tint: Color,
    val arrow: Boolean = false,
    val danger: Boolean = false,
    val onClick: () -> Unit
)

/**
 * 点任务弹出的操作菜单（参考 qBittorrent / Transmission 手机客户端）。
 *
 * 弹窗 → 整页。用户要求「只读/浏览类面板改回全屏」，只有真正改数据的地方
 * （重命名 / 保存位置 / 限速 / 分享率 / 分类 / 标签 / Tracker）继续弹窗。
 * tr 与 qb 的菜单项不同是接口差异：tr 没有分类、标签、强制继续、自动种子管理。
 *
 * 下一级（详情 / 编辑）仍然叠在它上面，关掉自然回到这一层。
 */
@Composable
fun TaskActionsScreen(
    task: TorrentTask,
    isQb: Boolean,
    onBack: () -> Unit,
    onOpenDetail: () -> Unit,
    onAction: (TorrentAction) -> Unit,
    onAutoManagement: () -> Unit,
    onEdit: (TaskEditMode) -> Unit,
    onOpenTrackers: () -> Unit
) {
    val colors = LocalMptColors.current
    var confirmDelete by remember { mutableStateOf(false) }
    var deleteFiles by remember { mutableStateOf(false) }
    val paused = task.status == TorrentStatus.PAUSED

    // 暂停/继续（qb 再加「强制继续」）单独一张卡：
    // 用户拿鸿蒙截图要求「安卓同步改」——暂停 / 重命名 / 更改保存位置 各自一张卡片，
    // 不再三项挤在一张卡里。
    val toggleGroup = buildList {
        add(
            ActionRow(
                label = if (paused) "继续" else "暂停",
                icon = if (paused) Icons.Rounded.PlayArrow else Icons.Rounded.PauseCircleOutline,
                tint = Palette.blue
            ) { onAction(if (paused) TorrentAction.RESUME else TorrentAction.PAUSE) }
        )
        if (isQb) {
            add(ActionRow("强制继续", Icons.Rounded.Bolt, Palette.green) { onAction(TorrentAction.RESUME_FORCED) })
        }
    }
    val renameRow = ActionRow("重命名", Icons.Rounded.Edit, Palette.blue, arrow = true) {
        onEdit(TaskEditMode.RENAME)
    }
    val locationRow = ActionRow("更改保存位置", Icons.Rounded.DriveFileMove, Palette.mint, arrow = true) {
        onEdit(TaskEditMode.LOCATION)
    }

    // 高危动作单独一组，永远排在最底部（用户要求：凡是高危操作都放最下面）
    val dangerGroup = listOf(
        ActionRow("删除种子", Icons.Rounded.Delete, Palette.red, danger = true) {
            confirmDelete = true
        }
    )

    val secondGroup = buildList {
        if (isQb) {
            add(ActionRow("分类", Icons.Rounded.Category, Palette.purple, arrow = true) {
                onEdit(TaskEditMode.CATEGORY)
            })
            add(ActionRow("标签", Icons.Rounded.Label, Palette.orange, arrow = true) {
                onEdit(TaskEditMode.TAG)
            })
            add(ActionRow("自动种子管理", Icons.Rounded.AutoMode, Palette.indigo) { onAutoManagement() })
        }
        add(ActionRow("限速设置", Icons.Rounded.Speed, Palette.blue, arrow = true) {
            onEdit(TaskEditMode.SPEED)
        })
        add(ActionRow("分享率设置", Icons.Rounded.TrendingUp, Palette.orange, arrow = true) {
            onEdit(TaskEditMode.SHARE)
        })
        // 查看 / 编辑 Tracker：两种下载器都有（qB 走 torrents/trackers，tr 走 trackerStats）
        add(ActionRow("Tracker 列表", Icons.Rounded.Public, Palette.mint, arrow = true) {
            onOpenTrackers()
        })
    }

    val thirdGroup = listOf(
        ActionRow("重新校验", Icons.Rounded.FactCheck, Palette.green) { onAction(TorrentAction.RECHECK) },
        ActionRow("重新汇报", Icons.Rounded.Campaign, Palette.green) { onAction(TorrentAction.REANNOUNCE) }
    )

    Box(Modifier.fillMaxSize().background(colors.background)) {
    Column(
        Modifier
            .fillMaxSize()
            .statusBarsPadding()
            .navigationBarsPadding()
    ) {
        PageHeader(title = "种子操作", subtitle = task.name, onBack = onBack)

        Column(
            Modifier
                .weight(1f)
                .verticalScroll(rememberScrollState())
                .padding(horizontal = Metrics.pagePadding)
                .padding(bottom = 24.dp)
        ) {
        // 第一行：进任务详情（详情是叠在上面的另一层，关掉自动回到这里）
        Row(
            Modifier
                .fillMaxWidth()
                .clip(RoundedCornerShape(12.dp))
                .background(colors.card)
                .clickable { onOpenDetail() }
                .padding(14.dp),
            verticalAlignment = Alignment.CenterVertically
        ) {
            Column(Modifier.weight(1f)) {
                Text(
                    "查看任务详情",
                    fontSize = 14.sp,
                    fontWeight = FontWeight.Medium,
                    color = colors.textPrimary
                )
                Spacer(Modifier.height(2.dp))
                Text(
                    "速度、流量、保存路径、做种时长",
                    fontSize = 10.sp,
                    color = colors.textSecondary
                )
            }
            Icon(
                Icons.Rounded.ChevronRight,
                null,
                tint = colors.textSecondary,
                modifier = Modifier.size(16.dp)
            )
        }

        // 组间距 12 → 8：这一页几乎全是单行卡，12dp 撑开后整页像被拆散（用户反馈「间距太大」），
        // 收到 8dp 更紧凑，又不至于黏在一起
        Spacer(Modifier.height(8.dp))
        ActionGroup(toggleGroup)
        Spacer(Modifier.height(8.dp))
        // tr / qb 的菜单顺序不一样（qb 是「更改保存位置 → 重命名」），保持和各自客户端一致
        if (isQb) {
            ActionGroup(listOf(locationRow))
            Spacer(Modifier.height(8.dp))
            ActionGroup(listOf(renameRow))
        } else {
            ActionGroup(listOf(renameRow))
            Spacer(Modifier.height(8.dp))
            ActionGroup(listOf(locationRow))
        }
        Spacer(Modifier.height(8.dp))
        ActionGroup(secondGroup)
        Spacer(Modifier.height(8.dp))
        ActionGroup(thirdGroup)
        Spacer(Modifier.height(8.dp))
        ActionGroup(dangerGroup, danger = true)
        }
    }
    }

    if (confirmDelete) {
        DeleteTaskDialog(
            task = task,
            deleteFiles = deleteFiles,
            onToggleFiles = { deleteFiles = !deleteFiles },
            onDismiss = { confirmDelete = false },
            onConfirm = {
                confirmDelete = false
                onBack()
                onAction(if (deleteFiles) TorrentAction.DELETE_WITH_FILES else TorrentAction.DELETE)
            }
        )
    }
}

@Composable
private fun ActionGroup(rows: List<ActionRow>, danger: Boolean = false) {
    val colors = LocalMptColors.current
    val shape = RoundedCornerShape(18.dp)
    Box(Modifier.fillMaxWidth()) {
        Column(
            Modifier
                .fillMaxWidth()
                .clip(shape)
                // 整页底色是 background，分组块用 card 色才分得出层；
                // 高危组整卡淡红底，和白底的功能组一眼分开
                .background(if (danger) Palette.red.copy(alpha = 0.08f) else colors.card)
                // 极轻的投影：整页是浅灰底、卡是白底，有了这层柔影才「浮」得起来
                .shadow(
                    10.dp,
                    shape,
                    ambientColor = Color.Black.copy(alpha = if (colors.isDark) 0.30f else 0.06f),
                    spotColor = Color.Black.copy(alpha = if (colors.isDark) 0.30f else 0.06f)
                )
        ) {
            rows.forEachIndexed { index, row ->
                if (index > 0) {
                    Box(
                        Modifier
                            .padding(start = 64.dp)
                            .fillMaxWidth()
                            .height(1.dp)
                            // 用户要求「每行加条线」：0.6dp + 极淡的 separator 基本看不见，
                            // 换成 1dp + textSecondary 27%，浅色/深色下都清晰（与鸿蒙一致）
                            .background(colors.textSecondary.copy(alpha = 0.27f))
                    )
                }
                Row(
                    Modifier
                        .fillMaxWidth()
                        .clickable(onClick = row.onClick)
                        // 行高 = 图标块 38 + 上下各 7 = 52（与鸿蒙 ROW_VPAD 保持一致）
                        .padding(horizontal = 13.dp, vertical = 7.dp),
                    verticalAlignment = Alignment.CenterVertically
                ) {
                    // 图标垫一块同色浅底：整页只有文字+裸图标时看着空，加了底色后每行有视觉锚点
                    Box(
                        Modifier
                            .size(38.dp)
                            .clip(RoundedCornerShape(12.dp))
                            .background(row.tint.copy(alpha = 0.16f)),
                        contentAlignment = Alignment.Center
                    ) {
                        Icon(row.icon, null, tint = row.tint, modifier = Modifier.size(19.dp))
                    }
                    Spacer(Modifier.width(13.dp))
                    Text(
                        row.label,
                        fontSize = 15.sp,
                        color = if (row.danger) Palette.red else colors.textPrimary,
                        modifier = Modifier.weight(1f)
                    )
                    if (row.arrow) {
                        Icon(
                            Icons.Rounded.ChevronRight,
                            null,
                            tint = colors.textSecondary,
                            modifier = Modifier.size(17.dp)
                        )
                    }
                }
            }
        }
        if (danger) {
            // 左侧红条（设计稿样式）：贴在卡片最左边，贯穿整组
            Box(
                Modifier
                    .align(Alignment.CenterStart)
                    .width(3.dp)
                    .fillMaxHeight()
                    .clip(RoundedCornerShape(2.dp))
                    .background(Palette.red.copy(alpha = 0.72f))
            )
        }
    }
}

// ---------------------------------------------------------------- 单任务编辑

/**
 * 单任务的编辑弹窗（重命名 / 更改保存位置 / 分类 / 标签 / 限速 / 分享率）。
 *
 * 全都在一个 Composable 里按 [mode] 分发：这几个表单的骨架一模一样
 * （标题 + 种子名 + 输入区 + 保存按钮），分开写只是复制粘贴。
 *
 * 整页 → 弹窗。分类 / 标签的「选择列表」不显示保存键，只留「关闭」，
 * 点某一项即生效并关窗，和鸿蒙端一致。
 */
@Composable
fun TaskEditDialog(
    task: TorrentTask,
    mode: TaskEditMode,
    isQb: Boolean,
    categories: List<String>,
    tags: List<String>,
    onClose: () -> Unit,
    onLoadTaxonomy: () -> Unit,
    onRename: (String) -> Unit,
    onLocation: (String) -> Unit,
    onCategory: (String, Boolean, String) -> Unit,
    onTags: (List<String>, Boolean) -> Unit,
    onSpeed: (Long, Long) -> Unit,
    onShare: (Int, Double) -> Unit
) {
    val colors = LocalMptColors.current
    val keyboard = LocalSoftwareKeyboardController.current
    val focus = LocalFocusManager.current

    var rename by remember(task.id) { mutableStateOf(task.name) }
    var location by remember(task.id) { mutableStateOf(task.savePath) }
    var downloadKb by remember(task.id) {
        mutableStateOf(if (task.downloadLimit > 0) (task.downloadLimit / 1024).toString() else "0")
    }
    var uploadKb by remember(task.id) {
        mutableStateOf(if (task.uploadLimit > 0) (task.uploadLimit / 1024).toString() else "0")
    }
    var ratioMode by remember(task.id) { mutableStateOf(task.ratioMode) }
    var ratio by remember(task.id) {
        mutableStateOf(if (task.ratioLimit > 0) trimNumber(task.ratioLimit) else "1")
    }
    // 分类 / 标签页面里的「新增」子态
    var creating by remember(mode) { mutableStateOf(false) }
    var newName by remember(mode) { mutableStateOf("") }
    var newSavePath by remember(mode) { mutableStateOf("") }

    LaunchedEffect(mode) {
        if (mode == TaskEditMode.CATEGORY || mode == TaskEditMode.TAG) onLoadTaxonomy()
    }

    fun dismissKeyboard() {
        keyboard?.hide()
        focus.clearFocus()
    }

    // 列表态（还没进「新增」）：没有可提交的东西，确认键退化成关闭
    val listState = (mode == TaskEditMode.CATEGORY || mode == TaskEditMode.TAG) && !creating
    val title = when {
        mode == TaskEditMode.CATEGORY && creating -> "新增分类"
        mode == TaskEditMode.TAG && creating -> "新增标签"
        else -> mode.title
    }
    val confirmText = when {
        listState -> "关闭"
        creating -> "创建"
        else -> "保存"
    }
    val enabled = when {
        listState -> true
        mode == TaskEditMode.RENAME -> rename.isNotBlank() && rename.trim() != task.name
        mode == TaskEditMode.LOCATION -> location.isNotBlank()
        mode == TaskEditMode.CATEGORY -> newName.isNotBlank() && categories.none {
            it.equals(newName.trim(), ignoreCase = true)
        }

        mode == TaskEditMode.TAG -> newName.isNotBlank()
        else -> true
    }

    fun submit() {
        dismissKeyboard()
        when (mode) {
            TaskEditMode.RENAME -> onRename(rename.trim())
            TaskEditMode.LOCATION -> onLocation(location.trim())
            TaskEditMode.CATEGORY -> onCategory(newName.trim(), true, newSavePath.trim())
            TaskEditMode.TAG -> onTags(parseTags(newName), true)
            TaskEditMode.SPEED -> onSpeed(
                downloadKb.toLongOrNull() ?: 0L,
                uploadKb.toLongOrNull() ?: 0L
            )

            TaskEditMode.SHARE -> onShare(ratioMode, ratio.toDoubleOrNull() ?: 1.0)
        }
        onClose()
    }

    OiiDialog(
        title = title,
        subtitle = task.name,
        confirmText = confirmText,
        // 列表态只有一个关闭键；表单态给「取消」，和弹窗的标准双键一致
        cancelText = if (listState) null else "取消",
        confirmEnabled = enabled,
        maxHeight = 380.dp,
        onDismiss = {
            dismissKeyboard()
            onClose()
        },
        onConfirm = { if (listState) onClose() else submit() }
    ) {
        when (mode) {
            TaskEditMode.RENAME -> {
                FieldLabel("新名称")
                EditField(
                    value = rename,
                    placeholder = task.name,
                    singleLine = true,
                    onValueChange = { rename = it }
                )
            }

            TaskEditMode.LOCATION -> {
                FieldLabel("保存位置")
                EditField(
                    value = location,
                    placeholder = "/video/movie",
                    singleLine = true,
                    onValueChange = { location = it }
                )
                Spacer(Modifier.height(8.dp))
                Text(
                    if (isQb) "已下载的文件会被一起移动（qB 的 setLocation）"
                    else "tr 会顺带把已经下载的文件搬过去（move=true）",
                    fontSize = 10.5.sp,
                    color = colors.textSecondary
                )
            }

            TaskEditMode.CATEGORY -> {
                if (!creating) {
                    LazyGroup {
                        ListRow(
                            label = "新增分类",
                            icon = Icons.Rounded.Category,
                            tint = Palette.blue,
                            arrow = true
                        ) { creating = true }
                        ListRow(
                            label = "重置分类",
                            icon = Icons.Rounded.Restore,
                            tint = Palette.green,
                            enabled = task.category.isNotBlank()
                        ) {
                            dismissKeyboard()
                            onCategory("", false, "")
                            onClose()
                        }
                    }
                    if (categories.isNotEmpty()) {
                        Spacer(Modifier.height(10.dp))
                        LazyGroup {
                            categories.forEach { name ->
                                ListRow(
                                    label = name,
                                    icon = Icons.Rounded.Category,
                                    tint = Palette.gray,
                                    checked = name == task.category
                                ) {
                                    dismissKeyboard()
                                    onCategory(name, false, "")
                                    onClose()
                                }
                            }
                        }
                    }
                } else {
                    FieldLabel("分类名称")
                    EditField(
                        value = newName,
                        placeholder = "例如 电视剧",
                        singleLine = true,
                        onValueChange = { newName = it }
                    )
                    if (categories.any { it.equals(newName.trim(), ignoreCase = true) }) {
                        Spacer(Modifier.height(6.dp))
                        Text("分类名称不能重复", fontSize = 11.sp, color = Palette.red)
                    }
                    Spacer(Modifier.height(16.dp))
                    FieldLabel("保存位置")
                    EditField(
                        value = newSavePath,
                        placeholder = "留空 = 用下载器默认目录",
                        singleLine = true,
                        onValueChange = { newSavePath = it }
                    )
                }
            }

            TaskEditMode.TAG -> {
                if (!creating) {
                    LazyGroup {
                        ListRow(
                            label = "新增标签",
                            icon = Icons.Rounded.Label,
                            tint = Palette.blue,
                            arrow = true
                        ) { creating = true }
                        ListRow(
                            label = "重置标签",
                            icon = Icons.Rounded.Restore,
                            tint = Palette.green,
                            enabled = task.tags.isNotEmpty()
                        ) {
                            dismissKeyboard()
                            onTags(emptyList(), false)
                            onClose()
                        }
                    }
                    if (tags.isNotEmpty()) {
                        Spacer(Modifier.height(10.dp))
                        LazyGroup {
                            tags.forEach { tag ->
                                ListRow(
                                    label = tag,
                                    icon = Icons.Rounded.Label,
                                    tint = Palette.orange,
                                    checked = tag in task.tags
                                ) {
                                    dismissKeyboard()
                                    // 再点一次已选中的标签 = 去掉它
                                    onTags(if (tag in task.tags) task.tags - tag else task.tags + tag, false)
                                    onClose()
                                }
                            }
                        }
                    }
                } else {
                    FieldLabel("新增标签")
                    EditField(
                        value = newName,
                        placeholder = "请输入标签",
                        singleLine = true,
                        onValueChange = { newName = it }
                    )
                    Spacer(Modifier.height(6.dp))
                    Text(
                        "多个标签请使用英文逗号隔开\n例：tag1,tag2,tag3...",
                        fontSize = 10.5.sp,
                        color = colors.textSecondary,
                        lineHeight = 16.sp
                    )
                }
            }

            TaskEditMode.SPEED -> {
                FieldLabel("下载限速")
                EditField(
                    value = downloadKb,
                    placeholder = "0",
                    numeric = true,
                    singleLine = true,
                    unit = "KB/s",
                    onValueChange = { downloadKb = it.filter { c -> c.isDigit() } }
                )
                Spacer(Modifier.height(6.dp))
                Text("输入 0 不限速", fontSize = 10.5.sp, color = colors.textSecondary)
                Spacer(Modifier.height(16.dp))
                FieldLabel("上传限速")
                EditField(
                    value = uploadKb,
                    placeholder = "0",
                    numeric = true,
                    singleLine = true,
                    unit = "KB/s",
                    onValueChange = { uploadKb = it.filter { c -> c.isDigit() } }
                )
                Spacer(Modifier.height(6.dp))
                Text("输入 0 不限速", fontSize = 10.5.sp, color = colors.textSecondary)
            }

            TaskEditMode.SHARE -> {
                LazyGroup {
                    RadioRow("使用全局分享限制", ratioMode == -2) { ratioMode = -2 }
                    RadioRow("设置为无分享限制", ratioMode == -1) { ratioMode = -1 }
                    RadioRow("自定义分享限制", ratioMode == 0) { ratioMode = 0 }
                }
                if (ratioMode == 0) {
                    Spacer(Modifier.height(14.dp))
                    FieldLabel("分享率上限")
                    EditField(
                        value = ratio,
                        placeholder = "1.0",
                        numeric = true,
                        singleLine = true,
                        onValueChange = { ratio = it }
                    )
                }
            }
        }
    }
}

// ---------------------------------------------------------------- 小组件

private fun parseTags(raw: String): List<String> =
    raw.split(",", "，").map { it.trim() }.filter { it.isNotEmpty() }.distinct()

private fun trimNumber(value: Double): String =
    if (value == value.toLong().toDouble()) value.toLong().toString()
    else String.format(java.util.Locale.US, "%.2f", value)

@Composable
private fun LazyGroup(content: @Composable () -> Unit) {
    val colors = LocalMptColors.current
    Column(
        Modifier
            .fillMaxWidth()
            .clip(RoundedCornerShape(10.dp))
            .background(colors.background)
    ) {
        content()
    }
}

@Composable
private fun ListRow(
    label: String,
    icon: ImageVector,
    tint: Color,
    arrow: Boolean = false,
    checked: Boolean = false,
    enabled: Boolean = true,
    onClick: () -> Unit
) {
    val colors = LocalMptColors.current
    Row(
        Modifier
            .fillMaxWidth()
            .clickable(enabled = enabled, onClick = onClick)
            .padding(horizontal = 12.dp, vertical = 13.dp),
        verticalAlignment = Alignment.CenterVertically
    ) {
        Icon(
            icon,
            null,
            tint = if (enabled) tint else tint.copy(alpha = 0.4f),
            modifier = Modifier.size(19.dp)
        )
        Spacer(Modifier.width(13.dp))
        Text(
            label,
            fontSize = 14.sp,
            color = if (enabled) {
                if (checked) colors.accent else colors.textPrimary
            } else {
                colors.textSecondary.copy(alpha = 0.6f)
            },
            modifier = Modifier.weight(1f)
        )
        when {
            checked -> Icon(Icons.Rounded.Check, null, tint = colors.accent, modifier = Modifier.size(17.dp))
            arrow -> Icon(
                Icons.Rounded.ChevronRight,
                null,
                tint = colors.textSecondary,
                modifier = Modifier.size(17.dp)
            )
        }
    }
}

@Composable
private fun RadioRow(label: String, selected: Boolean, onClick: () -> Unit) {
    val colors = LocalMptColors.current
    Row(
        Modifier
            .fillMaxWidth()
            .clickable(onClick = onClick)
            .padding(horizontal = 12.dp, vertical = 13.dp),
        verticalAlignment = Alignment.CenterVertically
    ) {
        Box(
            Modifier
                .size(20.dp)
                .clip(CircleShape)
                .border(
                    width = if (selected) 6.dp else 1.5.dp,
                    color = if (selected) Palette.red else colors.textSecondary.copy(alpha = 0.5f),
                    shape = CircleShape
                )
        )
        Spacer(Modifier.width(13.dp))
        Text(label, fontSize = 14.sp, color = colors.textPrimary)
    }
}

@Composable
private fun FieldLabel(text: String) {
    val colors = LocalMptColors.current
    Text(
        text,
        fontSize = 12.sp,
        color = colors.accent,
        modifier = Modifier.padding(bottom = 7.dp)
    )
}

@Composable
private fun EditField(
    value: String,
    placeholder: String,
    numeric: Boolean = false,
    singleLine: Boolean = false,
    unit: String? = null,
    onValueChange: (String) -> Unit
) {
    val colors = LocalMptColors.current
    val keyboard = LocalSoftwareKeyboardController.current
    val focusManager = LocalFocusManager.current
    val shape = RoundedCornerShape(10.dp)
    Row(
        Modifier
            .fillMaxWidth()
            .heightIn(min = 46.dp)
            .clip(shape)
            // 弹窗卡片是 card 色，输入框用背景色才有「凹进去」的层次
            .background(colors.background)
            .border(1.dp, colors.separator, shape)
            .padding(horizontal = 12.dp, vertical = 12.dp),
        verticalAlignment = Alignment.CenterVertically
    ) {
        Box(Modifier.weight(1f), contentAlignment = Alignment.CenterStart) {
            if (value.isEmpty()) {
                Text(placeholder, fontSize = 13.sp, color = colors.textSecondary)
            }
            BasicTextField(
                value = value,
                onValueChange = onValueChange,
                singleLine = singleLine,
                textStyle = TextStyle(fontSize = 13.sp, color = colors.textPrimary),
                cursorBrush = SolidColor(colors.accent),
                keyboardOptions = KeyboardOptions(
                    keyboardType = if (numeric) KeyboardType.Number else KeyboardType.Text,
                    imeAction = if (singleLine) ImeAction.Done else ImeAction.Default
                ),
                keyboardActions = KeyboardActions(
                    onDone = {
                        focusManager.clearFocus()
                        keyboard?.hide()
                    }
                ),
                modifier = Modifier.fillMaxWidth()
            )
        }
        unit?.let {
            Text(it, fontSize = 12.sp, color = colors.textSecondary)
        }
    }
}

/** 删除确认：勾选框用实线边框 + 打勾，避免浅色底上「看不见」 */
@Composable
private fun DeleteTaskDialog(
    task: TorrentTask,
    deleteFiles: Boolean,
    onToggleFiles: () -> Unit,
    onDismiss: () -> Unit,
    onConfirm: () -> Unit
) {
    val colors = LocalMptColors.current
    OiiDialog(
        title = "删除种子",
        confirmText = "删除",
        destructive = true,
        maxHeight = 260.dp,
        onDismiss = onDismiss,
        onConfirm = onConfirm
    ) {
        Text(
            "确定要删除「${breakableName(task.name.take(40))}」吗？",
            fontSize = 13.sp,
            color = colors.textPrimary,
            lineHeight = 19.sp
        )
        Spacer(Modifier.height(12.dp))
        Row(
            Modifier
                .fillMaxWidth()
                .clickable(onClick = onToggleFiles),
            verticalAlignment = Alignment.CenterVertically
        ) {
            CheckBoxBox(deleteFiles)
            Spacer(Modifier.width(10.dp))
            Text(
                "同时删除已下载的文件",
                fontSize = 13.sp,
                color = if (deleteFiles) Palette.red else colors.textPrimary
            )
        }
    }
}

@Composable
fun CheckBoxBox(checked: Boolean) {
    val colors = LocalMptColors.current
    Box(
        Modifier
            .size(20.dp)
            .clip(RoundedCornerShape(5.dp))
            .background(if (checked) Palette.red else colors.background)
            .border(
                1.6.dp,
                if (checked) Palette.red else colors.textSecondary.copy(alpha = 0.7f),
                RoundedCornerShape(5.dp)
            ),
        contentAlignment = Alignment.Center
    ) {
        if (checked) {
            Icon(Icons.Rounded.Check, null, tint = Color.White, modifier = Modifier.size(14.dp))
        }
    }
}
