import Foundation
import Darwin

struct Problem: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

struct Window: Decodable {
    let usedPercent: Double
    let windowDurationMins: Int?
    let resetsAt: TimeInterval?
    var remaining: String { "\(Int(100 - min(100, max(0, usedPercent))))%" }

    func remainingTimeFraction(at date: Date) -> Double? {
        guard let minutes = windowDurationMins, minutes > 0, let resetsAt else { return nil }
        let secondsLeft = resetsAt - date.timeIntervalSince1970
        return min(1, max(0, secondsLeft / (Double(minutes) * 60)))
    }

    func label(_ fallback: String) -> String {
        guard let minutes = windowDurationMins, minutes > 0 else { return fallback }
        if minutes % 1440 == 0 { return "\(minutes / 1440)天" }
        if minutes % 60 == 0 { return "\(minutes / 60)小时" }
        return "\(minutes)分钟"
    }
}
struct Bucket: Decodable { let primary, secondary: Window? }
struct Snapshot: Decodable {
    struct Credits: Decodable { let availableCount: Int }
    let rateLimits: Bucket
    let rateLimitsByLimitId: [String: Bucket]?
    let rateLimitResetCredits: Credits?
    let accountId: String?
    var windows: [(String, Window)] {
        let bucket = rateLimitsByLimitId?["codex"] ?? rateLimits
        return [("主周期", bucket.primary), ("次周期", bucket.secondary)].compactMap { name, window in
            window.map { ($0.label(name), $0) }
        }
    }
}

final class Client {
    private let process = Process()
    private let input = Pipe(), output = Pipe()
    private var buffer = Data()
    private var sequence = 0

    init(executable: String? = nil) throws {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        var dirs = ["\(home)/.nvmd/bin", "/opt/homebrew/bin", "/usr/local/bin", "\(home)/.local/bin", "/Applications/Codex.app/Contents/Resources"]
        dirs += (ProcessInfo.processInfo.environment["PATH"] ?? "").components(separatedBy: ":").filter { $0.hasPrefix("/") }
        guard let path = executable ?? dirs.map({ $0 + "/codex" }).first(where: FileManager.default.isExecutableFile) else {
            throw Problem("找不到 Codex CLI，请安装后刷新")
        }
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = ([URL(fileURLWithPath: path).deletingLastPathComponent().path] + dirs + ["/usr/bin", "/bin"]).joined(separator: ":")
        process.environment = env
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = ["app-server", "--listen", "stdio://"]
        process.currentDirectoryURL = URL(fileURLWithPath: "/tmp")
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        try process.run()
        do {
            _ = try call("initialize", ["clientInfo": ["name": "codex_usage_menu", "version": "1.0"], "capabilities": ["experimentalApi": true]])
            try send(["method": "initialized"])
        } catch {
            stop()
            throw error
        }
    }

    private func stop() {
        try? input.fileHandleForWriting.close()
        if process.isRunning { process.terminate() }
    }
    deinit { stop() }

    private func send(_ value: [String: Any]) throws {
        var bytes = try JSONSerialization.data(withJSONObject: value)
        bytes.append(10)
        try input.fileHandleForWriting.write(contentsOf: bytes)
    }
    private func call(_ method: String, _ params: [String: Any]) throws -> Data {
        sequence += 1
        try send(["id": sequence, "method": method, "params": params])
        let deadline = ProcessInfo.processInfo.systemUptime + 25
        while ProcessInfo.processInfo.systemUptime < deadline {
            if let end = buffer.firstIndex(of: 10) {
                let line = buffer.prefix(upTo: end)
                buffer.removeSubrange(...end)
                guard let msg = try JSONSerialization.jsonObject(with: line) as? [String: Any],
                      msg["id"] as? Int == sequence else { continue }
                if let error = msg["error"] as? [String: Any] {
                    let message = error["message"] as? String ?? "Codex 接口出错"
                    throw Problem(String(message.prefix(200)))
                }
                guard let result = msg["result"], JSONSerialization.isValidJSONObject(result) else { throw Problem("Codex 响应格式异常") }
                return try JSONSerialization.data(withJSONObject: result)
            }
            var fd = pollfd(fd: output.fileHandleForReading.fileDescriptor, events: Int16(POLLIN), revents: 0)
            let ready = poll(&fd, 1, 500)
            if ready < 0 && errno != EINTR { throw Problem("无法读取 Codex 响应") }
            guard ready > 0 else { continue }
            var chunk = [UInt8](repeating: 0, count: 8192)
            let count = Darwin.read(fd.fd, &chunk, chunk.count)
            if count < 0 && errno == EINTR { continue }
            guard count > 0 else { throw Problem("Codex 连接结束，请检查 CLI 和登录状态") }
            buffer.append(contentsOf: chunk.prefix(count))
            guard buffer.count <= 4_194_304 else { throw Problem("Codex 响应过大") }
        }
        throw Problem("Codex 响应超时")
    }

    func read() throws -> Snapshot {
        try JSONDecoder().decode(Snapshot.self, from: call("account/rateLimits/read", ["excludeResetCreditDetails": true]))
    }
    func reset(key: String) throws -> String {
        struct Reply: Decodable { let outcome: String }
        let data = try call("account/rateLimitResetCredit/consume", ["idempotencyKey": key])
        switch try JSONDecoder().decode(Reply.self, from: data).outcome {
        case "reset": return "重置成功"
        case "nothingToReset": return "当前无需重置"
        case "noCredit": return "没有可用 reset"
        case "alreadyRedeemed": return "该 reset 已兑换"
        default: return "服务端返回未知结果"
        }
    }
}
