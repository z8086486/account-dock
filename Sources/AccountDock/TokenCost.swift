import Foundation
import SwiftUI

struct TokenCost: Codable, Sendable {
    var usd: Double = 0
    var tokens: Int64 = 0
    var basis: [String: [Int64]]?
    mutating func add(_ other: TokenCost) {
        usd += other.usd; tokens += other.tokens
        for (key, counts) in other.basis ?? [:] {
            var all = basis ?? [:]
            var sum = all[key] ?? Array(repeating: Int64(0), count: 5)
            for i in 0..<5 { sum[i] += counts[i] }
            all[key] = sum; basis = all
        }
    }
    func valued(rates: [String: [Double]]) -> TokenCost {
        guard let basis else { return self }
        var value = TokenCost()
        for (key, counts) in basis {
            let parts = key.split(separator: "|")
            guard parts.count == 2, let rates = rates[String(parts[0])], rates.count == 8, counts.count == 5 else { continue }
            let start = parts[1] == "long" ? 4 : 0
            for i in 0..<4 { value.usd += Double(counts[i]) * rates[start + i] / 1_000_000 }
            value.tokens += counts[4]
        }
        return value
    }
}

/// Standard API equivalent, not subscription charges. Rates checked 2026-10-14.
enum TokenPricing {
    static let source = URL(string: "https://developers.openai.com/api/docs/pricing")!
    static let checked = "2026-10-14"
    // USD per million: uncached input, cache read, cache write, output.
    static let rates: [String: [Double]] = [
        "gpt-6.1-sol": [2, 0.1, 2.5, 10],
        "gpt-6-astra": [10, 1, 12.5, 50],
        "gpt-6-luna": [0.1, 0.01, 0.125, 0.5],
        "gpt-5.6-sol": [4, 0.4, 5, 20],
        "gpt-5.3-codex": [1.75, 0.175, 1.75, 14]
    ]
    static func count(_ value: Any?) -> Int64? {
        guard let n = value as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID(),
              n.doubleValue.isFinite, n.doubleValue >= 0, n.doubleValue < 1e15,
              n.doubleValue.rounded(.down) == n.doubleValue else { return nil }
        return n.int64Value
    }
    static func estimate(model: String?, usage: [String: Any], expected: Int64) -> TokenCost? {
        guard let model, model.hasPrefix("gpt-"),
              let input = count(usage["input_tokens"]), let cached = count(usage["cached_input_tokens"]),
              let output = count(usage["output_tokens"]), let total = count(usage["total_tokens"]),
              total == expected, input + output == total else { return nil }
        // Missing cache-write information for models that charge it cannot be guessed.
        guard let writes = count(usage["cache_write_input_tokens"]) ?? (model == "gpt-5.3-codex" ? 0 : nil),
              cached + writes <= input else { return nil }
        let long = model != "gpt-5.3-codex" && input > 272_000
        let rate = rates[model] ?? [0, 0, 0, 0]
        let inputCost = (Double(input - cached - writes) * rate[0] + Double(cached) * rate[1] + Double(writes) * rate[2]) * (long ? 2 : 1)
        let outputCost = Double(output) * rate[3] * (long ? 1.5 : 1)
        return TokenCost(usd: (inputCost + outputCost) / 1_000_000, tokens: total, basis: [model + (long ? "|long" : "|short"): [input - cached - writes, cached, writes, output, total]])
    }
}

struct TokenCostView: View {
    let snapshot: ActivitySnapshot
    let account: String?
    @ObservedObject private var pricing = PricingStore.shared
    @State private var details = false
    var body: some View {
        let today = snapshot.cost(account: account, day: ActivitySnapshot.day(Date()))
        let total = pricing.value(snapshot.cost(account: account))
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text("API 단가 환산 · 추정").fontWeight(.medium)
                Spacer()
                Button { details.toggle() } label: { Image(systemName: "info.circle") }
                    .buttonStyle(.plain).help("단가·환율·집계 범위")
                    .popover(isPresented: $details) {
                        VStack(alignment: .leading, spacing: 10) {
                            Text("API 표준 단가 환산").fontWeight(.semibold)
                            Text("실제 청구액이 아닙니다. 모델과 입력·캐시·출력 내역이 확인된 로컬 기록만 계산합니다. Fast 모드·도구 요금·세금은 제외합니다.")
                            Text("환산된 토큰 \(total.tokens.formatted()) / 로컬 \(snapshot.tokens(account: account).formatted())")
                            if let rate = pricing.cache.krw {
                                Text("$1 = ₩\(rate.formatted()) · \(pricing.cache.fxDate ?? "")")
                            } else { Text("환율을 아직 불러오지 못했습니다.") }
                            Text("가격표 · \(pricing.cache.priceDate.map { ActivitySnapshot.day($0) } ?? TokenPricing.checked + " 앱 내장값")")
                            if let error = pricing.error { Text(error).foregroundStyle(.secondary) }
                            Button(pricing.loading ? "불러오는 중…" : "가격표·환율 새로고침") { Task { await pricing.refresh(force: true) } }
                                .disabled(pricing.loading)
                            Link("환율 출처 · Frankfurter", destination: URL(string: "https://frankfurter.dev")!)
                            Link("OpenAI 공식 가격표", destination: TokenPricing.source)
                        }.font(.system(size: 12)).padding(16).frame(width: 310)
                    }
            }
            HStack { Text("오늘"); Spacer(); Text(pricing.label(today)) }
            HStack { Text("누적"); Spacer(); Text(pricing.label(total)) }
            if total.tokens < snapshot.tokens(account: account) {
                Text("세부 내역이 확인된 토큰만 환산").font(.system(size: 10)).foregroundStyle(DockTheme.muted)
            }
        }.font(.system(size: 11)).monospacedDigit().foregroundStyle(DockTheme.muted)
        .task { await pricing.refresh() }
    }
}
