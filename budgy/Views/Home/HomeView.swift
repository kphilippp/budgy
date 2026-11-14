import SwiftUI
import SwiftData
import Charts

/// Today: what you can spend, how this month is flowing, and anything that needs a decision.
struct HomeView: View {
    @Environment(\.modelContext) private var context
    @Environment(SyncService.self) private var sync
    @Query(filter: #Predicate<Account> { $0.isSample }) private var sampleAccounts: [Account]

    @State private var showBreakdown = false
    @State private var showAddTransaction = false
    @State private var showSubscriptions = false
    @State private var paydayPaycheck: Transaction?
    @AppStorage("rothAnnualLimit") private var rothLimit: Double = 7_500

    var body: some View {
        NavigationStack {
            EngineReader { engine in
                let monthly = engine.monthlySpend()
                let groups = engine.groupSpending(since: monthly.period.start, until: monthly.period.end)
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        SafeToSpendHero(monthly: monthly, flow: SpendingFlow(engine: engine, monthly: monthly)) {
                            showBreakdown = true
                        }
                        .sheet(isPresented: $showBreakdown) {
                            SafeToSpendBreakdownView(monthly: monthly, schedule: engine.schedule)
                        }
                        .padding(.bottom, 10)

                        // Anything that wants a decision sits right under the number it affects.
                        if !sampleAccounts.isEmpty {
                            SampleDataBanner()
                        }

                        SyncStatusBanner()

                        if let transfer = engine.savingsTransferDue, let schedule = engine.schedule {
                            SavingsTransferReminderCard(
                                schedule: schedule,
                                paycheck: transfer.paycheck,
                                amount: transfer.amount
                            )
                        }

                        ForEach(engine.unassignedExtraPay, id: \.transaction.id) { item in
                            ExtraPayCard(paycheck: item.transaction, extra: item.extra, goals: engine.goals.filter { !$0.isArchived && !$0.isComplete })
                        }

                        if !engine.unfundedGoalsThisPeriod.isEmpty {
                            FundGoalsCard(goals: engine.unfundedGoalsThisPeriod, periodStart: engine.currentPeriod.start)
                        }

                        NextMoneyStepCard(step: engine.nextMoneyStep(rothLimit: rothLimit))

                        SpendingGroupsSection(groups: groups, windowStart: monthly.period.start, unsortedCount: engine.unsortedTransactions.count)

                        HomeAccountSections(engine: engine)

                        InvestmentGroupsSection(engine: engine)

                        RecentTransactionsCard(transactions: Array(engine.includedTransactions.sorted { $0.date > $1.date }.prefix(6)))
                    }
                    .padding(.horizontal)
                    .padding(.bottom, 32)
                }
                .budgyCanvas()
                .refreshable { await sync.sync(context: context) }
                .onChange(of: engine.savingsTransferDue?.paycheck.id, initial: true) { _, paycheckID in
                    #if DEBUG
                    // `-BudgyNoPayday YES` keeps the payday flow closed for screenshots and design review.
                    if UserDefaults.standard.bool(forKey: "BudgyNoPayday") { return }
                    #endif
                    guard let paycheckID,
                          paydayPaycheck == nil,
                          let paycheck = engine.paychecks.first(where: { $0.id == paycheckID }) else { return }
                    paydayPaycheck = paycheck
                }
                .fullScreenCover(item: $paydayPaycheck) { paycheck in
                    if let schedule = engine.schedule {
                        let safe = engine.safeToSpend()
                        PaydayFlowView(
                            schedule: schedule,
                            paycheck: paycheck,
                            savingsAmount: engine.basePaycheck * schedule.savingsRate,
                            reservedCharges: safe.upcoming.filter { $0.source == .bill || $0.source == .subscription },
                            safeToSpend: safe.amount,
                            nextPayday: engine.nextPayday
                        )
                    }
                }
            }
            .navigationTitle("Today")
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

// MARK: - Safe to spend

/// The number Budgy exists for, set large on the canvas, with this month's spending flow beneath it.
private struct SafeToSpendHero: View {
    var monthly: MonthlySpendResult
    var flow: SpendingFlow
    var onShowBreakdown: () -> Void

    private var isNegative: Bool { monthly.left < 0 }

    private var periodText: String {
        let payday = monthly.safeUntilDate.formatted(.dateTime.month(.abbreviated).day())
        let days = "\(monthly.daysRemaining) \(monthly.daysRemaining == 1 ? "day" : "days")"
        return isNegative
            ? "Over by \(abs(monthly.left).currencyWhole) with \(days) until payday, \(payday)"
            : "\(monthly.perDay.currencyWhole) a day for \(days) · payday \(payday)"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button(action: onShowBreakdown) {
                HStack(spacing: 5) {
                    Text("Safe to spend")
                    Image(systemName: "info.circle").imageScale(.small)
                }
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .accessibilityHint("Shows how Safe to Spend is calculated")

            MoneyText(monthly.left, size: 64)
                .foregroundStyle(isNegative ? AnyShapeStyle(.negative) : AnyShapeStyle(.primary))

            Text(periodText)
                .font(.subheadline)
                .foregroundStyle(.secondary)

            if flow.isMeaningful {
                SpendingFlowView(flow: flow)
                    .padding(.top, 18)
            }
        }
        .padding(.top, 4)
        .animation(Motion.gentle, value: monthly.left)
    }
}

/// Cumulative everyday spending across the budget month, against an even pace.
struct SpendingFlow {
    struct Point: Identifiable {
        var date: Date
        var amount: Double
        var id: Date { date }
    }

    var start: Date
    var end: Date
    /// Running total of everyday spending, from 0 at the start of the month up to now.
    var points: [Point]
    /// Everything this month can hold: spent so far plus what's still safe to spend.
    var allowance: Double
    var spent: Double
    /// Where an even pace would put spending right now.
    var expectedNow: Double

    var isMeaningful: Bool { allowance > 0 || spent > 0 }
    /// Positive when spending is under an even pace.
    var difference: Double { expectedNow - spent }

    var pace: [Point] { [Point(date: start, amount: 0), Point(date: end, amount: allowance)] }

    init(engine: FinanceEngine, monthly: MonthlySpendResult, now: Date = .now) {
        let calendar = Calendar.current
        start = monthly.period.start
        // Safe to Spend runs to payday, so the pace does too (the budget month can end earlier).
        end = max(monthly.safeUntilDate, now.addingTimeInterval(3_600))
        spent = monthly.spent
        allowance = max(monthly.spent + monthly.left, monthly.spent)

        let total = end.timeIntervalSince(start)
        let elapsed = min(max(now.timeIntervalSince(start), 0), total)
        expectedNow = total > 0 ? allowance * elapsed / total : 0

        // Same transactions as `monthly.spent`: everyday spending, not bills or subscriptions.
        let today = calendar.startOfDay(for: now)
        let tomorrow = calendar.date(byAdding: .day, value: 1, to: today) ?? now
        var byDay: [Date: Double] = [:]
        for transaction in engine.includedTransactions
        where transaction.date >= start && transaction.date < tomorrow && transaction.recurringItem == nil {
            byDay[calendar.startOfDay(for: transaction.date), default: 0] += transaction.spendingAmount
        }

        var running = 0.0
        var result = [Point(date: start, amount: 0)]
        var day = calendar.startOfDay(for: start)
        while day < today, let next = calendar.date(byAdding: .day, value: 1, to: day) {
            running += byDay[day] ?? 0
            result.append(Point(date: next, amount: running))
            day = next
        }
        running += byDay[today] ?? 0
        result.append(Point(date: min(max(now, start), end), amount: running))
        points = result
    }
}

private struct SpendingFlowView: View {
    @Environment(\.themeColor) private var themeColor
    var flow: SpendingFlow

    private var paceTag: Tag {
        let margin = max(flow.allowance * 0.02, 1)
        if flow.difference > margin {
            return Tag("\(flow.difference.currencyWhole) under pace", systemImage: "arrow.down.right", color: .positive)
        }
        if flow.difference < -margin {
            return Tag("\(abs(flow.difference).currencyWhole) over pace", systemImage: "arrow.up.right", color: .caution)
        }
        return Tag("On pace", systemImage: "equal", color: .positive)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                paceTag
                Spacer()
                Text("\(flow.spent.currencyWhole) spent so far")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }

            Chart {
                ForEach(flow.pace) { point in
                    LineMark(x: .value("Date", point.date), y: .value("Amount", point.amount), series: .value("Line", "Even pace"))
                        .foregroundStyle(Color.inkTertiary)
                        .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 4]))
                }
                ForEach(flow.points) { point in
                    AreaMark(x: .value("Date", point.date), y: .value("Amount", point.amount))
                        .foregroundStyle(LinearGradient(colors: [themeColor.opacity(0.30), themeColor.opacity(0)], startPoint: .top, endPoint: .bottom))
                        .interpolationMethod(.monotone)
                    LineMark(x: .value("Date", point.date), y: .value("Amount", point.amount), series: .value("Line", "Spent"))
                        .foregroundStyle(themeColor)
                        .lineStyle(StrokeStyle(lineWidth: 2.5, lineCap: .round, lineJoin: .round))
                        .interpolationMethod(.monotone)
                }
                if let now = flow.points.last {
                    PointMark(x: .value("Date", now.date), y: .value("Amount", now.amount))
                        .symbolSize(140)
                        .foregroundStyle(themeColor.opacity(0.25))
                    PointMark(x: .value("Date", now.date), y: .value("Amount", now.amount))
                        .symbolSize(44)
                        .foregroundStyle(themeColor)
                }
            }
            .chartXScale(domain: flow.start...flow.end)
            .chartYScale(domain: 0...max(flow.allowance, flow.spent, 1) * 1.08)
            .chartXAxis(.hidden)
            .chartYAxis(.hidden)
            .chartLegend(.hidden)
            .frame(height: 112)

            HStack {
                Text(flow.start.formatted(.dateTime.month(.abbreviated).day()))
                Spacer()
                Text("Payday \(flow.end.formatted(.dateTime.month(.abbreviated).day()))")
            }
            .font(.caption2)
            .foregroundStyle(.tertiary)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Spending this budget month")
        .accessibilityValue("\(flow.spent.currencyWhole) spent of \(flow.allowance.currencyWhole). \(paceTag.text).")
    }
}

