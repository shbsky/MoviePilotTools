package com.moviepilottools.mptools.net.dlna

import android.content.Context
import android.net.wifi.WifiManager
import android.util.Xml
import com.moviepilottools.mptools.net.Net
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.Request
import okhttp3.RequestBody.Companion.toRequestBody
import org.xmlpull.v1.XmlPullParser
import java.io.StringReader
import java.net.DatagramPacket
import java.net.DatagramSocket
import java.net.InetAddress
import java.net.URI

/**
 * 极简 DLNA/UPnP 投送客户端（只做 MediaRenderer 需要的那几个动作）。
 *
 * 为什么自己写：Songloft 的投屏是原生客户端的私有能力（它网页上明确写着
 * "Casting needs the native app — it is not available in a browser."），
 * 网页/API 都拿不到，只能 App 端自己走标准协议。
 *
 * 流程：SSDP M-SEARCH 发现设备 → 拉设备描述 XML 找 AVTransport 的 controlURL
 *      → SOAP 调 SetAVTransportURI + Play 把音频地址推过去（音箱自己去拉流）。
 */
object DlnaClient {

    private const val TAG = "DLNA-Cast"

    private const val SSDP_ADDR = "239.255.255.250"
    private const val SSDP_PORT = 1900
    private const val MEDIA_RENDERER = "urn:schemas-upnp-org:device:MediaRenderer:1"
    private const val AV_TRANSPORT = "urn:schemas-upnp-org:service:AVTransport:1"
    private const val RENDERING_CONTROL = "urn:schemas-upnp-org:service:RenderingControl:1"
    private const val SOAP_ENV = "http://schemas.xmlsoap.org/soap/envelope/"

    /** 发现到的投送目标 */
    data class Device(
        val name: String,
        val model: String,
        val location: String,
        val controlUrl: String,
        /** RenderingControl 的 controlURL：有它才能调音箱音量，没有就只能靠音箱自己的旋钮 */
        val volumeUrl: String = ""
    ) {
        val id: String get() = controlUrl
        val volumeSupported: Boolean get() = volumeUrl.isNotBlank()
    }

    /** 播放状态快照（用来判断一首放完了没有，好接着推下一首） */
    data class Transport(
        val state: String = "",
        val positionMs: Long = 0L,
        val durationMs: Long = 0L
    )

    // ---------------------------------------------------------------- 发现

    /**
     * 广播搜索 MediaRenderer。会临时持有 multicast lock —— 不持有时安卓会过滤组播包，
     * 一台设备都发现不了。
     */
    fun discover(context: Context, timeoutMs: Long = 4000L): List<Device> {
        val lock = acquireMulticastLock(context)
        try {
            val locations = LinkedHashSet<String>()
            DatagramSocket().use { socket ->
                socket.soTimeout = 1000
                socket.broadcast = true

                val message = buildString {
                    append("M-SEARCH * HTTP/1.1\r\n")
                    append("HOST: $SSDP_ADDR:$SSDP_PORT\r\n")
                    append("MAN: \"ssdp:discover\"\r\n")
                    append("MX: 2\r\n")
                    append("ST: $MEDIA_RENDERER\r\n")
                    append("USER-AGENT: MoviePilotTools/Android UPnP/1.1\r\n")
                    append("\r\n")
                }.toByteArray()

                // UDP 会丢包，发三次比较稳
                val target = InetAddress.getByName(SSDP_ADDR)
                repeat(3) {
                    runCatching {
                        socket.send(DatagramPacket(message, message.size, target, SSDP_PORT))
                    }
                }

                val deadline = System.currentTimeMillis() + timeoutMs
                val buffer = ByteArray(4096)
                while (System.currentTimeMillis() < deadline) {
                    val packet = DatagramPacket(buffer, buffer.size)
                    val received = runCatching { socket.receive(packet) }.isSuccess
                    if (!received) continue
                    val text = String(packet.data, 0, packet.length, Charsets.UTF_8)
                    val location = headerValue(text, "location") ?: continue
                    if (location.startsWith("http", true)) locations.add(location)
                }
            }

            return locations.mapNotNull { location ->
                runCatching { describe(location) }.getOrNull()
            }.distinctBy { it.controlUrl }
        } finally {
            releaseMulticastLock(lock)
        }
    }

