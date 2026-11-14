---
name: budgy-design
description: Budgy's "Tidewater" design language and craft rules for its SwiftUI iOS app — mineral palette and sea-glass accent, New York serif display type and typeset money, pebble icons, panels and mist canvas, charts, motion tokens, springs, gestures, haptics, Liquid Glass, Dynamic Type, copy, and accessibility. Use whenever building, restyling, polishing, animating, or reviewing any SwiftUI view in Budgy, adding a screen or component, or when the user asks to make something look or feel nicer. This is the primary design skill for this repo; it routes to narrower skills (gestures, choreograph, break-ui, write-swift, learn-taste, budgy-finance) when a task needs depth.
---

# Budgy Design — Tidewater

Budgy is a calm money app. People open it to answer one question — *what can I spend?* — often
while slightly anxious. The design language, **Tidewater**, is cool, mineral, and organic:
misty paper or deep forest ink underneath, one sea-glass accent, serif figures set like a
statement, and soft irregular "pebbles" where other apps use circles and squares. Every decision
serves **confidence and calm**: the number is clear, the interface responds instantly, nothing
moves without a reason, and important moments (payday, a goal funded, a bill paid) are felt.

The motion and gesture rules are the SwiftUI translation of Apple's WWDC guidance
(`../apple-design/SKILL.md`, written for the web — read it for the *why*, use this file for the
*how*) plus Emil Kowalski's motion rules. When a web-flavored skill conflicts with this file, this
file wins.

Platform: iOS 27.2+, SwiftUI, Liquid Glass, Swift 6 with main-actor-by-default. Dark mode is the
default appearance; every screen must also be checked in light mode.

## Where things live

| Thing | File |
|---|---|
| Palette: `Color.canvas/surface/ink…`, organic hues, semantics, `Color(light:dark:)` | `budgy/Views/Components/Palette.swift` |
| `AppTheme` accents, `BudgyColor`, `.card()`, `IconBadge`, `SectionHeader`, `BudgetBar`, `ProgressBar`, `ProgressRing` | `budgy/Views/Components/Theme.swift` |
| `Motion`, `Radius`, `Pebble`, `Font.display`, `MoneyText`, `heroNumber`, `scaledFont`, `BudgyBackground`, `.budgyCanvas()`, `.budgyList()`, `.budgyRows()`, `.fieldStyle()`, `Tag`, `Haptics`, `.pressable` | `budgy/Views/Components/DesignSystem.swift` |
| Navigation title fonts (New York via UIKit appearance) | `budgy/MyApp.swift` |
| Rules learned from the user's corrections | `DESIGN.md` at the repo root (written by `learn-taste`; read it first if it exists) |

Always reuse these. Never add a second card style, radius, spring, font helper, or a raw color.

## Routing

| Task | Also load |
|---|---|
| A drag, swipe, sheet, fling, hold-to-confirm | `gestures` (then translate with §6) |
| Several things animating together; onboarding and payday flows | `choreograph` |
| "What could animate here?" | `find-animation-opportunities` |
| Reviewing a motion diff | `review-animations` |
| Stress-testing a screen with real-world data | `break-ui` (one `#Preview` per dataset; data enters via `SampleData` / `DemoBankService`) |
| Copy or logic for savings, credit, investing, subscriptions | `budgy-finance` |
| Concurrency, models, tests, logging | `write-swift` |
| End of a design session | `learn-taste` (writes rules to `DESIGN.md`) |

---

## 1. Color

**Never use system colors** (`.green`, `.red`, `.orange`, `.blue`, `Color.gray`, `.white` text on
color…). Use the palette; each token has a light and a dark value.

| Role | Token |
|---|---|
| Page | `.canvas` (misty paper / forest ink) — via `.budgyCanvas()` or `BudgyBackground`, never a raw fill |
| Panels | `.surface`; floating things (swipe card, fields) `.surfaceRaised` |
| Edges, dividers | `.hairline` — `Divider().overlay(Color.hairline)` |
| Text | inherits `.ink` from the root; use `.secondary` / `.tertiary` for hierarchy (they derive from ink) |
| Accent | `@Environment(\.themeColor)` (user-chosen; default Sea Glass) and `.tint` — never `Color.accentColor` |
| Safe, saved, on track | `.positive` (moss) |
| Due soon, near a limit, needs a look | `.caution` (ochre) |
| Over, negative, late | `.negative` (clay) |
| Categories, goals, accounts | `BudgyColor.named(_:)`, `BudgyColor.forAccount(_:)` — organic hues: lake, moss, ochre, rosehip, heather, eucalyptus, dusk, clay, wheat, sage, glacier, bark, stone |

Rules:
- The interface stays ~90% neutral. Color carries meaning, never decoration.
- No gradients on fills (`.gradient` is banned). The only gradients are the mist, a chart's area
  fade, and nothing else.
