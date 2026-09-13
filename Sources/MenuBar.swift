// MenuBar.swift —— 菜单栏常驻图标（在应用进程内）。
//
// 与原 dsh-tray 的根本区别：它不再是一个独立进程，因此：
//   · 不需要 pid 文件判断"托盘是否已在跑"（只有一个应用实例）
//   · 不需要 .dsh-stop-request-* / .dsh-restart-request-* 标志文件
//   · 不需要 open -a 绕一圈（TCC 权限按发起进程判定带来的限制，这里根本不存在）
//   · 不需要端口隔离与 90 秒保质期
// 点菜单项 = 直接调本进程内的方法。
import Cocoa

@MainActor
final class MenuBar: NSObject, NSMenuDelegate {
    private var statusItem: NSStatusItem
    private let config: LauncherConfig
    private let service: ServiceController
    private unowned let window: WebWindow

    /// 打开窗口（左键或菜单项）。
    var onOpen: (() -> Void)?

    init(config: LauncherConfig, service: ServiceController, window: WebWindow) {
        self.config = config
        self.service = service
        self.window = window
        self.statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        super.init()

        // 直接挂菜单：点击即弹出，菜单项在 menuNeedsUpdate 里按实时状态重建。
        // （早先用「临时挂菜单 → performClick → 立刻摘掉」会让 action 来不及派发；
        //   挂在 statusItem.menu 上交给 AppKit 管理则没有这个问题。）
        statusItem.menu = NSMenu()
        statusItem.menu?.delegate = self
        if let button = statusItem.button {
            button.image = Self.trayIcon()
            button.image?.isTemplate = true
            button.toolTip = tooltip()
        }

        service.onStateChange = { [weak self] _ in
            self?.refresh()
        }
        refresh()
    }

    // MARK: - 图标

    /// 菜单栏图标：黑色鲸鱼（模板图标，菜单栏明暗自动反白）。
    ///
    /// 与 dsh-launcher 的 dsh-tray 保持一致：加载 `@2x`（32×32）那份，
    /// 逻辑尺寸设 18pt —— 系统按屏幕倍率铺满，Retina 下清晰。
    /// 注意别换成 1x（16×16）那份：它在 Retina 上要被拉大两倍多，会发糊。
    private static func trayIcon() -> NSImage? {
        let name = "tray-iconTemplate@2x"
        let candidates: [URL?] = [
            Bundle.main.url(forResource: name, withExtension: "png", subdirectory: "icons"),
            Bundle.main.url(forResource: name, withExtension: "png"),
            // 从源码目录直接运行（未打 .app）时的后备路径
            URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent().deletingLastPathComponent()
                .appendingPathComponent("Resources/icons/\(name).png"),
        ]
        for case let url? in candidates {
            guard let image = NSImage(contentsOf: url) else { continue }
            image.size = NSSize(width: 18, height: 18)
            return image
        }
        return nil
    }

    private func refresh() {
        guard let button = statusItem.button else { return }
        button.image = Self.trayIcon()
        button.image?.isTemplate = true
        button.toolTip = tooltip()
    }

    private func tooltip() -> String {
        switch service.state {
        case .ready:
            return "DSH 运行中（端口 \(config.port)）"
        case .starting, .waitingPort:
            return "DSH 正在启动…"
        case .failed(let reason):
            return "DSH 启动失败：\(reason)"
        case .idle:
            return "DSH 未运行"
        }
    }

    // MARK: - 交互

    /// 菜单每次显示前重建，保证状态行与各项可用性都是最新的。
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        for item in buildMenu().items {
            menu.addItem(item)
        }
    }

    /// 每次弹出时重建菜单，保证状态是实时的。
    private func buildMenu() -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false

        // 状态行：同时说清服务归属。用户据此就能明白为什么「重启服务」不可用。
        let header = NSMenuItem(title: statusLine(), action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)
        menu.addItem(.separator())

        let open = NSMenuItem(title: "打开窗口", action: #selector(openWindow), keyEquivalent: "o")
        open.target = self
        open.isEnabled = true
        menu.addItem(open)

        let reload = NSMenuItem(title: "重新载入界面", action: #selector(reloadPage), keyEquivalent: "r")
        reload.target = self
        reload.isEnabled = service.state.isRunning
        menu.addItem(reload)

        menu.addItem(.separator())
        // 重启的可用范围：
        //   · 自己启动的服务 → 正常重启；
        //   · 本启动器此前留下、现已成孤儿的服务 → 接管（否则它会一直占着端口又认证不了）；
        //   · 真正的外来服务 → 禁用，重启它会打断正在使用它的会话。
        let owned = service.ownsProcess
        let orphaned = !owned && service.isOurOrphanedService()
        let restart = NSMenuItem(title: orphaned ? "接管服务" : "重启服务",
                                 action: #selector(restartService),
                                 keyEquivalent: "R")
        restart.target = self
        restart.isEnabled = (owned || orphaned) && !service.state.isBusy
        if !owned && !orphaned {
            restart.toolTip = "该服务不是本启动器启动的，重启它会打断正在使用它的会话"
        } else if orphaned {
            restart.toolTip = "这是本启动器此前留下、仍在运行的服务：接管它以便重新获得认证"
        }
        menu.addItem(restart)

        let quit = NSMenuItem(title: "退出 DSH", action: #selector(quitAll), keyEquivalent: "q")
        quit.target = self
        quit.isEnabled = true
        menu.addItem(quit)

        return menu
    }

    private func statusLine() -> String {
        switch service.state {
        case .ready:
            let owner = service.ownsProcess ? "" : "（外部启动）"
            return "DSH 运行中 · 端口 \(config.port)\(owner)"
        case .starting: return "正在启动服务…"
        case .waitingPort: return "等待服务就绪…"
        case .failed(let reason): return "启动失败：\(reason)"
        case .idle: return "DSH 未运行"
        }
    }

    // MARK: - 动作

    @objc private func openWindow() {
        logInfo("菜单栏：打开窗口")
        onOpen?()
    }

    @objc private func reloadPage() {
        logInfo("菜单栏：重新载入界面")
        window.reloadPage()
    }

    @objc private func restartService() {
        // 双保险：菜单项对外来服务已禁用，这里再确认一次，
        // 因为"重启别人的服务"会打断正在使用它的会话。
        guard service.ownsProcess || service.isOurOrphanedService() else {
            logInfo("菜单栏：重启服务被拒绝——该服务不是本启动器启动的")
            window.showExternalServiceNotice()
            return
        }
        logInfo(service.ownsProcess ? "菜单栏：重启服务" : "菜单栏：接管遗留服务")
        window.restartService()
    }

    /// 退出 = 关窗口 + 停服务 + 撤图标。
    /// 走 AppDelegate.requestQuit：停服务是异步的，必须等它做完再真正退出
    /// （早期直接在 applicationWillTerminate 里同步等待，会与主线程死锁）。
    @objc private func quitAll() {
        logInfo("菜单栏：退出 DSH（关窗口 + 停服务 + 撤图标）")
        (NSApp.delegate as? AppDelegate)?.requestQuit()
    }

    func remove() {
        NSStatusBar.system.removeStatusItem(statusItem)
    }
}
