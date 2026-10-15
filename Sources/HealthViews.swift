import SwiftUI
import AppKit

/// A cached limit passing its reset time does not establish the new window's usage.
enum QuotaReadingState: Equatable {
    case current, old, reset, undated

    static func evaluate(_ window: QuotaWindow, now: TimeInterval) -> Self {
        if window.isExpired(now: now) { return .reset }
        guard let captured = window.capturedAt else { return .undated }
        return now - captured > 15 * 60 || captured > now + 60 ? .old : .current
    }
}

/// Keep account limits as individual device observations; percentages are never combined.
struct UnifiedQuotaSection: View {
    let report: ScanReport
    let scope: DeviceScope
    let now: TimeInterval
    var openLocal: (String) -> Void
    var openDevice: (String) -> Void
    @State private var expanded = Set<String>()

    private struct Reading: Identifiable {
        let host: String?
        let runtime: DetectedLLMRuntime
        var id: String { (host ?? "local") + ":" + runtime.name }
    }

    private var readings: [Reading] {
        var result: [Reading] = []
        if scope == .all || scope == .local {
            result += report.detectedLLMs.map { Reading(host: nil, runtime: $0) }
        }
        for host in report.remoteHosts where scope == .all || scope == .remote(host) {
            result += (report.remoteLLMs[host] ?? []).map { Reading(host: host, runtime: $0) }
        }
        return result
    }

    private func platform(_ name: String) -> String {
        name == "Gemini" || name == "Antigravity" ? "Antigravity" : name
    }

    private var platforms: [String] {
        let known = Set(readings.map { platform($0.runtime.name) })
        return ["Claude", "Codex", "Grok", "Antigravity"].filter { known.contains($0) }
    }

