package com.moviepilottools.mptools.ui.transfers

import android.content.Context
import android.net.Uri
import android.provider.OpenableColumns
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.BasicTextField
import androidx.compose.foundation.text.KeyboardActions
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.rounded.Description
import androidx.compose.material.icons.rounded.ExpandLess
import androidx.compose.material.icons.rounded.ExpandMore
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.SolidColor
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalFocusManager
import androidx.compose.ui.platform.LocalSoftwareKeyboardController
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.moviepilottools.mptools.data.ServerConfig
import com.moviepilottools.mptools.data.ServerType
import com.moviepilottools.mptools.data.formatStorageSize
import com.moviepilottools.mptools.ui.components.OiiDialog
import com.moviepilottools.mptools.ui.theme.LocalMptColors
import com.moviepilottools.mptools.ui.theme.Palette
import com.moviepilottools.mptools.vm.AddTorrentRequest
import com.moviepilottools.mptools.vm.AddTorrentState
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

private enum class AddMode(val label: String) {
    URL("从URL或磁力链接下载"),
    FILE("从本地上传种子文件下载")
}

private data class PickedTorrent(val bytes: ByteArray, val name: String)

/**
 * 新增下载弹窗（整页 → 弹窗）。
 *
 * tr 与 qb 的差异是真实的接口差异，不是省事：
 * - tr 的 torrent-add 只认 download-dir / paused / metainfo，没有重命名、自动种子管理、跳过校验；
 * - qb 的 torrents/add 支持 rename / autoTMM / skip_checking，所以这两块只在 qb 下出现。
 */
