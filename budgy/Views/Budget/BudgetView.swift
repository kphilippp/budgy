import SwiftUI
import SwiftData
import Charts

enum BudgetMode: String, CaseIterable, Identifiable {
    case paycheck = "Per Paycheck"
    case monthly = "Monthly"
    var id: String { rawValue }
}

struct BudgetView: View {
    @State private var mode: BudgetMode = .paycheck
    @State private var offset = 0
    @State private var editingCategory: Category?
    @State private var showNewCategory = false

    var body: some View {
        NavigationStack {
            EngineReader { engine in
                let breakdown = mode == .paycheck ? engine.paycheckBreakdown(offset: offset) : engine.monthlyBreakdown(offset: offset)
                ScrollView {
                    VStack(spacing: 16) {
                        Picker("View", selection: $mode) {
                            ForEach(BudgetMode.allCases) { Text($0.rawValue).tag($0) }
                        }
                        .pickerStyle(.segmented)
                        .onChange(of: mode) { offset = 0 }

                        PeriodNavigator(period: breakdown.period, mode: mode, offset: $offset)

                        if mode == .monthly && breakdown.paydayCount >= 3 {
                            Label("3-paycheck month! Your extra check is a bonus. Consider sending it to a goal.", systemImage: "gift.fill")
                                .font(.subheadline.weight(.medium))
                                .foregroundStyle(.green)
                                .card(padding: 14)
                        }

                        BudgetSummaryCard(breakdown: breakdown, base: engine.basePaycheck)
                        WaterfallChart(breakdown: breakdown)

                        LineSection(title: "Pay Yourself First", lines: breakdown.payYourselfFirst, color: .green)
                        LineSection(title: "Bills", lines: breakdown.bills, color: .orange)
                        LineSection(title: "Subscriptions", lines: breakdown.subscriptions, color: .purple)

                        NavigationLink {
                            SubscriptionsView(embedded: true)
                        } label: {
                            HStack(spacing: 12) {
                                IconBadge(systemImage: "repeat.circle.fill", color: .purple, size: 34)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("Bills & Subscriptions").font(.headline)
                                    Text("Manage recurring charges and Pay Yourself First").font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                                Image(systemName: "chevron.right").foregroundStyle(.tertiary)
                            }
                            .card(padding: 14)
                        }
                        .buttonStyle(.plain)
                        LineSection(title: "Goals", lines: breakdown.goals, color: .pink)

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
                .background(Color(.systemGroupedBackground))
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
    var mode: BudgetMode
    @Binding var offset: Int

    private var title: String {
        switch mode {
        case .monthly:
            return period.start.formatted(.dateTime.month(.wide).year())
        case .paycheck:
            let end = Calendar.current.date(byAdding: .day, value: -1, to: period.end) ?? period.end
            return "\(period.start.formatted(.dateTime.month(.abbreviated).day())) – \(end.formatted(.dateTime.month(.abbreviated).day()))"
        }
    }

    var body: some View {
        HStack {
            Button("Previous", systemImage: "chevron.left") { withAnimation { offset -= 1 } }
                .labelStyle(.iconOnly)
            Spacer()
            VStack(spacing: 2) {
                Text(title).font(.headline)
                Text(offset == 0 ? (mode == .paycheck ? "This paycheck" : "This month") : (offset < 0 ? "Past" : "Upcoming"))
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

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(breakdown.actualIncome > 0 ? "Income received" : "Expected income")
                        .font(.subheadline).foregroundStyle(.secondary)
                    Text(breakdown.income.currencyWhole)
                        .font(.system(.title, design: .rounded).weight(.bold))
                    if breakdown.paydayCount > 0 {
                        Text("Base paycheck \(base.currencyWhole) × \(breakdown.paydayCount)")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 4) {
                    Text("Left over").font(.subheadline).foregroundStyle(.secondary)
                    Text(breakdown.leftOver.currencyWhole)
                        .font(.system(.title, design: .rounded).weight(.bold))
                        .foregroundStyle(breakdown.leftOver >= 0 ? .green : .red)
                    Text("Plan: \(breakdown.plannedLeftOver.currencyWhole)")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }

            // Proportional bar of where the money goes.
            GeometryReader { proxy in
                let total = max(breakdown.income, breakdown.fixedTotal + breakdown.categorySpentTotal, 1)
                let segments: [(Double, Color)] = [
                    (breakdown.payYourselfFirstTotal, .green),
                    (breakdown.billsTotal, .orange),
                    (breakdown.subscriptionsTotal, .purple),
                    (breakdown.goalsTotal, .pink),
                    (breakdown.categorySpentTotal, .blue),
                    (max(breakdown.leftOver, 0), .gray.opacity(0.3))
                ]
                HStack(spacing: 2) {
                    ForEach(Array(segments.enumerated()), id: \.offset) { _, segment in
                        if segment.0 > 0 {
                            Rectangle()
                                .fill(segment.1.gradient)
                                .frame(width: max(proxy.size.width * segment.0 / total - 2, 2))
                        }
                    }
                }
                .clipShape(.capsule)
            }
            .frame(height: 14)
            .accessibilityHidden(true)

            HStack(spacing: 14) {
                legend("Roth", .green)
                legend("Bills", .orange)
                legend("Subs", .purple)
                legend("Goals", .pink)
                legend("Spent", .blue)
            }
            .font(.caption2)
        }
        .card()
    }

    private func legend(_ title: String, _ color: Color) -> some View {
        HStack(spacing: 4) {
            Circle().fill(color).frame(width: 7, height: 7)
            Text(title).foregroundStyle(.secondary)
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
            ("Roth", breakdown.payYourselfFirstTotal, .green),
            ("Bills", breakdown.billsTotal, .orange),
            ("Subs", breakdown.subscriptionsTotal, .purple),
            ("Goals", breakdown.goalsTotal, .pink),
            ("Spent", breakdown.categorySpentTotal, .blue)
        ]
        for part in parts {
            result.append(Step(name: part.0, start: running - part.1, end: running, color: part.2))
            running -= part.1
        }
        result.append(Step(name: "Left", start: min(running, 0), end: max(running, 0), color: running >= 0 ? .mint : .red))
        return result
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionHeader(title: "Where It Goes")
            Chart(steps) { step in
                BarMark(
                    x: .value("Step", step.name),
                    yStart: .value("From", step.start),
                    yEnd: .value("To", step.end),
                    width: .ratio(0.62)
                )
                .foregroundStyle(step.color.gradient)
                .cornerRadius(6)
                .annotation(position: .top, spacing: 4) {
                    Text(abs(step.end - step.start).currencyWhole)
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(.secondary)
                }
            }
            .chartYAxis {
                AxisMarks(position: .leading) { value in
                    AxisGridLine()
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
                                    .foregroundStyle(.green)
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
                            .foregroundStyle(left >= 0 ? AnyShapeStyle(.secondary) : AnyShapeStyle(.red))
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
        self.budget = category?.budgetPerPaycheck ?? 50
        self.systemImage = category?.systemImage ?? "tag.fill"
        self.colorName = category?.colorName ?? "blue"
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    HStack {
                        IconBadge(systemImage: systemImage, color: BudgyColor.named(colorName), size: 44)
                        TextField("Group name", text: $name).font(.title3)
                    }
                }
                Section {
                    LabeledContent("Per paycheck") {
                        TextField("Amount", value: $budget, format: .currency(code: "USD"))
                            .keyboardType(.decimalPad)
                            .multilineTextAlignment(.trailing)
                    }
                } header: {
                    Text("Budget")
                } footer: {
                    Text("About \((budget * 26 / 12).currencyWhole) per month on a biweekly schedule.")
                }
                Section("Icon") {
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 6), spacing: 12) {
                        ForEach(Self.icons, id: \.self) { icon in
                            Button {
                                systemImage = icon
                            } label: {
                                IconBadge(systemImage: icon, color: icon == systemImage ? BudgyColor.named(colorName) : .gray.opacity(0.5), size: 38)
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
            .navigationTitle(category == nil ? "New Group" : "Edit Group")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel", systemImage: "xmark") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save", systemImage: "checkmark") {
                        let target = category ?? {
                            let new = Category(name: name, systemImage: systemImage, colorName: colorName, budgetPerPaycheck: budget, sortOrder: categories.count)
                            context.insert(new)
                            return new
                        }()
                        target.name = name
                        target.budgetPerPaycheck = budget
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
                    Circle()
                        .fill(BudgyColor.named(name).gradient)
                        .frame(width: 32, height: 32)
                        .overlay {
                            if selection == name {
                                Image(systemName: "checkmark").font(.caption.weight(.bold)).foregroundStyle(.white)
                            }
                        }
                }
                .buttonStyle(.plain)
                .accessibilityLabel(name)
            }
        }
    }
}
