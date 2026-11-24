package com.moviepilottools.mptools.ui.automation

import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
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
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.rounded.Add
import androidx.compose.material.icons.rounded.Check
import androidx.compose.material.icons.rounded.Close
import androidx.compose.material.icons.rounded.ExpandMore
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.ModalBottomSheet
import androidx.compose.material3.Switch
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.rememberModalBottomSheetState
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.moviepilottools.mptools.data.HeaderPair
import com.moviepilottools.mptools.data.RssItemRecord
import com.moviepilottools.mptools.data.RssRuleEngine
import com.moviepilottools.mptools.data.RssSource
import com.moviepilottools.mptools.data.ServerConfig
import com.moviepilottools.mptools.data.formatBytes
import com.moviepilottools.mptools.ui.components.BasicField
import com.moviepilottools.mptools.ui.components.DividerLine
import com.moviepilottools.mptools.ui.components.FieldLabel
import com.moviepilottools.mptools.ui.components.OiiCard
import com.moviepilottools.mptools.ui.theme.LocalMptColors
import com.moviepilottools.mptools.ui.theme.Palette
import kotlinx.coroutines.launch

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun SourceEditorSheet(
    initial: RssSource,
    servers: List<ServerConfig>,
    presetPaths: List<String>,
    onDismiss: () -> Unit,
    onSave: (RssSource) -> Unit,
    onTest: suspend (RssSource) -> Result<Pair<Int, List<RssItemRecord>>>
) {
    val colors = LocalMptColors.current
    val sheetState = rememberModalBottomSheetState(skipPartiallyExpanded = true)
    val scope = rememberCoroutineScope()

    var draft by remember { mutableStateOf(initial) }
    var apiKey by remember { mutableStateOf(initial.apiKey) }
    var headers by remember { mutableStateOf(initial.headers) }
    var includeInput by remember { mutableStateOf("") }
    var excludeInput by remember { mutableStateOf("") }

    var testing by remember { mutableStateOf(false) }
    var testResult by remember { mutableStateOf<String?>(null) }
    var preview by remember { mutableStateOf<List<Pair<RssItemRecord, Boolean>>>(emptyList()) }
    var testOk by remember { mutableStateOf(true) }

    ModalBottomSheet(
        onDismissRequest = onDismiss,
        sheetState = sheetState,
        containerColor = colors.background
    ) {
        LazyColumn(
            modifier = Modifier.fillMaxWidth().heightIn(max = 680.dp),
            contentPadding = androidx.compose.foundation.layout.PaddingValues(
                start = 16.dp, end = 16.dp, bottom = 28.dp
            ),
            verticalArrangement = Arrangement.spacedBy(12.dp)
        ) {
            item {
                Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
                    Text(
                        if (initial.url.isBlank() && initial.name.isBlank()) "添加 RSS 源" else "编辑 RSS 源",
                        fontSize = 18.sp,
                        fontWeight = FontWeight.SemiBold,
                        color = colors.textPrimary
                    )
                    Spacer(Modifier.weight(1f))
                    TextButton(onClick = {
                        val cleaned = draft.copy(
                            name = draft.name.trim(),
                            url = draft.url.trim(),
                            apiKey = apiKey.trim(),
                            headers = headers.filter { it.key.isNotBlank() }
                        )
                        onSave(cleaned)
                    }) { Text("保存", color = Palette.blue) }
                }
            }

            // 基本信息
            item {
                OiiCard(modifier = Modifier.fillMaxWidth()) {
                    FieldLabel("名称")
                    Spacer(Modifier.height(6.dp))
                    BasicField(draft.name, "例如 XX 站免费") { draft = draft.copy(name = it) }
                    Spacer(Modifier.height(12.dp))
                    FieldLabel("RSS 地址")
                    Spacer(Modifier.height(6.dp))
                    BasicField(draft.url, "https://your-site.example/rss.php?token=...") {
                        draft = draft.copy(url = it)
                    }
                    Spacer(Modifier.height(12.dp))
                    Row(verticalAlignment = Alignment.CenterVertically) {
                        Column(Modifier.weight(1f)) {
                            Text("启用此源", fontSize = 14.sp, color = colors.textPrimary)
                            Text("关闭后不刷新、不推送", fontSize = 11.sp, color = colors.textSecondary)
                        }
                        Switch(draft.enabled, { draft = draft.copy(enabled = it) })
                    }
                }
            }

            // 站点认证
            item {
                OiiCard(modifier = Modifier.fillMaxWidth()) {
                    Text("站点认证", fontSize = 14.sp, fontWeight = FontWeight.Medium, color = colors.textPrimary)
                    Spacer(Modifier.height(4.dp))
                    Text(
                        "多数 PT 站只需 URL 里的 passkey；部分站点需要 API Key，其他站可用自定义 Header（Cookie / Authorization）。",
                        fontSize = 11.sp,
                        color = colors.textSecondary,
                        lineHeight = 16.sp
                    )
                    Spacer(Modifier.height(10.dp))
                    FieldLabel("站点 API Key（可选）")
                    Spacer(Modifier.height(6.dp))
                    BasicField(apiKey, "仅部分站点需要", secret = true) { apiKey = it }

                    Spacer(Modifier.height(12.dp))
                    FieldLabel("自定义 Headers")
                    headers.forEachIndexed { index, header ->
                        Row(
                            Modifier.fillMaxWidth().padding(top = 6.dp),
                            verticalAlignment = Alignment.CenterVertically
                        ) {
                            Box(Modifier.weight(1f)) {
                                BasicField(header.key, "名称，如 Cookie") { value ->
                                    headers = headers.toMutableList().also {
                                        it[index] = header.copy(key = value)
                                    }
                                }
                            }
                            Spacer(Modifier.width(6.dp))
                            Box(Modifier.weight(1.4f)) {
                                BasicField(header.value, "值", secret = true) { value ->
                                    headers = headers.toMutableList().also {
                                        it[index] = header.copy(value = value)
                                    }
                                }
                            }
                            Icon(
                                Icons.Rounded.Close, null,
                                tint = colors.textSecondary,
                                modifier = Modifier
                                    .padding(start = 6.dp)
                                    .size(16.dp)
                                    .clickable {
                                        headers = headers.toMutableList().also { it.removeAt(index) }
                                    }
                            )
                        }
                    }
                    Spacer(Modifier.height(8.dp))
                    Row(
                        Modifier
                            .clip(RoundedCornerShape(9.dp))
                            .background(Palette.blue.copy(alpha = 0.1f))
                            .clickable { headers = headers + HeaderPair() }
                            .padding(horizontal = 10.dp, vertical = 6.dp),
                        verticalAlignment = Alignment.CenterVertically
                    ) {
                        Icon(Icons.Rounded.Add, null, tint = Palette.blue, modifier = Modifier.size(13.dp))
                        Spacer(Modifier.width(4.dp))
                        Text("添加 Header", fontSize = 12.sp, color = Palette.blue)
                    }
                }
            }

            // 投递
            item {
                OiiCard(modifier = Modifier.fillMaxWidth()) {
                    Text("投递设置", fontSize = 14.sp, fontWeight = FontWeight.Medium, color = colors.textPrimary)
                    Spacer(Modifier.height(10.dp))

                    DropField(
                        label = "目标下载器",
                        value = draft.targetServerId?.let { id ->
                            servers.firstOrNull { it.id == id }?.displayName
                        } ?: "自动（第一台）",
                        options = listOf("自动（第一台）") + servers.map { it.displayName }
                    ) { index ->
                        draft = draft.copy(
                            targetServerId = if (index == 0) null else servers.getOrNull(index - 1)?.id
                        )
                    }

                    Spacer(Modifier.height(12.dp))
                    DropField(
                        label = "保存路径",
                        value = draft.savePath.ifBlank { "跟随下载器默认" },
                        options = listOf("跟随下载器默认") + presetPaths
                    ) { index ->
                        draft = draft.copy(savePath = if (index == 0) "" else presetPaths[index - 1])
                    }
                    Spacer(Modifier.height(6.dp))
                    BasicField(draft.savePath, "也可直接填自定义路径，如 /PT/Seeding") {
                        draft = draft.copy(savePath = it)
                    }

                    Spacer(Modifier.height(12.dp))
                    FieldLabel("分类 / 标签")
                    Spacer(Modifier.height(6.dp))
                    BasicField(draft.category, "例如 Movie / TV") { draft = draft.copy(category = it) }

                    Spacer(Modifier.height(12.dp))
                    Row(verticalAlignment = Alignment.CenterVertically) {
                        Column(Modifier.weight(1f)) {
                            Text("添加后暂停", fontSize = 14.sp, color = colors.textPrimary)
                            Text("先暂停，确认无误再手动开始", fontSize = 11.sp, color = colors.textSecondary)
                        }
                        Switch(draft.addPaused, { draft = draft.copy(addPaused = it) })
                    }

                    Spacer(Modifier.height(10.dp))
                    FieldLabel("优先级")
                    Spacer(Modifier.height(6.dp))
                    Row(horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                        listOf(-1 to "低", 0 to "默认", 1 to "高").forEach { (value, label) ->
                            val active = draft.priority == value
                            Box(
                                Modifier
                                    .weight(1f)
                                    .clip(RoundedCornerShape(9.dp))
                                    .background(if (active) Palette.blue else colors.background)
                                    .clickable { draft = draft.copy(priority = value) }
                                    .padding(vertical = 8.dp),
                                contentAlignment = Alignment.Center
                            ) {
                                Text(
                                    label, fontSize = 12.sp,
                                    color = if (active) Color.White else colors.textSecondary
                                )
                            }
                        }
                    }
                }
            }

            // 规则
            item {
                OiiCard(modifier = Modifier.fillMaxWidth()) {
                    Row(verticalAlignment = Alignment.CenterVertically) {
                        Column(Modifier.weight(1f)) {
                            Text("自动下载", fontSize = 14.sp, fontWeight = FontWeight.Medium, color = colors.textPrimary)
                            Text("命中规则的条目直接推送到下载器", fontSize = 11.sp, color = colors.textSecondary)
                        }
                        Switch(draft.autoDownload, { draft = draft.copy(autoDownload = it) })
                    }

                    Spacer(Modifier.height(10.dp))
                    DividerLine()
                    Spacer(Modifier.height(10.dp))

                    Text("筛选规则", fontSize = 13.sp, fontWeight = FontWeight.Medium, color = colors.textPrimary)
                    Spacer(Modifier.height(4.dp))
                    Text(
                        "包含关键词要全部命中；排除关键词任一命中即淘汰；集数支持 01-12、S01E01-E10、01 02 03。",
                        fontSize = 11.sp,
                        color = colors.textSecondary,
                        lineHeight = 16.sp
                    )

                    Spacer(Modifier.height(10.dp))
                    KeywordEditor(
                        title = "包含关键词",
                        keywords = draft.includeKeywords,
                        input = includeInput,
                        onInputChange = { includeInput = it },
                        onAdd = {
                            val k = includeInput.trim()
                            if (k.isNotEmpty() && !draft.includeKeywords.contains(k)) {
                                draft = draft.copy(includeKeywords = draft.includeKeywords + k)
                            }
                            includeInput = ""
                        },
                        onRemove = { keyword ->
                            draft = draft.copy(includeKeywords = draft.includeKeywords - keyword)
                        }
                    )

                    Spacer(Modifier.height(10.dp))
                    KeywordEditor(
                        title = "排除关键词",
                        keywords = draft.excludeKeywords,
                        input = excludeInput,
                        onInputChange = { excludeInput = it },
                        onAdd = {
                            val k = excludeInput.trim()
                            if (k.isNotEmpty() && !draft.excludeKeywords.contains(k)) {
                                draft = draft.copy(excludeKeywords = draft.excludeKeywords + k)
                            }
                            excludeInput = ""
                        },
                        onRemove = { keyword -> draft = draft.copy(excludeKeywords = draft.excludeKeywords - keyword) }
                    )

                    Spacer(Modifier.height(12.dp))
                    Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                        Column(Modifier.weight(1f)) {
                            FieldLabel("最小体积 (GB)")
                            Spacer(Modifier.height(6.dp))
                            BasicField(
                                draft.minSizeGB?.toString() ?: "",
                                "不限",
                                keyboardType = KeyboardType.Decimal
                            ) { text ->
                                draft = draft.copy(minSizeGB = text.toDoubleOrNull())
                            }
                        }
                        Column(Modifier.weight(1f)) {
                            FieldLabel("最大体积 (GB)")
                            Spacer(Modifier.height(6.dp))
                            BasicField(
                                draft.maxSizeGB?.toString() ?: "",
                                "不限",
                                keyboardType = KeyboardType.Decimal
                            ) { text ->
                                draft = draft.copy(maxSizeGB = text.toDoubleOrNull())
                            }
                        }
                    }

                    Spacer(Modifier.height(12.dp))
                    FieldLabel("集数过滤")
                    Spacer(Modifier.height(6.dp))
                    BasicField(draft.episodeFilter, "例如 01-12 或 S01E01-E10") {
                        draft = draft.copy(episodeFilter = it)
                    }
                }
            }

            // 测试与预览
            item {
                OiiCard(modifier = Modifier.fillMaxWidth()) {
                    Row(verticalAlignment = Alignment.CenterVertically) {
                        Text("规则预览", fontSize = 14.sp, fontWeight = FontWeight.Medium, color = colors.textPrimary)
                        Spacer(Modifier.weight(1f))
                        Row(
                            Modifier
                                .clip(RoundedCornerShape(10.dp))
                                .background(Palette.blue.copy(alpha = 0.12f))
                                .clickable(enabled = !testing) {
                                    testing = true
                                    scope.launch {
                                        val result = onTest(
                                            draft.copy(
                                                apiKey = apiKey.trim(),
                                                headers = headers.filter { it.key.isNotBlank() }
                                            )
                                        )
                                        testing = false
                                        result.onSuccess { (count, samples) ->
                                            testOk = true
                                            testResult = "抓取成功，共 $count 条"
                                            preview = samples.map { it to RssRuleEngine.matches(it, draft) }
                                        }.onFailure {
                                            testOk = false
                                            testResult = "失败：${it.message}"
                                            preview = emptyList()
                                        }
                                    }
                                }
                                .padding(horizontal = 10.dp, vertical = 6.dp)
                        ) {
                            Text(if (testing) "抓取中…" else "抓取并预览", fontSize = 12.sp, color = Palette.blue)
                        }
                    }

                    testResult?.let {
                        Spacer(Modifier.height(8.dp))
                        Text(it, fontSize = 11.sp, color = if (testOk) Palette.green else Palette.red)
                    }

                    if (preview.isNotEmpty()) {
                        Spacer(Modifier.height(8.dp))
                        preview.forEach { (item, matched) ->
                            Row(
                                Modifier.fillMaxWidth().padding(vertical = 3.dp),
                                verticalAlignment = Alignment.CenterVertically
                            ) {
                                Box(
                                    Modifier
                                        .size(6.dp)
                                        .clip(RoundedCornerShape(3.dp))
                                        .background(if (matched) Palette.green else colors.separator)
                                )
                                Spacer(Modifier.width(6.dp))
                                Text(
                                    item.title,
                                    fontSize = 11.sp,
                                    color = if (matched) colors.textPrimary else colors.textSecondary,
                                    maxLines = 1,
                                    overflow = TextOverflow.Ellipsis,
                                    modifier = Modifier.weight(1f)
                                )
                                if (item.sizeBytes > 0) {
                                    Text(formatBytes(item.sizeBytes), fontSize = 10.sp, color = colors.textSecondary)
                                }
                                if (matched) {
                                    Spacer(Modifier.width(4.dp))
                                    Icon(Icons.Rounded.Check, null, tint = Palette.green, modifier = Modifier.size(12.dp))
                                }
                            }
                        }
                        Text("绿色 = 命中规则，会自动推送", fontSize = 10.sp, color = colors.textSecondary)
                    }

                    Spacer(Modifier.height(8.dp))
                    Text(
                        "保存后规则立即生效，新发布的条目会在下次刷新时推送。",
                        fontSize = 10.sp,
                        color = colors.textSecondary
                    )
                }
            }
        }
    }
}

