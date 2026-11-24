# MPtools 鸿蒙重制版 PRD（简单版）

- 目标设备：华为 Mate 80 Pro Max（HarmonyOS NEXT，API 26）
- 参照基准：安卓版 MoviePilotTools（D:\WorkBuddy\MPtools\android\，48 个 Kotlin 文件，Compose UI）
- 编写：许清楚（产品经理）｜ 依据：逐文件通读安卓版源码提取，非凭空规划

---

## 1. 产品目标

把安卓版 MPtools 的**完整功能**原样搬到鸿蒙：一个自用的 IT 资产 / PT 工具箱，在一个 App 里管理 qBittorrent 与 Transmission 下载器（多服务器、多地址自动选路）、MoviePilot 影音库（榜单浏览 / 跨站搜资源 / 一键投递 / 订阅）、Songloft 音乐库（浏览 / 搜索 / 收藏 / 本机播放 / DLNA 投音箱），外加多服务器仪表盘和全套设置。鸿蒙版不是 Phase 1 缩水版——用户已明确否定「只有三个页面的骨架」，要求对齐安卓版全部能力，做到「手机上不用打开电脑就能管全部家当」。

---

## 2. 信息架构

底部 Tab 共 **5 个**（与安卓版一致，悬浮胶囊式圆角栏）：

```
┌ 仪表盘 ┬ 任务 ┬ 音乐 ┬ MoviePilot ┬ 设置 ┐
```

二级页面树：

```
仪表盘（DashboardScreen）
 ├─ 服务器选择下拉（全部服务器 / 各服务器 / 管理服务器…）
 ├─ 下载器卡片 → 跳「任务」页并只筛这台机器（返回键回仪表盘还原筛选）
 ├─ 媒体库卡片「未接入」→ 跳 MoviePilot 服务器列表
任务（TransfersScreen）
 └─ 任务详情（TorrentDetailScreen）：暂停/继续/校验/重新汇报/删除(含文件)
服务器管理（ServerListScreen → ServerEditScreen）  ← 全局覆盖层
音乐（MusicScreen）
 ├─ 歌单详情（playlist 视图，返回回列表）
 ├─ 搜索态（防抖搜索条 + 结果列表）
 ├─ 投送弹窗（CastDialog：设备列表 / 投送中面板）
 └─ 全屏播放页（NowPlayingScreen，沉浸式封面）
MoviePilot（MoviePilotScreen）
 ├─ 发现页：频道 Pill 横滑 + 三列海报瀑布（分页加载 + 海报上订阅按钮）
 ├─ 搜索页（关键字搜媒体 → 结果列表）
 ├─ 媒体详情（MediaDetailScreen）：演职员 / 订阅 / 候选资源搜索+筛选+投递
 │    └─ 筛选抽屉（FilterSheet）/ 投递抽屉（DownloadSheet）
 ├─ 订阅列表（SubscribeListScreen）：状态/进度/暂停恢复/删除
 └─ MP 服务器列表 / 编辑（MpServerListScreen / MpServerEditScreen）
设置（SettingsScreen）
 ├─ 关于弹窗（版本 / 构建 / 支持服务 / 隐私声明）
 ├─ 服务器设置 → 下载器服务器列表 / 编辑
 ├─ MoviePilot → MP 服务器列表
 ├─ 音乐服务（Songloft 配置弹窗：多行地址探测 / 账号密码 / 测试）
 ├─ 预设下载目录弹窗 / 刷新频率弹窗
 ├─ 外观主题 / 字体大小
 └─ 仪表盘定制（4 个模块开关）
（可选，见待确认）RSS 自动化（AutomationScreen → 源编辑抽屉 SourceEditorSheet）
```

全局覆盖层（盖在 Tab 之上，返回键逐层回退）：任务详情、下载器服务器列表/编辑、MP 服务器列表/编辑、全屏播放页。播放中在任意 Tab 底部常驻迷你播放条（MiniPlayerBar），切页不断歌。

---

## 3. 用户故事

### 仪表盘
- 作为用户，我想一眼看到「N/M 台在线」和当前总下载/上传速度，出门在外也能确认家里机器活着。
- 作为用户，我想在顶部下拉切换「全部服务器」或单台服务器，仪表盘数字随之只算这台。
- 作为用户，我想点某台下载器卡片直接跳到任务页看它的种子，返回键回仪表盘。
- 作为用户，我想在仪表盘看到 MoviePilot 媒体库统计（电影/电视剧/剧集/用户 + 本月新增）。
- 作为用户，我想自己开关仪表盘上的四个模块（流量监控/媒体库/数据聚合/服务器状态）。

