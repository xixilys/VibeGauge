import Foundation
import CryptoKit
import os

/// 只缓存用量字段，不保存对话正文；按文件保留贡献，才能在日志重写后撤销旧账。
///
/// 口径（对齐 ccusage 的做法）：
/// · Claude：同一 requestId 在日志里会写多行（流式分块），取 token 最多的那条；跨文件再去重（--fork-session 会复制历史）。
///   `cache_creation.ephemeral_1h_input_tokens` 单独记，1 小时缓存写入按 2× 输入价算；`usage.speed == "fast"` 记为 fast 档。
/// · Codex：新版每次请求写一条 `token_usage_record`（带 response_id，天然去重）；旧版回退到 `token_count`
///   的 `last_token_usage`（累计值没前进就不算）。`thread_settings_applied.service_tier` 记下 priority/fast 档。
///   同一个 rollout 文件出现在 sessions/ 和 archived_sessions/ 里只算一次。
/// · 远程主机：ssh 跑采集脚本拿逐条记录（Claude / Codex / opencode），挂载目录（如 WSL 的家目录）当成另一台设备直接读。
public final class UsageHistory {
    public static let shared = UsageHistory()

    public struct ModelTotals: Codable, Equatable {
        public var ctx: Int64 = 0
        public var cacheRead: Int64 = 0
        public var cacheWrite: Int64 = 0
        public var out: Int64 = 0
        public var think: Int64 = 0
        public var tokenTotal: Int64 { ctx + out }
        mutating func add(_ other: ModelTotals) {
            ctx += other.ctx; cacheRead += other.cacheRead; cacheWrite += other.cacheWrite
            out += other.out; think += other.think
        }
    }

    public struct Totals: Codable, Equatable {
        public var ctx: Int64 = 0
        public var cacheRead: Int64 = 0
        public var cacheWrite: Int64 = 0
        public var out: Int64 = 0
        public var think: Int64 = 0
        public var turns = 0
        public var sessions = 0
        public var models: [String: ModelTotals] = [:]
        public var tokenTotal: Int64 { ctx + out }
        public var newInput: Int64 { max(0, ctx - cacheRead - cacheWrite) }
        public var cacheTotal: Int64 { cacheRead + cacheWrite }
        public var cacheHitRate: Double { ctx > 0 ? Double(cacheRead) / Double(ctx) * 100 : 0 }

        mutating func add(_ record: Record) {
            let u = record.usage
            ctx += u.ctx; cacheRead += u.cacheRead; cacheWrite += u.cacheWrite
            out += u.out; think += u.think; turns += 1
            models[record.model, default: ModelTotals()].add(u)
        }
        mutating func merge(_ other: Totals) {
            ctx += other.ctx; cacheRead += other.cacheRead; cacheWrite += other.cacheWrite
            out += other.out; think += other.think; turns += other.turns; sessions += other.sessions
            for (model, usage) in other.models { models[model, default: ModelTotals()].add(usage) }
        }
    }

    public struct Day: Codable, Equatable, Identifiable {
        public var id: String { date }
        public let date: String
        public var sources: [String: Totals]
        public var total: Totals { sources.values.reduce(into: Totals()) { $0.merge($1) } }
    }

    public struct Snapshot: Equatable {
        public var days: [Day] = []
        public var dailyTokens: [String: Int64] = [:]
        public var totals: [String: Totals] = [:]
        public var aggregate = Totals()
        public var earliestDate: String?
        public var activeDays = 0
        public var isScanning = false
        public var processedFiles = 0
        public var totalFiles = 0
        public var error = ""
        public var sourceNotes: [String: String] = [:]
        /// 用户自己配了 prices.json（手填或 models.dev 同步）
        public var hasPriceTable = false
        public var priceCurrency = ""
        /// 内置官方价的日期（空 = 内置价读不到）
        public var builtinPriceAsOf = ""
        public var hasAnyPricing: Bool { hasPriceTable || !builtinPriceAsOf.isEmpty }
        /// 按币种分桶：国产模型 ¥、外国模型 $，不做汇率换算，各显各的
        public var costByCurrency: [String: Double] = [:]
        public var costBySource: [String: [String: Double]] = [:]
        public var costByModel: [String: [String: Double]] = [:]
        public var todayCostBySource: [String: [String: Double]] = [:]
        public var todayBySource: [String: Totals] = [:]
        /// 每日花费（主币种），给热力图 tooltip / 柱状图
        public var dailyCost: [String: Double] = [:]
        public var primaryCurrency = "USD"
        public var forecasts: [String: CostForecast] = [:]
        /// 设备作用域 → 币种 → 预测；键为 local / remote:<host>，不把其他设备的曲线带入筛选页。
        public var forecastsByDevice: [String: [String: CostForecast]] = [:]
        public var dailyCostByDevice: [String: [String: [String: Double]]] = [:]
        public var forecast: CostForecast? { forecasts[primaryCurrency] }
        public var claudeBlock: BillingBlock?
        public var unpricedModels = 0
        public var unpricedBySource: [String: Int] = [:]
        public var unpricedNames: [String] = []
        public var unpricedNamesBySource: [String: [String]] = [:]
        public var cumulativeTurns = 0
        public var replayedTurns = 0
        public var skippedRecords = 0
        public var capturedAt: TimeInterval = 0
        public var tokenTotal: Int64 { aggregate.tokenTotal }
        public var ctx: Int64 { aggregate.ctx }
        public var cacheRead: Int64 { aggregate.cacheRead }
        public var cacheHitRate: Double? { ctx > 0 ? Double(cacheRead) / Double(ctx) : nil }
        public init() {}

        /// 零点后的下一次扫描前，不把昨日缓存继续显示成今日用量。
        public func currentDaySources(at now: TimeInterval = Date().timeIntervalSince1970,
                                      timeZone: TimeZone = .current) -> [String: Totals] {
            guard capturedAt > 0,
                  UsageHistory.dayKey(timestamp: capturedAt, timeZone: timeZone) == UsageHistory.dayKey(timestamp: now, timeZone: timeZone)
            else { return [:] }
            return todayBySource
        }
    }

