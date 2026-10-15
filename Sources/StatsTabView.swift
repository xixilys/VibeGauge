import SwiftUI
import Foundation

/// 统计页：金额预测放最前（今天 / 本月会花多少），然后是近 14 天柱状图、Claude 5 小时块、热力图、各来源。
/// 展示层只读快照；历史归并、定价、预测和日历归桶都在后台完成。
/// 传了 scope 就只显示当前设备的来源 —— 全部按只读副本裁剪，不改 snapshot 本身。
public struct StatsTabView: View {
    public let snapshot: UsageHistory.Snapshot
    public let scope: DeviceScope
    public let hosts: [String]
    @State private var selectedCurrency = ""
    public init(snapshot: UsageHistory.Snapshot, scope: DeviceScope = .all, hosts: [String] = []) {
        self.snapshot = snapshot; self.scope = scope; self.hosts = hosts
    }

    private var scoped: Bool { scope != .all }
    private var remoteHost: String? { if case .remote(let host) = scope { return host }; return nil }
    private func allows(_ source: String) -> Bool { DeviceScope.includes(source: source, scope: scope, hosts: hosts) }
    private func counts(_ day: UsageHistory.Day) -> Bool {
        day.sources.contains { allows($0.key) && !UsageHistory.isProxySource($0.key) }
    }

    private var visibleTotals: [String: UsageHistory.Totals] {
        scoped ? snapshot.totals.filter { allows($0.key) } : snapshot.totals
    }
    private var visibleAggregate: UsageHistory.Totals {
        guard scoped else { return snapshot.aggregate }
        return visibleTotals.filter { !UsageHistory.isProxySource($0.key) }
            .values.reduce(into: UsageHistory.Totals()) { $0.merge($1) }
    }
    private var hasRecords: Bool { visibleAggregate.turns > 0 }
    private var dailyTokens: [String: Int64] {
        guard scoped else { return snapshot.dailyTokens }
        var out: [String: Int64] = [:]
        for day in snapshot.days where counts(day) {
            out[day.date] = day.sources.filter { allows($0.key) && !UsageHistory.isProxySource($0.key) }
                .values.reduce(Int64(0)) { $0 + $1.tokenTotal }
        }
        return out
    }
    private var activeDays: Int { dailyTokens.values.filter { $0 > 0 }.count }
    private var costBySource: [String: [String: Double]] {
        scoped ? snapshot.costBySource.filter { allows($0.key) } : snapshot.costBySource
    }
    private var costByCurrency: [String: Double] {
        var out: [String: Double] = [:]
        for (source, perCurrency) in costBySource where !UsageHistory.isProxySource(source) {
            for (currency, value) in perCurrency { out[currency, default: 0] += value }
        }
        return out
    }
    private var todayCost: [String: Double] {
        var out: [String: Double] = [:]
        for (source, perCurrency) in snapshot.todayCostBySource where allows(source) && !UsageHistory.isProxySource(source) {
            for (currency, value) in perCurrency { out[currency, default: 0] += value }
        }
        return out
    }
    private var unpricedBySource: [String: Int] {
        scoped ? snapshot.unpricedBySource.filter { allows($0.key) } : snapshot.unpricedBySource
    }
    private var unpricedNames: Set<String> {
        Set(snapshot.unpricedNamesBySource.filter { allows($0.key) && !UsageHistory.isProxySource($0.key) }.values.flatMap { $0 })
    }
    private var forecasts: [String: CostForecast] {
        scoped ? snapshot.forecastsByDevice[scope.key] ?? [:] : snapshot.forecasts
    }
    private var forecast: CostForecast? {
        if let selected = forecasts[selectedCurrency] { return selected }
        let withData = forecasts.filter { $0.value.hasData }
        let candidates = withData.isEmpty ? forecasts : withData
        return candidates["USD"] ?? candidates["CNY"] ?? candidates.keys.sorted().first.flatMap { candidates[$0] }
    }
    private var dailyCost: [String: Double] {
        let currency = forecast?.currency ?? snapshot.primaryCurrency
        if scoped { return snapshot.dailyCostByDevice[scope.key]?[currency] ?? [:] }
        return snapshot.dailyCostByDevice.values.reduce(into: [String: Double]()) { result, perCurrency in
            for (day, cost) in perCurrency[currency] ?? [:] { result[day, default: 0] += cost }
        }
    }
    private var earliestDate: String? {
        guard scoped else { return snapshot.earliestDate }
        return snapshot.days.first { counts($0) }?.date
    }
    private var cacheHitRate: Double? {
        let a = visibleAggregate
        return a.ctx > 0 ? Double(a.cacheRead) / Double(a.ctx) : nil
    }
    /// 设备分组后的来源：本机在前，远程 / 挂载设备按名字排。
    private var sources: [String] {
        var keys = Set(visibleTotals.keys)
        if let host = remoteHost {
            for cli in ["Claude", "Codex", "OpenCode"] { keys.insert("\(cli) · \(host)") }
        } else {
            keys.formUnion(["Claude", "Codex"].filter { allows($0) })
        }
        let order = ["Claude", "Codex", "OpenCode"]
        return keys.filter { allows($0) }.sorted { a, b in
            let da = UsageHistory.device(of: a) ?? "", db = UsageHistory.device(of: b) ?? ""
            if da != db { return da < db }
            let pa = UsageHistory.isProxySource(a), pb = UsageHistory.isProxySource(b)
            if pa != pb { return !pa }
            let ia = order.firstIndex(of: UsageHistory.cli(of: a)) ?? 9, ib = order.firstIndex(of: UsageHistory.cli(of: b)) ?? 9
            return ia != ib ? ia < ib : a < b
        }
    }
    private var days: [Date] {
        let cal = Calendar.current, today = Calendar.current.startOfDay(for: Date())
        return (0..<42).map { cal.date(byAdding: .day, value: $0 - 41, to: today)! }
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if snapshot.isScanning && snapshot.capturedAt == 0 {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text("正在汇总历史（\(snapshot.processedFiles)/\(snapshot.totalFiles) 个文件）…").font(VG.caption).foregroundStyle(.secondary)
                }
            }
            if !snapshot.error.isEmpty {
                Label(snapshot.error, systemImage: "exclamationmark.triangle.fill")
                    .font(VG.caption).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
            }
            forecastCard
            if remoteHost == nil, let block = snapshot.claudeBlock, block.isActive { blockCard(block) }
            metrics
            heatmap
            distribution
            providers
            footnotes
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: 金额预测

