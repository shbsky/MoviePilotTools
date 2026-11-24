package com.moviepilottools.mptools.ui.settings

import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
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
import androidx.compose.material.icons.rounded.ArrowBack
import androidx.compose.material.icons.rounded.VerifiedUser
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.moviepilottools.mptools.ui.components.DividerLine
import com.moviepilottools.mptools.ui.theme.LocalMptColors
import com.moviepilottools.mptools.ui.theme.Metrics
import com.moviepilottools.mptools.ui.theme.Palette

/**
 * 用户协议 / 免责声明。
 *
 * 纯本地静态文本：不从网络拉、不落库、不接受任何输入。
 * 改动文案只动下面这几个 List，别在 Composable 里塞条件逻辑。
 */
private const val UPDATED_AT = "最后更新：2026-11-16"

private val definition = listOf(
    "本软件【MoviePilotTools】是第三方远程管理客户端工具。",
    "本软件本身不生产、不存储、不托管、不分发任何视频、音频、种子、影视资源文件，也不提供资源检索、资源下载、资源分享服务。",
    "所有功能仅通过网络 API，连接用户自行部署、自行维护的后端服务（包含但不限于 MoviePilot、Transmission、qBittorrent、Songloft），向用户自有后端下发控制指令、展示后端返回的状态数据。",
    "所有媒体信息、种子任务、站点数据、音乐内容，全部来源于用户自己搭建的后端服务，不由本 APP 生成或提供。"
)

private val promises = listOf(
    "用户保证：自行拥有所部署后端服务器、存储文件的相关权限，仅使用本工具管理自身拥有合法著作权 / 使用权的媒体、文件与资源。",
    "用户承诺，不会利用本工具及后端服务，未经著作权人许可，实施下载、订阅、抓取、上传、做种、分享受版权保护的影视、音乐等作品。未经授权传播版权作品属于侵权行为，严重时将涉及行政处罚乃至刑事责任。",
    "用户知晓：PT 站点、BT 做种等相关操作存在版权风险，所有站点账号、流量、种子任务均由用户独立管理，与本软件开发者无关。"
)

private val liability = listOf(
    "本工具仅提供远程管理的技术通道，无法审查、识别、判断用户后端服务中的文件、种子、媒体内容是否侵权；开发者无法访问、查看用户后端内的私有文件。",
    "用户利用本软件、搭配后端服务实施的任何侵权、违法操作，全部法律责任由用户独立承担，软件开发者不承担任何连带、补充责任。",
    "因用户服务器故障、网络异常、第三方 Tracker / PT 站点、MoviePilot / qB / Tr / Songloft 后端本身产生的数据丢失、账号封禁、版权投诉、行政处罚、民事索赔等全部损失，均由用户自行承担。",
    "在法律允许最大范围内，开发者不承担任何间接损失、衍生损害赔偿责任。若版权权利人向开发者提交有效侵权通知，开发者可配合转达通知，但无义务审查用户私有后端内的内容。"
)

private val usage = listOf(
    "本工具不内置种子库、资源广场、PT 站点入口、资源推荐等功能；APP 仅作为连接用户自有后端的控制器。",
    "禁止用户利用本软件从事违反中华人民共和国法律法规的行为，一旦违规，开发者有权终止使用权限。",
    "软件内展示的影视海报、影片名称、评分等元数据，均是用户后端 MoviePilot 服务拉取返回的数据，并非本 APP 内置资源。"
)

@Composable
fun TermsScreen(onBack: () -> Unit) {
    val colors = LocalMptColors.current

    Column(
        Modifier
            .fillMaxSize()
            .background(colors.background)
    ) {
        // 顶栏：跟其它二级页一致，左侧圆形返回
        Row(
            Modifier
                .fillMaxWidth()
                .padding(horizontal = Metrics.pagePadding, vertical = 10.dp),
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
                    null,
                    tint = colors.textPrimary,
                    modifier = Modifier.size(19.dp)
                )
            }
            Spacer(Modifier.weight(1f))
            Text(
                "用户协议",
                fontSize = 17.sp,
                fontWeight = FontWeight.SemiBold,
                color = colors.textPrimary
            )
            Spacer(Modifier.weight(1f))
            Spacer(Modifier.size(34.dp))
        }

        Column(
            Modifier
                .fillMaxSize()
                .verticalScroll(rememberScrollState())
                .padding(horizontal = Metrics.pagePadding)
                .padding(bottom = 60.dp)
        ) {
            HeaderCard()

            Section("一、软件定义", definition)
            Section("二、用户承诺", promises, numbered = true)
            Section("三、免责与责任划分", liability, numbered = true)
            Section("四、软件使用约定", usage, numbered = true)

            Spacer(Modifier.height(14.dp))
            Text(
                UPDATED_AT,
                fontSize = 11.sp,
                color = colors.textSecondary,
                modifier = Modifier.fillMaxWidth()
            )
            Spacer(Modifier.height(6.dp))
            Text(
                "继续使用本软件即表示你已阅读、理解并同意上述全部条款。若不同意，请停止使用并卸载。",
                fontSize = 11.sp,
                color = colors.textSecondary,
                lineHeight = 17.sp
            )
        }
    }
}

