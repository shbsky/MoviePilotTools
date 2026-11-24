# 音乐模块设计说明（Songloft 接入 · 投送小爱方案）

> 版本：v1.3.0 起
> 状态：第一阶段（音乐库 + 本机播放）**已实现**；第二阶段（投送到小爱音箱 / 发指令）**待接入凭据后实施**

---

## 一、第一阶段：已落地

### 1. 数据源

Songloft（`http://192.168.1.10:58091`），接口契约是从它前端 Lynx bundle 里逆出来的，
不是猜的 —— 见 `net/SongloftClient.kt` 顶部注释：

| 用途 | 请求 | 返回 |
|---|---|---|
| 登录 | `POST /api/v1/auth/login` `{username, password}` | `{access_token, refresh_token, expires_in}` |
| 歌曲列表 | `GET /api/v1/songs?limit&offset&keyword` | `{items:[...], total}` |
| 歌单列表 | `GET /api/v1/playlists?limit&offset` | `{items:[...], total}` |
| 歌单歌曲 | `GET /api/v1/playlists/{id}/songs` | `{items:[...], total}` |
| 音乐库统计 | `GET /api/v1/songs/stats` | `{total_songs, artist_count, album_count, ...}` |
| 健康检查 | `GET /api/v1/health` | `{"status":"ok"}` |

鉴权两种通道都会用上：

- **JSON 接口** → `Authorization: Bearer <access_token>`
- **音频流 / 封面图** → URL 追加 `?access_token=xxx`
  （Songloft 自己的播放器就是这么拼的：`s1()` 函数对相对地址补 base + `access_token`）

安卓侧实现：
- `net/SongloftClient.kt` —— 登录、token 复用、401 自动重登一次、分页、搜索
- `net/SongloftAuthInterceptor.kt` —— 按 host+port 命中当前 Songloft 时补 Bearer 头，
  让 Coil 加载封面、MediaPlayer 拉音频也能通过鉴权，不影响其它请求
- 字段解析对 `snake_case` / `camelCase` 双兼容，`artist` 支持字符串 / 对象 / 数组三种形态

### 2. 界面

| 区域 | 内容 |
|---|---|
| 底部标签 | 「自动化」→「音乐」（`Icons.Rounded.LibraryMusic`，粉色主色 `#FF2D55`） |
| 音乐页顶部 | 标题 + 「N 首 · M 位歌手」；右侧搜索 / 刷新；进入歌单时变成返回箭头 |
| 歌单区 | 横向滚动卡片（封面 + 名称 + 曲目数） |
| 歌曲列表 | 48dp 封面、标题、`歌手 · 专辑`、时长；滑到底自动加载下一页（每页 60） |
| 搜索结果 | 同列表复用，标题区隐藏歌单 |
| 迷你播放条 | 常驻在底部标签栏上方，**切到其它标签页也显示**，带 2dp 播放进度线 |
| 全屏播放页 | 大封面、可拖动进度条、上一首/播放暂停/下一首 |

### 3. 播放

`player/MusicPlayer.kt` —— 直接用 `MediaPlayer`，没引入 ExoPlayer：

- 队列 + 上一首/下一首；播放超过 3 秒按「上一首」先回到开头（主流播放器行为）
- 播完最后一首停在结尾，不循环
- `AudioFocusRequest` 抢焦点，被来电/其它播放器打断自动暂停
- 400ms 刷新一次进度，`SEEK_CLOSEST` 精确跳转
- MediaPlayer 活在 ViewModel 里，切标签页不断；应用被杀则停止（前台服务是第二阶段的事）

### 4. 配置入口

设置 → 资源管理 → **音乐服务**：地址 / 账号 / 密码 + 「测试」按钮（会真登录一次并读音乐库统计，
直接告诉你「登录成功 · 音乐库 1234 首 / 321 位歌手」）。账号密码跟其它配置一起走
AndroidKeyStore AES/GCM 加密存储。

---

## 二、第二阶段：投送 / 小爱（待实施）

### 关键限制（先说清楚）

Songloft 的投屏能力写在它自己的界面里：
> "Casting needs the native app — it is not available in a browser."