    @ViewBuilder
    private var forecastCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            VGSectionHeader(title: L("API 等价费用", "API-equivalent cost"), symbol: "dollarsign.circle.fill", tint: .green) {
                if scoped { VGPill(text: remoteHost ?? L("本机", "Local"), tint: .blue, symbol: "desktopcomputer") }
                if let f = forecast { VGPill(text: f.currency, tint: .secondary) }
            }
            Label(L("Codex 云端 / Dot：用量尚未接入", "Codex Cloud / Dot: usage not yet included"), systemImage: "cloud")
                .font(VG.caption).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
            if forecasts.count > 1 {
                Picker(L("币种", "Currency"), selection: Binding(get: { forecast?.currency ?? "" }, set: { selectedCurrency = $0 })) {
                    ForEach(forecasts.keys.sorted(), id: \.self) { currency in Text(currency).tag(currency) }
                }
                .pickerStyle(.segmented).labelsHidden().controlSize(.small)
            }
            Text(L("参考 API 单价折算，订阅与渠道账单以平台为准。", "Reference API estimates; subscription and provider bills are determined by the platform."))
                .font(VG.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if let f = forecast {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(Fmt.money(f.todaySoFar, f.currency)).font(VG.number(26, .bold))
                    Text(L("今日累计", "Today so far")).font(VG.subheadline).foregroundStyle(.secondary)
                    Spacer()
                    VStack(alignment: .trailing, spacing: 1) {
                        Text(f.todayConfidence == .insufficient ? L("短时估计", "Short-term estimate") : L("全天参考", "Daily estimate")).font(VG.caption).foregroundStyle(.secondary)
                        Text(Fmt.money(f.todayProjected, f.currency)).font(VG.number(15)).foregroundStyle(.green)
                    }
                }
                VGProgress(value: f.todayHigh > 0 ? f.todaySoFar / f.todayHigh : 0, tint: .green, height: 6,
                           marker: f.todayHigh > 0 ? f.todayProjected / f.todayHigh : nil)
                HStack {
                    Text("区间 \(Fmt.money(f.todayLow, f.currency)) – \(Fmt.money(f.todayHigh, f.currency))")
                    Spacer()
                    Text("近 1 小时 \(Fmt.money(f.lastHourCost, f.currency))/h")
                }
                .font(VG.caption).foregroundStyle(.secondary)
                HStack(spacing: 6) {
                    VGStat(title: "昨天", value: Fmt.money(f.yesterday, f.currency))
                    VGStat(title: "本周", value: Fmt.money(f.weekSoFar, f.currency))
                    VGStat(title: f.monthConfidence == .insufficient ? L("本月累计", "Month to date") : L("本月参考", "Month estimate"),
                           value: Fmt.money(f.monthConfidence == .insufficient ? f.monthSoFar : f.monthProjected, f.currency),
                           detail: f.monthConfidence == .insufficient ? L("历史不足，暂不预测", "Not enough history") : L("已计 \(Fmt.money(f.monthSoFar, f.currency))", "Recorded \(Fmt.money(f.monthSoFar, f.currency))"))
                }
                VGBarChart(values: f.recentCosts, labels: f.recentDays.map { shortDate($0) },
                           projectedLast: f.todayProjected, tint: .green, height: 52,
                           format: { Fmt.money($0, f.currency) })
                Text(f.monthConfidence == .insufficient
                     ? L("\(f.basis) · 近 14 天仅 \(f.historyDays) 日记录，暂不外推整月。", "\(f.basis) · Only \(f.historyDays) recorded days in the last 14; monthly extrapolation is withheld.")
                     : L("\(f.basis) · 本月波动范围 \(Fmt.money(f.monthLow, f.currency)) – \(Fmt.money(f.monthHigh, f.currency)) · \(f.historyDays) 日记录", "\(f.basis) · Monthly variability \(Fmt.money(f.monthLow, f.currency)) – \(Fmt.money(f.monthHigh, f.currency)) · \(f.historyDays) recorded days"))
                    .font(VG.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                let others = forecasts.filter { $0.key != f.currency && $0.value.hasData }
                if !others.isEmpty {
                    ForEach(others.keys.sorted(), id: \.self) { cur in
                        if let o = others[cur] {
                            HStack {
                                Text(cur).font(VG.subheadline).foregroundStyle(.secondary)
                                Spacer()
                                Text(L("今日 \(Fmt.money(o.todaySoFar, cur)) · 本月已计 \(Fmt.money(o.monthSoFar, cur))", "Today \(Fmt.money(o.todaySoFar, cur)) · month to date \(Fmt.money(o.monthSoFar, cur))"))
                                    .font(VG.font(11, .medium)).lineLimit(1).minimumScaleFactor(0.8)
                            }
                        }
                    }
                }
            } else {
                Text(snapshot.hasAnyPricing ? "近 35 天没有可定价的用量" : "价格表读不到：内置价随 App 分发，或在 ~/.config/vibegauge/prices.json 自己填")
                    .font(VG.subheadline).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
        .vgCard()
    }

    private func blockCard(_ b: BillingBlock) -> some View {
        let now = Date().timeIntervalSince1970
        let progress = (now - b.start) / max(1, b.end - b.start)
        return VStack(alignment: .leading, spacing: 8) {
            VGSectionHeader(title: L("本机 Claude · 当前 5 小时块", "Local Claude · current 5-hour block"), symbol: "timer", tint: .orange) {
                Text(Fmt.countdown(to: b.end, now: now).map { "剩 \($0)" } ?? "").font(VG.caption).foregroundStyle(.secondary)
            }
            HStack(alignment: .firstTextBaseline) {
                Text(Fmt.money(b.cost, b.currency)).font(VG.number(18, .bold))
                Text("已花 · \(b.requests) 次请求").font(VG.caption).foregroundStyle(.secondary)
                Spacer()
                Text("到块结束约 \(Fmt.money(b.projected, b.currency))").font(VG.font(11, .medium)).foregroundStyle(.orange)
            }
            VGProgress(value: progress, tint: .orange, height: 5)
            Text("按块内速度 \(Fmt.money(b.perHour, b.currency))/小时推算（ccusage blocks 口径：首条请求整点起算，5 小时一块）")
                .font(VG.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
        .vgCard()
    }

    // MARK: 总览

    private var metrics: some View {
        VStack(alignment: .leading, spacing: 8) {
            VGSectionHeader(title: remoteHost.map { "\($0) · 累计" } ?? "累计", symbol: "chart.bar.fill", tint: .blue) {
                Text(earliestDate.map { "自 \($0) 起" } ?? "").font(VG.caption).foregroundStyle(.secondary)
            }
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 6), GridItem(.flexible(), spacing: 6)], spacing: 6) {
                VGStat(title: "累计 token", value: hasRecords ? Fmt.tokens(visibleAggregate.tokenTotal) : "—", detail: "输入（含缓存）+ 输出", symbol: "number")
                VGStat(title: "API 等价成本", value: costText(costByCurrency),
                       detail: !unpricedNames.isEmpty ? L("\(unpricedNames.count) 个模型未定价", "\(unpricedNames.count) unpriced models") : "今天 \(costText(todayCost))",
                       symbol: "dollarsign")
                VGStat(title: "活跃天数", value: hasRecords ? "\(activeDays)" : "—", detail: "有 token 用量的日子", symbol: "calendar")
                VGStat(title: "缓存命中率", value: cacheHitRate.map { String(format: "%.1f%%", $0 * 100) } ?? "—", detail: "缓存读取 / 全部输入", symbol: "bolt.fill")
            }
        }
        .vgCard()
    }

