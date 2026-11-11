import SwiftUI
import SwiftData
import Charts

struct HomeView: View {
    @Environment(\.modelContext) private var context
    @Environment(SyncService.self) private var sync
    @Query(filter: #Predicate<Account> { $0.isSample }) private var sampleAccounts: [Account]

    @State private var showBreakdown = false
    @State private var showAddTransaction = false
    @State private var showSubscriptions = false

    var body: some View {
        NavigationStack {
            EngineReader { engine in
                let monthly = engine.monthlySpend()
                let groups = engine.groupSpending(since: monthly.period.start, until: monthly.period.end)
                ScrollView {
                    VStack(spacing: 16) {
                        if !sampleAccounts.isEmpty {
                            SampleDataBanner()
                        }

                        SyncStatusBanner()

                        SafeToSpendCard(monthly: monthly, groups: groups) {
                            showBreakdown = true
                        }
                        .sheet(isPresented: $showBreakdown) {
                            SafeToSpendBreakdownView(monthly: monthly)
                        }

                        ForEach(engine.unassignedExtraPay, id: \.transaction.id) { item in
                            ExtraPayCard(paycheck: item.transaction, extra: item.extra, goals: engine.goals.filter { !$0.isArchived && !$0.isComplete })
                        }

                        if !engine.unfundedGoalsThisPeriod.isEmpty {
                            FundGoalsCard(goals: engine.unfundedGoalsThisPeriod, periodStart: engine.currentPeriod.start)
                        }

                        SpendingGroupsSection(groups: groups, windowStart: monthly.period.start, unsortedCount: engine.unsortedTransactions.count)

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
}

// MARK: - Safe to Spend

/// This budget month's Safe to Spend: monthly income minus fixed costs and what you've spent so far.
struct SafeToSpendCard: View {
    var monthly: MonthlySpendResult
    var groups: [FinanceEngine.GroupSpend]
    var onShowBreakdown: () -> Void

    private var isNegative: Bool { monthly.left < 0 }
    private var left: Double { max(monthly.left, 0) }

    private var periodText: String {
        let end = Calendar.current.date(byAdding: .day, value: -1, to: monthly.period.end) ?? monthly.period.end
        return "\(monthly.period.start.formatted(.dateTime.month(.abbreviated).day())) – \(end.formatted(.dateTime.month(.abbreviated).day())) · \(monthly.daysRemaining) \(monthly.daysRemaining == 1 ? "day" : "days") left"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
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
                    Text(monthly.left.currencyWhole)
                        .font(.system(size: 50, weight: .bold, design: .rounded))
                        .foregroundStyle(isNegative ? AnyShapeStyle(.red) : AnyShapeStyle(.primary))
                        .contentTransition(.numericText(value: monthly.left))
                        .minimumScaleFactor(0.5)
                        .lineLimit(1)
                    Text(periodText)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                SpendDonut(groups: groups, spent: monthly.spent, left: left)
                    .frame(width: 104, height: 104)
            }

            SpendBar(spent: monthly.spent, left: left, overBy: isNegative ? -monthly.left : 0, dailyAllowance: monthly.perDay, days: monthly.daysRemaining)
        }
        .padding(20)
        .glassEffect(.regular, in: .rect(cornerRadius: 28))
        .animation(.smooth, value: monthly.left)
    }
}

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
    var monthly: MonthlySpendResult

    var body: some View {
        NavigationStack {
            List {
                Section {
                    row(monthly.incomeIsEstimated ? "Monthly income (estimated)" : "Monthly income", monthly.income, sign: "")
                    if monthly.bills > 0 { row("Bills", -monthly.bills, sign: "−") }
                    if monthly.subscriptions > 0 { row("Subscriptions", -monthly.subscriptions, sign: "−") }
                    if monthly.payYourselfFirst > 0 { row("Pay Yourself First (Roth)", -monthly.payYourselfFirst, sign: "−") }
                    if monthly.goals > 0 { row("Goal contributions", -monthly.goals, sign: "−") }
                    row("Spent so far", -monthly.spent, sign: "−")
                } header: {
                    Text(periodTitle)
                } footer: {
                    Text("Your budget month starts the day you pay your credit card off. Budgy counts on your usual paychecks; an extra paycheck in a month is treated as bonus money. Change the start day or your monthly income in Settings → Paycheck.")
                }

                Section {
                    HStack {
                        Text("Safe to Spend").font(.headline)
                        Spacer()
                        Text(monthly.left.currency).font(.headline.monospacedDigit())
                    }
                    HStack {
                        Text("Per day for \(monthly.daysRemaining) days")
                        Spacer()
                        Text(monthly.perDay.currency).monospacedDigit()
                    }
                }

                if !monthly.scheduled.isEmpty {
                    Section("Scheduled this month") {
                        ForEach(monthly.scheduled) { charge in
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

    private var periodTitle: String {
        let end = Calendar.current.date(byAdding: .day, value: -1, to: monthly.period.end) ?? monthly.period.end
        return "\(monthly.period.start.formatted(.dateTime.month(.abbreviated).day())) – \(end.formatted(.dateTime.month(.abbreviated).day()))"
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

/// Shows why a refresh failed instead of failing silently.
private struct SyncStatusBanner: View {
    @Environment(SyncService.self) private var sync
    @Query private var items: [PlaidItem]
    @State private var showConnections = false

    private var message: String? {
        if let error = sync.lastError { return error }
        let failing = items.filter { !$0.lastError.isEmpty }
        guard let first = failing.first else { return nil }
        return "\(first.institutionName): \(first.lastError)" + (failing.count > 1 ? " (+\(failing.count - 1) more)" : "")
    }

    var body: some View {
        if sync.isSyncing {
            HStack(spacing: 10) {
                ProgressView()
                Text("Refreshing your accounts…").font(.subheadline)
                Spacer()
            }
            .card(padding: 12)
        } else if let message {
            Button { showConnections = true } label: {
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Couldn't refresh").font(.subheadline.weight(.semibold))
                        Text(message).font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.leading)
                    }
                    Spacer()
                    Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
                }
                .card(padding: 12)
            }
            .buttonStyle(.plain)
            .sheet(isPresented: $showConnections) {
                NavigationStack {
                    BankConnectionsView()
                        .toolbar {
                            ToolbarItem(placement: .confirmationAction) {
                                Button("Done", systemImage: "checkmark") { showConnections = false }
                            }
                        }
                }
            }
        }
    }
}

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