/// How Safe to Spend is built, plus the protected buffer that feeds it.
struct SafeToSpendBreakdownView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var context
    var monthly: MonthlySpendResult
    var schedule: PaySchedule?

    var body: some View {
        NavigationStack {
            List {
                Group {
                    Section {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Safe to spend")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                            MoneyText(monthly.left, size: 40, showsCents: true)
                            Text("\(monthly.perDay.currency) a day for \(monthly.daysRemaining) \(monthly.daysRemaining == 1 ? "day" : "days")")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                        .padding(.vertical, 6)
                    }

                    Section {
                        SavingsCalculationTable(
                            formula: SavingsFormula(
                                checkingCash: monthly.cash,
                                creditCards: monthly.cardOwed,
                                upcomingBills: monthly.billReserve,
                                plannedSavings: monthly.plannedSavings,
                                checkingBuffer: monthly.checkingBuffer,
                                expectedBasePay: monthly.expectedIncome
                            )
                        )
                        .padding(.vertical, 4)
                    } header: {
                        Text(periodTitle)
                    } footer: {
                        Text("Safe to Spend starts with included checking cash, protects savings, pays off included credit cards, reserves commitments, goals, and your checking buffer, then adds only base pay expected before this budget month ends.")
                    }

                    if let schedule {
                        BufferSection(schedule: schedule)
                    }

                    if !monthly.scheduled.isEmpty {
                        Section("Scheduled this month") {
                            ForEach(monthly.scheduled) { charge in
                                HStack(spacing: 12) {
                                    IconBadge(systemImage: charge.systemImage, color: color(for: charge.source), size: 30)
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
                .budgyRows()
            }
            .budgyList()
            .navigationTitle("Breakdown")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done", systemImage: "checkmark") { dismiss() } }
            }
        }
        .presentationDetents([.medium, .large])
        .onDisappear {
            try? context.save()
            SyncService.performHousekeeping(context: context)
        }
    }

    private var periodTitle: String {
        "Through payday on \(monthly.safeUntilDate.formatted(.dateTime.month(.abbreviated).day()))"
    }

    private func color(for source: UpcomingCharge.Source) -> Color {
        switch source {
        case .bill: .ochre
        case .subscription: .heather
        case .payYourselfFirst: .moss
        case .creditCard: .lake
        case .goal: .rosehip
        }
    }
}

/// Cash kept in checking that Safe to Spend never counts. Lives next to the math it changes.
private struct BufferSection: View {
    @Bindable var schedule: PaySchedule

    var body: some View {
        Section {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Label("Protected buffer", systemImage: "shield.lefthalf.filled")
                        .font(.subheadline.weight(.semibold))
                    Spacer()
                    Text(schedule.checkingBuffer.currencyWhole)
                        .font(.headline.monospacedDigit())
                        .contentTransition(.numericText(value: schedule.checkingBuffer))
                }
                Slider(value: $schedule.checkingBuffer, in: 0...2_000, step: 50)
                    .accessibilityLabel("Protected checking buffer")
                    .accessibilityValue(schedule.checkingBuffer.currencyWhole)
            }
            .padding(.vertical, 4)
        } footer: {
            Text("Kept in checking and never included in Safe to Spend.")
        }
    }
}

// MARK: - Needs a decision

private struct SavingsTransferReminderCard: View {
    @Environment(\.modelContext) private var context
    @Bindable var schedule: PaySchedule
    var paycheck: Transaction
    var amount: Double

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 12) {
                IconBadge(systemImage: "arrow.down.heart.fill", color: .positive, size: 40)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Pay yourself first")
                        .font(.headline)
                    Text("Move \(amount.currency) to savings or investments before spending this paycheck.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }

            HStack {
                Tag("\(schedule.savingsRate.formatted(.percent.precision(.fractionLength(0)))) of base pay", systemImage: "chart.pie.fill", color: .positive)
                Spacer()
                Text("Paid \(paycheck.date.formatted(.dateTime.month(.abbreviated).day()))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Button {
                // This card disappears in the same update, so the haptic is fired directly.
                Haptics.success()
                withAnimation(Motion.standard) {
                    schedule.lastSavingsTransferPaycheckID = paycheck.id
                }
                try? context.save()
                SyncService.performHousekeeping(context: context)
            } label: {
                Text("I moved the money")
                    .frame(maxWidth: .infinity)
            }
            // Prominent buttons always use the accent: it's tuned so white labels stay legible.
            .buttonStyle(.glassProminent)
            .foregroundStyle(.white)
        }
        .card()
        .accessibilityElement(children: .contain)
    }
}

/// The one thing to do with spare money right now, from the save → debt → invest ladder.
private struct NextMoneyStepCard: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.themeColor) private var themeColor
    var step: MoneyStep

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                IconBadge(systemImage: step.systemImage, color: themeColor, size: 40)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Next money step · \(step.number) of \(MoneyStep.stepCount)")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)
                    Text(step.title)
                        .font(.headline)
                }
            }
            Text(step.detail)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if let progress = step.progress {
                ProgressBar(value: progress, color: themeColor)
                    .accessibilityLabel("Progress")
            }
            StepDots(current: step.number, total: MoneyStep.stepCount, color: themeColor)
        }
        .card()
        .accessibilityElement(children: .combine)
        .animation(Motion.animation(Motion.gentle, reduceMotion: reduceMotion), value: step.id)
    }
}