    private var visibleHosts: [String] {
        report.remoteHosts.filter { scope == .all || scope == .remote($0) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            VGSectionHeader(title: L("额度一览", "Quota overview"), symbol: "square.stack.3d.up.fill", tint: .indigo) {
                Text(scope == .all ? L("所有设备", "All devices") : L("按设备", "By device"))
                    .font(VG.caption).foregroundStyle(.secondary)
            }
            if platforms.isEmpty {
                Label(L("正在读取设备额度…", "Reading device quotas…"), systemImage: "clock")
                    .font(VG.callout).foregroundStyle(.secondary)
            }
            ForEach(platforms, id: \.self) { name in
                platformGroup(name)
            }
            if !visibleHosts.isEmpty {
                deviceConnections
                Text(L("同一账号可能在多台设备出现；额度逐台显示，不相加。", "The same account may appear on several devices. Quota readings are not added together."))
                    .font(VG.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .vgCard()
    }

    private func tint(_ name: String) -> Color {
        switch name {
        case "Claude": return .orange
        case "Codex": return .green
        case "Grok": return .primary
        default: return .blue
        }
    }

    private func platformGroup(_ name: String) -> some View {
        let rows = readings.filter { platform($0.runtime.name) == name }
        let visible = expanded.contains(name) ? rows : Array(rows.prefix(2))
        return VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 6) {
                Circle().fill(tint(name)).frame(width: 7, height: 7)
                Text(name).font(VG.callout.weight(.semibold))
                Spacer(minLength: 4)
                if rows.count > 1 {
                    Text(L("\(rows.count) 台设备", "\(rows.count) devices"))
                        .font(VG.caption).foregroundStyle(.secondary)
                }
            }
            ForEach(visible) { reading in
                deviceReading(reading)
            }
            if rows.count > 2 {
                Button {
                    if expanded.contains(name) { expanded.remove(name) } else { expanded.insert(name) }
                } label: {
                    Label(expanded.contains(name) ? L("收起设备", "Fewer devices") : L("另外 \(rows.count - 2) 台设备", "\(rows.count - 2) more devices"),
                          systemImage: expanded.contains(name) ? "chevron.up" : "chevron.down")
                        .font(VG.caption).foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 8).fill(tint(name).opacity(0.035)))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(VG.stroke, lineWidth: 0.5))
    }

    private func deviceReading(_ reading: Reading) -> some View {
        let runtime = reading.runtime
        let connection = reading.host.flatMap { report.remoteDeviceStatus[$0] }
        let offline = connection.map { !$0.error.isEmpty } ?? false
        let connectionOld = connection.map { now - ($0.lastSuccess ?? 0) > 180 } ?? false
        let retained = !runtime.quotaNote.isEmpty
        return Button {
            if let host = reading.host { openDevice(host) } else { openLocal(runtime.name) }
        } label: {
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline, spacing: 5) {
                    Text(reading.host.map { RemoteCollector.displayName(for: $0) } ?? L("本机", "Local"))
                        .font(VG.subheadline.weight(.medium)).foregroundStyle(.primary)
                        .lineLimit(1).truncationMode(.middle)
                    if !runtime.tier.isEmpty {
                        Text(runtime.tier).font(VG.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                    Spacer(minLength: 4)
                    if offline {
                        Text(L("连接失败 · 上次记录", "Offline · last reading")).foregroundStyle(.orange)
                    } else if runtime.isRunning && !connectionOld {
                        Text(L("会话在线", "Session running")).foregroundStyle(.secondary)
                    }
                }
                .font(VG.caption)
                if runtime.hasQuota {
                    HStack(spacing: 12) {
                        if let window = runtime.fiveHour { quota(window, title: "5h", offline: offline || retained || connectionOld) }
                        if let window = runtime.sevenDay { quota(window, title: L("周", "Week"), offline: offline || retained || connectionOld) }
                        Spacer(minLength: 0)
                    }
                    if runtime.secondaryFiveHour != nil || runtime.secondarySevenDay != nil {
                        HStack(spacing: 8) {
                            Text(runtime.secondaryPoolName).font(VG.caption).foregroundStyle(.secondary)
                            if let window = runtime.secondaryFiveHour { quota(window, title: "5h", offline: offline || retained || connectionOld) }
                            if let window = runtime.secondarySevenDay { quota(window, title: L("周", "Week"), offline: offline || retained || connectionOld) }
                            Spacer(minLength: 0)
                        }
                    }
                } else {
                    Text(L("暂无额度数据", "Quota unavailable"))
                        .font(VG.caption).foregroundStyle(.secondary)
                }
                if retained {
                    Text(runtime.quotaNote).font(VG.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(runtime.quotaSubtitle)
    }

    private func quota(_ window: QuotaWindow, title: String, offline: Bool) -> some View {
        let state = QuotaReadingState.evaluate(window, now: now)
        let trusted = state == .current && !offline
        let pct = max(0, min(100, window.usedPct))
        return VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 4) {
                Text(title).foregroundStyle(.secondary)
                Text(state == .reset ? "—" : L("已用 \(pct)%", "\(pct)% used"))
                    .monospacedDigit().foregroundStyle(trusted ? Color.primary : Color.secondary)
                if state == .old || offline { Text(L("上次", "Last")).foregroundStyle(.secondary) }
            }
            .font(VG.caption)
            if state == .reset {
                Text(L("已到重置时间，待刷新", "Reset due · awaiting update"))
                    .font(VG.font(9)).foregroundStyle(.secondary)
            } else if state == .undated {
                Text(L("采样时间未知", "Sample time unknown"))
                    .font(VG.font(9)).foregroundStyle(.secondary)
            } else {
                HStack(spacing: 4) {
                    if let age = window.ageSeconds(now: now) {
                        Text(L("\(Fmt.agoShort(age))采样", "Sample \(Fmt.agoShort(age))"))
                    }
                    if let reset = window.resetsAt, let countdown = Fmt.countdown(to: reset, now: now) {
                        Text(L("· \(countdown)重置", "· resets \(countdown)"))
                    }
                }
                .font(VG.font(9)).foregroundStyle(.secondary)
            }
        }
    }

    private var deviceConnections: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(visibleHosts, id: \.self) { host in
                let status = report.remoteDeviceStatus[host]
                let failed = !(status?.error ?? "").isEmpty
                let recent = now - (status?.lastSuccess ?? 0) <= 180
                HStack(spacing: 5) {
                    Circle().fill(failed ? Color.orange : recent ? Color.green : Color.secondary)
                        .frame(width: 5, height: 5)
                    Text(RemoteCollector.displayName(for: host)).lineLimit(1).truncationMode(.middle)
                    Spacer(minLength: 4)
                    Text(failed ? L("连接失败", "Connection failed") : status?.lastSuccess == nil ? L("等待连接", "Waiting") : recent ? L("已连接", "Connected") : L("连接待刷新", "Connection needs refresh"))
                }
                .font(VG.caption).foregroundStyle(.secondary)
                .help(status?.error ?? "")
            }
        }
    }
}

/// 概览页的费用卡：分清已发生与预测，历史不足时展示月累计。
struct OverviewStrip: View {
    let forecasts: [String: CostForecast]
    let capturedAt: TimeInterval
    let unpricedCount: Int
    var openStats: () -> Void
    var openPrices: () -> Void

    private var forecast: CostForecast? {
        let withData = forecasts.filter { $0.value.hasData }
        let candidates = withData.isEmpty ? forecasts : withData
        return candidates["USD"] ?? candidates["CNY"] ?? candidates.keys.sorted().first.flatMap { candidates[$0] }
    }

