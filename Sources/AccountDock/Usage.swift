import SwiftUI

struct UsageWindow: Decodable, Identifiable, Sendable {
    let id: String
    let bucket: String
    let usedPercent: Double
    let remainingPercent: Double
    let windowMinutes: Double?
    let resetsAt: Double?
    var title: String {
        guard let minutes = windowMinutes else { return bucket }
        if minutes >= 1440 { return "\(Int(minutes / 1440))일 한도 · \(bucket)" }
        if minutes >= 60 { return "\(Int(minutes / 60))시간 한도 · \(bucket)" }
        return "\(Int(minutes))분 한도 · \(bucket)"
    }
}
struct CreditBalance: Decodable, Identifiable, Sendable {
    let id: String
    let bucket: String
    let status: String
    let balance: String?
    var label: String {
        switch status {
        case "unlimited": return "무제한"
        case "balance": return balance.map { "\($0) 크레딧" } ?? "잔액 미제공"
        case "empty": return "남은 크레딧 없음"
        case "available": return "크레딧 있음 · 잔액 미제공"
        default: return "잔액 미제공"
        }
    }
}
struct UsageReport: Decodable, Sendable {
    let status: String
    let windows: [UsageWindow]
    let activity: [String: Double]
    var credits: [CreditBalance]? = nil
    var resetCredits: Int? = nil
    let checkedAt: Double?
}