### 下载器管理
- 作为用户，我想添加多台 qBittorrent / Transmission 服务器，一台可以填多条地址（内网 IP + 公网域名），App 并发探测自动挑能通的那条。
- 作为用户，我想整段粘贴 `https://mp.example.com:3000/qb/` 这样的地址，App 自动拆出协议/域名/端口/子路径。
- 作为用户，我想给 qBittorrent 5.2+ 直接填 API Key（Bearer 认证），或用传统账密。
- 作为用户，我想测试连接并看到「可用/连不上」的逐条探测结果。

### 任务管理
- 作为用户，我想按状态（全部/下载中/做种中/已完成/已暂停/错误）、分类、标签筛选任务，还能按名称搜索。
- 作为用户，我想按添加时间/名称/体积/进度/当前速度排序任务列表。
- 作为用户，我想点开任务详情看数据简报（速度/种子Peer/比率/做种时间/保存路径/Tracker/添加完成时间）。
- 作为用户，我想对任务做暂停/继续/强制校验/重新汇报，删除时可选「同时删除已下载的文件」（二次确认）。
- 作为用户，我想任务卡片上直接看到进度条、状态色（下载蓝/做种绿/错误红）、↓↑速度、Peer 数和分类标签。

### MoviePilot 影音库
- 作为用户，我想在发现页横滑切换 12 个频道（豆瓣热映/热门电影/热门剧集/豆瓣电影/豆瓣剧集/TOP250/华语口碑/全球口碑/番剧/TMDB趋势/TMDB电影/TMDB剧集），三列海报瀑布无限下滑。
- 作为用户，我想关键字搜索影片并从结果直接订阅。
- 作为用户，我想进详情页看简介/评分/类型/导演/演职员，并一键「订阅」（海报和详情页都能订）。
- 作为用户，我想在详情页「搜索资源」跨站找种子（站点多时要几十秒，提示可以边等边看）。
- 作为用户，我想按站点/分辨率/质量/编码筛选，勾「只看免费/促销」「隐藏 H&R」，按做种数/发布时间/大小/站点排序。
- 作为用户，我想看到每条资源的促销角标（免费/2X/免费2X/折扣）和分辨率/质量/编码徽章、种/下人数、发布时间。
- 作为用户，我想选下载器和保存路径（来自 MP 的下载器与目录配置）一键投递，由 MP 带站点 cookie 完成下载。
- 作为用户，我想管理 MP 订阅列表：看「订阅中/已暂停/已停止/新建」状态和「x / y 集」进度，能暂停/恢复/删除。
- 作为用户，我想配置多个 MoviePilot 服务器（API Token 必填、账密可选、多地址自动选路、测试连接）。

### 音乐（Songloft）
- 作为用户，我想浏览歌曲库（统计：N 首 · M 位歌手）和歌单横滑卡片，点歌单进详情连播。
- 作为用户，我想搜索歌曲（0.4 秒防抖即时出结果，可按歌曲/歌手/专辑匹配），键盘搜索键立即搜。
- 作为用户，我想点红心收藏歌曲（写入 Songloft 内建收藏歌单 id=1），收藏状态全局同步显示。
- 作为用户，我想「播放全部」当前列表，播放中切 Tab 不断歌（常驻迷你条：封面/歌名/上一首/暂停/下一首/退出）。
- 作为用户，我想进全屏播放页：沉浸式大封面、进度条点哪拖哪（44dp 触摸区）、循环模式三档（列表停/单曲循环/列表循环）、音量条藏在喇叭图标后弹出调节。
- 作为用户，我想时间行中间显示「原文件 · FLAC · 1022 kbps」这样的编码信息（学飞牛音乐）。
- 作为用户，我想投送到 DLNA 音箱：扫描局域网设备、选定后回列表点歌即自动投给音箱整表连播；投送中可五键控制（上一首/暂停/下一首等）并调音箱音量（不支持时提示用旋钮）。
- 作为用户，我想看到投送被音箱接管/本机接管的状态切换（投送中图标变蓝、迷你条显示「投送到 X」）。
- 作为用户，我想配置 Songloft：多行地址逐条探测 ✓/✕、账密、登录测试；token 本地持久化避免服务端登录限流。

