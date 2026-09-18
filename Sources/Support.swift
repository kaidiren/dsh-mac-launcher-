// Support.swift —— 日志、端口探测与认证 URL 解析等基础工具。
//
// 与原方案的关键差别：这里不再有 lsof 子进程、不再有 curl 探活子进程、
// 不再有日志文件 grep 回捞 token —— 全部改成进程内的直接调用。
import Foundation
import Darwin

/// 统一日志：写文件 + 同时输出到 stderr（从终端启动时能直接看到）。
final class Log: @unchecked Sendable {
    static let shared = Log()

    private let queue = DispatchQueue(label: "dsh.launcher.log")
    private var path: URL?
    private let formatter: DateFormatter

    private init() {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        formatter = f
    }

    /// 配置日志位置（应用启动时调用一次）。
    func configure(directory: URL) {
        // 立刻建目录：错误面板里的「打开日志」在首次启动、还没写过日志时也要能打开
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        path = directory.appendingPathComponent("launcher.log")
        FileManager.default.createFile(atPath: path!.path, contents: nil)
    }

    /// 认证 URL 等本机凭据在写入任何持久化位置前先脱敏。
    static func redact(_ message: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: "token=[A-Za-z0-9_.%\\-]+") else { return message }
        let range = NSRange(message.startIndex..., in: message)
        return regex.stringByReplacingMatches(in: message, range: range, withTemplate: "token=<REDACTED>")
    }

    func write(_ message: String) {
        let line = "[\(formatter.string(from: Date()))] \(Log.redact(message))\n"
        queue.async { [weak self] in
            guard let self else { return }
            FileHandle.standardError.write(Data(line.utf8))
            guard let path = self.path else { return }
            if let handle = try? FileHandle(forWritingTo: path) {
                defer { try? handle.close() }
                _ = try? handle.seekToEnd()
                try? handle.write(contentsOf: Data(line.utf8))
            } else {
                try? Data(line.utf8).write(to: path)
            }
        }
    }
}

/// 便捷函数。
func logInfo(_ message: String) { Log.shared.write(message) }

/// 端口探测：进程内直接 connect，不 fork 任何子进程（原方案要 fork 一次 lsof）。
enum PortProbe {
    /// 目标端口是否有进程在 LISTEN。
    ///
    /// 注意：非阻塞 connect 返回 EINPROGRESS 只说明"握手进行中"，**不代表端口可达**；
    /// 必须用 select + SO_ERROR 取回真正的结果，否则会把任意端口都判成有服务。
    static func isListening(port: Int, host: String = "127.0.0.1") -> Bool {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        defer { close(fd) }

        let flags = fcntl(fd, F_GETFL, 0)
        _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK)

        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = in_port_t(UInt16(port).bigEndian)
        addr.sin_addr.s_addr = inet_addr(host)

        let result = withUnsafePointer(to: &addr) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { socketPointer in
                connect(fd, socketPointer, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        if result == 0 { return true }                 // 立即成功
        guard errno == EINPROGRESS else { return false } // 回环上多为 ECONNREFUSED

        // 等可写，再用 SO_ERROR 取回握手结果
        var writeSet = fd_set()
        withUnsafeMutablePointer(to: &writeSet) { pointer in
            pointer.withMemoryRebound(to: UInt8.self, capacity: MemoryLayout<fd_set>.size) { bytes in
                bytes.update(repeating: 0, count: MemoryLayout<fd_set>.size)
            }
        }
        let wordSize = MemoryLayout<Int32>.size * 8
        let index = Int(fd) / wordSize
        let bit = Int32(1) << Int32(Int(fd) % wordSize)
        withUnsafeMutablePointer(to: &writeSet.fds_bits) { tuplePointer in
            tuplePointer.withMemoryRebound(to: Int32.self, capacity: 32) { bits in
                bits[index] |= bit
            }
        }
        var timeout = timeval(tv_sec: 1, tv_usec: 0)
        let selected = select(fd + 1, nil, &writeSet, nil, &timeout)
        guard selected > 0 else { return false }

        var socketError: Int32 = 0
        var length = socklen_t(MemoryLayout<Int32>.size)
        guard getsockopt(fd, SOL_SOCKET, SO_ERROR, &socketError, &length) == 0 else { return false }
        return socketError == 0
    }

    /// 等待端口就绪；返回是否在超时前就绪。
    /// `isAlive` 用于提前发现子进程已退出（不必等到超时）。
    static func waitUntilListening(port: Int,
                                   timeout: TimeInterval,
                                   isAlive: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if isListening(port: port) { return true }
            if !isAlive() { return false }
            Thread.sleep(forTimeInterval: 0.10)
        }
        return isListening(port: port)
    }
}

