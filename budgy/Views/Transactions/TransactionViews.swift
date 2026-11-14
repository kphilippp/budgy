import SwiftUI
import SwiftData

struct TransactionRow: View {
    var transaction: Transaction

    private var icon: (String, Color) {
        switch transaction.kind {
        case .income: ("arrow.down.circle.fill", .moss)
        case .contribution: ("leaf.fill", .sage)
        case .transfer: ("arrow.left.arrow.right", .stone)
        case .creditCardPayment: ("creditcard.fill", .lake)
        case .refund: ("arrow.uturn.backward", .eucalyptus)
        case .expense:
            if let item = transaction.recurringItem { (item.systemImage, .ochre) }
            else if let category = transaction.category { (category.systemImage, BudgyColor.named(category.colorName)) }
            else { ("questionmark", .stone) }
        }
    }

    private var subtitle: String {
        var parts: [String] = []
        if transaction.kind == .expense {
            parts.append(transaction.recurringItem?.kind.displayName ?? transaction.category?.name ?? "Uncategorized")
        } else {
            parts.append(transaction.kind.displayName)
        }
        if let account = transaction.account { parts.append(account.name) }
        if transaction.isPending { parts.append("Pending") }
        return parts.joined(separator: " · ")
    }

    var body: some View {
        HStack(spacing: 12) {
            IconBadge(systemImage: icon.0, color: icon.1, size: 34)
            VStack(alignment: .leading, spacing: 2) {
                Text(transaction.displayName)
                    .font(.subheadline.weight(.medium))
                    .lineLimit(1)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                Text(transaction.amount < 0 ? "+\(abs(transaction.amount).currency)" : transaction.amount.currency)
                    .font(.subheadline.weight(.semibold).monospacedDigit())
                    .foregroundStyle(transaction.amount < 0 ? .moss : .primary)
                Text(transaction.date.formatted(.dateTime.month(.abbreviated).day()))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .contentShape(.rect)
    }
}

struct TransactionListView: View {
    @Query(sort: \Transaction.date, order: .reverse) private var transactions: [Transaction]
    @State private var searchText = ""
    @State private var showAdd = false

    private var filtered: [Transaction] {
        guard !searchText.isEmpty else { return transactions }
        return transactions.filter {
            $0.displayName.localizedCaseInsensitiveContains(searchText)
                || ($0.category?.name.localizedCaseInsensitiveContains(searchText) ?? false)
        }
    }

    private var grouped: [(day: Date, items: [Transaction])] {
        let groups = Dictionary(grouping: filtered) { Calendar.current.startOfDay(for: $0.date) }
        return groups.keys.sorted(by: >).map { ($0, groups[$0] ?? []) }
    }

    var body: some View {
        List {
            Group {
                ForEach(grouped, id: \.day) { group in
                    Section(group.day.formatted(.dateTime.weekday(.wide).month().day())) {
                        ForEach(group.items) { transaction in
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
        .overlay {
            if filtered.isEmpty {
                ContentUnavailableView.search(text: searchText)
            }
        }
        .navigationTitle("Transactions")
        .searchable(text: $searchText, prompt: "Merchant or category")
        .toolbar {
            Button("Add", systemImage: "plus") { showAdd = true }
        }
        .sheet(isPresented: $showAdd) { TransactionEditor(transaction: nil) }
    }
}

/// Adds a new transaction (when `transaction` is nil) or edits an existing one.
struct TransactionEditor: View {
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @Query(sort: \Category.sortOrder) private var categories: [Category]
    @Query(sort: \Account.sortOrder) private var accounts: [Account]

    let transaction: Transaction?

    @State private var name: String
    @State private var amountText: String
    @State private var date: Date
    @State private var kind: TransactionKind
    @State private var categoryID: UUID?
    @State private var accountID: UUID?
    @State private var notes: String
    @State private var rememberCategory: Bool

    init(transaction: Transaction?) {
        self.transaction = transaction
        self.name = transaction?.displayName ?? ""
        self.amountText = transaction.map { String(format: "%.2f", abs($0.amount)) } ?? ""
        self.date = transaction?.date ?? .now
        self.kind = transaction?.kind ?? .expense
        self.categoryID = transaction?.category?.id
        self.accountID = transaction?.account?.id
        self.notes = transaction?.notes ?? ""
        self.rememberCategory = false
    }

    private var amount: Double? { Double(amountText.replacingOccurrences(of: ",", with: "").replacingOccurrences(of: "$", with: "")) }
    private var isNew: Bool { transaction == nil }

    var body: some View {
        if isNew {
            NavigationStack { form }
        } else {
            form
        }
    }

    private var form: some View {
        Form {
            Group {
                Section {
                    TextField("Merchant or description", text: $name)
                        .font(.title3.weight(.medium))
                    HStack {
                        Text("$").foregroundStyle(.secondary)
                        TextField("0.00", text: $amountText)
                            .keyboardType(.decimalPad)
                            .font(.system(.largeTitle, design: .serif))
                    }
                }

                Section {
                    Picker("Type", selection: $kind) {
                        ForEach(TransactionKind.allCases) { Text($0.displayName).tag($0) }
                    }
                    if kind == .expense || kind == .refund {
                        Picker("Group", selection: $categoryID) {
                            Text("Unsorted").tag(UUID?.none)
                            ForEach(categories) { category in
                                Label(category.name, systemImage: category.systemImage).tag(Optional(category.id))
                            }
                        }
                    }
                    Picker("Account", selection: $accountID) {
                        Text("None").tag(UUID?.none)
                        ForEach(accounts) { account in
                            Text(account.name).tag(Optional(account.id))
                        }
                    }
                    DatePicker("Date", selection: $date, displayedComponents: .date)
                }

                if !isNew, kind == .expense, !name.isEmpty {
                    Section {
                        Toggle("Always categorize \(name) this way", isOn: $rememberCategory)
                    }
                }

                Section("Notes") {
                    TextField("Optional", text: $notes, axis: .vertical)
                }

                if let transaction, !transaction.isLinkedToPlaid {
                    Section {
                        Button("Delete Transaction", role: .destructive) {
                            context.delete(transaction)
                            try? context.save()
                            dismiss()
                        }
                    }
                }
            }
            .budgyRows()
        }
        .budgyList()
        .navigationTitle(isNew ? "New Transaction" : "Edit Transaction")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if isNew {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", systemImage: "xmark") { dismiss() }
                }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button("Save", systemImage: "checkmark") { save() }
                    .disabled(name.isEmpty || amount == nil)
            }
        }
    }

    private func save() {
        guard let amount else { return }
        // Store using Plaid's sign convention: money in is negative.
        let signed = (kind == .income || kind == .refund) ? -abs(amount) : abs(amount)
        let target: Transaction
        if let transaction {
            target = transaction
            if transaction.merchant.isEmpty { transaction.name = name } else { transaction.merchant = name }
        } else {
            target = Transaction(name: name, merchant: name, amount: signed, date: date, kind: kind)
            context.insert(target)
        }
        target.amount = signed
        target.date = date
        target.kind = kind
        target.notes = notes
        target.category = (kind == .expense || kind == .refund) ? categories.first { $0.id == categoryID } : nil
        target.account = accounts.first { $0.id == accountID }
        target.needsCategoryReview = false

        if rememberCategory {
            let key = name.merchantKey
            let existing = (try? context.fetch(FetchDescriptor<MerchantRule>(predicate: #Predicate { $0.merchantKey == key }))) ?? []
            existing.forEach(context.delete)
            context.insert(MerchantRule(merchantKey: key, categoryID: categoryID, kind: kind))
            // Apply the rule to past transactions from the same merchant too.
            let all = (try? context.fetch(FetchDescriptor<Transaction>())) ?? []
            for other in all where other.displayName.merchantKey == key && other.kind == .expense {
                other.category = target.category
            }
        }

        try? context.save()
        SyncService.performHousekeeping(context: context)
        dismiss()
    }
}

extension Transaction {
    var isLinkedToPlaid: Bool { !plaidTransactionID.isEmpty }
}