    private func costText(_ value: [String: Double]) -> String {
        guard snapshot.hasAnyPricing else { return "未定价" }
        return value.isEmpty ? "—" : Fmt.money(value)
    }

    private var heatmap: some View {
        let dates = days
        let keys = dates.map { UsageHistory.dayKey(timestamp: $0.timeIntervalSince1970) }
        let values = keys.map { dailyTokens[$0] ?? 0 }
        let grades = UsageHistory.levels(values)
        return VStack(alignment: .leading, spacing: 8) {
            VGSectionHeader(title: "每日强度 · 近 6 周", symbol: "square.grid.3x3.fill", tint: .teal) {
                Text(maxDayText).font(VG.caption).foregroundStyle(.secondary)
            }
            HStack(alignment: .top, spacing: 4) {
                VStack(spacing: 4) {
                    ForEach(0..<7, id: \.self) { row in
                        Text(weekday(dates[row])).font(VG.caption).foregroundStyle(.secondary).frame(width: 16, height: 15)
                    }
                }
                ForEach(0..<6, id: \.self) { column in
                    VStack(spacing: 4) {
                        ForEach(0..<7, id: \.self) { row in
                            let i = column * 7 + row
                            RoundedRectangle(cornerRadius: 3.5, style: .continuous)
                                .fill(grades[i] == 0 ? Color.primary.opacity(0.07) : Color.teal.opacity(0.18 + Double(grades[i]) * 0.16))
                                .frame(maxWidth: .infinity).frame(height: 15)
                                .help("\(keys[i]) · \(Fmt.tokens(values[i])) token" + (dailyCost[keys[i]].map { " · " + Fmt.money($0, forecast?.currency ?? snapshot.primaryCurrency) } ?? ""))
                        }
                    }
                }
            }
            HStack(spacing: 3) {
                Spacer()
                Text("少").font(VG.caption).foregroundStyle(.secondary)
                ForEach(1...5, id: \.self) { level in
                    RoundedRectangle(cornerRadius: 2, style: .continuous).fill(Color.teal.opacity(0.18 + Double(level) * 0.16)).frame(width: 9, height: 9)
                }
                Text("多").font(VG.caption).foregroundStyle(.secondary)
            }
        }
        .vgCard()
    }