### 设置
- 作为用户，我想集中管理所有服务器入口：下载器、MoviePilot、音乐服务、预设下载目录、刷新频率（2/3/5/10/30/60 秒）。
- 作为用户，我想切换外观主题（跟随系统/浅色/深色）和字体大小（90%~120%）。
- 作为用户，我想知道版本信息和支持的服务，并确认「数据全部留在本机」。

### RSS 自动化（安卓版代码保留但入口已下线，是否进鸿蒙版待确认，见 §6）
- 作为用户，我想添加 RSS 源并配规则：包含/排除关键字、体积上下限、集数过滤（01-12 / S01E01-E10）、分类/标签/保存路径/添加后暂停/优先级/目标下载器、站点 API Key 与自定义 Headers。
- 作为用户，我想看规则预览（绿色=命中会推送），开启「自动下载」后后台定时刷新、命中即推给下载器并发通知。

---

## 4. 需求池

### P0 —— 必须对齐安卓版的核心（35 条）

| # | 需求 | 安卓版对应 |
|---|------|-----------|
| 1 | 5 Tab 框架：仪表盘/任务/音乐/MoviePilot/设置，悬浮胶囊底栏 | MainActivity.kt（Tab enum + BottomBar） |
| 2 | 仪表盘 Hero 卡：在线数、总 ↓↑ 速度、最后刷新时间、服务器下拉选择 | DashboardScreen.kt（HeroCard） |
| 3 | 仪表盘「流量监控」模块（↓↑ 速度瓦片，可开关） | DashboardScreen.kt（SpeedTile） |
| 4 | 仪表盘「媒体库」模块：MP 媒体统计 4 项 + 本月新增，未接入引导 | DashboardScreen.kt（MediaLibraryCard） |
| 5 | 仪表盘「数据聚合」模块：做种总数/正在下载/实时总带宽/剩余空间 | DashboardScreen.kt（StatTile 区块） |
| 6 | 仪表盘「服务器状态」卡片（在线点、↓↑速度、做种体积、比率、剩余空间、错误信息），点击钻入任务页 | DashboardScreen.kt（ServerStatusTile） |
| 7 | 仪表盘四模块可定制开关 | SettingsScreen.kt（仪表盘定制） |
| 8 | 下载器服务器管理：添加/编辑/删除/测试连接，类型 qBittorrent/Transmission | ui/settings/ServerScreens.kt |
| 9 | 多端点地址：一行一条多行输入、自动归一化拆协议/端口/子路径、并发探测自动选路、手动锁定 | data/Models.kt（Endpoint/parseEndpoints）+ net/EndpointResolver.kt |
| 10 | qB 认证双通道：账密 Cookie 或 API Key（qB 5.2+ Bearer） | net/QBittorrentClient.kt |
| 11 | Transmission RPC（会话 ID 409 重试、rpcPath 可配） | net/TransmissionClient.kt |
| 12 | 任务列表：状态/分类/标签筛选 + 搜索 + 五种排序 + 汇总行（做种数/体积/速度） | TransfersScreen.kt（StatusFilter/SortMode/FilterBar） |
| 13 | 任务卡片：海报缩略图、进度、状态色、速度、Peer 数、分类标签 | TransfersScreen.kt（TaskCard） |
| 14 | 任务详情：数据简报全字段 + 6 种操作（暂停/继续/校验/重新汇报/删除/删文件）+ 删除二次确认 | TorrentDetailScreen.kt + vm/AppViewModel.kt（TorrentAction） |
| 15 | 下载器轮询刷新（可配 2~60 秒），状态汇总（ServerSnapshot：速度/做种数/体积/累计上下行/剩余空间/版本） | vm/AppViewModel.kt + net/QBittorrentClient.kt / TransmissionClient.kt |
| 16 | MoviePilot 发现页：12 个频道、三列海报网格、分页加载、海报渐变兜底 | MoviePilotScreen.kt + vm/MpViewModel.kt（MpChannels） |
| 17 | MP 媒体搜索：关键字 → 结果列表 → 可直接订阅 | MoviePilotScreen.kt（SearchScreen） |
| 18 | 媒体详情：背景图/海报、简介、评分、类型、导演、演职员 | MediaDetailScreen.kt |
| 19 | 一键订阅/取消订阅（海报角标 + 详情页按钮，含季参数） | MoviePilotClient.kt（subscribe/deleteSubscribe/updateSubscribeState） |
| 20 | 候选资源跨站搜索：流式解析（边收边显示）、总数提示、耗时预期文案 | net/MoviePilotClient.kt（searchResources） |
| 21 | 资源筛选抽屉：站点/分辨率/质量/编码 + 只看免费促销/隐藏 H&R + 5 字段排序升降序 | data/MpModels.kt（ResourceFilter/ResourceSortField）+ MediaDetailScreen.kt（FilterSheet） |
| 22 | 资源行展示：站点、促销角标（免费/2X/免费2X/折扣）、分辨率/质量/编码徽章、体积、种/下、发布时间 | MediaDetailScreen.kt（ResourceRow）+ MpModels.kt |
| 23 | 投递抽屉：MP 下载器选择 + MP 保存路径选择 + 确认下载（MP 决定投递方式带 cookie） | MediaDetailScreen.kt（DownloadSheet）+ MoviePilotClient.kt（downloaders/savePaths/addDownload） |
| 24 | 订阅列表：状态标签（订阅中/已暂停/已停止/新建）、集数进度、暂停恢复、删除 | MpModels.kt（MpSubscribe）+ MoviePilotScreen.kt（SubscribeListScreen） |
| 25 | MP 服务器管理：多服务器、API Token 必填校验、可选账密、多端点、测试、删除 | ui/moviepilot/MpServerScreens.kt |
| 26 | 音乐库浏览：统计副标题、歌单横滑卡、歌单详情、全部歌曲列表、播放全部 | MusicScreen.kt + net/SongloftClient.kt |
| 27 | 音乐防抖搜索（0.4s，歌曲/歌手/专辑），IME 搜索键直搜 | MusicScreen.kt（SearchBar） |
| 28 | 收藏红心：读内建收藏歌单（id=1），POST/DELETE 切换，列表与全屏页同步 | net/SongloftClient.kt（favoriteIds/setFavorite） |
| 29 | 本机播放核心：播放/暂停/上下首/拖动进度/本机音量、切 Tab 不断歌 | player/PlaybackCore.kt + player/MusicService.kt + vm/MusicViewModel.kt |
| 30 | 迷你播放条（常驻）+ 全屏播放页（沉浸封面、44dp 进度条、循环三档、弹出式音量条、「原文件 · FLAC · 1022 kbps」编码行） | ui/music/PlayerBars.kt |
| 31 | DLNA 投音箱：SSDP 扫描、投送整表连播、五键控制、音箱音量调节/不支持提示、选定设备后点歌直投、被接管状态互斥 | net/dlna/DlnaClient.kt + player/CastService.kt + vm/CastController.kt + CastSheet.kt |
| 32 | Songloft 配置弹窗：多行地址逐条 TCP/HTTP 探测 ✓/✕、账密、登录测试 | SettingsScreen.kt（MusicServerDialog） |
| 33 | Songloft token 持久化（避免服务端登录限流） | data/TokenVault.kt |
| 34 | 设置页全量：状态卡/关于弹窗、资源管理组（服务器/MP/音乐/预设目录/刷新频率）、外观主题、字体大小 | SettingsScreen.kt |
| 35 | 本地配置持久化（服务器、端点、设置、RSS 规则全部留本机） | data/ConfigStore.kt |
| 36 | App 图标沿用安卓版图标（禁止另设计）：直接拷贝 `D:\WorkBuddy\MPtools\android\app\src\main\res\mipmap-xxxhdpi\ic_launcher.png`（192×192，深色圆角底 + MP 渐变字）为鸿蒙工程资源，覆盖现有占位图。工程处理：拷为 AppScope/resources/base/media/app_icon.png 与 entry 的 icon 资源同名文件（现有工程引用 $media:app_icon 于 AppScope/app.json5、$media:icon 于 entry module.json5，替换同名资源即可，不改引用） | 用户指定（安卓版 mipmap-xxxhdpi/ic_launcher.png） |

