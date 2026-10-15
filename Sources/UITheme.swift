import Foundation

/// 新界面文字沿用仓库约定的中英双语入口，AppleLanguages 也可用于本地检查。
func L(_ chinese: String, _ english: String) -> String {
    Locale.preferredLanguages.first?.hasPrefix("zh") == true ? chinese : english
}

/// 界面缩放。默认字号偏小是最常见的反馈，菜单里可选档位，写进 UserDefaults 后即时生效。
enum UITheme {
    static let scaleKey = "fontScale"

    /// 只接受 0.5–2.0 的合理值，坏值一律回落到 1.0（免得写坏配置把界面缩没了）。
    static var fontScale: CGFloat {
        let value = UserDefaults.standard.double(forKey: scaleKey)
        return value >= 0.5 && value <= 2.0 ? CGFloat(value) : 1.0
    }

    /// 菜单档位（标题, 倍率）。
    static let presets: [(title: String, value: Double)] = [
        ("小", 0.9), ("标准", 1.0), ("大", 1.15), ("特大", 1.3), ("超大", 1.5),
    ]
}
