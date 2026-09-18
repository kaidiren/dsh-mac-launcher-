// AppMain.swift —— 应用入口：单实例守卫、应用菜单、生命周期编排。
//
// 原方案里"点 Dock 图标"要跑一整支 bash 脚本才能决定做什么；
// 这里启动即完成决策：已有实例 → 唤醒它并退出自己；没有 → 起服务、开窗、挂菜单栏。
import Cocoa

/// 启动计时起点：main 顶层的第一条语句，越早越好。
/// 配合 `ProcessStart.date` 就能把「进程启动 → main」这一段（dyld 加载、运行时与
/// WebKit 等框架初始化 —— 睡眠唤醒后页缓存全冷时最贵的一段）单独量出来。
let LAUNCH_AT = Date()

// MARK: - 单实例守卫

/// 同一个启动器只允许跑一份：
/// 原方案靠 mkdir 锁 + 两次点击都会各自开窗来兜底，这里直接用应用实例表判断。
enum InstanceGuard {
    static let bundleID = "com.kaidiren.dsh-mac-launcher"

    /// 若已有实例在运行则激活它并返回 true（调用方应退出）。
    static func activateExistingInstanceIfAny() -> Bool {
        let others = NSRunningApplication
            .runningApplications(withBundleIdentifier: bundleID)
            .filter { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier }
        guard let existing = others.first else { return false }
        logInfo("检测到已有实例在运行（pid=\(existing.processIdentifier)），激活它并退出本次启动")
        existing.activate(options: [.activateAllWindows])
        return true
    }
}