    private var maxDayText: String {
        let visible = Set(days.map { UsageHistory.dayKey(timestamp: $0.timeIntervalSince1970) })
        guard let day = dailyTokens.filter({ $0.value > 0 && visible.contains($0.key) }).sorted(by: { $0.value == $1.value ? $0.key < $1.key : $0.value > $1.value }).first else { return "" }
        return "最多：\(shortDate(day.key))"
    }
    private func shortDate(_ key: String) -> String {
        let parts = key.split(separator: "-").compactMap { Int($0) }
        return parts.count == 3 ? "\(parts[1])/\(parts[2])" : key
    }
    private func weekday(_ date: Date) -> String {
        ["日", "一", "二", "三", "四", "五", "六"][Calendar.current.component(.weekday, from: date) - 1]
    }

    private var distribution: some View {
        let all = visibleAggregate
        let parts: [(String, Int64, Color)] = [("新输入", all.newInput, .blue), ("输出", all.out, .orange), ("缓存", all.cacheTotal, .green)]
        let total = max(1, all.newInput + all.out + all.cacheTotal)
        return VStack(alignment: .leading, spacing: 8) {
            VGSectionHeader("token 构成", symbol: "chart.pie.fill", tint: .indigo)
            GeometryReader { geo in
                HStack(spacing: 1.5) {
                    ForEach(parts, id: \.0) { part in
                        Rectangle().fill(part.2.gradient).frame(width: max(0, geo.size.width * CGFloat(Double(part.1) / Double(total)) - 1.5))
                    }
                }.clipShape(Capsule())
            }.frame(height: 7)
            ForEach(parts, id: \.0) { part in
                HStack(spacing: 6) {
                    Circle().fill(part.2).frame(width: 7, height: 7)
                    Text(part.0).font(VG.subheadline)
                    if part.0 == "输出", all.think > 0 { Text("含思考 \(Fmt.tokens(all.think))").font(VG.caption).foregroundStyle(.secondary) }
                    Spacer()
                    Text(hasRecords ? Fmt.tokens(part.1) : "—").font(VG.number(11, .medium)).foregroundStyle(.secondary)
                }
            }
        }
        .vgCard()
    }

