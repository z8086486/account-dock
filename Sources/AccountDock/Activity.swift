import Foundation
import Darwin

/// Only derived counters are retained. Message and tool payloads are never stored or logged.
struct LocalLimitSample: Sendable, Codable {
    let data: Data
    let date: Date
}

/// Execution metadata only. Conversation text and tool output are never retained.
struct ActiveConversation: Sendable, Identifiable, Equatable {
    let id: String
    let account: String
    var model: String?
    var effort: String?
    var serviceTier: String?
    var project: String?
    var effortLabel: String {
        switch effort?.lowercased() {
        case "none": "None"
        case "minimal": "Minimal"
        case "low": "Low"
        case "medium": "Medium"
        case "high": "High"
        case "xhigh", "extra_high", "extra high": "Extra High"
        case "max": "Max"
        case "ultra": "Ultra"
        default: "확인 안 됨"
        }
    }
    var speedLabel: String {
        switch serviceTier?.lowercased() {
        case "fast", "priority": "빠름"
        case "ultrafast": "매우 빠름"
        case "standard", "default": "일반"
        default: "확인 안 됨"
        }
    }
    /// Decorative weighting, not a throughput, billing, or token estimate.
    var animationWeight: Double {
        let reasoning: Double
        switch effort?.lowercased() {
        case "high": reasoning = 1.15
        case "xhigh", "extra_high", "extra high": reasoning = 1.3
        case "max": reasoning = 1.45
        case "ultra": reasoning = 1.6
        default: reasoning = 1
        }
        let speed: Double
        switch serviceTier?.lowercased() {
        case "fast", "priority": speed = 1.25
        case "ultrafast": speed = 1.5
        default: speed = 1
        }
        return reasoning * speed
    }
    var shortID: String { String(id.suffix(8)) }
}

struct ActivityTurnContext: Sendable, Codable, Equatable {
    var turnID: String?
    var model: String?
    var effort: String?
    var serviceTier: String?
    var project: String?
    init(_ payload: [String: Any]) {
        let settings = (payload["collaboration_mode"] as? [String: Any])?["settings"] as? [String: Any]
        turnID = (payload["turn_id"] as? String).map { String($0.prefix(100)) }
        model = (payload["model"] as? String).map { String($0.prefix(100)) }
        effort = (payload["effort"] as? String) ?? (payload["reasoning_effort"] as? String) ?? (settings?["reasoning_effort"] as? String)
        serviceTier = (payload["service_tier"] as? String) ?? (payload["serviceTier"] as? String)
        effort = effort?.lowercased()
        if !["none", "minimal", "low", "medium", "high", "xhigh", "extra_high", "extra high", "max", "ultra"].contains(effort ?? "") { effort = nil }
        serviceTier = serviceTier?.lowercased()
        if !["fast", "priority", "ultrafast", "standard", "default"].contains(serviceTier ?? "") { serviceTier = nil }
        project = (payload["cwd"] as? String).map { String(URL(fileURLWithPath: $0).lastPathComponent.prefix(100)) }
    }
}

