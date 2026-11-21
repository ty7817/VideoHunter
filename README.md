# 视频猎手 VideoHunter

输入一个网页链接，自动识别页面里所有能播放的视频地址，并直接用内置播放器播放。

- 当前版本：**2.6 / Build 10**
- 平台：iOS 16.0+（iPhone / iPad）
- 形态：SwiftUI + WKWebView + AVPlayer，纯原生，无第三方依赖
- 产物：完整 Xcode 工程，可直接编译；也提供 GitHub Actions 一键产出未签名 IPA

---

## 2.6 新增（本版本）

| 能力 | 说明 |
| --- | --- |
| 独立设置页面 | 设置中心不再是半屏 sheet，改为全屏独立页面；从首页齿轮、右上角菜单或播放器菜单进入，完成后返回原界面 |
| iPad 多窗口 | 打开 `UIApplicationSupportsMultipleScenes`，设置页和浏览器各用一个 `WindowGroup`。iPad 可新建多个浏览器窗口，每个窗口拥有独立的 `BrowserController`、网页、扫描结果和播放器 |
| 独立设置窗口 | 设置页新增「窗口」分区，可在 iPad 上把设置放到独立窗口，和浏览器并排显示；设置窗口标题栏提供“关闭窗口” |
| 共享数据 | 多窗口共享同一份 `AppSettings`、插件、离线媒体库和相册权限；每个浏览窗口的网页状态互不影响 |
| iPhone 限制 | iPhone 由 iOS 限制为单窗口；设置页仍是全屏独立页面，不会退回 sheet |

---

## 2.5 新增（上一版）

设置中心按八个分区一次填齐，全部设置项都接了真实代码路径，不是只摆开关。

| 分区 | 主要设置 |
| --- | --- |
| 插件 | 插件总开关、插件数量/启用数、脚本注入位置说明；总开关关闭后 `PluginStore.userScripts()` 返回空，切换后自动重载页面并重新注入 |
| 后台设置 | 后台播放、切后台自动画中画、电话/Siri 中断恢复、拔出耳机继续外放、播放时保持常亮、离线下载允许蜂窝网络 |
| 视频设置 | 自动扫描、扫描间隔 2/3/5/8 秒、视频列表上限、优先 HLS、加载视频预览图、过滤广告 iframe、包含跨站 iframe |
| 外观设置 | 跟随系统/浅色/深色、强调色、列表密度、缩略图尺寸、分类徽标、来源域名、iframe 标记 |
| 图片设置 | 当前网页图片扫描、整站扫描图片、图片列表上限、解码上限（标准 2048 / 高清 3072 / 超清 4096）、并发 2/3/4/6、缩略图/原图/视频首帧缓存上限 |
| AI 设置 | 本地离线增强：本地智能分类、智能标题清洗；不联网、不需要 API Key，也没有假装存在的云模型配置 |
| 播放器设置 | 默认倍速、默认画面模式、自动隐藏控制条、隐藏延迟、横滑快进步长、自动下一个、单个循环 |
| 播放信息 | 读取当前视频/本地文件的真实轨道参数：分辨率、帧率、视频码率、视频编码、音频格式、采样率、声道、音频码率、时长、文件大小、容器/协议；未知字段显示“未知”，HLS 未报告码率时显示“自适应码率（未报告）” |

> 播放信息来自 `AVURLAsset` 的 track 参数，不写死、不估算。HLS 的分片码率由服务器自适应，单条 track 不报告时只能显示“未报告”。

---

## 2.4 新增

| 能力 | 说明 |
| --- | --- |
| 后台运行（下载） | 离线下载改用 `URLSessionConfiguration.background`，切后台、锁屏或 App 被系统回收后由系统继续下载；App 被唤醒时通过 `handleEventsForBackgroundURLSession` 交还 completionHandler，任务元数据持久化到 `downloads-jobs.json`，重新启动后仍能落盘 |
| 后台播放 | 保持 `UIBackgroundModes = audio`、`AVAudioSession .playback/.moviePlayback`、`audiovisualBackgroundPlaybackPolicy = .continuesIfPossible`；锁屏/切后台继续播放，保留 Now Playing 和远程控制 |
| 画中画 | `AVPictureInPictureController` 手动 PiP，并打开 `canStartPictureInPictureAutomaticallyFromInline`；切后台时先尝试自动进入 PiP，不支持时仍可点播放器里的 PiP 按钮 |
| 下载鉴权 | 后台下载请求显式携带页面 Cookie、Referer、Origin、移动端 UA，减少登录态/防盗链站点的 403 |