    // MARK: 各来源

    private var providers: some View {
        VStack(alignment: .leading, spacing: 8) {
            VGSectionHeader(title: "各来源", symbol: "square.stack.3d.up.fill", tint: .purple) {
                Text("今天 · 累计").font(VG.caption).foregroundStyle(.secondary)
            }
            ForEach(sources, id: \.self) { source in
                if let total = visibleTotals[source] {
                    providerRow(source, total)
                } else {
                    HStack(spacing: 8) {
                        sourceIcon(source)
                        Text(source).font(VG.font(12, .medium))
                        Spacer()
                        Text(snapshot.sourceNotes[source] ?? (snapshot.isScanning ? "正在汇总…" : "无记录"))
                            .font(VG.caption).foregroundStyle(.secondary).lineLimit(2).multilineTextAlignment(.trailing)
                    }
                    .padding(.vertical, 2)
                }
            }
            if remoteHost == nil {
                HStack(spacing: 8) {
                    sourceIcon("Grok")
                    Text("Grok / Gemini").font(VG.font(12, .medium))
                    Spacer()
                    Text("本地日志没有 token 统计").font(VG.caption).foregroundStyle(.secondary)
                }
            }
        }
        .vgCard()
    }

    private func sourceIcon(_ source: String) -> some View {
        let cli = UsageHistory.cli(of: source)
        let (symbol, tint): (String, Color) = {
            if source.hasPrefix("API") { return ("key.horizontal.fill", .gray) }
            switch cli {
            case "Claude": return ("sparkle", .orange)
            case "Codex": return ("chevron.left.forwardslash.chevron.right", .blue)
            case "OpenCode": return ("terminal.fill", .indigo)
            default: return ("circle.dashed", .gray)
            }
        }()
        return VGIcon(symbol: symbol, tint: tint, size: 18)
    }

