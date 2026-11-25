package com.moviepilottools.mptools.ui.settings

import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.imePadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.rounded.Add
import androidx.compose.material.icons.rounded.ArrowBack
import androidx.compose.material.icons.rounded.Delete
import androidx.compose.material.icons.rounded.Dns
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateListOf
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
import com.moviepilottools.mptools.data.Endpoint
import com.moviepilottools.mptools.data.EndpointMode
import com.moviepilottools.mptools.data.ServerConfig
import com.moviepilottools.mptools.data.ServerType
import com.moviepilottools.mptools.ui.components.BasicField
import com.moviepilottools.mptools.ui.components.DividerLine
import com.moviepilottools.mptools.ui.components.OiiDialog
import com.moviepilottools.mptools.ui.components.FieldLabel
import com.moviepilottools.mptools.ui.components.ServerBadge
import com.moviepilottools.mptools.ui.theme.LocalMptColors
import com.moviepilottools.mptools.ui.theme.Metrics
import com.moviepilottools.mptools.ui.theme.Palette
import com.moviepilottools.mptools.vm.UiState
import kotlinx.coroutines.launch
import java.util.UUID

@Composable
fun ServerListScreen(
    state: UiState,
    onBack: () -> Unit,
    onAdd: () -> Unit,
    onEdit: (String) -> Unit
) {
    val colors = LocalMptColors.current

    Column(Modifier.fillMaxSize().background(colors.background)) {
        ScreenHeader(title = "下载器设置", onBack = onBack, onAdd = onAdd)

        if (state.servers.isEmpty()) {
            Box(Modifier.fillMaxSize(), contentAlignment = Alignment.Center) {
                Column(horizontalAlignment = Alignment.CenterHorizontally) {
                    Icon(Icons.Rounded.Dns, null, tint = colors.textSecondary, modifier = Modifier.size(38.dp))
                    Spacer(Modifier.height(10.dp))
                    Text("还没有服务器", fontSize = 15.sp, color = colors.textSecondary)
                    Spacer(Modifier.height(6.dp))
                    Text(
                        "点击右上角 + 添加",
                        fontSize = 13.sp,
                        color = colors.accent
                    )
                }
            }
        } else {
            LazyColumn(
                contentPadding = androidx.compose.foundation.layout.PaddingValues(
                    start = Metrics.pagePadding, end = Metrics.pagePadding, top = 4.dp, bottom = 110.dp
                ),
                verticalArrangement = Arrangement.spacedBy(10.dp)
            ) {
                items(state.servers, key = { it.id }) { server ->
                    val snapshot = state.snapshots[server.id]
                    Row(
                        Modifier
                            .fillMaxWidth()
                            .clip(RoundedCornerShape(14.dp))
                            .background(colors.card)
                            .clickable { onEdit(server.id) }
                            .padding(14.dp),
                        verticalAlignment = Alignment.CenterVertically
                    ) {
                        ServerBadge(server.type, 34)
                        Spacer(Modifier.width(12.dp))
                        Column(Modifier.weight(1f)) {
                            Row(verticalAlignment = Alignment.CenterVertically) {
                                Text(
                                    server.displayName,
                                    fontSize = 15.sp,
                                    fontWeight = FontWeight.Medium,
                                    color = colors.textPrimary,
                                    maxLines = 1,
                                    overflow = TextOverflow.Ellipsis
                                )
                                Spacer(Modifier.width(6.dp))
                                Box(
                                    Modifier
                                        .size(7.dp)
                                        .clip(CircleShape)
                                        .background(
                                            when {
                                                snapshot == null -> Palette.orange
                                                snapshot.online -> Palette.green
                                                else -> Palette.red
                                            }
                                        )
                                )
                            }
                            Spacer(Modifier.height(3.dp))
                            Text(
                                server.activeEndpoints.firstOrNull()?.display ?: "未配置地址",
                                fontSize = 12.sp,
                                color = colors.textSecondary,
                                maxLines = 1,
                                overflow = TextOverflow.Ellipsis
                            )
                            if (server.activeEndpoints.size > 1) {
                                Spacer(Modifier.height(2.dp))
                                Text(
                                    "共 ${server.activeEndpoints.size} 个地址 · 自动切换",
                                    fontSize = 11.sp,
                                    color = Palette.blue
                                )
                            }
                        }
                    }
                }
            }
        }
    }
}

