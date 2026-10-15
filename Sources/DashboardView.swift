import Cocoa
import Combine
import SwiftUI
import Combine
import os

struct MiniProgressBar: View {
    var value: Double
    var color: Color = .green
    var width: CGFloat = 16
    var height: CGFloat = 3.5

    var body: some View {
        ZStack(alignment: .leading) {
            RoundedRectangle(cornerRadius: height / 2)
                .fill(Color.secondary.opacity(0.22))
                .frame(width: width, height: height)

            let safeRatio = max(0.02, min(1.0, value))
            RoundedRectangle(cornerRadius: height / 2)
                .fill(color)
                .frame(width: max(1.5, width * CGFloat(safeRatio)), height: height)
        }
    }
}

/// 承接滚动的容器。**必须放在这一层**：macOS 只把滚动事件派给光标下最深的可滚动视图，
/// SwiftUI 的 ScrollView 会吞掉它，挂在外层 NSHostingView 上收不到。
/// 横向为主 → 切 Tab 并吞事件；其余交给正常纵向滚动。
final class SwipeScrollView: NSScrollView {
    var onSwipe: ((Int) -> Void)?
    private let log = Logger(subsystem: "com.haifeng.vibegauge", category: "swipe")
    private var accum: CGFloat = 0
    private var lastAt: TimeInterval = 0
    private var armed = true          // 一次物理手势只允许触发一次（否则一次滑动会连跳两步）

    override func scrollWheel(with e: NSEvent) {
        let dx = e.scrollingDeltaX      // AppKit 已按用户的「自然滚动」设置给过方向，别再取反
        let dy = e.scrollingDeltaY
        let hasPhase = e.phase != [] || e.momentumPhase != []
        if e.phase == .began { accum = 0; armed = true }

        guard abs(dx) > abs(dy) * 1.5 else {
            accum = 0
            super.scrollWheel(with: e)
            return
        }
        guard e.momentumPhase == [] else { return }          // 惯性阶段只吞掉
        if hasPhase && !armed { return }                     // 本次手势已触发过，剩下的事件全吞掉

        accum += dx
        let threshold: CGFloat = e.hasPreciseScrollingDeltas ? 45 : 3
        let now = Date().timeIntervalSince1970
        if abs(accum) >= threshold, now - lastAt > 0.25 {
            let step = accum < 0 ? 1 : -1                    // 向左滑 = 下一步；向右滑 = 上一步/返回
            log.debug("swipe accum=\(self.accum) step=\(step) phase=\(e.phase.rawValue)")
            accum = 0
            lastAt = now
            if hasPhase { armed = false }
            onSwipe?(step)
        }
    }
}

struct SwipeScroll<Content: View>: NSViewRepresentable {
    let content: Content
    let onSwipe: (Int) -> Void
    let onHeight: (CGFloat) -> Void

    func makeNSView(context: Context) -> SwipeScrollView {
        let sv = SwipeScrollView()
        sv.hasVerticalScroller = false          // 用户不要侧边滚动条；触控板照样能滚
        sv.autohidesScrollers = true
        sv.drawsBackground = false
        sv.onSwipe = onSwipe
        let host = NSHostingView(rootView: content)
        host.translatesAutoresizingMaskIntoConstraints = false
        sv.documentView = host
        NSLayoutConstraint.activate([
            host.topAnchor.constraint(equalTo: sv.contentView.topAnchor),
            host.leadingAnchor.constraint(equalTo: sv.contentView.leadingAnchor),
            host.widthAnchor.constraint(equalTo: sv.contentView.widthAnchor)
        ])
        return sv
    }

    func updateNSView(_ sv: SwipeScrollView, context: Context) {
        sv.onSwipe = onSwipe
        if let host = sv.documentView as? NSHostingView<Content> {
            host.rootView = content
            let h = host.fittingSize.height
            DispatchQueue.main.async { onHeight(h) }          // 内容高度回传，外层据此定高
        }
    }
}

/// 面板能触发的动作（由 AppDelegate 注入；SwiftUI 视图自己关不了菜单，需要关的由闭包里 cancelTracking）
public struct PanelActions {
    /// 主线程读取常驻采集器已经生成的报告；面板不重复扫描日志和进程。
    public var latestReport: () -> ScanReport? = { nil }
    public var isVisible: () -> Bool = { true }
    public var cleanOrphans: () -> Void = {}
    public var cleanNPX: () -> Void = {}
    public var rescan: () -> Void = {}
    public var setAutoClean: (Bool) -> Void = { _ in }
    public var setLaunchAtLogin: (Bool) -> Void = { _ in }
    public var setThresholdNotify: (Bool) -> Void = { _ in }
    public var setExitChangeNotify: (Bool) -> Void = { _ in }
    public var setFontScale: (Double) -> Void = { _ in }
    public var installProxy: () -> Void = {}
    public var uninstallProxy: () -> Void = {}
    public var copyProxyPrefix: () -> Void = {}
    public var purgeLogs: () -> Void = {}
    /// Tab 切换后内容高度变了 → 让宿主按新 fittingSize 重排
    public var relayout: () -> Void = {}
    public var syncPrices: (@escaping (String, Bool) -> Void) -> Void = { completion in completion("", false) }
    public var quit: () -> Void = {}
    public init() {}
}

public struct PanelSettings {
    public var autoClean: Bool = false
    public var launchAtLogin: Bool = false
    public var thresholdNotify: Bool = true
    public var exitChangeNotify: Bool = true
    public var fontScale: Double = 1.0
    public init(autoClean: Bool = false, launchAtLogin: Bool = false, thresholdNotify: Bool = true, exitChangeNotify: Bool = true, fontScale: Double = 1.0) {
        self.autoClean = autoClean
        self.launchAtLogin = launchAtLogin
        self.thresholdNotify = thresholdNotify
        self.exitChangeNotify = exitChangeNotify
        self.fontScale = fontScale
    }
}

/// 全局「设备」作用域：本机 / 某台远程主机 / 全部（本机 + 所有远程）。
/// 只影响展示，不动任何采集口径；持久化成 "all" / "local" / "remote:<host>"。
public enum DeviceScope: Equatable {
    case all
    case local
    case remote(String)

    /// 持久化键：写进 @AppStorage("vg.device")。
    public var key: String {
        switch self {
        case .all: return "all"
        case .local: return "local"
        case .remote(let host): return "remote:\(host)"
        }
    }

    /// 反序列化。坏值（含空主机名）一律回落到「全部」，免得锁死在空视图。
    public static func from(key: String) -> DeviceScope {
        if key == "local" { return .local }
        if key.hasPrefix("remote:") {
            let host = String(key.dropFirst("remote:".count))
            return host.isEmpty ? .all : .remote(host)
        }
        return .all
    }

    /// 配置变了（那台主机被删了）→ 回落「全部」。
    public func resolved(hosts: [String]) -> DeviceScope {
        if case .remote(let host) = self, !hosts.contains(host) { return .all }
        return self
    }

    /// 某个历史来源是否属于当前设备。
    /// 远程 / 挂载来源都带设备后缀 `Claude · <设备>`（见 UsageHistory.device）；没后缀的（含 API · X 记账）都算本机。
    public static func includes(source: String, scope: DeviceScope, hosts: [String]) -> Bool {
        switch scope {
        case .all:
            return true
        case .local:
            return UsageHistory.device(of: source) == nil
        case .remote(let host):
            return UsageHistory.device(of: source) == host
        }
    }

    /// 有历史快照后，受支持的 CLI 统一使用已去重的当日记录（包括 archived / opencode）。
    /// 本机实时行仅在首次扫描前回退使用；API 代理不重复计入。
    static func todayUsage(local: [CLIUsage], history: [String: UsageHistory.Totals], scope: DeviceScope,
                           historyReady: Bool = true) -> [CLIUsage] {
        let labels = ["Claude": "Claude Code", "Codex": "Codex", "OpenCode": "opencode"]
        var rows: [CLIUsage]
        if case .remote = scope { rows = [] } else { rows = local }
        guard historyReady else { return rows }
        rows = rows.map { row in
            guard labels.values.contains(row.name) else { return row }
            var empty = CLIUsage(name: row.name)
            empty.note = L("今日暂无已采集用量", "No collected usage today")
            return empty
        }
        for source in history.keys.sorted() {
            guard !UsageHistory.isProxySource(source),
                  includes(source: source, scope: scope, hosts: []),
                  let label = labels[UsageHistory.cli(of: source)], let totals = history[source] else { continue }
            guard totals.turns > 0 || totals.tokenTotal > 0 else { continue }
            let index: Int
            if let existing = rows.firstIndex(where: { $0.name == label }) { index = existing }
            else { rows.append(CLIUsage(name: label)); index = rows.count - 1 }
            rows[index].ctx += totals.ctx
            rows[index].cacheRead += totals.cacheRead
            rows[index].out += totals.out
            rows[index].think += totals.think
            rows[index].requests += totals.turns
            rows[index].turns += totals.turns
            if rows[index].hasTokens { rows[index].note = "" }
        }
        return rows
    }
}

/// 菜单里的面板：顶部 Tab 切换（订阅 / API / 统计 / 网络 / 系统），高度随当前 Tab 内容自适应（实测 macOS 14 NSMenu 会跟着
/// 自定义视图的 frame 实时重排），只有超过屏幕可用高度才在内部滚动。
public struct DashboardView: View {
    @State public var report: ScanReport
    public var actions: PanelActions

    static var panelWidth: CGFloat { 420 * max(1, min(UITheme.fontScale, 1.3)) }
    /// 内容区上限：屏幕可用高度减去菜单外壳/Tab 栏/退出项；不到上限就按内容高度，超过才滚动
    static var maxContentHeight: CGFloat { max(300, (NSScreen.main?.visibleFrame.height ?? 900) - 170) }

    @AppStorage("vg.tab") private var tab: Int = 0
    @AppStorage("vg.device") private var deviceKey: String = "all"
    @AppStorage("vg.todayCLI") private var todayCLIKey: String = ""
    @State private var expandedCards: Set<String> = []
    @State private var measuredHeight: CGFloat = 400
    @State private var drillDown: String? = nil      // 非空 = 正在看某个平台的详情页
    @State private var autoCleanOn: Bool
    @State private var launchAtLoginOn: Bool
    @State private var notifyOn: Bool
    @State private var exitNotifyOn: Bool
    @State private var fontScaleOn: Double

    @State private var liveNow: Date = Date()
    @State private var network = NetworkSnapshot()
    @State private var history = UsageHistory.Snapshot()
    @State private var health = NerfReport()

    private let liveTicker = Timer.publish(every: 5.0, on: .main, in: .common).autoconnect()

    public init(report: ScanReport, settings: PanelSettings, actions: PanelActions) {
        self.init(report: report, settings: settings, actions: actions, preload: true)
    }

    /// preload：截图渲染模式（ImageRenderer 不跑 onAppear），把各后台快照直接塞进初始状态。
    init(report: ScanReport, settings: PanelSettings, actions: PanelActions, preload: Bool, drill: String? = nil) {
        Self.migrateTabSelection()
        _report = State(initialValue: report)
        self.actions = actions
        if preload {
            _history = State(initialValue: UsageHistory.shared.snapshot())
            _network = State(initialValue: NetworkScanner.shared.snapshot())
            _health = State(initialValue: NerfDetector.shared.snapshot())
            _drillDown = State(initialValue: drill)
        }
        _autoCleanOn = State(initialValue: settings.autoClean)
        _launchAtLoginOn = State(initialValue: settings.launchAtLogin)
        _notifyOn = State(initialValue: settings.thresholdNotify)
        _exitNotifyOn = State(initialValue: settings.exitChangeNotify)
        _fontScaleOn = State(initialValue: settings.fontScale)
    }