struct ActivitySnapshot: Sendable {
    var costs: [String: [String: TokenCost]] = [:]
    var limits: [String: LocalLimitSample] = [:]
    var days: [String: [String: Int64]] = [:]
    var activeAccounts: [String: Int] = [:]
    var activeConversations: [ActiveConversation] = []
    var observedAccounts: Set<String> = []
    var active = false
    var indexing = true
    var unreadableFiles = 0
    var updatedAt: Date?
    func filtered(accounts: Set<String>) -> ActivitySnapshot {
        var result = self
        result.costs = costs.mapValues { $0.filter { accounts.contains($0.key) } }
        result.days = days.mapValues { $0.filter { accounts.contains($0.key) } }
        result.limits = limits.filter { accounts.contains($0.key) }
        result.activeAccounts = activeAccounts.filter { accounts.contains($0.key) }
        result.activeConversations = activeConversations.filter { accounts.contains($0.account) }
        result.observedAccounts = observedAccounts.intersection(accounts)
        return result
    }
    static let unknown = "__unknown__"
    var animationLoad: Double {
        guard active else { return 0 }
        let count = max(1, activeAccounts.values.reduce(0, +))
        return Double(count) + activeConversations.reduce(0) { $0 + max(0, $1.animationWeight - 1) }
    }
    func tokens(account: String? = nil, day: String? = nil) -> Int64 {
        days.filter { day == nil || $0.key == day }.values.reduce(0) { result, accounts in
            result + (account.map { accounts[$0, default: 0] } ?? accounts.values.reduce(0, +))
        }
    }
    func cost(account: String? = nil, day: String? = nil) -> TokenCost {
        var result = TokenCost()
        for (date, accounts) in costs where day == nil || day == date {
            for (id, value) in accounts where account == nil || account == id { result.add(value) }
        }
        return result
    }
    static func day(_ date: Date) -> String {
        let parts = Calendar.current.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year!, parts.month!, parts.day!)
    }
}

struct ActivityLogState: Sendable, Codable {
    var offset: UInt64 = 0
    var fileNumber: UInt64 = 0
    var pending = Data()
    var account = ActivitySnapshot.unknown
    var previousTotal: Int64 = 0
    var limit: LocalLimitSample?
    var days: [String: [String: Int64]] = [:]
    var turns: Set<String> = []
    var latest = Date.distantPast
    var oversizedLine = false
    var liveOnly = false
    var lastWork = Date.distantPast
    var lastFinish = Date.distantPast
    var attributedAccount: String?
    var attributionStart: UInt64?
    var model: String?
    var costs: [String: [String: TokenCost]]?
    var replayUntil: UInt64?
    var turnContext: ActivityTurnContext?
    var activeTurnID: String?