    private var updatedText: String {
        guard capturedAt > 0 else { return L("汇总中…", "Summarizing…") }
        let age = max(0, Int(Date().timeIntervalSince1970 - capturedAt))
        if age < 60 { return L("刚刚更新", "Updated just now") }
        return L("更新于\(Fmt.agoShort(age))", age < 3600 ? "Updated \(age / 60)m ago" : "Updated \(age / 3600)h ago")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label(L("API 等价估算", "API-equivalent estimate"), systemImage: "chart.line.uptrend.xyaxis")
                    .font(VG.font(11, .medium)).foregroundStyle(.secondary)
                Spacer()
                Button(action: openPrices) {
                    Label(L("价格明细", "Rates"), systemImage: "chevron.right").labelStyle(.titleAndIcon).font(VG.caption)
                }
                .buttonStyle(.borderless)
            }
            HStack(alignment: .top, spacing: 14) {
                cell(title: L("今日累计", "Today so far"), value: forecast.map { Fmt.money($0.todaySoFar, $0.currency) } ?? "—",
                     detail: L("仅已采集用量", "Collected usage only"))
                Rectangle().fill(VG.stroke).frame(width: 0.5)
                cell(title: L("本月累计", "Month so far"),
                     value: forecast.map { Fmt.money($0.monthSoFar, $0.currency) } ?? "—",
                     detail: L("预测与趋势见统计", "Forecasts in Statistics"))
            }
            .fixedSize(horizontal: false, vertical: true)
            Text(L("按参考 API 单价折算，用于比较用量，不是订阅账单。", "Reference API rates help compare usage; these are not subscription bills."))
                .font(VG.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Label(L("Codex 云端 / Dot：用量尚未接入", "Codex Cloud / Dot: usage not yet included"), systemImage: "cloud")
                .font(VG.caption).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
                .help(L("当前统计来自已采集的会话日志。云端任务在本机执行工具，不代表云端 token 记录也保存在本机。",
                        "Totals come from collected session logs. Running a cloud task's tools locally does not store its cloud token usage locally."))
            ForEach(forecasts.keys.sorted().filter { $0 != forecast?.currency }, id: \.self) { currency in
                if let other = forecasts[currency], other.hasData {
                    Text(L("\(currency) · 今日 \(Fmt.money(other.todaySoFar, currency)) · 本月已计 \(Fmt.money(other.monthSoFar, currency))",
                           "\(currency) · today \(Fmt.money(other.todaySoFar, currency)) · month to date \(Fmt.money(other.monthSoFar, currency))"))
                        .font(VG.caption).foregroundStyle(.secondary)
                }
            }
            HStack(spacing: 4) {
                Text(updatedText)
                    .font(VG.caption).foregroundStyle(.tertiary)
                Spacer()
                if unpricedCount > 0 {
                    Button(L("\(unpricedCount) 个模型未定价", "\(unpricedCount) unpriced models"), action: openPrices)
                        .font(VG.caption).foregroundStyle(.orange).buttonStyle(.plain)
                }
            }
        }
        .vgCard(fill: Color.accentColor.opacity(0.045))
    }