/// Where you are on the money ladder: done steps filled, the current one longer.
private struct StepDots: View {
    var current: Int
    var total: Int
    var color: Color

    var body: some View {
        HStack(spacing: 5) {
            ForEach(1...total, id: \.self) { index in
                Capsule()
                    .fill(index <= current ? color : Color.ink.opacity(0.1))
                    .frame(width: index == current ? 18 : 6, height: 6)
            }
        }
        .accessibilityHidden(true)
    }
}

struct ExtraPayCard: View {
    @Environment(\.modelContext) private var context
    var paycheck: Transaction
    var extra: Double
    var goals: [Goal]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                IconBadge(systemImage: "dollarsign.arrow.circlepath", color: .positive, size: 40)
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
                        withAnimation(Motion.standard) { paycheck.extraPayHandled = true }
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
        Haptics.success()
        withAnimation(Motion.standard) {
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
            HStack(alignment: .top, spacing: 12) {
                IconBadge(systemImage: "mountain.2.fill", color: .rosehip, size: 40)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Fund your goals").font(.headline)
                    Text("Move \(total.currency) to savings this paycheck")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
            VStack(spacing: 8) {
                ForEach(goals) { goal in
                    HStack(spacing: 10) {
                        IconBadge(systemImage: goal.systemImage, color: BudgyColor.named(goal.colorName), size: 26)
                        Text(goal.name)
                        Spacer()
                        Text(goal.contributionPerPaycheck.currency).monospacedDigit()
                    }
                    .font(.subheadline)
                }
            }
            Button {
                Haptics.success()
                withAnimation(Motion.standard) {
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
            .foregroundStyle(.white)
        }
        .card()
    }
}

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
                HStack(alignment: .top, spacing: 12) {
                    IconBadge(systemImage: "exclamationmark.triangle.fill", color: .caution, size: 32)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Couldn't refresh").font(.subheadline.weight(.semibold))
                        Text(message).font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.leading)
                    }
                    Spacer()
                    Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
                }
                .card(padding: 12)
            }
            .buttonStyle(.pressable)
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
    @Environment(\.themeColor) private var themeColor

    var body: some View {
        HStack(spacing: 12) {
            IconBadge(systemImage: "sparkles", color: themeColor, size: 36)
            VStack(alignment: .leading, spacing: 2) {
                Text("You're looking at sample data").font(.subheadline.weight(.semibold))
                Text("Connect your bank in Settings, or remove it when you're ready.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            Button("Remove") {
                withAnimation(Motion.standard) { SampleData.removeSampleData(context: context) }
                SyncService.performHousekeeping(context: context)
            }
            .buttonStyle(.glass)
            .font(.caption.weight(.semibold))
        }
        .card(padding: 14)
    }
}

