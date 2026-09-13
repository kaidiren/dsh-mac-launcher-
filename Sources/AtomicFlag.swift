// AtomicFlag.swift —— 供主线程与后台线程共享的简单布尔标志。
//
// 用途：等待端口就绪的循环跑在后台队列上，需要判断「子进程是否已退出」；
// 而子进程退出事件来自主线程。这里用一把锁把状态做成线程安全的，
// 而不是让后台线程去断言自己在主 actor 上（那会直接 trap）。
import Foundation

final class AtomicFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var stored = false

    init(_ initial: Bool = false) { stored = initial }

    var value: Bool {
        get {
            lock.lock()
            defer { lock.unlock() }
            return stored
        }
        set {
            lock.lock()
            stored = newValue
            lock.unlock()
        }
    }
}
