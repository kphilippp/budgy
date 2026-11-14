import SwiftUI
import SwiftData

struct GoalsView: View {
    @Environment(\.themeColor) private var themeColor
    @State private var showNewGoal = false
    @Namespace private var zoom

    var body: some View {
        NavigationStack {
            EngineReader { engine in
                let active = engine.goals.filter { !$0.isArchived }
                ScrollView {
                    VStack(spacing: 16) {
                        EmergencyFundCard(fund: engine.emergencyFund)
                        if active.isEmpty {
                            VStack(spacing: 14) {
                                IconBadge(systemImage: "mountain.2.fill", color: themeColor, size: 84)
                                Text("No goals yet")
                                    .font(.display(.title2))
                                Text("Save up for a trip, a laptop, or anything else. Budgy earmarks money in your savings and tells you how much to set aside each paycheck.")
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                                    .multilineTextAlignment(.center)
                                Button("Create a Goal") { showNewGoal = true }
                                    .buttonStyle(.glassProminent)
                                    .foregroundStyle(.white)
                                    .controlSize(.large)
                                    .padding(.top, 6)
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.horizontal, 12)
                            .padding(.top, 48)
                        } else {
                            GoalsSummary(goals: active)
                            LazyVGrid(columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)], spacing: 12) {
                                ForEach(active) { goal in
                                    NavigationLink {
                                        GoalDetailView(goal: goal)
                                            .zoomDestination(goal.id, in: zoom)
                                    } label: {
                                        GoalTile(goal: goal, status: GoalStatus(goal: goal, engine: engine))
                                            .zoomSource(goal.id, in: zoom)
                                    }
                                    .buttonStyle(.pressable)
                                }
                            }
                        }
                    }
                    .padding(.horizontal)
                    .padding(.bottom, 24)
                }
                .budgyCanvas()
            }
            .navigationTitle("Goals")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("New Goal", systemImage: "plus") { showNewGoal = true }
                }
            }
            .budgyToolbar()
            .sheet(isPresented: $showNewGoal) { GoalEditor(goal: nil) }
        }
    }
}

/// Emergency savings measured in months of spending covered, with 3- and 6-month milestones.
private struct EmergencyFundCard: View {
    var fund: EmergencyFundStatus

    private var months: Double { fund.monthsCovered }

    private var status: String {
        if fund.monthlySpending <= 0 { return "Budgy needs some spending history or bills to size this." }
        if !fund.hasStarterCushion { return "Start with \(fund.starterTarget.currencyWhole) so a surprise bill doesn't go on a card." }
        if months < EmergencyFundStatus.solidMonths { return "\((fund.solidTarget - fund.amount).currencyWhole) more reaches 3 months." }
        if months < EmergencyFundStatus.fullMonths { return "Solid. \((fund.fullTarget - fund.amount).currencyWhole) more reaches 6 months, worth aiming for if your pay varies." }
        return "Fully funded. Extra savings can go toward investing."
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .center, spacing: 12) {
                IconBadge(systemImage: "shield.lefthalf.filled", color: .positive, size: 40)
                Text("Emergency fund")
                    .font(.headline)
                Spacer()
                Text("\(months.formatted(.number.precision(.fractionLength(1)))) mo")
                    .font(.display(.title2).monospacedDigit())
                    .foregroundStyle(months >= EmergencyFundStatus.solidMonths ? .positive : .primary)
                    .contentTransition(.numericText(value: months))
            }

            GeometryReader { proxy in
                let width = proxy.size.width
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.ink.opacity(0.07))
                    Capsule()
                        .fill(Color.positive)
                        .frame(width: max(width * min(months / EmergencyFundStatus.fullMonths, 1), 6))
                    // 3-month milestone tick.
                    Rectangle()
                        .fill(Color.surface)
                        .frame(width: 2)
                        .offset(x: width * EmergencyFundStatus.solidMonths / EmergencyFundStatus.fullMonths - 1)
                }
            }
            .frame(height: 10)
            .accessibilityHidden(true)

            HStack {
                Text("\(fund.amount.currencyWhole) saved")
                Spacer()
                Text("3 mo · 6 mo")
            }
            .font(.caption.weight(.medium))
            .foregroundStyle(.secondary)

            Text(status)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Text(fund.spendingIsEstimated
                 ? "Based on \(fund.monthlySpending.currencyWhole)/mo from your bills and budgets. Savings earmarked for other goals don't count."
                 : "Based on \(fund.monthlySpending.currencyWhole)/mo, your average spending over the last 90 days. Savings earmarked for other goals don't count.")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .card()
        .accessibilityElement(children: .combine)
    }
}

