// Service.swift —— 后台 `dsh web` 服务的生命周期管理。
//
// 替代原 launch-dsh-web.sh 的这几段：
//   · 进程检测（lsof 查端口）        → PortProbe.isListening（进程内 socket）
//   · nohup 拉起 + pid 文件          → Process + 进程内句柄
//   · 等端口就绪（0.2s 轮询 60s）    → PortProbe.waitUntilListening
//   · tail/grep 日志取 token URL     → 直接读子进程 stdout（AuthURLParser.Scanner）
//   · dsh-web.pid / dsh-web.url      → 进程内状态 + 一份 0600 权限的缓存
//   · mkdir 启动锁 + stop/restart 标志文件 → 主线程串行状态机（同一进程内不存在并发）
import Foundation

/// 服务当前状态。
enum ServiceState: Equatable {
    case idle
    case starting
    case waitingPort
    case ready
    case failed(String)

    var isBusy: Bool {
        switch self {
        case .starting, .waitingPort: return true
        default: return false
        }
    }

    var isRunning: Bool {
        if case .ready = self { return true }
        return false
    }

    var label: String {
        switch self {
        case .idle: return "未运行"
        case .starting: return "正在启动服务…"
        case .waitingPort: return "等待服务就绪…"
        case .ready: return "运行中"
        case .failed(let reason): return "启动失败：\(reason)"
        }
    }
}

/// 服务管理错误。
enum ServiceError: LocalizedError {
    case dshBinaryNotFound(String)
    case launchFailed(String)
    case exitedEarly(String)
    case portTimeout(Int, TimeInterval)
    case tokenUnavailable(TimeInterval)
    case connectionFailed(Int)

    var errorDescription: String? {
        switch self {
        case .dshBinaryNotFound(let path):
            return "找不到可执行的 dsh（配置项 DSH_BIN 当前为 \(path)）"
        case .launchFailed(let reason):
            return "无法启动 dsh web：\(reason)"
        case .exitedEarly(let tail):
            return "dsh web 进程提前退出\(tail.isEmpty ? "" : "，最后输出：\(tail)")"
        case .portTimeout(let port, let seconds):
            return "等待端口 \(port) 就绪超时（\(Int(seconds)) 秒）"
        case .tokenUnavailable(let seconds):
            return "服务已就绪，但 \(Int(seconds)) 秒内未取到认证 URL"
        case .connectionFailed(let port):
            return "无法连接到 127.0.0.1:\(port)。请确认 dsh web 服务是否正常，然后重试。"
        }
    }
}

/// 管理 `dsh web` 子进程：启动、等待就绪、取认证地址、重启、停止。
@MainActor
final class ServiceController {

    private(set) var state: ServiceState = .idle {
        didSet { if state != oldValue { onStateChange?(state) } }
    }
    /// 本进程拉起的子进程；为 nil 表示服务不是本启动器启动的（复用已有服务）。
    private(set) var process: Process?
    /// 最近一次解析到的认证 URL（含 token，切勿打印）。
    private(set) var authenticatedURL: String?
    /// 本进程是否持有服务进程（决定退出时能否停掉它）。
    var ownsProcess: Bool { process != nil }

    var onStateChange: ((ServiceState) -> Void)?
    var onOutput: ((String) -> Void)?
    var onAuthenticatedURL: ((String) -> Void)?

    private let config: LauncherConfig
    private var scanner: AuthURLParser.Scanner
    /// 子进程退出时置位，供后台等待循环提前中断（跨线程，必须线程安全）。
    private let exitedEarly = AtomicFlag()
    /// 输出尾部若干行，出错时作为诊断信息。
    private var recentOutput: [String] = []

    init(config: LauncherConfig) {
        self.config = config
        self.scanner = AuthURLParser.Scanner(port: config.port)
        // 复用上次的认证地址：服务重启后签名密钥不变，缓存里的 token 可能仍有效，
        // 至少能省掉一次"等 stdout 打印"的时间。
        if let cached = AuthCache.read(from: config.authCachePath) {
            authenticatedURL = cached
        }
    }

