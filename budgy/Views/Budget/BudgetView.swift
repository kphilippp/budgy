import SwiftUI
import SwiftData
import Charts

struct BudgetView: View {
    @State private var offset = 0
    @State private var editingCategory: Category?
    @State private var showNewCategory = false

    var body: some View {
        NavigationStack {
            EngineReader { engine in
                let breakdown = engine.budgetMonthBreakdown(offset: offset)
                ScrollView {
                    VStack(spacing: 16) {
                        PeriodNavigator(period: breakdown.period, offset: $offset)

                        if breakdown.paydayCount > engine.paychecksPerMonth {
                            HStack(spacing: 12) {
                                IconBadge(systemImage: "gift.fill", color: .positive, size: 34)
                                Text("Extra paycheck this month. It isn't in your budget, so it's bonus money for a goal.")
                                    .font(.subheadline)
                            }
                            .card(padding: 14)
                        }

                        BudgetSummaryCard(breakdown: breakdown, base: engine.basePaycheck, paychecks: engine.paychecksPerMonth, isOverridden: (engine.schedule?.monthlyIncomeOverride ?? 0) > 0)
                        WaterfallChart(breakdown: breakdown)

                        LineSection(title: "Pay yourself first", lines: breakdown.payYourselfFirst, color: .moss)
                        LineSection(title: "Bills", lines: breakdown.bills, color: .ochre)
                        LineSection(title: "Subscriptions", lines: breakdown.subscriptions, color: .heather)

                        NavigationLink {
                            SubscriptionsView(embedded: true)
                        } label: {
                            HStack(spacing: 12) {
                                IconBadge(systemImage: "repeat.circle.fill", color: .heather, size: 34)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("Bills & Subscriptions").font(.headline)
                                    Text("Manage recurring charges and Pay Yourself First").font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                                Image(systemName: "chevron.right").foregroundStyle(.tertiary)
                            }
                            .card(padding: 14)
                        }
                        .buttonStyle(.pressable)
                        LineSection(title: "Goals", lines: breakdown.goals, color: .rosehip)

                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                SectionHeader(title: "Spending", trailing: "\(breakdown.categorySpentTotal.currencyWhole) of \(breakdown.categoryBudgetTotal.currencyWhole)")
                            }
                            VStack(spacing: 14) {
                                // Subscriptions and Bills groups are covered by the lines above.
                                ForEach(Array(zip(engine.categories, breakdown.categories)).filter { $0.0.systemRole.isEmpty || $0.1.actual > 0 }, id: \.0.id) { category, line in
                                    Button {
                                        editingCategory = category
                                    } label: {
                                        CategoryBudgetRow(line: line)
                                    }
                                    .buttonStyle(.plain)
                                }
                                if breakdown.uncategorizedSpent > 0 {
                                    CategoryBudgetRow(line: BudgetLine(name: "Uncategorized", planned: 0, actual: breakdown.uncategorizedSpent, systemImage: "questionmark", colorName: "gray"))
                                }
                                Button("Add Group", systemImage: "plus") { showNewCategory = true }
                                    .font(.subheadline.weight(.medium))
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            .card()
                        }
                    }
                    .padding(.horizontal)
                    .padding(.bottom, 24)
                }
                .budgyCanvas()
            }
            .navigationTitle("Budget")
            .budgyToolbar()
            .sheet(item: $editingCategory) { category in
                CategoryEditor(category: category)
            }
            .sheet(isPresented: $showNewCategory) {
                CategoryEditor(category: nil)
            }
        }
    }
}

private struct PeriodNavigator: View {
    var period: PayPeriod
    @Binding var offset: Int

    private var title: String {
        let end = Calendar.current.date(byAdding: .day, value: -1, to: period.end) ?? period.end
        return "\(period.start.formatted(.dateTime.month(.abbreviated).day())) – \(end.formatted(.dateTime.month(.abbreviated).day()))"
    }