    /// 旧索引 2 是系统页；只迁移一次，之后用户主动选择统计页不会被改回去。
    static func migrateTabSelection(defaults: UserDefaults = .standard) {
        guard !defaults.bool(forKey: "vg.fiveTabsMigrated") else { return }
        if defaults.integer(forKey: "vg.tab") == 2 { defaults.set(4, forKey: "vg.tab") }
        defaults.set(true, forKey: "vg.fiveTabsMigrated")
    }

    private var nowTS: TimeInterval { liveNow.timeIntervalSince1970 }
    private var currentTokens: TokenStats { report.tokens }
    private var currentLLMs: [DetectedLLMRuntime] { report.detectedLLMs }
    private var currentAPI: ProxyStatus { report.api }
    private var currentCLI: [CLIUsage] { report.cliUsage }
    private var currentInteractions: [InteractionRecord] { Array(currentTokens.recentInteractions.prefix(3)) }

    /// 当前设备作用域（存储值 + 已配置主机名做一次回落，主机被删也不锁死在空视图）。
    private var deviceScope: DeviceScope { DeviceScope.from(key: deviceKey).resolved(hosts: report.remoteHosts) }
    private var isRemoteScope: Bool { if case .remote = deviceScope { return true }; return false }
    private var scopedForecasts: [String: CostForecast] {
        deviceScope == .all ? history.forecasts : history.forecastsByDevice[deviceScope.key] ?? [:]
    }
    private var scopedUnpricedCount: Int {
        Set(history.unpricedNamesBySource.filter {
            !UsageHistory.isProxySource($0.key) && DeviceScope.includes(source: $0.key, scope: deviceScope, hosts: report.remoteHosts)
        }.values.flatMap { $0 }).count
    }

    private var retainedHistoryNote: String? {
        let cachedSources = history.sourceNotes.keys.filter {
            UsageHistory.device(of: $0) != nil && history.totals[$0] != nil &&
                DeviceScope.includes(source: $0, scope: deviceScope, hosts: report.remoteHosts)
        }
        return cachedSources.isEmpty ? nil : L("含远端缓存；刷新状态见统计页", "Includes retained remote history; see Statistics for refresh status")
    }

    /// 与费用采用同一份当日记录，包含归档会话及远程设备。
    private var todayCLICandidates: [CLIUsage] {
        DeviceScope.todayUsage(local: currentCLI, history: history.currentDaySources(), scope: deviceScope,
                               historyReady: history.capturedAt > 0)
    }

    /// 今日 token（ctx+out）最多的 CLI；都为空就退回第一个。
    private var busiestTodayCLI: CLIUsage? {
        let list = todayCLICandidates
        return list.filter { $0.hasTokens }.max { ($0.ctx + $0.out) < ($1.ctx + $1.out) } ?? list.first
    }

    /// 手动选中的 CLI；选了但不在候选里（换设备/换主机）→ 自动跟随最忙的那个。
    private var selectedTodayCLI: CLIUsage? {
        if !todayCLIKey.isEmpty, let picked = todayCLICandidates.first(where: { $0.name == todayCLIKey }) { return picked }
        return busiestTodayCLI
    }

    /// Claude Code 专属的「按项目 / 最近交互」只在本地且选中 Claude Code 时出现。
    private var showClaudeExtras: Bool { deviceScope == .local && selectedTodayCLI?.name == "Claude Code" }

    /// API 上游 → 复用平台卡片：档位 = 套餐名或 "API Key"，额度条 / 余额 / 今日 token 叠加
    private var apiCards: [DetectedLLMRuntime] {
        currentAPI.providers.map { p in
            var tokens = ""
            if p.calls > 0 {
                let models = p.models.prefix(2).joined(separator: " / ") + (p.models.count > 2 ? " …" : "")
                tokens = "\(models) · 上下文 \(formatTokens(p.ctx)) · 输出 \(formatTokens(p.out))" + (p.ctx > 0 ? String(format: " · 命中 %.0f%%", p.cacheHitRate) : "")
            }
            // 上游在真实调用里给了限流头 → 拿来当余量显示（被动，不额外发请求）
            var headerLine = ""
            if let hw = p.headerWindow {
                let pct = hw.effectivePct(now: nowTS)
                headerLine = "限流 \(p.headerLabel) 已用 \(pct)%"
                if let c = Fmt.countdown(to: hw.resetsAt, now: nowTS) { headerLine += " · 重置 \(c)" }
            }
            let sub: String
            if !headerLine.isEmpty, p.balanceText.isEmpty, p.fiveHour == nil { sub = headerLine }
            else if !p.balanceText.isEmpty { sub = p.balanceText }
            else if !p.quotaError.isEmpty { sub = "额度: " + String(p.quotaError.prefix(24)) }   // 如"当前用户不存在coding plan"
            else { sub = p.calls > 0 ? "无额度接口 · 只记调用" : "今日无调用" }

            // 第四行：延迟 + 错误 + 花费，都从记账文件里已有的字段算，没有就不写
            var obs: [String] = []
            if p.p95ms > 0 { obs.append("p50 \(Fmt.ms(p.p50ms)) · p95 \(Fmt.ms(p.p95ms))") }
            if p.errors > 0 { obs.append(String(format: "%d 错(%.0f%%)", p.errors, p.errorRate) + (p.count429 > 0 ? " 含 \(p.count429) 限流" : "")) }
            if !p.cost.isEmpty { obs.append(Fmt.money(p.cost)) }
            return DetectedLLMRuntime(
                name: p.provider, isRunning: nowTS - p.lastTS < 120, tier: p.plan.isEmpty ? "API Key" : p.plan, detail: "\(p.calls) 次",
                fiveHour: p.fiveHour, sevenDay: p.sevenDay, quotaSubtitle: sub,
                extraLine: tokens, extraLine2: obs.joined(separator: " · "),
                quotaNote: p.quotaIsEstimate ? "估算 · " + p.estimateNote : "",
                platformDetail: apiDetail(p)
            )
        }
    }

    /// API 上游的详情页：把记账文件能证明的都列出来（延迟分位 / 错误 / 按 key 分账 / 模型）
    private func apiDetail(_ p: APIProviderStatus) -> PlatformDetail {
        var d = PlatformDetail()
        d.rows.append(("上游主机", p.host))
        if !p.plan.isEmpty { d.rows.append(("套餐", p.plan)) }
        d.rows.append(("今日调用", "\(p.calls) 次"))
        if p.p95ms > 0 {
            d.rows.append(("延迟 p50 / p95", "\(Fmt.ms(p.p50ms)) / \(Fmt.ms(p.p95ms))"))
            d.rows.append(("最慢一次", Fmt.ms(p.maxms)))
        }
        d.rows.append(("错误率", p.calls > 0 ? String(format: "%.1f%%（%d / %d）", p.errorRate, p.errors, p.calls) : "—"))
        if p.count429 > 0 { d.rows.append(("429 限流", "\(p.count429) 次")) }
        if p.ctx > 0 {
            d.rows.append(("输入 / 输出", "\(formatTokens(p.ctx)) / \(formatTokens(p.out))"))
            d.rows.append(("缓存命中", String(format: "%.0f%%（读 %@）", p.cacheHitRate, formatTokens(p.cacheRead))))
        }
        if p.quotaIsEstimate {
            d.rows.append(("额度口径", "估算：本机记账请求数 ÷ 套餐上限"))
            d.rows.append(("套餐上限", p.planLimitText))
            d.rows.append(("估算底数", p.estimateNote))
            d.rows.append(("注意", "走代理之外的调用算不进来，会偏低"))
        }
        if let m = p.monthly {
            d.rows.append(("月窗口", "\(m.effectivePct(now: nowTS))%" + (Fmt.countdown(to: m.resetsAt, now: nowTS).map { " · 重置 \($0)" } ?? "")))
        }
        if !p.cost.isEmpty {
            d.rows.append(("今日花费（估）", Fmt.money(p.cost) + (currentAPI.priceAsOf.isEmpty ? "" : " · 价目表 \(currentAPI.priceAsOf)")))
        } else if p.calls > 0 {
            d.rows.append(("今日花费", currentAPI.hasPriceTable ? "该模型不在价目表里" : "未配置价目表"))
        }
        if let hw = p.headerWindow {
            var v = "已用 \(hw.effectivePct(now: nowTS))%（按 \(p.headerLabel)）"
            if let c = Fmt.countdown(to: hw.resetsAt, now: nowTS) { v += " · 重置 \(c)" }
            if let age = hw.ageSeconds(now: nowTS) { v += " · 取自 \(Fmt.agoShort(age))的调用" }
            d.rows.append(("限流余量（响应头）", v))
        }
        if !p.models.isEmpty { d.rows.append(("模型", p.models.joined(separator: ", "))) }
        if !p.balanceText.isEmpty { d.rows.append(("余额", p.balanceText)) }
        if !p.quotaError.isEmpty { d.rows.append(("额度接口", p.quotaError)) }
        for k in p.keys {
            var v = "\(k.calls) 次"
            if k.errors > 0 { v += " · \(k.errors) 错" }
            if k.ctx > 0 { v += " · \(formatTokens(k.ctx))→\(formatTokens(k.out))" }
            if !k.cost.isEmpty { v += " · " + Fmt.money(k.cost) }
            d.rows.append(("key \(k.fingerprint)", v))
        }
        d.sourceFiles = ["~/.config/vibegauge/api-calls.jsonl", "~/.config/vibegauge/api-quota.json"]
        if currentAPI.hasPriceTable { d.sourceFiles.append("~/.config/vibegauge/prices.json") }
        if p.quotaIsEstimate { d.sourceFiles.append("~/.config/vibegauge/plans.json") }
        return d
    }

    private func secondsAgo(_ timestamp: TimeInterval) -> Int {
        max(0, Int(nowTS - timestamp))
    }

    private func isRecentInteraction(timestamp: TimeInterval) -> Bool {
        secondsAgo(timestamp) < 120
    }

    private func tierColor(_ tier: String) -> Color {
        if tier.contains("API") { return .blue }
        if tier.contains("本地") { return .purple }
        if tier.isEmpty || tier.contains("未登录") { return .secondary }
        return .green
    }

    /// 0% 绿 → 100% 红 连续渐变。平方让曲线后段变色更快：
    /// 50% 已是黄绿、70% 黄、85% 橙、95%+ 红 —— 旧版"除了 100% 全是绿"没有识别度。
    /// 饱和度/亮度固定，深浅色模式下都能看清。
    private func quotaColor(_ pct: Int) -> Color {
        let p = Double(max(0, min(100, pct))) / 100.0
        return Color(hue: 0.33 * (1.0 - p * p), saturation: 0.82, brightness: 0.82)
    }

    private struct ModelDisplayGroup: Identifiable {
        let id: String
        let isFullWidth: Bool
        let models: [DetectedLLMRuntime]
    }

    private var modelDisplayGroups: [ModelDisplayGroup] {
        var groups: [ModelDisplayGroup] = []
        var currentRegular: [DetectedLLMRuntime] = []

        for llm in currentLLMs {
            if llm.isFullWidth {
                if !currentRegular.isEmpty {
                    groups.append(ModelDisplayGroup(id: "reg-\(groups.count)", isFullWidth: false, models: currentRegular))
                    currentRegular = []
                }
                groups.append(ModelDisplayGroup(id: "full-\(llm.id)", isFullWidth: true, models: [llm]))
            } else {
                currentRegular.append(llm)
            }
        }
        if !currentRegular.isEmpty {
            groups.append(ModelDisplayGroup(id: "reg-\(groups.count)", isFullWidth: false, models: currentRegular))
        }
        return groups
    }