@Composable
private fun KeywordEditor(
    title: String,
    keywords: List<String>,
    input: String,
    onInputChange: (String) -> Unit,
    onAdd: () -> Unit,
    onRemove: (String) -> Unit
) {
    val colors = LocalMptColors.current
    FieldLabel(title)
    if (keywords.isNotEmpty()) {
        Row(
            Modifier.fillMaxWidth().padding(top = 6.dp),
            horizontalArrangement = Arrangement.spacedBy(5.dp)
        ) {
            keywords.take(4).forEach { keyword ->
                Row(
                    Modifier
                        .clip(RoundedCornerShape(8.dp))
                        .background(colors.separator)
                        .clickable { onRemove(keyword) }
                        .padding(horizontal = 7.dp, vertical = 4.dp),
                    verticalAlignment = Alignment.CenterVertically
                ) {
                    Text(keyword, fontSize = 11.sp, color = colors.textPrimary)
                    Spacer(Modifier.width(3.dp))
                    Icon(Icons.Rounded.Close, null, tint = colors.textSecondary, modifier = Modifier.size(10.dp))
                }
            }
        }
    }
    Spacer(Modifier.height(6.dp))
    Row(verticalAlignment = Alignment.CenterVertically) {
        Box(Modifier.weight(1f)) {
            BasicField(input, "输入后点添加") { onInputChange(it) }
        }
        Spacer(Modifier.width(6.dp))
        Box(
            Modifier
                .clip(RoundedCornerShape(9.dp))
                .background(Palette.blue.copy(alpha = 0.12f))
                .clickable { onAdd() }
                .padding(horizontal = 12.dp, vertical = 10.dp)
        ) {
            Text("添加", fontSize = 12.sp, color = Palette.blue)
        }
    }
}