    var body: some View {
        HStack {
            Button("Previous", systemImage: "chevron.left") { withAnimation { offset -= 1 } }
                .labelStyle(.iconOnly)
            Spacer()
            VStack(spacing: 2) {
                Text(title).font(.display(.title3))
                Text(offset == 0 ? "This budget month" : (offset < 0 ? "Past" : "Upcoming"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("Next", systemImage: "chevron.right") { withAnimation { offset += 1 } }
                .labelStyle(.iconOnly)
        }
        .buttonStyle(.glass)
        .buttonBorderShape(.circle)
    }
}

private struct BudgetSummaryCard: View {
    var breakdown: BudgetBreakdown
    var base: Double
    var paychecks: Int
    var isOverridden: Bool

    private struct Segment: Identifiable {
        var id: String { name }
        var name: String
        var amount: Double
        var color: Color
    }

    private var segments: [Segment] {
        [
            Segment(name: "Saved", amount: breakdown.payYourselfFirstTotal, color: .moss),
            Segment(name: "Bills", amount: breakdown.billsTotal, color: .ochre),
            Segment(name: "Subscriptions", amount: breakdown.subscriptionsTotal, color: .heather),
            Segment(name: "Goals", amount: breakdown.goalsTotal, color: .rosehip),
            Segment(name: "Spent", amount: breakdown.categorySpentTotal, color: .lake),
            Segment(name: "Left", amount: max(breakdown.leftOver, 0), color: Color.ink.opacity(0.12))
        ].filter { $0.amount > 0 }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Monthly income")
                        .font(.subheadline).foregroundStyle(.secondary)
                    MoneyText(breakdown.income, size: 38)
                    Text(isOverridden ? "Set in Settings" : "\(base.currencyWhole) × \(paychecks) paychecks")
                        .font(.caption).foregroundStyle(.secondary)
                    if breakdown.actualIncome > 0 {
                        Text("\(breakdown.actualIncome.currencyWhole) received so far")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 4) {
                    Text("Left over").font(.subheadline).foregroundStyle(.secondary)
                    MoneyText(breakdown.leftOver, size: 38)
                        .foregroundStyle(breakdown.leftOver >= 0 ? .positive : .negative)
                    Text("Plan: \(breakdown.plannedLeftOver.currencyWhole)")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }

            // Where the month's money goes, as separate soft segments.
            GeometryReader { proxy in
                let total = max(segments.reduce(0) { $0 + $1.amount }, 1)
                let gap: CGFloat = 3
                let usable = proxy.size.width - gap * CGFloat(max(segments.count - 1, 0))
                HStack(spacing: gap) {
                    ForEach(segments) { segment in
                        Capsule()
                            .fill(segment.color)
                            .frame(width: max(usable * segment.amount / total, 4))
                    }
                }
            }
            .frame(height: 10)
            .accessibilityHidden(true)

            FlowLegend(items: segments.filter { $0.name != "Left" }.map { ($0.name, $0.color) })
        }
        .padding(.top, 4)
    }
}

/// Small dot-and-label legend that wraps onto a second line when it needs to.
private struct FlowLegend: View {
    var items: [(String, Color)]

    var body: some View {
        ViewThatFits {
            HStack(spacing: 14) { allEntries }
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 14) { entries(items.prefix(3)) }
                HStack(spacing: 14) { entries(items.dropFirst(3)) }
            }
        }
        .font(.caption)
    }

    private var allEntries: some View { entries(items[...]) }

    private func entries(_ slice: ArraySlice<(String, Color)>) -> some View {
        ForEach(Array(slice.enumerated()), id: \.offset) { _, item in
            HStack(spacing: 5) {
                Circle().fill(item.1).frame(width: 7, height: 7)
                Text(item.0).foregroundStyle(.secondary)
            }
        }
    }
}

/// Paycheck → Pay Yourself First → Bills → Subscriptions → Goals → Spending → Left Over.
private struct WaterfallChart: View {
    @Environment(\.themeColor) private var themeColor
    var breakdown: BudgetBreakdown

    private struct Step: Identifiable {
        let id = UUID()
        var name: String
        var start: Double
        var end: Double
        var color: Color
    }

    private var steps: [Step] {
        var running = breakdown.income
        var result = [Step(name: "Pay", start: 0, end: running, color: themeColor)]
        let parts: [(String, Double, Color)] = [
            ("Saved", breakdown.payYourselfFirstTotal, .moss),
            ("Bills", breakdown.billsTotal, .ochre),
            ("Subs", breakdown.subscriptionsTotal, .heather),
            ("Goals", breakdown.goalsTotal, .rosehip),
            ("Spent", breakdown.categorySpentTotal, .lake)
        ]
        for part in parts {
            result.append(Step(name: part.0, start: running - part.1, end: running, color: part.2))
            running -= part.1
        }
        result.append(Step(name: "Left", start: min(running, 0), end: max(running, 0), color: running >= 0 ? .sage : .negative))
        return result
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionHeader(title: "Where it goes")
            Chart(steps) { step in
                BarMark(
                    x: .value("Step", step.name),
                    yStart: .value("From", step.start),
                    yEnd: .value("To", step.end),
                    width: .ratio(0.62)
                )
                .foregroundStyle(step.color)
                .cornerRadius(8)
                .annotation(position: .top, spacing: 4) {
                    if abs(step.end - step.start) >= 1 {
                        Text(abs(step.end - step.start).currencyWhole)
                            .font(.caption2.weight(.medium))
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .chartXAxis {
                AxisMarks { _ in AxisValueLabel() }
            }
            .chartYAxis {
                AxisMarks(position: .leading) { value in
                    AxisGridLine().foregroundStyle(Color.hairline)
                    AxisValueLabel {
                        if let amount = value.as(Double.self) { Text(amount.currencyWhole) }
                    }
                }
            }
            .frame(height: 220)
            .card()
        }
    }
}

private struct LineSection: View {
    var title: String
    var lines: [BudgetLine]
    var color: Color

    var body: some View {
        if !lines.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                SectionHeader(title: title, trailing: lines.reduce(0) { $0 + $1.planned }.currency)
                VStack(spacing: 10) {
                    ForEach(lines) { line in
                        HStack(spacing: 12) {
                            IconBadge(systemImage: line.systemImage, color: BudgyColor.named(line.colorName), size: 30)
                            Text(line.name).font(.subheadline.weight(.medium))
                            Spacer()
                            if line.actual > 0 {
                                Image(systemName: "checkmark.circle.fill")
                                    .foregroundStyle(.positive)
                                    .accessibilityLabel("Paid")
                            }
                            Text(line.planned.currency).font(.subheadline.monospacedDigit())
                        }
                    }
                }
                .card(padding: 14)
            }
        }
    }
}

