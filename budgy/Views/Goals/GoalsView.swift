import SwiftUI
import SwiftData

struct GoalsView: View {
    @State private var showNewGoal = false

    var body: some View {
        NavigationStack {
            EngineReader { engine in
                let active = engine.goals.filter { !$0.isArchived }
                ScrollView {
                    VStack(spacing: 16) {
                        if active.isEmpty {
                            ContentUnavailableView {
                                Label("No goals yet", systemImage: "target")
                            } description: {
                                Text("Save up for a trip, an emergency fund, or anything else. Budgy earmarks money in your savings and tells you how much to set aside each paycheck.")
                            } actions: {
                                Button("Create a Goal") { showNewGoal = true }
                                    .buttonStyle(.glassProminent)
                            }
                            .padding(.top, 60)
                        } else {
                            GoalsSummary(goals: active)
                            LazyVGrid(columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)], spacing: 12) {
                                ForEach(active) { goal in
                                    NavigationLink {
                                        GoalDetailView(goal: goal)
                                    } label: {
                                        GoalTile(goal: goal, status: GoalStatus(goal: goal, engine: engine))
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                        }
                    }
                    .padding(.horizontal)
                    .padding(.bottom, 24)
                }
                .background(Color(.systemGroupedBackground))
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
        case .complete: "Complete 🎉"
        case .onTrack: "On track"
        case .behind: "Behind"
        case .noDeadline: projectedDate.map { "Done \($0.formatted(.dateTime.month(.abbreviated).year()))" } ?? "In progress"
        case .noPlan: "No plan yet"
        }
    }

    var color: Color {
        switch state {
        case .complete, .onTrack: .green
        case .behind: .orange
        case .noDeadline: .secondary
        case .noPlan: .secondary
        }
    }
}

private struct GoalsSummary: View {
    var goals: [Goal]

    var body: some View {
        let saved = goals.reduce(0) { $0 + $1.savedAmount }
        let target = goals.reduce(0) { $0 + $1.targetAmount }
        let perPaycheck = goals.reduce(0) { $0 + $1.contributionPerPaycheck }
        HStack(spacing: 16) {
            ProgressRing(progress: target > 0 ? saved / target : 0, color: .pink, lineWidth: 10)
                .frame(width: 64, height: 64)
            VStack(alignment: .leading, spacing: 4) {
                Text("\(saved.currencyWhole) saved")
                    .font(.title2.weight(.bold))
                Text("of \(target.currencyWhole) across \(goals.count) goal\(goals.count == 1 ? "" : "s")")
                    .font(.subheadline).foregroundStyle(.secondary)
                Text("\(perPaycheck.currencyWhole) per paycheck")
                    .font(.caption.weight(.medium)).foregroundStyle(.pink)
            }
            Spacer()
        }
        .padding(20)
        .glassEffect(.regular.tint(.pink.opacity(0.1)), in: .rect(cornerRadius: 28))
    }
}

private struct GoalTile: View {
    var goal: Goal
    var status: GoalStatus

    var body: some View {
        let color = BudgyColor.named(goal.colorName)
        VStack(alignment: .leading, spacing: 12) {
            ZStack {
                ProgressRing(progress: goal.progress, color: color, lineWidth: 9)
                Image(systemName: goal.systemImage)
                    .font(.title2.weight(.semibold))
                    .foregroundStyle(color)
            }
            .frame(width: 72, height: 72)
            .frame(maxWidth: .infinity)

            VStack(alignment: .leading, spacing: 2) {
                Text(goal.name).font(.headline).lineLimit(1)
                Text("\(goal.savedAmount.currencyWhole) of \(goal.targetAmount.currencyWhole)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            Text(status.label)
                .font(.caption.weight(.semibold))
                .foregroundStyle(status.color)
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
                            ProgressRing(progress: goal.progress, color: color, lineWidth: 16)
                            VStack(spacing: 2) {
                                Text("\(Int(goal.progress * 100))%")
                                    .font(.system(size: 40, weight: .bold, design: .rounded))
                                Text(goal.remaining.currencyWhole + " to go")
                                    .font(.subheadline).foregroundStyle(.secondary)
                            }
                        }
                        .frame(width: 190, height: 190)

                        Text("\(goal.savedAmount.currency) of \(goal.targetAmount.currency)")
                            .font(.headline.monospacedDigit())

                        HStack {
                            Button("Add Money", systemImage: "plus") { adjustment = .add }
                                .buttonStyle(.glassProminent)
                                .tint(color)
                            Button("Withdraw", systemImage: "minus") { adjustment = .withdraw }
                                .buttonStyle(.glass)
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 20)
                    .glassEffect(.regular.tint(color.opacity(0.1)), in: .rect(cornerRadius: 28))

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
                        Text("What if…").font(.headline)
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
                                withAnimation { goal.contributionPerPaycheck = whatIf }
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
            .background(Color(.systemGroupedBackground))
        }
        .navigationTitle(goal.name)
        .toolbar { Button("Edit") { showEdit = true } }
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
                Section {
                    TextField("Amount", value: $amount, format: .currency(code: "USD"))
                        .keyboardType(.decimalPad)
                        .font(.system(.largeTitle, design: .rounded).weight(.bold))
                } footer: {
                    Text(isWithdrawal
                         ? "Un-earmarks money from this goal. Nothing moves in your bank."
                         : "Earmarks money already in your savings for this goal. Nothing moves in your bank.")
                }
            }
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
                                IconBadge(systemImage: icon, color: icon == systemImage ? BudgyColor.named(colorName) : .gray.opacity(0.5), size: 38)
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
