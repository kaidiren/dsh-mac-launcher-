# dsh-mac-launcher

[DeepSeek Harness](https://github.com/deepseek-ai/deepseek-harness) Web GUI 的**纯原生 macOS 启动器**。

用一个 Swift + WKWebView 的单进程应用承载它的 Web GUI：点 Dock 图标即用，
**不依赖 Google Chrome，也不需要任何系统自动化权限。**

```
点 Dock 图标
   └─ DSH.app 自己：探端口 → 必要时拉起 dsh web → 认证 → WKWebView 开窗
                    ↑ 全在一个进程里完成，没有脚本、没有标志文件、没有 osascript
```

## 前置要求

- macOS 14+（`LSMinimumSystemVersion`）
- Xcode 命令行工具：`xcode-select --install`（编译需要）
- **[DeepSeek Harness](https://github.com/deepseek-ai/deepseek-harness) 已安装** ——
  本应用只是它的 GUI 宿主，不含 DSH 本身。装好后 `dsh --version` 应能正常输出；
  若不在默认位置，用 `DSH_BIN` 指定

## 安装

```sh
cd dsh-mac-launcher
./build.sh                    # Release 构建：编译 + 生成图标 + 组装 build/DSH.app
cp -R "build/DSH.app" /Applications/
```

`build.sh` 默认产出 **Release** 版本（`-O -wmo` 全模块优化 + 剥离符号，可执行文件约 268 KB）。
需要带符号调试时用 `BUILD_TYPE=debug ./build.sh`（`-Onone -g`，不剥离）。

然后把 `/Applications/DSH.app` 拖到 Dock。首次点击会自己起服务并开窗。

> 若端口上已经有 `dsh web` 在跑（比如你之前用别的方式启动过），本启动器会直接复用，
> 并尽量从历史日志里取回认证地址，不会去重启它。

自检（不做任何动作，只打印本次决策）：

```sh
"/Applications/DSH.app/Contents/MacOS/DSHLauncher" --print-decision
```

另有两条自省路径，用于验证无法用脚本点击的菜单动作
（菜单点击在 macOS 上需要辅助功能权限，脚本发不了按键）：

```sh
DSHLauncher --self-test-restart   # 启动后自动触发一次「重启服务」，验证整条链路
DSHLauncher --self-test-close     # 关掉窗口，验证「关窗不退出应用、也不停服务」
```

## 行为

**服务**
- 端口已有监听 → 复用，**绝不重启**
- 端口空闲 → 拉起 `dsh web --port <端口> --no-open`，直接读子进程 stdout 解析认证 URL
- 取到的认证 URL 缓存在 `~/Library/Logs/DSH/auth-url`（权限 `0600`）

**认证**（这一版的核心简化）
- 日常启动**裸加载根地址**，让持久 cookie 生效 —— 服务端重启也不影响
  （DSH 的签名密钥是持久化凭据，cookie 不绑定进程级 launch token）
- cookie 失效时才用带 token 的地址补一次认证。token 优先取"服务日志里最新那条"
  （一定是当前进程的）；本启动器启动的服务会重启一次拿新 token
- **别人启动的服务**（终端里手动跑的、旧启动器留下的）：只尝试从日志恢复认证地址，
  **找不到也绝不重启它** —— 那会打断正在使用它的会话

**窗口**
- 默认占满屏幕可用区域；`DSH_WINDOW_MODE=custom` 时用配置尺寸，并记住你调整过的大小
- 页面缩放：`⌘+` / `⌘-` 每档 10%、`⌘0` 回到 100%（菜单「显示」）；调过的值会被记住
- **关窗口不退出应用**：服务与菜单栏图标继续在，点 Dock 图标窗口回来
- 外链交给系统默认浏览器；下载走"下载"文件夹
- 右键菜单是精简版（剪切/拷贝/粘贴/重新载入/回到主页），没有浏览器味的"检查元素"

**菜单栏**（与应用同进程，图标是黑色鲸鱼模板图标，深浅色菜单栏自动适配）
- 左键 → 菜单：状态行 · 打开窗口（⌘O）· 重新载入界面（⌘R）· 重启服务（⇧⌘R）· 退出 DSH（⌘Q）
- `重启服务` **无条件可用**：它会把端口上的服务停掉再重新拉起，**不管那个服务是不是本启动器
  启动的**（不是的话按端口反查监听者，SIGTERM → 3 秒宽限 → SIGKILL 强停，日志里会写明）。
  这会打断正在使用该服务的会话 —— 这正是它与下面「退出 DSH」的区别
- `退出 DSH` = 关窗口 + 停服务 + 撤图标。只停"本启动器启动的服务"；
  别人的服务会保留（日志里会写明）
- 菜单首行会标明服务归属（`DSH 运行中 · 端口 3080（外部启动）`）

## 配置

环境变量（也可写在 `~/.dsh/mac-launcher.yaml`，格式 `KEY: value`）：

| 变量 | 默认 | 说明 |
|---|---|---|
| `DSH_WEB_PORT` | `3080` | 服务端口 |
| `DSH_BIN` | 自动探测 | `dsh` 可执行文件路径 |
| `DSH_WORKDIR` | `~` | `dsh web` 的工作目录（决定 GUI 会话的起始目录） |
| `DSH_WINDOW_MODE` | `maximized` | `maximized` 占满屏幕 \| `custom` |
| `DSH_WINDOW_WIDTH` / `HEIGHT` | `1180` / `800` | 仅 `custom` 模式 |
| `DSH_REMEMBER_WINDOW_SIZE` | `1` | `custom` 模式下记住窗口大小 |
| `DSH_IMMERSIVE_WINDOW` | `0` | `1` = 隐藏标题栏的沉浸式窗口 |
| `DSH_PAGE_ZOOM` | `1.0` | 页面缩放（Chrome 那种整体缩放）；用户按 ⌘+ / ⌘- 调过的值会被记住并优先 |
| `DSH_TRAY` | `1` | `0` = 不显示菜单栏图标 |
| `DSH_OPEN_WINDOW` | `1` | `0` = 启动时不自动开窗 |
| `DSH_LOG_DIR` | `~/Library/Logs/DSH` | 日志目录 |
| `DSH_SERVICE_TIMEOUT` | `60` | 等端口就绪的上限（秒） |
| `DSH_TOKEN_TIMEOUT` | `20` | 等认证 URL 的上限（秒） |

命令行里未被本启动器识别的参数，会原样转给 `dsh web`。

## 日志

都在 `~/Library/Logs/DSH/`（不再把运行期文件写进源码目录）：

| 文件 | 内容 |
|---|---|
| `launcher.log` | 启动器决策与动作，排错先看这里 |
| `service.log` | `dsh web` 的输出（认证 URL 已脱敏） |
| `auth-url` | 带 token 的认证地址，权限 `0600`，**本机凭据不要外传** |

目录在应用启动时即建立，所以还没有任何日志时点错误面板的「打开日志」也能打开它。

## 排错

**每点一次 Dock 图标就多一个窗口？**
不会。服务与窗口都在同一进程内，且应用有单实例守卫（第二次启动会激活已有实例并退出）。

**窗口只显示空白或「Loading plugins…」很久**
启动遮罩会一直显示到前端真正渲染出来。若超过十几秒，看 `launcher.log` 里
"界面就绪"那行；只有认证墙（`dsh web authentication required`）才会触发重新认证。

**提示「端口 xxxx 上的服务不是本启动器启动的」**
端口上那个服务是别处（终端 / 旧启动器）启动的。两种做法：
1. **想直接接管它** → 菜单栏「重启服务」会强制停掉它再重新拉起（**会打断正在使用它的会话**）；
2. **想不打断它** → 在浏览器里打开 dsh 打印的认证地址完成一次认证，之后本启动器复用同一 cookie 即可进入。

**界面状态坏了（空白引导页）**
数据在 `~/.dsh/` 下通常是好的，是浏览器里那个 origin 的本地状态需要重置。
在窗口里按 `⌘⌥I` 打开开发者工具（或改用 Safari/无痕窗口验证），执行：

```js
Object.keys(localStorage).filter(k => k.startsWith('dsh')).forEach(k => localStorage.removeItem(k)); location.reload()
```

**想完全重置本启动器的状态**（cookie、窗口大小、缓存）：

```sh
rm -rf ~/Library/WebKit/com.kaidiren.dsh-mac-launcher \
       ~/Library/HTTPStorages/com.kaidiren.dsh-mac-launcher.binarycookies \
       ~/Library/Logs/DSH
defaults delete com.kaidiren.dsh-mac-launcher 2>/dev/null
```

## 目录结构

| 文件 | 作用 |
|---|---|
| `Sources/main.swift` | 入口：单实例守卫、应用菜单、退出流程、信号处理 |
| `Sources/Config.swift` | 配置解析（环境变量 / 配置文件） |
| `Sources/Service.swift` | `dsh web` 生命周期：启动、就绪、token 解析、重启、停止 |
| `Sources/WebWindow.swift` | 窗口 + WKWebView 宿主、认证流程、下载、右键菜单、兼容注入 |
| `Sources/MenuBar.swift` | 菜单栏图标与三动作 |
| `Sources/OverlayView.swift` | 启动进度与错误面板 |
| `Sources/Support.swift` | 日志、端口探测、认证 URL 解析与缓存 |
| `Sources/AtomicFlag.swift` | 跨线程标志（后台等待端口时判断子进程存活） |
| `build.sh` | 一键构建（默认 Release；`BUILD_TYPE=debug` 可切调试版） |
| `Resources/Info.plist` | bundle 描述 |
| `scripts/winlist.swift` | 调试小工具：列出窗口（验证开窗与尺寸） |
| `docs/背景与验证记录.md` | 为什么这样设计，以及可行性验证的实测数据 |

## 已知限制

- 菜单栏图标只在**本应用运行时**存在。退掉应用图标就没了 —— 但服务仍在跑，重新打开应用即可。
- WKWebView 与 Chrome 的渲染内核不同。已实测 DSH GUI 完整可用（会话列表、工作区、余额、
  上传下载、WebSocket 长连接），个别 CSS 细节可能有细微差异。
- 在 macOS 14.4 以下运行时会注入 `AbortSignal.any` / `Promise.withResolvers` / `Promise.try`
  的兼容实现（DSH 前端在关键路径上用了它们且没有 polyfill）。
- 文件上传用 `<input type=file>`（原生文件面板）；拖放上传与剪贴板粘贴图片沿用浏览器行为，
  遇到问题请记录到 `launcher.log` 附近的现象里反馈。

## 许可

本项目以 [MIT](LICENSE) 发布。

`Resources/icons/app-icon-mac.png`（应用图标）取自
[anywhere-labs/dsh-desktop](https://github.com/anywhere-labs/dsh-desktop)，
**其版权归该项目所有、不在本项目的 MIT 范围内**；再分发前请自行确认其许可。
`Resources/icons/tray-iconTemplate*.png` 与 `tray-icon.svg` 沿用旧启动器的素材。

菜单栏图标加载 `@2x`（32×32）那份、逻辑尺寸设为 18pt，并标记为模板图标。
**不要改用 1x（16×16）那份** —— 它在 Retina 上要被拉大两倍多，菜单栏里会发糊。
