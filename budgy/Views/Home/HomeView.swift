import SwiftUI
import SwiftData
import Charts

/// What period Safe to Spend covers.
enum SpendHorizon: String, CaseIterable, Identifiable {
    case payday = "Paycheck"
    case month = "Month"
    case custom = "Pick Date"

    var id: String { rawValue }
}

struct HomeView: View {
    @Environment(\.modelContext) private var context
    @Environment(SyncService.self) private var sync
    @Query(filter: #Predicate<Account> { $0.isSample }) private var sampleAccounts: [Account]

    @State private var horizon: SpendHorizon = .payday
    @State private var customDate = Calendar.current.date(byAdding: .day, value: 21, to: .now) ?? .now
    @State private var showBreakdown = false
    @State private var showAddTransaction = false
    @State private var showSubscriptions = false

    var body: some View {
        NavigationStack {
            EngineReader { engine in
                let until = untilDate(engine)
                let windowStart = windowStart(engine)
                let result = engine.safeToSpend(until: until)
                let groups = engine.groupSpending(since: windowStart, until: until)
                ScrollView {
                    VStack(spacing: 16) {
                        if !sampleAccounts.isEmpty {
                            SampleDataBanner()
                        }

                        SafeToSpendCard(
                            result: result,
                            spent: engine.discretionarySpent(since: windowStart),
                            groups: groups,
                            horizon: $horizon,
                            customDate: $customDate
                        ) {
                            showBreakdown = true
                        }
                        .sheet(isPresented: $showBreakdown) {
                            SafeToSpendBreakdownView(result: result)
                        }

                        ForEach(engine.unassignedExtraPay, id: \.transaction.id) { item in
                            ExtraPayCard(paycheck: item.transaction, extra: item.extra, goals: engine.goals.filter { !$0.isArchived && !$0.isComplete })
                        }

                        if !engine.unfundedGoalsThisPeriod.isEmpty {
                            FundGoalsCard(goals: engine.unfundedGoalsThisPeriod, periodStart: engine.currentPeriod.start)
                        }

                        SpendingGroupsSection(groups: groups, windowStart: windowStart, unsortedCount: engine.unsortedTransactions.count)

                        InvestmentGroupsSection(engine: engine)

                        RecentTransactionsCard(transactions: Array(engine.transactions.sorted { $0.date > $1.date }.prefix(6)))
                    }
                    .padding(.horizontal)
                    .padding(.bottom, 24)
                }
                .background(Color(.systemGroupedBackground))
                .refreshable { await sync.sync(context: context) }
            }
            .navigationTitle("Budgy")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Add Transaction", systemImage: "plus") { showAddTransaction = true }
                }
                ToolbarItem(placement: .topBarLeading) {
                    Button("Subscriptions", systemImage: "repeat") { showSubscriptions = true }
                }
            }
            .navigationDestination(isPresented: $showSubscriptions) {
                SubscriptionsView(embedded: true)
            }
            .budgyToolbar()
            .sheet(isPresented: $showAddTransaction) {
                TransactionEditor(transaction: nil)
            }
        }
    }

    private func untilDate(_ engine: FinanceEngine) -> Date {
        switch horizon {
        case .payday:
            return engine.nextPayday
        case .month:
            return Calendar.current.dateInterval(of: .month, for: .now)?.end ?? engine.nextPayday
        case .custom:
            return max(customDate, Calendar.current.date(byAdding: .day, value: 1, to: .now) ?? .now)
        }
    }

    /// Spending is counted from the start of this paycheck (or the 1st, for Month End).
    private func windowStart(_ engine: FinanceEngine) -> Date {
        if horizon == .month {
            return Calendar.current.dateInterval(of: .month, for: .now)?.start ?? engine.currentPeriod.start
        }
        return engine.currentPeriod.start
    }
}

// MARK: - Safe to Spend

struct SafeToSpendCard: View {
    var result: SafeToSpendResult
    /// Everyday spending so far in this window.
    var spent: Double
    var groups: [FinanceEngine.GroupSpend]
    @Binding var horizon: SpendHorizon
    @Binding var customDate: Date
    var onShowBreakdown: () -> Void

    private var isNegative: Bool { result.amount < 0 }
    private var left: Double { max(result.amount, 0) }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Picker("Period", selection: $horizon) {
                ForEach(SpendHorizon.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)

            HStack(alignment: .center, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Text("Safe to Spend")
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(.secondary)
                        Button(action: onShowBreakdown) {
                            Image(systemName: "info.circle")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("How Safe to Spend is calculated")
                    }
                    Text(result.amount.currencyWhole)
                        .font(.system(size: 50, weight: .bold, design: .rounded))
                        .foregroundStyle(isNegative ? AnyShapeStyle(.red) : AnyShapeStyle(.primary))
                        .contentTransition(.numericText(value: result.amount))
                        .minimumScaleFactor(0.5)
                        .lineLimit(1)
                    Text("until \(result.untilDate.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day())) · \(result.daysRemaining) \(result.daysRemaining == 1 ? "day" : "days")")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                SpendDonut(groups: groups, spent: spent, left: left)
                    .frame(width: 104, height: 104)
            }

            if horizon == .custom {
                DatePicker("Spend until", selection: $customDate, in: Date.now..., displayedComponents: .date)
                    .font(.subheadline)
            }

            SpendBar(spent: spent, left: left, overBy: isNegative ? -result.amount : 0, dailyAllowance: result.dailyAllowance, days: result.daysRemaining)
        }
        .padding(20)
        .glassEffect(.regular, in: .rect(cornerRadius: 28))
        .animation(.smooth, value: result.amount)
    }
}