@Composable
private fun DropField(
    label: String,
    value: String,
    options: List<String>,
    onSelect: (Int) -> Unit
) {
    val colors = LocalMptColors.current
    var expanded by remember { mutableStateOf(false) }

    FieldLabel(label)
    Spacer(Modifier.height(6.dp))
    Box {
        Row(
            Modifier
                .fillMaxWidth()
                .height(38.dp)
                .clip(RoundedCornerShape(9.dp))
                .background(colors.background)
                .clickable { expanded = true }
                .padding(horizontal = 10.dp),
            verticalAlignment = Alignment.CenterVertically
        ) {
            Text(
                value,
                fontSize = 14.sp,
                color = colors.textPrimary,
                maxLines = 1,
                overflow = TextOverflow.Ellipsis,
                modifier = Modifier.weight(1f)
            )
            Icon(
                Icons.Rounded.ExpandMore,
                null,
                tint = colors.textSecondary,
                modifier = Modifier.size(18.dp)
            )
        }
        DropdownMenu(expanded = expanded, onDismissRequest = { expanded = false }) {
            options.forEachIndexed { index, option ->
                DropdownMenuItem(
                    text = { Text(option, fontSize = 13.sp) },
                    onClick = {
                        expanded = false
                        onSelect(index)
                    }
                )
            }
        }
    }
}