struct CategoryBudgetRow: View {
    var line: BudgetLine

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                IconBadge(systemImage: line.systemImage, color: BudgyColor.named(line.colorName), size: 30)
                Text(line.name).font(.subheadline.weight(.medium))
                Spacer()
                VStack(alignment: .trailing, spacing: 1) {
                    Text(line.actual.currency).font(.subheadline.weight(.semibold).monospacedDigit())
                    if line.planned > 0 {
                        let left = line.planned - line.actual
                        Text(left >= 0 ? "\(left.currencyWhole) left" : "\(abs(left).currencyWhole) over")
                            .font(.caption)
                            .foregroundStyle(left >= 0 ? AnyShapeStyle(.secondary) : AnyShapeStyle(.clay))
                    }
                }
            }
            if line.planned > 0 {
                BudgetBar(spent: line.actual, budget: line.planned, color: BudgyColor.named(line.colorName))
            }
        }
        .contentShape(.rect)
    }
}

struct CategoryEditor: View {
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @Query private var categories: [Category]

    let category: Category?

    @State private var name: String
    @State private var budget: Double
    @State private var systemImage: String
    @State private var colorName: String

    private static let icons = ["cart.fill", "fork.knife", "car.fill", "bag.fill", "sparkles", "heart.fill", "house.fill", "gift.fill",
                                "pawprint.fill", "gamecontroller.fill", "book.fill", "cup.and.saucer.fill", "tshirt.fill", "graduationcap.fill",
                                "airplane", "wrench.and.screwdriver.fill", "stroller.fill", "square.grid.2x2.fill"]

    init(category: Category?) {
        self.category = category
        self.name = category?.name ?? ""
        self.budget = category?.monthlyBudget ?? 50
        self.systemImage = category?.systemImage ?? "tag.fill"
        self.colorName = category?.colorName ?? "blue"
    }

    var body: some View {
        NavigationStack {
            Form {
                Group {
                    Section {
                        HStack {
                            IconBadge(systemImage: systemImage, color: BudgyColor.named(colorName), size: 44)
                            TextField("Group name", text: $name).font(.title3)
                        }
                    }
                    Section {
                        LabeledContent("Per month") {
                            TextField("Amount", value: $budget, format: .currency(code: "USD"))
                                .keyboardType(.decimalPad)
                                .multilineTextAlignment(.trailing)
                        }
                    } header: {
                        Text("Budget")
                    } footer: {
                        Text("About \((budget / 30).currencyWhole) a day over a budget month.")
                    }
                    Section("Icon") {
                        LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 6), spacing: 12) {
                            ForEach(Self.icons, id: \.self) { icon in
                                Button {
                                    systemImage = icon
                                } label: {
                                    IconBadge(systemImage: icon, color: icon == systemImage ? BudgyColor.named(colorName) : .stone.opacity(0.5), size: 38)
                                }
                                .buttonStyle(.plain)
                                .accessibilityLabel(icon)
                            }
                        }
                    }
                    Section("Color") {
                        ColorPickerRow(selection: $colorName)
                    }
                    if let category {
                        Section {
                            Button("Delete Group", role: .destructive) {
                                category.deleteGroup(context: context)
                                try? context.save()
                                dismiss()
                            }
                        }
                    }
                }
                .budgyRows()
            }
            .budgyList()
            .navigationTitle(category == nil ? "New Group" : "Edit Group")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel", systemImage: "xmark") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save", systemImage: "checkmark") {
                        let target = category ?? {
                            let new = Category(name: name, systemImage: systemImage, colorName: colorName, monthlyBudget: budget, sortOrder: categories.count)
                            context.insert(new)
                            return new
                        }()
                        target.name = name
                        target.monthlyBudget = budget
                        target.systemImage = systemImage
                        target.colorName = colorName
                        try? context.save()
                        dismiss()
                    }
                    .disabled(name.isEmpty)
                }
            }
        }
    }
}

struct ColorPickerRow: View {
    @Binding var selection: String

    var body: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 6), spacing: 12) {
            ForEach(BudgyColor.palette, id: \.self) { name in
                Button {
                    selection = name
                } label: {
                    Pebble(seed: name.stableHash)
                        .fill(BudgyColor.named(name))
                        .frame(width: 32, height: 32)
                        .overlay {
                            Pebble(seed: name.stableHash)
                                .stroke(Color.ink.opacity(selection == name ? 0.7 : 0), lineWidth: 2)
                                .padding(-5)
                        }
                }
                .buttonStyle(.plain)
                .accessibilityLabel(name)
                .accessibilityAddTraits(selection == name ? .isSelected : [])
            }
        }
    }
}
