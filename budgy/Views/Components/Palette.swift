import SwiftUI
import UIKit

// Budgy's "Tidewater" palette: cool mineral neutrals, one tide-blue accent, and muted organic hues.
// Every color resolves separately for light and dark mode. Rules: .claude/skills/budgy-design/SKILL.md

extension UIColor {
    convenience init(hex: UInt32, alpha: Double = 1) {
        self.init(
            red: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255,
            alpha: alpha
        )
    }
}

extension Color {
    /// A color with separate light- and dark-mode values.
    init(light: UInt32, dark: UInt32, lightAlpha: Double = 1, darkAlpha: Double = 1) {
        self.init(uiColor: UIColor { traits in
            traits.userInterfaceStyle == .dark
                ? UIColor(hex: dark, alpha: darkAlpha)
                : UIColor(hex: light, alpha: lightAlpha)
        })
    }

    // MARK: Surfaces

    /// The page: misty paper in light mode, deep harbor ink in dark mode.
    static let canvas = Color(light: 0xEFF1F3, dark: 0x0B0E11)
    /// Panels that sit on the canvas.
    static let surface = Color(light: 0xFAFBFC, dark: 0x13161A)
    /// Things that float above panels (the swipe card, sheets' fields).
    static let surfaceRaised = Color(light: 0xFFFFFF, dark: 0x191D22)
    /// Panel edges and dividers.
    static let hairline = Color(light: 0x131920, dark: 0xE6EAEE, lightAlpha: 0.09, darkAlpha: 0.08)

    // MARK: Ink

    static let ink = Color(light: 0x131920, dark: 0xE6EAEE)
    static let inkSecondary = Color(light: 0x565D64, dark: 0x939AA2)
    static let inkTertiary = Color(light: 0x8A9096, dark: 0x5F666D)

    // MARK: Organic hues (categories, goals, accounts, semantics)

    static let spruce = Color(light: 0x2E6E5E, dark: 0x4E9F88)
    static let moss = Color(light: 0x46784E, dark: 0x8DBF8F)
    static let ochre = Color(light: 0x9C6129, dark: 0xDDA46E)
    static let clay = Color(light: 0xA8472F, dark: 0xE58C76)
    static let lake = Color(light: 0x3B6A8C, dark: 0x86B0CF)
    static let heather = Color(light: 0x6E5A92, dark: 0xB3A3D6)
    static let rosehip = Color(light: 0xA0506A, dark: 0xDE9AAE)
    static let dusk = Color(light: 0x4D5A92, dark: 0x9FA8DE)
    static let wheat = Color(light: 0x857020, dark: 0xD8C27A)
    static let glacier = Color(light: 0x2E7A89, dark: 0x86C4CF)
    static let sage = Color(light: 0x4D7E6C, dark: 0xA3CDB9)
    static let bark = Color(light: 0x7A5A44, dark: 0xC4A189)
    static let eucalyptus = Color(light: 0x2F7A73, dark: 0x7CC2BA)
    static let stone = Color(light: 0x66706C, dark: 0x9CA6A2)

    // MARK: Semantics

    /// Money that is safe, saved, or on track.
    static let positive = moss
    /// Approaching a limit, due soon, needs a look.
    static let caution = ochre
    /// Over budget, negative, late.
    static let negative = clay
}

// Dot syntax inside `foregroundStyle(_:)`, `fill(_:)`, `tint(_:)` and other ShapeStyle contexts.
extension ShapeStyle where Self == Color {
    static var canvas: Color { Color.canvas }
    static var surface: Color { Color.surface }
    static var surfaceRaised: Color { Color.surfaceRaised }
    static var hairline: Color { Color.hairline }
    static var ink: Color { Color.ink }
    static var inkSecondary: Color { Color.inkSecondary }
    static var inkTertiary: Color { Color.inkTertiary }
    static var spruce: Color { Color.spruce }
    static var moss: Color { Color.moss }
    static var ochre: Color { Color.ochre }
    static var clay: Color { Color.clay }
    static var lake: Color { Color.lake }
    static var heather: Color { Color.heather }
    static var rosehip: Color { Color.rosehip }
    static var dusk: Color { Color.dusk }
    static var wheat: Color { Color.wheat }
    static var glacier: Color { Color.glacier }
    static var sage: Color { Color.sage }
    static var bark: Color { Color.bark }
    static var eucalyptus: Color { Color.eucalyptus }
    static var stone: Color { Color.stone }
    static var positive: Color { Color.positive }
    static var caution: Color { Color.caution }
    static var negative: Color { Color.negative }
}