/// On-track status for a goal with a deadline.
struct GoalStatus {
    enum Kind { case complete, onTrack, behind, noDeadline, noPlan }

    var state: Kind
    var requiredPerPaycheck: Double?
    var projectedDate: Date?

    init(goal: Goal, engine: FinanceEngine) {
        requiredPerPaycheck = engine.requiredPerPaycheck(for: goal)
        projectedDate = engine.projectedCompletion(for: goal, perPaycheck: goal.contributionPerPaycheck)
        if goal.isComplete {
            state = .complete
        } else if goal.contributionPerPaycheck <= 0 {
            state = .noPlan
        } else if let required = requiredPerPaycheck {
            state = goal.contributionPerPaycheck + 0.5 >= required ? .onTrack : .behind
        } else {
            state = .noDeadline
        }
    }

    var label: String {
        switch state {
        case .complete: "Complete"
        case .onTrack: "On track"
        case .behind: "Behind"
        case .noDeadline: projectedDate.map { "Done \($0.formatted(.dateTime.month(.abbreviated).year()))" } ?? "In progress"
        case .noPlan: "No plan yet"
        }
    }

    var color: Color {
        switch state {
        case .complete, .onTrack: .positive
        case .behind: .caution
        case .noDeadline: .secondary
        case .noPlan: .secondary
        }
    }
}

private struct GoalsSummary: View {
    @Environment(\.themeColor) private var themeColor
    var goals: [Goal]

    var body: some View {
        let saved = goals.reduce(0) { $0 + $1.savedAmount }
        let target = goals.reduce(0) { $0 + $1.targetAmount }
        let perPaycheck = goals.reduce(0) { $0 + $1.contributionPerPaycheck }
        HStack(alignment: .center, spacing: 18) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Saved toward goals")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.secondary)
                MoneyText(saved, size: 48)
                Text("of \(target.currencyWhole) across \(goals.count) goal\(goals.count == 1 ? "" : "s") · \(perPaycheck.currencyWhole) per paycheck")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            ProgressRing(progress: target > 0 ? saved / target : 0, color: themeColor, lineWidth: 5, seed: 41)
                .frame(width: 76, height: 76)
        }
        .padding(.top, 4)
    }
}

private struct GoalTile: View {
    var goal: Goal
    var status: GoalStatus

