// Config.swift —— 启动器配置。
//
// 目的：对齐原 dsh-launcher 的全部可配置项，同时把状态文件从仓库目录搬到
// 用户的标准位置（日志进 ~/Library/Logs/DSH，状态进 UserDefaults）。
//
// 优先级：命令行参数 > 环境变量 > 配置文件 > 内置默认值
// 环境变量名与原 launch-dsh-web.sh 完全一致，老用户的自定义无需改写。
import Foundation

/// 窗口尺寸模式。
enum WindowMode: String {
    /// 占满屏幕可用区域（默认，等价旧版的 maximized）。
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
    /// 带 token 认证 URL 的缓存（权限 0600；token 是本机凭据）。
    var authCachePath: URL { logDirectory.appendingPathComponent("auth-url") }

    /// 记录"本启动器拉起的服务进程"（pid + 启动时间）。
    /// 用途：启动器退出后服务会继续跑（这是设计），下次启动时端口被它占着，
    /// 而它的 launch token 随进程输出一起消失了 —— 靠这个文件就能认出
    /// "这是我自己留下的服务，可以放心接管"，而不会误判成别人的服务。
    var serviceStatePath: URL { logDirectory.appendingPathComponent("service-state.json") }

    /// 可能记着认证 URL 的日志文件，按"越新越优先"排列。
    /// 包含原 dsh-launcher 的 dsh-web.log：从旧启动器迁移过来时，
    /// 手上那个服务很可能是它启动的，其 token 只出现在那份日志里。
    var authLogCandidates: [URL] {
        var candidates: [URL] = [serviceLogPath]
        // 原 dsh-launcher 的日志：迁移期最常见的一种"别人的服务"
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