> iOS 不允许普通 App 在后台无限运行。2.4 放开的是系统允许的三类：**后台音频/PiP** 和 **background URLSession 下载**；WKWebView 整站扫描仍必须在前台，进后台后系统会暂停网页加载。

---

## 2.3 新增

| 能力 | 说明 |
| --- | --- |
| SPA 路由监听 | Hook `pushState` / `replaceState` / `popstate` / `hashchange`；每次路由切换递增 generation，旧页面结果自动作废，不再把上一页视频留在列表里 |
| Cookie 观察 | 监听 `WKHTTPCookieStore` 变化并同步到 `HTTPCookieStorage`；“清除 Cookie 与缓存”会同时清 WK 数据、系统 Cookie、`URLCache`、图片内存/磁盘缓存和视频首帧缓存 |
| iframe 治理 | 消息带 `isIframe` 标记；默认过滤广告 iframe 与跨站 iframe，可在菜单里切换“包含跨站 iframe”，整站扫描同样适用 |
| 音频中断恢复 | 电话/Siri 中断按系统 `shouldResume` 恢复；耳机拔出后按用户要求继续外放播放，新设备接入也会恢复 |
| 搜索/筛选/分页 | 本页视频和整站结果都支持按标题、域名、链接搜索，按格式/分类筛选，每 80 条分批加载 |
| 图片批量保存 | 图片页新增多选模式、全选、批量写入相册，并逐张报告成功/失败数量与权限问题 |
| 整站图片扫描 | 扫描 worker 同时注册 `vhImage`，每页收集图片并按分类汇总；结果页新增“视频 / 图片”切换和图片全屏原图查看 |
| 离线媒体库 | MP4 直链可下载到 Application Support 的本地媒体库，支持进度、失败提示、删除、离线播放；HLS/DASH/WebM 暂不支持直接离线 |
| 工程治理 | 新增 `FramePolicy` / `DownloadManager` / `LibraryView` 拆文件；加入 `PrivacyInfo.xcprivacy`、收窄 ATS、Release 关闭 Web Inspector、注入脚本 Node 冒烟测试 |

---

## 一、已实现的功能