    var body: some View {
        let color = BudgyColor.named(goal.colorName)
        VStack(alignment: .leading, spacing: 12) {
            ZStack {
                ProgressRing(progress: goal.progress, color: color, lineWidth: 4, seed: goal.systemImage.stableHash)
                Image(systemName: goal.systemImage)
                    .font(.title3.weight(.medium))
                    .foregroundStyle(color)
            }
            .frame(width: 76, height: 76)
            .frame(maxWidth: .infinity)

            VStack(alignment: .leading, spacing: 2) {
                Text(goal.name).font(.display(.headline)).lineLimit(1)
                Text("\(goal.savedAmount.currencyWhole) of \(goal.targetAmount.currencyWhole)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            Tag(status.label, color: status.color)
        }
        .card()
    }
}

struct GoalDetailView: View {
    @Environment(\.modelContext) private var context
    @Bindable var goal: Goal
    @State private var whatIf: Double = 0
    @State private var showEdit = false
    @State private var adjustment: Adjustment?

    enum Adjustment: Identifiable {
        case add, withdraw
        var id: Self { self }
    }

    var body: some View {
        EngineReader { engine in
            let status = GoalStatus(goal: goal, engine: engine)
            let color = BudgyColor.named(goal.colorName)
            ScrollView {
                VStack(spacing: 16) {
                    VStack(spacing: 16) {
                        ZStack {
                            ProgressRing(progress: goal.progress, color: color, lineWidth: 7, seed: goal.systemImage.stableHash)
                            VStack(spacing: 2) {
                                Text("\(Int(goal.progress * 100))%")
                                    .heroNumber(size: 46)
                                    .contentTransition(.numericText(value: goal.progress))
                                Text(goal.remaining.currencyWhole + " to go")
                                    .font(.subheadline).foregroundStyle(.secondary)
                            }
                        }
                        .frame(width: 210, height: 210)

                        Text("\(goal.savedAmount.currency) of \(goal.targetAmount.currency)")
                            .font(.display(.headline).monospacedDigit())

                        HStack {
                            Button("Add Money", systemImage: "plus") { adjustment = .add }
                                .buttonStyle(.glassProminent)
                                .foregroundStyle(.white)
                            Button("Withdraw", systemImage: "minus") { adjustment = .withdraw }
                                .buttonStyle(.glass)
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)

                    VStack(alignment: .leading, spacing: 10) {
                        row("Per paycheck", goal.contributionPerPaycheck.currency)
                        if let deadline = goal.deadline {
                            row("Deadline", deadline.formatted(.dateTime.month(.wide).day().year()))
                        }
                        if let required = status.requiredPerPaycheck {
                            row("Needed per paycheck", required.currency)
                        }
                        if let projected = status.projectedDate {
                            row("Projected finish", projected.formatted(.dateTime.month(.wide).year()))
                        }
                        HStack {
                            Text("Status").foregroundStyle(.secondary)
                            Spacer()
                            Text(status.label).fontWeight(.semibold).foregroundStyle(status.color)
                        }
                    }
                    .font(.subheadline)
                    .card()

                    // What-if planner.
                    VStack(alignment: .leading, spacing: 12) {
                        Text("What if…").font(.display(.title3))
                        Text("I put \(whatIf.currencyWhole) toward this each paycheck")
                            .font(.subheadline)
                        Slider(value: $whatIf, in: 0...max(500, goal.contributionPerPaycheck * 2), step: 5)
                            .tint(color)
                        if let finish = engine.projectedCompletion(for: goal, perPaycheck: whatIf) {
                            let current = status.projectedDate
                            Text("You'd finish **\(finish.formatted(.dateTime.month(.wide).year()))**" + comparison(finish, current))
                                .font(.subheadline)
                        } else {
                            Text("Move the slider to see when you'd finish.")
                                .font(.subheadline).foregroundStyle(.secondary)
                        }
                        if abs(whatIf - goal.contributionPerPaycheck) >= 1 {
                            Button("Use \(whatIf.currencyWhole) per paycheck") {
                                withAnimation(Motion.standard) { goal.contributionPerPaycheck = whatIf }
                                try? context.save()
                                SyncService.performHousekeeping(context: context)
                            }
                            .buttonStyle(.glass)
                        }
                    }
                    .card()
                }
                .padding(.horizontal)
                .padding(.bottom, 24)
            }
            .budgyCanvas()
        }
        .navigationTitle(goal.name)
        .toolbar { Button("Edit") { showEdit = true } }
        // Money added to a goal is a moment worth feeling; withdrawals stay quiet.
        .sensoryFeedback(trigger: goal.savedAmount) { old, new in new > old ? .success : nil }
        .animation(Motion.gentle, value: goal.savedAmount)
        .sheet(isPresented: $showEdit) { GoalEditor(goal: goal) }
        .sheet(item: $adjustment) { kind in
            GoalAdjustSheet(goal: goal, isWithdrawal: kind == .withdraw)
        }
        .onAppear { whatIf = goal.contributionPerPaycheck }
    }

    private func row(_ title: String, _ value: String) -> some View {
        HStack {
            Text(title).foregroundStyle(.secondary)
            Spacer()
            Text(value).monospacedDigit()
        }
    }

    private func comparison(_ finish: Date, _ current: Date?) -> String {
        guard let current else { return "." }
        let months = Calendar.current.dateComponents([.month], from: current, to: finish).month ?? 0
        if months < 0 { return ", \(-months) month\(months == -1 ? "" : "s") sooner." }
        if months > 0 { return ", \(months) month\(months == 1 ? "" : "s") later." }
        return "."
    }
}

private struct GoalAdjustSheet: View {
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    var goal: Goal
    var isWithdrawal: Bool
    @State private var amount: Double = 0

    var body: some View {
        NavigationStack {
            Form {
                Group {
                    Section {
                        TextField("Amount", value: $amount, format: .currency(code: "USD"))
                            .keyboardType(.decimalPad)
                            .font(.system(.largeTitle, design: .serif))
                    } footer: {
                        Text(isWithdrawal
                             ? "Un-earmarks money from this goal. Nothing moves in your bank."
                             : "Earmarks money already in your savings for this goal. Nothing moves in your bank.")
                    }
                }
                .budgyRows()
            }
            .budgyList()
            .navigationTitle(isWithdrawal ? "Withdraw" : "Add to \(goal.name)")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel", systemImage: "xmark") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save", systemImage: "checkmark") {
                        goal.savedAmount = max(goal.savedAmount + (isWithdrawal ? -amount : amount), 0)
                        try? context.save()
                        dismiss()
                    }
                    .disabled(amount <= 0)
                }
            }
        }
        .presentationDetents([.medium])
    }
}

