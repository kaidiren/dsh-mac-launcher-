// Config.swift —— 启动器配置。
//
// 目的：集中所有可调项，并把状态文件放在用户的标准位置
// （日志进 ~/Library/Logs/DSH，状态进 UserDefaults）。
//
// 优先级：命令行参数 > 环境变量 > 配置文件 > 内置默认值
// 环境变量名保持稳定，升级后原有自定义无需改写。
import Foundation

/// 窗口尺寸模式。
enum WindowMode: String {
    /// 占满屏幕可用区域（默认）。
    case maximized
    /// 使用固定尺寸。
    case custom
}

/// 冻结后的启动器配置。
struct LauncherConfig {
    // MARK: 服务
    var port: Int = 3080
    var dshBin: String = ""
    var workdir: String = ""
    /// 透传给 `dsh web` 的额外参数（命令行里未被启动器识别的部分）。
    var forwardArgs: [String] = []
    var serviceReadyTimeout: TimeInterval = 60
    var tokenTimeout: TimeInterval = 20
    var startupGrace: TimeInterval = 10
    var stopTimeout: TimeInterval = 10

    // MARK: 窗口
    var windowMode: WindowMode = .maximized
    var windowWidth: Double = 1180
    var windowHeight: Double = 800
    /// 记住用户调整过的窗口大小（仅 custom 模式且有记忆值时生效）。
    var rememberWindowSize: Bool = true

    // MARK: 界面
    var trayEnabled: Bool = true
    var openWindowOnLaunch: Bool = true
    var showStartupOverlay: Bool = true
    /// 用无边距沉浸式窗口（隐藏标题栏），观感更接近原生应用。
    var immersiveWindow: Bool = false
    /// 页面缩放（对应 Chrome 的"页面缩放"，不是手势那种浮层放大）。
    /// 只作为**首次运行**的初值：之后用户在窗口里 ⌘+ / ⌘- 调过的值会被记住并优先。
    var pageZoom: Double = 1.0

    // MARK: 文件位置
    var logDirectory: URL = LauncherConfig.defaultLogDirectory()
    var appLogPath: URL { logDirectory.appendingPathComponent("launcher.log") }
    var serviceLogPath: URL { logDirectory.appendingPathComponent("service.log") }
    /// `dsh web` 的原始输出（stdout + stderr 合流）。启动器按节奏增量读它：一边解析
    /// 认证 URL，一边把脱敏后的内容转发进 `service.log`。
    /// 里面会出现**明文认证 URL**，所以固定 0600：这份不外发，要外发用 `service.log`。
    var serviceRawLogPath: URL { logDirectory.appendingPathComponent("service-raw.log") }
    /// 带 token 认证 URL 的缓存（权限 0600；token 是本机凭据）。
    var authCachePath: URL { logDirectory.appendingPathComponent("auth-url") }

    /// 记录"本启动器拉起的服务进程"（pid + 启动时间）。
    /// 用途：启动器退出后服务会继续跑（这是设计），下次启动时端口被它占着，
    /// 而它的 launch token 随进程输出一起消失了 —— 靠这个文件就能认出
    /// "这是我自己留下的服务，可以放心接管"，而不会误判成别人的服务。
    var serviceStatePath: URL { logDirectory.appendingPathComponent("service-state.json") }

    /// 可能记着认证 URL 的日志文件，按"越新越优先"排列。
    /// 也包含旧版 shell 启动器的日志：端口上那个服务若是它启动的，
    /// 其 token 只会出现在那份日志里。
    var authLogCandidates: [URL] {
        // 原始日志里是**明文**（service.log 的 token 已被 Log.redact 写成 <REDACTED>，
        // 正则匹配不到），所以它排第一；service.log 作为后备 —— 老版本或外部启动器
        // 留下的日志里可能有明文。
        var candidates: [URL] = [serviceRawLogPath, serviceLogPath]
        // 旧版 shell 启动器可能把日志留在这两处
        let legacyLogs = [
            "\(homeDirectory)/dsh/dsh-launcher/dsh-web.log",
            "\(homeDirectory)/dsh-launcher/dsh-web.log",
        ]
        candidates.append(contentsOf: legacyLogs.map { URL(fileURLWithPath: $0) })
        // 与旧启动器共用日志目录时，它可能仍按旧名写
        candidates.append(logDirectory.appendingPathComponent("dsh-web.log"))
        return candidates
    }

    private var homeDirectory: String { NSHomeDirectory() }

    // MARK: 派生
    var rootURL: URL { URL(string: "http://127.0.0.1:\(port)/")! }

    /// 这个 URL 是否属于**本启动器自己的服务**：只看端口。
    ///
    /// 规则：启动端口是 `port`（默认 3080）时，3080 上的页面一律留在 WKWebView 内导航 ——
    /// 它们是本服务的界面、SPA 路由与认证跳转（cookie 失效时会用带 token 的地址加载，
    /// 服务端 303 到 `/?token=…` 并下发 cookie；这一步若被丢到外部浏览器，窗口就再也
    /// 拿不到 cookie，只能反复重启服务）。其它端口 —— 本机别的服务（如 8787 的看板）
    /// 与任何外网地址 —— 一律交给系统默认浏览器，点链接不再把 DSH 界面顶掉。
    ///
    /// 不校验 host：`127.0.0.1:3080`、`localhost:3080` 都算自己（写法不同、端口相同）。
    /// 代价是形如 `example.com:3080` 的外网地址也会被当成"自己的服务"留在窗口内；
    /// 真要收紧，加一条"host 必须回环"的条件即可。
    func isOwnService(_ url: URL) -> Bool {
        let scheme = url.scheme?.lowercased() ?? ""
        guard scheme == "http" || scheme == "https" else { return false }
        return (url.port ?? (scheme == "https" ? 443 : 80)) == port
    }

