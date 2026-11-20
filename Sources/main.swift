import AppKit
import SwiftUI

private let timestampFormatter: DateFormatter = {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.calendar = Calendar(identifier: .gregorian)
    formatter.timeZone = .autoupdatingCurrent
    formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
    return formatter
}()

func stamp(_ date: Date) -> String {
    timestampFormatter.string(from: date)
}

final class MenuApp: NSObject, NSApplicationDelegate, ObservableObject {
    private var item: NSStatusItem!
    private let popover = NSPopover()
    private(set) var snapshot: Snapshot?
    private(set) var updated: Date?
    private(set) var failure: String?
    private(set) var busy = false
    private var timer: Timer?
    struct ServiceState {
        var usage: ProviderUsage?
        var updated: Date?
        var failure: String?
        var request: UUID?
    }
    private(set) var services: [Provider: ServiceState] = [:]
    private(set) var pinned = UserDefaults.standard.string(forKey: "pinnedProvider").flatMap(Provider.init(rawValue:)) ?? .codex
    private let historyKey = "lastResetAttempt"

    func applicationDidFinishLaunching(_ notification: Notification) {
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let url = Bundle.main.url(forResource: "CodexUsage", withExtension: "icns"),
           let icon = NSImage(contentsOf: url), let button = item.button {
            icon.size = NSSize(width: 18, height: 18)
            button.image = icon
            button.imagePosition = .imageLeading
            button.setAccessibilityLabel("Codex Usage")
        }
        let edit = NSMenu(title: "编辑")
        edit.addItem(withTitle: "粘贴", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "全选", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        let mainMenu = NSMenu()
        let editItem = NSMenuItem(title: "编辑", action: nil, keyEquivalent: "")
        editItem.submenu = edit
        mainMenu.addItem(editItem)
        NSApp.mainMenu = mainMenu
        item.button?.target = self
        item.button?.action = #selector(togglePanel)
        popover.behavior = .transient
        refresh()
        let timer = Timer(timeInterval: 60, repeats: true) { [weak self] _ in self?.refresh() }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    @objc private func togglePanel() {
        guard let button = item.button else { return }
        if popover.isShown {
            popover.performClose(nil)
        } else {
            let available = button.window?.screen?.visibleFrame.height ?? 720
            let host = NSHostingController(rootView: UsagePanel(app: self, maxBodyHeight: min(620, available - 100)))
            host.sizingOptions = [.preferredContentSize]
            popover.contentViewController = host
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            popover.contentViewController?.view.window?.makeKey()
        }
    }

    var lastReset: (Date, String)? {
        guard let record = UserDefaults.standard.dictionary(forKey: historyKey),
              let date = record["time"] as? Date, let result = record["result"] as? String else { return nil }
        return (date, result)
    }

    private func render() {
        objectWillChange.send()
        let windows = snapshot?.windows ?? []
        let remaining = windows.map { "\($0.0) \($0.1.remaining)" }.joined(separator: " · ")
        item.button?.title = (remaining.isEmpty ? (busy ? "…" : "—") : remaining) + (failure != nil && !windows.isEmpty ? " ⟳" : "")
        item.button?.toolTip = "Codex 剩余用量" + (failure == nil ? "" : "（刷新失败）")
        if pinned != .codex {
            let state = services[pinned] ?? ServiceState()
            let value = state.usage?.summary ?? (state.request != nil ? "…" : "—")
            item.button?.title = value + (state.failure != nil ? " ⟳" : "")
            item.button?.toolTip = pinned.rawValue + "　" + (state.failure ?? value)
        }
    }

    func pin(_ provider: Provider) {
        pinned = provider
        UserDefaults.standard.set(provider.rawValue, forKey: "pinnedProvider")
        render()
    }

    func configure(_ provider: Provider) {
        popover.performClose(nil)
        let name = provider.rawValue
        NSApp.activate(ignoringOtherApps: true)
        let dialog = NSAlert()
        dialog.messageText = name + " 账户设置"
        dialog.informativeText = "输入 API Key 后存入本机钥匙串。"
        let field = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 310, height: 24))
        field.placeholderString = "API Key"
        let region = NSPopUpButton(frame: NSRect(x: 0, y: 32, width: 310, height: 26))
        region.addItems(withTitles: ["智谱国内站 · open.bigmodel.cn", "国际站 · api.z.ai"])
        let panel = NSView(frame: NSRect(x: 0, y: 0, width: 310, height: provider == .glm ? 60 : 26))
        panel.addSubview(field)
        if provider == .glm {
            if (try? Credential.load(provider))?.international == true { region.selectItem(at: 1) }
            panel.addSubview(region)
        }
        dialog.accessoryView = panel
        dialog.addButton(withTitle: "保存")
        dialog.addButton(withTitle: "取消")
        dialog.addButton(withTitle: "移除密钥")
        dialog.window.initialFirstResponder = field
        let response = dialog.runModal()
        if response == .alertSecondButtonReturn { return }
        do {
            if response == .alertFirstButtonReturn {
                let key = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !key.isEmpty, !key.contains(where: { $0.isWhitespace || $0.isNewline }) else {
                    throw Problem("请输入有效的 API Key")
                }
                try Credential.store(Credential(key: key, international: region.indexOfSelectedItem == 1), for: provider)
            } else if response == .alertThirdButtonReturn {
                try Credential.store(nil, for: provider)
            } else { return }
            services[provider] = ServiceState()
            refreshService(provider)
            render()
        } catch {
            let alert = NSAlert()
            alert.messageText = error.localizedDescription
            alert.runModal()
        }
    }