也就是说**投送是它原生客户端的私有能力，网页/API 侧拿不到**。
所以「投到小爱音箱」不能靠调 Songloft 实现，必须在安卓端自己做。

### 三条路线对比

| 路线 | 做法 | 需要什么 | 能做什么 | 风险 |
|---|---|---|---|---|
| **A（已完成）** | 手机本机播放 | 无 | 浏览、搜索、播放 | 声音只在手机上 |
| **B** | 自研 DLNA（SSDP + AVTransport） | 无（局域网内发现设备） | 把 Songloft 的音频推到小爱音箱播放 | 音箱要能访问音频 URL（局域网 IP 或公网映射）；小爱对 DLNA 的兼容性因固件而异 |
| **C** | 小米 MIoT 云（xiaogpt 那套） | 小米账号 `userId` + `serviceToken` + `cookie`（手动抓） | 任意 TTS 指令：放歌/问天气/开关灯 | 凭据会过期；登录常要验证码；接口非公开，随固件变动 |

### B 方案实现细节（DLNA）

1. **发现**：UDP 组播 `M-SEARCH * HTTP/1.1` 到 `239.255.255.250:1900`，
   `ST: urn:schemas-upnp-org:device:MediaRenderer:1`，收 `LOCATION` 头
2. **描述**：GET `LOCATION` 拿 device description XML，解析出
   `AVTransport`（控播放）和 `RenderingControl`（控音量）的 `controlURL`
3. **推送**：SOAP `SetAVTransportURI` 传音频 URL + `CurrentURIMetaData`（DIDL-Lite），再 `Play`
4. **控制**：`Pause` / `Stop` / `Seek` / `GetPositionInfo` / `SetVolume`
5. **前提**：音箱得能直接 GET 到那个音频 URL。Songloft 在内网 `192.168.1.10:58091` 时，
   只要音箱和 NAS 同一网段就通；跨网段就得靠你已经在做的公网映射。
   注意带 `access_token` 的 URL 是长期有效的临时令牌，投送时直接整条给音箱即可。

工作量估计：发现 + 描述解析 + 3 个 SOAP 动作 ≈ 400 行，一天内能出可用版本。

### C 方案实现细节（小爱指令）

小爱音箱的 MIoT 服务是 `urn:miot-spec-v2:device:speaker`，常用 siid/piid：

- `player_play_url`（放指定音频 URL）
- `play-text` / TTS 播报（说一句话）
- `player_play_music`（按内容源播放，参数复杂）

需要的凭据（只能你手动取，脚本登录会被验证码拦）：

```
userId        （小米账号数字 ID）
serviceToken  （从 micoapi 抓，约一个月过期）
cookie        （含 userId 与 serviceToken）
```

取法：浏览器登录 `https://account.xiaomi.com` → F12 → Application → Cookies，
复制 `userId`、`serviceToken`；或按 xiaogpt 文档用 `micli` 抓一次。

### 建议实施顺序

1. **B 先行**：不需要任何账号凭据，纯局域网协议，能立刻实现「把歌投到小爱播放」
2. **C 后补**：等你把 `userId / serviceToken / cookie` 给我，再做「语音指令 + TTS 播报」
3. 第二阶段还要顺带做：**前台服务**（锁屏常驻通知 + 后台不断播）、
   **MediaSession**（耳机线控 / 车机 / 锁屏控制）

---

## 三、代码地图

```
data/MusicModels.kt         歌曲 / 歌单 / 页面状态 / 播放状态
net/SongloftClient.kt       Songloft 全部接口 + token 会话（SongloftSession）
net/SongloftAuthInterceptor.kt   图片/音频请求补 Bearer
player/MusicPlayer.kt       MediaPlayer 队列播放器
vm/MusicViewModel.kt        列表/分页/搜索/歌单 + 播放调度
ui/music/MusicScreen.kt     音乐页（歌单横滑 + 歌曲列表 + 搜索）
ui/music/PlayerBars.kt      迷你播放条 + 全屏播放页
```

RSS 模块的代码文件（`data/RssModels.kt`、`work/RssWorker.kt`、`ui/automation/*`）暂时保留，
但入口已移除、后台定时任务已在启动时取消；确认不再需要后再整体删除。
