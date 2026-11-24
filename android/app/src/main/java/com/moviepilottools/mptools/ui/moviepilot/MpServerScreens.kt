package com.moviepilottools.mptools.ui.moviepilot

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
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.rounded.Add
import androidx.compose.material.icons.rounded.ArrowBack
import androidx.compose.material.icons.rounded.ChevronRight
import androidx.compose.material.icons.rounded.Delete
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
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
import com.moviepilottools.mptools.data.MpServer
import com.moviepilottools.mptools.ui.components.BasicField
import com.moviepilottools.mptools.ui.components.EmptyHint
import com.moviepilottools.mptools.ui.components.FieldLabel
import com.moviepilottools.mptools.ui.components.OiiDialog
import com.moviepilottools.mptools.ui.theme.LocalMptColors
import com.moviepilottools.mptools.ui.theme.Metrics
import com.moviepilottools.mptools.ui.theme.Palette
import kotlinx.coroutines.launch
import java.util.UUID

/**
 * MoviePilot 服务器列表 / 编辑（对应鸿蒙 ui/moviepilot/MpServerScreens.ets）。
 *
 * 
 * - 列表行统一成下载器那种卡片——MP 圆徽标 + 名称 + 两行地址 + 状态点 + chevron，
 *   去掉了右侧那颗「使用」胶囊（跟着鸿蒙一起收敛）；
 * - 编辑页从整页改成弹窗，切换当前服务器挪进编辑弹窗的「设为当前使用」。
 */
@Composable
fun MpServerListScreen(
    servers: List<MpServer>,
    activeId: String?,
    /** 当前服务器最近一次拉数据是否报错（决定状态点是绿还是红） */
    error: String = "",
    onBack: () -> Unit,
    onAdd: () -> Unit,
    onEdit: (MpServer) -> Unit
) {
    val colors = LocalMptColors.current

    Column(Modifier.fillMaxSize().background(colors.background)) {
        Row(
            Modifier.fillMaxWidth().padding(horizontal = Metrics.pagePadding, vertical = 10.dp),
            verticalAlignment = Alignment.CenterVertically
        ) {
            Box(
                Modifier.size(34.dp).clip(CircleShape).background(colors.card).clickable(onClick = onBack),
                contentAlignment = Alignment.Center
            ) {
                Icon(Icons.Rounded.ArrowBack, null, tint = colors.textPrimary, modifier = Modifier.size(19.dp))
            }
            Spacer(Modifier.width(10.dp))
            Text("MoviePilot 服务器", fontSize = 17.sp, fontWeight = FontWeight.SemiBold, color = colors.textPrimary)
            Spacer(Modifier.weight(1f))
            Row(Modifier.clickable(onClick = onAdd), verticalAlignment = Alignment.CenterVertically) {
                Icon(Icons.Rounded.Add, null, tint = colors.accent, modifier = Modifier.size(16.dp))
                Text("添加", fontSize = 13.sp, color = colors.accent)
            }
        }

        if (servers.isEmpty()) {
            EmptyHint("还没有配置 MoviePilot")
            return@Column
        }

        Column(
            Modifier
                .fillMaxSize()
                .verticalScroll(rememberScrollState())
                .padding(horizontal = Metrics.pagePadding)
        ) {
            Spacer(Modifier.height(4.dp))
            servers.forEach { server ->
                Row(
                    Modifier
                        .fillMaxWidth()
                        .padding(bottom = 9.dp)
                        .clip(RoundedCornerShape(14.dp))
                        .background(colors.card)
                        .clickable { onEdit(server) }
                        .padding(13.dp),
                    verticalAlignment = Alignment.CenterVertically
                ) {
                    // 和下载器列表同款的图标块（那边是 qb/tr 缩写，这边统一 MP）
                    Box(
                        Modifier
                            .size(32.dp)
                            .clip(CircleShape)
                            .background(Palette.blue.copy(alpha = 0.15f)),
                        contentAlignment = Alignment.Center
                    ) {
                        Text(
                            "MP",
                            fontSize = 12.sp,
                            fontWeight = FontWeight.Bold,
                            color = Palette.blue
                        )
                    }
                    Spacer(Modifier.width(11.dp))

                    Column(Modifier.weight(1f)) {
                        Row(verticalAlignment = Alignment.CenterVertically) {
                            Text(
                                server.displayName,
                                fontSize = 15.sp,
                                fontWeight = FontWeight.Medium,
                                color = colors.textPrimary,
                                maxLines = 1,
                                overflow = TextOverflow.Ellipsis,
                                modifier = Modifier.weight(1f)
                            )
                            Spacer(Modifier.width(6.dp))
                            // 绿点 = 当前在用且没报错；红点 = 当前在用但拉数据失败；灰点 = 未启用
                            Box(
                                Modifier
                                    .size(7.dp)
                                    .clip(CircleShape)
                                    .background(
                                        when {
                                            server.id != activeId -> colors.textSecondary.copy(alpha = 0.45f)
                                            error.isBlank() -> Palette.green
                                            else -> Palette.red
                                        }
                                    )
                            )
                        }
                        Spacer(Modifier.height(3.dp))
                        addressLines(server).forEachIndexed { index, line ->
                            Text(
                                line,
                                fontSize = 11.sp,
                                // 第一行灰、第二行蓝（「共 N 个地址」提示也是蓝色小字）
                                color = if (index == 0) colors.textSecondary else Palette.blue,
                                maxLines = 1,
                                overflow = TextOverflow.Ellipsis,
                                modifier = Modifier.padding(top = if (index == 0) 0.dp else 2.dp)
                            )
                        }
                        if (server.apiToken.isBlank()) {
                            Text(
                                "缺少 API Token",
                                fontSize = 10.sp,
                                color = Palette.red,
                                modifier = Modifier.padding(top = 2.dp)
                            )
                        }
                    }

                    Icon(
                        Icons.Rounded.ChevronRight,
                        null,
                        tint = colors.textSecondary,
                        modifier = Modifier.size(16.dp)
                    )
                }
            }
            Spacer(Modifier.height(20.dp))
        }
    }
}

