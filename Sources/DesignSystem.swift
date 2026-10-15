import SwiftUI

/// 面板的设计语言：按 macOS HIG 的字阶（说明 ≥10pt、正文 12–13pt）、连续圆角卡片 + 发丝描边、
/// 系统设置风格的彩色图标方块、SF Symbols、等宽数字。所有尺寸都乘用户选的字号倍率。
enum VG {
    static var scale: CGFloat { UITheme.fontScale }

    /// 旧代码写死的 7–12pt 统一映射到 HIG 字阶（菜单里 7pt 的字实在看不清）。
    static func scaled(_ legacy: CGFloat, weight: Font.Weight = .regular, design: Font.Design = .default) -> Font {
        let mapped: CGFloat
        switch legacy {
        case ..<8: mapped = 10
        case ..<9: mapped = 10.5
        case ..<10: mapped = 11
        case ..<11: mapped = 12
        case ..<12: mapped = 13
        case ..<14: mapped = legacy + 1.5
        default: mapped = legacy + 2
        }
        return .system(size: mapped * scale, weight: weight, design: design)
    }

    static func font(_ size: CGFloat, _ weight: Font.Weight = .regular, _ design: Font.Design = .default) -> Font {
        .system(size: size * scale, weight: weight, design: design)
    }
    static var title: Font { font(15, .semibold) }
    static var headline: Font { font(13, .semibold) }
    static var body: Font { font(12.5) }
    static var callout: Font { font(12) }
    static var subheadline: Font { font(11) }
    static var caption: Font { font(10) }
    static func number(_ size: CGFloat, _ weight: Font.Weight = .semibold) -> Font {
        .system(size: size * scale, weight: weight, design: .rounded).monospacedDigit()
    }

    static let radius: CGFloat = 10
    static let fill = Color.primary.opacity(0.045)
    static let fillStrong = Color.primary.opacity(0.075)
    static let stroke = Color.primary.opacity(0.08)

    /// 额度 / 占用：0% 绿 → 100% 红（与原来的连续渐变一致）
    static func heat(_ pct: Int) -> Color {
        let p = Double(max(0, min(100, pct))) / 100.0
        return Color(hue: 0.33 * (1.0 - p * p), saturation: 0.78, brightness: 0.82)
    }
}

// MARK: - 卡片

struct VGCardModifier: ViewModifier {
    var padding: CGFloat
    var fill: Color
    func body(content: Content) -> some View {
        content
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: VG.radius, style: .continuous).fill(fill))
            .overlay(RoundedRectangle(cornerRadius: VG.radius, style: .continuous).strokeBorder(VG.stroke, lineWidth: 0.5))
    }
}

extension View {
    func vgCard(padding: CGFloat = 12, fill: Color = VG.fill) -> some View {
        modifier(VGCardModifier(padding: padding, fill: fill))
    }

    /// 旧代码 `.background(Color.secondary.opacity(x)).cornerRadius(r)` 的统一替换：连续圆角 + 发丝描边。
    func vgFill(_ opacity: Double, radius: CGFloat) -> some View {
        let shape = RoundedRectangle(cornerRadius: radius + 2, style: .continuous)
        return background(shape.fill(Color.primary.opacity(opacity * 0.75)))
            .overlay(shape.strokeBorder(VG.stroke.opacity(opacity >= 0.05 ? 1 : 0.6), lineWidth: 0.5))
    }
}

// MARK: - 基础部件

/// 系统设置风格的彩色图标方块。
struct VGIcon: View {
    let symbol: String
    var tint: Color = .accentColor
    var size: CGFloat = 20
    var body: some View {
        RoundedRectangle(cornerRadius: size * 0.28, style: .continuous)
            .fill(tint.gradient)
            .frame(width: size * VG.scale, height: size * VG.scale)
            .overlay(Image(systemName: symbol)
                .font(.system(size: size * 0.55 * VG.scale, weight: .semibold))
                .foregroundStyle(.white))
    }
}

/// 分区标题：图标方块 + 标题 + 右侧附注。
struct VGSectionHeader<Trailing: View>: View {
    let title: String
    let symbol: String
    var tint: Color = .accentColor
    @ViewBuilder var trailing: () -> Trailing
    var body: some View {
        HStack(spacing: 8) {
            VGIcon(symbol: symbol, tint: tint)
            Text(title).font(VG.headline).lineLimit(1)
            Spacer(minLength: 4)
            trailing()
        }
    }
}

extension VGSectionHeader where Trailing == EmptyView {
    init(_ title: String, symbol: String, tint: Color = .accentColor) {
        self.title = title; self.symbol = symbol; self.tint = tint; self.trailing = { EmptyView() }
    }
}

/// 胶囊标签（状态 / 档位）。
struct VGPill: View {
    let text: String
    var tint: Color = .secondary
    var symbol: String? = nil
    var body: some View {
        HStack(spacing: 3) {
            if let symbol { Image(systemName: symbol).font(VG.font(9, .bold)) }
            Text(text).font(VG.font(10, .semibold)).lineLimit(1)
        }
        .padding(.horizontal, 7).padding(.vertical, 2.5)
        .foregroundStyle(tint)
        .background(Capsule().fill(tint.opacity(0.14)))
        .fixedSize()
    }
}