    /// 经记账代理的上游（"API · GLM" 这类）：同一请求多半已在 CLI 日志里，不进总数
    public static func isProxySource(_ source: String) -> Bool { source.hasPrefix("API") }

    /// 来源属于哪台设备：`X · <设备>` 的后缀；本机来源没有后缀（API 记账也算本机）。
    public static func device(of source: String) -> String? {
        guard !isProxySource(source), let r = source.range(of: " · ", options: .backwards) else { return nil }
        return String(source[r.upperBound...])
    }

    /// 来源的 CLI 名（去掉设备后缀）。
    public static func cli(of source: String) -> String {
        guard !isProxySource(source), let r = source.range(of: " · ", options: .backwards) else { return source }
        return String(source[..<r.lowerBound])
    }

    /// 同值同档，零日留空；档位只由非零日的最近秩分位数决定。
    public static func levels(_ values: [Int64]) -> [Int] {
        let positive = values.filter { $0 > 0 }.sorted()
        guard !positive.isEmpty else { return values.map { _ in 0 } }
        let thresholds = (1...4).map { positive[max(0, Int(ceil(Double(positive.count) * Double($0) / 5)) - 1)] }
        return values.map { value in value <= 0 ? 0 : 1 + thresholds.filter { value > $0 }.count }
    }

    public static func dayKey(timestamp: TimeInterval, timeZone: TimeZone = .current) -> String {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = timeZone
        let c = cal.dateComponents([.year, .month, .day], from: Date(timeIntervalSince1970: timestamp))
        return String(format: "%04d-%02d-%02d", c.year!, c.month!, c.day!)
    }

    public static func codexLastTokenUsage(_ fields: [String: Int64]) -> ModelTotals {
        ModelTotals(ctx: fields["input_tokens"] ?? 0, cacheRead: fields["cached_input_tokens"] ?? 0,
                    cacheWrite: fields["cache_write_input_tokens"] ?? 0, out: fields["output_tokens"] ?? 0,
                    think: fields["reasoning_output_tokens"] ?? 0)
    }

    /// 累计值回退时只建立新基线；不把负差变成零，也不把整个重置值再记一次。
    public static func codexCumulativeDelta(previous: [String: Int64]?, current: [String: Int64]) -> ModelTotals? {
        var delta: [String: Int64] = [:]
        for key in tokenKeys {
            let now = current[key] ?? 0, old = previous?[key] ?? 0
            guard now >= old else { return nil }
            delta[key] = now - old
        }
        let result = codexLastTokenUsage(delta)
        return result.tokenTotal > 0 ? result : nil
    }

    /// 同一累计快照可被额度刷新重复写入；不同请求即便单次 token 完全相同，也不能被去重。
    static func codexUsage(info: [String: Any], previous: inout [String: Int64]?) -> (usage: ModelTotals, cumulative: Bool)? {
        let total = tokenFields(info["total_token_usage"])
        let last = tokenFields(info["last_token_usage"])
        let old = previous
        if let total { previous = total }
        if let total, total == old { return nil }
        if let last { return (codexLastTokenUsage(last), false) }
        guard let total, let delta = codexCumulativeDelta(previous: old, current: total) else { return nil }
        return (delta, true)
    }

    struct Record: Codable, Equatable {
        var id: String
        var source: String
        var timestamp: TimeInterval
        var model: String
        var usage: ModelTotals
        var cumulative = false
        /// 多会话来源（opencode / 远程）的会话键。nil 时沿用旧口径：按日志文件路径计会话。
        /// 必须是可选：老缓存里没有这个键，可选字段才能被 decodeIfPresent 兼容，不必升版本丢历史。
        var session: String? = nil
        /// 1 小时缓存写入（已含在 usage.cacheWrite 里），单独计价。
        var cw1h: Int64? = nil
        /// 服务档：Codex "priority"/"fast"、Claude "fast"；nil = 标准。
        var tier: String? = nil
    }

    /// 文件内同 requestId 取 token 最多的那条（流式分块会先写一个不完整的 usage），跨文件同理。
    static func deduplicateClaude(_ files: [String: [Record]]) -> [String: Record] {
        var result: [String: Record] = [:]
        for path in files.keys.sorted() {
            for record in files[path] ?? [] {
                if let old = result[record.id], !prefer(record, over: old) { continue }
                result[record.id] = record
            }
        }
        return result
    }

    static func prefer(_ candidate: Record, over existing: Record) -> Bool {
        if candidate.usage.tokenTotal != existing.usage.tokenTotal { return candidate.usage.tokenTotal > existing.usage.tokenTotal }
        return candidate.timestamp > existing.timestamp
    }

    private struct FileState: Codable {
        var source: String
        var model = "?"
        var size: UInt64 = 0
        var mtime: TimeInterval = 0
        var offset: UInt64 = 0
        var head = ""
        var previousTotal: [String: Int64]?
        var records: [String: Record] = [:]
        var skipped = 0
        /// 远程来源专用：上次拉到的最大 time_updated / 文件 mtime（毫秒），下次只拉比它更新的。
        var cursor: Int64? = nil
        /// 远程来源专用：上次全量拉取时刻；超过一天就强制全量，把远端删掉的会话清出去。
        var fullAt: TimeInterval? = nil
        // ---- 以下为 parser 2 新增，全部可选，老缓存照样能解 ----
        var tier: String? = nil
        var hasUsageRecords: Bool? = nil
        var forked: Bool? = nil
        var burstLast: TimeInterval? = nil
        var burstFirstId: String? = nil
        var burstDone: Bool? = nil
        var replayed: Int? = nil
    }
    private struct DiskCache: Codable {
        var version = 3
        var files: [String: FileState] = [:]
        var days: [Day] = []
        var updatedAt: TimeInterval = 0
        /// 解析器版本：升级后仍在磁盘上的日志重解析一次（已删除日志的历史保留）。
        var parser: Int? = nil
    }
    private static let parserVersion = 2