struct GoalEditor: View {
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @Query private var goals: [Goal]

    let goal: Goal?

    @State private var name: String
    @State private var target: Double
    @State private var saved: Double
    @State private var perPaycheck: Double
    @State private var hasDeadline: Bool
    @State private var deadline: Date
    @State private var systemImage: String
    @State private var colorName: String

    private static let icons = ["airplane", "cross.case.fill", "laptopcomputer", "car.fill", "house.fill", "gift.fill", "graduationcap.fill",
                                "heart.fill", "camera.fill", "gamecontroller.fill", "ring", "pawprint.fill", "beach.umbrella.fill", "star.fill",
                                "iphone", "bicycle", "music.note", "sparkles"]

    init(goal: Goal?) {
        self.goal = goal
        self.name = goal?.name ?? ""
        self.target = goal?.targetAmount ?? 1_000
        self.saved = goal?.savedAmount ?? 0
        self.perPaycheck = goal?.contributionPerPaycheck ?? 50
        self.hasDeadline = goal?.deadline != nil
        self.deadline = goal?.deadline ?? Calendar.current.date(byAdding: .month, value: 6, to: .now) ?? .now
        self.systemImage = goal?.systemImage ?? "star.fill"
        self.colorName = goal?.colorName ?? "purple"
    }

    var body: some View {
        NavigationStack {
            Form {
                Group {
                    Section {
                        HStack {
                            IconBadge(systemImage: systemImage, color: BudgyColor.named(colorName), size: 44)
                            TextField("Goal name", text: $name).font(.title3)
                        }
                    }
                    Section {
                        currencyField("Target", $target)
                        currencyField("Already saved", $saved)
                        currencyField("Per paycheck", $perPaycheck)
                    }
                    Section {
                        Toggle("Deadline", isOn: $hasDeadline.animation())
                        if hasDeadline {
                            DatePicker("Finish by", selection: $deadline, in: Date.now..., displayedComponents: .date)
                        }
                    }
                    Section("Icon") {
                        LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 6), spacing: 12) {
                            ForEach(Self.icons, id: \.self) { icon in
                                Button { systemImage = icon } label: {
                                    IconBadge(systemImage: icon, color: icon == systemImage ? BudgyColor.named(colorName) : .stone.opacity(0.5), size: 38)
                                }
                                .buttonStyle(.plain)
                                .accessibilityLabel(icon)
                            }
                        }
                    }
                    Section("Color") { ColorPickerRow(selection: $colorName) }
                    if let goal {
                        Section {
                            Button(goal.isArchived ? "Unarchive" : "Archive Goal") {
                                goal.isArchived.toggle()
                                try? context.save()
                                dismiss()
                            }
                            Button("Delete Goal", role: .destructive) {
                                context.delete(goal)
                                try? context.save()
                                dismiss()
                            }
                        }
                    }
                }
                .budgyRows()
            }
            .budgyList()
            .navigationTitle(goal == nil ? "New Goal" : "Edit Goal")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel", systemImage: "xmark") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save", systemImage: "checkmark", action: save).disabled(name.isEmpty || target <= 0)
                }
            }
        }
    }

    private func currencyField(_ title: String, _ value: Binding<Double>) -> some View {
        LabeledContent(title) {
            TextField(title, value: value, format: .currency(code: "USD"))
                .keyboardType(.decimalPad)
                .multilineTextAlignment(.trailing)
        }
    }

    private func save() {
        let target = goal ?? {
            let new = Goal(name: name, systemImage: systemImage, colorName: colorName, targetAmount: self.target)
            new.sortOrder = goals.count
            context.insert(new)
            return new
        }()
        target.name = name
        target.targetAmount = self.target
        target.savedAmount = saved
        target.contributionPerPaycheck = perPaycheck
        target.deadline = hasDeadline ? deadline : nil
        target.systemImage = systemImage
        target.colorName = colorName
        try? context.save()
        SyncService.performHousekeeping(context: context)
        dismiss()
    }
}