@Composable
fun TorrentAddDialog(
    server: ServerConfig,
    defaultSavePath: String,
    categories: List<String>,
    state: AddTorrentState,
    onDismiss: () -> Unit,
    onLoadTaxonomy: () -> Unit,
    onSubmit: (AddTorrentRequest) -> Unit,
    onClearState: () -> Unit,
    onDone: () -> Unit
) {
    val colors = LocalMptColors.current
    val context = LocalContext.current
    val scope = rememberCoroutineScope()
    val isQb = server.type == ServerType.QBITTORRENT
    val focus = LocalFocusManager.current
    val keyboard = LocalSoftwareKeyboardController.current

    fun dismissKeyboard() {
        focus.clearFocus()
        keyboard?.hide()
    }

    var mode by remember { mutableStateOf(AddMode.URL) }
    var modeMenu by remember { mutableStateOf(false) }
    var urls by remember { mutableStateOf("") }
    var savePath by remember { mutableStateOf(defaultSavePath) }
    var rename by remember { mutableStateOf("") }
    var cookie by remember { mutableStateOf("") }
    var autoTmm by remember { mutableStateOf(false) }
    var skipHashCheck by remember { mutableStateOf(false) }
    var selectedCategory by remember { mutableStateOf("") }
    var categoryMenu by remember { mutableStateOf(false) }
    var picked by remember { mutableStateOf<PickedTorrent?>(null) }
    var pickError by remember { mutableStateOf<String?>(null) }

    // qB 的分类来自下载器本身，进弹窗时拉一次（没拉到就只有一个「不分类」）
    LaunchedEffect(isQb) {
        if (isQb) onLoadTaxonomy()
    }

    val filePicker = rememberLauncherForActivityResult(ActivityResultContracts.OpenDocument()) { uri ->
        if (uri == null) return@rememberLauncherForActivityResult
        scope.launch {
            val result = withContext(Dispatchers.IO) { readTorrent(context, uri) }
            result
                .onSuccess { picked = it; pickError = null }
                .onFailure { pickError = it.message ?: "读取种子文件失败" }
        }
    }

    val canSubmit = !state.submitting && when (mode) {
        AddMode.URL -> urls.isNotBlank()
        AddMode.FILE -> picked != null
    }

    OiiDialog(
        title = "新增下载",
        subtitle = server.displayName,
        confirmText = if (state.submitting) "提交中…" else "提交",
        confirmEnabled = canSubmit,
        busy = state.submitting,
        maxHeight = 420.dp,
        onDismiss = {
            dismissKeyboard()
            onDismiss()
        },
        onConfirm = {
            dismissKeyboard()
            val list = urls.lines().map { it.trim() }.filter { it.isNotEmpty() }
            onSubmit(
                AddTorrentRequest(
                    urls = if (mode == AddMode.URL) list else emptyList(),
                    fileBytes = if (mode == AddMode.FILE) picked?.bytes else null,
                    fileName = if (mode == AddMode.FILE) picked?.name.orEmpty() else "",
                    savePath = savePath.trim(),
                    rename = rename.trim(),
                    cookie = cookie.trim(),
                    category = selectedCategory,
                    autoTmm = autoTmm,
                    skipHashCheck = skipHashCheck
                )
            )
        }
    ) {
        // 下载方式（下拉）：URL/磁力 或 本地种子文件
        Box {
            Row(
                Modifier
                    .fillMaxWidth()
                    .clip(RoundedCornerShape(10.dp))
                    .background(colors.background)
                    .clickable { modeMenu = true }
                    .padding(horizontal = 12.dp, vertical = 12.dp),
                verticalAlignment = Alignment.CenterVertically
            ) {
                Text(
                    mode.label,
                    fontSize = 13.5.sp,
                    color = colors.textPrimary,
                    modifier = Modifier.weight(1f)
                )
                Icon(
                    if (modeMenu) Icons.Rounded.ExpandLess else Icons.Rounded.ExpandMore,
                    null,
                    tint = colors.accent,
                    modifier = Modifier.size(18.dp)
                )
            }
            DropdownMenu(
                expanded = modeMenu,
                onDismissRequest = { modeMenu = false },
                containerColor = colors.card
            ) {
                AddMode.entries.forEach { item ->
                    DropdownMenuItem(
                        text = {
                            Text(
                                item.label,
                                fontSize = 14.sp,
                                color = if (item == mode) colors.accent else colors.textPrimary
                            )
                        },
                        onClick = { modeMenu = false; mode = item }
                    )
                }
            }
        }

        Spacer(Modifier.height(14.dp))

        when (mode) {
            AddMode.URL -> {
                FieldTitle("下载链接")
                InputBox(
                    value = urls,
                    placeholder = "多个下载链接请换行",
                    minHeight = 84.dp,
                    onValueChange = { urls = it }
                )
                Spacer(Modifier.height(6.dp))
                Text(
                    "支持磁力链（magnet:）与 .torrent 直链；一行一个",
                    fontSize = 10.5.sp,
                    color = colors.textSecondary
                )
            }

            AddMode.FILE -> {
                FieldTitle("种子文件")
                Row(
                    Modifier
                        .fillMaxWidth()
                        .clip(RoundedCornerShape(10.dp))
                        .background(colors.background)
                        .clickable { filePicker.launch(arrayOf("*/*")) }
                        .padding(horizontal = 12.dp, vertical = 13.dp),
                    verticalAlignment = Alignment.CenterVertically
                ) {
                    Icon(
                        Icons.Rounded.Description,
                        null,
                        tint = colors.accent,
                        modifier = Modifier.size(20.dp)
                    )
                    Spacer(Modifier.width(10.dp))
                    Column(Modifier.weight(1f)) {
                        Text(
                            picked?.name ?: "选择一个 .torrent 文件",
                            fontSize = 13.sp,
                            color = if (picked == null) colors.textSecondary else colors.textPrimary,
                            maxLines = 1,
                            overflow = TextOverflow.Ellipsis
                        )
                        picked?.let {
                            Spacer(Modifier.height(2.dp))
                            Text(
                                formatStorageSize(it.bytes.size.toLong()),
                                fontSize = 10.5.sp,
                                color = colors.textSecondary
                            )
                        }
                    }
                    Text(
                        if (picked == null) "选择" else "更换",
                        fontSize = 12.sp,
                        color = colors.accent
                    )
                }
                pickError?.let {
                    Spacer(Modifier.height(6.dp))
                    Text(it, fontSize = 11.sp, color = Palette.red)
                }
            }
        }

        Spacer(Modifier.height(14.dp))
        FieldTitle("文件保存位置")
        InputBox(
            value = savePath,
            placeholder = defaultSavePath.ifBlank { "留空 = 用下载器默认目录" },
            singleLine = true,
            onValueChange = { savePath = it }
        )

        if (isQb) {
            Spacer(Modifier.height(14.dp))
            FieldTitle("重命名")
            InputBox(
                value = rename,
                placeholder = "留空 = 使用种子里的名称",
                singleLine = true,
                onValueChange = { rename = it }
            )
        }

        Spacer(Modifier.height(14.dp))
        FieldTitle("Cookie")
        InputBox(
            value = cookie,
            placeholder = "站点直链需要登录时才填",
            singleLine = true,
            onValueChange = { cookie = it }
        )
        Spacer(Modifier.height(6.dp))
        Text(
            "填了之后，带 Cookie 的 http 直链会由 App 先取回种子再交给下载器；磁力链不需要 Cookie。",
            fontSize = 10.sp,
            color = colors.textSecondary,
            lineHeight = 15.sp
        )

        // qB 专属：分类是「选下载器里已有的分类」，不是折叠面板；
        // 自动种子管理 / 跳过哈希校验是两个开关，直接平铺。
        if (isQb) {
            Spacer(Modifier.height(14.dp))
            FieldTitle("下载分类")
            Box {
                Row(
                    Modifier
                        .fillMaxWidth()
                        .clip(RoundedCornerShape(10.dp))
                        .background(colors.background)
                        .border(1.dp, colors.separator, RoundedCornerShape(10.dp))
                        .clickable {
                            dismissKeyboard()
                            categoryMenu = true
                        }
                        .padding(horizontal = 12.dp, vertical = 12.dp),
                    verticalAlignment = Alignment.CenterVertically
                ) {
                    Text(
                        selectedCategory.ifBlank { "不分类" },
                        fontSize = 13.sp,
                        color = if (selectedCategory.isBlank()) {
                            colors.textSecondary
                        } else {
                            colors.textPrimary
                        },
                        modifier = Modifier.weight(1f)
                    )
                    Icon(
                        Icons.Rounded.ExpandMore,
                        null,
                        tint = colors.accent,
                        modifier = Modifier.size(18.dp)
                    )
                }
                DropdownMenu(
                    expanded = categoryMenu,
                    onDismissRequest = { categoryMenu = false },
                    containerColor = colors.card
                ) {
                    DropdownMenuItem(
                        text = {
                            Text(
                                "不分类",
                                fontSize = 14.sp,
                                color = if (selectedCategory.isBlank()) colors.accent else colors.textPrimary
                            )
                        },
                        onClick = {
                            selectedCategory = ""
                            categoryMenu = false
                        }
                    )
                    categories.forEach { name ->
                        DropdownMenuItem(
                            text = {
                                Text(
                                    name,
                                    fontSize = 14.sp,
                                    color = if (name == selectedCategory) colors.accent else colors.textPrimary
                                )
                            },
                            onClick = {
                                selectedCategory = name
                                categoryMenu = false
                            }
                        )
                    }
                }
            }

            Spacer(Modifier.height(10.dp))
            CheckRow(
                label = "自动种子管理",
                checked = autoTmm,
                onToggle = { autoTmm = !autoTmm }
            )
            Spacer(Modifier.height(8.dp))
            CheckRow(
                label = "跳过哈希校验",
                checked = skipHashCheck,
                onToggle = { skipHashCheck = !skipHashCheck }
            )
        }

        state.error?.let { message ->
            Spacer(Modifier.height(14.dp))
            Box(
                Modifier
                    .fillMaxWidth()
                    .clip(RoundedCornerShape(10.dp))
                    .background(Palette.red.copy(alpha = 0.10f))
                    .padding(11.dp)
            ) {
                Text(message, fontSize = 12.sp, color = Palette.red, lineHeight = 17.sp)
            }
        }
    }

    if (state.done) {
        // 成功态改成同一套弹窗（原来是 M3 AlertDialog，白底 + 系统圆角，跟其它弹窗不像一家人）
        OiiDialog(
            title = "已添加到下载器",
            subtitle = state.message.ifBlank { "任务已创建" },
            confirmText = "完成",
            cancelText = null,
            maxHeight = 200.dp,
            onDismiss = {
                onClearState()
                onDone()
            },
            onConfirm = {
                onClearState()
                onDone()
            }
        ) {
            Text(
                "已交给下载器，回列表就能看到它开始跑了。",
                fontSize = 12.sp,
                color = colors.textSecondary,
                lineHeight = 17.sp
            )
        }
    }
}