| 能力 | 说明 |
| --- | --- |
| 网页浏览 | 内置 WKWebView，地址栏输入即打开，支持返回 / 前进 / 刷新 |
| 四路识别 | ① DOM（`<video>`、`<source>`、`data-src` 等懒加载属性）② 网络请求（Hook `XMLHttpRequest` / `fetch`，按 Content-Type 判断）③ 页面内联脚本里的 m3u8 / mp4 直链 ④ `performance` 资源记录 |
| 子框架覆盖 | 脚本注入 `forMainFrameOnly = false`，内嵌 iframe 里的播放器同样能抓到 |
| 实时更新 | `MutationObserver` + 3 秒轮询，播放按钮点下后新产生的地址会自动进列表 |
| 整站扫描 | 从当前页出发，先读 `sitemap.xml` 铺底，再按广度优先逐页打开站内链接（默认 60 页 / 3 层，可调），把每一页的视频汇总后按页分组展示 |
| 并发提速 | 整站扫描用多个隐藏 WKWebView 同时开工（1～4 路可调，默认 3 路），并缩短单页等待；进度页实时显示并发路数、页/分钟 |
| 插件系统 | 用户脚本插件：填网址正则，命中后注入自定义 JS，可增删改、启停、排序；内置视频增强 / 懒加载 / 直链记录三个模板；改完自动刷新当前页 |
| 视频预览图 | 注入脚本读取 `<video poster>`、列表项 `<img>`、页面的 `og:image` / `twitter:image` / JSON-LD 缩略图；下载带 Cookie + Referer 多级重试，MP4 还会抽取首帧兜底，列表直接显示缩略图 |
| 网页图片库 | 新增独立「网页图片」页：抓 `<img>` / `srcset` / `<picture>` / `<a>` 图片直链 / CSS 背景 / og:image，按截图、封面海报、商品图、插画、壁纸、头像、图标等自动分类，双列网格展示 |
| 原图查看 | 点开图片进入全屏原图页，支持双指/双击缩放、拖动、保存到相册、复制链接、分享、Safari 打开 |
| 回到主页 | 顶部地址栏左侧新增高亮「房子」按钮，一键停止加载并清空当前页的视频/图片识别结果 |
| 后台播放 | 已配置后台音频 + `audiovisualBackgroundPlaybackPolicy`，锁屏/切后台继续播放；接入 Now Playing 与远程控制中心（播放、暂停、上一首/下一首、进度拖动） |
| 后台下载 | 离线 MP4 使用 background URLSession，切后台/锁屏继续下载，重新唤醒后恢复落盘 |
| 自动分类 | 按链接路径、文件名、页面标题判断电影 / 剧集 / 动漫 / 综艺 / 短视频 / 音乐 / 其他，本页列表按分类分节，整站结果可切「按分类 / 按页面」 |
| 去重排序 | 按 URL 去重，HLS → MP4 → 其他，最多保留 200 条；自动过滤 `.ts` / `.m4s` 等 HLS 分片 |
| 内置播放 | AVPlayer 播放 HLS / MP4，自动带 `Referer`、`Origin`、`User-Agent`，减少 403；支持全屏、画中画（含切后台自动 PiP）、AirPlay |
| 播放界面 | 自绘控制条：拖动进度、时间显示、0.5～2 倍速、画面适应/填充、双击播放暂停、横滑快进、控制条自动隐藏、上一个/下一个队列播放、失败重试 |
| 直接链接 | 地址栏粘贴 `.m3u8` / `.mp4` 时，拦下导航直接进播放器，不在网页里显示一堆文本 |
| Cookie 打通 | 网页登录后的 Cookie 同步到 `HTTPCookieStorage`，播放需要登录的源时可用 |
| 其他 | 桌面版 / 移动版 UA 一键切换、清缓存、复制单个或全部链接、Safari 打开兜底 |

---

## 二、目录结构

```
VideoHunter/
├── VideoHunter.xcodeproj/
│   └── project.pbxproj
├── VideoHunter/
│   ├── VideoHunterApp.swift      # App 入口，音频会话配置
│   ├── ContentView.swift         # 主界面 + 识别结果列表
│   ├── BrowserController.swift   # WKWebView 管理、导航策略、Cookie 同步
│   ├── BrowserView.swift         # WKWebView 的 SwiftUI 封装
│   ├── MediaSniffer.swift        # 消息接收、去重、排序、类型判断
│   ├── MediaItem.swift           # 媒体数据模型
│   ├── MediaCategory.swift       # 视频分类规则（电影/剧集/动漫…）
│   ├── ThumbnailView.swift       # 预览图下载、缓存与缩略图视图
│   ├── SiteCrawler.swift         # 整站扫描调度（多路隐藏 WKWebView 并发）
│   ├── SiteScanView.swift        # 整站扫描的设置 / 进度 / 结果页
│   ├── MediaRowView.swift        # 视频列表通用行
│   ├── Plugin.swift              # 用户脚本插件模型与存储
│   ├── PluginListView.swift      # 插件管理 / 编辑器
│   ├── ImageLibrary.swift        # 图片模型、分类、图片嗅探器
│   ├── ImageViews.swift          # 图片列表 / 原图详情 / 缩放
│   ├── RemoteImageLoader.swift   # 带 Cookie/Referer 重试的图片下载器
│   ├── PlayerView.swift          # 自绘播放界面（AVPlayerLayer + 控制条 + 后台播放）
│   ├── InjectedScript.swift      # 注入网页的识别脚本（核心）
│   ├── FramePolicy.swift         # 广告/跨站 iframe 过滤
│   ├── DownloadManager.swift     # MP4 离线下载与本地媒体库元数据
│   ├── LibraryView.swift         # 离线媒体库界面
│   ├── PrivacyInfo.xcprivacy     # 隐私清单
│   └── Info.plist                # ATS 只放开网页内容与媒体，后台音频
├── .github/workflows/build.yml      # 云端打包未签名 IPA
├── scripts/build-ipa.sh             # macOS 本地一键打包
└── README.md
```