    /// 应用自身默认位置（用于把 dsh 的 nvm bin 目录补进 PATH）。
    static var homeDirectory: String { NSHomeDirectory() }

    /// 默认日志目录：用户标准位置，不再把运行期文件写进源码目录。
    static func defaultLogDirectory() -> URL {
        URL(fileURLWithPath: "\(homeDirectory)/Library/Logs/DSH")
    }

    // MARK: 载入
    /// 从环境变量与配置文件组装配置。`dshForwardArgs` 是命令行里未识别的参数。
    static func load(forwardedArgs: [String] = []) -> LauncherConfig {
        let env = ProcessInfo.processInfo.environment
        var config = LauncherConfig()

        // 1. 配置文件（~/.dsh/mac-launcher.yaml 的极简解析：仅 key: value）
        let fileValues = readConfigFile()

        /// 环境变量优先于配置文件。
        func value(_ key: String, _ fallback: String) -> String {
            if let v = env[key], !v.isEmpty { return v }
            if let v = fileValues[key], !v.isEmpty { return v }
            return fallback
        }
        func intValue(_ key: String, _ fallback: Int) -> Int {
            Int(value(key, String(fallback))) ?? fallback
        }
        func doubleValue(_ key: String, _ fallback: Double) -> Double {
            Double(value(key, String(fallback))) ?? fallback
        }
        func boolValue(_ key: String, _ fallback: Bool) -> Bool {
            switch value(key, fallback ? "1" : "0").lowercased() {
            case "1", "true", "yes", "on": return true
            case "0", "false", "no", "off": return false
            default: return fallback
            }
        }

        config.port = intValue("DSH_WEB_PORT", 3080)
        config.dshBin = value("DSH_BIN", defaultDshBin())
        config.workdir = value("DSH_WORKDIR", homeDirectory)
        config.serviceReadyTimeout = doubleValue("DSH_SERVICE_TIMEOUT", 60)
        config.tokenTimeout = doubleValue("DSH_TOKEN_TIMEOUT", 20)
        config.stopTimeout = doubleValue("DSH_STOP_TIMEOUT", 10)

        let modeString = value("DSH_WINDOW_MODE", "maximized").lowercased()
        config.windowMode = (modeString == "custom") ? .custom : .maximized
        config.windowWidth = doubleValue("DSH_WINDOW_WIDTH", 1180)
        config.windowHeight = doubleValue("DSH_WINDOW_HEIGHT", 800)
        config.rememberWindowSize = boolValue("DSH_REMEMBER_WINDOW_SIZE", true)

        config.trayEnabled = boolValue("DSH_TRAY", true)
        config.openWindowOnLaunch = boolValue("DSH_OPEN_WINDOW", true)
        config.showStartupOverlay = boolValue("DSH_STARTUP_OVERLAY", true)
        config.immersiveWindow = boolValue("DSH_IMMERSIVE_WINDOW", false)
        config.pageZoom = doubleValue("DSH_PAGE_ZOOM", 1.0)

        let logDir = value("DSH_LOG_DIR", "\(homeDirectory)/Library/Logs/DSH")
        config.logDirectory = URL(fileURLWithPath: (logDir as NSString).expandingTildeInPath)

        config.forwardArgs = forwardedArgs
        return config
    }

    /// 猜一个可用的 dsh 路径：优先当前 PATH，其次常见的 nvm 安装位置。
    private static func defaultDshBin() -> String {
        let candidates = [
            "/opt/homebrew/bin/dsh",
            "/usr/local/bin/dsh",
            "\(homeDirectory)/.nvm/versions/node/v24.6.0/bin/dsh",
        ]
        for path in candidates where FileManager.default.isExecutableFile(atPath: path) {
            return path
        }
        // 扫一遍 nvm 下所有 node 版本，取第一个有 dsh 的（新版本优先）
        let nvmRoot = "\(homeDirectory)/.nvm/versions/node"
        if let versions = try? FileManager.default.contentsOfDirectory(atPath: nvmRoot) {
            for version in versions.sorted(by: >) {
                let path = "\(nvmRoot)/\(version)/bin/dsh"
                if FileManager.default.isExecutableFile(atPath: path) { return path }
            }
        }
        return "dsh"   // 交给 PATH 解析，失败时给出可读错误
    }

    /// 极简 YAML 读取：只认顶层的 `key: value`，够用且不引入依赖。
    private static func readConfigFile() -> [String: String] {
        let path = "\(homeDirectory)/.dsh/mac-launcher.yaml"
        guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { return [:] }
        var result: [String: String] = [:]
        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }
            guard let separator = line.firstIndex(of: ":") else { continue }
            let key = String(line[line.startIndex..<separator]).trimmingCharacters(in: .whitespaces)
            var raw = String(line[line.index(after: separator)...]).trimmingCharacters(in: .whitespaces)
            if let hash = raw.firstIndex(of: "#"), raw[raw.startIndex] != "\"" {
                raw = String(raw[raw.startIndex..<hash]).trimmingCharacters(in: .whitespaces)
            }
            raw = raw.trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
            if !key.isEmpty { result[key] = raw }
        }
        return result
    }
}