@Composable
fun ServerEditDialog(
    existing: ServerConfig?,
    onDismiss: () -> Unit,
    onSave: (ServerConfig) -> Unit,
    onDelete: (String) -> Unit,
    onTest: suspend (ServerConfig) -> Result<String>
) {
    val colors = LocalMptColors.current
    val scope = rememberCoroutineScope()

    var name by remember { mutableStateOf(existing?.name ?: "") }
    var type by remember { mutableStateOf(existing?.type ?: ServerType.QBITTORRENT) }
    var username by remember { mutableStateOf(existing?.username ?: "") }
    var password by remember { mutableStateOf(existing?.password ?: "") }
    var apiKey by remember { mutableStateOf(existing?.apiKey ?: "") }
    var useApiKey by remember { mutableStateOf(existing?.useApiKey ?: false) }
    var rpcPath by remember { mutableStateOf(existing?.rpcPath ?: "/transmission/rpc") }
    var mode by remember { mutableStateOf(existing?.endpointMode ?: EndpointMode.AUTO) }
    var pinned by remember { mutableStateOf(existing?.pinnedEndpointIndex ?: 0) }
    var testResult by remember { mutableStateOf<String?>(null) }
    var testing by remember { mutableStateOf(false) }
    var confirmDelete by remember { mutableStateOf(false) }
    var saveError by remember { mutableStateOf<String?>(null) }

    val endpoints = remember(existing?.id) {
        mutableStateListOf<Endpoint>().apply {
            val initial = existing?.endpoints?.takeIf { it.isNotEmpty() }
                ?: listOf(Endpoint(host = "", port = if (existing?.type == ServerType.TRANSMISSION) 9091 else 8080))
            addAll(initial)
        }
    }
    // 保存时会丢掉空地址行，「手动固定」必须按保存后的有效地址序号，否则会指错地址。
    val pinnedTargets = endpoints.map { it.normalized() }.filter { it.host.isNotBlank() }

    fun buildConfig(): ServerConfig = ServerConfig(
        id = existing?.id ?: UUID.randomUUID().toString(),
        name = name.trim(),
        type = type,
        // 允许整段粘贴 http(s)://host:port/path，保存时统一拆开
        endpoints = endpoints.map { it.normalized() }.filter { it.host.isNotBlank() },
        username = username,
        password = password,
        apiKey = apiKey,
        useApiKey = useApiKey,
        rpcPath = rpcPath.ifBlank { "/transmission/rpc" },
        endpointMode = mode,
        pinnedEndpointIndex = pinned.coerceIn(0, (pinnedTargets.size - 1).coerceAtLeast(0))
    )

    fun save() {
        val candidate = buildConfig()
        if (candidate.activeEndpoints.isEmpty()) {
            saveError = "至少填一条访问地址（域名或 IP）。端口可以留空，https 走 443、http 走 80。"
            return
        }
        runCatching { onSave(candidate) }
    }

    // 提示 / 删除确认弹出时先藏起表单，不做层叠背景（和鸿蒙端一致）
    if (saveError == null && !confirmDelete) {
        OiiDialog(
            title = if (existing == null) "添加服务器" else "编辑服务器",
            subtitle = if (existing == null) null else existing.displayName,
            confirmText = "保存",
            maxHeight = 440.dp,
            onDismiss = onDismiss,
            onConfirm = { save() }
        ) {
            FieldLabel("名称")
            Spacer(Modifier.height(6.dp))
            BasicField(name, "例如 家里的 NAS", onChange = { name = it })

            Spacer(Modifier.height(14.dp))
            FieldLabel("类型")
            Spacer(Modifier.height(6.dp))
            Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                ServerType.entries.forEach { option ->
                    val selected = option == type
                    Box(
                        Modifier
                            .weight(1f)
                            .clip(RoundedCornerShape(10.dp))
                            .background(if (selected) colors.accent else colors.background)
                            .clickable {
                                type = option
                                endpoints.forEachIndexed { index, endpoint ->
                                    if (endpoint.port == 8080 || endpoint.port == 9091) {
                                        endpoints[index] = endpoint.copy(
                                            port = if (option == ServerType.TRANSMISSION) 9091 else 8080
                                        )
                                    }
                                }
                            }
                            .padding(vertical = 11.dp),
                        contentAlignment = Alignment.Center
                    ) {
                        Text(
                            option.label,
                            fontSize = 13.sp,
                            color = if (selected) Color.White else colors.textPrimary,
                            fontWeight = if (selected) FontWeight.Medium else FontWeight.Normal
                        )
                    }
                }
            }

            Spacer(Modifier.height(16.dp))
            Row(verticalAlignment = Alignment.CenterVertically) {
                Text("访问地址", fontSize = 13.sp, fontWeight = FontWeight.Medium, color = colors.textPrimary)
                Spacer(Modifier.width(8.dp))
                Text("可填多个，自动挑能通的", fontSize = 10.5.sp, color = colors.textSecondary)
                Spacer(Modifier.weight(1f))
                Row(
                    Modifier.clickable {
                        endpoints.add(
                            Endpoint(host = "", port = if (type == ServerType.TRANSMISSION) 9091 else 8080)
                        )
                    },
                    verticalAlignment = Alignment.CenterVertically
                ) {
                    Icon(Icons.Rounded.Add, null, tint = colors.accent, modifier = Modifier.size(15.dp))
                    Text("添加", fontSize = 13.sp, color = colors.accent)
                }
            }
            Spacer(Modifier.height(8.dp))

            endpoints.forEachIndexed { index, endpoint ->
                Column(
                    Modifier
                        .fillMaxWidth()
                        .padding(bottom = 10.dp)
                        .clip(RoundedCornerShape(10.dp))
                        .background(colors.background)
                        .padding(12.dp)
                ) {
                    Row(verticalAlignment = Alignment.CenterVertically) {
                        Text("地址 ${index + 1}", fontSize = 12.sp, color = colors.textSecondary)
                        Spacer(Modifier.weight(1f))
                        if (endpoints.size > 1) {
                            Icon(
                                Icons.Rounded.Delete,
                                null,
                                tint = Palette.red,
                                modifier = Modifier
                                    .size(16.dp)
                                    .clickable { endpoints.removeAt(index) }
                            )
                        }
                    }
                    Spacer(Modifier.height(8.dp))
                    BasicField(
                        endpoint.host,
                        "192.168.1.10 或 qb.example.com",
                        onChange = { endpoints[index] = endpoints[index].copy(host = it.trim()) }
                    )
                    Spacer(Modifier.height(8.dp))
                    Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                        BasicField(
                            if (endpoint.port in 1..65535) endpoint.port.toString() else "",
                            "端口（空=默认）",
                            modifier = Modifier.weight(1f),
                            keyboardType = KeyboardType.Number,
                            onChange = { text ->
                                val port = text.filter { it.isDigit() }.take(5).toIntOrNull() ?: 0
                                endpoints[index] = endpoints[index].copy(port = port)
                            }
                        )
                        BasicField(
                            endpoint.basePath,
                            "子路径 /qb（可空）",
                            modifier = Modifier.weight(1.4f),
                            onChange = { endpoints[index] = endpoints[index].copy(basePath = it.trim()) }
                        )
                    }
                    Spacer(Modifier.height(8.dp))
                    Row(verticalAlignment = Alignment.CenterVertically) {
                        BasicField(
                            endpoint.label,
                            "备注：家里 / 外网",
                            modifier = Modifier.weight(1f),
                            onChange = { endpoints[index] = endpoints[index].copy(label = it) }
                        )
                        Spacer(Modifier.width(8.dp))
                        Box(
                            Modifier
                                .clip(RoundedCornerShape(8.dp))
                                .background(
                                    if (endpoint.https) Palette.blue.copy(alpha = 0.16f) else colors.card
                                )
                                .clickable {
                                    endpoints[index] = endpoints[index].copy(https = !endpoint.https)
                                }
                                .padding(horizontal = 9.dp, vertical = 7.dp)
                        ) {
                            Text(
                                "HTTPS",
                                fontSize = 11.sp,
                                color = if (endpoint.https) Palette.blue else colors.textSecondary
                            )
                        }
                    }
                    if (endpoint.host.isNotBlank()) {
                        val preview = endpoint.normalized()
                        Spacer(Modifier.height(6.dp))
                        Text(
                            if (preview.isValid) "实际请求：${preview.display}" else "地址格式不对，检查是否填了多余字符",
                            fontSize = 10.sp,
                            color = if (preview.isValid) colors.textSecondary else Palette.red,
                            maxLines = 1,
                            overflow = TextOverflow.Ellipsis
                        )
                    }
                }
            }

            Spacer(Modifier.height(6.dp))
            FieldLabel("选路方式")
            Spacer(Modifier.height(6.dp))
            Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                EndpointMode.entries.forEach { option ->
                    val selected = mode == option
                    Box(
                        Modifier
                            .weight(1f)
                            .clip(RoundedCornerShape(10.dp))
                            .background(if (selected) Palette.blue.copy(alpha = 0.13f) else colors.background)
                            .clickable { mode = option }
                            .padding(vertical = 10.dp),
                        contentAlignment = Alignment.Center
                    ) {
                        Text(
                            if (option == EndpointMode.AUTO) "自动切换" else "固定地址",
                            fontSize = 13.sp,
                            color = if (selected) Palette.blue else colors.textSecondary
                        )
                    }
                }
            }
            if (mode == EndpointMode.MANUAL) {
                Spacer(Modifier.height(8.dp))
                pinnedTargets.forEachIndexed { index, endpoint ->
                    Row(
                        Modifier
                            .fillMaxWidth()
                            .clickable { pinned = index }
                            .padding(vertical = 7.dp),
                        verticalAlignment = Alignment.CenterVertically
                    ) {
                        Box(
                            Modifier
                                .size(16.dp)
                                .clip(CircleShape)
                                .background(if (pinned == index) Palette.blue else colors.separator)
                        )
                        Spacer(Modifier.width(8.dp))
                        Text(
                            endpoint.display,
                            fontSize = 12.sp,
                            color = colors.textSecondary,
                            maxLines = 1,
                            overflow = TextOverflow.Ellipsis
                        )
                    }
                }
            }

            Spacer(Modifier.height(16.dp))
            FieldLabel("认证")
            Spacer(Modifier.height(6.dp))
            if (type == ServerType.QBITTORRENT) {
                Row(verticalAlignment = Alignment.CenterVertically) {
                    Text("使用 API Key（qBittorrent 5.2+）", fontSize = 12.5.sp, color = colors.textPrimary)
                    Spacer(Modifier.weight(1f))
                    Box(
                        Modifier
                            .clip(RoundedCornerShape(8.dp))
                            .background(if (useApiKey) Palette.blue.copy(alpha = 0.15f) else colors.card)
                            .clickable { useApiKey = !useApiKey }
                            .padding(horizontal = 10.dp, vertical = 6.dp)
                    ) {
                        Text(
                            if (useApiKey) "已启用" else "未启用",
                            fontSize = 12.sp,
                            color = if (useApiKey) Palette.blue else colors.textSecondary
                        )
                    }
                }
                Spacer(Modifier.height(8.dp))
            }

            if (useApiKey && type == ServerType.QBITTORRENT) {
                BasicField(apiKey, "粘贴 API Key", secret = true, onChange = { apiKey = it })
            } else {
                BasicField(username, "用户名", onChange = { username = it })
                Spacer(Modifier.height(8.dp))
                BasicField(password, "密码", secret = true, onChange = { password = it })
            }

            if (type == ServerType.TRANSMISSION) {
                Spacer(Modifier.height(14.dp))
                FieldLabel("RPC 路径")
                Spacer(Modifier.height(6.dp))
                BasicField(rpcPath, "/transmission/rpc", onChange = { rpcPath = it })
            }

            Spacer(Modifier.height(16.dp))
            Row(
                Modifier
                    .fillMaxWidth()
                    .clip(RoundedCornerShape(10.dp))
                    .background(Palette.blue.copy(alpha = 0.12f))
                    .clickable {
                        testing = true
                        testResult = null
                        scope.launch {
                            val result = onTest(buildConfig())
                            testing = false
                            testResult = result.getOrElse { it.message ?: "连接失败" }
                        }
                    }
                    .padding(vertical = 12.dp),
                horizontalArrangement = Arrangement.Center
            ) {
                Text(
                    if (testing) "正在测试…" else "测试连接",
                    fontSize = 13.5.sp,
                    color = Palette.blue,
                    fontWeight = FontWeight.Medium
                )
            }
            testResult?.let {
                Spacer(Modifier.height(8.dp))
                Text(
                    it,
                    fontSize = 12.sp,
                    color = if (it.startsWith("连接成功")) Palette.green else Palette.red
                )
            }

            if (existing != null) {
                Spacer(Modifier.height(12.dp))
                Row(
                    Modifier
                        .fillMaxWidth()
                        .clip(RoundedCornerShape(10.dp))
                        .background(Palette.red.copy(alpha = 0.1f))
                        .clickable { confirmDelete = true }
                        .padding(vertical = 12.dp),
                    horizontalArrangement = Arrangement.Center
                ) {
                    Text("删除服务器", fontSize = 13.5.sp, color = Palette.red)
                }
            }
        }
    }

    saveError?.let { message ->
        OiiDialog(
            title = "还不能保存",
            confirmText = "知道了",
            cancelText = null,
            maxHeight = 220.dp,
            onDismiss = { saveError = null },
            onConfirm = { saveError = null }
        ) {
            Text(message, fontSize = 13.sp, color = colors.textPrimary, lineHeight = 19.sp)
        }
    }

    if (confirmDelete && existing != null) {
        OiiDialog(
            title = "删除服务器",
            subtitle = existing.displayName,
            confirmText = "删除",
            destructive = true,
            maxHeight = 200.dp,
            onDismiss = { confirmDelete = false },
            onConfirm = {
                confirmDelete = false
                onDelete(existing.id)
            }
        ) {
            Text(
                "该操作不可恢复，已设的地址、账号密码都会一起删掉。",
                fontSize = 13.sp,
                color = colors.textPrimary,
                lineHeight = 19.sp
            )
        }
    }
}

@Composable
private fun ScreenHeader(title: String, onBack: () -> Unit, onAdd: () -> Unit) {
    val colors = LocalMptColors.current
    Row(
        Modifier.fillMaxWidth().padding(horizontal = Metrics.pagePadding, vertical = 10.dp),
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
            Icon(Icons.Rounded.ArrowBack, null, tint = colors.textPrimary, modifier = Modifier.size(19.dp))
        }
        Spacer(Modifier.weight(1f))
        Text(title, fontSize = 17.sp, fontWeight = FontWeight.SemiBold, color = colors.textPrimary)
        Spacer(Modifier.weight(1f))
        Box(
            Modifier
                .size(34.dp)
                .clip(CircleShape)
                .background(colors.card)
                .clickable(onClick = onAdd),
            contentAlignment = Alignment.Center
        ) {
            Icon(Icons.Rounded.Add, null, tint = colors.accent, modifier = Modifier.size(20.dp))
        }
    }
}
