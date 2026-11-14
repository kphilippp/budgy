import SwiftUI
import UIKit

// Budgy's "Tidewater" design system: motion, type, shape, and surfaces.
// The rules behind these live in .claude/skills/budgy-design/SKILL.md — use these instead of inline values.

// MARK: - Motion

enum Motion {
    /// Default for state changes. Critically damped: no overshoot.
    static let standard: Animation = .spring(response: 0.35, dampingFraction: 1.0)
    /// Small toggles, chips, press feedback.
    static let quick: Animation = .spring(response: 0.25, dampingFraction: 1.0)
    /// Large surfaces, screen-level swaps, rolling numbers, charts drawing in.
    static let gentle: Animation = .spring(response: 0.5, dampingFraction: 1.0)
    /// Only after a drag or flick released with force — the slight bounce is earned.
    static let momentum: Animation = .spring(response: 0.35, dampingFraction: 0.8)
    /// What Reduce Motion gets instead: a short crossfade.
    static let reducedFade: Animation = .easeOut(duration: 0.2)

    /// `animation`, or a short fade when Reduce Motion is on.
    static func animation(_ animation: Animation, reduceMotion: Bool) -> Animation {
        reduceMotion ? reducedFade : animation
    }
}

/// Progressive resistance past a boundary: the further you pull, the less it follows.
/// From Apple's *Designing Fluid Interfaces*.
func rubberBand(_ offset: CGFloat, dimension: CGFloat, constant: CGFloat = 0.55) -> CGFloat {
    guard dimension > 0 else { return 0 }
    let resisted = (abs(offset) * dimension * constant) / (dimension + constant * abs(offset))
    return offset < 0 ? -resisted : resisted
}

// MARK: - Shape

enum Radius {
    /// Panels (`.card()`).
    static let panel: CGFloat = 26
    /// The large swipe card on Sort.
    static let feature: CGFloat = 34
    /// Text fields and small tiles.
    static let field: CGFloat = 16
}

extension String {
    /// A hash that is the same on every launch (Swift's `hashValue` is not), for seeding shapes.
    nonisolated var stableHash: UInt64 {
        utf8.reduce(5381 as UInt64) { ($0 &* 33) &+ UInt64($1) }
    }
}

/// A tiny deterministic random generator, so a seed always draws the same pebble.
nonisolated struct SplitMix64 {
    private var state: UInt64

    init(seed: UInt64) { state = seed }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    /// A value in 0..<1.
    mutating func nextUnit() -> CGFloat {
        CGFloat(next() >> 11) / CGFloat(1 << 53)
    }
}

/// A smooth, slightly irregular round: Budgy's organic stand-in for a circle or rounded square.
/// The same seed always draws the same pebble, so each icon keeps its own shape.
nonisolated struct Pebble: Shape {
    var seed: UInt64
    /// How far points may sink inward, as a fraction of the radius.
    var roughness: CGFloat = 0.08

    func path(in rect: CGRect) -> Path {
        var random = SplitMix64(seed: seed)
        let count = 7
        let center = CGPoint(x: rect.midX, y: rect.midY)
        let rotation = random.nextUnit() * 2 * .pi
        let points: [CGPoint] = (0..<count).map { index in
            let angle = rotation + CGFloat(index) / CGFloat(count) * 2 * .pi
            // Sink inward only, so the pebble never spills past its frame.
            let scale = 1 - roughness * random.nextUnit()
            return CGPoint(
                x: center.x + cos(angle) * rect.width / 2 * scale,
                y: center.y + sin(angle) * rect.height / 2 * scale
            )
        }

        // A closed Catmull-Rom spline through the points, drawn as cubic Béziers.
        var path = Path()
        path.move(to: points[0])
        for index in 0..<count {
            let p0 = points[(index + count - 1) % count]
            let p1 = points[index]
            let p2 = points[(index + 1) % count]
            let p3 = points[(index + 2) % count]
            path.addCurve(
                to: p2,
                control1: CGPoint(x: p1.x + (p2.x - p0.x) / 6, y: p1.y + (p2.y - p0.y) / 6),
                control2: CGPoint(x: p2.x - (p3.x - p1.x) / 6, y: p2.y - (p3.y - p1.y) / 6)
            )
        }
        path.closeSubpath()
        return path
    }
}

// MARK: - Typography