    mutating func observeOwner(_ owner: String?, at offset: UInt64) {
        if owner != attributedAccount {
            attributedAccount = owner
            attributionStart = owner == nil ? nil : offset
        }
    }
    mutating func consume(_ line: Data, at position: UInt64 = 0) {
        guard let object = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any],
              let payload = object["payload"] as? [String: Any] else { return }
        if object["type"] as? String == "session_meta" {
            if let id = payload["creator_account_id"] as? String, !id.isEmpty { account = id }
            return
        }
        if object["type"] as? String == "turn_context" {
            model = payload["model"] as? String
            turnContext = ActivityTurnContext(payload)
            return
        }
        guard object["type"] as? String == "event_msg", let type = payload["type"] as? String else { return }
        let stamp = object["timestamp"] as? String ?? ""
        let date = Self.parseDate(stamp)
        if let date { latest = max(latest, date) }
        if type == "token_count", let date, let rates = payload["rate_limits"] as? [String: Any],
           let data = try? JSONSerialization.data(withJSONObject: rates), date >= (limit?.date ?? .distantPast) {
            limit = LocalLimitSample(data: data, date: date)
        }
        let turn = payload["turn_id"] as? String ?? "legacy"
        if type == "task_started" { turns.insert(turn); activeTurnID = turn }
        if ["task_complete", "turn_aborted", "task_failed"].contains(type) {
            turns.remove(turn); if let date { lastFinish = max(lastFinish, date) }
            if activeTurnID == turn { activeTurnID = nil }
            if turnContext?.turnID == turn { turnContext = nil }
        }
        if type == "token_count", payload["info"] is [String: Any], let date { lastWork = max(lastWork, date) }
        guard !liveOnly else { return }
        guard type == "token_count", let info = payload["info"] as? [String: Any],
              let usage = info["total_token_usage"] as? [String: Any],
              let number = usage["total_tokens"] as? NSNumber,
              CFGetTypeID(number) != CFBooleanGetTypeID(), number.doubleValue.isFinite,
              number.doubleValue >= 0, number.doubleValue < 1e15 else { return }
        let total = number.int64Value
        // Duplicate and older cumulative events must never inflate usage.
        let firstCounter = previousTotal == 0
        var delta = max(0, total - previousTotal)
        previousTotal = max(previousTotal, total)
        guard delta > 0, let date else { return }
        let resolved = (attributionStart.map { position >= $0 } ?? false) ? (attributedAccount ?? account) : account
        let day = ActivitySnapshot.day(date)
        // A resumed log may start with a lifetime counter inherited from earlier
        // history. Only its explicit last request belongs to this event's day.
        if firstCounter, let last = info["last_token_usage"] as? [String: Any],
           let lastTotal = TokenPricing.count(last["total_tokens"]), lastTotal < total,
           let input = TokenPricing.count(last["input_tokens"]),
           let output = TokenPricing.count(last["output_tokens"]), input + output == lastTotal {
            let inherited = total - lastTotal
            delta = lastTotal
            if position < (replayUntil ?? 0) {
                // Repair the old daily bucket once while replaying metadata;
                // preserve account attribution for all subsequent events.
                let old = days[day]?[resolved] ?? 0
                days[day]?[resolved] = max(0, old - inherited)
            }
        }
        if position >= (replayUntil ?? 0) { days[day, default: [:]][resolved, default: 0] += delta }
        if let last = info["last_token_usage"] as? [String: Any],
           let cost = TokenPricing.estimate(model: model, usage: last, expected: delta) {
            var all = costs ?? [:]
            all[day, default: [:]][resolved, default: TokenCost()].add(cost)
            costs = all
        }
    }
    static func parseDate(_ text: String) -> Date? {
        // ISO8601 timestamps with and without fractional seconds; no shared mutable formatter.
        try? Date(text, strategy: .iso8601.year().month().day().dateSeparator(.dash)
            .time(includingFractionalSeconds: text.contains(".")).timeSeparator(.colon).timeZone(separator: .colon))
    }
    mutating func append(_ data: Data) {
        pending.append(data)
        let baseOffset = offset >= UInt64(pending.count) ? offset - UInt64(pending.count) : 0
        var cursor = pending.startIndex
        while let newline = pending.range(of: Data([10]), in: cursor..<pending.endIndex)?.lowerBound {
            let line = pending[cursor..<newline]
            if !oversizedLine && line.count <= 2_000_000 &&
                (line.prefix(256).range(of: Data("\"turn_context\"".utf8)) != nil || line.prefix(256).range(of: Data("\"event_msg\"".utf8)) != nil || line.prefix(256).range(of: Data("\"session_meta\"".utf8)) != nil) {
                consume(Data(line), at: baseOffset + UInt64(cursor - pending.startIndex))
            }
            oversizedLine = false
            cursor = pending.index(after: newline)
        }
        if cursor > pending.startIndex { pending.removeSubrange(pending.startIndex..<cursor) }
        if pending.count > 2_000_000 { pending.removeAll(keepingCapacity: true); oversizedLine = true }
    }
}