/// Spent vs. left over, with the daily allowance.
struct SpendBar: View {
    @Environment(\.themeColor) private var themeColor
    var spent: Double
    var left: Double
    var overBy: Double
    var dailyAllowance: Double
    var days: Int

    private var total: Double { max(spent + left, 1) }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                if overBy > 0 {
                    Label("Over by \(overBy.currencyWhole)", systemImage: "exclamationmark.triangle.fill")
                        .font(.headline)
                        .foregroundStyle(.red)
                } else {
                    Text("\(dailyAllowance.currencyWhole)/day")
                        .font(.headline)
                    Text("for \(days) day\(days == 1 ? "" : "s")")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }

            GeometryReader { proxy in
                let spentWidth = overBy > 0 ? proxy.size.width : proxy.size.width * spent / total
                HStack(spacing: 3) {
                    if spent > 0 || overBy > 0 {
                        Capsule()
                            .fill(overBy > 0 ? AnyShapeStyle(Color.red.gradient) : AnyShapeStyle(Color.secondary.opacity(0.45)))
                            .frame(width: max(spentWidth - (left > 0 ? 3 : 0), 6))
                    }
                    if left > 0 && overBy == 0 {
                        Capsule().fill(themeColor.gradient)
                    }
                }
            }
            .frame(height: 12)
            .accessibilityHidden(true)

            HStack {
                Label("\(spent.currencyWhole) spent", systemImage: "circle.fill")
                    .labelStyle(DotLabelStyle(color: overBy > 0 ? .red : .secondary.opacity(0.6)))
                Spacer()
                Label("\(left.currencyWhole) left", systemImage: "circle.fill")
                    .labelStyle(DotLabelStyle(color: themeColor))
            }
            .font(.caption.weight(.medium))
            .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
    }
}

struct DotLabelStyle: LabelStyle {
    var color: Color
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 4) {
            configuration.icon.font(.system(size: 6)).foregroundStyle(color)
            configuration.title
        }
    }
}

/// How much of the window's money is already spent, broken down by group.
struct SpendDonut: View {
    var groups: [FinanceEngine.GroupSpend]
    var spent: Double
    var left: Double

    private struct Slice: Identifiable {
        let id: String
        var amount: Double
        var color: Color
    }

    private var slices: [Slice] {
        var result = groups.filter { $0.discretionary > 0 }.map {
            Slice(id: $0.name, amount: $0.discretionary, color: BudgyColor.named($0.colorName))
        }
        result.append(Slice(id: "Left", amount: max(left, spent + left == 0 ? 1 : 0), color: Color.secondary.opacity(0.18)))
        return result
    }

    private var percentSpent: Int {
        let total = spent + left
        return total > 0 ? Int((spent / total * 100).rounded()) : 0
    }