extension Font {
    /// New York, for titles and the figures that matter. Body text stays in SF.
    static func display(_ style: Font.TextStyle = .title, weight: Font.Weight = .medium) -> Font {
        .system(style, design: .serif, weight: weight)
    }
}

/// A fixed-design font whose base size scales with Dynamic Type.
private struct ScaledFont: ViewModifier {
    @ScaledMetric private var size: CGFloat
    var weight: Font.Weight
    var design: Font.Design

    init(size: CGFloat, weight: Font.Weight, design: Font.Design, relativeTo textStyle: Font.TextStyle) {
        _size = ScaledMetric(wrappedValue: size, relativeTo: textStyle)
        self.weight = weight
        self.design = design
    }

    func body(content: Content) -> some View {
        content.font(.system(size: size, weight: weight, design: design))
    }
}

extension View {
    /// Use for hero numbers and big symbols instead of `.font(.system(size:))`,
    /// so they grow and shrink with the user's text size.
    func scaledFont(
        size: CGFloat,
        weight: Font.Weight = .regular,
        design: Font.Design = .default,
        relativeTo textStyle: Font.TextStyle = .largeTitle
    ) -> some View {
        modifier(ScaledFont(size: size, weight: weight, design: design, relativeTo: textStyle))
    }

    /// A large figure that isn't money (a percentage, a count): serif, tabular, never wraps.
    func heroNumber(size: CGFloat = 44) -> some View {
        scaledFont(size: size, weight: .regular, design: .serif)
            .monospacedDigit()
            .lineLimit(1)
            .minimumScaleFactor(0.5)
    }
}

/// Money set like a statement: serif figures with a small, raised currency symbol (and cents, if shown).
struct MoneyText: View {
    var amount: Double
    var showsCents: Bool
    var weight: Font.Weight
    @ScaledMetric private var size: CGFloat

    init(_ amount: Double, size: CGFloat = 52, showsCents: Bool = false, weight: Font.Weight = .regular) {
        self.amount = amount
        self.showsCents = showsCents
        self.weight = weight
        _size = ScaledMetric(wrappedValue: size, relativeTo: .largeTitle)
    }

    private struct Parts {
        var sign = ""
        var symbol = ""
        var symbolLeads = true
        var whole = ""
        var fraction = ""
    }

    private var parts: Parts {
        let code = Locale.current.currency?.identifier ?? "USD"
        let formatted = abs(amount).formatted(.currency(code: code).precision(.fractionLength(showsCents ? 2 : 0)))
        let symbol = Locale.current.currencySymbol ?? "$"
        var parts = Parts(sign: amount < 0 ? "−" : "")

        var number = formatted
        if let range = formatted.range(of: symbol) {
            parts.symbol = symbol
            parts.symbolLeads = range.lowerBound == formatted.startIndex
            number.removeSubrange(range)
        }
        number = number.trimmingCharacters(in: .whitespaces)

        let separator = Locale.current.decimalSeparator ?? "."
        if showsCents, let range = number.range(of: separator, options: .backwards) {
            parts.whole = String(number[..<range.lowerBound])
            parts.fraction = String(number[range.lowerBound...])
        } else {
            parts.whole = number
        }
        return parts
    }

    var body: some View {
        let parts = parts
        let small = Font.system(size: size * 0.46, weight: weight, design: .serif)
        let raise = size * 0.38
        let symbol = Text(parts.symbol).font(small).foregroundStyle(.inkSecondary).baselineOffset(raise)
        let fraction = Text(parts.fraction).font(small).foregroundStyle(.inkSecondary).baselineOffset(raise)
        let none = Text(verbatim: "")

        Text("\(Text(verbatim: parts.sign))\(parts.symbolLeads ? symbol : none)\(Text(verbatim: parts.whole))\(fraction)\(parts.symbolLeads ? none : symbol)")
            .font(.system(size: size, weight: weight, design: .serif))
            .monospacedDigit()
            .lineLimit(1)
            .minimumScaleFactor(0.5)
            .contentTransition(.numericText(value: amount))
            .accessibilityLabel(showsCents ? amount.currency : amount.currencyWhole)
    }
}

// MARK: - Surfaces

/// The canvas, with an optional mist of the accent rising from the top edge.
struct BudgyBackground: View {
    @Environment(\.themeColor) private var themeColor
    @Environment(\.colorScheme) private var colorScheme
    var mist = true