    private func cell(title: String, value: String, detail: String) -> some View {
        Button(action: openStats) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(VG.caption).foregroundStyle(.secondary)
                Text(value).font(VG.number(19, .semibold)).lineLimit(1).minimumScaleFactor(0.75).foregroundStyle(.primary)
                Text(detail).font(VG.caption).foregroundStyle(.secondary).lineLimit(2).fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// 模型健康详情页（降智检测）。
struct HealthDetailView: View {
    let report: NerfReport
    var rescan: () -> Void

    private var grouped: [(NerfFinding.Severity, [NerfFinding])] {
        [NerfFinding.Severity.hard, .soft, .good, .info].compactMap { sev in
            let items = report.findings.filter { $0.severity == sev }
            return items.isEmpty ? nil : (sev, items)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            hero
            if !report.currentModels.isEmpty { modelsCard }
            findingsCard
            probeCard
            methodCard
        }
    }

    private var hero: some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: report.status.symbol)
                .font(.system(size: 30 * VG.scale, weight: .semibold))
                .foregroundStyle(report.status.tint.gradient)
                .frame(width: 44, height: 44)
            VStack(alignment: .leading, spacing: 3) {
                Text(report.status.label).font(VG.title)
                Text(report.headline).font(VG.subheadline).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                Text("近 48 小时 · \(report.sessionsScanned) 个会话 · \(report.turnsScanned) 轮").font(VG.caption).foregroundStyle(.tertiary)
            }
            Spacer(minLength: 0)
            Button(action: rescan) { Image(systemName: "arrow.clockwise") }
                .buttonStyle(.borderless)
                .help("立刻重新检查")
        }
        .vgCard(fill: report.status.tint.opacity(0.08))
    }

    private var modelsCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            VGSectionHeader("正在用的模型", symbol: "cpu.fill", tint: .blue)
            ForEach(report.currentModels.keys.sorted(), id: \.self) { key in
                VGKeyValue(key: key, value: report.currentModels[key] ?? "")
            }
        }
        .vgCard()
    }

    private var findingsCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            VGSectionHeader(title: "证据", symbol: "list.bullet.rectangle.fill", tint: .orange) {
                Text("\(report.findings.count) 条").font(VG.caption).foregroundStyle(.secondary)
            }
            if report.findings.isEmpty {
                Label("没发现模型被换、推理级别被降或上下文被缩的记录", systemImage: "checkmark.circle")
                    .font(VG.subheadline).foregroundStyle(.secondary)
            }
            ForEach(grouped.indices, id: \.self) { gi in
                let sev = grouped[gi].0
                let items = grouped[gi].1
                VStack(alignment: .leading, spacing: 5) {
                    Text(sev.label).font(VG.font(10, .semibold)).foregroundStyle(sev.tint)
                    ForEach(items.prefix(8)) { f in findingRow(f) }
                    if items.count > 8 { Text("另 \(items.count - 8) 条").font(VG.caption).foregroundStyle(.secondary) }
                }
            }
        }
        .vgCard()
    }

    private func findingRow(_ f: NerfFinding) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: f.severity.symbol).font(VG.font(12, .semibold)).foregroundStyle(f.severity.tint).frame(width: 16)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 5) {
                    Text(f.title).font(VG.font(12, .medium)).lineLimit(2)
                    Spacer(minLength: 4)
                    Text(Fmt.agoShort(max(0, Int(Date().timeIntervalSince1970 - f.timestamp)))).font(VG.caption).foregroundStyle(.tertiary).fixedSize()
                }
                Text(f.detail).font(VG.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 4) {
                    VGPill(text: f.source, tint: .secondary)
                    if !f.session.isEmpty { VGPill(text: f.session, tint: .blue, symbol: "folder") }
                }
            }
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(f.severity.tint.opacity(f.severity >= .soft ? 0.07 : 0.03)))
    }

    private var probeCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            VGSectionHeader(title: "指纹检测（is-gpt-nerfed）", symbol: "waveform.path.ecg", tint: .pink) {
                VGPill(text: report.probeInstalled ? "已安装" : "未安装", tint: report.probeInstalled ? .green : .secondary)
            }
            if report.probeInstalled {
                if report.probes.isEmpty {
                    Text("近 7 天还没有检测记录。在 Codex 里输入 $is-gpt-nerfed 可立即检测。").font(VG.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                ForEach(report.probes.prefix(5)) { p in
                    HStack(spacing: 6) {
                        Text(NerfDetector.verdictTitle(p).replacingOccurrences(of: "指纹：", with: ""))
                            .font(VG.font(11, .semibold))
                            .foregroundStyle(p.verdict == "MATCH" ? Color.green : (p.verdict == "SUSPICIOUS" ? .orange : (p.verdict.hasPrefix("INVALID") ? .secondary : .red)))
                        Text("\(p.expected) → \(p.prediction)").font(VG.caption).foregroundStyle(.secondary).lineLimit(1)
                        Spacer()
                        Text(p.probability.map { String(format: "%.0f%%", $0 * 100) } ?? "").font(VG.number(10, .medium)).foregroundStyle(.secondary)
                        Text(Fmt.agoShort(max(0, Int(Date().timeIntervalSince1970 - p.finished)))).font(VG.caption).foregroundStyle(.tertiary)
                    }
                }
            } else {
                Text("被动检测只能看到 Codex 自己记下的模型名。想确认「名字没变、权重被换」，可以装 is-gpt-nerfed：它用 ModelTrace 随机数指纹比对（每次约 3 条短回答的 token），结论会自动出现在这里。")
                    .font(VG.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                Button {
                    if let url = URL(string: "https://github.com/kiyoakii/is-gpt-nerfed/blob/main/README.zh-CN.md") { NSWorkspace.shared.open(url) }
                } label: {
                    Label("查看安装方法", systemImage: "arrow.up.right.square").font(VG.font(11, .medium))
                }
                .buttonStyle(.link)
            }
        }
        .vgCard()
    }

    private var methodCard: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("怎么判断的").font(VG.font(10, .semibold)).foregroundStyle(.secondary)
            Text("· Codex：没改设置（无 thread_settings_applied）却换了更弱的模型、调低了推理级别、跑了隐藏的内部模型、上下文窗口变小 → 硬证据；改了设置的变化标「是你改的吗？」。")
            Text("· Claude Code：主对话里没用 /model 却换成了更小的档位（如 Opus → Sonnet）→ 硬证据；来回切换（opusplan 这类）只提示。")
            Text("· 行为统计：今天每次请求的平均输出、思考占比明显低于近两周中位数 → 可疑，仅供参考。")
            Text("· 全部只读本机日志，0 token；指纹检测由 is-gpt-nerfed 自己调度。")
        }
        .font(VG.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        .padding(.horizontal, 4)
    }
}