    private func refreshService(_ provider: Provider) {
        guard services[provider]?.request == nil else { return }
        let request = UUID()
        services[provider, default: ServiceState()].request = request
        Task { @MainActor in
            do {
                let usage = try await UsageService.read(provider)
                guard services[provider]?.request == request else { return }
                services[provider] = ServiceState(usage: usage, updated: usage == nil ? nil : Date())
            } catch {
                guard services[provider]?.request == request else { return }
                services[provider]?.failure = error.localizedDescription
                services[provider]?.request = nil
            }
            render()
        }
    }

    private func record(_ result: String, at date: Date) {
        UserDefaults.standard.set(["time": date, "result": result], forKey: historyKey)
    }

    func refresh() {
        refreshService(.deepSeek)
        refreshService(.glm)
        guard !busy else { render(); return }
        busy = true
        render()
        DispatchQueue.global(qos: .utility).async {
            let result = Result { try Client().read() }
            DispatchQueue.main.async {
                switch result {
                case .success(let value):
                    self.snapshot = value
                    self.updated = Date()
                    self.failure = nil
                case .failure(let error):
                    self.failure = error.localizedDescription
                }
                self.busy = false
                self.render()
            }
        }
    }

    func reset() {
        guard !busy, failure == nil, let snapshot, (snapshot.rateLimitResetCredits?.availableCount ?? 0) > 0 else { return }
        let date = Date()
        let key = UUID().uuidString
        busy = true
        record("等待结果，尚未确认", at: date)
        render()
        DispatchQueue.global(qos: .userInitiated).async {
            var sent = false
            let outcome: String
            do {
                let client = try Client()
                let latest = try client.read()
                guard latest.accountId == snapshot.accountId else { throw Problem("账户已切换") }
                guard (latest.rateLimitResetCredits?.availableCount ?? 0) > 0 else { throw Problem("当前无可确认的 reset 次数") }
                sent = true
                outcome = try client.reset(key: key)
            } catch {
                outcome = (sent ? "重置结果待确认 · " : "未提交 · ") + error.localizedDescription
            }
            DispatchQueue.main.async {
                self.record(outcome, at: date)
                self.busy = false
                self.refresh()
            }
        }
    }

    func quit() { NSApp.terminate(nil) }
}

signal(SIGPIPE, SIG_IGN)
if CommandLine.arguments.contains("--check") {
    do {
        let snapshot = try Client().read()
        print("用量周期 \(snapshot.windows.count)，可用 reset \(snapshot.rateLimitResetCredits.map { String($0.availableCount) } ?? "未知")")
    } catch {
        print("用量读取失败：\(error.localizedDescription)")
        exit(1)
    }
} else {
    let app = NSApplication.shared
    let delegate = MenuApp()
    app.delegate = delegate
    app.setActivationPolicy(.accessory)
    app.run()
}