@Composable
private fun HeaderCard() {
    val colors = LocalMptColors.current
    Column(
        Modifier
            .fillMaxWidth()
            .clip(RoundedCornerShape(12.dp))
            .background(colors.card)
            .padding(16.dp)
    ) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            Box(
                Modifier
                    .size(30.dp)
                    .clip(RoundedCornerShape(9.dp))
                    .background(Palette.blue.copy(alpha = 0.12f)),
                contentAlignment = Alignment.Center
            ) {
                Icon(
                    Icons.Rounded.VerifiedUser,
                    null,
                    tint = Palette.blue,
                    modifier = Modifier.size(17.dp)
                )
            }
            Spacer(Modifier.width(10.dp))
            Column(Modifier.weight(1f)) {
                Text(
                    "MoviePilotTools",
                    fontSize = 15.sp,
                    fontWeight = FontWeight.SemiBold,
                    color = colors.textPrimary
                )
                Spacer(Modifier.height(2.dp))
                Text(
                    "多服务远端管理工具",
                    fontSize = 11.sp,
                    color = colors.textSecondary
                )
            }
        }

        Spacer(Modifier.height(12.dp))
        Box(
            Modifier
                .fillMaxWidth()
                .clip(RoundedCornerShape(9.dp))
                .background(Palette.blue.copy(alpha = 0.09f))
                .padding(11.dp)
        ) {
            Text(
                "APP 本地不产生、不存储、不分发任何媒体 / 种子资源",
                fontSize = 12.sp,
                fontWeight = FontWeight.Medium,
                color = Palette.blue,
                lineHeight = 18.sp
            )
        }

        Spacer(Modifier.height(12.dp))
        Text(
            "适用场景：对接用户自行部署的 MoviePilot、Transmission、qBittorrent、Songloft 等后端服务，APP 仅做远程状态查看与指令下发。",
            fontSize = 12.sp,
            color = colors.textPrimary,
            lineHeight = 19.sp
        )

        Spacer(Modifier.height(10.dp))
        Text(
            "重要提醒：协议属于风险隔离的书面声明，无法 100% 免除法律风险；核心风控是软件本身不内置资源、不内置种子、不托管 PT 站点、不主动引导资源下载。",
            fontSize = 11.sp,
            color = colors.textSecondary,
            lineHeight = 17.sp
        )
    }
}

@Composable
private fun Section(title: String, paragraphs: List<String>, numbered: Boolean = false) {
    val colors = LocalMptColors.current
    Spacer(Modifier.height(14.dp))
    Column(
        Modifier
            .fillMaxWidth()
            .clip(RoundedCornerShape(12.dp))
            .background(colors.card)
            .padding(14.dp)
    ) {
        Text(
            title,
            fontSize = 14.sp,
            fontWeight = FontWeight.SemiBold,
            color = colors.textPrimary
        )
        Spacer(Modifier.height(9.dp))
        paragraphs.forEachIndexed { index, text ->
            if (index > 0) {
                Spacer(Modifier.height(9.dp))
                DividerLine(Modifier.fillMaxWidth())
                Spacer(Modifier.height(9.dp))
            }
            Row(Modifier.fillMaxWidth()) {
                if (numbered) {
                    Text(
                        "${index + 1}.",
                        fontSize = 12.sp,
                        color = colors.textSecondary,
                        modifier = Modifier.width(20.dp)
                    )
                }
                Text(
                    text,
                    fontSize = 12.sp,
                    color = colors.textSecondary,
                    lineHeight = 19.sp,
                    modifier = Modifier.weight(1f)
                )
            }
        }
    }
}