@Composable
private fun FieldTitle(text: String) {
    val colors = LocalMptColors.current
    Text(
        text,
        fontSize = 12.sp,
        color = colors.textSecondary,
        modifier = Modifier.padding(bottom = 7.dp)
    )
}

@Composable
private fun InputBox(
    value: String,
    placeholder: String,
    minHeight: androidx.compose.ui.unit.Dp = 42.dp,
    singleLine: Boolean = false,
    onValueChange: (String) -> Unit
) {
    val colors = LocalMptColors.current
    val keyboard = LocalSoftwareKeyboardController.current
    val focusManager = LocalFocusManager.current
    val shape = RoundedCornerShape(10.dp)
    Box(
        Modifier
            .fillMaxWidth()
            .heightIn(min = minHeight)
            .clip(shape)
            // 弹窗卡片是 card 色，输入框用背景色才有层次
            .background(colors.background)
            .border(1.dp, colors.separator, shape)
            .padding(horizontal = 12.dp, vertical = 11.dp),
        contentAlignment = Alignment.TopStart
    ) {
        if (value.isEmpty()) {
            Text(placeholder, fontSize = 13.sp, color = colors.textSecondary)
        }
        BasicTextField(
            value = value,
            onValueChange = onValueChange,
            singleLine = singleLine,
            textStyle = TextStyle(fontSize = 13.sp, color = colors.textPrimary, lineHeight = 19.sp),
            cursorBrush = SolidColor(colors.accent),
            keyboardOptions = KeyboardOptions(
                keyboardType = KeyboardType.Text,
                // 单行输入框给「完成」键，按一下就把键盘收掉
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
}

@Composable
private fun CheckRow(label: String, checked: Boolean, onToggle: () -> Unit) {
    val colors = LocalMptColors.current
    Row(
        Modifier
            .fillMaxWidth()
            .clip(RoundedCornerShape(10.dp))
            .background(colors.background)
            .clickable(onClick = onToggle)
            .padding(horizontal = 12.dp, vertical = 11.dp),
        verticalAlignment = Alignment.CenterVertically
    ) {
        Box(
            Modifier
                .size(19.dp)
                .clip(CircleShape)
                .border(
                    width = if (checked) 5.5.dp else 1.5.dp,
                    color = if (checked) colors.accent else colors.textSecondary.copy(alpha = 0.5f),
                    shape = CircleShape
                )
        )
        Spacer(Modifier.width(11.dp))
        Text(label, fontSize = 13.sp, color = colors.textPrimary)
    }
}

/** 读本地 .torrent：超过 10 MB 基本不可能是种子，直接拒绝，避免把内存吃爆 */
private fun readTorrent(context: Context, uri: Uri): Result<PickedTorrent> = runCatching {
    val bytes = context.contentResolver.openInputStream(uri)?.use { it.readBytes() }
        ?: throw IllegalStateException("无法打开该文件")
    if (bytes.isEmpty()) throw IllegalStateException("种子文件是空的")
    if (bytes.size > 10 * 1024 * 1024) throw IllegalStateException("文件过大，不像是种子文件")
    if (bytes[0] != 'd'.code.toByte()) throw IllegalStateException("这个文件不是 .torrent（bencode 格式校验失败）")

    var name = "upload.torrent"
    runCatching {
        context.contentResolver.query(uri, null, null, null, null)?.use { cursor ->
            val index = cursor.getColumnIndex(OpenableColumns.DISPLAY_NAME)
            if (index >= 0 && cursor.moveToFirst()) {
                name = cursor.getString(index) ?: name
            }
        }
    }
    PickedTorrent(bytes, name.ifBlank { "upload.torrent" })
}