    private func providerRow(_ source: String, _ totals: UsageHistory.Totals) -> some View {
        let ratio = visibleAggregate.tokenTotal > 0 ? Double(totals.tokenTotal) / Double(visibleAggregate.tokenTotal) : 0
        let today = snapshot.todayBySource[source]
        let todayCost = snapshot.todayCostBySource[source] ?? [:]
        let device = UsageHistory.device(of: source)
        return VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 8) {
                sourceIcon(source)
                Text(UsageHistory.cli(of: source)).font(VG.font(12, .semibold))
                if let device { VGPill(text: device, tint: .blue, symbol: "desktopcomputer") }
                if UsageHistory.isProxySource(source) { VGPill(text: "不计入总数", tint: .secondary) }
                Spacer()
                Text(costText(costBySource[source] ?? [:])).font(VG.number(12))
            }
            HStack {
                Text("今天 \(today.map { Fmt.tokens($0.tokenTotal) } ?? "0") token · \(today?.turns ?? 0) 次" + (todayCost.isEmpty ? "" : " · \(Fmt.money(todayCost))"))
                Spacer()
                Text("累计 \(Fmt.tokens(totals.tokenTotal)) · \(totals.sessions) 会话")
            }
            .font(VG.caption).foregroundStyle(.secondary).lineLimit(1).minimumScaleFactor(0.85)
            VGProgress(value: UsageHistory.isProxySource(source) ? 0 : ratio, tint: .purple, height: 4)
            if let note = snapshot.sourceNotes[source] { Text(note).font(VG.caption).foregroundStyle(.secondary) }
            if unpricedBySource[source, default: 0] > 0 {
                let names = snapshot.unpricedNamesBySource[source, default: []].prefix(4).joined(separator: "、")
                Text("未定价：\(names)（不计入成本）").font(VG.caption).foregroundStyle(.orange).lineLimit(2)
            }
        }
        .padding(.vertical, 3)
    }

    private var footnotes: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(priceNote)
            Text("总数与热力图只算 CLI 日志（Claude / Codex / opencode，含远程与挂载设备）；经记账代理的 API 调用多半已在 CLI 日志里，单列不重复计入。思考包含在输出中。")
            if snapshot.cumulativeTurns > 0 {
                Text("\(snapshot.cumulativeTurns) 次旧格式 Codex 记录按累计差归桶，跨日精度受事件时间限制。")
            }
            if snapshot.replayedTurns > 0 {
                Text("已跳过 \(snapshot.replayedTurns) 条 fork 会话重放的父会话用量。")
            }
            if snapshot.skippedRecords > 0 {
                Text("\(snapshot.skippedRecords) 条记录缺少有效时间或用量，未计入。").foregroundStyle(.orange)
            }
        }
        .font(VG.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        .padding(.horizontal, 4)
    }

    private var priceNote: String {
        var parts: [String] = []
        if !snapshot.builtinPriceAsOf.isEmpty { parts.append(L("内置参考目录（\(snapshot.builtinPriceAsOf)），各模型来源见价格页", "Built-in reference catalog (\(snapshot.builtinPriceAsOf)); see Rates for individual sources")) }
        if snapshot.hasPriceTable { parts.append("你的 prices.json 优先") }
        let head = parts.isEmpty ? "未配置价格" : parts.joined(separator: "，")
        return head + L("；内置模型按支持的缓存、长上下文与 Fast 规则计算，自定义价按你的覆盖规则。API 等价估算不等于订阅账单。", "; built-in models use supported cache, long-context and Fast rules; custom rates follow your overrides. API estimates are not subscription bills.")
    }
}