### P1 —— 重要，可排第二轮（6 条）

| # | 需求 | 安卓版对应 |
|---|------|-----------|
| 37 | RSS 自动化全套：源管理（启停/收藏图标兜底/规则摘要）、源编辑抽屉（关键字/体积/集数过滤/Headers/API Key/投递设置/优先级）、规则预览（绿色命中高亮） | ui/automation/AutomationScreen.kt + SourceEditorSheet.kt + data/RssModels.kt |
| 38 | RSS 规则引擎 + 后台轮询 + 系统通知（自动追番） | data/RssRuleEngine.kt + RssRepository.kt + work/RssWorker.kt |
| 39 | 豆瓣海报请求头处理（Referer 拦截器，否则豆瓣图挂掉） | net/DoubanImageHeaderInterceptor.kt |
| 40 | 端点探测缓存与 hostKey 去重、端口留空走协议默认端口 | data/Models.kt（Endpoint.normalized/hostKey） |
| 41 | 全局 Toast 体系（统一 2.2~2.4s 自动消失，各 VM 共用） | MainActivity.kt + 各 ViewModel |
| 42 | 返回键/手势逐层回退（详情→列表→搜索逐层退，不直接退出 App；仪表盘钻入任务页返回还原筛选） | MainActivity.kt + MoviePilotScreen.kt（BackHandler 链） |