// MARK: - 应用委托

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var config: LauncherConfig!
    private var service: ServiceController!
    private var window: WebWindow!
    private var menuBar: MenuBar?

    func applicationDidFinishLaunching(_ notification: Notification) {
        config = LauncherConfig.load(forwardedArgs: AppFlags.forwardArgs)
        Log.shared.configure(directory: config.logDirectory)
        LogDirectory.current = config.logDirectory
        ServiceController.ServiceLogWriter.shared.configure(config.serviceLogPath)
        NotificationCenter.default.addObserver(forName: .dshLauncherRetryRequested,
                                               object: nil,
                                               queue: .main) { [weak self] _ in
            Task { @MainActor in await self?.window.start() }
        }

        logInfo("DSH 原生启动器启动（bundle=\(Bundle.main.bundleIdentifier ?? "-")，port=\(config.port)）")

        // 自检模式：只打印本次决策，不做任何动作。必须放在单实例守卫之前——
        // 它是只读的，既不该被"已有实例在运行"挡掉，也不该起服务或开窗。
        if AppFlags.printDecision {
            print("PORT=\(config.port)")
            print("DSH_BIN=\(config.dshBin)")
            print("WORKDIR=\(config.workdir)")
            print("WINDOW_MODE=\(config.windowMode.rawValue)")
            print("WINDOW_SIZE=\(Int(config.windowWidth))x\(Int(config.windowHeight))")
            print("TRAY=\(config.trayEnabled ? 1 : 0)")
            print("OPEN_WINDOW=\(config.openWindowOnLaunch ? 1 : 0)")
            print("IMMERSIVE=\(config.immersiveWindow ? 1 : 0)")
            print("SERVICE_LISTENING=\(PortProbe.isListening(port: config.port) ? 1 : 0)")
            print("LOG_DIR=\(config.logDirectory.path)")
            exit(0)
        }

        // 单实例：第二次点 Dock 图标不该再起一个服务/窗口。
        // 隔离模式跳过它，供旁路验证启动流程（必须配独立的端口与日志目录）。
        if AppFlags.isolated {
            logInfo("隔离模式：跳过单实例守卫")
        } else if InstanceGuard.activateExistingInstanceIfAny() {
            NSApp.terminate(nil)
            return
        }

        buildMainMenu()

        // 先把"能看到的东西"建好：服务控制器、窗口、菜单栏图标。
        // 冷启动时 dsh web 要约 10 秒才就绪，用户不该在这 10 秒里对着空白等。
        service = ServiceController(config: config)
        window = WebWindow(config: config, service: service)

        if config.trayEnabled {
            let bar = MenuBar(config: config, service: service, window: window)
            bar.onOpen = { [weak self] in self?.showWindow() }
            menuBar = bar
        }

        if config.openWindowOnLaunch {
            // 立刻把窗口摆出来（此时遮罩已在转），再异步走服务启动流程。
            // 放到下一个 run loop 是为了让窗口先完成首次绘制。
            window.present()
            Task { @MainActor in
                await Task.yield()
                await window.start()
            }
        } else {
            logInfo("按配置不自动开窗（DSH_OPEN_WINDOW=0）")
            if config.showStartupOverlay {
                // 不开窗也要让后续"从菜单栏打开"能直接进
                logInfo("等待用户从菜单栏打开窗口")
            }
        }

        if AppFlags.selfTestRestart {
            logInfo("自省模式：5 秒后触发一次「重启服务」")
            DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in
                self?.runSelfTestRestart()
            }
        }

        if AppFlags.selfTestClose {
            logInfo("自省模式：界面就绪后关闭窗口，检查应用与服务是否仍存活")
            DispatchQueue.main.asyncAfter(deadline: .now() + 22) { [weak self] in
                self?.runSelfTestClose()
            }
        }
    }

    /// 点 Dock 图标（或再次打开应用）时把窗口找回来。
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showWindow()
        return true
    }

    /// 关掉窗口不退出应用：服务与菜单栏继续常驻。
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    private func showWindow() {
        guard let window else { return }
        if window.hasLoadedPage {
            window.present()
        } else {
            Task { await window.start() }
        }
    }

    /// 退出流程。
    ///
    /// 注意：**不能**在 applicationWillTerminate 里同步等待 `service.stop()`——
    /// 那是 @MainActor 方法，而这里正跑在主线程上，用信号量等它必然死锁，
    /// 结果就是"点了退出，日志说有停服务，进程却还活着"。
    /// 改为：先异步停服务（带超时上限），停完再真正 terminate。
    private var isTerminating = false

    func requestQuit() {
        guard !isTerminating else { return }
        isTerminating = true
        logInfo("开始退出：停服务 → 撤菜单栏图标")
        menuBar?.remove()

        guard let service, service.ownsProcess else {
            logInfo("服务非本启动器启动，保留其运行")
            NSApp.terminate(nil)
            return
        }

        Task { @MainActor in
            // 硬上限：`dsh web` 可能有活跃连接，迟迟不退的话不能让「退出」看起来卡死
            let stopper = Task { await service.stop() }
            let timeout = Task {
                try? await Task.sleep(nanoseconds: 8_000_000_000)
                stopper.cancel()
            }
            await stopper.value
            timeout.cancel()
            logInfo("已退出")
            NSApp.terminate(nil)
        }
    }

    /// 真正退出时只做清理（服务已在 requestQuit 里停好）。
    func applicationWillTerminate(_ notification: Notification) {
        menuBar?.remove()
    }

    // MARK: - 应用菜单

    /// 原生应用菜单：⌘W 关窗口、⌘R 重新载入、⇧⌘R 重启服务、⌘Q 退出。
    private func buildMainMenu() {
        let mainMenu = NSMenu()

        // 应用菜单
        let appMenuItem = NSMenuItem()
        let appMenu = NSMenu()
        let appName = "DSH"
        appMenu.addItem(withTitle: "关于 \(appName)", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "隐藏 \(appName)", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "退出 \(appName)", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appMenuItem.submenu = appMenu
        mainMenu.addItem(appMenuItem)

        // 编辑菜单：WKWebView 里的输入框依赖它提供 ⌘C/⌘V/⌘A 的标准动作
        let editMenuItem = NSMenuItem()
        let editMenu = NSMenu(title: "编辑")
        editMenu.addItem(withTitle: "撤销", action: Selector(("undo:")), keyEquivalent: "z")
        editMenu.addItem(withTitle: "重做", action: Selector(("redo:")), keyEquivalent: "Z")
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: "剪切", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "拷贝", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "粘贴", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "全选", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editMenuItem.submenu = editMenu
        mainMenu.addItem(editMenuItem)

        // 显示菜单：页面缩放。对应 Chrome 的 ⌘+ / ⌘- / ⌘0 ——
        // 注意这是"页面整体缩放"（布局按比例放大），不是手势那种浮层放大。
        let viewMenuItem = NSMenuItem()
        let viewMenu = NSMenu(title: "显示")
        let zoomIn = NSMenuItem(title: "放大", action: #selector(zoomInAction), keyEquivalent: "+")
        zoomIn.target = self
        viewMenu.addItem(zoomIn)
        let zoomOut = NSMenuItem(title: "缩小", action: #selector(zoomOutAction), keyEquivalent: "-")
        zoomOut.target = self
        viewMenu.addItem(zoomOut)
        let zoomReset = NSMenuItem(title: "实际大小", action: #selector(zoomResetAction), keyEquivalent: "0")
        zoomReset.target = self
        viewMenu.addItem(zoomReset)
        viewMenuItem.submenu = viewMenu
        mainMenu.addItem(viewMenuItem)

        // 窗口菜单
        let windowMenuItem = NSMenuItem()
        let windowMenu = NSMenu(title: "窗口")
        let close = NSMenuItem(title: "关闭窗口", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        windowMenu.addItem(close)
        let reload = NSMenuItem(title: "重新载入界面", action: #selector(reloadPage), keyEquivalent: "r")
        reload.target = self
        windowMenu.addItem(reload)
        let restart = NSMenuItem(title: "重启服务", action: #selector(restartService), keyEquivalent: "R")
        restart.target = self
        windowMenu.addItem(restart)
        windowMenu.addItem(.separator())
        windowMenu.addItem(withTitle: "最小化", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        windowMenuItem.submenu = windowMenu
        mainMenu.addItem(windowMenuItem)

        NSApp.mainMenu = mainMenu
        NSApp.windowsMenu = windowMenu
    }

    // MARK: - 页面缩放动作（菜单「显示」调它们）

    @objc private func zoomInAction() { window?.zoomIn() }
    @objc private func zoomOutAction() { window?.zoomOut() }
    @objc private func zoomResetAction() { window?.resetZoom() }

    /// 自省：关窗口后确认「关窗不退出应用、也不停服务」。
    private func runSelfTestClose() {
        logInfo("自省：关闭窗口")
        window.close()
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
            guard let self else { return }
            let windowClosed = !self.window.isOpen
            let serviceAlive = self.service.isListening
            logInfo("自省：关窗后 窗口已关=\(windowClosed ? "是" : "否") 服务仍在监听=\(serviceAlive ? "是" : "否")")
            logInfo("自省：结论=\(windowClosed && serviceAlive ? "符合预期（关窗留服务）" : "不符合预期")")
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                logInfo("自省：结束，退出")
                self.requestQuit()
            }
        }
    }

    /// 自省：走的是与菜单栏「重启服务」同一个 window.restartService()。
    private func runSelfTestRestart() {
        logInfo("自省：触发重启服务")
        window.restartService { [weak self] in
            guard let self else { return }
            self.logInfoRestartOutcome()
            // 留足时间让界面走完"就绪"判定，再退出
            DispatchQueue.main.asyncAfter(deadline: .now() + 14) {
                logInfo("自省：重启流程结束，退出")
                self.requestQuit()
            }
        }
    }

    private func logInfoRestartOutcome() {
        logInfo("自省：重启完成，服务监听=\(service.isListening ? "是" : "否")")
    }

    @objc private func reloadPage() { window?.reloadPage() }
    @objc private func restartService() { window?.restartService() }
}

// MARK: - 命令行参数

/// 启动器自己识别的参数；其余原样转给 `dsh web`（与原脚本的透传行为一致）。
enum AppFlags {
    private(set) static var forwardArgs: [String] = []
    private(set) static var printDecision = false
    /// 自省：启动完成后触发一次「重启服务」，用于验证该动作的完整链路。
    /// 菜单栏动作无法用脚本点击（需要辅助功能权限），这条路径是它的可靠替身。
    private(set) static var selfTestRestart = false
    /// 自省：关掉窗口后检查"应用与服务是否都还活着"，然后退出。
    /// 「关窗不退出应用」这条行为无法用脚本点关闭按钮验证（需要辅助功能权限）。
    private(set) static var selfTestClose = false
    /// 隔离模式：跳过单实例守卫。
    ///
    /// 为什么需要它：单实例守卫让"再启动一个实例"在架构上不可能，
    /// 于是任何需要在旁路验证启动流程的人（包括自动化脚本）都只能去 kill 正在用的实例，
    /// 反而更容易把用户正在用的窗口弄没。给测试一个独立入口更安全。
    /// 注意：隔离实例若与正式实例共用端口/数据目录，仍会互相打架，务必配合
    /// DSH_WEB_PORT 与 DSH_LOG_DIR 指向独立位置使用。
    private(set) static var isolated = false

    static func parse() {
        var forwarded: [String] = []
        var iterator = CommandLine.arguments.dropFirst().makeIterator()
        while let argument = iterator.next() {
            switch argument {
            case "--print-decision":
                printDecision = true
            case "--self-test-restart":
                selfTestRestart = true
            case "--self-test-close":
                selfTestClose = true
            case "--isolated":
                isolated = true
            case "--help", "-h":
                printUsage()
                exit(0)
            case "--version":
                print("dsh-mac-launcher \(Version.string)")
                exit(0)
            default:
                // 原脚本把参数原样转给 dsh web；这里保持同样行为
                forwarded.append(argument)
            }
        }
        forwardArgs = forwarded
    }

    private static func printUsage() {
        print("""
        dsh-mac-launcher —— DSH Web GUI 的原生 macOS 启动器（不依赖 Chrome）

        用法：
          dsh-mac-launcher [启动器选项] [-- dsh web 的额外参数]

        启动器选项：
          --print-decision   只打印本次的启动决策，不做任何动作（自检用）
          --self-test-restart 启动后自动触发一次「重启服务」（验证该动作的链路）
          --self-test-close   启动后关闭窗口，验证「关窗不退出应用、也不停服务」
          --isolated          跳过单实例守卫（验证启动流程用；请配合独立的
                              DSH_WEB_PORT 与 DSH_LOG_DIR，否则会与正式实例互相干扰）
          --version          打印版本
          --help             显示本帮助

        其余参数原样转给 `dsh web`。

        配置（环境变量，也可写在 ~/.dsh/mac-launcher.yaml）：
          DSH_WEB_PORT        服务端口，默认 3080
          DSH_BIN             dsh 可执行文件路径（默认自动探测）
          DSH_WORKDIR         dsh web 的工作目录，默认 ~
          DSH_WINDOW_MODE     maximized（默认，占满屏幕）| custom
          DSH_WINDOW_WIDTH    仅 custom 模式，默认 1180
          DSH_WINDOW_HEIGHT   仅 custom 模式，默认 800
          DSH_IMMERSIVE_WINDOW 1 = 隐藏标题栏的沉浸式窗口
          DSH_TRAY            1（默认）= 显示菜单栏图标
          DSH_OPEN_WINDOW     1（默认）= 启动时自动开窗
          DSH_LOG_DIR         日志目录，默认 ~/Library/Logs/DSH
        """)
    }
}

enum Version {
    static let string = "1.0.0"
}

// MARK: - 信号处理

/// 处理 SIGTERM / SIGINT，让应用走正常退出流程。
///
/// 否则 `kill <pid>`（以及某些关停场景）会让进程直接被内核收走：
/// applicationWillTerminate 不执行 → 后台服务不被停止，留下来变成孤儿进程。
enum SignalHandling {
    nonisolated(unsafe) private static var shuttingDown = false

    static func install() {
        for signalNumber in [SIGTERM, SIGINT] {
            let source = DispatchSource.makeSignalSource(signal: signalNumber, queue: .main)
            source.setEventHandler {
                if shuttingDown { return }
                shuttingDown = true
                logInfo("收到信号 \(signalNumber)，开始优雅退出")
                // 信号回调不在 actor 上下文中，切回主 actor 再走退出流程
                Task { @MainActor in
                    (NSApp.delegate as? AppDelegate)?.requestQuit()
                }
            }
            source.resume()
            signal(signalNumber, SIG_IGN)
            sources.append(source)
        }
    }

    nonisolated(unsafe) private static var sources: [DispatchSourceSignal] = []
}

// MARK: - 入口

AppFlags.parse()

// 从终端直接跑（非 .app 包）时，让 AppKit 把它当成普通应用来初始化。
// main.swift 的顶层代码本就运行在主线程上。
MainActor.assumeIsolated {
    let application = NSApplication.shared
    let delegate = AppDelegate()
    application.delegate = delegate
    application.setActivationPolicy(.regular)
    SignalHandling.install()
    application.run()
}