    var body: some View {
        Color.canvas
            .overlay(alignment: .top) {
                if mist {
                    let strong = colorScheme == .dark ? 0.30 : 0.20
                    let soft = colorScheme == .dark ? 0.16 : 0.11
                    let clear = Color.canvas.opacity(0)
                    MeshGradient(
                        width: 3, height: 3,
                        points: [
                            [0, 0], [0.55, 0], [1, 0],
                            [0, 0.45], [0.62, 0.52], [1, 0.34],
                            [0, 1], [0.5, 1], [1, 1]
                        ],
                        colors: [
                            themeColor.opacity(strong), Color.glacier.opacity(soft), clear,
                            themeColor.opacity(soft * 0.6), clear, Color.lake.opacity(soft * 0.45),
                            clear, clear, clear
                        ]
                    )
                    .frame(height: 480)
                }
            }
            .ignoresSafeArea()
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}

extension View {
    /// Puts a scrolling screen on the canvas. `mist` for primary screens; plain canvas for detail screens.
    func budgyCanvas(mist: Bool = true) -> some View {
        background { BudgyBackground(mist: mist) }
    }

    /// Restyles a `List` or `Form` onto the canvas. Wrap its sections in a `Group` with
    /// `.budgyRows()` so rows sit on panels instead of system gray.
    func budgyList(mist: Bool = false) -> some View {
        scrollContentBackground(.hidden)
            .background { BudgyBackground(mist: mist) }
    }

    /// Row styling for `List`/`Form` content: panel-colored rows with hairline separators.
    func budgyRows() -> some View {
        listRowBackground(Color.surface)
            .listRowSeparatorTint(Color.hairline)
    }

    /// A text field sitting on its own small panel (onboarding, inline entry).
    func fieldStyle() -> some View {
        padding(14)
            .background(Color.surfaceRaised, in: .rect(cornerRadius: Radius.field, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: Radius.field, style: .continuous)
                    .strokeBorder(Color.hairline, lineWidth: 1)
            }
    }
}

/// A small tinted capsule for status: "On track", "$120 under pace", "Due soon".
struct Tag: View {
    var text: String
    var systemImage: String?
    var color: Color

    init(_ text: String, systemImage: String? = nil, color: Color) {
        self.text = text
        self.systemImage = systemImage
        self.color = color
    }

    var body: some View {
        HStack(spacing: 4) {
            if let systemImage {
                Image(systemName: systemImage).imageScale(.small)
            }
            Text(text)
        }
        .font(.caption.weight(.semibold))
        .foregroundStyle(color)
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(color.opacity(0.14), in: .capsule)
    }
}

// MARK: - Haptics

/// For actions whose view disappears in the same update (a card that's dismissed by its own button),
/// where `.sensoryFeedback` would never see its trigger change. Prefer `.sensoryFeedback` everywhere else.
enum Haptics {
    static func success() {
        UINotificationFeedbackGenerator().notificationOccurred(.success)
    }
}

// MARK: - Press feedback

/// For custom tappable cards: responds on touch-down, not on release.
struct PressableButtonStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .contentShape(.rect)
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.97 : 1)
            .opacity(configuration.isPressed && reduceMotion ? 0.7 : 1)
            .animation(Motion.quick, value: configuration.isPressed)
    }
}

extension ButtonStyle where Self == PressableButtonStyle {
    static var pressable: PressableButtonStyle { PressableButtonStyle() }
}

// MARK: - Zoom navigation

extension View {
    /// Marks a card or row that a pushed screen grows out of (and shrinks back into).
    /// Pair with `zoomDestination(_:in:)` on the destination's root, using the same id and namespace.
    /// The system owns the curve, keeps the interactive swipe back, and crossfades under Reduce Motion.
    func zoomSource(_ id: some Hashable, in namespace: Namespace.ID, cornerRadius: CGFloat = Radius.panel) -> some View {
        matchedTransitionSource(id: id, in: namespace) { source in
            source.clipShape(.rect(cornerRadius: cornerRadius, style: .continuous))
        }
    }

    /// The pushed screen side of `zoomSource(_:in:)`. Put it on the destination's outermost view.
    func zoomDestination(_ id: some Hashable, in namespace: Namespace.ID) -> some View {
        navigationTransition(.zoom(sourceID: id, in: namespace))
    }
}