### P2 —— 锦上添花（5 条）

| # | 需求 | 安卓版对应 |
|---|------|-----------|
| 43 | 海报加载失败的渐变色兜底（按标题生成） | MoviePilotScreen.kt（posterFallback） |
| 44 | 全部条目视图（RSS 已见条目历史、命中高亮） | data/RssModels.kt（RssItemRecord） |
| 45 | 仪表盘模块顺序自定义（dashboardOrder 配置已存在但 UI 未暴露） | data/ConfigStore.kt（AppSettings.dashboardOrder） |
| 46 | 时间相对化显示（「3 小时前」）等格式化细节 | data/Format.kt |
| 47 | 投送页音量百分比实时数字、拖动中防抖（避免系统档位回跳） | PlayerBars.kt（CompactSlider）+ CastController.kt |

**统计：P0 × 36，P1 × 6，P2 × 5，共 47 条。**

---

## 5. UI 规划要点（按页骨架）

**全局**
- **App 图标（用户硬性要求）**：沿用安卓版图标，禁止另设计。源文件 `D:\WorkBuddy\MPtools\android\app\src\main\res\mipmap-xxxhdpi\ic_launcher.png`（192×192，深色圆角底 + MP 渐变字）。工程侧直接把该 png 拷为 AppScope/resources/base/media/app_icon.png 与 entry 的 $media:icon 资源同名覆盖现有占位图，不改引用（AppScope/app.json5 引 $media:app_icon，entry module.json5 引 $media:icon）。
- 深色为主的卡片式设计语言：圆角卡片、分色图标底（蓝/绿/紫/橙/粉）、状态色语义（下载蓝 #0A84FF、做种绿 #34C759、错误红 #FF3B30、排队紫 #5E5CE6、校验橙 #FF9500）。
- 悬浮胶囊底栏（圆角 24dp 阴影卡片），5 个 Tab 图标+文字，选中蓝色。
- 顶部安全区避让（鸿蒙状态栏）、列表底部预留 110dp 避让底栏和迷你条。
- 全局 Toast：底部居中深色圆角条。

**仪表盘**：顶部 Hero 渐变卡（蓝→靛蓝，标题「MoviePilotTools Harmony」+ 服务器下拉胶囊 + 在线点 + 大号 ↓↑ 速度 + 刷新时间）→ 两列速度瓦片 → 媒体库 2×2 统计格（含「本月新增 N」小字）→ 数据聚合 2×2 → 服务器卡片两列网格（点卡钻入任务页）。

**任务页**：顶栏（服务器下拉 + 标题「传输任务」+ 排序菜单 + 刷新钮）→ 搜索框 → 筛选条（状态/分类/标签三个下拉 Pill，激活变蓝带计数）→ 汇总行 → 任务卡列表（左海报缩略图，中间名称+进度条+分类标签，右速度/进度百分比）。详情页：头部（名称+状态色条）→ 数据简报网格 → 操作按钮排（暂停/继续/校验/重新汇报）→ 信息行列表 → 底部红色「删除」带确认弹窗（含「同时删除文件」开关）。

**音乐页**：顶栏（标题/副标题 + 搜索/刷新/投送三图标，投送中变蓝）→ 歌单横滑 104dp 方卡 → 「全部歌曲」标题 + 粉色「播放全部」胶囊 → 歌曲行（48dp 封面、歌名/歌手、时长、右侧红心，播放中高亮）。全屏播放页：沉浸式封面（占屏上部）→ 「正在播放」小标 + 歌名歌手 → 时间行（左当前时间 · 中「原文件 · FLAC · 1022 kbps」· 右总时长）→ 粗轨道进度条（44dp 触摸区）→ 底部控制排：循环/上一首/播放暂停/下一首/喇叭（音量条弹出）。