actor ActivityScanner {
    private var files: [URL: ActivityLogState] = [:]
    private var live: [URL: ActivityLogState] = [:]
    private struct SettingsSample {
        let turn: String?
        let checkedAt: Date
        let value: ObservedActivitySettings?
    }
    private var requestSettings: [URL: SettingsSample] = [:]
    private var discovered: [URL] = []
    private var watchedFolders: Set<URL> = []
    private let cacheURL: URL?
    private var lastSave = Date.distantPast
    private var cacheDirty = false
    private struct Cache: Codable { let version: Int; let root: String; let files: [String: ActivityLogState] }
    private var lastScan = Date.distantPast
    private var root: URL
    private let managed: URL
    init(root: URL, managed: URL, cacheURL: URL? = nil) {
        self.root = root; self.managed = managed; self.cacheURL = cacheURL
        if let cacheURL, let attrs = try? FileManager.default.attributesOfItem(atPath: cacheURL.path),
           (attrs[.size] as? NSNumber)?.intValue ?? Int.max < 20_000_000,
           let data = try? Data(contentsOf: cacheURL), let cache = try? JSONDecoder().decode(Cache.self, from: data),
           [1, 2, 3, 4].contains(cache.version), cache.root == root.path {
            files = Dictionary(uniqueKeysWithValues: cache.files.map { path, original in
                var state = original
                if cache.version < 4 {
                    state.costs = nil; state.model = nil
                    // Re-read pricing metadata while retaining previously attributed token totals.
                    state.replayUntil = max(state.replayUntil ?? 0, state.offset)
                    state.offset = 0; state.previousTotal = 0; state.pending = Data()
                    state.oversizedLine = false
                }
                return (URL(fileURLWithPath: path), state)
            })
        }
    }
    func scan(root newRoot: URL, now: Date = Date()) -> ActivitySnapshot {
        if newRoot != root { root = newRoot; lastScan = .distantPast; files = [:]; live = [:]; requestSettings = [:] }
        let fm = FileManager.default
        if now.timeIntervalSince(lastScan) >= 30 {
            var homes = [root, managed.appendingPathComponent("codex")]
            let accounts = (try? fm.contentsOfDirectory(at: managed.appendingPathComponent("accounts"), includingPropertiesForKeys: nil)) ?? []
            homes += accounts.map { $0.appendingPathComponent("codex") }
            var paths: Set<URL> = []
            var directories: Set<URL> = []
            for home in homes {
                for name in ["sessions", "archived_sessions"] {
                    let folder = home.appendingPathComponent(name).resolvingSymlinksInPath()
                    guard directories.insert(folder).inserted,
                          let enumerator = fm.enumerator(at: folder, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles]) else { continue }
                    for case let url as URL in enumerator where url.pathExtension == "jsonl" {
                        if (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true { paths.insert(url.resolvingSymlinksInPath()) }
                    }
                }
            }
            watchedFolders = directories
            discovered = paths.sorted { $0.path < $1.path }
            if files.keys.contains(where: { !paths.contains($0) }) { cacheDirty = true }
            files = files.filter { paths.contains($0.key) }
            live = live.filter { paths.contains($0.key) }
            requestSettings = requestSettings.filter { paths.contains($0.key) }
            lastScan = now
        }
        let owners = ActivityOwnership.read().filter { url, _ in
            watchedFolders.contains { url.path.hasPrefix($0.path + "/") }
        }
        discovered = Array(Set(discovered).union(owners.keys))
        var snapshot = ActivitySnapshot(indexing: false)
        var budget = 8 * 1024 * 1024
        // Recently modified logs first so historical indexing does not delay current work.
        let entries = discovered.compactMap { url -> (URL, UInt64, Date, UInt64)? in
            guard let attrs = try? fm.attributesOfItem(atPath: url.path), let size = attrs[.size] as? NSNumber else { return nil }
            return (url, size.uint64Value, attrs[.modificationDate] as? Date ?? .distantPast,
                    (attrs[.systemFileNumber] as? NSNumber)?.uint64Value ?? 0)
        }.sorted { $0.2 > $1.2 }
        for (url, size, modified, number) in entries {
            var state = files[url] ?? ActivityLogState()
            if size < state.offset || (state.fileNumber != 0 && number != state.fileNumber) {
                state = ActivityLogState(); requestSettings[url] = nil
            }
            state.fileNumber = number
            let oldOwner = state.attributedAccount
            state.observeOwner(owners[url], at: size)
            if oldOwner != state.attributedAccount { cacheDirty = true }
            if size > state.offset && budget > 0 {
                do {
                    let handle = try FileHandle(forReadingFrom: url)
                    defer { try? handle.close() }
                    try handle.seek(toOffset: state.offset)
                    let data = try handle.read(upToCount: min(budget, 8 * 1024 * 1024)) ?? Data()
                    state.offset += UInt64(data.count); budget -= data.count
                    if !data.isEmpty { cacheDirty = true }
                    state.append(data)
                } catch { snapshot.unreadableFiles += 1 }
            }
            snapshot.indexing = snapshot.indexing || state.offset < size
            files[url] = state
            // Fast lane: current activity never waits for the historical index.
            if now.timeIntervalSince(modified) < 300 {
                var recent = live[url] ?? ActivityLogState()
                recent.liveOnly = true
                if recent.fileNumber != number || recent.offset > size {
                    recent = ActivityLogState(); recent.liveOnly = true
                }
                if recent.offset == 0 {
                    recent.offset = size > 524_288 ? size - 524_288 : 0
                    recent.oversizedLine = recent.offset > 0 // discard partial first line
                }
                recent.fileNumber = number
                recent.account = owners[url] ?? state.account
                if size > recent.offset, let handle = try? FileHandle(forReadingFrom: url) {
                    defer { try? handle.close() }
                    try? handle.seek(toOffset: recent.offset)
                    if let data = try? handle.read(upToCount: 524_288) {
                        recent.offset += UInt64(data.count); recent.append(data)
                    }
                }
                if let owner = owners[url] { recent.account = owner }
                live[url] = recent
                // Missing starts in a tail are covered by fresh token events; terminal events win.
                let active = (!recent.turns.isEmpty && now.timeIntervalSince(recent.latest) < 180)
                    || (recent.lastWork > recent.lastFinish && now.timeIntervalSince(recent.lastWork) < 15)
                if active && recent.offset == size {
                    snapshot.active = true
                    snapshot.activeAccounts[recent.account, default: 0] += 1
                    // A historical context must not be mistaken for a different live turn.
                    let turn = recent.activeTurnID ?? (state.offset == size ? state.activeTurnID : nil)
                    let context = recent.turnContext ?? (turn != nil && state.turnContext?.turnID == turn ? state.turnContext : nil)
                    let threadID = String(url.deletingPathExtension().lastPathComponent.suffix(36))
                    var sample = requestSettings[url]
                    if sample?.turn != turn || sample == nil ||
                        ((turn == nil || sample?.value?.serviceTier == nil) && now.timeIntervalSince(sample!.checkedAt) >= 5) {
                        let value: ObservedActivitySettings?
                        if let turn { value = ActivitySettingsReader.settings(home: root, threadID: threadID, turnID: turn) }
                        else { value = ActivitySettingsReader.latestSettings(home: root, threadID: threadID,
                            since: max(now.addingTimeInterval(-180), recent.lastFinish)) }
                        sample = SettingsSample(turn: turn, checkedAt: now, value: value)
                        requestSettings[url] = sample
                    }
                    let confirmedTurn = turn ?? sample?.value?.turnID
                    let current = confirmedTurn != nil && context?.turnID == confirmedTurn
                    snapshot.activeConversations.append(ActiveConversation(
                        id: url.deletingPathExtension().lastPathComponent, account: recent.account,
                        model: sample?.value?.model ?? (current ? context?.model : nil),
                        effort: sample?.value?.effort ?? (current ? context?.effort : nil),
                        serviceTier: sample?.value?.serviceTier ?? (current ? context?.serviceTier : nil),
                        project: current ? context?.project : nil))
                } else { requestSettings[url] = nil }
                if let limit = recent.limit, limit.date > (snapshot.limits[recent.account]?.date ?? .distantPast) {
                    snapshot.limits[recent.account] = limit
                }
            }
            if state.account != ActivitySnapshot.unknown { snapshot.observedAccounts.insert(state.account) }
            if let owner = owners[url] { snapshot.observedAccounts.insert(owner) }
            for accounts in state.days.values {
                snapshot.observedAccounts.formUnion(accounts.keys.filter { $0 != ActivitySnapshot.unknown })
            }
            if let limit = state.limit, limit.date > (snapshot.limits[state.account]?.date ?? .distantPast) {
                snapshot.limits[state.account] = limit
            }
            for (day, accounts) in state.costs ?? [:] {
                for (account, cost) in accounts { snapshot.costs[day, default: [:]][account, default: TokenCost()].add(cost) }
            }
            for (day, accounts) in state.days {
                for (account, tokens) in accounts { snapshot.days[day, default: [:]][account, default: 0] += tokens }
            }
        }
        snapshot.updatedAt = now
        if let cacheURL, cacheDirty, now.timeIntervalSince(lastSave) >= 30 {
            let sanitized = Dictionary(uniqueKeysWithValues: files.map { url, state in
                var saved = state
                saved.offset -= UInt64(saved.pending.count)
                saved.pending = Data() // Never persist conversation text, even a partial line.
                return (url.path, saved)
            })
            if let data = try? JSONEncoder().encode(Cache(version: 4, root: root.path, files: sanitized)) {
                try? fm.createDirectory(at: cacheURL.deletingLastPathComponent(), withIntermediateDirectories: true,
                    attributes: [.posixPermissions: 0o700])
                try? data.write(to: cacheURL, options: .atomic)
                try? fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: cacheURL.path)
            }
            lastSave = now; cacheDirty = false
        }
        return snapshot
    }
}

