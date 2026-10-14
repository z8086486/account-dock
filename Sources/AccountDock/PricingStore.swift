import Foundation
import Combine

@MainActor
final class PricingStore: ObservableObject {
    static let shared = PricingStore()
    struct Cache: Codable {
        var rates: [String: [Double]]
        var priceDate: Date?
        var krw: Double?
        var fxDate: String?
        var checkedAt: Date?
    }
    @Published private(set) var cache: Cache
    @Published private(set) var loading = false
    @Published private(set) var error: String?
    private let url: URL
    private var attempted = Date.distantPast
    init() {
        url = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Caches/app.accountdock.mac/pricing-v1.json")
        cache = (try? Data(contentsOf: url)).flatMap { try? JSONDecoder().decode(Cache.self, from: $0) }
            ?? Cache(rates: TokenPricing.rates.mapValues { $0 + [$0[0] * 2, $0[1] * 2, $0[2] * 2, $0[3] * 1.5] })
    }
    func refresh(force: Bool = false) async {
        guard !loading, Date().timeIntervalSince(attempted) >= (force ? 5 : 300),
              force || Date().timeIntervalSince(cache.checkedAt ?? .distantPast) >= 86400 else { return }
        attempted = Date(); loading = true; defer { loading = false }
        var failures: [String] = []
        async let priceData = Self.fetch("https://developers.openai.com/api/docs/pricing.md")
        async let fxData = Self.fetch("https://api.frankfurter.dev/v2/rate/usd/krw")
        do {
            let data = try await priceData
            let rates = Self.parsePrices(String(decoding: data, as: UTF8.self))
            guard !rates.isEmpty else { throw URLError(.cannotParseResponse) }
            cache.rates = rates; cache.priceDate = Date()
        } catch { failures.append("가격표") }
        do {
            let rate = try Self.parseFX(await fxData)
            cache.krw = rate.0; cache.fxDate = rate.1
        } catch { failures.append("환율") }
        error = failures.isEmpty ? nil : failures.joined(separator: "·") + " 조회 실패 · 저장된 값 사용"
        if failures.isEmpty { cache.checkedAt = Date() }
        if let data = try? JSONEncoder().encode(cache) {
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? data.write(to: url, options: .atomic)
        }
    }
    nonisolated static func fetch(_ address: String) async throws -> Data {
        var request = URLRequest(url: URL(string: address)!, timeoutInterval: 15)
        request.setValue("AccountDock/0.12", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let response = response as? HTTPURLResponse, response.statusCode == 200, data.count <= 2_000_000 else { throw URLError(.badServerResponse) }
        return data
    }
    nonisolated static func parsePrices(_ text: String) -> [String: [Double]] {
        // Fail closed if OpenAI changes the named Standard table. Never parse Batch/Fast rows.
        guard let start = text.range(of: "### Standard pricing data") else { return [:] }
        let section = text[start.upperBound...].components(separatedBy: "###").first ?? ""
        var rates: [String: [Double]] = [:]
        for line in section.components(separatedBy: .newlines) where line.hasPrefix("| gpt-") {
            let columns = line.split(separator: "|", omittingEmptySubsequences: true).map { $0.trimmingCharacters(in: .whitespaces) }
            guard columns.count == 9, columns[0].range(of: #"^gpt-[a-z0-9.-]+$"#, options: .regularExpression) != nil else { continue }
            let numbers = columns.dropFirst().compactMap { Double($0.replacingOccurrences(of: "$", with: "").replacingOccurrences(of: ",", with: "")) }
            guard numbers.count == 8, numbers.allSatisfy({ $0.isFinite && $0 >= 0 && $0 < 10000 }) else { continue }
            rates[columns[0]] = numbers
        }
        return rates
    }
    nonisolated static func parseFX(_ data: Data) throws -> (Double, String) {
        struct FX: Decodable { let base: String; let quote: String; let rate: Double; let date: String }
        let fx = try JSONDecoder().decode(FX.self, from: data)
        guard fx.base == "USD", fx.quote == "KRW", fx.rate.isFinite, fx.rate > 0, fx.rate < 100_000,
              fx.date.range(of: #"^\d{4}-\d{2}-\d{2}$"#, options: .regularExpression) != nil else { throw URLError(.cannotParseResponse) }
        return (fx.rate, fx.date)
    }
    func value(_ cost: TokenCost) -> TokenCost { cost.valued(rates: cache.rates) }
    func label(_ cost: TokenCost) -> String {
        let value = value(cost)
        guard value.tokens > 0 else { return "환산할 기록 없음" }
        let usd = value.usd.formatted(.currency(code: "USD"))
        guard let krw = cache.krw else { return usd + " · 환율 미조회" }
        return usd + " · 약 " + (value.usd * krw).formatted(.currency(code: "KRW").precision(.fractionLength(0)))
    }
}