// MARK: - Accounts

private struct HomeAccountSections: View {
    var engine: FinanceEngine

    private var accounts: [Account] {
        let included = engine.includedAccounts.filter {
            $0.kind == .checking || $0.kind == .savings || $0.kind == .creditCard
        }
        return included.sorted {
            let firstIsCard = $0.kind == .creditCard
            let secondIsCard = $1.kind == .creditCard
            return firstIsCard == secondIsCard ? $0.sortOrder < $1.sortOrder : !firstIsCard
        }
    }

    var body: some View {
        HomeAccountsCard(accounts: accounts)
    }
}

private struct HomeAccountsCard: View {
    var accounts: [Account]

    private var net: Double {
        accounts.reduce(0) { $0 + $1.signedBalance }
    }

    var body: some View {
        if !accounts.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                SectionHeader(title: "Cash & cards")
                VStack(spacing: 0) {
                    ForEach(accounts) { account in
                        NavigationLink {
                            AccountDetailView(account: account)
                        } label: {
                            HomeAccountBalanceRow(account: account)
                        }
                        .buttonStyle(.plain)
                        Divider().overlay(Color.hairline).padding(.leading, 50)
                    }

                    HStack(alignment: .firstTextBaseline) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Net cash after cards")
                                .font(.subheadline.weight(.semibold))
                            Text("Includes savings. Safe to Spend uses checking only.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Text(net.currency)
                            .font(.display(.headline, weight: .semibold).monospacedDigit())
                            .foregroundStyle(net < 0 ? .negative : .positive)
                    }
                    .padding(.top, 12)
                    .accessibilityElement(children: .combine)
                }
                .card(padding: 14)
            }
        }
    }
}

