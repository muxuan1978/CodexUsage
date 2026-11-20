import SwiftUI

struct UsagePanel: View {
    @ObservedObject var app: MenuApp
    let maxBodyHeight: CGFloat
    @State private var collapsed: Set<Provider> = []
    @Environment(\.colorScheme) private var scheme

    private var mint: Color {
        scheme == .dark ? Color(red: 0.38, green: 0.90, blue: 0.69) : Color(red: 0.03, green: 0.47, blue: 0.34)
    }

    private var timeColor: Color {
        scheme == .dark ? Color(red: 0.78, green: 0.67, blue: 1) : Color(red: 0.43, green: 0.25, blue: 0.69)
    }

    private func symbol(_ provider: Provider) -> String {
        switch provider {
        case .codex: return "terminal"
        case .deepSeek: return "wallet.pass"
        case .glm: return "chart.bar"
        }
    }

    private func summary(_ provider: Provider) -> String {
        if provider == .codex {
            let windows = app.snapshot?.windows ?? []
            if let first = windows.first { return "\(first.0) \(first.1.remaining)" }
            return app.busy ? "读取中…" : "暂无用量"
        }
        let state = app.services[provider]
        if let usage = state?.usage { return usage.summary }
        if state?.failure != nil { return "查询失败" }
        return state?.request != nil ? "读取中…" : "未配置"
    }

    var body: some View {
        VStack(spacing: 0) {
            ViewThatFits(in: .vertical) {
                serviceList.fixedSize(horizontal: false, vertical: true)
                ScrollView { serviceList }.frame(height: maxBodyHeight)
            }
            .frame(maxHeight: maxBodyHeight)
            Divider()
            HStack(spacing: 14) {
                let date = updated(app.pinned)
                Text(date.map { "更新于 " + stamp($0) } ?? "等待首次更新")
                    .font(.caption).monospacedDigit().foregroundStyle(.secondary)
                Spacer()
                Button(action: app.refresh) { Image(systemName: "arrow.clockwise") }
                    .help("刷新全部服务").accessibilityLabel("刷新全部服务")
                Menu {
                    Button("DeepSeek 账户设置…") { app.configure(.deepSeek) }
                    Button("GLM 账户设置…") { app.configure(.glm) }
                    Divider()
                    Button("退出 Codex Usage", action: app.quit)
                } label: { Image(systemName: "gearshape") }
                    .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                    .help("设置").accessibilityLabel("设置")
            }
            .buttonStyle(.borderless)
            .padding(.horizontal, 18).padding(.vertical, 10)
        }
        .frame(width: 360)
        .fixedSize(horizontal: true, vertical: true)
    }