    private func formatTokens(_ count: Int64) -> String {
        if count >= 100_000_000 {
            return String(format: "%.2f 亿", Double(count) / 100_000_000.0)
        } else if count >= 10_000 {
            return String(format: "%.1f 万", Double(count) / 10_000.0)
        } else {
            return "\(count)"
        }
    }

    private func formatTokensInt(_ count: Int) -> String {
        formatTokens(Int64(count))
    }

    private func refreshLive() {
        // 只读缓存，避免与常驻 8 秒采集重复执行文件遍历、ps 和 API 汇总。
        let latestNetwork = NetworkScanner.shared.snapshot()
        if network != latestNetwork { network = latestNetwork }
        let latestHistory = UsageHistory.shared.snapshot()
        if history.capturedAt != latestHistory.capturedAt || history.isScanning != latestHistory.isScanning ||
           history.processedFiles != latestHistory.processedFiles || history.totalFiles != latestHistory.totalFiles { history = latestHistory }
        let latestHealth = NerfDetector.shared.snapshot()
        if health.capturedAt != latestHealth.capturedAt { health = latestHealth }
        if let latest = actions.latestReport() {
            report = latest
        }
    }

    /// 底栏：原来挂在系统菜单里的「同步价格 / 字号 / 退出」，收进面板，风格与卡片一致。
    private var footerBar: some View {
        HStack(spacing: 4) {
            FooterButton(symbol: "tag", title: L("模型价格", "Prices")) { openPrices() }
            FooterButton(symbol: "textformat.size",
                         title: UITheme.presets.first { abs($0.value - fontScaleOn) < 0.001 }?.title ?? "字号") {
                let presets = UITheme.presets
                let i = presets.firstIndex { abs($0.value - fontScaleOn) < 0.001 } ?? 1
                let next = presets[(i + 1) % presets.count].value
                fontScaleOn = next
                actions.setFontScale(next)
                actions.relayout()
            }
            .help("点一下切换字号：小 / 标准 / 大 / 特大 / 超大")
            Spacer(minLength: 0)
            FooterButton(symbol: "power", title: "退出", tint: .red) { actions.quit() }
        }
        .padding(.top, 6)
        .overlay(alignment: .top) { Rectangle().fill(VG.stroke).frame(height: 0.5) }
    }

    private let gridCols = [
        GridItem(.flexible(), spacing: 6),
        GridItem(.flexible(), spacing: 6)
    ]

    // MARK: - 外壳

    public var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            headerBar

            // 设备切换：只在配了远程主机 / 挂载目录时出现，选了就整页跟着走
            if !report.remoteHosts.isEmpty && drillDown == nil {
                deviceSelectorRow
            }

            SwipeScroll(
                content: tabContent.frame(width: Self.panelWidth - 28, alignment: .leading),
                onSwipe: { step in
                    guard drillDown == nil else { return }   // 详情页里不响应滑动，只用「返回」按钮
                    let next = max(0, min(4, tab + step))
                    if next != tab { tab = next }
                },
                onHeight: { h in if abs(h - measuredHeight) > 1 { measuredHeight = h } }
            )
            .frame(width: Self.panelWidth - 28, height: min(max(measuredHeight, 360), Self.maxContentHeight))