private struct HomeAccountBalanceRow: View {
    var account: Account

    private var detail: String {
        var parts = [account.institution.isEmpty ? account.kind.displayName : account.institution]
        if !account.mask.isEmpty { parts.append("••\(account.mask)") }
        return parts.joined(separator: " ")
    }

    private var displayedBalance: String {
        account.kind == .creditCard ? "−\(account.balance.currency)" : account.balance.currency
    }

    var body: some View {
        HStack(spacing: 12) {
            IconBadge(systemImage: account.kind.systemImage, color: BudgyColor.forAccount(account.kind), size: 38)
            VStack(alignment: .leading, spacing: 2) {
                Text(account.name).font(.subheadline.weight(.semibold))
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Text(displayedBalance)
                .font(.subheadline.weight(.semibold).monospacedDigit())
                .foregroundStyle(account.kind == .creditCard ? .negative : .primary)
            Image(systemName: "chevron.right")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .padding(.vertical, 8)
        .contentShape(.rect)
    }
}

// MARK: - Recent

struct RecentTransactionsCard: View {
    var transactions: [Transaction]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                SectionHeader(title: "Recent")
                NavigationLink("See all") { TransactionListView() }
                    .font(.subheadline.weight(.medium))
            }
            VStack(spacing: 0) {
                if transactions.isEmpty {
                    Text("Transactions appear here as your bank sends them.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .padding(.vertical, 8)
                }
                ForEach(transactions) { transaction in
                    NavigationLink {
                        TransactionEditor(transaction: transaction)
                    } label: {
                        TransactionRow(transaction: transaction)
                    }
                    .buttonStyle(.plain)
                    .padding(.vertical, 8)
                    if transaction.id != transactions.last?.id {
                        Divider().overlay(Color.hairline).padding(.leading, 48)
                    }
                }
            }
            .card(padding: 14)
        }
    }
}
