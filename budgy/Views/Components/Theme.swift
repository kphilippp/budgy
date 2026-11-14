import SwiftUI

// MARK: - Formatting

extension Double {
    /// "$1,234.56"
    var currency: String {
        formatted(.currency(code: Locale.current.currency?.identifier ?? "USD"))
    }

    /// "$1,235" for large headline numbers.
    var currencyWhole: String {
        formatted(.currency(code: Locale.current.currency?.identifier ?? "USD").precision(.fractionLength(0)))
    }
}

extension Date {
    /// Day-level relative text for due dates: "today", "tomorrow", "in 5 days", "yesterday".
    var relativeDayText: String {
        let calendar = Calendar.current
        let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: .now), to: calendar.startOfDay(for: self)).day ?? 0
        switch days {
        case 0: return "today"
        case 1: return "tomorrow"
        case -1: return "yesterday"
        case 2...: return "in \(days) days"
        default: return "\(-days) days ago"
        }
    }
}

// MARK: - Colors

/// The app-wide accent, chosen in Settings → Display. Raw values are stored, so cases keep their old names.
enum AppTheme: String, CaseIterable, Identifiable {
    case teal, blue, indigo, purple, pink, orange, green, graphite

    var id: String { rawValue }

    var title: String {
        switch self {
        case .teal: "Sea Glass"
        case .blue: "Lake"
        case .indigo: "Dusk"
        case .purple: "Heather"
        case .pink: "Rosehip"
        case .orange: "Ochre"
        case .green: "Moss"
        case .graphite: "Slate"
        }
    }

    /// Mid-tones in dark mode and deep tones in light mode, so white button labels stay legible on both.
    var color: Color {
        switch self {
        case .teal: Color(light: 0x2E6E5E, dark: 0x4E9F88)
        case .blue: Color(light: 0x3A6688, dark: 0x5F8FB3)
        case .indigo: Color(light: 0x4B568C, dark: 0x7680C4)
        case .purple: Color(light: 0x6B5790, dark: 0x9681BF)
        case .pink: Color(light: 0x9C4D66, dark: 0xC27A90)
        case .orange: Color(light: 0x98602A, dark: 0xB88346)
        case .green: Color(light: 0x45764D, dark: 0x6A9D6C)
        case .graphite: Color(light: 0x46524E, dark: 0x7D8A86)
        }
    }
}

extension EnvironmentValues {
    /// The user's accent. Set once in `RootView`; read it instead of `Color.accentColor`.
    @Entry var themeColor: Color = AppTheme.teal.color
}

enum BudgyColor {

    /// Names you can pick for categories and goals. Stored by name, so these strings never change.
    static let palette = ["blue", "green", "orange", "pink", "purple", "teal", "indigo", "red", "yellow", "mint", "cyan", "brown"]

    static func named(_ name: String) -> Color {
        switch name {
        case "blue": .lake
        case "green": .moss
        case "orange": .ochre
        case "pink": .rosehip
        case "purple": .heather
        case "teal": .eucalyptus
        case "indigo": .dusk
        case "red": .clay
        case "yellow": .wheat
        case "mint": .sage
        case "cyan": .glacier
        case "brown": .bark
        case "gray": .stone
        default: .spruce
        }
    }

    static func forAccount(_ kind: AccountKind) -> Color {
        switch kind {
        case .checking: .lake
        case .savings: .moss
        case .creditCard: .ochre
        case .retirement401k: .dusk
        case .rothIRA: .sage
        case .brokerage: .heather
        case .other: .stone
        }
    }
}

// MARK: - Panels

/// The standard panel: one quiet step off the canvas, a hairline edge, no shadow.
struct CardBackground: ViewModifier {
    @Environment(\.displayScale) private var displayScale
    @Environment(\.colorSchemeContrast) private var contrast
    var padding: CGFloat = 16

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: Radius.panel, style: .continuous)
        content
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background { shape.fill(Color.surface) }
            .overlay {
                shape.strokeBorder(
                    contrast == .increased ? Color.inkTertiary : Color.hairline,
                    lineWidth: contrast == .increased ? 1 : 1 / displayScale
                )
            }
    }
}