    private fun acquireMulticastLock(context: Context): WifiManager.MulticastLock? = runCatching {
        val wifi = context.applicationContext.getSystemService(Context.WIFI_SERVICE) as WifiManager
        wifi.createMulticastLock("mpt-dlna").apply {
            setReferenceCounted(false)
            acquire()
        }
    }.getOrNull()

    private fun releaseMulticastLock(lock: WifiManager.MulticastLock?) {
        runCatching { lock?.takeIf { it.isHeld }?.release() }
    }

    /** 拉设备描述，取出友好名 + AVTransport 的 controlURL */
    private fun describe(location: String): Device? {
        val xml = Net.client.newCall(Request.Builder().url(location).build()).execute().use { res ->
            if (!res.isSuccessful) return null
            res.body?.string().orEmpty()
        }
        if (xml.isBlank()) return null

        val parser = Xml.newPullParser()
        parser.setInput(StringReader(xml))

        var friendlyName = ""
        var modelName = ""
        var deviceType = ""
        var currentService = ""
        var controlUrl = ""
        var avControl: String? = null
        var volumeControl: String? = null

        var event = parser.eventType
        while (event != XmlPullParser.END_DOCUMENT) {
            if (event == XmlPullParser.START_TAG) {
                when (parser.name) {
                    "friendlyName" -> if (friendlyName.isBlank()) friendlyName = readText(parser)
                    "modelName" -> if (modelName.isBlank()) modelName = readText(parser)
                    "deviceType" -> deviceType = readText(parser)
                    "serviceType" -> currentService = readText(parser)
                    "controlURL" -> {
                        controlUrl = readText(parser)
                        if (currentService.contains("AVTransport", true) && avControl == null) {
                            avControl = controlUrl
                        }
                        if (currentService.contains("RenderingControl", true) && volumeControl == null) {
                            volumeControl = controlUrl
                        }
                    }
                }
            }
            event = parser.next()
        }

        // 没有 AVTransport 的（比如纯纯的网关/路由器）直接丢掉
        val target = avControl ?: return null
        if (deviceType.isNotBlank() && !deviceType.contains("MediaRenderer", true)) return null

        return Device(
            name = friendlyName.ifBlank { modelName.ifBlank { "未知设备" } },
            model = modelName,
            location = location,
            controlUrl = absolute(location, target),
            volumeUrl = volumeControl?.let { absolute(location, it) }.orEmpty()
        )
    }

    private fun readText(parser: XmlPullParser): String {
        var text = ""
        var depth = 1
        while (depth > 0) {
            when (parser.next()) {
                XmlPullParser.START_TAG -> depth++
                XmlPullParser.END_TAG -> depth--
                XmlPullParser.TEXT -> if (depth == 1) text += parser.text.orEmpty()
            }
        }
        return text.trim()
    }

    private fun absolute(location: String, path: String): String {
        if (path.startsWith("http", true)) return path
        return runCatching {
            URI(location).resolve(path).toString()
        }.getOrDefault(path)
    }

    private fun headerValue(raw: String, key: String): String? {
        raw.lineSequence().forEach { line ->
            val index = line.indexOf(':')
            if (index > 0 && line.substring(0, index).trim().equals(key, true)) {
                return line.substring(index + 1).trim()
            }
        }
        return null
    }

    // ---------------------------------------------------------------- 控制

