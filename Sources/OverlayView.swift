// OverlayView.swift —— 启动阶段的进度与错误提示。
//
// 原方案在这一段是空白的：服务冷启动约 10 秒，用户看到的只是一个白窗口
// （出错了也只能去翻 dsh-web.log）。这里给出明确的阶段文案与可操作的错误面板。
import Cocoa

@MainActor
final class OverlayView: NSView {

    private let material = NSVisualEffectView()
    private let stack = NSStackView()
    private let spinner = NSProgressIndicator()
    private let titleLabel = NSTextField(labelWithString: "")
    private let detailLabel = NSTextField(wrappingLabelWithString: "")
    /// 阶段 + 已用时间这类高频刷新的短文本
    private let subtitleLabel = NSTextField(labelWithString: "")
    private let buttonRow = NSStackView()
    private var actionButtons: [NSButton] = []

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        build()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) 未实现") }

    private func build() {
        wantsLayer = true
        layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        autoresizingMask = [.width, .height]

        material.material = .windowBackground
        material.blendingMode = .behindWindow
        material.state = .active
        material.frame = bounds
        material.autoresizingMask = [.width, .height]
        addSubview(material)

        spinner.style = .spinning
        spinner.controlSize = .regular
        spinner.isDisplayedWhenStopped = false

        titleLabel.font = .systemFont(ofSize: 15, weight: .medium)
        titleLabel.alignment = .center
        titleLabel.textColor = .labelColor

        detailLabel.font = .systemFont(ofSize: 12)
        detailLabel.alignment = .center
        detailLabel.textColor = .secondaryLabelColor
        detailLabel.isHidden = true
        detailLabel.preferredMaxLayoutWidth = 520

        subtitleLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        subtitleLabel.alignment = .center
        subtitleLabel.textColor = .tertiaryLabelColor
        subtitleLabel.isHidden = true

        buttonRow.orientation = .horizontal
        buttonRow.spacing = 8
        buttonRow.isHidden = true

        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 14
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.addArrangedSubview(spinner)
        stack.addArrangedSubview(titleLabel)
        stack.addArrangedSubview(subtitleLabel)
        stack.addArrangedSubview(detailLabel)
        stack.addArrangedSubview(buttonRow)
        addSubview(stack)

        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
            stack.widthAnchor.constraint(lessThanOrEqualToConstant: 560),
        ])
    }

    /// 显示进度状态。
    ///
    /// `detail` 是较长的说明或错误原因，`subtitle` 用来放"阶段 + 已用时间"这类
    /// 需要频繁刷新的短文本（它不会触发重新布局，也不影响标题层级）。
    func show(message: String, detail: String? = nil, subtitle: String? = nil, isError: Bool = false) {
        isHidden = false
        titleLabel.stringValue = message
        if let detail, !detail.isEmpty {
            detailLabel.stringValue = detail
            detailLabel.isHidden = false
            detailLabel.textColor = isError ? .systemRed : .secondaryLabelColor
        } else {
            detailLabel.isHidden = true
        }
        if let subtitle, !subtitle.isEmpty {
            subtitleLabel.stringValue = subtitle
            subtitleLabel.isHidden = false
        } else {
            subtitleLabel.isHidden = true
        }

        if isError {
            spinner.stopAnimation(nil)
            spinner.isHidden = true
            buildErrorButtons()
            buttonRow.isHidden = false
        } else {
            spinner.isHidden = false
            spinner.startAnimation(nil)
            clearErrorButtons()
            buttonRow.isHidden = true
        }
    }

    /// 只更新进度副标题（高频调用，避免每次都重建整个栈）。
    func updateSubtitle(_ text: String) {
        subtitleLabel.stringValue = text
        subtitleLabel.isHidden = text.isEmpty
    }

    func hide() {
        isHidden = true
        spinner.stopAnimation(nil)
        subtitleLabel.isHidden = true
    }

    // MARK: - 错误面板的操作按钮

    private func clearErrorButtons() {
        for button in actionButtons {
            buttonRow.removeArrangedSubview(button)
            button.removeFromSuperview()
        }
        actionButtons.removeAll()
    }

    private func buildErrorButtons() {
        clearErrorButtons()
        addButton("打开日志") {
            NSWorkspace.shared.open(LogDirectory.current)
        }
        addButton("复制日志路径") { [weak self] in
            guard let self else { return }
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            pasteboard.setString(LogDirectory.current.path, forType: .string)
            self.titleLabel.stringValue = "日志路径已复制"
        }
        addButton("重试") {
            NotificationCenter.default.post(name: .dshLauncherRetryRequested, object: nil)
        }
        buttonRow.isHidden = false
    }

    private func addButton(_ title: String, action: @escaping () -> Void) {
        let button = ActionButton(title: title, action: action)
        actionButtons.append(button)
        buttonRow.addArrangedSubview(button)
    }
}

/// 把闭包包成 NSButton 的动作，省掉一堆 @objc 方法。
final class ActionButton: NSButton {
    private let handler: () -> Void

    init(title: String, action: @escaping () -> Void) {
        self.handler = action
        super.init(frame: .zero)
        self.title = title
        self.bezelStyle = .rounded
        self.target = self
        self.action = #selector(invoke)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) 未实现") }

    @objc private func invoke() { handler() }
}

/// 记录当前日志目录，供错误面板使用。
enum LogDirectory {
    nonisolated(unsafe) static var current: URL = URL(fileURLWithPath: NSHomeDirectory())
        .appendingPathComponent("Library/Logs/DSH")
}

extension Notification.Name {
    static let dshLauncherRetryRequested = Notification.Name("dsh.launcher.retry")
}
