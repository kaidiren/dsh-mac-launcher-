// WebWindow.swift —— 原生窗口 + WKWebView 宿主。
//
// 这一段替代原启动器的全部窗口操作：
//   · Chrome `--app=<url>` 开应用窗口   → WKWebView 直接加载
//   · AppleScript 枚举窗口「检测/聚焦」  → 进程内持有一个 NSWindow，天然单窗口
//   · Chrome 丢弃 --start-maximized      → NSScreen.visibleFrame 直接设定
//   · AppleScript set bounds 撑满屏幕    → 同上（无需 screen-bounds 工具）
//   · AppleScript close 关窗口           → window.close()
//   · 4 段 osascript 都要「自动化」权限  → 完全不需要任何 TCC 授权
import Cocoa
import WebKit

/// 主窗口：承载 DSH Web GUI。
@MainActor
final class WebWindow: NSObject, NSWindowDelegate, WKNavigationDelegate, WKUIDelegate,
                       WKDownloadDelegate {

    private let config: LauncherConfig
    private let service: ServiceController
    private(set) var window: NSWindow!
    private var webView: WebView!
    private var overlay: OverlayView!
    /// 是否已经用带 token 的地址加载过一次（用于 loadHome 选择目标）。
    private var usedTokenAuth = false
    /// 真正"用 token URL 加载"过几次：达到上限就停止重试，避免无限循环。
    /// 注意别用 usedTokenAuth 当重试上限 —— 它在"从日志恢复地址"时也会置位，
    /// 会把后面「识别并接管孤儿服务」那条补救路径一起挡掉。
    private var tokenAttempts = 0
    /// 最近一次真正尝试过的认证地址。
    /// 关键防线：从日志恢复出来的往往是**同一个已失效的 token URL**，
    /// 若不加去重就会「恢复→加载→401→再恢复」无限打转（实测 1 秒内几百轮）。
    private var lastAttemptedAuthURL: String?
    /// 认证补救的节流时间戳：短时间内只补救一次。
    private var lastRecoveryAt = Date.distantPast
    /// 是否正在执行 token 认证流程（防止并发重复触发）。
    private var authenticating = false
    private var lastStatusCode = 0
    private var finishedOnce = false
    /// 连接失败重试次数（网络类错误），有上限，避免无限循环。
    private var connectionRetries = 0
    private static let maxConnectionRetries = 15
    /// 是否正在重启服务。
    ///
    /// 重启期间一律不加载：`start()`（冷启动流程）与菜单栏「重启」可能几乎同时
    /// 发生，而 `start()` 走到加载那一步时并不知道服务正要被换掉，
    /// 就会撞上"端口关了又开"的窗口期、白跑一串连接失败重试。
    /// 重启流程自己在就绪后会发起加载，所以这里直接让路即可。
    private var restarting = false
    /// 每次发起加载自增；用于丢弃"上一次启动流程遗留的"加载请求。
    private var loadGeneration = 0
    /// 进度心跳任务与起始时间
    private var progressTask: Task<Void, Never>?
    private var progressStartedAt = Date()
    /// 预热用的 WebView（不显示、不挂 delegate）：只为尽早把 WebKit 的子进程拉起来。
    private var prewarmView: WKWebView?
    /// 启动计时打点：配合 main.swift 的 LAUNCH_AT 与 ProcessStart.date，
    /// 在界面就绪时汇总成一行"启动耗时"日志（见 logStartupTiming）。
    private var windowShownAt: Date?
    private var serviceReadyAt: Date?
    /// 页面缩放（1.0 = 100%）。用户用 ⌘+ / ⌘- 调过的值记在 UserDefaults，重启后仍生效。
    private(set) var pageZoom: Double = 1.0
    private static let pageZoomKey = "pageZoom"
    private static let minZoom = 0.5
    private static let maxZoom = 3.0
    /// 前端就绪轮询的中间状态。
    private var readinessAttempts = 0
    private var lastContentLength = -1

    /// 窗口不可用（已关闭）时由 AppDelegate 重新创建。
    var isOpen: Bool { window != nil && window.isVisible }

    /// 当前是否有页面已加载成功（菜单栏据此显示状态）。
    private(set) var hasLoadedPage = false

    /// 供 WebView 内部右键菜单使用。
    var rootURLString: String { config.rootURL.absoluteString }

    init(config: LauncherConfig, service: ServiceController) {
        self.config = config
        self.service = service
        super.init()
        buildWindow()
        prewarmWebKit()
        restorePageZoom()
    }

    /// 预热 WebKit 子进程（只建进程，不碰网络）。
    ///
    /// 只创建一个 WKWebView 并不会拉起 WebKit 的 WebContent/GPU 子进程 —— 要等真正发起
    /// 加载才会。而主流程此刻还要解析配置、等端口、等 token，中间白等好几秒；这里先加载
    /// 一个空页面，把这几个子进程提前热起来。
    ///
    /// **不要改成请求 config.rootURL**：那会引入竞态 —— 若这一下恰好吃在"服务已 bind
    /// 端口、HTTP 还没就绪"的窗口期，TCP 握手成功而 HTTP 迟迟不响应，这个挂住的请求会
    /// 占住同 origin 的连接池，把主 WebView 的加载一起拖住（实测表现：界面空白 0 字符、
    /// 26 秒才兜底就绪）。
    private func prewarmWebKit() {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .default()
        configuration.userContentController.addUserScript(Polyfill.script())
        let view = WKWebView(frame: .zero, configuration: configuration)
        prewarmView = view
        view.loadHTMLString("<!doctype html><meta charset=\"utf-8\"><title>DSH</title>", baseURL: nil)
    }

    // MARK: - 窗口构建

    private func buildWindow() {
        let style: NSWindow.StyleMask = config.immersiveWindow
            ? [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
            : [.titled, .closable, .miniaturizable, .resizable]

        let frame = targetFrame()
        window = NSWindow(contentRect: frame, styleMask: style, backing: .buffered, defer: false)
        window.title = "DSH"
        window.minSize = NSSize(width: 640, height: 460)
        window.delegate = self
        window.isReleasedWhenClosed = false
        if config.immersiveWindow {
            window.titlebarAppearsTransparent = true
            window.titleVisibility = .hidden
            window.isMovableByWindowBackground = true
        }

        let configuration = WKWebViewConfiguration()
        // 持久化 data store 是"认证一次、长期复用"的关键：
        // cookie 落在 ~/Library/WebKit/<bundle-id>/，关窗、退应用、甚至服务重启都还在。
        configuration.websiteDataStore = .default()
        configuration.preferences.isElementFullscreenEnabled = true
        configuration.preferences.setValue(true, forKey: "developerExtrasEnabled")
        configuration.userContentController.addUserScript(Polyfill.script())

        webView = WebView(frame: NSRect(origin: .zero, size: frame.size), configuration: configuration)
        webView.autoresizingMask = [.width, .height]
        webView.navigationDelegate = self
        webView.uiDelegate = self
        webView.allowsBackForwardNavigationGestures = false
        webView.allowsMagnification = true
        webView.setValue(false, forKey: "drawsBackground")
        webView.appHost = self

        let container = NSView(frame: NSRect(origin: .zero, size: frame.size))
        container.autoresizingMask = [.width, .height]
        webView.frame = container.bounds
        container.addSubview(webView)

        overlay = OverlayView(frame: container.bounds)
        overlay.autoresizingMask = [.width, .height]
        container.addSubview(overlay)

        window.contentView = container
        window.setFrame(frame, display: false)
    }

    /// 启动阶段目标尺寸：默认占满屏幕可用区域；custom 模式用配置或上次记忆的尺寸。
    private func targetFrame() -> NSRect {
        let screen = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1280, height: 800)
        switch config.windowMode {
        case .maximized:
            return screen
        case .custom:
            if config.rememberWindowSize, let saved = WindowMemory.load() {
                return clamp(saved, into: screen)
            }
            let size = NSSize(width: config.windowWidth, height: config.windowHeight)
            return clamp(NSRect(origin: screen.origin, size: size), into: screen)
        }
    }

    private func clamp(_ rect: NSRect, into screen: NSRect) -> NSRect {
        var result = rect
        result.size.width = min(result.size.width, screen.size.width)
        result.size.height = min(result.size.height, screen.size.height)
        result.origin.x = max(screen.origin.x, min(result.origin.x, screen.maxX - result.size.width))
        result.origin.y = max(screen.origin.y, min(result.origin.y, screen.maxY - result.size.height))
        return result
    }

    // MARK: - 前台显示

    func present() {
        if window == nil { buildWindow() }
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        if window.isMiniaturized { window.deminiaturize(nil) }
        // 只在首次记录：之后从菜单栏/Dock 再打开窗口不算"启动"
        if windowShownAt == nil { windowShownAt = Date() }
    }

    // MARK: - 页面缩放（菜单「显示」里的 ⌘+ / ⌘- / ⌘0）

    /// 应用初始缩放：优先"上次调过的值"，其次配置项 DSH_PAGE_ZOOM，最后 100%。
    private func restorePageZoom() {
        let saved = UserDefaults.standard.object(forKey: Self.pageZoomKey) as? Double
        pageZoom = min(max(saved ?? config.pageZoom, Self.minZoom), Self.maxZoom)
        webView.pageZoom = pageZoom
        if abs(pageZoom - 1.0) > 0.001 {
            logInfo("页面缩放：\(Int((pageZoom * 100).rounded()))%（沿用上次的值）")
        }
    }

    func zoomIn() { setPageZoom(pageZoom + 0.1) }
    func zoomOut() { setPageZoom(pageZoom - 0.1) }
    func resetZoom() { setPageZoom(1.0) }

    /// 步进 0.1、范围 50%–300%（与 Chrome 的档位观感一致），并把值记住。
    private func setPageZoom(_ value: Double) {
        pageZoom = min(max(value, Self.minZoom), Self.maxZoom)
        webView.pageZoom = pageZoom
        UserDefaults.standard.set(pageZoom, forKey: Self.pageZoomKey)
        logInfo("页面缩放：\(Int((pageZoom * 100).rounded()))%")
    }

    /// 开启主流程：先让窗口和转圈动起来，再拉起服务、加载界面。
    ///
    /// 顺序很重要：冷启动时 `dsh web` 要约 10 秒才就绪，如果把这 10 秒花在
    /// "先解析配置、建控制器、建菜单栏"之后才显示窗口，用户会先看到一小段空白，
    /// 再看到一个静止的转圈。现在窗口与遮罩一启动就出现，并持续显示当前阶段与耗时。
    func start() async {
        if config.showStartupOverlay {
            overlay.show(message: "正在检查服务…")
        }
        present()
        // 让 run loop 转一圈：确保窗口与旋转指示器真的画出来并开始动画，
        // 再去做后面那些会占用主线程一点的准备工作。
        await Task.yield()

        // 每秒刷新一次"阶段 + 已用时间"，让等待过程可见
        startProgressTicker()

        do {
            try await service.startIfNeeded()
        } catch {
            stopProgressTicker()
            showFailure(error)
            return
        }
        serviceReadyAt = Date()
        stopProgressTicker()
        usedTokenAuth = false
        tokenAttempts = 0
        lastAttemptedAuthURL = nil
        loadHome()
    }

    /// 进度心跳：把当前阶段与已用时间写进遮罩副标题。
    private func startProgressTicker() {
        progressStartedAt = Date()
        progressTask?.cancel()
        progressTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                guard let self, !self.hasLoadedPage else { return }
                let elapsed = Date().timeIntervalSince(self.progressStartedAt)
                let phase = self.service.state.label
                self.overlay.updateSubtitle(String(format: "%@ · 已用 %.0f 秒", phase, elapsed))
                try? await Task.sleep(nanoseconds: 500_000_000)
            }
        }
    }

    private func stopProgressTicker() {
        progressTask?.cancel()
        progressTask = nil
    }

    /// 加载主页。
    ///
    /// **优先裸加载根地址**，让持久 cookie 发挥作用：本地回环只有一次 GET，
    /// 省掉一次 303 往返，也避免把 token 写进任何 URL。实测 cookie 能跨应用重启、
    /// 跨服务重启保持有效（签名密钥持久化、cookie 不绑定进程级 launch token）。
    ///
    /// 只有 cookie 失效（服务端 401）时，才用带 token 的地址补一次认证；
    /// token 取"服务日志里最新那条"（一定是当前进程的），没有则用缓存的。
    private func loadHome() {
        guard !restarting else {
            logInfo("跳过加载：服务正在重启，稍后由重启流程发起")
            return
        }
        performLoad()
    }

    /// 真正的加载逻辑。重启流程在拿到新 token 后直接调它
    /// （那时 `restarting` 仍为 true，所以不能走 loadHome 的拦截）。
    private func performLoad() {
        // 每次发起加载都回到"未就绪"状态。
        // 这一步不能省：hasLoadedPage 在首次就绪时被置为 true，且不会自己复位；重启服务
        // （以及任何重新加载）走的正是这条路径，若不在这里清掉，didFinish 触发的
        // pollReadiness 会被它的 guard 直接挡回、finishReadiness 永不执行 ——
        // 表现就是"重启后卡在加载界面"（遮罩撤不掉）。
        hasLoadedPage = false
        if config.showStartupOverlay, !finishedOnce {
            overlay.show(message: "正在加载界面…")
        }
        if finishedOnce { connectionRetries = 0 }
        loadGeneration += 1
        let generation = loadGeneration

        // 认证地址的优先级：
        //   1. 本进程从子进程 stdout 解析到的 —— 必然属于当前服务进程，最可靠；
        //   2. 日志里最新那条 —— 用于"复用别人启动的服务"（我们拿不到它的 stdout）；
        //   3. 都没有 → 裸加载根地址，靠持久 cookie（日常最省事的一条路）。
        let target: String
        if let own = service.currentAuthURL {
            target = own
        } else if let recovered = service.recoverTokenFromLog() {
            target = recovered
        } else {
            target = config.rootURL.absoluteString
        }
        usedTokenAuth = (target != config.rootURL.absoluteString)
        if usedTokenAuth {
            tokenAttempts += 1
            lastAttemptedAuthURL = target
        }
        guard generation == loadGeneration else {
            logInfo("跳过已被取代的加载（第 \(generation) 次，当前第 \(loadGeneration) 次）")
            return
        }
        logInfo("加载界面：\(target)")
        guard let url = URL(string: target) else { return }
        webView.load(URLRequest(url: url))
    }

    /// 认证失效时的补救：取一次带 token 的地址重新加载。
    private func recoverAuthentication(reason: String) {
        // 节流：一次失败可能连着触发多个代理回调，避免并发补救打成风暴
        let now = Date()
        guard now.timeIntervalSince(lastRecoveryAt) > 0.5 else { return }
        lastRecoveryAt = now
        logInfo("检测到认证失效（\(reason)），尝试重新认证")

        // 先找现成的认证地址：服务日志里最新那条一定属于当前进程。
        // 必须跳过"已经试过且失败"的那个地址 —— 日志里恢复出来的往往就是它，
        // 不去重会变成无限循环（恢复→加载→401→再恢复）。
        if let url = service.recoverTokenFromLog() ?? service.currentAuthURL,
           url != lastAttemptedAuthURL,
           tokenAttempts < 2 {
            authenticating = true
            usedTokenAuth = true
            lastAttemptedAuthURL = url
            logInfo("用已知认证地址重新加载")
            webView.load(URLRequest(url: URL(string: url)!))
            return
        }

        // 手上没有 token。能不能接管这个服务，取决于它是不是"我们自己留下的"：
        //
        //   · 本启动器此前拉起、退出后继续在跑（设计如此）→ 它变成孤儿，launch token
        //     随进程输出一起消失。它的 pid 记在 service-state.json 里，据此可以认出来，
        //     接管它是安全的 —— 否则用户会被永久堵在这个错误页上。
        //   · 真的是别人启动的（终端里手动跑的、旧启动器留下的）→ **绝不能碰**：
        //     重启会打断正在使用它的会话，SO_REUSEPORT 下还可能两个进程同绑一个端口。
        if !service.ownsProcess, service.isOurOrphanedService() {
            logInfo("端口上的服务是本启动器此前留下的孤儿进程，接管它")
            overlay.show(message: "正在接管遗留服务…")
            authenticating = true
            Task { @MainActor [weak self] in
                guard let self else { return }
                do {
                    try await self.service.takeOverOrphanedService()
                    if let url = self.service.currentAuthURL, let target = URL(string: url) {
                        self.usedTokenAuth = true
                        self.webView.load(URLRequest(url: target))
                    } else {
                        self.showFailure(LauncherError.authenticationFailed)
                    }
                } catch {
                    self.showFailure(error)
                }
            }
            return
        }

        guard service.ownsProcess else {
            logInfo("服务不是本启动器启动的，且无法取得其认证地址；不擅自重启它")
            showFailure(LauncherError.externalServiceNeedsAuth(port: config.port))
            return
        }

        guard tokenAttempts < 2 else {
            logInfo("token 认证已尝试 \(tokenAttempts) 次仍失败，停止重试")
            // 记下这次用过的地址，避免后续再次选中同一个必然失效的 token
            lastAttemptedAuthURL = service.currentAuthURL ?? lastAttemptedAuthURL
            showFailure(LauncherError.authenticationFailed)
            return
        }
        authenticating = true
        usedTokenAuth = true
        logInfo("手上没有可用的认证地址，重启本启动器启动的服务以取得新 token")
        overlay.show(message: "正在重新认证…")
        Task { @MainActor in
            do {
                try await service.restart()
                if let url = service.currentAuthURL, let target = URL(string: url) {
                    webView.load(URLRequest(url: target))
                } else {
                    showFailure(LauncherError.authenticationFailed)
                }
            } catch {
                showFailure(error)
            }
        }
    }

    private func showFailure(_ error: Error) {
        let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        logInfo("失败：\(message)")
        overlay.show(message: "启动失败", detail: message, isError: true)
    }

    // MARK: - 重新加载 / 重启

    /// ⌘R：重新加载页面（服务不动）。用于前端资源更新或界面卡住时。
    func reloadPage() {
        logInfo("重新加载页面")
        webView.reload()
    }

    /// 菜单栏「重启」：停服务 → 重新拉起 → 等就绪 → 重开窗口。
    ///
    /// 必须等端口就绪再加载：否则新服务还没起来，界面会先经历一串连接失败重试
    /// （日志里刷 -1004，遮罩上的计数也在跳），观感上像是出错。
    func restartService(completion: (() -> Void)? = nil) {
        tokenAttempts = 0
        lastAttemptedAuthURL = nil
        guard !restarting else {
            logInfo("重启已在进行中，忽略重复请求")
            return
        }
        restarting = true
        overlay.show(message: "正在重启服务…")
        Task { @MainActor in
            do {
                try await service.restart()
                usedTokenAuth = false
                authenticating = false
                finishedOnce = false
                connectionRetries = 0
                overlay.show(message: "正在等待服务就绪…")
                await waitForServiceReady()
                // 再等一小会儿取新 token：新服务的 launch token 与旧的不同，
                // 手上只有旧的话会白跑一次 401。
                await waitForFreshToken()
                await waitForServiceReady()   // 双保险：token 到了也确认端口可用
                // 走到这里才加载：此时端口已就绪、token 已拿到，一次加载即成功。
                performLoad()
            } catch {
                showFailure(error)
            }
            restarting = false
            completion?()
        }
    }

    /// 轮询等端口就绪（最多约 30 秒），用于重启后。
    private func waitForServiceReady() async {
        let deadline = Date().addingTimeInterval(30)
        while Date() < deadline {
            if service.isListening { return }
            try? await Task.sleep(nanoseconds: 200_000_000)
        }
        logInfo("等待服务就绪超时，仍然尝试加载")
    }

    /// 轮询等本进程解析到新服务的 token（最多约 15 秒）。
    private func waitForFreshToken() async {
        let deadline = Date().addingTimeInterval(15)
        while Date() < deadline {
            if service.currentAuthURL != nil { return }
            try? await Task.sleep(nanoseconds: 200_000_000)
        }
        logInfo("未等到新 token，改用 cookie 或日志里的地址加载")
    }

    func close() {
        saveWindowSizeIfNeeded()
        window?.close()
    }

    // MARK: - NSWindowDelegate

    func windowWillClose(_ notification: Notification) {
        saveWindowSizeIfNeeded()
    }

    /// 关闭窗口不退出应用：服务与菜单栏继续常驻（与原启动器语义一致）。
    func windowShouldClose(_ sender: NSWindow) -> Bool { true }

    private func saveWindowSizeIfNeeded() {
        guard config.windowMode == .custom, config.rememberWindowSize, let window else { return }
        WindowMemory.save(window.frame)
    }

    // MARK: - WKNavigationDelegate

    func webView(_ webView: WKWebView,
                            decidePolicyFor navigationAction: WKNavigationAction,
                            decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        if navigationAction.shouldPerformDownload {
            decisionHandler(.download)
            return
        }
        // 应用窗口不该在内核里"逛网页"：只有本服务自己的页面留在窗口内，
        // 其余 http(s) 链接一律交给系统默认浏览器 —— 包括本机其它服务的链接
        // （如 http://localhost:8787/…），它们以前会被就地打开、把 DSH 界面顶掉。
        if let url = navigationAction.request.url,
           let scheme = url.scheme?.lowercased(),
           scheme == "http" || scheme == "https",
           !config.isOwnService(url) {
            openInSystemBrowser(url)
            decisionHandler(.cancel)
            return
        }
        decisionHandler(.allow)
    }

    func webView(_ webView: WKWebView,
                            decidePolicyFor navigationResponse: WKNavigationResponse,
                            decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void) {
        let status = (navigationResponse.response as? HTTPURLResponse)?.statusCode ?? 0
        let mime = navigationResponse.response.mimeType ?? ""
        // 非可渲染内容（下载）走下载流程
        if !navigationResponse.canShowMIMEType || navigationResponse.response.url?.pathExtension == "zip" {
            decisionHandler(.download)
            return
        }
        Task { @MainActor [weak self] in
            self?.lastStatusCode = status
            if status == 401 {
                logInfo("收到 401（未认证）")
            }
        }
        _ = mime
        decisionHandler(.allow)
    }

    func webView(_ webView: WKWebView,
                            didReceive challenge: URLAuthenticationChallenge,
                            completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        completionHandler(.performDefaultHandling, nil)
    }

    /// 每次新导航开始都复位"认证进行中"标志。
    /// 不复位的话：第一次补救把 authenticating 置 true，失败后第二次补救会被
    /// `guard !authenticating` 直接打回 —— 结果连「识别并接管孤儿服务」都走不到。
    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        authenticating = false
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.finishedOnce = true
            self.detectAuthWall()
        }
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        Task { @MainActor [weak self] in
            self?.handleNavigationError(error)
        }
    }

    func webView(_ webView: WKWebView,
                            didFailProvisionalNavigation navigation: WKNavigation!,
                            withError error: Error) {
        Task { @MainActor [weak self] in
            self?.handleNavigationError(error)
        }
    }

    private func handleNavigationError(_ error: Error) {
        let nsError = error as NSError
        // 服务没起来时的连接失败：服务可能正在冷启动或刚被重启，短暂重试；
        // 但有次数上限，否则会退化成无限循环（原方案在这里是"重复开窗"）。
        if nsError.domain == NSURLErrorDomain,
           nsError.code == NSURLErrorCannotConnectToHost || nsError.code == NSURLErrorNetworkConnectionLost {
            connectionRetries += 1
            guard connectionRetries <= Self.maxConnectionRetries else {
                logInfo("连接服务失败已达 \(Self.maxConnectionRetries) 次，停止重试")
                showFailure(ServiceError.connectionFailed(config.port))
                return
            }
            logInfo("连接服务失败（\(nsError.code)），第 \(connectionRetries) 次重试")
            overlay.show(message: "正在连接服务…",
                         detail: "第 \(connectionRetries)/\(Self.maxConnectionRetries) 次尝试")
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
                self?.loadHome()
            }
            return
        }
        logInfo("加载失败：\(error.localizedDescription)")
        showFailure(error)
    }

    /// 认证墙检测：服务端对未认证的索引请求返回 401 纯文本。
    /// 不能只看 HTTP 状态码（WKWebView 可能把 401 页当普通内容渲染），
    /// 所以再读一次页面文本做双重确认。
    ///
    /// 注意：`didFinish` 只表示 HTML 送达，DSH 前端此时显示 "Loading plugins…"，
    /// 真正渲染出 GUI 还要等客户端插件加载完。所以这里不直接把遮罩撤掉，
    /// 而是启动"就绪轮询"，等页面内容稳定下来再撤。
    private func detectAuthWall() {
        webView.evaluateJavaScript("document.title + '\\n' + (document.body ? document.body.innerText : '')") { [weak self] result, _ in
            guard let self else { return }
            let text = (result as? String) ?? ""
            let isWall = self.lastStatusCode == 401
                || text.contains("authentication required")
                || text.contains("dsh web authentication")
            if isWall {
                logInfo("检测到认证墙（\(text.count) 字符）：\(text.prefix(80))")
                self.recoverAuthentication(reason: "服务端要求认证")
                return
            }
            self.window.title = self.pageTitle(from: text) ?? "DSH"
            self.scheduleReadinessCheck()
        }
    }

    /// 轮询等待前端真正就绪：内容出现且停止增长。
    /// 服务端已经把页面送达（认证通过），所以此时遮罩上的文案是"正在加载界面"。
    private func scheduleReadinessCheck() {
        readinessAttempts = 0
        lastContentLength = -1
        pollReadiness()
    }

    private func pollReadiness() {
        guard !hasLoadedPage else { return }
        readinessAttempts += 1

        // 只取内容长度与前缀：不依赖 __DSH_BOOT_READY__（它在客户端插件加载完成之前
        // 就已经置位了，用它判断会过早撤掉遮罩，露出 "Loading plugins…"）。
        let js = """
        (function(){
          var text = document.body ? document.body.innerText : '';
          return JSON.stringify({
            len: text.length,
            head: text.replace(/\\s+/g, ' ').trim().slice(0, 70)
          });
        })()
        """
        webView.evaluateJavaScript(js) { [weak self] result, _ in
            guard let self else { return }
            guard let json = result as? String,
                  let data = json.data(using: .utf8),
                  let payload = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                self.finishReadiness(head: nil)
                return
            }
            let length = payload["len"] as? Int ?? 0
            let head = payload["head"] as? String ?? ""

            // 就绪判定：
            //   · 内容已经"长得像界面"（>200 字符）→ 立即撤遮罩。
            //     界面雏形约 300 字符，"Loading plugins…" 只有 20 多字符，不会误判。
            //   · 内容还很小 → 按 0.2s 递增到 1.2s 的间隔继续看，最多 ~9 秒兜底。
            //
            // 早先要求"长度连续两次完全相同"再撤遮罩，那是个性能坑：界面若在缓慢填充，
            // 长度一直在变就永远凑不满，必须跑满 25 次（10 秒）才超时收场 ——
            // 表现就是"有时卡住"。
            let hasInterface = length > 200
            if hasInterface || self.readinessAttempts >= 20 {
                self.finishReadiness(head: head, length: length)
                return
            }
            let interval = min(0.2 * Double(self.readinessAttempts), 1.2)
            DispatchQueue.main.asyncAfter(deadline: .now() + interval) { [weak self] in
                self?.pollReadiness()
            }
        }
    }

    private func finishReadiness(head: String?, length: Int? = nil) {
        guard !hasLoadedPage else { return }
        hasLoadedPage = true
        authenticating = false
        connectionRetries = 0
        let count = length ?? lastContentLength
        logInfo("界面就绪（\(max(count, 0)) 字符）\(head.map { "内容开头：\($0)" } ?? "")")
        logStartupTiming()
        overlay.hide()
    }

    /// 打一行启动耗时汇总。四段各自能说明问题：
    ///   · 进程启动→main：dyld 加载 + 运行时/框架初始化（睡眠唤醒后页缓存全冷时最贵的一段）
    ///   · 窗口显示：main 走到窗口摆出来（含 WebKit 对象构建）
    ///   · 服务就绪：复用已有服务时接近 0；冷启动 dsh web 时是最大头
    ///   · 界面就绪：加载 + 前端渲染完成
    private func logStartupTiming() {
        let now = Date()
        func offset(_ date: Date?) -> String {
            guard let date else { return "—" }
            return String(format: "%.2fs", date.timeIntervalSince(LAUNCH_AT))
        }
        let preMain: String
        let total: String
        if let start = ProcessStart.date {
            preMain = String(format: "%.2fs", LAUNCH_AT.timeIntervalSince(start))
            total = String(format: "%.2fs", now.timeIntervalSince(start))
        } else {
            preMain = "?"
            total = offset(now)
        }
        logInfo("启动耗时：进程启动→main \(preMain) / 窗口显示 \(offset(windowShownAt)) / 服务就绪 \(offset(serviceReadyAt)) / 界面就绪 \(offset(now))（合计 \(total)）")
    }

    private func pageTitle(from text: String) -> String? {
        let first = text.split(separator: "\n").first.map(String.init) ?? ""
        return first.isEmpty ? nil : first
    }

    // MARK: - WKUIDelegate（文件上传 / 新窗口 / 右键菜单）

    func webView(_ webView: WKWebView,
                            runOpenPanelWith parameters: WKOpenPanelParameters,
                            initiatedByFrame frame: WKFrameInfo,
                            completionHandler: @escaping ([URL]?) -> Void) {
        Task { @MainActor in
            let panel = NSOpenPanel()
            panel.allowsMultipleSelection = parameters.allowsMultipleSelection
            panel.canChooseDirectories = parameters.allowsDirectories
            panel.canChooseFiles = true
            panel.title = "选择要上传的文件"
            panel.begin { response in
                completionHandler(response == .OK ? panel.urls : nil)
            }
        }
    }

    func webView(_ webView: WKWebView,
                            createWebViewWith configuration: WKWebViewConfiguration,
                            for navigationAction: WKNavigationAction,
                            windowFeatures: WKWindowFeatures) -> WKWebView? {
        // 页面里的 target=_blank：本服务的链接就地打开（保住窗口上下文），
        // 其余（外链、以及本机其它端口的服务）交给系统默认浏览器。
        if let url = navigationAction.request.url {
            if config.isOwnService(url) {
                webView.load(navigationAction.request)
            } else if let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" {
                openInSystemBrowser(url)
            }
        }
        return nil
    }

    /// 交给系统默认浏览器打开，并留一行日志。
    ///
    /// 日志只记 host + path：链接 query 里可能带 token，不能落到 launcher.log 里。
    private func openInSystemBrowser(_ url: URL) {
        let path = url.path.isEmpty ? "/" : url.path
        logInfo("链接交给系统浏览器：\(url.host ?? "?")\(path)")
        NSWorkspace.shared.open(url)
    }

    // MARK: - WKDownloadDelegate

    func download(_ download: WKDownload,
                              decideDestinationUsing response: URLResponse,
                              suggestedFilename: String,
                              completionHandler: @escaping (URL?) -> Void) {
        Task { @MainActor in
            let directory = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
                ?? URL(fileURLWithPath: NSHomeDirectory())
            let name = suggestedFilename.isEmpty ? "download" : suggestedFilename
            var destination = directory.appendingPathComponent(name)
            var index = 2
            let base = (name as NSString).deletingPathExtension
            let ext = (name as NSString).pathExtension
            while FileManager.default.fileExists(atPath: destination.path) {
                let candidate = ext.isEmpty ? "\(base) \(index)" : "\(base) \(index).\(ext)"
                destination = directory.appendingPathComponent(candidate)
                index += 1
            }
            logInfo("下载文件到 \(destination.path)")
            completionHandler(destination)
        }
    }

    func downloadDidFinish(_ download: WKDownload) {
        Task { @MainActor in
            logInfo("下载完成（文件位于「下载」文件夹）")
        }
    }

    func download(_ download: WKDownload, didFailWithError error: Error, resumeData: Data?) {
        Task { @MainActor in
            logInfo("下载失败：\(error.localizedDescription)")
        }
    }
}

