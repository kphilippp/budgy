import SwiftUI
import SwiftData
import Charts

struct AccountsView: View {
    @Environment(\.modelContext) private var context
    @Environment(SyncService.self) private var sync
    @State private var showAddAccount = false
    @Namespace private var zoom

    var body: some View {
        NavigationStack {
            EngineReader { engine in
                ScrollView {
                    VStack(spacing: 16) {
                        NetWorthCard(engine: engine)

                        let ordered = engine.accounts.sorted { $0.sortOrder < $1.sortOrder }
                        let creditCards = ordered.filter { $0.kind == .creditCard && !$0.isHidden }
                        if !creditCards.isEmpty {
                            // Highest utilization first: that's the card to pay down first.
                            CreditHealthCard(cards: creditCards.sorted { $0.utilization > $1.utilization }, credit: engine.credit, zoom: zoom)
                        }
                        AccountGroup(title: "Cash", accounts: ordered.filter { $0.kind == .checking || $0.kind == .savings || $0.kind == .other }, engine: engine, zoom: zoom)
                        AccountGroup(title: "Credit Cards", accounts: ordered.filter { $0.kind == .creditCard }, engine: engine, zoom: zoom)
                        AccountGroup(title: "Investments & Retirement", accounts: ordered.filter(\.kind.isInvestment), engine: engine, zoom: zoom)

                        if engine.includedAccounts.contains(where: { $0.kind == .rothIRA }) {
                            RothProgressCard(engine: engine)
                        }

                        Button {
                            showAddAccount = true
                        } label: {
                            Label("Add Account Manually", systemImage: "plus")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.glass)
                        .controlSize(.large)
                    }
                    .padding(.horizontal)
                    .padding(.bottom, 24)
                }
                .budgyCanvas()
                .refreshable { await sync.sync(context: context) }
            }
            .navigationTitle("Accounts")
            .budgyToolbar()
            .sheet(isPresented: $showAddAccount) {
                AccountEditor(account: nil)
            }
        }
    }
}

// MARK: - Credit health

private struct CreditHealthCard: View {
    var cards: [Account]
    var credit: CreditSnapshot
    var zoom: Namespace.ID

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                IconBadge(systemImage: "creditcard.fill", color: .lake, size: 40)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Credit health")
                        .font(.headline)
                    Text("Keep each card under 30%")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            if let overall = credit.overallUtilization, let band = credit.overallBand {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(alignment: .firstTextBaseline) {
                        Text("Overall utilization")
                            .font(.subheadline)
                        Spacer()
                        Text(overall, format: .percent.precision(.fractionLength(0)))
                            .font(.title3.weight(.bold).monospacedDigit())
                            .foregroundStyle(band.needsAttention ? .ochre : .moss)
                            .contentTransition(.numericText(value: overall))
                        Text(band.title)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                    }
                    Text(overallHint(band))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .accessibilityElement(children: .combine)
                Divider().overlay(Color.hairline)
            }

            if credit.lateFees12Months > 0 {
                CreditWarningRow(
                    systemImage: "exclamationmark.octagon.fill",
                    color: .clay,
                    text: "\(credit.lateFees12Months.currency) in late fees this year. A payment 30 days late hurts your score more than anything else, so turn on autopay for at least the minimum."
                )
            }
            if credit.interestPaid90Days > 0.5 {
                CreditWarningRow(
                    systemImage: "percent",
                    color: .ochre,
                    text: "\(credit.interestPaid90Days.currency) in card interest over 90 days. Pay the full statement balance by the due date to stop it."
                )
            }

            ForEach(cards) { card in
                CreditHealthRow(card: card, zoom: zoom)
                if card.id != cards.last?.id { Divider().overlay(Color.hairline) }
            }
        }
        .card()
    }

    private func overallHint(_ band: UtilizationBand) -> String {
        switch band {
        case .excellent:
            "Under 10% overall is where the best scores are. Keep paying before statements close."
        case .good:
            "Paying \(credit.paydownToTenPercent.currencyWhole) more before statements close would bring you under 10%, where the best scores are."
        default:
            "Start with the card at the highest percentage. Each card counts on its own as well as the total."
        }
    }
}

private struct CreditWarningRow: View {
    var systemImage: String
    var color: Color
    var text: String