    var body: some View {
        ZStack {
            Chart(slices) { slice in
                SectorMark(angle: .value("Amount", slice.amount), innerRadius: .ratio(0.7), angularInset: 1.5)
                    .cornerRadius(3)
                    .foregroundStyle(slice.color)
            }
            .chartLegend(.hidden)
            VStack(spacing: 0) {
                Text("\(percentSpent)%")
                    .font(.system(.headline, design: .rounded).weight(.bold))
                Text("spent")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .accessibilityElement()
        .accessibilityLabel("\(percentSpent) percent of this period's money spent")
    }
}

struct SafeToSpendBreakdownView: View {
    @Environment(\.dismiss) private var dismiss
    var result: SafeToSpendResult

    var body: some View {
        NavigationStack {
            List {
                Section {
                    row("Checking balance", result.cash, sign: "")
                    if result.cardOwed > 0 { row("Credit card balance", -result.cardOwed, sign: "−") }
                    if result.upcomingTotal > 0 { row("Bills, subscriptions & Roth before \(result.untilDate.formatted(.dateTime.month().day()))", -result.upcomingTotal, sign: "−") }
                    if result.goalReserve > 0 { row("Goal contributions", -result.goalReserve, sign: "−") }
                    if result.expectedIncome > 0 { row("Base pay from \(result.paydaysBeforeDate) payday\(result.paydaysBeforeDate == 1 ? "" : "s")", result.expectedIncome, sign: "+") }
                } footer: {
                    Text("Card purchases count as spent the moment you swipe, so Budgy sets aside your whole card balance. Future paychecks are counted at your base amount, never overtime.")
                }

                Section {
                    HStack {
                        Text("Safe to Spend").font(.headline)
                        Spacer()
                        Text(result.amount.currency).font(.headline.monospacedDigit())
                    }
                }

                if !result.upcoming.isEmpty {
                    Section("Set aside") {
                        ForEach(result.upcoming) { charge in
                            HStack {
                                IconBadge(systemImage: charge.systemImage, color: color(for: charge.source), size: 28)
                                VStack(alignment: .leading) {
                                    Text(charge.name)
                                    Text(charge.date.formatted(.dateTime.weekday(.wide).month().day()))
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                                Text(charge.amount.currency).monospacedDigit()
                            }
                        }
                    }
                }
            }
            .navigationTitle("Breakdown")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done", systemImage: "checkmark") { dismiss() } }
            }
        }
        .presentationDetents([.medium, .large])
    }

    private func row(_ title: String, _ value: Double, sign: String) -> some View {
        HStack {
            Text(title)
            Spacer()
            Text("\(sign)\(abs(value).currency)")
                .monospacedDigit()
                .foregroundStyle(value < 0 ? .secondary : .primary)
        }
    }

    private func color(for source: UpcomingCharge.Source) -> Color {
        switch source {
        case .bill: .orange
        case .subscription: .purple
        case .payYourselfFirst: .green
        case .creditCard: .blue
        case .goal: .pink
        }
    }
}

// MARK: - Cards

private struct SampleDataBanner: View {
    @Environment(\.modelContext) private var context

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "sparkles.rectangle.stack.fill")
                .font(.title2)
                .foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 2) {
                Text("You're looking at sample data").font(.subheadline.weight(.semibold))
                Text("Connect your bank in Settings, or remove it when you're ready.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            Button("Remove") {
                withAnimation { SampleData.removeSampleData(context: context) }
                SyncService.performHousekeeping(context: context)
            }
            .buttonStyle(.glass)
            .font(.caption.weight(.semibold))
        }
        .card(padding: 14)
    }
}

struct ExtraPayCard: View {
    @Environment(\.modelContext) private var context
    var paycheck: Transaction
    var extra: Double
    var goals: [Goal]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                IconBadge(systemImage: "dollarsign.arrow.circlepath", color: .green, size: 36)
                VStack(alignment: .leading, spacing: 2) {
                    Text("+\(extra.currency) extra this paycheck")
                        .font(.headline)
                    Text("Overtime or bonus on \(paycheck.date.formatted(.dateTime.month().day())). Where should it go?")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(goals) { goal in
                        Button {
                            assign(to: goal)
                        } label: {
                            Label(goal.name, systemImage: goal.systemImage)
                        }
                        .buttonStyle(.glass)
                        .tint(BudgyColor.named(goal.colorName))
                    }
                    Button("Keep for spending", systemImage: "cart") {
                        withAnimation { paycheck.extraPayHandled = true }
                    }
                    .buttonStyle(.glass)
                }
                .font(.subheadline.weight(.medium))
            }
            .scrollClipDisabled()
        }
        .card()
    }

    private func assign(to goal: Goal) {
        withAnimation {
            goal.savedAmount += extra
            paycheck.extraPayHandled = true
        }
        try? context.save()
        SyncService.performHousekeeping(context: context)
    }
}

struct FundGoalsCard: View {
    @Environment(\.modelContext) private var context
    var goals: [Goal]
    var periodStart: Date

    private var total: Double { goals.reduce(0) { $0 + $1.contributionPerPaycheck } }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                IconBadge(systemImage: "target", color: .pink, size: 36)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Fund your goals").font(.headline)
                    Text("Move \(total.currency) to savings this paycheck")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
            ForEach(goals) { goal in
                HStack {
                    Label(goal.name, systemImage: goal.systemImage)
                        .foregroundStyle(BudgyColor.named(goal.colorName))
                    Spacer()
                    Text(goal.contributionPerPaycheck.currency).monospacedDigit()
                }
                .font(.subheadline)
            }
            Button {
                withAnimation {
                    for goal in goals {
                        goal.savedAmount += goal.contributionPerPaycheck
                        goal.lastFundedPeriodStart = periodStart
                    }
                }
                try? context.save()
                SyncService.performHousekeeping(context: context)
            } label: {
                Text("I moved it").frame(maxWidth: .infinity)
            }
            .buttonStyle(.glassProminent)
        }
        .card()
    }
}

struct RecentTransactionsCard: View {
    var transactions: [Transaction]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                SectionHeader(title: "Recent Activity")
                NavigationLink("See All") { TransactionListView() }
                    .font(.subheadline)
                    .padding(.top, 8)
            }
            VStack(spacing: 0) {
                ForEach(transactions) { transaction in
                    NavigationLink {
                        TransactionEditor(transaction: transaction)
                    } label: {
                        TransactionRow(transaction: transaction)
                    }
                    .buttonStyle(.plain)
                    .padding(.vertical, 6)
                }
            }
            .card(padding: 14)
        }
    }
}