**MoviePilot 页**：顶栏（标题 + 服务器名可点 + 搜索/订阅图标）→ 频道 Pill 横滑 → 三列海报网格（0.68 宽高比、右下角订阅角标、底部加载圈）。详情页：大背景图 + 标题/年份/类型/评分 → 订阅按钮 → 简介 → 类型/导演 → 演职员横滑 → 「候选资源」区：搜索按钮（含耗时提示文案）→ 排序/筛选行（筛选数角标）→ 资源行（站点名、促销角标、徽章、体积、种/下、下载按钮）。投递抽屉：下载器单选 → 保存路径单选 → 蓝色「确认下载」→ 底部说明文案。

**设置页**：状态卡（图标 + 名称 + 「已连接 N/M 台服务器」+ 绿色「运行中」徽章）→ 「资源管理」组（服务器设置/MoviePilot/音乐服务/预设下载目录/刷新频率五行，右侧显示值摘要）→ 「应用设置」组（主题/字体）→ 「仪表盘定制」组（四个开关行）→ 「关于」组（版本/构建/支持）。

**服务器编辑页**（下载器与 MP 共用模式）：名称 → 类型选择（下载器）或 API Token（MP，必填红字校验）→ 多端点列表（「地址 N」行 + 添加钮）→ 选路方式（自动/手动）→ 认证区 → RPC 路径（仅 Transmission）→ 测试连接（含逐条 ✓/✕）→ 删除服务器（红色 + 确认弹窗）。

---

## 6. 待确认问题

1. **RSS 自动化要不要进鸿蒙 v1？** 安卓版代码里 RSS 模块（规则引擎、后台 Worker、自动化页）完整保留，但 Tab 已被音乐页取代（MainActivity 启动时会主动 cancel 后台任务）。此前确认过「RSS 订阅规则引擎后台自动追番」是安卓版功能——请拍板：鸿蒙版是 (a) 作为独立页面放进 v1（需求池 #36-37 已列 P1），还是 (b) 像安卓现状一样代码级保留但暂不给入口，还是 (c) 彻底不要。
2. **鸿蒙后台能力取舍**：安卓用 WorkManager 做 RSS 周期轮询、前台 Service 保活播放和投送心跳。鸿蒙 NEXT 的后台任务受长时任务（continuous task）白名单约束——音乐播放可以申请 AVPlayback 长时任务并出通知栏控制，但「RSS 后台轮询」可能只能做成「前台打开时定时刷新」。是否接受这个降级？通知栏媒体控制卡片要不要做（安卓版有 Media3 通知）？
3. **DLNA 投送是否算 P0？** 需求池目前把 #31 列为 P0。但鸿蒙 NEXT 上 SSDP 组播发现依赖局域网权限与 socket 行为，真机未验证。若第一轮风险太大，可降为 P1，先只做本机播放。请确认。
4. **多服务器「选路」策略是否原样复刻**：安卓版是「每次连接前并发探测全部端点、选最快能通的」，探测失败自动轮换。鸿蒙版照搬，还是简化为「顺序尝试、记住上次成功的那条」？后者省电省流量，但切换网络时首次连接会慢一点。
5. **应用名与品牌**：仪表盘 Hero 卡上安卓版写「MoviePilotTools Android」，鸿蒙版写「MoviePilotTools Harmony」还是沿用图标名「MPtools」？bundle id 已定 com.moviepilottools.mptools，仅涉及显示文案。

## 7. 用户决策（2026-11-14 拍板，架构师/工程师必须遵照执行）
1. **RSS 自动化**：选 b —— 对齐安卓现状：规则引擎/数据模型代码级保留，但**不提供页面入口**，v1 不做 RSS 页面与后台轮询。
2. **DLNA 投音箱**：选 a —— P0，第一轮完整实现（SSDP 扫描 + 五键控制 + 音量 + 被接管让位逻辑）。
3. **后台播放**：选 a —— 完整后台：长时任务（backgroundTaskManager audioPlayback）+ AVSession 锁屏封面 + 通知栏媒体控制卡片。
4. **多服务器选路**：选 a —— 原样复刻安卓版「多地址并发探测选最快」，不简化。
5. **应用显示名**：定为「MPtools」（bundle 保持 com.moviepilottools.mptools）。