@MainActor
enum UsageReader {
    static func read(_ credential: Data) async throws -> UsageReport {
        let empty = UsageReport(status: "unavailable", windows: [], activity: [:], checkedAt: nil)
        guard let json = try JSONSerialization.jsonObject(with: credential) as? [String: Any],
              let tokens = json["tokens"] as? [String: Any],
              let token = tokens["access_token"] as? String, let account = tokens["account_id"] as? String else { return empty }
        if let expiry = CodexService.claims(token)["exp"] as? Double, expiry < Date().timeIntervalSince1970 + 30 {
            return UsageReport(status: "login_required", windows: [], activity: [:], checkedAt: nil)
        }
        let home = try CodexService.temporaryHome()
        let connection: CodexConnection
        do { connection = try CodexConnection(binary: CodexService.binary(), home: home, ephemeral: true) }
        catch { try? FileManager.default.removeItem(at: home); throw error }
        var requiresLogin = false
        connection.serverRequest = { method in
            if method == "account/chatgptAuthTokens/refresh" { requiresLogin = true; connection.close() }
        }
        let result: UsageReport
        do {
            try await connection.initialize()
            _ = try await connection.request("account/login/start", params: ["type": "chatgptAuthTokens", "accessToken": token, "chatgptAccountId": account])
            let limits = try? await connection.request("account/rateLimits/read")
            let activity = connection.isClosed ? nil : try? await connection.request("account/usage/read")
            result = normalize(limits: limits, activity: activity, requiresLogin: requiresLogin)
        } catch {
            result = UsageReport(status: requiresLogin ? "login_required" : "unavailable", windows: [], activity: [:], checkedAt: nil)
        }
        await connection.shutdown()
        try? FileManager.default.removeItem(at: home)
        return result
    }
    static func normalize(limits: [String: Any]?, activity: [String: Any]?, requiresLogin: Bool = false) -> UsageReport {
        if requiresLogin { return UsageReport(status: "login_required", windows: [], activity: [:], checkedAt: nil) }
        var groups = limits?["rateLimitsByLimitId"] as? [String: [String: Any]] ?? [:]
        if let single = limits?["rateLimits"] as? [String: Any] {
            let key = single["limitId"] as? String ?? "codex"
            groups[key] = single.merging(groups[key] ?? [:]) { old, new in new is NSNull ? old : new }
        }
        var windows: [UsageWindow] = [], credits: [CreditBalance] = []
        for key in groups.keys.sorted() {
            let group = groups[key]!
            let bucket = group["limitName"] as? String ?? key
            for role in ["primary", "secondary"] {
                if let value = group[role] as? [String: Any], let used = number(value["usedPercent"]) {
                    windows.append(UsageWindow(id: key + ":" + role, bucket: bucket, usedPercent: min(100, max(0, used)),
                        remainingPercent: 100 - min(100, max(0, used)), windowMinutes: number(value["windowDurationMins"]).flatMap { $0 > 0 && $0 < 10_000_000 ? $0 : nil },
                        resetsAt: number(value["resetsAt"]).flatMap { $0 > 0 && $0 < 100_000_000_000 ? $0 : nil }))
                }
            }
            if let value = group["credits"] as? [String: Any] {
                let raw = value["balance"] as? String
                let balance = raw.flatMap { text -> String? in
                    guard text.count <= 40, text.range(of: #"^\d{1,19}(?:\.\d{1,8})?$"#, options: .regularExpression) != nil else { return nil }
                    return text
                }
                let status = (value["unlimited"] as? Bool == true) ? "unlimited" : balance != nil ? "balance" :
                    (value["hasCredits"] as? Bool == false) ? "empty" : (value["hasCredits"] as? Bool == true) ? "available" : "unknown"
                credits.append(CreditBalance(id: key, bucket: bucket, status: status, balance: balance))
            }
        }
        let reset = (limits?["rateLimitResetCredits"] as? [String: Any])?["availableCount"]
        let count = number(reset).flatMap { $0 >= 0 && $0 <= 1_000_000 && $0.rounded() == $0 ? Int($0) : nil }
        var totals: [String: Double] = [:]
        let summary = activity?["summary"] as? [String: Any] ?? [:]
        for key in ["lifetimeTokens", "peakDailyTokens"] {
            if let value = number(summary[key]), value >= 0 { totals[key] = value }
        }
        let hasData = !windows.isEmpty || !credits.isEmpty || count != nil || !totals.isEmpty
        return UsageReport(status: hasData ? (limits != nil && activity != nil ? "available" : "partial") : "unavailable",
            windows: windows, activity: totals, credits: credits, resetCredits: count, checkedAt: Date().timeIntervalSince1970)
    }
    private static func number(_ value: Any?) -> Double? {
        guard let value = value as? NSNumber, CFGetTypeID(value) != CFBooleanGetTypeID(), value.doubleValue.isFinite else { return nil }
        return value.doubleValue
    }
}

struct AccountUsageView: View {
    let report: UsageReport?
    let loading: Bool
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if loading {
                HStack(spacing: 8) { ProgressView().controlSize(.small); Text("사용량 확인 중…") }
                    .font(.system(size: 11)).foregroundStyle(DockTheme.muted)
            } else if let report {
                if report.status == "login_required" {
                    Label("사용량 조회를 위해 이 계정으로 다시 로그인해 주세요.", systemImage: "lock.rotation")
                        .font(.system(size: 11)).foregroundStyle(DockTheme.muted)
                } else if report.windows.isEmpty && report.activity.isEmpty && (report.credits ?? []).isEmpty && report.resetCredits == nil {
                    Text("사용량 정보를 제공받지 못했습니다. 잠시 후 다시 확인해 주세요.")
                        .font(.system(size: 11)).foregroundStyle(DockTheme.muted)
                }
                ForEach(report.windows) { window in
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text(window.title).font(.system(size: 11))
                            Spacer()
                            Text("\(window.remainingPercent, specifier: "%.0f")% 남음")
                                .font(.system(size: 12, weight: .semibold, design: .monospaced))
                        }
                        GeometryReader { geo in
                            ZStack(alignment: .leading) {
                                Capsule().fill(DockTheme.navy.opacity(0.07))
                                Capsule().fill(window.remainingPercent <= 20 ? DockTheme.orange : DockTheme.blue)
                                    .frame(width: geo.size.width * min(100, max(0, window.remainingPercent)) / 100)
                            }
                        }.frame(height: 6)
                        if let reset = window.resetsAt {
                            Text("초기화 · \(Date(timeIntervalSince1970: reset).formatted(date: .abbreviated, time: .shortened))")
                                .font(.system(size: 10)).foregroundStyle(DockTheme.muted)
                        }
                    }
                }
                ForEach(report.credits ?? []) { credit in
                    HStack {
                        Label("크레딧 · \(credit.bucket)", systemImage: "circle.hexagongrid")
                        Spacer()
                        Text(credit.label).fontWeight(.semibold)
                    }.font(.system(size: 12)).padding(12)
                        .background(DockTheme.blue.opacity(0.18), in: RoundedRectangle(cornerRadius: 9))
                }
                if let count = report.resetCredits {
                    HStack { Text("한도 초기화 보상"); Spacer(); Text("\(count)회 남음") }
                        .font(.system(size: 11)).foregroundStyle(DockTheme.muted)
                }
                if (report.credits ?? []).isEmpty && ["available", "partial"].contains(report.status) {
                    Text("크레딧 잔액 · 확인할 수 없음")
                        .font(.system(size: 10)).foregroundStyle(DockTheme.muted)
                }
                if let lifetime = report.activity["lifetimeTokens"] {
                    Text("누적 사용 토큰 · \(lifetime.formatted(.number.precision(.fractionLength(0))))")
                        .font(.system(size: 11)).foregroundStyle(DockTheme.muted)
                }
                if let checked = report.checkedAt {
                    Text("확인 · \(Date(timeIntervalSince1970: checked).formatted(date: .omitted, time: .shortened)) · Codex 기준")
                        .font(.system(size: 9)).foregroundStyle(DockTheme.muted)
                }
            } else {
                Text("사용량을 아직 확인하지 않았습니다.").font(.system(size: 11)).foregroundStyle(DockTheme.muted)
            }
        }
    }
}

@MainActor
enum UsageBatch {
    static func read(_ accounts: [AccountPreset], limit: Int = 4,
                     reader: @escaping @MainActor @Sendable (Data) async throws -> UsageReport = UsageReader.read,
                     receive: @MainActor (String, UsageReport) -> Void) async {
        await withTaskGroup(of: (String, UsageReport).self) { group in
            var next = 0
            let fetch: @Sendable (AccountPreset) async -> (String, UsageReport) = { account in
                let report: UsageReport
                do { report = try await reader(account.credential) }
                catch { report = UsageReport(status: "unavailable", windows: [], activity: [:], checkedAt: nil) }
                return (account.id, report)
            }
            while next < min(max(1, limit), accounts.count) {
                let account = accounts[next]
                group.addTask { await fetch(account) }
                next += 1
            }
            while let (id, report) = await group.next() {
                if Task.isCancelled { group.cancelAll(); break }
                receive(id, report)
                if next < accounts.count {
                    let account = accounts[next]
                    group.addTask { await fetch(account) }
                    next += 1
                }
            }
        }
    }
}