/** 地址按行拆：第一行主地址，第二行次地址或「共 N 个地址」提示 */
private fun addressLines(server: MpServer): List<String> {
    val eps = server.activeEndpoints
    return when {
        eps.isEmpty() -> listOf("未设置地址")
        eps.size == 1 -> listOf(eps[0].display)
        eps.size == 2 -> listOf(eps[0].display, eps[1].display)
        else -> listOf(eps[0].display, "共 ${eps.size} 个地址 · 自动切换")
    }
}

@Composable
fun MpServerEditDialog(
    existing: MpServer?,
    /** 当前正在使用的服务器 id，用来决定要不要显示「设为当前使用」 */
    activeId: String? = null,
    onDismiss: () -> Unit,
    onSave: (MpServer) -> Unit,
    onDelete: (String) -> Unit,
    onTest: suspend (MpServer) -> Result<String>,
    onMakeActive: ((String) -> Unit)? = null
) {
    val colors = LocalMptColors.current
    val scope = rememberCoroutineScope()

    var name by remember { mutableStateOf(existing?.name ?: "MoviePilot") }
    var apiToken by remember { mutableStateOf(existing?.apiToken ?: "") }
    var username by remember { mutableStateOf(existing?.username ?: "") }
    var password by remember { mutableStateOf(existing?.password ?: "") }
    var mode by remember { mutableStateOf(existing?.endpointMode ?: EndpointMode.AUTO) }
    var pinned by remember { mutableStateOf(existing?.pinnedEndpointIndex ?: 0) }
    var testing by remember { mutableStateOf(false) }
    var testResult by remember { mutableStateOf<String?>(null) }
    var testOk by remember { mutableStateOf(true) }
    var confirmDelete by remember { mutableStateOf(false) }
    var saveError by remember { mutableStateOf<String?>(null) }

    val endpoints = remember(existing?.id) {
        mutableStateListOf<Endpoint>().apply {
            addAll(
                existing?.endpoints?.takeIf { it.isNotEmpty() }
                    ?: listOf(Endpoint(host = "", port = 3000, label = "内网"))
            )
        }
    }

    fun build(): MpServer = MpServer(
        id = existing?.id ?: UUID.randomUUID().toString(),
        name = name.trim(),
        // 允许整段粘贴 http(s)://host:port/path，保存时统一拆成 host/port/子路径
        endpoints = endpoints.map { it.normalized() }.filter { it.host.isNotBlank() },
        apiToken = apiToken.trim(),
        username = username.trim(),
        password = password,
        endpointMode = mode,
        pinnedEndpointIndex = pinned
    )

    fun save() {
        val candidate = build()
        if (candidate.activeEndpoints.isEmpty()) {
            saveError = "至少填一条访问地址（域名或 IP）。端口可以留空，https 走 443、http 走 80。"
            return
        }
        if (candidate.apiToken.isBlank()) {
            saveError = "请填写 API Token，否则无法调用 MoviePilot 接口。"
            return
        }
        onSave(candidate)
    }

    // 提示 / 删除确认弹出时先藏起表单，不做层叠背景
    if (saveError == null && !confirmDelete) {
        OiiDialog(
            title = if (existing == null) "添加 MoviePilot" else "编辑 MoviePilot",
            subtitle = existing?.displayName,
            confirmText = "保存",
            maxHeight = 400.dp,
            onDismiss = onDismiss,
            onConfirm = { save() }
        ) {
            FieldLabel("名称")
            Spacer(Modifier.height(6.dp))
            BasicField(name, "例如 家里的 MoviePilot") { name = it }

            Spacer(Modifier.height(14.dp))
            FieldLabel("API Token")
            Spacer(Modifier.height(6.dp))
            BasicField(apiToken, "MP → 设置 → 系统 → API Token", secret = true) { apiToken = it }
            Spacer(Modifier.height(4.dp))
            Text(
                "必填。它能让 App 调用 MP 的发现、搜索、投递、订阅接口。",
                fontSize = 10.sp,
                color = colors.textSecondary
            )

            Spacer(Modifier.height(14.dp))
            FieldLabel("MP 用户名 / 密码（可选）")
            Spacer(Modifier.height(6.dp))
            BasicField(username, "登录名") { username = it }
            Spacer(Modifier.height(8.dp))
            BasicField(password, "密码", secret = true) { password = it }
            Spacer(Modifier.height(4.dp))
            Text(
                "填了才能用「边搜边显示」的渐进式资源搜索（MP 用登录 Cookie 校验）。",
                fontSize = 10.sp,
                color = colors.textSecondary,
                lineHeight = 15.sp
            )

            Spacer(Modifier.height(16.dp))
            Row(verticalAlignment = Alignment.CenterVertically) {
                Text("访问地址", fontSize = 13.sp, fontWeight = FontWeight.Medium, color = colors.textPrimary)
                Spacer(Modifier.width(8.dp))
                Text("可填多条，自动挑能通的", fontSize = 10.5.sp, color = colors.textSecondary)
                Spacer(Modifier.weight(1f))
                Row(
                    Modifier.clickable { endpoints.add(Endpoint(host = "", port = 3000)) },
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
                                Icons.Rounded.Delete, null, tint = Palette.red,
                                modifier = Modifier.size(16.dp).clickable { endpoints.removeAt(index) }
                            )
                        }
                    }
                    Spacer(Modifier.height(8.dp))
                    BasicField(endpoint.host, "192.168.1.10 或 mp.example.com") {
                        endpoints[index] = endpoints[index].copy(host = it.trim())
                    }
                    Spacer(Modifier.height(8.dp))
                    Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                        BasicField(
                            if (endpoint.port in 1..65535) endpoint.port.toString() else "",
                            "端口（空=默认）",
                            modifier = Modifier.weight(1f),
                            keyboardType = KeyboardType.Number
                        ) { text ->
                            val port = text.filter { it.isDigit() }.take(5).toIntOrNull() ?: 0
                            endpoints[index] = endpoints[index].copy(port = port)
                        }
                        BasicField(
                            endpoint.basePath, "子路径 /mp（可空）",
                            modifier = Modifier.weight(1.4f)
                        ) { endpoints[index] = endpoints[index].copy(basePath = it.trim()) }
                    }
                    Spacer(Modifier.height(8.dp))
                    Row(verticalAlignment = Alignment.CenterVertically) {
                        BasicField(endpoint.label, "备注：家里 / 外网", modifier = Modifier.weight(1f)) {
                            endpoints[index] = endpoints[index].copy(label = it)
                        }
                        Spacer(Modifier.width(8.dp))
                        Box(
                            Modifier
                                .clip(RoundedCornerShape(9.dp))
                                .background(if (endpoint.https) Palette.green.copy(alpha = 0.15f) else colors.card)
                                .clickable { endpoints[index] = endpoints[index].copy(https = !endpoint.https) }
                                .padding(horizontal = 10.dp, vertical = 8.dp)
                        ) {
                            Text(
                                if (endpoint.https) "https" else "http",
                                fontSize = 11.sp,
                                color = if (endpoint.https) Palette.green else colors.textSecondary
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

            Spacer(Modifier.height(8.dp))
            Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                listOf(
                    EndpointMode.AUTO to "自动选择",
                    EndpointMode.MANUAL to "手动固定"
                ).forEach { (option, label) ->
                    val selected = mode == option
                    Box(
                        Modifier
                            .weight(1f)
                            .clip(RoundedCornerShape(10.dp))
                            .background(if (selected) colors.accent else colors.background)
                            .clickable { mode = option }
                            .padding(vertical = 10.dp),
                        contentAlignment = Alignment.Center
                    ) {
                        Text(
                            label, fontSize = 12.sp,
                            color = if (selected) Color.White else colors.textPrimary
                        )
                    }
                }
            }
            if (mode == EndpointMode.MANUAL) {
                Spacer(Modifier.height(8.dp))
                Row(horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                    endpoints.forEachIndexed { index, _ ->
                        Box(
                            Modifier
                                .clip(RoundedCornerShape(9.dp))
                                .background(if (pinned == index) colors.accent else colors.background)
                                .clickable { pinned = index }
                                .padding(horizontal = 12.dp, vertical = 7.dp)
                        ) {
                            Text(
                                "地址 ${index + 1}", fontSize = 11.sp,
                                color = if (pinned == index) Color.White else colors.textSecondary
                            )
                        }
                    }
                }
            }

            Spacer(Modifier.height(16.dp))
            Row(horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                Box(
                    Modifier
                        .weight(1f)
                        .clip(RoundedCornerShape(10.dp))
                        .background(Palette.blue.copy(alpha = 0.12f))
                        .clickable(enabled = !testing) {
                            testing = true
                            scope.launch {
                                val result = onTest(build())
                                testing = false
                                result.onSuccess {
                                    testOk = true
                                    testResult = it
                                }.onFailure {
                                    testOk = false
                                    testResult = it.message
                                }
                            }
                        }
                        .padding(vertical = 11.dp),
                    contentAlignment = Alignment.Center
                ) {
                    Text(if (testing) "测试中…" else "测试连接", fontSize = 13.sp, color = Palette.blue)
                }
                if (existing != null) {
                    Box(
                        Modifier
                            .weight(1f)
                            .clip(RoundedCornerShape(10.dp))
                            .background(Palette.red.copy(alpha = 0.12f))
                            .clickable { confirmDelete = true }
                            .padding(vertical = 11.dp),
                        contentAlignment = Alignment.Center
                    ) {
                        Text("删除服务器", fontSize = 13.sp, color = Palette.red)
                    }
                }
            }
            testResult?.let {
                Spacer(Modifier.height(8.dp))
                Text(it, fontSize = 11.sp, color = if (testOk) Palette.green else Palette.red)
            }

            // 列表行不再放「使用」按钮，切换入口收在这里（和鸿蒙端一致）
            if (existing != null && existing.id != activeId && onMakeActive != null) {
                Spacer(Modifier.height(8.dp))
                Box(
                    Modifier
                        .fillMaxWidth()
                        .clip(RoundedCornerShape(10.dp))
                        .background(Palette.green.copy(alpha = 0.12f))
                        .clickable {
                            onMakeActive(existing.id)
                            onDismiss()
                        }
                        .padding(vertical = 11.dp),
                    contentAlignment = Alignment.Center
                ) {
                    Text("设为当前使用", fontSize = 13.sp, color = Palette.green)
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
            title = "删除这台 MoviePilot？",
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
                "只删除 App 里的配置，不影响 MP 本身。",
                fontSize = 13.sp,
                color = colors.textPrimary
            )
        }
    }
}