// MARK: - 应用自定义错误

enum LauncherError: LocalizedError {
    case authenticationFailed
    case externalServiceNeedsAuth(port: Int)

    var errorDescription: String? {
        switch self {
        case .authenticationFailed:
            return "无法完成认证。请确认 dsh web 服务正在运行，或从菜单栏选择「重启」。"
        case .externalServiceNeedsAuth(let port):
            return """
            端口 \(port) 上的服务不是本启动器启动的，且拿不到它的认证地址。

            两种做法：
            · 菜单栏「重启」会强制停掉它再重新拉起（会打断正在使用它的会话）；
            · 或者在浏览器里打开 dsh 打印的认证地址完成一次认证，
              之后本启动器复用同一个 cookie 即可进入。
            """
        }
    }
}

// MARK: - 带自定义右键菜单的 WKWebView

/// WKWebView 默认右键菜单是浏览器味的（重新载入、检查元素、返回…），
/// 在应用窗口里显得很突兀。这里换成精简版：只保留编辑与查看相关项。
final class WebView: WKWebView {
    weak var appHost: WebWindow?

    override func menu(for event: NSEvent) -> NSMenu? {
        let menu = NSMenu()
        let point = convert(event.locationInWindow, from: nil)
        let element = hitTest(point)

        // 编辑类操作交给 responder chain，这样能正确处理输入框选区
        if element is NSTextView || element is NSTextField {
            menu.addItem(withTitle: "剪切", action: #selector(NSText.cut(_:)), keyEquivalent: "")
            menu.addItem(withTitle: "拷贝", action: #selector(NSText.copy(_:)), keyEquivalent: "")
            menu.addItem(withTitle: "粘贴", action: #selector(NSText.paste(_:)), keyEquivalent: "")
            menu.addItem(.separator())
            menu.addItem(withTitle: "全选", action: #selector(NSText.selectAll(_:)), keyEquivalent: "")
            menu.addItem(.separator())
        }

        let reload = NSMenuItem(title: "刷新", action: #selector(reloadFromMenu), keyEquivalent: "")
        reload.target = self
        menu.addItem(reload)

        let home = NSMenuItem(title: "回到主页", action: #selector(goHome), keyEquivalent: "")
        home.target = self
        menu.addItem(home)

        return menu
    }

    @objc private func reloadFromMenu() {
        Task { @MainActor in appHost?.reloadPage() }
    }

    @objc private func goHome() {
        Task { @MainActor in
            guard let host = appHost, let url = URL(string: host.rootURLString) else { return }
            load(URLRequest(url: url))
        }
    }
}

// MARK: - 窗口尺寸记忆

enum WindowMemory {
    private static let key = "dsh.window.frame"

    static func save(_ frame: NSRect) {
        UserDefaults.standard.set(NSStringFromRect(frame), forKey: key)
    }

    static func load() -> NSRect? {
        guard let stored = UserDefaults.standard.string(forKey: key) else { return nil }
        let rect = NSRectFromString(stored)
        return rect.width > 320 ? rect : nil
    }
}

// MARK: - 旧系统兼容注入

/// DSH 前端在关键路径上用了 `AbortSignal.any` / `Promise.withResolvers` / `Promise.try`
/// （2024-03 起才 Baseline），且没有 polyfill。macOS 14.4+ 的 WebKit 已内置，
/// 这里仍然注入兜底实现，让更旧的系统也能跑起来，并避免个别版本的行为差异。
enum Polyfill {
    static func script() -> WKUserScript {
        let source = """
        (function () {
          try {
            if (typeof AbortSignal !== 'undefined' && typeof AbortSignal.any !== 'function') {
              AbortSignal.any = function (signals) {
                var controller = new AbortController();
                var abort = function (reason) { controller.abort(reason); };
                for (var i = 0; i < signals.length; i++) {
                  var signal = signals[i];
                  if (signal.aborted) { abort(signal.reason); return controller.signal; }
                  signal.addEventListener('abort', function (event) { abort(event.target.reason); }, { once: true });
                }
                return controller.signal;
              };
            }
            if (typeof Promise.withResolvers !== 'function') {
              Promise.withResolvers = function () {
                var resolve, reject;
                var promise = new Promise(function (res, rej) { resolve = res; reject = rej; });
                return { promise: promise, resolve: resolve, reject: reject };
              };
            }
            if (typeof Promise.try !== 'function') {
              Promise.try = function (fn) {
                var args = Array.prototype.slice.call(arguments, 1);
                return new Promise(function (resolve) { resolve(fn.apply(undefined, args)); });
              };
            }
          } catch (error) {
            console.error('dsh polyfill failed:', error);
          }
        })();
        """
        return WKUserScript(source: source, injectionTime: .atDocumentStart, forMainFrameOnly: false)
    }
}