    // MARK: - 状态查询

    /// 目标端口是否已有服务在监听。
    var isListening: Bool { PortProbe.isListening(port: config.port) }

    /// 当前认证 URL：优先本进程刚解析到的，其次缓存。
    var currentAuthURL: String? { authenticatedURL }

    /// 从服务日志里恢复认证 URL。
    ///
    /// 用途：应用重启后复用"上一个启动器实例留下的"服务进程时，我们手上没有它的
    /// stdout，而进程级 launch token 只在它自己的 stdout 里出现过一次。此时服务日志
    /// 里最后一次出现的认证 URL 就是当前服务的 token，用它即可免去重启服务。
    /// （cookie 通常已经够用，这一步只在前者失效时兜底。）
    func recoverTokenFromLog() -> String? {
        var attempts: [String] = []
        for path in config.authLogCandidates {
            guard let text = try? String(contentsOf: path, encoding: .utf8) else {
                attempts.append("\(path.lastPathComponent)：不存在或不可读")
                continue
            }
            guard let found = AuthURLParser.lastAuthURL(in: text, port: config.port) else {
                attempts.append("\(path.lastPathComponent)：\(text.count) 字符，无端口 \(config.port) 的认证 URL")
                continue
            }
            logInfo("已从日志恢复认证 URL（\(path.lastPathComponent)）")
            AuthCache.write(found, to: config.authCachePath)
            authenticatedURL = found
            return found
        }
        logInfo("未能在日志里找到认证 URL（\(attempts.joined(separator: "；"))）")
        return nil
    }

    // MARK: - 启动

    /// 确保服务可用。
    /// - 端口已有监听：复用，不重启（与原启动器语义一致）。
    /// - 端口空闲：拉起 `dsh web`，等端口就绪并解析认证 URL。
    func startIfNeeded() async throws {
        // 若另一条路径正在重启服务，等它做完——否则这里会看到"端口有监听"
        // 而直接返回，调用方随即加载界面，撞上一个正在被替换/尚未就绪的服务。
        var waited = 0
        while restartInFlight && waited < 400 {          // 最多等约 40 秒
            try? await Task.sleep(nanoseconds: 100_000_000)
            waited += 1
        }
        if restartInFlight {
            throw ServiceError.portTimeout(config.port, 40)
        }

        if isListening {
            logInfo("服务已在运行（端口 \(config.port) 有监听），复用现有进程")
            state = .ready
            return
        }
        try await launch()
    }