            footerBar
        }
        .padding(.horizontal, 14)
        .padding(.top, 12)
        .padding(.bottom, 10)
        .frame(width: Self.panelWidth)
        .onChange(of: tab) { _, _ in actions.relayout() }
        .onChange(of: measuredHeight) { _, _ in actions.relayout() }
        .onChange(of: drillDown) { _, _ in actions.relayout() }
        .onReceive(liveTicker) { date in
            guard actions.isVisible() else { return }
            liveNow = date
            refreshLive()
        }
        .onAppear { refreshLive() }
    }

    /// 顶栏：应用标识 + 当前页摘要 + 模型健康胶囊 + 刷新；下面一条整宽分段控件。详情页换成「返回」。
    private var headerBar: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 9) {
                if let name = drillDown {
                    Button(action: { withAnimation(.easeInOut(duration: 0.15)) { drillDown = nil } }) {
                        Label("返回", systemImage: "chevron.left").font(VG.font(12, .medium))
                    }
                    .buttonStyle(.borderless)
                    Text(name == Self.healthPage ? L("模型检查", "Model checks") : name == Self.pricesPage ? L("模型价格", "Model prices") : name).font(VG.headline).lineLimit(1)
                } else {
                    VGIcon(symbol: "gauge.with.dots.needle.67percent", tint: .accentColor, size: 26)
                    VStack(alignment: .leading, spacing: 1) {
                        Text("VibeGauge").font(VG.headline)
                        Text(tabStatusText).font(VG.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
                Spacer(minLength: 6)
                if drillDown == nil {
                    Button(action: openHealth) {
                        VGPill(text: L("模型检查", "Model checks"), tint: .secondary,
                               symbol: health.status == .alert || health.status == .watch ? "info.circle" : "checkmark.shield")
                    }
                    .buttonStyle(.plain)
                    .help(L("本机近期会话：", "Recent local sessions: ") + health.headline)
                }
                Button(action: rescanAll) {
                    Image(systemName: "arrow.clockwise")
                        .font(VG.font(11, .semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 26, height: 26)
                        .background(Circle().fill(VG.fillStrong))
                }
                .buttonStyle(.plain)
                .help("重新扫描（进程 / 用量 / 降智检测）")
            }
            if drillDown == nil {
                Picker("", selection: $tab) {
                    Text(L("概览", "Overview")).tag(0)
                    Text("API").tag(1)
                    Text("统计").tag(2)
                    Text("网络").tag(3)
                    Text("系统").tag(4)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(maxWidth: .infinity)
                .help("也可以在面板上用触控板左右滑动切换")
            }
        }
    }

    /// 截图用：顶栏 + 当前页内容，不含 NSScrollView（ImageRenderer 画不了 AppKit 视图）。
    var renderBody: some View {
        VStack(alignment: .leading, spacing: 10) {
            headerBar
            if !report.remoteHosts.isEmpty && drillDown == nil { deviceSelectorRow }
            tabContent.frame(width: Self.panelWidth - 28, alignment: .leading)
            footerBar
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .frame(width: Self.panelWidth)
    }

    static let healthPage = "__health"
    static let pricesPage = "__prices"

    private func openHealth() {
        withAnimation(.easeInOut(duration: 0.15)) { drillDown = Self.healthPage }
    }

    private func openPrices() {
        withAnimation(.easeInOut(duration: 0.15)) { drillDown = Self.pricesPage }
    }

    private func rescanAll() {
        actions.rescan()
        UsageHistory.shared.refreshSoon()
        DispatchQueue.global(qos: .userInitiated).async {
            let report = NerfDetector.shared.refreshNow(history: UsageHistory.shared.snapshot())
            DispatchQueue.main.async { self.health = report }
        }
    }

    /// 当前页内容（不含滚动容器）：面板里包在 SwipeScroll 里，渲染截图时直接用。
    @ViewBuilder
    var tabContent: some View {
        VStack(alignment: .leading, spacing: 10) {
            if drillDown == Self.healthPage {
                HealthDetailView(report: health, rescan: rescanAll)
            } else if drillDown == Self.pricesPage {
                PricingDetailView(history: history, syncPrices: actions.syncPrices)
            } else if let name = drillDown, let llm = (currentLLMs + apiCards).first(where: { $0.name == name }) {
                detailPage(for: llm)
            } else {
                switch tab {
                case 1:
                    remoteScopeNote
                    apiSection
                case 2: StatsTabView(snapshot: history, scope: deviceScope, hosts: report.remoteHosts)
                case 3:
                    remoteScopeNote
                    NetworkTabView(snapshot: network, onRetest: { NetworkScanner.shared.forceRefresh() }, width: Self.panelWidth - 28)
                case 4:
                    remoteScopeNote
                    actionSection
                    hardwareSection
                    diskSection
                    devicesSection
                    settingsSection
                default: aiSection
                }
            }
        }
    }

    /// Tab 栏右侧只留紧凑摘要，五个入口仍能在菜单栏宽度内完整显示。
    private var tabStatusText: String {
        let active = currentLLMs.filter { $0.isRunning }.count
        let calls = currentAPI.providers.reduce(0) { $0 + $1.calls }
        switch tab {
        case 1: return "今日 \(calls) 次"
        case 2: return history.isScanning ? "汇总中" : (deviceScope == .all ? "\(history.activeDays) 活跃天" : "按设备统计")
        case 3: return "\(network.aiExits.filter { !$0.isGemini && !$0.ip.isEmpty && $0.error.isEmpty }.count)/4 出口"
        case 4: return "\(active) 平台活跃"
        default: return deviceScope == .all ? L("设备额度与今日用量", "Device quotas and today's usage") : L("按设备查看", "Viewing one device")
        }
    }

    private var tabStatusLine: some View {
        Text(tabStatusText)
            .font(VG.scaled(8.5))
            .foregroundColor(.secondary)
            .lineLimit(1)
    }

    // MARK: - 设备切换器

    /// Tab 栏正下方的设备胶囊行；只在有远程主机时渲染。
    private var deviceSelectorRow: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 4) {
                Image(systemName: "desktopcomputer")
                    .font(VG.scaled(8))
                    .foregroundColor(.secondary)
                deviceChip(L("所有设备", "All devices"), scope: .all)
                deviceChip(L("本机", "Local"), scope: .local)
                ForEach(report.remoteHosts, id: \.self) { host in
                    deviceChip(RemoteCollector.displayName(for: host), scope: .remote(host))
                }
            }
        }
        .scrollIndicators(.hidden)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// 与 Tab/字号按钮同款的胶囊：选中填充强调色，未选中灰底。
    private func deviceChip(_ label: String, scope: DeviceScope) -> some View {
        let active = deviceScope == scope
        return Button(action: {
            deviceKey = scope.key
            actions.relayout()
        }) {
            Text(label)
                .font(VG.scaled(8.5, weight: active ? .bold : .medium))
                .foregroundColor(active ? .white : .secondary)
                .lineLimit(1)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(active ? Color.accentColor : Color.secondary.opacity(0.12))
                .clipShape(Capsule())
        }
        .buttonStyle(.plain)
    }

    /// API / 网络 / 系统这三页只统计本机；选了远程设备时在页首如实说明。
    @ViewBuilder
    private var remoteScopeNote: some View {
        if case .remote(let host) = deviceScope {
            HStack(spacing: 4) {
                Image(systemName: "info.circle")
                    .font(VG.scaled(8))
                    .foregroundColor(.secondary)
                Text("该页只统计本机（\(host) 未采集）")
                    .font(VG.scaled(8.5))
                    .foregroundColor(.secondary)
                    .lineLimit(2)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .vgFill(0.08, radius: 6)
        }
    }

    // MARK: - Tab 系统：物理硬件 + MCP/NPX

    private var hardwareSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                VGIcon(symbol: "cpu.fill", tint: .gray)
                Text("系统与硬件").font(VG.headline)
                Spacer()
                Text("发热: \(report.thermalStateString)")
                    .font(VG.scaled(9.5, weight: .medium))
                    .foregroundColor(report.thermalStateString == "正常" ? .secondary : .orange)
            }

            // 内存
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline) {
                    Text("内存")
                        .font(VG.scaled(11, weight: .medium))
                    Spacer()
                    Text(String(format: "已用 %.1f / %.1f GB", report.usedMemoryGB, report.totalMemoryGB))
                        .font(VG.scaled(10.5))
                        .foregroundColor(.secondary)
                    Text("\(report.freePercentage)% 可用")
                        .font(VG.scaled(9.5, weight: .bold))
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1.5)
                        .background(report.freePercentage >= 60 ? Color.green.opacity(0.18) : Color.orange.opacity(0.18))
                        .foregroundColor(report.freePercentage >= 60 ? .green : .orange)
                        .clipShape(Capsule())
                }

                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        RoundedRectangle(cornerRadius: 2.5)
                            .fill(Color.secondary.opacity(0.18))
                            .frame(height: 5)
                        let usedRatio = max(0.02, min(1.0, 1.0 - Double(report.freePercentage) / 100.0))
                        RoundedRectangle(cornerRadius: 2.5)
                            .fill(report.freePercentage >= 60 ? Color.green : Color.orange)
                            .frame(width: geo.size.width * CGFloat(usedRatio), height: 5)
                    }
                }
                .frame(height: 5)

                HStack(spacing: 4) {
                    let compStr = report.compressorGB > 1.0
                        ? String(format: "%.2f GB", report.compressorGB)
                        : "\(Int(report.compressorGB * 1024)) MB"
                    let swapStr = report.swapUsedGB > 1.0
                        ? String(format: "%.2f GB", report.swapUsedGB)
                        : "\(Int(report.swapUsedGB * 1024)) MB"
                    Text("压缩池 \(compStr)")
                    Text("·")
                    Text("Swap \(swapStr)")
                }
                .font(VG.scaled(9))
                .foregroundColor(.secondary)
            }

            // 磁盘
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("磁盘")
                        .font(VG.scaled(11, weight: .medium))
                    Spacer()
                    Text(String(format: "剩余 %.1f GB / %.1f GB (%.0f%%)", report.diskFreeGB, report.diskTotalGB, report.diskFreePct))
                        .font(VG.scaled(10))
                        .foregroundColor(.secondary)
                }

                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        RoundedRectangle(cornerRadius: 2.5)
                            .fill(Color.secondary.opacity(0.18))
                            .frame(height: 5)
                        let usedRatio = report.diskTotalGB > 0 ? max(0.02, min(1.0, (report.diskTotalGB - report.diskFreeGB) / report.diskTotalGB)) : 0.5
                        RoundedRectangle(cornerRadius: 2.5)
                            .fill(Color.blue.opacity(0.85))
                            .frame(width: geo.size.width * CGFloat(usedRatio), height: 5)
                    }
                }
                .frame(height: 5)

                HStack {
                    Text(String(format: "CPU 负载: %.2f (1m) · %.2f (5m)", report.loadAvg1m, report.loadAvg5m))
                    Spacer()
                }
                .font(VG.scaled(9))
                .foregroundColor(.secondary)
            }

            Divider().opacity(0.35)

            // MCP 与开发缓存
            HStack {
                let mcpMemStr = report.activeMCPTotalMemMB > 1024
                    ? String(format: "%.1f GB", report.activeMCPTotalMemMB / 1024.0)
                    : "\(Int(report.activeMCPTotalMemMB)) MB"
                HStack(spacing: 3) {
                    Text("活跃 MCP:")
                        .foregroundColor(.secondary)
                    Text("\(report.activeMCPProcessCount) 进程 (\(mcpMemStr))")
                        .foregroundColor(.primary)
                }
                Spacer()
                let npxStr = report.npxCacheMB > 1024
                    ? String(format: "%.1f GB", report.npxCacheMB / 1024.0)
                    : "\(Int(report.npxCacheMB)) MB"
                HStack(spacing: 3) {
                    Text("NPX 缓存:")
                        .foregroundColor(.secondary)
                    Text(npxStr)
                        .foregroundColor(.primary)
                }
            }
            .font(VG.scaled(9))

            if report.totalOrphanCount > 0 {
                VStack(alignment: .leading, spacing: 3) {
                    Text("断链孤儿 \(report.totalOrphanCount) 个 · \(Int(report.totalOrphanMemMB)) MB")
                        .font(VG.scaled(9, weight: .semibold))
                        .foregroundColor(.orange)
                    ForEach(report.orphanedGroups) { g in
                        HStack {
                            Text(g.serviceName)
                            Spacer()
                            Text("\(g.processCount) 个 · \(Int(g.totalMemMB)) MB")
                        }
                        .font(VG.scaled(8.5))
                        .foregroundColor(.secondary)
                    }
                }
            }
        }
        .padding(10)
        .vgFill(0.06, radius: 8)
    }

    // MARK: - Tab 订阅：平台矩阵 + 今日 Token + 最近交互

    /// Start with individual quota readings across devices; cost remains an estimate below usage.
    private var aiSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            UnifiedQuotaSection(report: report, scope: deviceScope, now: nowTS,
                                openLocal: { name in drillDown = name },
                                openDevice: { host in deviceKey = DeviceScope.remote(host).key; actions.relayout() })
            if case .remote(let host) = deviceScope {
                remoteDeviceSection(host: host).vgCard()
            } else {
                localAISection.vgCard()
            }
            OverviewStrip(forecasts: scopedForecasts, capturedAt: history.capturedAt, unpricedCount: scopedUnpricedCount,
                          coverageNote: retainedHistoryNote,
                          openStats: { tab = 2 }, openPrices: openPrices)
        }
    }

    private var localAISection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                VGIcon(symbol: "chart.bar.fill", tint: .blue)
                Text(L("今日用量", "Today's usage")).font(VG.headline)
                Spacer()
                let activeCount = currentLLMs.filter { $0.isRunning }.count
                HStack(spacing: 4) {
                    Circle()
                        .fill(activeCount > 0 ? Color.green : Color.secondary.opacity(0.4))
                        .frame(width: 5, height: 5)
                    Text(L("本机 \(activeCount) 个平台在线", "\(activeCount) local platforms online"))
                        .font(VG.scaled(9.5, weight: .medium))
                        .foregroundColor(.secondary)
                }
            }

            todayContextBlock

            DisclosureGroup(L("本机平台详情", "Local platform details")) {
            VStack(spacing: 5) {
                ForEach(modelDisplayGroups) { group in
                    if group.isFullWidth {
                        if let model = group.models.first {
                            fullWidthModelCard(for: model)
                        }
                    } else {
                        HStack(alignment: .top, spacing: 6) {
                            ForEach(group.models) { llm in
                                modelCard(for: llm).frame(maxWidth: .infinity, alignment: .topLeading)
                            }
                        }
                    }
                }
            }
            .padding(.top, 6)
            }
            .font(VG.caption).foregroundStyle(.secondary)

            // 最近交互（最多 3 轮）
            if showClaudeExtras && !currentInteractions.isEmpty {
                let hasLive = currentInteractions.contains { isRecentInteraction(timestamp: $0.timestamp) }

                VStack(alignment: .leading, spacing: 5) {
                    HStack {
                        HStack(spacing: 4) {
                            Circle()
                                .fill(hasLive ? Color.green : Color.secondary.opacity(0.4))
                                .frame(width: 5, height: 5)

                            Text(hasLive ? "实时捕获" : "最近交互")
                                .font(VG.scaled(9.5, weight: .bold))
                                .foregroundColor(hasLive ? .primary : .secondary)
                        }

                        Spacer()

                        Text("最新 \(currentInteractions.count) 轮")
                            .font(VG.scaled(8))
                            .foregroundColor(.secondary)
                    }

                    VStack(spacing: 4) {
                        ForEach(currentInteractions) { item in
                            interactionRow(for: item)
                        }
                    }
                }
                .padding(8)
                .vgFill(0.06, radius: 7)
            }
        }
    }

    /// 今日上下文：跟随当前设备今日 token（ctx+out）最多的 CLI，可手动切换；指标口径与本机 Claude 版一致。
    @ViewBuilder
    private var todayContextBlock: some View {
        VStack(alignment: .leading, spacing: 5) {
            if let u = selectedTodayCLI {
                HStack {
                    Text(L("今日输入 · \(u.name)", "Today's input · \(u.name)"))
                        .font(VG.scaled(10, weight: .medium))
                        .foregroundColor(.secondary)
                    Text(u.hasTokens ? formatTokens(u.ctx) : "—")
                        .font(VG.scaled(10.5, weight: .bold))
                        .foregroundColor(.primary)
                        .help(L("当日累计输入，包含缓存；不是单次请求的上下文长度。", "Daily cumulative input including cache; not a single request's context length."))
                    Spacer()
                    if u.hasTokens {
                        Text(String(format: "缓存率 %.1f%%", u.cacheHitRate))
                            .font(VG.scaled(9.5, weight: .semibold))
                            .foregroundColor(u.cacheHitRate >= 80 ? .green : .secondary)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1.5)
                            .background(u.cacheHitRate >= 80 ? Color.green.opacity(0.15) : Color.secondary.opacity(0.12))
                            .clipShape(Capsule())
                    }
                }

                if u.hasTokens {
                    HStack(alignment: .top, spacing: 12) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(L("新输入", "Fresh input")).font(VG.caption).foregroundStyle(.secondary)
                            Text(formatTokens(max(0, u.ctx - u.cacheRead))).font(VG.number(15))
                        }
                        VStack(alignment: .leading, spacing: 2) {
                            Text(L("缓存读取", "Cached input")).font(VG.caption).foregroundStyle(.secondary)
                            Text(formatTokens(u.cacheRead)).font(VG.number(15)).foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 0)
                    }
                    .help(L("新输入包含首次写入缓存的内容；输入累计中已包含缓存读取。", "Fresh input includes cache creation. Total input already includes cache reads."))
                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            RoundedRectangle(cornerRadius: 2)
                                .fill(Color.secondary.opacity(0.18))
                                .frame(height: 4)
                            let hitRatio = max(0.01, min(1.0, u.cacheHitRate / 100.0))
                            RoundedRectangle(cornerRadius: 2)
                                .fill(Color.green.opacity(0.85))
                                .frame(width: geo.size.width * CGFloat(hitRatio), height: 4)
                        }
                    }
                    .frame(height: 4)

                    HStack {
                        Text(L("输出 \(formatTokens(u.out)) · 其中思考 \(formatTokens(u.think))", "Output \(formatTokens(u.out)) · includes \(formatTokens(u.think)) reasoning"))
                            .font(VG.scaled(8.5))
                            .foregroundColor(.secondary)
                        Spacer()
                        Text("今日 \(u.requests) 次调用")
                            .font(VG.scaled(8.5, weight: .medium))
                            .foregroundColor(.secondary)
                    }
                } else {
                    Text(u.turns > 0 ? "\(u.turns) 轮 · \(u.note)" : u.note)
                        .font(VG.scaled(8.5))
                        .foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                if todayCLICandidates.count > 1 { todayCLIChipRow }
                if deviceScope == .all {
                    Text(L("已采集日志 · 本机与远程设备合计", "Collected logs · local and remote devices combined"))
                        .font(VG.caption).foregroundStyle(.secondary)
                }
                if let note = retainedHistoryNote {
                    Text(note).font(VG.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                // 列表和上方选中的 CLI 使用同一个设备范围。
                if !isRemoteScope && !todayCLICandidates.isEmpty {
                    Divider().opacity(0.25)
                    VStack(alignment: .leading, spacing: 4) {
                        let activeRows = todayCLICandidates.filter { $0.hasTokens || $0.turns > 0 || $0.requests > 0 }
                        if activeRows.count > 1 || expandedCards.contains("__idleCLI") {
                            ForEach(todayCLICandidates.filter { $0.hasTokens || $0.turns > 0 || $0.requests > 0 || expandedCards.contains("__idleCLI") }) { row in
                                VStack(alignment: .leading, spacing: 3) {
                                    HStack {
                                        Text(row.name).font(VG.font(11, .semibold)).foregroundStyle(.primary)
                                        Spacer()
                                        Text(row.hasTokens ? L("\(row.requests) 次请求", "\(row.requests) requests") : row.turns > 0 ? L("\(row.turns) 轮", "\(row.turns) turns") : "")
                                            .font(VG.caption).foregroundStyle(.secondary)
                                    }
                                    if row.hasTokens {
                                        HStack {
                                            Text(L("输入 \(formatTokens(row.ctx)) · 输出 \(formatTokens(row.out))", "Input \(formatTokens(row.ctx)) · output \(formatTokens(row.out))"))
                                            Spacer(minLength: 4)
                                            Text(String(format: L("缓存 %.0f%%", "Cache %.0f%%"), row.cacheHitRate))
                                                .foregroundStyle(row.cacheHitRate >= 80 ? Color.green : .secondary)
                                        }
                                        .font(VG.caption).foregroundStyle(.secondary).lineLimit(1).minimumScaleFactor(0.85)
                                    } else {
                                        Text(row.note).font(VG.caption).foregroundStyle(.secondary)
                                            .fixedSize(horizontal: false, vertical: true)
                                    }
                                }
                                .padding(.vertical, 4)
                            }
                        }
                        let idleCount = todayCLICandidates.filter { !$0.hasTokens && $0.turns == 0 && $0.requests == 0 }.count
                        if idleCount > 0 {
                            Button {
                                if expandedCards.contains("__idleCLI") { expandedCards.remove("__idleCLI") }
                                else { expandedCards.insert("__idleCLI") }
                                actions.relayout()
                            } label: {
                                Label(expandedCards.contains("__idleCLI") ? L("收起空闲工具", "Hide idle tools") : L("查看 \(idleCount) 个空闲工具", "Show \(idleCount) idle tools"),
                                      systemImage: expandedCards.contains("__idleCLI") ? "chevron.up" : "chevron.down")
                                    .font(VG.caption).foregroundStyle(.secondary)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }

                // 今日按项目（工作目录）归因：只在本机且选中 Claude Code 时
                if showClaudeExtras && !currentTokens.todayByProject.isEmpty {
                    Divider().opacity(0.25)
                    let projects = currentTokens.todayByProject
                    let top = expandedCards.contains("__proj") ? Array(projects.prefix(8)) : Array(projects.prefix(3))
                    let maxCtx = max(1, projects.first?.ctx ?? 1)
                    VStack(alignment: .leading, spacing: 2.5) {
                        HStack {
                            Text("按项目")
                                .font(VG.scaled(8, weight: .bold))
                                .foregroundColor(.secondary)
                            Spacer()
                            if projects.count > 3 {
                                Button(action: {
                                    if expandedCards.contains("__proj") { expandedCards.remove("__proj") } else { expandedCards.insert("__proj") }
                                }) {
                                    Text(expandedCards.contains("__proj") ? "收起" : "另 \(projects.count - 3) 个")
                                        .font(VG.scaled(7.5))
                                        .foregroundColor(.blue)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        ForEach(top) { p in
                            HStack(spacing: 4) {
                                Text(p.name)
                                    .font(VG.scaled(8.5, weight: .medium))
                                    .lineLimit(1)
                                    .frame(width: 96, alignment: .leading)
                                MiniProgressBar(value: Double(p.ctx) / Double(maxCtx), color: .blue.opacity(0.75), width: 46, height: 3.5)
                                Text(formatTokens(p.ctx))
                                    .font(VG.scaled(8))
                                    .foregroundColor(.secondary)
                                    .fixedSize()
                                Spacer(minLength: 2)
                                Text(p.clis.joined(separator: "+"))
                                    .font(VG.scaled(7.5))
                                    .foregroundColor(.secondary.opacity(0.8))
                                    .fixedSize()
                                Text("\(p.turns) 轮")
                                    .font(VG.scaled(7.5))
                                    .foregroundColor(.secondary)
                                    .fixedSize()
                            }
                            .help(p.path)
                        }
                    }
                }
            } else {
                Text("今日还没有可用量记录")
                    .font(VG.scaled(8.5))
                    .foregroundColor(.secondary)
            }
        }
    }

    /// 手动切换今日上下文的 CLI；存 "vg.todayCLI"，空 = 跟随最忙的。
    private var todayCLIChipRow: some View {
        HStack(spacing: 4) {
            ForEach(todayCLICandidates) { u in
                let active = selectedTodayCLI?.name == u.name
                Button(action: {
                    todayCLIKey = u.name
                    actions.relayout()
                }) {
                    Text(u.name)
                        .font(VG.scaled(8, weight: active ? .bold : .regular))
                        .foregroundColor(active ? .white : .secondary)
                        .lineLimit(1)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1.5)
                        .background(active ? Color.accentColor : Color.secondary.opacity(0.12))
                        .clipShape(Capsule())
                }
                .buttonStyle(.plain)
            }
            Spacer(minLength: 0)
        }
    }

    // MARK: - 订阅页 · 远程设备分区

    /// 选了某台远程主机：只展示采集器能拿到的（opencode / Codex / Claude），拿不到的如实说明。
    @ViewBuilder
    private func remoteDeviceSection(host: String) -> some View {
        let today = historyTodayRows(host)
        let hostSources = history.totals.filter { UsageHistory.device(of: $0.key) == host }
        let total: UsageHistory.Totals? = hostSources.isEmpty ? nil : hostSources.values.reduce(into: UsageHistory.Totals()) { $0.merge($1) }
        let cost = history.costBySource.filter { UsageHistory.device(of: $0.key) == host }.values
            .reduce(into: [String: Double]()) { acc, v in for (k, x) in v { acc[k, default: 0] += x } }
        let todayCost = history.todayCostBySource.filter { UsageHistory.device(of: $0.key) == host }.values
            .reduce(into: [String: Double]()) { acc, v in for (k, x) in v { acc[k, default: 0] += x } }
        let unpriced = history.unpricedBySource.filter { UsageHistory.device(of: $0.key) == host }.values.reduce(0, +)
        let isMount = UsageHistory.mountRoots().contains { $0.label == host }
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                VGIcon(symbol: "desktopcomputer", tint: .blue)
                Text(L("设备 · \(RemoteCollector.displayName(for: host))", "Device · \(RemoteCollector.displayName(for: host))")).font(VG.headline)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
                VGPill(text: isMount ? "挂载目录" : "SSH 采集", tint: .blue, symbol: isMount ? "externaldrive.connected.to.line.below" : "network")
            }

            HStack(spacing: 6) {
                remoteMetric("历史用量", total.map { Fmt.tokens($0.tokenTotal) + " token" } ?? "暂无记录",
                             total.map { "\($0.sessions) 会话 · \($0.turns) 请求" } ?? "等待历史采集")
                remoteMetric("API 等价成本", total == nil ? "暂无记录" : (cost.isEmpty ? "未定价" : Fmt.money(cost)),
                             unpriced > 0 ? "\(unpriced) 个模型未定价 · 今天 \(Fmt.money(todayCost))" : "今天 \(Fmt.money(todayCost))")
            }

            if today.isEmpty {
                Text("该设备今日还没有采集到 CLI 用量")
                    .font(VG.scaled(8.5))
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                todayContextBlock
                Divider().opacity(0.25)
                remoteCLIList(today)
            }

            let notes = Array(Set(["Claude", "Codex", "OpenCode"].compactMap { history.sourceNotes["\($0) · \(host)"] })).sorted()
            if !notes.isEmpty {
                Text(notes.joined(separator: " · "))
                    .font(VG.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Text(isMount ? "直接读挂载目录里的 .claude / .codex 日志，口径与本机一致。" : "每 5 分钟经 ssh 增量拉取 Claude / Codex / opencode 的逐条记录，按请求时间归到每一天；成本按内置官方价或你的价目表。")
                .font(VG.scaled(8))
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func remoteMetric(_ title: String, _ value: String, _ detail: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(VG.scaled(8.5)).foregroundColor(.secondary)
            Text(value).font(VG.scaled(12, weight: .semibold, design: .rounded))
                .lineLimit(2).minimumScaleFactor(0.85)
            Text(detail).font(VG.scaled(8)).foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(8)
        .vgFill(0.07, radius: 7)
    }

    /// 远程设备今日各 CLI 一张紧凑卡片：输入、输出、次数和缓存命中率。
    @ViewBuilder
    private func remoteCLIList(_ rows: [CLIUsage]) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text("今日各 CLI")
                .font(VG.scaled(9, weight: .bold))
                .foregroundColor(.secondary)
            ForEach(rows) { u in
                VStack(alignment: .leading, spacing: 3) {
                    HStack {
                        Text(u.name)
                            .font(VG.scaled(9, weight: .semibold))
                        Spacer()
                        Text("\(u.requests) 次")
                            .font(VG.scaled(8.5))
                            .foregroundColor(.secondary)
                    }
                    HStack(spacing: 6) {
                        Text("输入 \(Fmt.tokens(u.ctx))")
                        Text("输出 \(Fmt.tokens(u.out))")
                        Spacer(minLength: 0)
                        if u.ctx > 0 {
                            Text(String(format: "缓存 %.0f%%", u.cacheHitRate))
                                .foregroundColor(u.cacheHitRate >= 80 ? .green : .secondary)
                        }
                    }
                    .font(VG.scaled(8.5))
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
                .vgFill(0.06, radius: 6)
            }
        }
    }

    // MARK: - Tab API：API Key 调用（经记账代理）

    private var apiSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                VGIcon(symbol: "key.horizontal.fill", tint: .blue)
                Text("API Key 调用").font(VG.headline)
                Spacer()
                let api = currentAPI
                HStack(spacing: 4) {
                    Circle()
                        .fill(api.running ? Color.green : (api.installed ? Color.orange : Color.secondary.opacity(0.4)))
                        .frame(width: 5, height: 5)
                    Text(api.running ? "代理运行中 · :\(api.port)" : (api.installed ? "代理已安装，未在跑" : "代理未安装"))
                        .font(VG.scaled(9.5, weight: .medium))
                        .foregroundColor(api.installed && !api.running ? .orange : .secondary)
                }
            }

            if apiCards.isEmpty {
                Text(currentAPI.installed
                     ? "还没有调用经过代理。把别名里的 BASE_URL 前面加上 http://127.0.0.1:\(currentAPI.port)/ 即可记账。"
                     : "菜单里「安装 API 记账代理」，再把别名里的 BASE_URL 前面加上 http://127.0.0.1:\(currentAPI.port)/ 即可记账。")
                    .font(VG.scaled(8.5))
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                LazyVGrid(columns: gridCols, spacing: 5) {
                    ForEach(apiCards) { card in
                        modelCard(for: card)
                    }
                }
            }

            Divider().opacity(0.35)

            // 记账覆盖体检：有 BASE_URL 没走代理 = 面板上看不到那些调用
            let cov = currentAPI.coverage
            if !cov.entries.isEmpty {
                HStack(spacing: 5) {
                    Image(systemName: cov.directCount > 0 ? "exclamationmark.triangle" : "checkmark.seal")
                        .font(VG.scaled(8))
                        .foregroundColor(cov.directCount > 0 ? .orange : .green)
                    Text("记账覆盖 \(cov.proxiedCount)/\(cov.entries.count) 处")
                        .font(VG.scaled(9, weight: .medium))
                    if cov.directCount > 0 {
                        Text("· 未接：" + cov.entries.filter { !$0.proxied }.prefix(3).map { $0.host }.joined(separator: " "))
                            .font(VG.scaled(8))
                            .foregroundColor(.orange)
                            .lineLimit(1)
                    }
                    Spacer()
                }
                .help(cov.entries.map { "\($0.proxied ? "✓" : "✗") \($0.name) → \($0.host)  (\($0.file):\($0.line))" }.joined(separator: "\n"))
            }

            // 代理控制
            HStack(spacing: 8) {
                if currentAPI.installed {
                    Text("代理前缀 http://127.0.0.1:\(currentAPI.port)/")
                        .font(VG.scaled(8.5))
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                    Spacer()
                    Button(action: actions.copyProxyPrefix) { Text("复制").font(VG.scaled(9)) }
                        .buttonStyle(.plain).foregroundColor(.blue)
                    Button(action: actions.uninstallProxy) { Text("停止并卸载").font(VG.scaled(9)) }
                        .buttonStyle(.plain).foregroundColor(.secondary)
                } else {
                    Text("代理未安装（LaunchAgent，登录自启，不依赖本 App）")
                        .font(VG.scaled(8.5))
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                    Spacer()
                    Button(action: actions.installProxy) { Text("安装并启动").font(VG.scaled(9, weight: .semibold)) }
                        .buttonStyle(.plain).foregroundColor(.blue)
                }
            }
        }
        .padding(10)
        .vgFill(0.06, radius: 8)
    }

    // MARK: - Tab 系统：磁盘占用（会话日志治理）

    private var diskSection: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 8) {
                VGIcon(symbol: "internaldrive.fill", tint: .gray)
                Text("磁盘占用").font(VG.headline)
                Spacer()
                Text(String(format: "AI 工具目录合计 %.1f GB", report.diskTotalAIGB))
                    .font(VG.scaled(9.5))
                    .foregroundColor(.secondary)
            }

            ForEach(report.disk.prefix(6)) { d in
                HStack(spacing: 5) {
                    Image(systemName: d.purgeable ? "clock.arrow.circlepath" : "lock")
                        .font(VG.scaled(7.5))
                        .foregroundColor(d.purgeable ? .blue.opacity(0.8) : .secondary.opacity(0.6))
                    Text(d.label)
                        .font(VG.scaled(9.5, weight: .medium))
                        .lineLimit(1)
                    Spacer()
                    if d.purgeable, d.oldMB >= 1 {
                        Text(String(format: "旧 %.0f MB", d.oldMB))
                            .font(VG.scaled(8.5, weight: .semibold))
                            .foregroundColor(.orange)
                    }
                    Text(sizeText(d.totalMB))
                        .font(VG.scaled(9.5))
                        .foregroundColor(.secondary)
                        .frame(width: 72, alignment: .trailing)
                }
                .help(d.note)
            }

            if report.purgeableMB >= 100 {
                Button(action: actions.purgeLogs) {
                    HStack {
                        Image(systemName: "trash").font(VG.scaled(9))
                        Text(String(format: "清理 %d 天前的会话记录 · %@", ProcessScanner.shared.logRetentionDays, sizeText(report.purgeableMB)))
                            .font(VG.scaled(10, weight: .semibold))
                        Spacer()
                        Text("移入废纸篓").font(VG.scaled(8)).foregroundColor(.secondary)
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
                    .background(Color.orange.opacity(0.14))
                    .foregroundColor(.orange)
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                }
                .buttonStyle(.plain)
            }

            Text("🔒 = 只统计不清理（运行库 / 插件 / 你的产物）")
                .font(VG.scaled(8))
                .foregroundColor(.secondary)
        }
        .padding(10)
        .vgFill(0.06, radius: 8)
    }

    private func sizeText(_ mb: Double) -> String {
        mb >= 1024 ? String(format: "%.2f GB", mb / 1024) : String(format: "%.0f MB", mb)
    }

    /// 远程 / 挂载设备今天各 CLI 的用量：取自历史汇总（按请求时间归日，≤5 分钟旧）。
    private func historyTodayRows(_ host: String) -> [CLIUsage] {
        DeviceScope.todayUsage(local: [], history: history.currentDaySources(), scope: .remote(host))
    }

    // MARK: - Tab 系统：设备与数据源

    private var devicesSection: some View {
        let hosts = RemoteCollector.hosts()
        let mounts = UsageHistory.mountRoots()
        return VStack(alignment: .leading, spacing: 8) {
            VGSectionHeader(title: "设备与数据源", symbol: "externaldrive.connected.to.line.below.fill", tint: .blue) {
                Text("\(hosts.count + mounts.count + 1) 台").font(VG.caption).foregroundStyle(.secondary)
            }
            VGKeyValue(key: "本机", value: "~/.claude · ~/.config/claude · ~/.codex（含 archived）· opencode")
            ForEach(hosts, id: \.self) { host in
                let note = history.sourceNotes["Codex · \(host)"]
                VGKeyValue(key: RemoteCollector.displayName(for: host), value: note ?? "SSH · Claude / Codex / opencode",
                           valueColor: note == nil ? .primary : .secondary)
            }
            ForEach(mounts.indices, id: \.self) { i in
                let m = mounts[i]
                VGKeyValue(key: m.label, value: FileManager.default.fileExists(atPath: m.path) ? "挂载 · \(m.path)" : "目录不在：\(m.path)",
                           valueColor: FileManager.default.fileExists(atPath: m.path) ? .primary : .orange)
            }
            Text("WSL / Linux 两种接法：能免密 ssh 就加到 remoteHosts；已经把那台机器的家目录挂到本机（SMB / sshfs / \\\\wsl$）就加到 mountRoots。")
                .font(VG.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(#"defaults write com.haifeng.vibegauge remoteHosts "user@wsl-host""#, forType: .string)
                } label: { Label("复制 SSH 配置命令", systemImage: "doc.on.doc").font(VG.font(11)) }
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(#"defaults write com.haifeng.vibegauge mountRoots "wsl=/Volumes/wsl/home/you""#, forType: .string)
                } label: { Label("复制挂载配置命令", systemImage: "doc.on.doc").font(VG.font(11)) }
            }
            .buttonStyle(.borderless)
        }
        .vgCard()
    }

    // MARK: - Tab 系统：设置

    private var settingsSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            VGSectionHeader("设置", symbol: "gearshape.fill", tint: .gray)
            fontRow
            settingRow("定时自动清理", detail: "每 30 分钟 + 睡醒后 + 内存 ≥85% 时静默巡检",
                       isOn: Binding(get: { autoCleanOn }, set: { autoCleanOn = $0; actions.setAutoClean($0) }))
            settingRow("登录时自动启动", detail: "随 macOS 登录常驻菜单栏",
                       isOn: Binding(get: { launchAtLoginOn }, set: { launchAtLoginOn = $0; actions.setLaunchAtLogin($0) }))
            settingRow("阈值通知", detail: "额度 80/95%、内存 85/93%、磁盘 90/96% 越线时提醒一次",
                       isOn: Binding(get: { notifyOn }, set: { notifyOn = $0; actions.setThresholdNotify($0) }))
            settingRow("出口变化通知", detail: "AI 出口 IP 或国家变化时提醒，每家 10 分钟最多一次",
                       isOn: Binding(get: { exitNotifyOn }, set: { exitNotifyOn = $0; actions.setExitChangeNotify($0) }))
        }
        .padding(10)
        .vgFill(0.06, radius: 8)
    }

    /// 字号是全局倍率：改完顺手 relayout，让宿主按新的 fittingSize 重排面板高度。
    private var fontRow: some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 1) {
                Text("字体大小").font(VG.scaled(9.5, weight: .medium))
                Text("整个面板的字号倍率，立即生效").font(VG.scaled(8)).foregroundColor(.secondary)
            }
            Spacer()
            HStack(spacing: 3) {
                ForEach(UITheme.presets, id: \.title) { preset in
                    Button(preset.title) {
                        fontScaleOn = preset.value
                        actions.setFontScale(preset.value)
                        actions.relayout()
                    }
                    .buttonStyle(.plain)
                    .font(VG.scaled(8.5, weight: abs(fontScaleOn - preset.value) < 0.001 ? .bold : .regular))
                    .foregroundColor(abs(fontScaleOn - preset.value) < 0.001 ? Color.accentColor : Color.secondary)
                }
            }
        }
        .padding(.vertical, 2)
    }

    private func settingRow(_ title: String, detail: String, isOn: Binding<Bool>) -> some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(VG.scaled(9.5, weight: .medium))
                Text(detail).font(VG.scaled(8)).foregroundColor(.secondary)
            }
            Spacer()
            Toggle("", isOn: isOn)
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.mini)
        }
        .padding(.vertical, 2)
    }

    // MARK: - Tab 系统：清理动作

    @ViewBuilder
    private var actionSection: some View {
        if report.totalOrphanCount > 0 || report.npxCacheMB > 100 {
            VStack(spacing: 5) {
                if report.totalOrphanCount > 0 {
                    Button(action: actions.cleanOrphans) {
                        HStack {
                            Text("清理断链 AI 残留进程")
                                .font(VG.scaled(10.5, weight: .medium))
                                .foregroundColor(.primary)
                            Spacer()
                            let memStr = report.totalOrphanMemMB > 1024
                                ? String(format: "%.2f GB", report.totalOrphanMemMB / 1024.0)
                                : "\(Int(report.totalOrphanMemMB)) MB"
                            Text(memStr)
                                .font(VG.scaled(9.5, weight: .bold))
                                .foregroundColor(.white)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Color.red.opacity(0.8))
                                .clipShape(Capsule())
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .vgFill(0.12, radius: 6)
                    }
                    .buttonStyle(.plain)
                }

                if report.npxCacheMB > 100 {
                    Button(action: actions.cleanNPX) {
                        HStack {
                            Text("清理 NPX 临时工具缓存")
                                .font(VG.scaled(10.5, weight: .medium))
                                .foregroundColor(.primary)
                            Spacer()
                            let npxStr = report.npxCacheMB > 1024
                                ? String(format: "%.2f GB", report.npxCacheMB / 1024.0)
                                : "\(Int(report.npxCacheMB)) MB"
                            Text(npxStr)
                                .font(VG.scaled(9.5, weight: .semibold))
                                .foregroundColor(.secondary)
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .vgFill(0.08, radius: 6)
                    }
                    .buttonStyle(.plain)
                }
            }
        } else {
            HStack {
                Circle()
                    .fill(Color.green)
                    .frame(width: 5, height: 5)
                Text("AI 与系统运行环境健康，暂无残留垃圾")
                    .font(VG.scaled(9.5))
                    .foregroundColor(.secondary)
                Spacer()
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
        }
    }

    // MARK: - 最近交互单行

    @ViewBuilder
    private func interactionRow(for item: InteractionRecord) -> some View {
        let isLive = isRecentInteraction(timestamp: item.timestamp)
        let secs = secondsAgo(item.timestamp)
        let timeAgo = secs < 8 ? "刚刚 · 实时" : Fmt.ago(secs)

        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 4) {
                Circle()
                    .fill(isLive ? Color.green : Color.secondary.opacity(0.35))
                    .frame(width: 4.5, height: 4.5)

                Text(Fmt.modelDisplayName(item.model))
                    .font(VG.scaled(9, weight: .semibold))
                    .foregroundColor(.primary)
                    .lineLimit(1)

                Text("(\(timeAgo))")
                    .font(VG.scaled(7.5))
                    .foregroundColor(isLive ? .green : .secondary)
                    .lineLimit(1)
                    .fixedSize()

                Spacer(minLength: 4)

                HStack(spacing: 3) {
                    MiniProgressBar(
                        value: item.cacheHitRate / 100.0,
                        color: item.cacheHitRate >= 80 ? .green : (item.cacheHitRate > 50 ? .blue : .secondary),
                        width: 20,
                        height: 3
                    )
                    Text(String(format: "%.1f%%", item.cacheHitRate))
                        .font(VG.scaled(8.5, weight: .bold))
                        .foregroundColor(item.cacheHitRate >= 80 ? .green : .primary)
                        .lineLimit(1)
                        .fixedSize()
                    Text("命中")
                        .font(VG.scaled(7))
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                        .fixedSize()
                }
            }

            HStack(spacing: 3.5) {
                Text("上下文 \(formatTokensInt(item.contextTokens))")
                Text("·")
                Text("输出 \(formatTokensInt(item.outputTokens))")
                if item.thinkingTokens > 0 {
                    Text("·")
                    Text("思考 \(formatTokensInt(item.thinkingTokens))")
                }
            }
            .font(VG.scaled(8))
            .foregroundColor(.secondary)
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 4.5)
        .vgFill(0.04, radius: 5)
    }

    // MARK: - 额度子组件

    /// "5H ▮▮ 12%" 一组
    @ViewBuilder
    private func quotaBar(label: String, win: QuotaWindow) -> some View {
        let pct = max(0, min(100, win.usedPct))
        let state = QuotaReadingState.evaluate(win, now: nowTS)
        let current = state == .current
        HStack(spacing: 3) {
            Text(label)
                .font(VG.scaled(7.5, weight: .medium))
                .foregroundColor(.secondary)
                .lineLimit(1)
                .fixedSize()
            if state != .reset {
                MiniProgressBar(value: Double(pct) / 100.0, color: current ? quotaColor(pct) : .secondary, width: 16, height: 3.5)
            }
            Text(state == .reset ? L("待刷新", "Awaiting update") : current ? "\(pct)%" : L("\(pct)% · 上次", "\(pct)% · last"))
                .font(VG.scaled(7.5, weight: .bold))
                .foregroundColor(current && pct >= 60 ? quotaColor(pct) : .secondary)
                .lineLimit(1)
                .fixedSize()
            if current && pct >= 100 {
                Text("耗尽")
                    .font(VG.scaled(7, weight: .semibold))
                    .foregroundColor(.red.opacity(0.85))
                    .lineLimit(1)
                    .fixedSize()
            }
        }
    }

    @ViewBuilder
    private func dot() -> some View {
        Text("·")
            .font(VG.scaled(7))
            .foregroundColor(.secondary)
            .fixedSize()
    }

    /// 脚注内容：各窗口重置倒计时 + 按池分别标数据新鲜度（>5 分钟才标）
    private func footerParts(for llm: DetectedLLMRuntime) -> (resets: String, stale: String) {
        let sp = llm.secondaryPoolName
        let windows: [(String, QuotaWindow?)] = [
            ("5H", llm.fiveHour), ("W", llm.sevenDay), ("\(sp)5H", llm.secondaryFiveHour), ("\(sp)W", llm.secondarySevenDay)
        ]
        let resets = windows.compactMap { label, w -> String? in
            guard let w = w, let c = Fmt.countdown(to: w.resetsAt, now: nowTS) else { return nil }
            return "\(label) \(c)"
        }
        var stale: [String] = []
        if let a = [llm.fiveHour, llm.sevenDay].compactMap({ $0?.ageSeconds(now: nowTS) }).max(), a > 300 {
            stale.append("记录于 \(Fmt.agoShort(a))")
        }
        if let a = [llm.secondaryFiveHour, llm.secondarySevenDay].compactMap({ $0?.ageSeconds(now: nowTS) }).max(), a > 300 {
            stale.append("\(sp) 记录于 \(Fmt.agoShort(a))")
        }
        return (resets.isEmpty ? "" : "重置 " + resets.joined(separator: " · "), stale.joined(separator: " · "))
    }

    /// 「按当前节奏会不会超额」——挑最吃紧的那个窗口，一直显示，不只是超额时才提示。
    /// 超额的窗口优先；都不超额就显示离满最近的那个。
    private func burnLine(for llm: DetectedLLMRuntime) -> (text: String, over: Bool)? {
        let wins: [(String, QuotaWindow?)] = [("5h", llm.fiveHour), ("周", llm.sevenDay),
                                              ("\(llm.secondaryPoolName)5h", llm.secondaryFiveHour),
                                              ("\(llm.secondaryPoolName)周", llm.secondarySevenDay)]
        var best: (label: String, burn: Burn)? = nil
        for (label, w) in wins {
            guard let w = w, QuotaReadingState.evaluate(w, now: nowTS) == .current,
                  let b = w.burn(now: nowTS), b.isRecent else { continue }
            if best == nil || b.projectedAtReset > best!.burn.projectedAtReset { best = (label, b) }
        }
        guard let (label, b) = best else { return nil }
        if let at = b.exhaustAt, let eta = Fmt.countdown(to: at, now: nowTS) {
            return ("\(label) 按当前节奏 \(eta) 后打满（重置时 \(b.projectedAtReset)%）", true)
        }
        return ("\(label) 按当前节奏，到重置 \(b.projectedAtReset)%", false)
    }

    /// 第三行脚注：节奏预测 + 重置/陈旧提示，可换两行，不截断
    @ViewBuilder
    private func quotaFooter(for llm: DetectedLLMRuntime) -> some View {
        let parts = footerParts(for: llm)
        if let b = burnLine(for: llm) {
            Text((b.over ? "⚡ " : "→ ") + b.text)
                .font(VG.scaled(7))
                .foregroundColor(b.over ? .orange : .secondary)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
        }
        if !parts.resets.isEmpty || !parts.stale.isEmpty {
            (Text(parts.resets)
                + Text(parts.resets.isEmpty || parts.stale.isEmpty ? "" : " · ")
                + Text(parts.stale).foregroundColor(.orange))
                .font(VG.scaled(7))
                .foregroundColor(.secondary)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// 一个套餐多模型额度：按已用 % 降序，只显示 3 个，其余"另 N 个"展开
    @ViewBuilder
    private func subQuotaRows(for llm: DetectedLLMRuntime) -> some View {
        if !llm.subQuotas.isEmpty {
            let sorted = llm.subQuotas.sorted { $0.window.effectivePct(now: nowTS) > $1.window.effectivePct(now: nowTS) }
            let expanded = expandedCards.contains(llm.id)
            let shown = expanded ? sorted : Array(sorted.prefix(3))
            VStack(alignment: .leading, spacing: 2) {
                ForEach(shown) { q in
                    HStack(spacing: 3) {
                        Text(q.name)
                            .font(VG.scaled(7.5))
                            .foregroundColor(.secondary)
                            .lineLimit(1)
                        Spacer(minLength: 2)
                        quotaBar(label: "", win: q.window)
                    }
                }
                if sorted.count > 3 {
                    Button(action: {
                        if expanded { expandedCards.remove(llm.id) } else { expandedCards.insert(llm.id) }
                    }) {
                        Text(expanded ? "收起 ▴" : "另 \(sorted.count - 3) 个 ▾")
                            .font(VG.scaled(7.5))
                            .foregroundColor(.blue)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.top, 1)
        }
    }

    @ViewBuilder
    private func cardHeader(for llm: DetectedLLMRuntime) -> some View {
        HStack(spacing: 3.5) {
            Circle()
                .fill(llm.isRunning ? Color.green : Color.secondary.opacity(0.3))
                .frame(width: 5, height: 5)

            Text(llm.name)
                .font(VG.scaled(10, weight: .semibold))
                .foregroundColor(llm.isRunning ? .primary : .secondary)
                .lineLimit(1)
                .fixedSize()
                .layoutPriority(1)

            if !llm.tier.isEmpty {
                Text(llm.tier)
                    .font(VG.scaled(7.5, weight: .bold))
                    .padding(.horizontal, 3.5)
                    .padding(.vertical, 1)
                    .background(tierColor(llm.tier).opacity(0.18))
                    .foregroundColor(tierColor(llm.tier))
                    .clipShape(Capsule())
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
            }

            Spacer(minLength: 2)

            Text(llm.detail)
                .font(VG.scaled(8.5, weight: llm.isRunning ? .medium : .regular))
                .foregroundColor(llm.isRunning ? .secondary : .secondary.opacity(0.75))
                .lineLimit(1)
                .fixedSize()
        }
    }

    // 普通卡片（双列）
    @ViewBuilder
    private func modelCard(for llm: DetectedLLMRuntime) -> some View {
        VStack(alignment: .leading, spacing: 3.5) {
            cardHeader(for: llm)

            if llm.hasQuota {
                HStack(spacing: 3) {
                    if let fh = llm.fiveHour { quotaBar(label: "5H", win: fh) }
                    if let sd = llm.sevenDay {
                        if llm.fiveHour != nil { dot() }
                        quotaBar(label: "W", win: sd)
                    }
                }
                quotaFooter(for: llm)
                if !llm.quotaNote.isEmpty {
                    Text(llm.quotaNote)
                        .font(VG.scaled(7.5))
                        .foregroundColor(.orange.opacity(0.85))      // 橙色 = 这数是估的，不是厂商给的
                        .lineLimit(1)
                }
            } else {
                Text(llm.quotaSubtitle.isEmpty ? (llm.isRunning ? "服务就绪" : "未启动") : llm.quotaSubtitle)
                    .font(VG.scaled(8))
                    .foregroundColor(.secondary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if !llm.extraLine.isEmpty {
                Text(llm.extraLine)
                    .font(VG.scaled(7.5))
                    .foregroundColor(.secondary)
                    .lineLimit(1)
            }
            if !llm.extraLine2.isEmpty {
                Text(llm.extraLine2)
                    .font(VG.scaled(7.5))
                    .foregroundColor(llm.extraLine2.contains("错") ? .orange : .secondary)
                    .lineLimit(1)
            }
            subQuotaRows(for: llm)
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 5)
        .vgFill(llm.isRunning ? 0.08 : 0.03, radius: 6)
        .contentShape(Rectangle())
        .onTapGesture { openDetail(llm) }
    }

    // 整行卡片（双池：原生池 + 三方池）
    @ViewBuilder
    private func fullWidthModelCard(for llm: DetectedLLMRuntime) -> some View {
        VStack(alignment: .leading, spacing: 4.5) {
            cardHeader(for: llm)

            HStack(spacing: 6) {
                if llm.fiveHour != nil || llm.sevenDay != nil {
                    HStack(spacing: 3.5) {
                        if let fh = llm.fiveHour { quotaBar(label: "5H", win: fh) }
                        if let sd = llm.sevenDay {
                            if llm.fiveHour != nil { dot() }
                            quotaBar(label: "W", win: sd)
                        }
                    }
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3.5)
                    .vgFill(0.06, radius: 4)
                    .fixedSize(horizontal: true, vertical: false)
                }

                Spacer(minLength: 4)

                if llm.secondaryFiveHour != nil || llm.secondarySevenDay != nil {
                    HStack(spacing: 3) {
                        Text(llm.secondaryPoolName)
                            .font(VG.scaled(7.5, weight: .bold))
                            .foregroundColor(.secondary)
                            .lineLimit(1)
                            .fixedSize()
                        if let fh = llm.secondaryFiveHour { quotaBar(label: "5H", win: fh) }
                        if let sd = llm.secondarySevenDay {
                            if llm.secondaryFiveHour != nil { dot() }
                            quotaBar(label: "W", win: sd)
                        }
                    }
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3.5)
                    .vgFill(0.06, radius: 4)
                    .fixedSize(horizontal: true, vertical: false)
                }
            }

            quotaFooter(for: llm)
            subQuotaRows(for: llm)
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 5)
        .vgFill(llm.isRunning ? 0.08 : 0.03, radius: 6)
        .contentShape(Rectangle())
        .onTapGesture { openDetail(llm) }
    }

    // MARK: - 详情页

    /// 大号额度环：外圈已用比例，中间百分比，下面窗口名 + 重置倒计时
    @ViewBuilder
    private func quotaRing(label: String, win: QuotaWindow, size: CGFloat = 78) -> some View {
        let pct = max(0, min(100, win.usedPct))
        let state = QuotaReadingState.evaluate(win, now: nowTS)
        let color = state == .current ? quotaColor(pct) : Color.secondary
        VStack(spacing: 4) {
            ZStack {
                Circle()
                    .stroke(Color.secondary.opacity(0.18), lineWidth: 7)
                if state != .reset { Circle()
                    .trim(from: 0, to: max(0.004, Double(pct) / 100.0))
                    .stroke(color, style: StrokeStyle(lineWidth: 7, lineCap: .round))
                    .rotationEffect(.degrees(-90)) }
                VStack(spacing: 0) {
                    Text(state == .reset ? "—" : "\(pct)")
                        .font(VG.scaled(21, weight: .bold, design: .rounded))
                        .foregroundColor(pct > 80 ? color : .primary)
                    Text(state == .reset ? L("待刷新", "Awaiting update") : state == .current ? L("% 已用", "% used") : L("% 上次记录", "% last reading"))
                        .font(VG.scaled(7))
                        .foregroundColor(.secondary)
                }
            }
            .frame(width: size, height: size)

            Text(label)
                .font(VG.scaled(9.5, weight: .semibold))
            if let c = Fmt.countdown(to: win.resetsAt, now: nowTS) {
                Text("重置 \(c)")
                    .font(VG.scaled(8))
                    .foregroundColor(.secondary)
            }
            if let a = win.ageSeconds(now: nowTS) {
                Text("记录于 \(Fmt.agoShort(a))")
                    .font(VG.scaled(7.5))
                    .foregroundColor(a > 300 ? .orange : .secondary.opacity(0.75))
            }
        }
    }

    private func sectionTitle(_ t: String) -> some View {
        Text(t)
            .font(VG.scaled(9.5, weight: .bold))
            .foregroundColor(.secondary)
    }

    private func card<T: View>(@ViewBuilder _ content: () -> T) -> some View {
        VStack(alignment: .leading, spacing: 6) { content() }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(10)
            .vgFill(0.06, radius: 8)
    }

    @ViewBuilder
    private func detailPage(for llm: DetectedLLMRuntime) -> some View {
        let d = llm.platformDetail

        // 1. 额度环
        if llm.hasQuota {
            card {
                HStack(alignment: .top, spacing: 0) {
                    if let fh = llm.fiveHour {
                        quotaRing(label: "5 小时窗口", win: fh).frame(maxWidth: .infinity)
                    }
                    if let sd = llm.sevenDay {
                        quotaRing(label: llm.name == "Grok" ? "周窗口" : "7 天窗口", win: sd).frame(maxWidth: .infinity)
                    }
                    if let sf = llm.secondaryFiveHour {
                        quotaRing(label: "\(llm.secondaryPoolName) 5H", win: sf).frame(maxWidth: .infinity)
                    }
                    if let sw = llm.secondarySevenDay {
                        quotaRing(label: "\(llm.secondaryPoolName)池 周", win: sw).frame(maxWidth: .infinity)
                    }
                }
            }
        }

        // 1.5 燃烧速率（窗口长度已知才算：本窗口迄今的平均速度）
        let burns: [(String, Burn)] = [("5 小时", llm.fiveHour), ("周", llm.sevenDay),
                                       ("\(llm.secondaryPoolName) 5 小时", llm.secondaryFiveHour),
                                       ("\(llm.secondaryPoolName) 周", llm.secondarySevenDay)]
            .compactMap { label, w in w?.burn(now: nowTS).map { (label, $0) } }
        if !burns.isEmpty {
            card {
                sectionTitle("燃烧速率（优先按近期节奏）")
                ForEach(Array(burns.enumerated()), id: \.offset) { _, item in
                    let b = item.1
                    HStack(spacing: 4) {
                        Text(item.0).font(VG.scaled(9)).foregroundColor(.secondary).lineLimit(1)
                        Spacer(minLength: 4)
                        Text(String(format: "%.1f%%/小时", b.pctPerHour))
                            .font(VG.scaled(9, weight: .semibold))
                        Text(b.basis)
                            .font(VG.scaled(7.5))
                            .foregroundColor(b.isRecent ? .blue.opacity(0.85) : .secondary)
                        Text("→ 重置时 \(b.projectedAtReset)%")
                            .font(VG.scaled(8.5))
                            .foregroundColor(b.projectedAtReset >= 100 ? .orange : .secondary)
                        if let at = b.exhaustAt, let eta = Fmt.countdown(to: at, now: nowTS) {
                            Text("· \(eta) 后打满")
                                .font(VG.scaled(8.5, weight: .semibold))
                                .foregroundColor(.orange)
                                .fixedSize()
                        }
                    }
                }
            }
        }

        // 2. 其他额度桶（Codex 的 Spark 等）
        if !d.extraPools.isEmpty {
            card {
                sectionTitle("其他额度桶（主卡未显示）")
                ForEach(Array(d.extraPools.enumerated()), id: \.offset) { _, item in
                    HStack(spacing: 4) {
                        Text(item.0).font(VG.scaled(9)).foregroundColor(.secondary).lineLimit(1)
                        Spacer(minLength: 4)
                        quotaBar(label: "", win: item.1)
                        if let c = Fmt.countdown(to: item.1.resetsAt, now: nowTS) {
                            Text(c).font(VG.scaled(7.5)).foregroundColor(.secondary).fixedSize()
                        }
                    }
                }
            }
        }

        // 3. 订阅 / 账号信息
        if !d.rows.isEmpty {
            card {
                HStack {
                    sectionTitle("订阅与账号")
                    Spacer()
                    if !llm.tier.isEmpty {
                        Text(llm.tier)
                            .font(VG.scaled(8, weight: .bold))
                            .padding(.horizontal, 4).padding(.vertical, 1)
                            .background(tierColor(llm.tier).opacity(0.18))
                            .foregroundColor(tierColor(llm.tier))
                            .clipShape(Capsule())
                    }
                }
                ForEach(Array(d.rows.enumerated()), id: \.offset) { _, row in
                    HStack(alignment: .top, spacing: 6) {
                        Text(row.0)
                            .font(VG.scaled(8.5))
                            .foregroundColor(.secondary)
                            .frame(width: 96, alignment: .leading)
                        Text(row.1)
                            .font(VG.scaled(8.5, design: .monospaced))
                            .foregroundColor(.primary)
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 0)
                    }
                }
            }
        }

        // 4. 活跃会话
        if !d.sessions.isEmpty {
            card {
                HStack {
                    sectionTitle("活跃会话")
                    Spacer()
                    Text("\(d.sessions.count) 个").font(VG.scaled(8)).foregroundColor(.secondary)
                }
                ForEach(d.sessions) { se in
                    VStack(alignment: .leading, spacing: 1) {
                        HStack(spacing: 4) {
                            Circle().fill(Color.green).frame(width: 4, height: 4)
                            Text(shortPath(se.cwd))
                                .font(VG.scaled(8.5, weight: .medium))
                                .lineLimit(1)
                                .truncationMode(.head)
                            Spacer(minLength: 4)
                            Text(Fmt.agoShort(se.startedAgo).replacingOccurrences(of: "前", with: ""))
                                .font(VG.scaled(8)).foregroundColor(.secondary).fixedSize()
                            Text(String(format: "%.0f MB", se.memMB))
                                .font(VG.scaled(8)).foregroundColor(.secondary).fixedSize()
                        }
                        Text("pid \(se.pid)")
                            .font(VG.scaled(7, design: .monospaced))
                            .foregroundColor(.secondary.opacity(0.7))
                    }
                    .padding(.vertical, 1)
                }
            }
        }

        // 5. 今日用量（该平台自己的）
        if let u = currentCLI.first(where: { $0.name.hasPrefix(llm.name) || llm.name.hasPrefix($0.name.replacingOccurrences(of: " Code", with: "")) }) {
            card {
                sectionTitle("今日用量")
                if u.hasTokens {
                    HStack(spacing: 0) {
                        detailMetric("上下文", formatTokens(u.ctx))
                        detailMetric("输出", formatTokens(u.out))
                        detailMetric("思考", formatTokens(u.think))
                        detailMetric("调用", "\(u.requests)")
                    }
                    HStack(spacing: 4) {
                        Text("缓存命中").font(VG.scaled(8)).foregroundColor(.secondary)
                        GeometryReader { geo in
                            ZStack(alignment: .leading) {
                                RoundedRectangle(cornerRadius: 2).fill(Color.secondary.opacity(0.18)).frame(height: 5)
                                RoundedRectangle(cornerRadius: 2).fill(Color.green.opacity(0.85))
                                    .frame(width: geo.size.width * CGFloat(max(0.01, min(1, u.cacheHitRate / 100))), height: 5)
                            }
                        }
                        .frame(height: 5)
                        Text(String(format: "%.1f%%", u.cacheHitRate))
                            .font(VG.scaled(8, weight: .bold)).fixedSize()
                    }
                } else {
                    Text(u.turns > 0 ? "\(u.turns) 轮 · \(u.note)" : u.note)
                        .font(VG.scaled(8.5)).foregroundColor(.secondary)
                }
            }
        }

        // 6. 数据来源
        if !d.sourceFiles.isEmpty {
            VStack(alignment: .leading, spacing: 2) {
                sectionTitle("数据来源（只读本机文件）")
                ForEach(d.sourceFiles, id: \.self) { f in
                    Text(f).font(VG.scaled(7.5, design: .monospaced)).foregroundColor(.secondary.opacity(0.8)).lineLimit(1)
                }
            }
            .padding(.horizontal, 4)
        }
    }

    private func detailMetric(_ label: String, _ value: String) -> some View {
        VStack(spacing: 1) {
            Text(value).font(VG.scaled(12, weight: .bold, design: .rounded))
            Text(label).font(VG.scaled(7.5)).foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity)
    }

    /// /Users/x/Desktop/code/foo → ~/…/code/foo
    private func shortPath(_ p: String) -> String {
        var s = p.replacingOccurrences(of: FileManager.default.homeDirectoryForCurrentUser.path, with: "~")
        let parts = s.split(separator: "/")
        if parts.count > 3 { s = "~/…/" + parts.suffix(2).joined(separator: "/") }
        return s
    }

    private func openDetail(_ llm: DetectedLLMRuntime) {
        // 只有真有东西可看才进详情，避免点进去一片空白
        guard llm.hasQuota || !llm.platformDetail.rows.isEmpty || !llm.platformDetail.sessions.isEmpty else { return }
        withAnimation(.easeInOut(duration: 0.15)) { drillDown = llm.name }
    }
}


/// 面板底栏的小按钮：图标 + 文字，悬停时出现圆角底色（系统工具栏按钮的手感）。
struct FooterButton: View {
    let symbol: String
    let title: String
    var tint: Color = .secondary
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: symbol).font(VG.font(11, .medium))
                Text(title).font(VG.font(11.5, .medium))
            }
            .foregroundStyle(hover ? tint : Color.secondary)
            .padding(.horizontal, 9)
            .padding(.vertical, 5)
            .background(Capsule().fill(hover ? VG.fillStrong : Color.clear))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
    }
}