---

## 三、构建方式

### 方式 A：GitHub Actions（没有 Mac 也能出 IPA）

1. 把整个 `VideoHunter` 目录推到 GitHub 仓库（public / private 都行）。
2. 打开仓库 **Actions** 页，选 **Build IPA**，点 **Run workflow**。
3. 跑完后在该次运行的 **Artifacts** 里下载 `VideoHunter-unsigned-ipa`，解压得到 `VideoHunter-unsigned.ipa`。
4. 用全能签 / Sideloadly / AltStore 等工具签名安装（需要你自己的证书或 Apple ID）。

> 说明：工作流使用 `macos-15` + `xcodebuild`，关闭代码签名（`CODE_SIGNING_ALLOWED=NO`），产出的是**未签名** IPA，正好给签名工具用。

### 方式 B：Xcode（有 Mac）

```bash
open VideoHunter.xcodeproj
```

1. 选中 `VideoHunter` Target → **Signing & Capabilities** → 选择你的 Team，Bundle Identifier 改成你自己的（如 `com.你的名字.videohunter`）。
2. 连上 iPhone，`Cmd + R` 运行。
3. 想直接出 IPA：`bash scripts/build-ipa.sh`（脚本会做 Release 编译并打包成 `VideoHunter-unsigned.ipa`）。

命令行编译（不签名）：

```bash
xcodebuild -project VideoHunter.xcodeproj -target VideoHunter \
  -configuration Release -sdk iphoneos \
  CODE_SIGNING_ALLOWED=NO build
```

---

## 四、它是怎么识别视频的

注入脚本在 `documentStart` 时机、注入到每一个 frame，做四件事：

1. **Hook 网络层**：包装 `XMLHttpRequest.prototype.open/send` 和 `window.fetch`，读 `responseURL` 与 `Content-Type`（`application/vnd.apple.mpegurl`、`video/mp4`、`dash+xml` 等），命中就上报。
2. **Hook 赋值**：改写 `HTMLMediaElement.prototype.src` 和 `HTMLSourceElement.prototype.src` 的 setter，站点用 JS 动态换源也能捕获。
3. **扫 DOM 与脚本**：遍历 `video/audio/source` 的 `currentSrc`、`src`、`data-src` 等属性；正则扫内联 `<script>` 里的 m3u8/mp4 直链（处理 `\/`、`\u002F` 转义）。
4. **扫 performance**：`performance.getEntriesByType('resource')` 里所有命中媒体后缀的请求。

上报到原生后，`MediaSniffer` 去重、按类型排序，`MediaListSheet` 展示，点一条即用 AVPlayer 播放。

### 整站扫描怎么工作

1. 按并发数起 1～4 个隐藏 `WKWebView`（默认 3），都注入同一套脚本，禁止自动播放，不占界面。
2. 先请求站点的 `/sitemap.xml`（如果是索引文件就再取最多 3 个子 sitemap），把里面的页面地址塞进队列，最多 150 条；读 sitemap 与起始页抓取同时进行。
3. 工作池不断取队列里的页面：每页等 0.55 秒让 JS 跑完，自动滚动触发懒加载，调用 `__vhRescan()` 再扫一遍，然后用 `__vhCollectLinks()` 取回该页的 `<a href>` 列表和直链视频。
4. 链接按「层级浅优先 → 含 video/detail/episode 等关键词优先」排序，默认只走同一域名（可含子域名），去重后最多扫 60 页、3 层。
5. 每页结果按 URL 全局去重，汇总成「页面 → 视频」两层结构；扫描过程可随时取消，已拿到的结果保留。

### 插件怎么工作

- 插件 = 名称 + 网址正则 + 注入时机（documentStart / documentEnd）+ 一段 JS。
- 命中 `location.href` 的正则时，脚本被包进 `try/catch` 注入每个 frame，报错只写 console，不影响网页。
- 插件保存在 `UserDefaults`（key `vh.user.plugins.v1`），改动后发通知，`BrowserController` 重建 user scripts 并刷新页面；整站扫描的 worker 启动时也会带上插件。
- 插件脚本里可调用 `window.__vhRescan()` 让 App 立刻重扫当前页。

---

## 五、已知限制（重要）

