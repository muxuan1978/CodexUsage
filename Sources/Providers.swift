import Foundation
import Security

enum Provider: String, CaseIterable {
    case codex = "Codex"
    case deepSeek = "DeepSeek"
    case glm = "GLM Coding Plan"
}

struct Credential: Codable {
    let key: String
    let international: Bool

    private static func query(_ provider: Provider) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: "local.codex.usage-menu.accounts",
         kSecAttrAccount as String: provider.rawValue]
    }

    static func load(_ provider: Provider) throws -> Self? {
        var request = query(provider)
        request[kSecReturnData as String] = true
        var value: CFTypeRef?
        let status = SecItemCopyMatching(request as CFDictionary, &value)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = value as? Data else { throw Problem("钥匙串读取失败（\(status)）") }
        return try JSONDecoder().decode(Self.self, from: data)
    }

    static func store(_ credential: Self?, for provider: Provider) throws {
        var request = query(provider)
        let status: OSStatus
        if let credential {
            let data = try JSONEncoder().encode(credential)
            let update = SecItemUpdate(request as CFDictionary, [kSecValueData: data] as CFDictionary)
            if update == errSecItemNotFound {
                request[kSecValueData as String] = data
                request[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
                status = SecItemAdd(request as CFDictionary, nil)
            } else { status = update }
        } else {
            status = SecItemDelete(request as CFDictionary)
            if status == errSecItemNotFound { return }
        }
        guard status == errSecSuccess else { throw Problem("钥匙串更新失败（\(status)）") }
    }
}

struct Balance: Decodable {
    let currency, total_balance, granted_balance, topped_up_balance: String
    var symbol: String { currency == "CNY" ? "¥" : (currency == "USD" ? "US$" : currency + " ") }
    var total: String { symbol + total_balance }
}

struct ModelAllowance {
    enum MissingReset {
        case idle, unavailable
    }

    let label: String
    let window: Window
    let missingReset: MissingReset?
}

enum ProviderUsage {
    case balances([Balance])
    case allowances([ModelAllowance])

    var summary: String {
        switch self {
        case .balances(let balances):
            return balances.map(\.total).joined(separator: " · ")
        case .allowances(let allowances):
            return allowances.map { "\($0.label) \($0.window.remaining)" }.joined(separator: " · ")
        }
    }
}

private final class NoRedirect: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

enum UsageService {
    private static let session = URLSession(configuration: .ephemeral, delegate: NoRedirect(), delegateQueue: nil)

    static func read(_ provider: Provider) async throws -> ProviderUsage? {
        guard let credential = try Credential.load(provider) else { return nil }
        let endpoint: String
        let authorization: String
        switch provider {
        case .deepSeek:
            endpoint = "https://api.deepseek.com/user/balance"
            authorization = "Bearer " + credential.key
        case .glm:
            let host = credential.international ? "api.z.ai" : "open.bigmodel.cn"
            endpoint = "https://\(host)/api/monitor/usage/quota/limit"
            authorization = credential.key
        case .codex: throw Problem("Codex 使用本机 CLI")
        }
        var request = URLRequest(url: URL(string: endpoint)!, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 20)
        request.setValue(authorization, forHTTPHeaderField: "Authorization")
        let (data, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else {
            if status == 401 || status == 403 { throw Problem("访问被拒绝，请检查密钥和账户权限") }
            throw Problem("查询失败（HTTP \(status)）")
        }
        return try provider == .deepSeek ? balance(data) : quota(data)
    }

    static func balance(_ data: Data) throws -> ProviderUsage {
        struct Reply: Decodable {
            let balance_infos: [Balance]
        }
        let balances = try JSONDecoder().decode(Reply.self, from: data).balance_infos
        guard !balances.isEmpty else { throw Problem("账户未返回余额") }
        return .balances(balances)
    }

    static func quota(_ data: Data) throws -> ProviderUsage {
        struct Reply: Decodable {
            struct Payload: Decodable { let limits: [Limit] }
            struct Limit: Decodable {
                let type: String
                let percentage: Double?
                let currentValue: Double?
                let unit, number: Int?
                let nextResetTime: Double?
            }
            let code: Int?
            let success: Bool?
            let data: Payload?
        }
        let reply = try JSONDecoder().decode(Reply.self, from: data)
        guard reply.success != false, reply.code == nil || reply.code == 200 || reply.code == 0 else {
            throw Problem("额度查询被拒绝，请检查密钥、服务站点和套餐（\(reply.code ?? -1)）")
        }
        let units: [Int: (label: String, component: Calendar.Component)] = [
            3: ("小时", .hour), 5: ("月", .month), 6: ("周", .weekOfYear)
        ]
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        var allowances: [ModelAllowance] = []
        for limit in reply.data?.limits ?? [] {
            guard ["TOKENS_LIMIT", "CREDIT_LIMIT"].contains(limit.type),
                  let used = limit.percentage, (0...100).contains(used) else { continue }
            let unit = limit.unit.flatMap { units[$0] }
            let count = limit.number ?? (limit.unit == 3 ? 5 : nil)
            let isFiveHour = limit.unit == 3 && count == 5
            let period = unit.flatMap { unit in count.map { "\($0)\(unit.label)" } }
            let label = (limit.type == "CREDIT_LIMIT" ? "积分" : "模型") + (period ?? "")
            let reset = limit.nextResetTime.flatMap { time -> TimeInterval? in
                guard time > 0 else { return nil }
                return time >= 1e11 ? time / 1000 : time
            }
            let minutes = isFiveHour ? 300 : reset.flatMap { time -> Int? in
                guard let unit, let count, count > 0 else { return nil }
                let end = Date(timeIntervalSince1970: time)
                guard let start = calendar.date(byAdding: unit.component, value: -count, to: end) else { return nil }
                return Int(exactly: (end.timeIntervalSince(start) / 60).rounded())
            }
            let window = Window(usedPercent: used, windowDurationMins: minutes, resetsAt: reset)
            var missingReset: ModelAllowance.MissingReset?
            if isFiveHour && reset == nil {
                missingReset = used == 0 && limit.currentValue == 0 ? .idle : .unavailable
            }
            allowances.append(ModelAllowance(label: label, window: window, missingReset: missingReset))
        }
        guard !allowances.isEmpty else { throw Problem("账户未返回模型额度") }
        return .allowances(allowances)
    }
}