    private enum Kind { case claude, codex, opencode, api, remote }
    private static func kind(of source: String) -> Kind {
        if source.hasPrefix("Claude") { return .claude }
        if source.hasPrefix("Codex") { return .codex }
        if source.hasPrefix("OpenCode") { return .opencode }
        if source.hasPrefix("Remote") { return .remote }
        return .api
    }

    private let lock = NSLock()
    private let worker = DispatchQueue(label: "com.haifeng.vibegauge.usage-history", qos: .utility)
    private let log = Logger(subsystem: "com.haifeng.vibegauge", category: "usage-history")
    private let home: String
    private let cachePath: String
    private let opencodeDB: String
    private let catalogOverride: PricingCatalog.Catalog?
    private var remoteStatus: [String: Bool] = [:]
    private var remoteError: [String: String] = [:]
    private var remoteCLIStatus: [String: String] = [:]
    private var remotePulledAt: [String: TimeInterval] = [:]
    private var timer: DispatchSourceTimer?
    private var started = false
    private var loaded = false
    private var errors: Set<String> = []
    private var cache = DiskCache()
    private var cached = Snapshot()
    /// 缓存约 30MB：有变化才写、且至少隔 30 分钟。崩溃丢掉的只是 offset 进度，
    /// 下次从旧 offset 重读，记录按 requestId/行偏移做键，重复读不会重复计数。
    private var dirty = false
    private var savedAt: TimeInterval = 0
    private static let saveEvery: TimeInterval = 1800
    private static let scanEvery: TimeInterval = 120
    private static let remoteEvery: TimeInterval = 300
    private let iso = ISO8601DateFormatter()
    private let isoPlain = ISO8601DateFormatter()
    private static let tokenKeys = ["input_tokens", "cached_input_tokens", "cache_write_input_tokens", "output_tokens", "reasoning_output_tokens"]
    private static let usageMarker = Data("\"usage\"".utf8)
    private static let codexMarkers = ["\"token_count\"", "\"turn_context\"", "\"session_meta\"", "\"token_usage_record\"", "\"thread_settings_applied\""].map { Data($0.utf8) }

    /// `opencodeDB` / `catalog` 只在自测里注入：真实路径按 XDG 规则算，内置价随 bundle 分发。
    public init(home: String = FileManager.default.homeDirectoryForCurrentUser.path, cachePath: String? = nil, opencodeDB: String? = nil,
                catalog: PricingCatalog.Catalog? = nil) {
        self.home = home
        self.cachePath = cachePath ?? "\(home)/.config/vibegauge/usage-daily.json"
        self.opencodeDB = opencodeDB ?? OpenCodeUsage.databasePath(home: home)
        self.catalogOverride = catalog
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        isoPlain.formatOptions = [.withInternetDateTime]
    }

    public func start() {
        lock.lock()
        guard !started else { lock.unlock(); return }
        started = true
        lock.unlock()
        worker.async { [weak self] in
            guard let self else { return }
            let timer = DispatchSource.makeTimerSource(queue: self.worker)
            timer.schedule(deadline: .now(), repeating: Self.scanEvery)
            timer.setEventHandler { [weak self] in self?.scan() }
            self.timer = timer
            timer.resume()
        }
    }

    /// 锁只保护快照交换，不参与读盘、解码、归并或落盘。
    public func snapshot() -> Snapshot {
        lock.lock(); defer { lock.unlock() }
        return cached
    }

    /// 立即重扫一次（价格表更新后刷新成本时用）。
    public func refreshNow() { worker.sync { scan() } }

    /// 后台排队重扫（面板上的「刷新」按钮，不阻塞主线程）。
    public func refreshSoon() { worker.async { [weak self] in self?.scan(forceRemote: true) } }

    func scanNowForTesting() { refreshNow() }

    // MARK: - 设备

    /// 挂载目录：`defaults write com.haifeng.vibegauge mountRoots "wsl=/Volumes/wsl/home/me; lab=/Volumes/lab/home/me"`。
    /// 每一项是另一台机器的家目录（里面有 .claude / .codex），标签就是面板里的设备名。
    public static func mountRoots(defaults: UserDefaults = .standard) -> [(label: String, path: String)] {
        guard let raw = defaults.string(forKey: "mountRoots") else { return [] }
        return parseMountRoots(raw)
    }