    /** 把音频地址推给音箱并开始播放 */
    fun play(device: Device, audioUrl: String, title: String, mime: String = "audio/mpeg"): Result<Unit> =
        runCatching {
            android.util.Log.i(TAG, "play() url=$audioUrl")
            android.util.Log.i(TAG, "play() mime=$mime title=$title device=${device.name}")
            val metadata = didl(title, audioUrl, mime)
            soap(
                device, "SetAVTransportURI",
                "<InstanceID>0</InstanceID>" +
                    "<CurrentURI>${escape(audioUrl)}</CurrentURI>" +
                    "<CurrentURIMetaData>${escape(metadata)}</CurrentURIMetaData>"
            )
            soap(device, "Play", "<InstanceID>0</InstanceID><Speed>1</Speed>")
            android.util.Log.i(TAG, "play() SetAVTransportURI + Play 都返回 200")
        }

    fun pause(device: Device): Result<Unit> = runCatching {
        soap(device, "Pause", "<InstanceID>0</InstanceID>")
    }

    fun stop(device: Device): Result<Unit> = runCatching {
        soap(device, "Stop", "<InstanceID>0</InstanceID>")
    }

    /** 拖动进度：AVTransport 的 Seek，Unit=REL_TIME 表示「跳到第几秒」 */
    fun seek(device: Device, positionMs: Long): Result<Unit> = runCatching {
        soap(
            device, "Seek",
            "<InstanceID>0</InstanceID><Unit>REL_TIME</Unit>" +
                "<Target>${msToTime(positionMs)}</Target>"
        )
    }

    /** 恢复播放（部分音箱没有 Pause，走 Play 也能继续） */
    fun resume(device: Device): Result<Unit> = runCatching {
        soap(device, "Play", "<InstanceID>0</InstanceID><Speed>1</Speed>")
    }

    // ---------------------------------------------------------------- 状态 / 音量

    /** 读当前播放状态与进度：轮询它就知道这首放完没有，好接着推下一首 */
    fun transport(device: Device): Transport {
        val stateXml = soap(device, "GetTransportInfo", "<InstanceID>0</InstanceID>")
        val positionXml = runCatching {
            soap(device, "GetPositionInfo", "<InstanceID>0</InstanceID>")
        }.getOrDefault("")
        val t = Transport(
            state = tagValue(stateXml, "CurrentTransportState"),
            positionMs = timeToMs(tagValue(positionXml, "RelTime")),
            durationMs = timeToMs(tagValue(positionXml, "TrackDuration"))
        )
        android.util.Log.d(TAG, "transport() state=${t.state} pos=${t.positionMs} dur=${t.durationMs}")
        return t
    }

    /**
     * 读音箱当前正在播放的媒体 URI（GetMediaInfo 的 CurrentURI）。
     *
     * 用途：判断音箱现在放的是不是我们推的流 —— 用户可能对小爱音箱语音点歌，
     * 或用别的设备接管了音箱，这时不能把状态翻转误判成「我们这首放完了」
     * 而自动推下一首去抢播。
     * 返回的是 XML 转义过的原文，调用方自行反转义后再比较。
     */
    fun mediaUri(device: Device): String {
        val xml = soap(device, "GetMediaInfo", "<InstanceID>0</InstanceID>")
        return tagValue(xml, "CurrentURI")
    }

    /** 音箱当前音量（0..100）；设备没开 RenderingControl 时返回 null */
    fun getVolume(device: Device): Int? {
        if (!device.volumeSupported) return null
        return runCatching {
            val xml = soap(
                device, "GetVolume",
                "<InstanceID>0</InstanceID><Channel>Master</Channel>",
                RENDERING_CONTROL, device.volumeUrl
            )
            tagValue(xml, "CurrentVolume").toIntOrNull()
        }.getOrNull()
    }

    /** 调音箱音量：投送时手机的实体音量键管不到音箱，只能走这个 */
    fun setVolume(device: Device, percent: Int): Result<Unit> = runCatching {
        if (!device.volumeSupported) throw DlnaException("这台设备不允许 App 调音量")
        soap(
            device, "SetVolume",
            "<InstanceID>0</InstanceID><Channel>Master</Channel>" +
                "<DesiredVolume>${percent.coerceIn(0, 100)}</DesiredVolume>",
            RENDERING_CONTROL, device.volumeUrl
        )
    }