- **DRM / FairPlay 加密流**：无法解密，内置播放器会失败，这是版权保护机制，不做绕过。
- **blob: 链接**：页面用 MSE 拼出来的流只在网页上下文有效，App 会标为"只能在原网页播放"。
- **DASH（.mpd）**：AVPlayer 不支持，列表会提示复制到 Safari / VLC。
- **需要登录 / 防盗链严格的站点**：已同步 Cookie 并附带 Referer/UA，但部分站点仍会 403，这属于对方服务端策略。
- **首次打开可能识别为空**：很多站点要点击播放后才发起请求，先点一下页面里的播放按钮，再回列表点"重新扫描"。
- **App Store 不会通过**：这类网页嗅探 + 播放器属于灰色地带，只适合自签自用，不要上传商店。
- **整站扫描不是无限爬**：只跟随页面里的 `<a href>`，不解析 JS 里的路由跳转；默认 60 页 / 3 层，冷门页面可能扫不到。想覆盖更多就调高页数和层级；把并发调到 4 路会更快，但更吃内存和流量。
- **扫描依赖前台运行**：iOS 会在 App 进入后台后暂停网页加载，扫描期间请保持前台、别锁屏。2.4 的“后台运行”只覆盖后台音频/PiP 和 background URLSession 下载，不是让 WKWebView 常驻。
- **预览图可能显示不出来**：部分站点对图片做了防盗链或需要登录 Cookie，下载失败时会回落到类型图标；`blob:`、画布渲染的视频也没有可用的封面图。
- **分类是启发式的**：靠 URL 和标题关键词判断，命名不规范的站点可能分错，可在 `MediaCategory.swift` 的 `rules` 里补关键词。
- **编译验证**：当前版本（2.4 / Build 8）在 GitHub Actions 的 macOS-15 + Xcode 16.4 上真实编译通过（`BUILD SUCCEEDED`），21 个 Swift 源文件全部参与编译，注入脚本冒烟测试通过，产物是未签名 IPA。
- **2.2 修复**：iPad 分享 popover 崩溃；相册写入权限检查与失败提示；ImageIO 下采样解码、图片请求 4 路并发上限、原图 72 MB / 缩略图 36 MB / 视频首帧 24 MB 缓存上限；列表复用前清空旧图，避免闪图。
- **2.3 边界**：离线下载只接受单文件 MP4；HLS 是多分片流，直接下载会得到一堆 `.ts`，因此不会伪装成“下载成功”。跨站 iframe 默认关闭，需要 YouTube/Bilibili 等嵌入内容时在菜单里打开。
- **2.3 测试**：`node scripts/test-injected.mjs` 覆盖首屏上报、SPA 路由 generation 递增、旧页去重和路由后重扫；云端构建已执行该测试。
- **2.4 验证**：2.4 / Build 8 在 Xcode 16.4 上 `BUILD SUCCEEDED`，21 个 Swift 文件全部参与编译；IPA 校验为 arm64、iOS 16.0、`UIBackgroundModes=audio`、`PrivacyInfo.xcprivacy` 已打包。
- **2.4 边界**：background URLSession 由系统调度，不能保证固定时间完成；用户从多任务界面强制杀掉 App 后，系统不会继续下载。后台音频/PiP 需要保持播放器页面存在；整站扫描仍不能后台常驻。

---

## 六、想改的地方

| 想改 | 在哪 |
| --- | --- |
| App 名称 | `Info.plist` 的 `CFBundleDisplayName` |
| 包名 | Target → General → Bundle Identifier，或 `project.pbxproj` 里 `PRODUCT_BUNDLE_IDENTIFIER` |
| 默认首页 | `ContentView` 的 placeholder 里加按钮，或改 `BrowserController.load` 调用 |
| 识别规则 | `InjectedScript.swift` 顶部 `MEDIA_RE` / `looksLikeSegment` |
| 列表上限 | `MediaSniffer.maxItems` |
| App 图标 | 新建 `Assets.xcassets` → `AppIcon`，放入 1024×1024 PNG 即可 |

---

## 七、合规提醒

本工具只用于播放你自己有权访问的公开网页内容。请遵守目标站点的服务条款与著作权法，不要用于批量下载、二次分发受版权保护的内容。
