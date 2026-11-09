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

/// The app-wide theme color, chosen in Settings → Display.
enum AppTheme: String, CaseIterable, Identifiable {
    case teal, blue, indigo, purple, pink, orange, green, graphite

    var id: String { rawValue }

    var title: String {
        switch self {
        case .teal: "Budgy Teal"
        case .blue: "Blue"
        case .indigo: "Indigo"
        case .purple: "Purple"
        case .pink: "Pink"
        case .orange: "Orange"
        case .green: "Green"
        case .graphite: "Graphite"
        }
    }

    var color: Color {
        switch self {
        case .teal: Color(red: 0.13, green: 0.72, blue: 0.62)
        case .blue: Color(red: 0.04, green: 0.52, blue: 1.0)
        case .indigo: Color(red: 0.37, green: 0.36, blue: 0.90)
        case .purple: Color(red: 0.69, green: 0.32, blue: 0.87)
        case .pink: Color(red: 1.0, green: 0.22, blue: 0.47)
        case .orange: Color(red: 1.0, green: 0.58, blue: 0.0)
        case .green: Color(red: 0.20, green: 0.78, blue: 0.35)
        case .graphite: Color(red: 0.56, green: 0.56, blue: 0.60)
        }
    }
}

extension EnvironmentValues {
    /// The user's theme color. Set once in `RootView`; read it instead of `Color.accentColor`.
    @Entry var themeColor: Color = AppTheme.teal.color
}

enum BudgyColor {

    /// Names you can pick for categories and goals.
    static let palette = ["blue", "green", "orange", "pink", "purple", "teal", "indigo", "red", "yellow", "mint", "cyan", "brown"]

    static func named(_ name: String) -> Color {
        switch name {
        case "blue": .blue
        case "green": .green
        case "orange": .orange
        case "pink": .pink
        case "purple": .purple
        case "teal": .teal
        case "indigo": .indigo
        case "red": .red
        case "yellow": .yellow
        case "mint": .mint
        case "cyan": .cyan
        case "brown": .brown
        default: .accentColor
        }
    }

    static func forAccount(_ kind: AccountKind) -> Color {
        switch kind {
        case .checking: .blue
        case .savings: .green
        case .creditCard: .orange
        case .retirement401k: .indigo
        case .rothIRA: .mint
        case .brokerage: .purple
        case .other: .gray
        }
    }
}

// MARK: - Card styling

struct CardBackground: ViewModifier {
    var padding: CGFloat = 16

    func body(content: Content) -> some View {
        content
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background {
                RoundedRectangle(cornerRadius: 24, style: .continuous)
                    .fill(.background.secondary)
            }
    }
}

extension View {
    /// The standard rounded card used throughout Budgy.
    func card(padding: CGFloat = 16) -> some View {
        modifier(CardBackground(padding: padding))
    }
}

/// A rounded colored square with an SF Symbol, like Settings icons.
struct IconBadge: View {
    var systemImage: String
    var color: Color
    var size: CGFloat = 32

    var body: some View {
        Image(systemName: systemImage)
            .font(.system(size: size * 0.45, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background {
                RoundedRectangle(cornerRadius: size * 0.28, style: .continuous)
                    .fill(color.gradient)
            }
            .accessibilityHidden(true)
    }
}

/// A section title used above cards.
struct SectionHeader: View {
    var title: String
    var trailing: String?

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title)
                .font(.title3.weight(.semibold))
            Spacer()
            if let trailing {
                Text(trailing)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 4)
        .padding(.top, 8)
    }
}

/// A thin capsule progress bar that turns orange then red as you approach and exceed a budget.
struct BudgetBar: View {
    var spent: Double
    var budget: Double
    var color: Color
    var height: CGFloat = 8

    private var fraction: Double { budget > 0 ? spent / budget : (spent > 0 ? 1 : 0) }

    private var barColor: Color {
        if fraction > 1 { return .red }
        if fraction > 0.85 { return .orange }
        return color
    }

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(.quaternary)
                Capsule()
                    .fill(barColor.gradient)
                    .frame(width: proxy.size.width * min(max(fraction, 0), 1))
            }
        }
        .frame(height: height)
        .accessibilityElement()
        .accessibilityLabel("\(Int(fraction * 100)) percent of budget used")
    }
}

/// A circular progress ring for goals.
struct ProgressRing: View {
    var progress: Double
    var color: Color
    var lineWidth: CGFloat = 8

    var body: some View {
        ZStack {
            Circle().stroke(color.opacity(0.18), lineWidth: lineWidth)
            Circle()
                .trim(from: 0, to: min(max(progress, 0), 1))
                .stroke(color.gradient, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
        }
        .accessibilityElement()
        .accessibilityLabel("\(Int(progress * 100)) percent complete")
    }
}
