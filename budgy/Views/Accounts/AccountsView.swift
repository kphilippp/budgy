import SwiftUI
import SwiftData
import Charts

struct AccountsView: View {
    @Environment(\.modelContext) private var context
    @Environment(SyncService.self) private var sync
    @State private var showAddAccount = false

    var body: some View {
        NavigationStack {
            EngineReader { engine in
                ScrollView {
                    VStack(spacing: 16) {
                        NetWorthCard(engine: engine)

                        let visible = engine.accounts.filter { !$0.isHidden }.sorted { $0.sortOrder < $1.sortOrder }
                        AccountGroup(title: "Cash", accounts: visible.filter { $0.kind == .checking || $0.kind == .savings || $0.kind == .other }, engine: engine)
                        AccountGroup(title: "Credit Cards", accounts: visible.filter { $0.kind == .creditCard }, engine: engine)
                        AccountGroup(title: "Investments & Retirement", accounts: visible.filter(\.kind.isInvestment), engine: engine)

                        if engine.accounts.contains(where: { $0.kind == .rothIRA }) {
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
                .background(Color(.systemGroupedBackground))
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
        VStack(alignment: .leading, spacing: 12) {
            Text("Net Worth")
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.secondary)
            Text(engine.netWorth.currencyWhole)
                .font(.system(size: 44, weight: .bold, design: .rounded))
                .contentTransition(.numericText(value: engine.netWorth))
            if points.count > 1 {
                Label("\(change >= 0 ? "+" : "−")\(abs(change).currencyWhole) since \(points.first?.date.formatted(.dateTime.month(.abbreviated).day()) ?? "")",
                      systemImage: change >= 0 ? "arrow.up.right" : "arrow.down.right")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(change >= 0 ? .green : .red)

                Chart(points) { point in
                    AreaMark(x: .value("Date", point.date), y: .value("Net Worth", point.value))
                        .foregroundStyle(LinearGradient(colors: [themeColor.opacity(0.35), themeColor.opacity(0.02)], startPoint: .top, endPoint: .bottom))
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
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(20)
        .glassEffect(.regular.tint(themeColor.opacity(0.1)), in: .rect(cornerRadius: 28))
    }
}

// MARK: - Groups

private struct AccountGroup: View {
    var title: String
    var accounts: [Account]
    var engine: FinanceEngine

    var body: some View {
        if !accounts.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                SectionHeader(title: title, trailing: accounts.reduce(0) { $0 + $1.signedBalance }.currencyWhole)
                VStack(spacing: 0) {
                    ForEach(accounts) { account in
                        NavigationLink {
                            AccountDetailView(account: account)
                        } label: {
                            AccountRow(account: account, engine: engine)
                        }
                        .buttonStyle(.plain)
                        if account.id != accounts.last?.id { Divider().padding(.leading, 52) }
                    }
                }
                .card(padding: 14)
            }
        }
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
                IconBadge(systemImage: account.kind.systemImage, color: BudgyColor.forAccount(account.kind), size: 38)
                VStack(alignment: .leading, spacing: 2) {
                    Text(account.name).font(.subheadline.weight(.semibold))
                    Text(detail).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 2) {
                    Text(account.balance.currency)
                        .font(.subheadline.weight(.semibold).monospacedDigit())
                    if account.kind == .creditCard, let due = account.nextPaymentDueDate() {
                        Text("Due \(due.formatted(.dateTime.month(.abbreviated).day()))")
                            .font(.caption).foregroundStyle(.orange)
                    } else if !account.isLinked {
                        Text("Updated \(account.lastUpdated.formatted(.relative(presentation: .named)))")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
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
                            .fill(BudgyColor.named(goal.colorName).gradient)
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
            .foregroundStyle(unassigned >= 0 ? AnyShapeStyle(.secondary) : AnyShapeStyle(.red))
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
                IconBadge(systemImage: "leaf.fill", color: .mint, size: 32)
                Text("Roth IRA \(Calendar.current.component(.year, from: .now).formatted(.number.grouping(.never)))")
                    .font(.headline)
                Spacer()
                Text("\(contributed.currencyWhole) of \(limit.currencyWhole)")
                    .font(.subheadline.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            BudgetBar(spent: contributed, budget: limit, color: .mint)
            Text(projected >= limit
                 ? "On pace to max out by Dec 31 🎯"
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
            Section {
                VStack(alignment: .leading, spacing: 10) {
                    Text(account.kind == .creditCard ? "Balance owed" : "Balance")
                        .font(.subheadline).foregroundStyle(.secondary)
                    Text(account.balance.currency)
                        .font(.system(.largeTitle, design: .rounded).weight(.bold))
                    let snapshots = (account.snapshots ?? []).sorted { $0.date < $1.date }
                    if snapshots.count > 1 {
                        Chart(snapshots) { snapshot in
                            LineMark(x: .value("Date", snapshot.date), y: .value("Balance", abs(snapshot.balance)))
                                .foregroundStyle(BudgyColor.forAccount(account.kind))
                                .interpolationMethod(.catmullRom)
                        }
                        .chartYScale(domain: .automatic(includesZero: false))
                        .frame(height: 140)
                    }
                    if account.kind == .creditCard && account.creditLimit > 0 {
                        BudgetBar(spent: account.balance, budget: account.creditLimit, color: .blue)
                        Text("\(Int(account.balance / account.creditLimit * 100))% of \(account.creditLimit.currencyWhole) limit used")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                .padding(.vertical, 4)
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
    @State private var creditLimit: Double
    @State private var isHidden: Bool

    init(account: Account?) {
        self.account = account
        self.name = account?.name ?? ""
        self.institution = account?.institution ?? ""
        self.kind = account?.kind ?? .checking
        self.balance = account?.balance ?? 0
        self.dueDay = account?.paymentDueDay ?? 0
        self.creditLimit = account?.creditLimit ?? 0
        self.isHidden = account?.isHidden ?? false
    }

    var body: some View {
        NavigationStack {
            Form {
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
                    Section("Card details") {
                        Picker("Payment due day", selection: $dueDay) {
                            Text("Not set").tag(0)
                            ForEach(1...31, id: \.self) { Text("\($0)").tag($0) }
                        }
                        LabeledContent("Credit limit") {
                            TextField("Limit", value: $creditLimit, format: .currency(code: "USD"))
                                .keyboardType(.decimalPad)
                                .multilineTextAlignment(.trailing)
                        }
                    }
                }
                if let account {
                    Section {
                        Toggle("Hide from totals", isOn: $isHidden)
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
        target.creditLimit = creditLimit
        target.isHidden = isHidden
        target.recordSnapshot(in: context)
        try? context.save()
        SyncService.performHousekeeping(context: context)
        dismiss()
    }
}