/// 细进度条（胶囊形）。
struct VGProgress: View {
    var value: Double
    var tint: Color = .accentColor
    var height: CGFloat = 5
    var marker: Double? = nil
    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(0.08))
                Capsule().fill(tint.gradient)
                    .frame(width: max(height, geo.size.width * CGFloat(max(0, min(1, value)))))
                if let marker {
                    Rectangle().fill(Color.primary.opacity(0.45))
                        .frame(width: 1.5, height: height + 4)
                        .offset(x: geo.size.width * CGFloat(max(0, min(1, marker))) - 0.75)
                }
            }
        }
        .frame(height: height)
    }
}

/// 数字小卡：标题 / 大号数值 / 说明。
struct VGStat: View {
    let title: String
    let value: String
    var detail: String = ""
    var symbol: String? = nil
    var tint: Color = .secondary
    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 4) {
                if let symbol { Image(systemName: symbol).font(VG.font(10, .semibold)).foregroundStyle(tint) }
                Text(title).font(VG.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Text(value).font(VG.number(16)).lineLimit(1).minimumScaleFactor(0.7)
            if !detail.isEmpty {
                Text(detail).font(VG.caption).foregroundStyle(.secondary).lineLimit(2).fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(VG.fillStrong))
    }
}

/// 柱状图：values 与 labels 等长；projected 是最后一根的预测（画成虚底）。
struct VGBarChart: View {
    let values: [Double]
    let labels: [String]
    var projectedLast: Double? = nil
    var tint: Color = .accentColor
    var height: CGFloat = 56
    var format: (Double) -> String = { String(format: "%.2f", $0) }
    var body: some View {
        let top = max(values.max() ?? 0, projectedLast ?? 0, 0.000_001)
        VStack(spacing: 3) {
            HStack(alignment: .bottom, spacing: 3) {
                ForEach(values.indices, id: \.self) { i in
                    let isLast = i == values.count - 1
                    ZStack(alignment: .bottom) {
                        if isLast, let p = projectedLast, p > values[i] {
                            RoundedRectangle(cornerRadius: 2.5, style: .continuous)
                                .strokeBorder(tint.opacity(0.6), style: StrokeStyle(lineWidth: 1, dash: [2, 2]))
                                .frame(height: max(2, height * CGFloat(p / top)))
                        }
                        RoundedRectangle(cornerRadius: 2.5, style: .continuous)
                            .fill(isLast ? AnyShapeStyle(tint.gradient) : AnyShapeStyle(tint.opacity(values[i] > 0 ? 0.45 : 0.12)))
                            .frame(height: max(2, height * CGFloat(values[i] / top)))
                    }
                    .frame(maxWidth: .infinity)
                    .help("\(labels.indices.contains(i) ? labels[i] : "") · \(format(values[i]))")
                }
            }
            .frame(height: height, alignment: .bottom)
            HStack {
                Text(labels.first ?? "").font(VG.caption).foregroundStyle(.secondary)
                Spacer()
                Text(labels.last ?? "").font(VG.caption).foregroundStyle(.secondary)
            }
        }
    }
}

/// 两列键值行。
struct VGKeyValue: View {
    let key: String
    let value: String
    var valueColor: Color = .primary
    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(key).font(VG.subheadline).foregroundStyle(.secondary)
            Spacer(minLength: 8)
            Text(value).font(VG.font(11, .medium)).foregroundStyle(valueColor).multilineTextAlignment(.trailing)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

extension NerfReport.Status {
    var tint: Color {
        switch self {
        case .alert: return .red
        case .watch: return .orange
        case .ok: return .green
        case .unknown: return .secondary
        }
    }
    var symbol: String {
        switch self {
        case .alert: return "exclamationmark.octagon.fill"
        case .watch: return "exclamationmark.triangle.fill"
        case .ok: return "checkmark.seal.fill"
        case .unknown: return "questionmark.circle"
        }
    }
    var label: String {
        switch self {
        case .alert: return "疑似降智"
        case .watch: return "有可疑迹象"
        case .ok: return L("未见异常", "No anomalies")
        case .unknown: return "暂无数据"
        }
    }
}

extension NerfFinding.Severity {
    var tint: Color {
        switch self {
        case .hard: return .red
        case .soft: return .orange
        case .info: return .secondary
        case .good: return .green
        }
    }
    var symbol: String {
        switch self {
        case .hard: return "xmark.octagon.fill"
        case .soft: return "exclamationmark.triangle.fill"
        case .info: return "info.circle"
        case .good: return "arrow.up.circle.fill"
        }
    }
    var label: String {
        switch self {
        case .hard: return "硬证据"
        case .soft: return "可疑"
        case .info: return "提示"
        case .good: return "好消息"
        }
    }
}