    var body: some View {
        Label {
            Text(text).font(.caption)
        } icon: {
            Image(systemName: systemImage).foregroundStyle(color)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct CreditHealthRow: View {
    var card: Account
    var zoom: Namespace.ID

    var body: some View {
        NavigationLink {
            AccountDetailView(account: card)
                .zoomDestination("credit-\(card.id)", in: zoom)
        } label: {
            VStack(alignment: .leading, spacing: 7) {
                HStack {
                    Text(card.name).font(.subheadline.weight(.semibold))
                    Spacer()
                    if card.creditLimit > 0 {
                        Text(card.utilization, format: .percent.precision(.fractionLength(0)))
                            .font(.subheadline.weight(.bold).monospacedDigit())
                            .foregroundStyle(card.utilization < 0.30 ? .moss : .ochre)
                    } else {
                        Text("Add card limit")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.ochre)
                    }
                }

                if card.creditLimit > 0 {
                    ProgressBar(value: card.utilization, color: card.utilization < 0.30 ? .positive : .caution, height: 5)
                    if card.utilizationPaymentNeeded > 0 {
                        Text("Pay \(card.utilizationPaymentNeeded.currency) before \(statementText) to report below 30%.")
                            .font(.caption)
                            .foregroundStyle(.ochre)
                    } else {
                        Text("No early payment needed. Pay \(card.balance.currency) in full by \(dueText).")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .contentShape(.rect)
            .zoomSource("credit-\(card.id)", in: zoom, cornerRadius: Radius.field)
        }
        .buttonStyle(.plain)
    }

    private var statementText: String {
        card.nextStatementClosingDate()?.formatted(.dateTime.month(.abbreviated).day()) ?? "the statement date"
    }

    private var dueText: String {
        card.nextPaymentDueDate()?.formatted(.dateTime.month(.abbreviated).day()) ?? "the due date"
    }
}

// MARK: - Net worth

private struct NetWorthCard: View {
    @Environment(\.themeColor) private var themeColor
    var engine: FinanceEngine

    private struct Point: Identifiable {
        var id: Date { date }
        var date: Date
        var value: Double
    }

    /// Sums each account's most recent snapshot on or before each date.
    private var history: [Point] {
        let accounts = engine.accounts.filter { !$0.isHidden }
        let snapshotsByAccount = accounts.map { ($0.snapshots ?? []).sorted { $0.date < $1.date } }
        let dates = Set(snapshotsByAccount.flatMap { $0.map { Calendar.current.startOfDay(for: $0.date) } }).sorted()
        return dates.map { date in
            let total = snapshotsByAccount.reduce(0) { sum, snapshots in
                sum + (snapshots.last { $0.date <= date.addingTimeInterval(86_399) }?.balance ?? 0)
            }
            return Point(date: date, value: total)
        }
    }

    var body: some View {
        let points = history
        let change = (points.last?.value ?? 0) - (points.first?.value ?? 0)
        VStack(alignment: .leading, spacing: 8) {
            Text("Net worth")
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.secondary)
            MoneyText(engine.netWorth, size: 56)
                .foregroundStyle(engine.netWorth < 0 ? AnyShapeStyle(.negative) : AnyShapeStyle(.primary))
            if points.count > 1 {
                Tag("\(change >= 0 ? "+" : "−")\(abs(change).currencyWhole) since \(points.first?.date.formatted(.dateTime.month(.abbreviated).day()) ?? "")",
                    systemImage: change >= 0 ? "arrow.up.right" : "arrow.down.right",
                    color: change >= 0 ? .positive : .negative)

                Chart(points) { point in
                    AreaMark(x: .value("Date", point.date), y: .value("Net Worth", point.value))
                        .foregroundStyle(LinearGradient(colors: [themeColor.opacity(0.30), themeColor.opacity(0)], startPoint: .top, endPoint: .bottom))
                        .interpolationMethod(.catmullRom)
                    LineMark(x: .value("Date", point.date), y: .value("Net Worth", point.value))
                        .foregroundStyle(themeColor)
                        .interpolationMethod(.catmullRom)
                        .lineStyle(StrokeStyle(lineWidth: 2.5, lineCap: .round))
                }
                .chartYScale(domain: .automatic(includesZero: false))
                .chartXAxis(.hidden)
                .chartYAxis(.hidden)
                .frame(height: 120)
                .padding(.top, 10)
                .accessibilityHidden(true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.top, 4)
        .padding(.bottom, 6)
    }
}

// MARK: - Groups

/// Include or leave out an account, as a small eye instead of a full-width switch.
private struct IncludeToggle: View {
    var name: String
    @Binding var isIncluded: Bool

    var body: some View {
        Button {
            withAnimation(Motion.quick) { isIncluded.toggle() }
        } label: {
            Image(systemName: isIncluded ? "eye" : "eye.slash")
                .font(.subheadline.weight(.medium))
                .foregroundStyle(isIncluded ? AnyShapeStyle(.tint) : AnyShapeStyle(.tertiary))
                .contentTransition(.symbolEffect(.replace))
                .frame(width: 36, height: 36)

                .contentShape(.circle)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Include \(name)")
        .accessibilityValue(isIncluded ? "Included" : "Left out")
        .accessibilityAddTraits(.isToggle)
        .accessibilityHint("Includes this account in Budgy calculations and on Today")
        .sensoryFeedback(.selection, trigger: isIncluded)
    }
}

private struct AccountGroup: View {
    @Environment(\.modelContext) private var context
    var title: String
    var accounts: [Account]
    var engine: FinanceEngine
    var zoom: Namespace.ID

    var body: some View {
        if !accounts.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                SectionHeader(title: title, trailing: accounts.reduce(0) { $0 + $1.signedBalance }.currencyWhole)
                VStack(spacing: 0) {
                    ForEach(accounts) { account in
                        HStack(alignment: .top, spacing: 8) {
                            NavigationLink {
                                AccountDetailView(account: account)
                                    .zoomDestination(account.id, in: zoom)
                            } label: {
                                AccountRow(account: account, engine: engine)
                                    .opacity(account.isHidden ? 0.55 : 1)
                                    .zoomSource(account.id, in: zoom, cornerRadius: Radius.field)
                            }
                            .buttonStyle(.plain)

                            IncludeToggle(name: account.name, isIncluded: inclusionBinding(for: account))
                                .padding(.top, 7)
                        }
                        if account.id != accounts.last?.id { Divider().overlay(Color.hairline).padding(.leading, 52) }
                    }
                }
                .card(padding: 14)
            }
        }
    }

    private func inclusionBinding(for account: Account) -> Binding<Bool> {
        Binding(
            get: { !account.isHidden },
            set: { isIncluded in
                account.isHidden = !isIncluded
                try? context.save()
                SyncService.performHousekeeping(context: context)
            }
        )
    }
}

struct AccountRow: View {
    var account: Account
    var engine: FinanceEngine

    private var detail: String {
        var parts = [account.institution.isEmpty ? account.kind.displayName : account.institution]
        if !account.mask.isEmpty { parts.append("••\(account.mask)") }
        return parts.joined(separator: " ")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                IconBadge(systemImage: account.kind.systemImage, color: BudgyColor.forAccount(account.kind), size: 36)
                VStack(alignment: .leading, spacing: 2) {
                    Text(account.name).font(.subheadline.weight(.semibold)).lineLimit(1)
                    Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 2) {
                    Text(account.balance.currency)
                        .font(.subheadline.weight(.semibold).monospacedDigit())
                    if account.kind == .creditCard, let due = account.nextPaymentDueDate() {
                        Text("Due \(due.formatted(.dateTime.month(.abbreviated).day()))")
                            .font(.caption).foregroundStyle(.ochre)
                    } else if !account.isLinked {
                        Text("Updated \(account.lastUpdated.formatted(.relative(presentation: .named)))")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            if account.kind == .savings {
                SavingsEarmarks(account: account, goals: engine.goals.filter { !$0.isArchived })
                    .padding(.leading, 50)
            }
        }
        .padding(.vertical, 6)
        .contentShape(.rect)
    }
}

/// Shows how much of savings is earmarked for each goal.
private struct SavingsEarmarks: View {
    var account: Account
    var goals: [Goal]

    var body: some View {
        let earmarked = goals.reduce(0) { $0 + $1.savedAmount }
        let unassigned = account.balance - earmarked
        let total = max(account.balance, earmarked, 1)
        VStack(alignment: .leading, spacing: 6) {
            GeometryReader { proxy in
                HStack(spacing: 2) {
                    ForEach(goals) { goal in
                        Rectangle()
                            .fill(BudgyColor.named(goal.colorName))
                            .frame(width: max(proxy.size.width * goal.savedAmount / total - 2, 0))
                    }
                    if unassigned > 0 {
                        Rectangle().fill(.quaternary)
                    }
                }
                .clipShape(.capsule)
            }
            .frame(height: 8)
            ViewThatFits {
                HStack(spacing: 10) { labels(unassigned: unassigned) }
                VStack(alignment: .leading, spacing: 2) { labels(unassigned: unassigned) }
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private func labels(unassigned: Double) -> some View {
        ForEach(goals) { goal in
            Label(goal.savedAmount.currencyWhole, systemImage: "circle.fill")
                .labelStyle(EarmarkLabelStyle(color: BudgyColor.named(goal.colorName)))
                .accessibilityLabel("\(goal.name) \(goal.savedAmount.currencyWhole)")
        }
        Text(unassigned >= 0 ? "\(unassigned.currencyWhole) free" : "\(abs(unassigned).currencyWhole) over-earmarked")
            .foregroundStyle(unassigned >= 0 ? AnyShapeStyle(.secondary) : AnyShapeStyle(.clay))
    }
}

private struct EarmarkLabelStyle: LabelStyle {
    var color: Color
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 3) {
            configuration.icon.foregroundStyle(color).imageScale(.small)
            configuration.title
        }
    }
}

// MARK: - Roth IRA

struct RothProgressCard: View {
    @AppStorage("rothAnnualLimit") private var limit: Double = 7_500
    var engine: FinanceEngine

    var body: some View {
        let contributed = engine.rothContributionsThisYear
        let projected = engine.rothProjectedThisYear
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                IconBadge(systemImage: "leaf.fill", color: .sage, size: 40)
                Text("Roth IRA \(Calendar.current.component(.year, from: .now).formatted(.number.grouping(.never)))")
                    .font(.headline)
                Spacer()
                Text("\(contributed.currencyWhole) of \(limit.currencyWhole)")
                    .font(.subheadline.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            ProgressBar(value: limit > 0 ? contributed / limit : 0, color: .sage)
            Text(projected >= limit
                 ? "On pace to max out by Dec 31."
                 : "On pace for \(projected.currencyWhole). \(max(limit - projected, 0).currencyWhole) of room left this year.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .card()
    }
}

// MARK: - Detail

struct AccountDetailView: View {
    @Environment(\.modelContext) private var context
    @Bindable var account: Account
    @State private var showEdit = false

    private var recent: [Transaction] {
        (account.transactions ?? []).sorted { $0.date > $1.date }
    }

    var body: some View {
        List {
            Group {
                Section {
                    VStack(alignment: .leading, spacing: 10) {
                        Text(account.kind == .creditCard ? "Balance owed" : "Balance")
                            .font(.subheadline).foregroundStyle(.secondary)
                        MoneyText(account.balance, size: 44, showsCents: true)
                        let snapshots = (account.snapshots ?? []).sorted { $0.date < $1.date }
                        if snapshots.count > 1 {
                            Chart(snapshots) { snapshot in
                                LineMark(x: .value("Date", snapshot.date), y: .value("Balance", abs(snapshot.balance)))
                                    .foregroundStyle(BudgyColor.forAccount(account.kind))
                                    .interpolationMethod(.catmullRom)
                                    .lineStyle(StrokeStyle(lineWidth: 2.5, lineCap: .round))
                            }
                            .chartYScale(domain: .automatic(includesZero: false))
                            .frame(height: 140)
                        }
                        if account.kind == .creditCard && account.creditLimit > 0 {
                            BudgetBar(spent: account.balance, budget: account.creditLimit, color: .lake)
                            Text("\(Int(account.balance / account.creditLimit * 100))% of \(account.creditLimit.currencyWhole) limit used")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .padding(.vertical, 4)
                }

                if account.kind == .creditCard {
                    Section {
                        if account.creditLimit <= 0 {
                            Label("Add the credit limit to calculate utilization.", systemImage: "exclamationmark.triangle.fill")
                                .foregroundStyle(.ochre)
                        } else {
                            LabeledContent("Current utilization") {
                                Text(account.utilization, format: .percent.precision(.fractionLength(1)))
                                    .foregroundStyle(account.utilization < 0.30 ? .moss : .ochre)
                            }
                            if account.utilizationPaymentNeeded > 0 {
                                LabeledContent("Pay before statement", value: account.utilizationPaymentNeeded.currency)
                                if let statementDate = account.nextStatementClosingDate() {
                                    LabeledContent("Statement closes") {
                                        Text(statementDate.formatted(date: .abbreviated, time: .omitted))
                                    }
                                }
                            } else {
                                Label("Already below 30% — no utilization payment needed.", systemImage: "checkmark.circle.fill")
                                    .foregroundStyle(.moss)
                            }
                            LabeledContent("Pay in full", value: account.balance.currency)
                            if let dueDate = account.nextPaymentDueDate() {
                                LabeledContent("Payment due") {
                                    Text(dueDate.formatted(date: .abbreviated, time: .omitted))
                                }
                            }
                        }
                    } header: {
                        Text("Payment plan")
                    } footer: {
                        Text("Utilization is calculated separately for every card. Budgy targets 29% to leave a small margin below 30%.")
                    }
                }

                if !recent.isEmpty {
                    Section("Transactions") {
                        ForEach(recent.prefix(50)) { transaction in
                            NavigationLink {
                                TransactionEditor(transaction: transaction)
                            } label: {
                                TransactionRow(transaction: transaction)
                            }
                        }
                    }
                }
            }
            .budgyRows()
        }
        .budgyList()
        .navigationTitle(account.name)
        .toolbar {
            Button("Edit") { showEdit = true }
        }
        .sheet(isPresented: $showEdit) {
            AccountEditor(account: account)
        }
    }
}

struct AccountEditor: View {
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @Query private var accounts: [Account]

    let account: Account?

    @State private var name: String
    @State private var institution: String
    @State private var kind: AccountKind
    @State private var balance: Double
    @State private var dueDay: Int
    @State private var statementDay: Int
    @State private var creditLimit: Double
    @State private var isHidden: Bool

    init(account: Account?) {
        self.account = account
        self.name = account?.name ?? ""
        self.institution = account?.institution ?? ""
        self.kind = account?.kind ?? .checking
        self.balance = account?.balance ?? 0
        self.dueDay = account?.paymentDueDay ?? 0
        self.statementDay = account?.statementClosingDay ?? 0
        self.creditLimit = account?.creditLimit ?? 0
        self.isHidden = account?.isHidden ?? false
    }

    var body: some View {
        NavigationStack {
            Form {
                Group {
                    Section {
                        TextField("Account name", text: $name)
                        TextField("Institution (e.g. Charles Schwab)", text: $institution)
                        Picker("Type", selection: $kind) {
                            ForEach(AccountKind.allCases) { Label($0.displayName, systemImage: $0.systemImage).tag($0) }
                        }
                    }
                    Section {
                        LabeledContent(kind == .creditCard ? "Amount owed" : "Balance") {
                            TextField("Balance", value: $balance, format: .currency(code: "USD"))
                                .keyboardType(.decimalPad)
                                .multilineTextAlignment(.trailing)
                        }
                    } footer: {
                        if account?.isLinked == true {
                            Text("This balance updates automatically from your bank.")
                        } else if kind.isInvestment {
                            Text("Update this every few weeks. Budgy keeps the history for your net worth chart.")
                        }
                    }
                    if kind == .creditCard {
                        Section {
                            Picker("Statement closing day", selection: $statementDay) {
                                Text("Not set").tag(0)
                                ForEach(1...31, id: \.self) { Text("\($0)").tag($0) }
                            }
                            Picker("Payment due day", selection: $dueDay) {
                                Text("Not set").tag(0)
                                ForEach(1...31, id: \.self) { Text("\($0)").tag($0) }
                            }
                            LabeledContent("Credit limit") {
                                TextField("Limit", value: $creditLimit, format: .currency(code: "USD"))
                                    .keyboardType(.decimalPad)
                                    .multilineTextAlignment(.trailing)
                            }
                        } header: {
                            Text("Card details")
                        } footer: {
                            Text("The statement closing date is when the balance is typically reported. The payment due date is when the statement balance must be paid to avoid interest.")
                        }
                    }
                    if let account {
                        Section {
                            Toggle("Include in Budgy", isOn: Binding(
                                get: { !isHidden },
                                set: { isHidden = !$0 }
                            ))
                            if !account.isLinked {
                                Button("Delete Account", role: .destructive) {
                                    context.delete(account)
                                    try? context.save()
                                    dismiss()
                                }
                            }
                        }
                    }
                }
                .budgyRows()
            }
            .budgyList()
            .navigationTitle(account == nil ? "New Account" : "Edit Account")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel", systemImage: "xmark") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save", systemImage: "checkmark", action: save).disabled(name.isEmpty)
                }
            }
        }
    }

    private func save() {
        let target = account ?? {
            let new = Account(name: name, institution: institution, kind: kind, balance: balance)
            new.sortOrder = accounts.count
            context.insert(new)
            return new
        }()
        target.name = name
        target.institution = institution
        target.kind = kind
        if target.balance != balance || account == nil {
            target.balance = balance
            target.lastUpdated = .now
        }
        target.paymentDueDay = dueDay
        target.statementClosingDay = statementDay
        target.creditLimit = creditLimit
        target.isHidden = isHidden
        target.recordSnapshot(in: context)
        try? context.save()
        SyncService.performHousekeeping(context: context)
        dismiss()
    }
}