- **Dark-mode hues are light pastels.** Never put white text on a category hue. Prominent buttons
  use the accent only — it is tuned (mid-tone in dark, deep in light) to carry a white label.
- Stored names never change: `AppTheme` raw values (`teal`, `blue`…) and `BudgyColor.palette`
  strings (`"blue"`, `"green"`…) are persisted; only their colors and titles may change.

## 2. Typography

- **New York serif for display, SF for everything else.** `Font.display(.title3)` for section
  titles, `.display(.largeTitle)` for screen-level headlines in flows, `.display(.headline)` for
  names on tiles. Navigation titles are already New York (set in `MyApp`).
- **Money is typeset with `MoneyText(amount, size:showsCents:)`** — serif figures with a small,
  raised currency symbol (and cents), tabular digits, rolling transitions, a proper minus sign,
  Dynamic Type scaling, and an accessibility label. Use it for every hero or headline amount:
  64 (Today), 56 (net worth, subscriptions, the swipe card), 48 (goals), 38–40 (budget, sheets).
  Small amounts in rows stay SF `.subheadline.weight(.semibold).monospacedDigit()`.
- Non-money hero figures (a percentage, months covered): `.heroNumber(size:)` (serif, tabular).
- **Never `.font(.system(size:))`.** For a big fixed design use `.scaledFont(size:weight:design:)`.
  (`IconBadge` is the one exception: its glyph is sized to its pebble.)
- Sentence case everywhere ("Where it goes", "Net worth"). No tracked capitals. No emoji in UI copy.

## 3. Shape and surfaces

- **Pebbles, not circles or rounded squares.** `IconBadge(systemImage:color:size:)` draws the glyph
  in the hue on a 15% tint of it, on a `Pebble` seeded by the symbol name, so each icon keeps its own
  slightly irregular shape. Use `Pebble(seed: someString.stableHash)` for any other organic round
  (swatches, avatars, selection rings). Never seed with `hashValue` (it changes every launch).
- **Panels** are `.card()` (radius `Radius.panel` 26, `.surface`, hairline edge, no shadow). The
  swipe card uses `Radius.feature` (34) and `.surfaceRaised`. Fields use `.fieldStyle()`.
- **Heroes are unboxed.** A screen's key figure sits directly on the canvas, under the mist, with a
  quiet label above and one line of context below. Panels start after the hero.
- **No glass slabs for content.** Liquid Glass is only the functional layer: toolbars, the tab bar,
  buttons (`.glass`, `.glassProminent`), the Advisor composer. Never glass-on-glass.
- **Shadows**: none, except on app-icon images.
- Spacing scale 4, 8, 12, 16, 20, 24, 32; screen gutters 16 (`.padding(.horizontal)`), flows 24–28.

### Screens and lists

- Primary tab screens: `ScrollView { … }.budgyCanvas()` (canvas + mist). Detail screens:
  `.budgyCanvas(mist: false)`.
- `List`/`Form`: wrap the sections in `Group { … }.budgyRows()` and put `.budgyList()` on the list,
  so rows sit on panel color with hairline separators over the canvas.

## 4. Components

| Need | Use |
|---|---|
| Section title above a panel | `SectionHeader(title:trailing:)` (serif) |
| Status ("On track", "$120 under pace", "Test account") | `Tag(_:systemImage:color:)` |
| Spending against a budget (warns near/over) | `BudgetBar(spent:budget:color:)` |
| Progress toward something good (goal, Roth limit, money step) | `ProgressBar(value:color:)` — never `BudgetBar`, which turns ochre near 100% |
| A goal's progress | `ProgressRing(progress:color:lineWidth:seed:)` — fine arc + a pebble that grows with progress |
| Tappable custom card | `.buttonStyle(.pressable)` |
| Include/exclude an account | the eye `IncludeToggle` in `AccountsView` (not a full-width switch in a crowded row) |
| Primary action | `.buttonStyle(.glassProminent)` + `.foregroundStyle(.white)` — the root ink would otherwise replace the white label |

## 5. Charts

Swift Charts, quiet and organic:
- Lines `.interpolationMethod(.monotone)` (cumulative data) or `.catmullRom` (balances),
  `lineWidth: 2.5`, round caps, in the accent.
- Area under a line: `LinearGradient` of the accent from 0.30 opacity to 0.
- Reference lines (pace, targets): `Color.inkTertiary`, `lineWidth: 1`, `dash: [3, 4]`.
- Hide axes and legends on hero charts; label the two ends in `.caption2` `.tertiary` instead.
  Detail charts may show a y-axis with `AxisGridLine().foregroundStyle(Color.hairline)` and no
  vertical grid.