    private var serviceList: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach([app.pinned] + Provider.allCases.filter { $0 != app.pinned }, id: \.self) { provider in
                VStack(alignment: .leading, spacing: 9) {
                    HStack(spacing: 8) {
                        Button {
                            if collapsed.contains(provider) { collapsed.remove(provider) }
                            else { collapsed.insert(provider) }
                        } label: {
                            HStack(spacing: 8) {
                                Image(systemName: symbol(provider)).foregroundStyle(mint)
                                Text(provider.rawValue).font(.headline)
                                Spacer(minLength: 4)
                                if collapsed.contains(provider) {
                                    Text(summary(provider)).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                }
                                Image(systemName: collapsed.contains(provider) ? "chevron.right" : "chevron.down")
                                    .font(.caption2).foregroundStyle(.secondary)
                            }.contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityHint(collapsed.contains(provider) ? "展开卡片" : "收起卡片")
                        Button { app.pin(provider) } label: {
                            Image(systemName: provider == app.pinned ? "pin.fill" : "pin")
                                .font(.caption).frame(width: 22, height: 22)
                        }
                        .buttonStyle(.plain).foregroundStyle(.secondary)
                        .disabled(provider == app.pinned)
                        .accessibilityLabel("固定 " + provider.rawValue)
                        .help(provider == app.pinned ? "已固定到菜单栏" : "固定到菜单栏")
                    }
                    if !collapsed.contains(provider) { details(provider) }
                    else if let message = failure(provider) { failureNote(provider, message) }
                }
                .padding(.horizontal, 14).padding(.vertical, 10)
                .background(provider == app.pinned ? mint.opacity(0.075) : Color.primary.opacity(0.035),
                            in: RoundedRectangle(cornerRadius: 12))
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func failure(_ provider: Provider) -> String? {
        provider == .codex ? app.failure : app.services[provider]?.failure
    }

    private func updated(_ provider: Provider) -> Date? {
        provider == .codex ? app.updated : app.services[provider]?.updated
    }

    private func failureNote(_ provider: Provider, _ message: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Label(message, systemImage: "exclamationmark.circle").foregroundStyle(.orange)
            if let date = updated(provider) { Text("上次成功　" + stamp(date)).foregroundStyle(.secondary) }
        }.font(.caption).fixedSize(horizontal: false, vertical: true)
    }

    private func progressBar(_ fraction: Double, color: Color) -> some View {
        GeometryReader { track in
            Capsule().fill(Color.secondary.opacity(0.16)).overlay(alignment: .leading) {
                Capsule().fill(color).frame(width: track.size.width * fraction)
            }
        }.frame(height: 4).accessibilityHidden(true)
    }

    private func meter(_ label: String, _ window: Window, missingReset: ModelAllowance.MissingReset? = nil) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
                Text(label + "剩余").font(.callout)
                Spacer()
                Text(window.remaining).font(.system(size: 17, weight: .semibold, design: .rounded)).monospacedDigit()
            }
            progressBar(min(1, max(0, 1 - window.usedPercent / 100)), color: mint)
            if let time = window.resetsAt {
                let date = Date(timeIntervalSince1970: time)
                TimelineView(.periodic(from: .now, by: 30)) { tick in
                    let fraction = window.remainingTimeFraction(at: tick.date)
                    VStack(alignment: .leading, spacing: 4) {
                        if let fraction { progressBar(fraction, color: timeColor) }
                        HStack {
                            Group {
                                if date > tick.date {
                                    HStack(spacing: 0) { Text(date, style: .relative); Text("后恢复") }
                                } else { Text("已到预计恢复时间") }
                            }.foregroundStyle(.secondary)
                            if let fraction {
                                Spacer(minLength: 8)
                                Text("时间剩余 \(fraction.formatted(.percent.precision(.fractionLength(0))))")
                                    .monospacedDigit().foregroundStyle(timeColor)
                            }
                        }.font(.caption).help(stamp(date))
                    }
                }
            } else if let missingReset {
                progressBar(missingReset == .idle ? 1 : 0, color: timeColor)
                Text(missingReset == .idle ? "使用后开始计时" : "GLM 暂未返回恢复时间")
                    .font(.caption).foregroundStyle(timeColor)
            }
        }
    }

    @ViewBuilder private func details(_ provider: Provider) -> some View {
        if provider == .codex {
            let windows = app.snapshot?.windows ?? []
            ForEach(windows.indices, id: \.self) { index in
                let (name, window) = windows[index]
                meter(name, window)
            }
            if windows.isEmpty { Text(app.busy ? "正在读取用量…" : "用量暂不可用").foregroundStyle(.secondary) }
            Divider()
            if let count = app.snapshot?.rateLimitResetCredits?.availableCount, app.failure == nil {
                if count > 0 {
                    Button("使用 reset · 剩 \(count) 次", action: app.reset).disabled(app.busy)
                } else { Text("暂无可用 reset").font(.caption).foregroundStyle(.secondary) }
            } else { Text("可用 reset 次数待查询").font(.caption).foregroundStyle(.secondary) }
            if let (date, result) = app.lastReset {
                VStack(alignment: .leading, spacing: 3) {
                    Text("最近重置　" + stamp(date))
                    Text(result)
                }.font(.caption).foregroundStyle(.secondary)
            }
        } else if let usage = app.services[provider]?.usage {
            switch usage {
            case .balances(let balances):
                ForEach(balances.indices, id: \.self) { index in
                    let balance = balances[index]
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Text(balance.total)
                                .font(.system(size: 29, weight: .semibold, design: .rounded))
                                .monospacedDigit()
                            Text("可用余额").font(.caption).foregroundStyle(.secondary)
                        }
                        Text("充值 " + balance.symbol + balance.topped_up_balance + "　赠金 " + balance.symbol + balance.granted_balance)
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            case .allowances(let allowances):
                ForEach(allowances.indices, id: \.self) { index in
                    let allowance = allowances[index]
                    meter(allowance.label, allowance.window, missingReset: allowance.missingReset)
                }
            }
        } else if failure(provider) == nil {
            if app.services[provider]?.request != nil {
                Text("正在读取用量…").foregroundStyle(.secondary)
            } else {
                Button("配置 API Key…") { app.configure(provider) }
            }
        }
        if let message = failure(provider) { failureNote(provider, message) }
    }
}
