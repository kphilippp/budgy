import SwiftUI
import SwiftData

/// Home screen list of spending groups (Groceries, Gas & Transportation, Subscriptions…) as compact bar rows.
struct SpendingGroupsSection: View {
    @Environment(AppNavigation.self) private var navigation
    var groups: [FinanceEngine.GroupSpend]
    var windowStart: Date
    var unsortedCount: Int

    @State private var showNewGroup = false
    @State private var editing: Category?
    @State private var deleting: Category?

    private var rows: [FinanceEngine.GroupSpend] { groups.filter { $0.category != nil } }
    /// Groups without a budget draw their bar relative to the biggest spender.
    private var largestSpend: Double { max(rows.map(\.spent).max() ?? 0, 1) }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                SectionHeader(title: "Spending", trailing: "since \(windowStart.formatted(.dateTime.month(.abbreviated).day()))")
                Button("Add Group", systemImage: "plus") { showNewGroup = true }
                    .labelStyle(.iconOnly)
                    .buttonStyle(.glass)
                    .buttonBorderShape(.circle)
                    .controlSize(.small)
            }

            if unsortedCount > 0 {
                Button {
                    navigation.selectedTab = .sort
                } label: {
                    HStack(spacing: 12) {
                        IconBadge(systemImage: "square.stack.fill", color: .caution, size: 32)
                        Text("\(unsortedCount) transaction\(unsortedCount == 1 ? "" : "s") to sort")
                            .font(.subheadline.weight(.semibold))
                        Spacer()
                        Image(systemName: "chevron.right")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.tertiary)
                    }
                    .card(padding: 12)
                }
                .buttonStyle(.pressable)
                .accessibilityHint("Opens the Sort tab")
            }

            VStack(spacing: 0) {
                ForEach(rows) { group in
                    if let category = group.category {
                        NavigationLink {
                            GroupDetailView(category: category)
                        } label: {
                            GroupRow(group: group, largestSpend: largestSpend)
                        }
                        .buttonStyle(.plain)
                        .contextMenu {
                            Button("Edit Group", systemImage: "pencil") { editing = category }
                            Button("Delete Group", systemImage: "trash", role: .destructive) { deleting = category }
                        }
                        if group.id != rows.last?.id {
                            Divider().overlay(Color.hairline).padding(.leading, 46)
                        }
                    }
                }
            }
            .card(padding: 14)
        }
        .sheet(isPresented: $showNewGroup) { CategoryEditor(category: nil) }
        .sheet(item: $editing) { CategoryEditor(category: $0) }
        .confirmationDialog("Delete this group?", item: $deleting, titleVisibility: .visible) { category in
            DeleteGroupButton(category: category)
        } message: { category in
            Text("Transactions in \(category.name) will move to the Sort tab so you can regroup them.")
        }
    }
}

/// One compact row: icon, name, amount, and a thin bar.
private struct GroupRow: View {
    var group: FinanceEngine.GroupSpend
    var largestSpend: Double

    var body: some View {
        let color = BudgyColor.named(group.colorName)
        HStack(spacing: 12) {
            IconBadge(systemImage: group.systemImage, color: color, size: 34)
            VStack(alignment: .leading, spacing: 7) {
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Text(group.name)
                        .font(.subheadline.weight(.medium))
                        .lineLimit(1)
                    Spacer(minLength: 8)
                    Text(group.spent.currencyWhole)
                        .font(.subheadline.weight(.semibold))
                        .monospacedDigit()
                        .foregroundStyle(group.budget > 0 && group.spent > group.budget ? .negative : .primary)
                    if group.budget > 0 {
                        Text("of \(group.budget.currencyWhole)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                }
                if group.budget > 0 {
                    BudgetBar(spent: group.spent, budget: group.budget, color: color, height: 5)
                } else {
                    // No budget: show this group's share of spending instead.
                    ProgressBar(value: group.spent / largestSpend, color: color.opacity(0.7), height: 5)
                }
            }
        }
        .padding(.vertical, 9)
        .contentShape(.rect)
    }
}

// MARK: - Investments

/// Roth IRA, 401(k), and brokerage accounts on Home.
struct InvestmentGroupsSection: View {
    var engine: FinanceEngine
    @AppStorage("rothAnnualLimit") private var rothLimit: Double = 7_500

    private var accounts: [Account] {
        let order: [AccountKind] = [.rothIRA, .retirement401k, .brokerage]
        return engine.accounts
            .filter { $0.kind.isInvestment && !$0.isHidden }
            .sorted { (order.firstIndex(of: $0.kind) ?? 0, $0.sortOrder) < (order.firstIndex(of: $1.kind) ?? 0, $1.sortOrder) }
    }

    var body: some View {
        if !accounts.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                SectionHeader(title: "Investments", trailing: accounts.reduce(0) { $0 + $1.balance }.currencyWhole)
                VStack(spacing: 0) {
                    ForEach(accounts) { account in
                        NavigationLink {
                            AccountDetailView(account: account)
                        } label: {
                            InvestmentRow(account: account, rothYTD: account.kind == .rothIRA ? engine.rothContributionsThisYear : nil, rothLimit: rothLimit)
                        }
                        .buttonStyle(.plain)
                        if account.id != accounts.last?.id {
                            Divider().overlay(Color.hairline).padding(.leading, 46)
                        }
                    }
                }
                .card(padding: 14)
            }
        }
    }
}

