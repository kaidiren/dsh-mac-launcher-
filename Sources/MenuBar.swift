// MenuBar.swift —— 菜单栏常驻图标（在应用进程内）。
//
// 图标跑在应用进程内，因此这些常见麻烦都不存在：
//   · 不需要 pid 文件判断"图标是否已在跑"（只有一个应用实例）
//   · 不需要跨进程的标志文件
//   · 不需要 open -a 绕一圈（AppleScript 的 TCC 权限按发起进程判定，这里没这问题）
//   · 不需要端口隔离与标志保质期
// 点菜单项 = 直接调本进程内的方法。
import Cocoa

@MainActor
final class MenuBar: NSObject, NSMenuDelegate {
    private var statusItem: NSStatusItem
    private let config: LauncherConfig
    private let service: ServiceController
    private unowned let window: WebWindow

    /// 打开（左键或菜单项）。
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
    /// 加载 `@2x`（32×32）那份，
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
        case .exited(let pid):
            return "DSH 服务已退出（pid \(pid)），可在菜单里重启"
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

        // 状态行：说清服务归属（外部启动的服务，重启时会先被强制停掉）。
        let header = NSMenuItem(title: statusLine(), action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)
        menu.addItem(.separator())

        let open = NSMenuItem(title: "打开", action: #selector(openWindow), keyEquivalent: "o")
        open.target = self
        open.isEnabled = true
        menu.addItem(open)

        let reload = NSMenuItem(title: "刷新", action: #selector(reloadPage), keyEquivalent: "r")
        reload.target = self
        reload.isEnabled = service.state.isRunning
        menu.addItem(reload)

        menu.addItem(.separator())
        // 「重启」无条件可用：它的语义是"把端口上的服务重启掉"，
        // 哪怕那个服务不是本启动器拉起的 —— 先强制停掉，再重新拉起。
        // 唯一例外是动作正在进行中（busy），避免重入。
        let restart = NSMenuItem(title: "重启", action: #selector(restartService), keyEquivalent: "R")
        restart.target = self
        restart.isEnabled = !service.state.isBusy
        restart.toolTip = service.ownsProcess
            ? "停止并重新拉起端口 \(config.port) 上的 dsh web"
            : "端口 \(config.port) 上的服务不是本启动器启动的：重启会先强制停掉它再重新拉起（会打断正在使用它的会话）"
        menu.addItem(restart)

        let quit = NSMenuItem(title: "退出", action: #selector(quitAll), keyEquivalent: "q")
        quit.target = self
        quit.isEnabled = true
        menu.addItem(quit)

        return menu
    }

    private func statusLine() -> String {
        switch service.state {
        case .ready:
            let owner = service.ownsProcess ? "" : "（外部启动）"
            return "运行中 · 端口 \(config.port)\(owner)"
        case .starting: return "正在启动服务…"
        case .waitingPort: return "等待服务就绪…"
        case .exited(let pid): return "服务已退出（pid \(pid)）"
        case .failed(let reason): return "启动失败：\(reason)"
        case .idle: return "DSH 未运行"
        }
    }

    // MARK: - 动作

    @objc private func openWindow() {
        logInfo("菜单栏：打开")
        onOpen?()
    }

    @objc private func reloadPage() {
        logInfo("菜单栏：刷新")
        window.reloadPage()
    }

    @objc private func restartService() {
        // 不再按归属设限：用户要的就是"把这个端口上的服务重启掉"。
        // 非本启动器拉起的服务会先被强制停止（可能打断正在使用它的会话），日志里会写明。
        logInfo(service.ownsProcess
                ? "菜单栏：重启"
                : "菜单栏：重启（端口上的服务非本启动器启动，将强制停止后重新拉起）")
        window.restartService()
    }

    /// 退出 = 关窗口 + 停服务 + 撤图标。
    /// 走 AppDelegate.requestQuit：停服务是异步的，必须等它做完再真正退出
    /// （早期直接在 applicationWillTerminate 里同步等待，会与主线程死锁）。
    @objc private func quitAll() {
        logInfo("菜单栏：退出（关窗口 + 停服务 + 撤图标）")
        (NSApp.delegate as? AppDelegate)?.requestQuit()
    }

    func remove() {
        NSStatusBar.system.removeStatusItem(statusItem)
    }
}