/// 进程启动时刻（内核记录的 p_starttime）。
/// 用来把「进程启动 → main 顶层第一条语句」这段量出来：这段是 dyld 加载 + 运行时与
/// 框架（WebKit 等）初始化，睡眠唤醒后页缓存全冷时能占到好几秒 —— 它也是启动耗时里
/// 唯一无法用 Date() 直接测到的部分。
enum ProcessStart {
    static let date: Date? = {
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, getpid()]
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        guard sysctl(&mib, 4, &info, &size, nil, 0) == 0 else { return nil }
        let tv = info.kp_proc.p_starttime
        return Date(timeIntervalSince1970: Double(tv.tv_sec) + Double(tv.tv_usec) / 1_000_000)
    }()
}

/// 从 `dsh web` 的输出里解析带认证 token 的 URL。
///
/// 原方案是"tail 日志 + grep + tail -1"，且必须等日志落盘、再区分本次新增的行；
/// 这里直接读子进程的 stdout/stderr，边读边解析，拿到即用。
enum AuthURLParser {
    /// 匹配 `dsh web: http://127.0.0.1:3080/?token=...`（也容忍 LAN 地址后缀）。
    static func firstAuthURL(in text: String, port: Int) -> String? {
        let pattern = "https?://[^\\s\"']*?:\(port)/\\?token=[A-Za-z0-9_.\\-]+"
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(text.startIndex..., in: text)
        guard let match = regex.firstMatch(in: text, range: range),
              let matchRange = Range(match.range, in: text) else { return nil }
        return String(text[matchRange])
    }

    /// 取文本里**最后一次**出现的认证 URL。
    /// 日志是追加写的，最后一条对应当前正在跑的那个服务进程。
    static func lastAuthURL(in text: String, port: Int) -> String? {
        let pattern = "https?://[^\\s\"']*?:\(port)/\\?token=[A-Za-z0-9_.\\-]+"
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(text.startIndex..., in: text)
        let matches = regex.matches(in: text, range: range)
        guard let last = matches.last, let matchRange = Range(last.range, in: text) else { return nil }
        return String(text[matchRange])
    }

    /// 增量扫描器：流式喂入输出片段，命中一次后即返回（用于逐块读取管道）。
    struct Scanner {
        let port: Int
        private var buffer = ""
        private(set) var url: String?

        init(port: Int) { self.port = port }

        /// 喂入一段新输出；若已解析出 URL 则返回它。
        mutating func feed(_ chunk: String) -> String? {
            if url != nil { return url }
            buffer += chunk
            // 只保留尾部窗口，避免长跑进程无限增长
            if buffer.count > 64_000 { buffer = String(buffer.suffix(16_000)) }
            if let found = AuthURLParser.firstAuthURL(in: buffer, port: port) {
                url = found
                return found
            }
            return nil
        }
    }
}

/// 读取认证 URL 缓存（权限 0600，仅本机当前用户可读）。
enum AuthCache {
    static func read(from url: URL) -> String? {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    static func write(_ value: String, to url: URL) {
        try? value.write(to: url, atomically: true, encoding: .utf8)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    static func clear(_ url: URL) {
        try? FileManager.default.removeItem(at: url)
    }
}