    private fun tagValue(xml: String, name: String): String =
        Regex("<$name>(.*?)</$name>", RegexOption.DOT_MATCHES_ALL)
            .find(xml)?.groupValues?.getOrNull(1)?.trim().orEmpty()

    /** 毫秒 → UPnP 的时间格式 H:MM:SS */
    private fun msToTime(ms: Long): String {
        val total = (ms.coerceAtLeast(0L) / 1000L)
        val h = total / 3600
        val m = (total % 3600) / 60
        val sec = total % 60
        return String.format(java.util.Locale.US, "%d:%02d:%02d", h, m, sec)
    }

    /** UPnP 的时长格式是 H:MM:SS(.mmm)，按「从右往左、每段乘 60」解析最省事 */
    private fun timeToMs(raw: String): Long {
        val value = raw.trim()
        if (value.isEmpty() || value.startsWith("NOT_IMPLEMENTED")) return 0L
        var seconds = 0.0
        var weight = 1.0
        value.split(":").reversed().forEach { part ->
            seconds += (part.toDoubleOrNull() ?: 0.0) * weight
            weight *= 60
        }
        return (seconds * 1000).toLong()
    }

    private fun soap(
        device: Device,
        action: String,
        body: String,
        service: String = AV_TRANSPORT,
        target: String = device.controlUrl
    ): String {
        val envelope = "<?xml version=\"1.0\" encoding=\"utf-8\"?>" +
            "<s:Envelope xmlns:s=\"$SOAP_ENV\" s:encodingStyle=\"http://schemas.xmlsoap.org/soap/encoding/\">" +
            "<s:Body><u:$action xmlns:u=\"$service\">$body</u:$action></s:Body></s:Envelope>"

        val request = Request.Builder()
            .url(target)
            .header("SOAPACTION", "\"$service#$action\"")
            .header("Content-Type", "text/xml; charset=\"utf-8\"")
            .post(envelope.toRequestBody("text/xml; charset=utf-8".toMediaType()))
            .build()

        return Net.client.newCall(request).execute().use { res ->
            val text = res.body?.string().orEmpty()
            if (!res.isSuccessful) {
                // UPnP 的错误都放在 errorDescription 里（701 = 转场不可用，714 = 非法实例）
                val reason = Regex("<errorDescription>(.*?)</errorDescription>", RegexOption.DOT_MATCHES_ALL)
                    .find(text)?.groupValues?.getOrNull(1)
                    .orEmpty()
                android.util.Log.w(TAG, "$action -> HTTP ${res.code} reason=$reason")
                throw DlnaException(
                    when {
                        res.code == 500 && reason.isNotBlank() -> "$reason（HTTP 500）"
                        res.code == 500 -> "设备拒绝了这次投送（HTTP 500）"
                        else -> "投送失败（HTTP ${res.code}）"
                    }
                )
            }
            text
        }
    }

    private fun didl(title: String, audioUrl: String, mime: String): String =
        "<DIDL-Lite xmlns=\"urn:schemas-upnp-org:metadata-1-0/DIDL-Lite/\" " +
            "xmlns:dc=\"http://purl.org/dc/elements/1.1/\" " +
            "xmlns:upnp=\"urn:schemas-upnp-org:metadata-1-0/upnp/\">" +
            "<item id=\"1\" parentID=\"0\" restricted=\"1\">" +
            "<dc:title>${escape(title)}</dc:title>" +
            "<upnp:class>object.item.audioItem.musicTrack</upnp:class>" +
            "<res protocolInfo=\"http-get:*:$mime:*\">${escape(audioUrl)}</res>" +
            "</item></DIDL-Lite>"

    private fun escape(value: String): String = value
        .replace("&", "&amp;")
        .replace("<", "&lt;")
        .replace(">", "&gt;")
        .replace("\"", "&quot;")
        .replace("'", "&apos;")
}

class DlnaException(message: String) : Exception(message)