/// Resolve only files actually held by a live Codex process. No shell, network, or credential logging.
enum ActivityOwnership {
    static func unique(_ candidates: [URL: Set<String>]) -> [URL: String] {
        candidates.compactMapValues { $0.count == 1 ? $0.first : nil }
    }
    static func read() -> [URL: String] {
        let capacity = proc_listallpids(nil, 0)
        guard capacity > 0, capacity < 100_000 else { return [:] }
        var pids = [Int32](repeating: 0, count: Int(capacity) + 128)
        let count = proc_listallpids(&pids, Int32(pids.count * MemoryLayout<Int32>.stride))
        guard count > 0 else { return [:] }
        var candidates: [URL: Set<String>] = [:]
        for pid in pids.prefix(Int(count)) {
            var path = [CChar](repeating: 0, count: Int(4 * MAXPATHLEN))
            guard proc_pidpath(pid, &path, UInt32(path.count)) > 0,
                  String(cString: path).hasSuffix("/codex"),
                  let (args, environment) = try? AppIdentityReader.arguments(pid),
                  !args.contains(where: { $0 == "-p" || $0 == "--profile" || $0.hasPrefix("--profile=") || $0.contains("cli_auth_credentials_store") }),
                  let home = environment["CODEX_HOME"] ?? environment["HOME"].map({ $0 + "/.codex" }), home.hasPrefix("/") else { continue }
            let base = URL(fileURLWithPath: home)
            if let config = try? String(contentsOf: base.appendingPathComponent("config.toml"), encoding: .utf8),
               config.contains("cli_auth_credentials_store") { continue }
            let auth = base.appendingPathComponent("auth.json")
            guard let size = try? auth.resourceValues(forKeys: [.fileSizeKey]).fileSize, size <= 1_000_000,
                  let data = try? Data(contentsOf: auth),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let tokens = object["tokens"] as? [String: Any],
                  let account = tokens["account_id"] as? String, !account.isEmpty else { continue }
            let bytes = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, nil, 0)
            guard bytes > 0, bytes < 4_000_000 else { continue }
            var fds = [proc_fdinfo](repeating: proc_fdinfo(), count: Int(bytes) / MemoryLayout<proc_fdinfo>.stride + 16)
            let used = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, &fds, Int32(fds.count * MemoryLayout<proc_fdinfo>.stride))
            for fd in fds.prefix(max(0, Int(used) / MemoryLayout<proc_fdinfo>.stride)) where fd.proc_fdtype == PROX_FDTYPE_VNODE {
                var info = vnode_fdinfowithpath()
                guard proc_pidfdinfo(pid, fd.proc_fd, PROC_PIDFDVNODEPATHINFO, &info, Int32(MemoryLayout.size(ofValue: info))) > 0 else { continue }
                let name = withUnsafePointer(to: &info.pvip.vip_path) {
                    $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXPATHLEN)) { String(cString: $0) }
                }
                guard name.hasSuffix(".jsonl"), name.contains("/sessions/") || name.contains("/archived_sessions/") else { continue }
                candidates[URL(fileURLWithPath: name).resolvingSymlinksInPath(), default: []].insert(account)
            }
        }
        return unique(candidates)
    }
}