    public static func parseMountRoots(_ raw: String) -> [(label: String, path: String)] {
        var out: [(label: String, path: String)] = []
        var seen = Set<String>()
        for item in raw.split(whereSeparator: { ";\n,".contains($0) }) {
            let text = item.trimmingCharacters(in: .whitespaces)
            guard !text.isEmpty else { continue }
            var label: String, path: String
            if let eq = text.firstIndex(of: "=") {
                label = String(text[..<eq]).trimmingCharacters(in: .whitespaces)
                path = String(text[text.index(after: eq)...]).trimmingCharacters(in: .whitespaces)
            } else {
                path = text
                label = URL(fileURLWithPath: text).lastPathComponent
            }
            path = (path as NSString).expandingTildeInPath
            guard path.hasPrefix("/"), label.range(of: #"^[A-Za-z0-9][A-Za-z0-9._-]{0,31}$"#, options: .regularExpression) != nil,
                  seen.insert(label).inserted else { continue }
            out.append((label: label, path: path))
        }
        return out
    }

    // MARK: - 扫描

    private func scan(forceRemote: Bool = false) {
        errors = []
        publishProgress(0, total: 0)
        loadCache()
        let paths = discoverFiles()
        let hosts = RemoteCollector.hosts()
        let now = Date().timeIntervalSince1970
        let refreshHosts = CommandLine.arguments.contains("--selftest") ? [] : hosts.filter {
            forceRemote || now - (remotePulledAt[$0] ?? 0) >= Self.remoteEvery
        }
        let units = paths.count + 1 + hosts.count
        publishProgress(0, total: units)
        for (index, item) in paths.enumerated() {
            autoreleasepool { process(item.path, source: item.source) }
            publishProgress(index + 1, total: units)
        }
        ingestOpenCode()
        publishProgress(paths.count + 1, total: units)
        // SSH 冷扫描可能很慢；先让本机的新数据可见，远端仍保留上次记录。
        // 两次汇总都在同一个 worker 上，快照交换以外不持锁。
        if !refreshHosts.isEmpty {
            publish(makeSnapshot(paths: paths, hosts: hosts, processed: paths.count + 1, total: units,
                                 refreshingHosts: Set(refreshHosts), isScanning: true))
            ingestRemote(hosts: refreshHosts)
        }
        var result = makeSnapshot(paths: paths, hosts: hosts, processed: units, total: units)
        cache.days = result.days
        cache.updatedAt = result.capturedAt
        if dirty, cache.updatedAt - savedAt >= Self.saveEvery {
            saveCache()
            dirty = false
            savedAt = cache.updatedAt
        }
        result.error = errors.sorted().joined(separator: "；")
        publish(result)
        log.notice("历史汇总完成：\(paths.count) 文件，\(result.days.count) 天，跳过 \(result.skippedRecords) 条不完整记录")
    }

    private func makeSnapshot(paths: [(path: String, source: String)], hosts: [String], processed: Int, total: Int,
                              refreshingHosts: Set<String> = [], isScanning: Bool = false) -> Snapshot {
        var result = summarize()
        result.isScanning = isScanning
        result.processedFiles = processed
        result.totalFiles = total
        for source in ["Claude", "Codex"] where !paths.contains(where: { $0.source == source }) {
            result.sourceNotes[source] = result.totals[source] == nil ? "未检测到本机会话日志" : "日志已移除，显示已缓存历史"
        }
        if result.totals["OpenCode"] == nil {
            result.sourceNotes["OpenCode"] = FileManager.default.fileExists(atPath: opencodeDB) ? "未检测到 opencode 用量记录" : "未检测到 opencode 数据库"
        }
        for host in hosts {
            for cli in ["OpenCode", "Codex", "Claude"] {
                let source = "\(cli) · \(host)"
                let reason = cli == "OpenCode" ? (remoteStatus[host] == false ? remoteError[host] : nil) : remoteCLIStatus[host]
                result.sourceNotes[source] = Self.remoteSourceNote(cli: cli, hasHistory: result.totals[source] != nil,
                                                                   isRefreshing: refreshingHosts.contains(host), failure: reason)
            }
        }
        for root in Self.mountRoots() where !FileManager.default.fileExists(atPath: root.path) {
            result.sourceNotes["Claude · \(root.label)"] = "挂载目录不在：\(root.path)"
            result.sourceNotes["Codex · \(root.label)"] = "挂载目录不在：\(root.path)"
        }
        result.capturedAt = Date().timeIntervalSince1970
        result.error = errors.sorted().joined(separator: "；")
        return result
    }

    /// 拉取失败时，已有记录也必须说明是保留的历史，不能被本机刷新时间掩盖。
    static func remoteSourceNote(cli: String, hasHistory: Bool, isRefreshing: Bool, failure: String?) -> String? {
        if isRefreshing {
            return hasHistory ? L("正在刷新远端日志，显示已缓存历史", "Refreshing remote logs; showing retained history")
                              : L("正在读取远端日志", "Reading remote logs")
        }
        if let failure {
            return hasHistory ? L("远端日志刷新失败（\(failure)），显示已缓存历史", "Remote refresh failed (\(failure)); showing retained history")
                              : L("未连上（\(failure)）", "Unavailable (\(failure))")
        }
        return hasHistory ? nil : L("远端无 \(cli) 记录", "No remote \(cli) records")
    }

    private func publish(_ result: Snapshot) {
        lock.lock()
        let old = cached
        cached = result
        lock.unlock()
        withExtendedLifetime(old) {}
    }

    private func discoverFiles() -> [(path: String, source: String)] {
        let fm = FileManager.default
        var result: [(path: String, source: String)] = []
        var roots: [(suffix: String, home: String)] = [("", home)]
        // 自测的临时 home 不读真实挂载目录
        if home == FileManager.default.homeDirectoryForCurrentUser.path {
            roots += Self.mountRoots().map { (suffix: " · \($0.label)", home: $0.path) }
        }
        for root in roots {
            let dirs: [(String, String)] = [(".claude/projects", "Claude"), (".config/claude/projects", "Claude"),
                                            (".codex/sessions", "Codex"), (".codex/archived_sessions", "Codex")]
            for (suffix, cli) in dirs {
                let base = URL(fileURLWithPath: "\(root.home)/\(suffix)")
                guard fm.fileExists(atPath: base.path) else { continue }
                guard let en = fm.enumerator(at: base, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey], errorHandler: { _, _ in
                    self.errors.insert("部分日志目录无法读取，汇总可能不完整")
                    return true
                }) else { errors.insert("日志目录无法读取"); continue }
                for case let url as URL in en where url.pathExtension == "jsonl" {
                    guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey]),
                          values.isRegularFile == true, values.isSymbolicLink != true else { continue }
                    result.append((url.path, cli + root.suffix))
                }
            }
        }
        let api = "\(home)/.config/vibegauge/api-calls.jsonl"
        if fm.fileExists(atPath: api) { result.append((api, "API")) }
        return result.sorted { $0.path < $1.path }
    }

    /// 本机 opencode：一次 SQL 整表重读后替换这份伪文件的全部记录；读失败保留上次，绝不拿空数据覆盖。
    private func ingestOpenCode() {
        guard FileManager.default.fileExists(atPath: opencodeDB) else { return }   // 库不在 → 保留已缓存历史
        guard let records = OpenCodeUsage.read(dbPath: opencodeDB) else {
            errors.insert("opencode 用量库暂时读不到，保留上次汇总")
            return
        }
        if records.isEmpty, let cached = cache.files[opencodeDB], !cached.records.isEmpty {
            errors.insert("opencode 用量库读回 0 条，保留上次汇总")
            return
        }
        cache.files[opencodeDB] = FileState(source: "OpenCode", records: records)
        dirty = true
    }

    /// 远程主机：ssh 拉 opencode 增量 + Claude/Codex 逐条记录（按文件 mtime 游标增量）。
    /// 失败只更新状态、保留该主机上次的记录 —— 和日志被删后仍保留历史是同一个口径。
    private func ingestRemote(hosts: [String]) {
        for host in hosts {
            let now = Date().timeIntervalSince1970
            remotePulledAt[host] = now
            let key = "remote://\(host)"
            var state = cache.files[key] ?? FileState(source: "OpenCode · \(host)")
            let full = state.fullAt == nil || now - (state.fullAt ?? 0) >= 86400
            switch RemoteCollector.pullUsage(host: host, since: full ? 0 : (state.cursor ?? 0)) {
            case .failure(let error):
                remoteStatus[host] = false
                remoteError[host] = error.message
                if full { state.fullAt = now; cache.files[key] = state; dirty = true }
            case .success(let pull):
                remoteStatus[host] = true
                remoteError[host] = nil
                state.source = "OpenCode · \(host)"
                if full { state.records = [:] }
                for record in pull.records { state.records[record.id] = record }
                if pull.maxUpdated > 0 { state.cursor = max(state.cursor ?? 0, pull.maxUpdated) }
                if full { state.fullAt = now }
                cache.files[key] = state
                dirty = true
            }
            // Claude / Codex 逐条：只拉 mtime 比游标新的文件（留 10 分钟余量），记录按 id 覆盖。
            let cliKey = "remote-cli://\(host)"
            var cli = cache.files[cliKey] ?? FileState(source: "Remote · \(host)")
            let since = max(0, (cli.cursor ?? 0) - 600_000)
            switch RemoteCollector.pullCLIRecords(host: host, since: since) {
            case .failure(let error):
                remoteCLIStatus[host] = error.message
                log.notice("remote cli \(host, privacy: .public) 未连上：\(error.message, privacy: .public)")
            case .success(let pull):
                remoteCLIStatus[host] = nil
                for record in pull.records {
                    if let old = cli.records[record.id], Self.kind(of: record.source) == .claude, !Self.prefer(record, over: old) { continue }
                    cli.records[record.id] = record
                }
                if pull.maxMtime > 0 { cli.cursor = max(cli.cursor ?? 0, pull.maxMtime) }
                cache.files[cliKey] = cli
                dirty = true
                log.notice("remote cli \(host, privacy: .public) 收到 \(pull.records.count) 条")
            }
        }
    }

    private func process(_ path: String, source: String) {
        do {
            let attrs = try FileManager.default.attributesOfItem(atPath: path)
            guard let mod = attrs[.modificationDate] as? Date, let size = (attrs[.size] as? NSNumber)?.uint64Value else { throw CocoaError(.fileReadUnknown) }
            let fh = try FileHandle(forReadingFrom: URL(fileURLWithPath: path))
            defer { try? fh.close() }
            let head = try fh.read(upToCount: 256) ?? Data()
            var state = cache.files[path] ?? FileState(source: source)
            let oldHead = Self.fingerprint(Data(head.prefix(Int(min(256, state.size)))))
            let rewritten = state.offset > size || size < state.size || (!state.head.isEmpty && oldHead != state.head)
                || (size == state.size && mod.timeIntervalSince1970 != state.mtime)
            if state.source != source || rewritten { state = FileState(source: source) }
            if state.size == size, state.mtime == mod.timeIntervalSince1970, state.head == Self.fingerprint(head) { return }
            try fh.seek(toOffset: state.offset)
            try readNewLines(fh, state: &state, size: size)
            state.head = Self.fingerprint(head)
            state.size = size; state.mtime = mod.timeIntervalSince1970
            cache.files[path] = state
            dirty = true
        } catch { errors.insert("部分日志无法读取，保留上次汇总并等待重试") }
    }

    private func readNewLines(_ fh: FileHandle, state: inout FileState, size: UInt64) throws {
        var remaining = size - state.offset
        var pending = Data()
        while remaining > 0 {
            guard let chunk = try fh.read(upToCount: Int(min(1_048_576, remaining))), !chunk.isEmpty else { break }
            remaining -= UInt64(chunk.count)
            pending.append(chunk)
            guard let lastNL = pending.lastIndex(of: 0x0A) else { continue }
            let end = pending.index(after: lastNL)
            let complete = pending[pending.startIndex..<end]
            var offset = state.offset
            for line in complete.split(separator: 0x0A, omittingEmptySubsequences: false).dropLast() {
                autoreleasepool { consume(Data(line), offset: offset, state: &state) }
                offset += UInt64(line.count + 1)
            }
            state.offset = offset
            pending = Data(pending[end...])
        }
    }

    private func consume(_ data: Data, offset: UInt64, state: inout FileState) {
        let kind = Self.kind(of: state.source)
        // 大多数行是工具结果和正文，先筛字段名，避免把数 GB 无关 JSON 全部解码。
        if kind == .claude, data.range(of: Self.usageMarker) == nil { return }
        if kind == .codex, !Self.codexMarkers.contains(where: { data.range(of: $0) != nil }) { return }
        guard !data.isEmpty else { return }
        guard let j = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { state.skipped += 1; return }
        switch kind {
        case .claude: consumeClaude(j, state: &state)
        case .codex: consumeCodex(j, offset: offset, state: &state)
        default: consumeAPI(j, offset: offset, state: &state)
        }
    }

    private func consumeClaude(_ line: [String: Any], state: inout FileState) {
        // 子代理进度行把一条完整的 assistant 记录包在 data.message 里
        var entry = line
        if entry["message"] == nil || (entry["type"] as? String) != "assistant",
           let inner = (line["data"] as? [String: Any])?["message"] as? [String: Any], inner["message"] is [String: Any] {
            entry = inner
            if entry["type"] == nil { entry["type"] = "assistant" }
        }
        guard entry["type"] as? String == "assistant", let msg = entry["message"] as? [String: Any],
              let usage = msg["usage"] as? [String: Any] else { return }
        if entry["isApiErrorMessage"] as? Bool == true { return }
        let model = msg["model"] as? String ?? "?"
        guard !model.contains("synthetic") else { return }
        guard let ts = timestamp(entry["timestamp"]),
              let id = (entry["requestId"] as? String) ?? (msg["id"] as? String) ?? (entry["uuid"] as? String), !id.isEmpty,
              let input = number(usage["input_tokens"]), let output = number(usage["output_tokens"]) else { state.skipped += 1; return }
        let read = number(usage["cache_read_input_tokens"]) ?? 0
        let write = number(usage["cache_creation_input_tokens"]) ?? 0
        let w1h = min(write, number((usage["cache_creation"] as? [String: Any])?["ephemeral_1h_input_tokens"]) ?? 0)
        let think = number((usage["output_tokens_details"] as? [String: Any])?["thinking_tokens"]) ?? 0
        let tier = (usage["speed"] as? String)?.lowercased() == "fast" ? "fast" : nil
        let record = Record(id: id, source: state.source, timestamp: ts, model: model.isEmpty ? "?" : model,
                            usage: ModelTotals(ctx: input + read + write, cacheRead: read, cacheWrite: write, out: output, think: think),
                            cw1h: w1h > 0 ? w1h : nil, tier: tier)
        if let old = state.records[id], !Self.prefer(record, over: old) { return }
        state.records[id] = record
    }

    private func consumeCodex(_ j: [String: Any], offset: UInt64, state: inout FileState) {
        guard let payload = j["payload"] as? [String: Any] else { return }
        let type = j["type"] as? String ?? ""
        switch type {
        case "session_meta":
            if let fork = payload["forked_from_id"] as? String, !fork.isEmpty { state.forked = true }
            if let model = payload["model"] as? String, !model.isEmpty { state.model = model }
        case "turn_context":
            if let model = payload["model"] as? String, !model.isEmpty { state.model = model }
        case "token_usage_record":
            guard let fields = Self.tokenFields(payload["usage"]), let ts = timestamp(j["timestamp"]) else { state.skipped += 1; return }
            if state.hasUsageRecords != true {
                // 这个文件有逐请求记录：此前从 token_count 推出来的记录作废，避免两套口径叠加
                state.hasUsageRecords = true
                state.records = state.records.filter { $0.key.hasPrefix("resp") }
            }
            let usage = Self.codexLastTokenUsage(fields)
            guard usage.tokenTotal > 0 else { return }
            let id = (payload["response_id"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "resp-off-\(offset)"
            state.records[id] = Record(id: id, source: state.source, timestamp: ts, model: state.model, usage: usage,
                                       session: nil, tier: state.tier)
        case "event_msg":
            let ptype = payload["type"] as? String ?? ""
            if ptype == "thread_settings_applied" {
                if let tier = (payload["thread_settings"] as? [String: Any])?["service_tier"] as? String { state.tier = tier.lowercased() }
                return
            }
            guard ptype == "token_count", let info = payload["info"] as? [String: Any] else { return }
            guard let parsed = Self.codexUsage(info: info, previous: &state.previousTotal) else { return }
            guard state.hasUsageRecords != true else { return }
            guard let ts = timestamp(j["timestamp"]) else { state.skipped += 1; return }
            let id = String(offset)
            // 旧版 fork 会把父会话的用量按同一秒重放一遍：开头连续 1 秒内的一串只当基线
            if state.forked == true, state.burstDone != true {
                if let last = state.burstLast {
                    if ts - last <= 1.0 {
                        if let first = state.burstFirstId { state.records[first] = nil; state.burstFirstId = nil; state.replayed = (state.replayed ?? 0) + 1 }
                        state.burstLast = ts
                        state.replayed = (state.replayed ?? 0) + 1
                        return
                    }
                    state.burstDone = true
                } else {
                    state.burstLast = ts
                    state.burstFirstId = id
                }
            }
            let model = (payload["model"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? state.model
            state.records[id] = Record(id: id, source: state.source, timestamp: ts, model: model, usage: parsed.usage,
                                       cumulative: parsed.cumulative, tier: state.tier)
        default:
            return
        }
    }

    private func consumeAPI(_ j: [String: Any], offset: UInt64, state: inout FileState) {
        guard let ts = timestamp(j["epoch"]) ?? timestamp(j["ts"]), let host = j["host"] as? String,
              let ctx = number(j["ctx"]), let out = number(j["out"]) else { state.skipped += 1; return }
        let provider = (j["provider"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? host
        let model = (j["model"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "?"
        let id = String(offset)
        state.records[id] = Record(id: id, source: "API · " + provider, timestamp: ts, model: model,
                                   usage: ModelTotals(ctx: ctx, cacheRead: number(j["cache_read"]) ?? 0,
                                                      cacheWrite: number(j["cache_write"]) ?? 0, out: out, think: number(j["think"]) ?? 0))
    }

    static func tokenFields(_ raw: Any?) -> [String: Int64]? {
        guard let fields = raw as? [String: Any], fields["input_tokens"] is NSNumber, fields["output_tokens"] is NSNumber else { return nil }
        var result: [String: Int64] = [:]
        for key in tokenKeys {
            let n = (fields[key] as? NSNumber)?.int64Value ?? 0
            guard n >= 0 else { return nil }
            result[key] = n
        }
        // 缓存读不会超过输入、缓存写不会超过剩下的新鲜输入（ccusage 同样夹紧）
        let input = result["input_tokens"] ?? 0
        result["cached_input_tokens"] = min(result["cached_input_tokens"] ?? 0, input)
        result["cache_write_input_tokens"] = min(result["cache_write_input_tokens"] ?? 0, input - (result["cached_input_tokens"] ?? 0))
        return result
    }
    private func number(_ raw: Any?) -> Int64? {
        guard let n = raw as? NSNumber, n.int64Value >= 0 else { return nil }
        return n.int64Value
    }
    private func timestamp(_ raw: Any?) -> TimeInterval? {
        if let n = raw as? NSNumber { return n.doubleValue > 0 && n.doubleValue.isFinite ? n.doubleValue : nil }
        guard var text = raw as? String else { return nil }
        if let range = text.range(of: #"\.\d{4,}"#, options: .regularExpression) { text.replaceSubrange(range, with: text[range].prefix(4)) }
        return (iso.date(from: text) ?? isoPlain.date(from: text))?.timeIntervalSince1970
    }
    private static func fingerprint(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }

    private func loadCache() {
        guard !loaded else { return }
        loaded = true
        guard FileManager.default.fileExists(atPath: cachePath) else { cache.parser = Self.parserVersion; return }
        do {
            let decoded = try JSONDecoder().decode(DiskCache.self, from: Data(contentsOf: URL(fileURLWithPath: cachePath)))
            guard decoded.version == 3 else { errors.insert("历史缓存版本变化，已重新汇总"); return }
            cache = decoded
        } catch { errors.insert("历史缓存无法读取，已重新汇总") }
        if (cache.parser ?? 1) < Self.parserVersion {
            // 新口径：仍在磁盘上的 Claude / Codex 日志重解析一次；已被清理的日志保留旧账
            let fm = FileManager.default
            for (path, state) in cache.files where [.claude, .codex].contains(Self.kind(of: state.source)) && fm.fileExists(atPath: path) {
                cache.files[path] = nil
            }
            cache.parser = Self.parserVersion
            dirty = true
            savedAt = 0
        }
    }
    private func saveCache() {
        do {
            let url = URL(fileURLWithPath: cachePath)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.deletingLastPathComponent().path)
            try JSONEncoder().encode(cache).write(to: url, options: [.atomic])
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: cachePath)
        } catch { errors.insert("历史缓存保存失败，重启后需重新汇总") }
    }
    private func readJSON(_ path: String) -> [String: Any]? {
        guard FileManager.default.fileExists(atPath: path) else { return nil }
        do {
            guard let json = try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: path))) as? [String: Any] else { throw CocoaError(.fileReadCorruptFile) }
            return json
        } catch { errors.insert("价目表无法读取，未计入成本"); return nil }
    }
    private func publishProgress(_ processed: Int, total: Int) {
        lock.lock()
        cached.isScanning = true; cached.processedFiles = processed; cached.totalFiles = total
        lock.unlock()
    }

    // MARK: - 汇总

    private func summarize() -> Snapshot {
        var result = Snapshot()
        var buckets: [String: [String: Totals]] = [:]
        var sessions: [String: Set<String>] = [:]
        var dailySessions: [String: [String: Set<String>]] = [:]
        var claudeFiles: [String: [String: [Record]]] = [:]     // 来源 → 文件 → 记录
        var records: [Record] = []
        let fm = FileManager.default

        // 同一 rollout 同时出现在 sessions/ 与 archived_sessions/（或被挪走后旧路径还在缓存里）：只留一份
        var codexWinner: [String: String] = [:]
        for (path, state) in cache.files where Self.kind(of: state.source) == .codex {
            let key = state.source + "|" + (path as NSString).lastPathComponent
            if let other = codexWinner[key], let o = cache.files[other] {
                let mine = (fm.fileExists(atPath: path) ? 1 : 0, state.records.count)
                let theirs = (fm.fileExists(atPath: other) ? 1 : 0, o.records.count)
                if mine > theirs { codexWinner[key] = path }
            } else { codexWinner[key] = path }
        }
        let codexKeep = Set(codexWinner.values)

        for (path, state) in cache.files {
            let kind = Self.kind(of: state.source)
            if kind == .codex, !codexKeep.contains(path) { continue }
            result.skippedRecords += state.skipped
            if state.hasUsageRecords != true { result.replayedTurns += state.replayed ?? 0 }
            if kind == .claude {
                claudeFiles[state.source, default: [:]][path] = Array(state.records.values)
            } else {
                records.append(contentsOf: state.records.values)
            }
            for record in state.records.values {
                let day = Self.dayKey(timestamp: record.timestamp)
                let sessionKey = record.session ?? path
                sessions[record.source, default: []].insert(sessionKey)
                dailySessions[day, default: [:]][record.source, default: []].insert(sessionKey)
            }
        }
        for (_, files) in claudeFiles { records.append(contentsOf: Self.deduplicateClaude(files).values) }

        for record in records {
            let day = Self.dayKey(timestamp: record.timestamp)
            buckets[day, default: [:]][record.source, default: Totals()].add(record)
            result.totals[record.source, default: Totals()].add(record)
            if record.cumulative { result.cumulativeTurns += 1 }
        }
        for source in result.totals.keys { result.totals[source]?.sessions = sessions[source]?.count ?? 0 }
        for day in buckets.keys {
            for source in buckets[day]!.keys { buckets[day]?[source]?.sessions = dailySessions[day]?[source]?.count ?? 0 }
        }
        result.days = buckets.keys.sorted().map { Day(date: $0, sources: buckets[$0]!) }
        result.earliestDate = result.days.first?.date
        let now = Date()
        let todayKey = Self.dayKey(timestamp: now.timeIntervalSince1970)
        result.todayBySource = buckets[todayKey] ?? [:]
        // 经记账代理的 API 调用不计入总数与热力图：同一次请求在 CLI 日志里已经记过一次。
        func cliTokens(_ d: Day) -> Int64 {
            d.sources.filter { !Self.isProxySource($0.key) }.values.reduce(0) { $0 + $1.tokenTotal }
        }
        result.dailyTokens = Dictionary(uniqueKeysWithValues: result.days.map { ($0.date, cliTokens($0)) })
        result.activeDays = result.dailyTokens.values.filter { $0 > 0 }.count
        for (source, totals) in result.totals where !Self.isProxySource(source) { result.aggregate.merge(totals) }

        // ---- 成本：用户价目表优先，内置官方价兜底；按每条记录的时间与档位算 ----
        let userJSON = readJSON("\(home)/.config/vibegauge/prices.json")
        let user = userJSON.map { ProcessScanner.PriceTable(json: $0) } ?? ProcessScanner.PriceTable()
        let catalog = catalogOverride ?? PricingCatalog.builtin
        let engine = CostEngine(user: user, catalog: catalog)
        result.hasPriceTable = !user.isEmpty
        result.priceCurrency = user.currency
        result.builtinPriceAsOf = catalog.isEmpty ? "" : catalog.asOf
        var priced: [String: Bool] = [:]
        let horizon = now.timeIntervalSince1970 - 35 * 86400
        var hourly: [String: [String: [Double]]] = [:]       // 币种 → 日 → 24 小时
        var lastHour: [String: Double] = [:]
        var deviceHourly: [String: [String: [String: [Double]]]] = [:]
        var deviceLastHour: [String: [String: Double]] = [:]
        var claudePoints: [UsageForecast.Point] = []
        let hourCal = Calendar.current
        for record in records {
            if priced[record.model] == nil { priced[record.model] = engine.isPriced(record.model) }
            guard priced[record.model] == true,
                  let c = engine.cost(model: record.model, ctx: record.usage.ctx, cacheRead: record.usage.cacheRead,
                                      cacheWrite: record.usage.cacheWrite, cacheWrite1h: record.cw1h ?? 0, out: record.usage.out,
                                      tier: record.tier, at: Date(timeIntervalSince1970: record.timestamp)) else { continue }
            result.costByCurrency[c.currency, default: 0] += c.value
            result.costBySource[record.source, default: [:]][c.currency, default: 0] += c.value
            result.costByModel[record.model, default: [:]][c.currency, default: 0] += c.value
            let isProxy = Self.isProxySource(record.source)
            if !isProxy, record.timestamp >= horizon {
                let day = Self.dayKey(timestamp: record.timestamp)
                let hour = hourCal.component(.hour, from: Date(timeIntervalSince1970: record.timestamp))
                if hourly[c.currency]?[day] == nil { hourly[c.currency, default: [:]][day] = Array(repeating: 0, count: 24) }
                hourly[c.currency]?[day]?[hour] += c.value
                let device = Self.device(of: record.source).map { "remote:\($0)" } ?? "local"
                if deviceHourly[device]?[c.currency]?[day] == nil {
                    deviceHourly[device, default: [:]][c.currency, default: [:]][day] = Array(repeating: 0, count: 24)
                }
                deviceHourly[device]?[c.currency]?[day]?[hour] += c.value
                if day == todayKey { result.todayCostBySource[record.source, default: [:]][c.currency, default: 0] += c.value }
                if record.timestamp >= now.timeIntervalSince1970 - 3600 {
                    lastHour[c.currency, default: 0] += c.value
                    deviceLastHour[device, default: [:]][c.currency, default: 0] += c.value
                }
            }
            if record.source == "Claude", c.currency == "USD", record.timestamp >= now.timeIntervalSince1970 - 86400 {
                claudePoints.append(.init(timestamp: record.timestamp, cost: c.value, tokens: record.usage.tokenTotal))
            }
        }
        let cliCost = result.costBySource.filter { !Self.isProxySource($0.key) }
            .values.reduce(into: [String: Double]()) { acc, v in for (k, x) in v { acc[k, default: 0] += x } }
        result.primaryCurrency = cliCost.max { $0.value < $1.value }?.key ?? "USD"
        for (currency, days) in hourly {
            result.forecasts[currency] = UsageForecast.compute(hourly: days, lastHourCost: lastHour[currency] ?? 0, currency: currency, now: now)
        }
        for (device, currencies) in deviceHourly {
            for (currency, days) in currencies {
                result.dailyCostByDevice[device, default: [:]][currency] = days.mapValues { $0.reduce(0, +) }
                result.forecastsByDevice[device, default: [:]][currency] = UsageForecast.compute(
                    hourly: days, lastHourCost: deviceLastHour[device]?[currency] ?? 0, currency: currency, now: now)
            }
        }
        for (day, hours) in hourly[result.primaryCurrency] ?? [:] { result.dailyCost[day] = hours.reduce(0, +) }
        if !claudePoints.isEmpty {
            result.claudeBlock = UsageForecast.currentBlock(claudePoints.sorted { $0.timestamp < $1.timestamp }, currency: "USD",
                                                            now: now.timeIntervalSince1970)
        }
        // 未定价只按「模型」计一次，别按请求数刷屏。
        var unpricedNames = Set<String>()
        for (source, totals) in result.totals {
            for (model, _) in totals.models where !(priced[model] ?? engine.isPriced(model)) {
                result.unpricedModels += 1
                result.unpricedBySource[source, default: 0] += 1
                unpricedNames.insert(model)
                result.unpricedNamesBySource[source, default: []].append(model)
            }
        }
        result.unpricedNames = unpricedNames.sorted()
        for key in result.unpricedNamesBySource.keys { result.unpricedNamesBySource[key]?.sort() }
        return result
    }
}

public extension Fmt {
    /// 单币种金额："¥12.34" / "$5.67"；不足一分钱显示 "<0.01"；≥ 1 万用千分位。
    static func money(_ value: Double, _ currency: String) -> String {
        let symbol = currency == "CNY" ? "¥" : (currency == "USD" ? "$" : (currency.isEmpty ? "" : currency + " "))
        if value < 0.01 && value > 0 { return "\(symbol)<0.01" }
        if value >= 10_000 {
            let f = NumberFormatter(); f.numberStyle = .decimal; f.maximumFractionDigits = 0
            return symbol + (f.string(from: NSNumber(value: value)) ?? String(format: "%.0f", value))
        }
        return String(format: "%@%.2f", symbol, value)
    }

    /// 多币种并列显示："¥12.34 + $5.67"。不换算汇率 —— 编一个汇率和编一个价格一样糟。
    static func money(_ byCurrency: [String: Double]) -> String {
        let parts = byCurrency.keys.sorted().compactMap { key in byCurrency[key].map { money($0, key) } }
        return parts.isEmpty ? "—" : parts.joined(separator: " + ")
    }

    static func tokens(_ count: Int64) -> String {
        if count >= 100_000_000 { return String(format: "%.2f 亿", Double(count) / 100_000_000) }
        if count >= 10_000 { return String(format: "%.1f 万", Double(count) / 10_000) }
        return String(count)
    }
}