- Bars: flat hues, `cornerRadius(8)`, no annotation on empty bars.
- Every chart gets an accessibility label and value that state the takeaway.

## 6. Motion

### Tokens — use these, never inline curves

```swift
Motion.standard   // .spring(response: 0.35, dampingFraction: 1.0) — default for state changes
Motion.quick      // .spring(response: 0.25, dampingFraction: 1.0) — toggles, chips, press
Motion.gentle     // .spring(response: 0.5,  dampingFraction: 1.0) — large surfaces, numbers
Motion.momentum   // .spring(response: 0.35, dampingFraction: 0.8) — ONLY after a drag/flick release
Motion.animation(_:reduceMotion:)  // a short fade under Reduce Motion
```

1. **Should it animate at all?** Motion must explain a change. Never animate scrolling, data
   appearing on load, or high-frequency actions.
2. Springs, critically damped, by default. Never `.easeIn` for entering or finger-following motion;
   `.linear` only to show time passing.
3. Bounce only when the user applied force (a flicked card). A celebration is not force.
4. `withAnimation` in the synchronous handler; a `Task` only for slow work after.
5. Sequence with `withAnimation(_, completionCriteria:) { } completion: { }`, never `Task.sleep`.
6. Enter and exit along the same path; sheets and zooms originate from their trigger.
7. Money rolls (`MoneyText` does it); amounts animate with `Motion.gentle`.
8. One timing family per component.

Reduce Motion (`\.accessibilityReduceMotion`): no slides, rotation, scale, or bounce — a short
crossfade or nothing. Direct manipulation stays. Also respect `\.accessibilityReduceTransparency`
and `\.colorSchemeContrast == .increased` (`.card()` already strengthens its edge).

## 7. Gestures

| Concept | SwiftUI |
|---|---|
| Track 1:1 while the finger is down | write `value.translation` straight into `@State`, no animation in `.onChanged` |
| Commit by where the flick is going | `value.predictedEndTranslation` |
| Velocity handoff | `.interpolatingSpring(duration:bounce:initialVelocity: v / remainingDistance)` |
| Rubber-band | `rubberBand(offset, dimension:)` |
| Snap-back | `Motion.momentum` |
| Hysteresis | `DragGesture(minimumDistance: 10)` |
| Crossing the commit line | `.sensoryFeedback(.selection, trigger: zone)` while dragging |
| Feedback on the surface | a wash of the destination's color that deepens with drag progress (see `SortCard`) |

## 8. Haptics

`.sensoryFeedback` by default. When the view that owns the action disappears in the same update (a
card dismissed by its own button), call `Haptics.success()` in the action instead.

| Moment | Feedback |
|---|---|
| Money moved, goal funded, bill matched, payday finished | success |
| Swipe crosses a commit line, include/exclude, picking from a set | selection |
| Card committed after a swipe | impact medium · Undo: impact light |
| Every tap, scroll, keystroke | nothing |

## 9. Copy

A level-headed friend who's good with money: plain, specific, short. Say the fact ("$17 a day
for 14 days · payday Nov 27"). Ban: seamless, effortless, unlock, empower, supercharge, journey,
robust, powerful, "at your fingertips", "not just X, it's Y", "The result? …". No exclamation marks
in body copy. Correct plurals at 0, 1, and many. Empty states say what will appear and how to make
it appear. Keep the user's own voice where they wrote it (e.g. "Ayy, you just got paid!").

## 10. Design review

Debug builds accept launch arguments for screenshots without tapping through onboarding:

```bash
xcrun simctl launch booted com.kevinphilip.budgy -BudgyDemo YES -BudgyNoPayday YES -BudgyTab goals -appearance light
```

`-BudgyDemo YES` signs into the test account with the Demo Bank (first run only),
`-BudgyNoPayday YES` keeps the payday flow closed, `-BudgyTab` is `home|budget|sort|goals|accounts`,
`-appearance` is `dark|light`, `-hasCompletedOnboarding NO` shows onboarding.

## Before you call it done

- [ ] No system colors, no `.gradient` fills, no white text on a category hue.
- [ ] Money headlines use `MoneyText`; no `.font(.system(size:))`.
- [ ] Icons are `IconBadge` pebbles; panels are `.card()`; screens use `.budgyCanvas()`/`.budgyList()`.
- [ ] Prominent buttons: accent + white label.
- [ ] Only `Motion.*` curves, each with a Reduce Motion path.
- [ ] Haptics only on the moments in §8.
- [ ] Checked in dark **and** light mode, and at a large Dynamic Type size.
- [ ] Tried with worst-case data (`break-ui`): huge and negative amounts, 40-character names, zero and one items.
- [ ] Builds: `xcodebuild -project budgy.xcodeproj -scheme budgy -destination 'platform=iOS Simulator,name=iPhone 18 Pro' build`