extension View {
    /// The standard panel used throughout Budgy.
    func card(padding: CGFloat = 16) -> some View {
        modifier(CardBackground(padding: padding))
    }
}

// MARK: - Icons

/// An SF Symbol on a soft, tinted pebble. Each symbol gets its own subtly different pebble shape.
struct IconBadge: View {
    var systemImage: String
    var color: Color
    var size: CGFloat = 32

    var body: some View {
        Image(systemName: systemImage)
            // Sized to the pebble, not to text: the pebble itself is a fixed size.
            .font(.system(size: size * 0.42, weight: .medium))
            .foregroundStyle(color)
            .frame(width: size, height: size)
            .background {
                Pebble(seed: systemImage.stableHash)
                    .fill(color.opacity(0.15))
            }
            .accessibilityHidden(true)
    }
}

// MARK: - Section headers

/// A serif section title above a panel, with an optional quiet detail on the right.
struct SectionHeader: View {
    var title: String
    var trailing: String?

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title)
                .font(.display(.title3))
            Spacer()
            if let trailing {
                Text(trailing)
                    .font(.subheadline)
                    .foregroundStyle(.inkSecondary)
                    .monospacedDigit()
            }
        }
        .padding(.horizontal, 4)
        .padding(.top, 14)
        .accessibilityAddTraits(.isHeader)
    }
}

// MARK: - Progress

/// A thin bar that turns ochre then clay as you approach and pass a budget.
struct BudgetBar: View {
    var spent: Double
    var budget: Double
    var color: Color
    var height: CGFloat = 6

    private var fraction: Double { budget > 0 ? spent / budget : (spent > 0 ? 1 : 0) }

    private var barColor: Color {
        if fraction > 1 { return .negative }
        if fraction > 0.85 { return .caution }
        return color
    }

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.ink.opacity(0.07))
                Capsule()
                    .fill(barColor)
                    .frame(width: max(proxy.size.width * min(max(fraction, 0), 1), fraction > 0 ? height : 0))
            }
        }
        .frame(height: height)
        .accessibilityElement()
        .accessibilityLabel("\(Int(fraction * 100)) percent of budget used")
    }
}

/// Progress toward something good (a goal, the Roth limit, a money step): no warning colors near the end.
struct ProgressBar: View {
    var value: Double
    var color: Color
    var height: CGFloat = 6

    private var clamped: Double { min(max(value, 0), 1) }

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.ink.opacity(0.07))
                Capsule()
                    .fill(color)
                    .frame(width: max(proxy.size.width * clamped, clamped > 0 ? height : 0))
            }
        }
        .frame(height: height)
        .accessibilityElement()
        .accessibilityValue(clamped.formatted(.percent.precision(.fractionLength(0))))
    }
}

/// A goal's growth ring: a fine arc around a pebble that grows as the goal fills.
struct ProgressRing: View {
    var progress: Double
    var color: Color
    var lineWidth: CGFloat = 6
    /// Varies the inner pebble's shape, e.g. by goal icon.
    var seed: UInt64 = 7

    private var clamped: Double { min(max(progress, 0), 1) }

    var body: some View {
        ZStack {
            Circle().stroke(color.opacity(0.14), lineWidth: lineWidth)
            Circle()
                .trim(from: 0, to: clamped)
                .stroke(color, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
            // Area grows with progress, so the pebble's radius follows the square root.
            Pebble(seed: seed)
                .fill(color.opacity(0.16))
                .scaleEffect(0.18 + 0.6 * sqrt(clamped))
        }
        .padding(lineWidth / 2)
        .accessibilityElement()
        .accessibilityLabel("\(Int(clamped * 100)) percent complete")
    }
}