private struct InvestmentRow: View {
    var account: Account
    var rothYTD: Double?
    var rothLimit: Double

    /// Change since the oldest balance Budgy has recorded.
    private var change: (amount: Double, since: Date)? {
        let snapshots = (account.snapshots ?? []).sorted { $0.date < $1.date }
        guard let first = snapshots.first, snapshots.count > 1 else { return nil }
        return (account.balance - first.balance, first.date)
    }

    var body: some View {
        let color = BudgyColor.forAccount(account.kind)
        HStack(spacing: 12) {
            IconBadge(systemImage: account.kind.systemImage, color: color, size: 34)
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(account.kind.displayName)
                            .font(.subheadline.weight(.medium))
                        Text(account.institution.isEmpty ? account.name : account.institution)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 8)
                    VStack(alignment: .trailing, spacing: 1) {
                        Text(account.balance.currencyWhole)
                            .font(.subheadline.weight(.semibold))
                            .monospacedDigit()
                        if let change {
                            Text("\(change.amount >= 0 ? "+" : "−")\(abs(change.amount).currencyWhole) since \(change.since.formatted(.dateTime.month(.abbreviated)))")
                                .font(.caption)
                                .foregroundStyle(change.amount >= 0 ? .positive : .negative)
                        }
                    }
                }
                if let rothYTD {
                    ProgressBar(value: rothLimit > 0 ? rothYTD / rothLimit : 0, color: color, height: 5)
                    Text("\(rothYTD.currencyWhole) of \(rothLimit.currencyWhole) contributed this year")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(.vertical, 9)
        .contentShape(.rect)
    }
}

private struct DeleteGroupButton: View {
    @Environment(\.modelContext) private var context
    var category: Category

    var body: some View {
        Button("Delete \(category.name)", role: .destructive) {
            withAnimation { category.deleteGroup(context: context) }
        }
    }
}

extension Category {
    /// Deletes the group and sends its transactions to the Sort tab.
    func deleteGroup(context: ModelContext) {
        for transaction in transactions ?? [] where transaction.kind == .expense {
            transaction.category = nil
            transaction.needsCategoryReview = true
        }
        let id = self.id
        let rules = (try? context.fetch(FetchDescriptor<MerchantRule>())) ?? []
        rules.filter { $0.categoryID == id }.forEach(context.delete)
        context.delete(self)
        try? context.save()
    }
}

/// Every transaction in one group, newest first.
struct GroupDetailView: View {
    @Environment(\.dismiss) private var dismiss
    @Bindable var category: Category
    @State private var showEdit = false

    private var transactions: [Transaction] {
        (category.transactions ?? []).sorted { $0.date > $1.date }
    }

    var body: some View {
        List {
            Group {
                Section {
                    HStack(spacing: 14) {
                        IconBadge(systemImage: category.systemImage, color: BudgyColor.named(category.colorName), size: 48)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(category.monthlyBudget > 0 ? "\(category.monthlyBudget.currencyWhole) per month" : "No budget")
                                .font(.headline)
                            Text("\(transactions.count) transaction\(transactions.count == 1 ? "" : "s")")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                    }
                    if category.systemRole == CategoryRole.subscriptions || category.systemRole == CategoryRole.bills {
                        NavigationLink("Manage Bills & Subscriptions") { SubscriptionsView(embedded: true) }
                    }
                }
                Section("Transactions") {
                    if transactions.isEmpty {
                        Text("Nothing here yet.").foregroundStyle(.secondary)
                    }
                    ForEach(transactions.prefix(100)) { transaction in
                        NavigationLink {
                            TransactionEditor(transaction: transaction)
                        } label: {
                            TransactionRow(transaction: transaction)
                        }
                    }
                }
            }
            .budgyRows()
        }
        .budgyList()
        .navigationTitle(category.name)
        .toolbar { Button("Edit") { showEdit = true } }
        .sheet(isPresented: $showEdit, onDismiss: {
            // The group may have been deleted from the editor.
            if category.modelContext == nil { dismiss() }
        }) {
            CategoryEditor(category: category)
        }
    }
}