    private func launch() async throws {
        let binary = config.dshBin
        guard FileManager.default.isExecutableFile(atPath: binary) else {
            state = .failed("找不到 dsh")
            throw ServiceError.dshBinaryNotFound(binary)
        }

        state = .starting
        exitedEarly.value = false
        recentOutput = []
        scanner = AuthURLParser.Scanner(port: config.port)

        let task = Process()
        task.executableURL = URL(fileURLWithPath: binary)
        task.arguments = ["web", "--port", String(config.port), "--no-open"] + config.forwardArgs
        task.currentDirectoryURL = URL(fileURLWithPath: config.workdir)
        task.environment = Self.childEnvironment(binaryPath: binary)

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        task.standardOutput = stdoutPipe
        task.standardError = stderrPipe

        // 子进程输出：一边写服务日志，一边做 token 增量解析
        for pipe in [stdoutPipe, stderrPipe] {
            pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
                let data = handle.availableData
                guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return }
                ServiceLogWriter.shared.append(text)
                Task { @MainActor [weak self] in
                    self?.ingest(text)
                }
            }
        }

        task.terminationHandler = { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.exitedEarly.value = true
            }
        }

        do {
            try task.run()
        } catch {
            state = .failed(error.localizedDescription)
            throw ServiceError.launchFailed(error.localizedDescription)
        }
        process = task
        recordServiceProcess(pid: task.processIdentifier)
        logInfo("已拉起 dsh web（pid=\(task.processIdentifier)，port=\(config.port)，cwd=\(config.workdir)）")
        if !config.forwardArgs.isEmpty {
            logInfo("透传给 dsh web 的参数：\(config.forwardArgs.joined(separator: " "))")
        }

        // 阶段一：等端口就绪
        state = .waitingPort
        let ready = await waitForPort()
        guard ready else {
            if exitedEarly.value {
                let tail = recentOutput.suffix(3).joined(separator: " / ")
                state = .failed("dsh web 提前退出")
                throw ServiceError.exitedEarly(tail)
            }
            state = .failed("端口未就绪")
            throw ServiceError.portTimeout(config.port, config.serviceReadyTimeout)
        }
        logInfo("服务就绪：http://127.0.0.1:\(config.port)/")

        // 阶段二：取认证 URL（若已有缓存则不等）
        if authenticatedURL != nil {
            state = .ready
            return
        }
        do {
            try await waitForAuthURL()
        } catch {
            // 拿不到 token URL 不算致命：加载根地址，若 cookie 还有效照样能进；
            // 真失效时会看到认证墙，窗口层会重试一次。
            logInfo("未取到认证 URL，退回根地址（若 cookie 有效仍可正常进入）")
        }
        state = .ready
    }

    /// 在后台线程做阻塞轮询，避免卡住主线程。
    private func waitForPort() async -> Bool {
        let port = config.port
        let timeout = config.serviceReadyTimeout
        // 只读取线程安全标志：绝不能在这里断言自己在主 actor 上——
        // 这个闭包跑在后台队列，assumeIsolated 会直接触发 dispatch 断言并崩溃。
        let flag = exitedEarly
        let isAlive: @Sendable () -> Bool = { !flag.value }
        return await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let ok = PortProbe.waitUntilListening(port: port, timeout: timeout, isAlive: isAlive)
                continuation.resume(returning: ok)
            }
        }
    }

    /// 轮询等待 token URL 出现（输出驱动：解析由 ingest 完成）。
    private func waitForAuthURL() async throws {
        let deadline = Date().addingTimeInterval(config.tokenTimeout)
        while Date() < deadline {
            if let url = authenticatedURL {
                AuthCache.write(url, to: config.authCachePath)
                onAuthenticatedURL?(url)
                return
            }
            if exitedEarly.value { throw ServiceError.exitedEarly("") }
            try? await Task.sleep(nanoseconds: 150_000_000)
        }
        throw ServiceError.tokenUnavailable(config.tokenTimeout)
    }

    // MARK: - 输出与 token 解析

    private func ingest(_ text: String) {
        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            recentOutput.append(String(line))
            if recentOutput.count > 20 { recentOutput.removeFirst() }
        }
        onOutput?(text)
        if authenticatedURL == nil, let found = scanner.feed(text) {
            authenticatedURL = found
            logInfo("已解析到认证 URL（已缓存到 \(config.authCachePath.lastPathComponent)，权限 0600）")
        }
    }

    // MARK: - 重启 / 停止

    /// 是否正在重启（供并发调用方等待，见 startIfNeeded）。
    private var restartInFlight = false

    /// 重启服务：停掉 → 重新拉起 → 等就绪。用于改了配置、或服务状态异常时。
    ///
    /// 重启期间对外的语义是"忙"：`startIfNeeded()` 会等它结束再返回，
    /// 免得并发进来的启动流程以为服务已就绪、抢先去加载一个还没起来的服务。
    func restart() async throws {
        restartInFlight = true
        defer { restartInFlight = false }
        logInfo("重启服务：停止 → 拉起")
        await stop()
        // 等端口真正释放，否则紧接着的启动会以为服务还在而直接复用
        let deadline = Date().addingTimeInterval(config.stopTimeout)
        while Date() < deadline, isListening {
            try? await Task.sleep(nanoseconds: 200_000_000)
        }
        if isListening {
            logInfo("警告：端口 \(config.port) 在 \(Int(config.stopTimeout)) 秒后仍被占用")
        }
        // 清掉上一轮的认证地址：新进程的 launch token 与旧的不同，
        // 留着只会让 loadHome 拿到一个必然失效的地址。
        authenticatedURL = nil
        AuthCache.clear(config.authCachePath)
        try await launch()
    }

    /// 停止服务。只对自己拉起的进程动手；别人启动的服务不碰。
    func stop() async {
        guard let task = process else {
            logInfo("服务不是本启动器启动的，跳过停止（避免误杀他用进程）")
            state = .idle
            return
        }
        guard task.isRunning else {
            logInfo("服务进程已退出")
            cleanupPipes()
            process = nil
            state = .idle
            return
        }
        let pid = task.processIdentifier
        logInfo("停止服务（pid=\(pid)）")
        task.terminate()   // SIGTERM，让 dsh 有机会清理
        // 宽限期内等它自己退出；超时就升级为 SIGKILL。
        // 实测 dsh web 在 SIGTERM 后可能因为活跃连接而迟迟不退，
        // 不升级的话「退出 DSH」会留下一个仍在监听的后台进程。
        var deadline = Date().addingTimeInterval(3.0)
        while Date() < deadline, task.isRunning {
            try? await Task.sleep(nanoseconds: 150_000_000)
        }
        if task.isRunning {
            logInfo("SIGTERM 后 3 秒仍未退出，发送 SIGKILL")
            kill(pid, SIGKILL)
            deadline = Date().addingTimeInterval(2.0)
            while Date() < deadline, task.isRunning {
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
        }
        if task.isRunning {
            logInfo("警告：服务进程仍未退出（pid=\(pid)）")
        }
        cleanupPipes()
        process = nil
        AuthCache.clear(config.authCachePath)
        try? FileManager.default.removeItem(at: config.serviceStatePath)
        authenticatedURL = nil
        state = .idle
        logInfo("服务已停止")
    }

    // MARK: - 服务进程归属（识别自己留下的服务）

    private struct ServiceRecord: Codable {
        var pid: Int32
        var port: Int
        var startedAt: Date
    }

    /// 记下本启动器拉起的服务进程，供下次启动时识别。
    private func recordServiceProcess(pid: Int32) {
        let record = ServiceRecord(pid: pid, port: config.port, startedAt: Date())
        guard let data = try? JSONEncoder().encode(record) else { return }
        try? data.write(to: config.serviceStatePath)
    }

    /// 读取记录（跨启动持久）。
    private func loadServiceRecord() -> ServiceRecord? {
        guard let data = try? Data(contentsOf: config.serviceStatePath),
              let record = try? JSONDecoder().decode(ServiceRecord.self, from: data) else { return nil }
        return record
    }

    /// 端口上那个服务，是不是"本启动器此前拉起、后来变成孤儿"的进程？
    ///
    /// 判断依据有两条且都必须满足：
    ///   1. 记录的 pid 仍然活着；
    ///   2. 它确实在监听我们的端口。
    /// 这样既能认出自己的孤儿服务（可以安全接管），又不会把终端里手工启动的服务认作自己的。
    func isOurOrphanedService() -> Bool {
        guard let record = loadServiceRecord(), record.port == config.port else { return false }
        guard kill(record.pid, 0) == 0 || errno == EPERM else {
            logInfo("历史服务进程 pid=\(record.pid) 已不存在")
            return false
        }
        let listeners = Self.listeningPIDs(port: config.port)
        let isMine = listeners.contains(record.pid)
        logInfo("端口 \(config.port) 的监听者=\(listeners.map(String.init).joined(separator: ","))；历史记录 pid=\(record.pid)；判定=\(isMine ? "本启动器此前拉起" : "不是本启动器的")")
        return isMine
    }

    /// 端口上有哪些 pid 在 LISTEN（用 lsof；读不到就退回"记录 pid 存活即认为相关"）。
    private static func listeningPIDs(port: Int) -> [Int32] {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/sbin/lsof")
        task.arguments = ["-nP", "-iTCP:\(port)", "-sTCP:LISTEN", "-t"]
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = Pipe()
        do { try task.run() } catch { return [] }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        task.waitUntilExit()
        guard let text = String(data: data, encoding: .utf8) else { return [] }
        return text.split(whereSeparator: { $0 == "\n" || $0 == " " })
            .compactMap { Int32($0.trimmingCharacters(in: .whitespaces)) }
    }

    /// 接管"本启动器此前拉起、现已成孤儿"的服务：结束它，再由本进程重新拉起。
    /// 只应在 isOurOrphanedService() 为真时调用。
    func takeOverOrphanedService() async throws {
        guard let record = loadServiceRecord(), record.port == config.port else { return }
        logInfo("接管遗留服务（pid=\(record.pid)）：结束它并重新拉起一个有认证地址的")
        kill(record.pid, SIGTERM)
        var deadline = Date().addingTimeInterval(3)
        while Date() < deadline, kill(record.pid, 0) == 0 {
            try? await Task.sleep(nanoseconds: 150_000_000)
        }
        if kill(record.pid, 0) == 0 {
            logInfo("遗留服务未响应 SIGTERM，发送 SIGKILL")
            kill(record.pid, SIGKILL)
        }
        deadline = Date().addingTimeInterval(5)
        while Date() < deadline, isListening {
            try? await Task.sleep(nanoseconds: 200_000_000)
        }
        authenticatedURL = nil
        AuthCache.clear(config.authCachePath)
        try await launch()
    }

    private func cleanupPipes() {
        for pipe in [process?.standardOutput as? Pipe, process?.standardError as? Pipe] {
            pipe?.fileHandleForReading.readabilityHandler = nil
        }
    }

    // MARK: - 环境

    /// 给子进程的 PATH：Finder/Dock 启动的进程 PATH 极简，必须补上 nvm 的 node/dsh。
    private static func childEnvironment(binaryPath: String) -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        let binaryDir = (binaryPath as NSString).deletingLastPathComponent
        let nvmBin = "\(NSHomeDirectory())/.nvm/versions/node"
        var paths = [binaryDir, "/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin", "/usr/sbin", "/sbin"]
        if let versions = try? FileManager.default.contentsOfDirectory(atPath: nvmBin) {
            for version in versions.sorted(by: >) {
                paths.append("\(nvmBin)/\(version)/bin")
            }
        }
        if let existing = env["PATH"], !existing.isEmpty { paths.append(existing) }
        env["PATH"] = paths.joined(separator: ":")
        env["HOME"] = NSHomeDirectory()
        return env
    }

    /// 服务输出追加写入服务日志。
    final class ServiceLogWriter: @unchecked Sendable {
        static let shared = ServiceLogWriter()
        private let queue = DispatchQueue(label: "dsh.launcher.service.log")
        private var path: URL?

        func configure(_ url: URL) { path = url }

        func append(_ text: String) {
            queue.async { [weak self] in
                guard let self, let path = self.path else { return }
                // 服务输出里可能带认证 URL，落盘前脱敏
                let safe = Log.redact(text)
                guard let data = safe.data(using: .utf8) else { return }
                if let handle = try? FileHandle(forWritingTo: path) {
                    defer { try? handle.close() }
                    _ = try? handle.seekToEnd()
                    try? handle.write(contentsOf: data)
                } else {
                    try? data.write(to: path)
                }
            }
        }
    }
}
