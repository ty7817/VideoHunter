# 视频猎手 VideoHunter

输入一个网页链接，自动识别页面里所有能播放的视频地址，并直接用内置播放器播放。

- 平台：iOS 16.0+（iPhone / iPad）
- 形态：SwiftUI + WKWebView + AVPlayer，纯原生，无第三方依赖
- 产物：完整 Xcode 工程，可直接编译；也提供 GitHub Actions 一键产出未签名 IPA

---

## 一、已实现的功能

| 能力 | 说明 |
| --- | --- |
| 网页浏览 | 内置 WKWebView，地址栏输入即打开，支持返回 / 前进 / 刷新 |
| 四路识别 | ① DOM（`<video>`、`<source>`、`data-src` 等懒加载属性）② 网络请求（Hook `XMLHttpRequest` / `fetch`，按 Content-Type 判断）③ 页面内联脚本里的 m3u8 / mp4 直链 ④ `performance` 资源记录 |
| 子框架覆盖 | 脚本注入 `forMainFrameOnly = false`，内嵌 iframe 里的播放器同样能抓到 |
| 实时更新 | `MutationObserver` + 3 秒轮询，播放按钮点下后新产生的地址会自动进列表 |
| 去重排序 | 按 URL 去重，HLS → MP4 → 其他，最多保留 200 条；自动过滤 `.ts` / `.m4s` 等 HLS 分片 |
| 内置播放 | AVPlayer 播放 HLS / MP4，自动带 `Referer`、`Origin`、`User-Agent`，减少 403；支持全屏、画中画、AirPlay |
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
│   ├── PlayerView.swift          # AVPlayer 播放页
│   ├── InjectedScript.swift      # 注入网页的识别脚本（核心）
│   └── Info.plist                # ATS 允许 http、后台音频（画中画）
├── .github/workflows/build-ipa.yml  # 云端打包未签名 IPA
├── scripts/build-ipa.sh             # macOS 本地一键打包
└── README.md
```

---

## 三、构建方式

### 方式 A：GitHub Actions（没有 Mac 也能出 IPA）

1. 把整个 `VideoHunter` 目录推到 GitHub 仓库（public / private 都行）。
2. 打开仓库 **Actions** 页，选 **Build IPA (unsigned)**，点 **Run workflow**。
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

---

## 五、已知限制（重要）

- **DRM / FairPlay 加密流**：无法解密，内置播放器会失败，这是版权保护机制，不做绕过。
- **blob: 链接**：页面用 MSE 拼出来的流只在网页上下文有效，App 会标为"只能在原网页播放"。
- **DASH（.mpd）**：AVPlayer 不支持，列表会提示复制到 Safari / VLC。
- **需要登录 / 防盗链严格的站点**：已同步 Cookie 并附带 Referer/UA，但部分站点仍会 403，这属于对方服务端策略。
- **首次打开可能识别为空**：很多站点要点击播放后才发起请求，先点一下页面里的播放按钮，再回列表点"重新扫描"。
- **App Store 不会通过**：这类网页嗅探 + 播放器属于灰色地带，只适合自签自用，不要上传商店。
- **本机未做真机编译验证**：开发环境是 Linux 云主机，没有 Xcode，无法在这里出 IPA。工程文件、plist、注入脚本都做了静态校验（pbxproj 可被解析库正常读取、Info.plist 可被 plistlib 解析、JS 通过 `node --check`、Swift 源文件通过 tree-sitter 语法解析），但真正的编译请在 Xcode 或上面的 Actions 里跑一次。

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
