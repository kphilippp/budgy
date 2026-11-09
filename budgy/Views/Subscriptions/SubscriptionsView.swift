import SwiftUI
import SwiftData

struct SubscriptionsView: View {
    /// When pushed from another screen, skip the extra NavigationStack.
    var embedded = false

    var body: some View {
        if embedded {
            SubscriptionsContent()
        } else {
            NavigationStack {
                SubscriptionsContent()
                    .budgyToolbar()
            }
        }
    }
}

private struct SubscriptionsContent: View {
    @Environment(\.modelContext) private var context
    @Query private var categories: [Category]
    @Query(sort: \RecurringItem.nextDueDate) private var items: [RecurringItem]
    @State private var filter: RecurringKind = .subscription
    @State private var editing: RecurringItem?
    @State private var showNew = false

    private var active: [RecurringItem] { items.filter { $0.isActive && !$0.needsReview } }
    private var review: [RecurringItem] { items.filter(\.needsReview) }
    private var priceIncreases: [RecurringItem] { active.filter(\.hasPriceIncrease) }
    private var filtered: [RecurringItem] { active.filter { $0.kind == filter } }

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                SubscriptionSummary(items: active)

                if !review.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            SectionHeader(title: "Found for You", trailing: "\(review.count) to review")
                            Button("Confirm All") {
                                withAnimation {
                                    for item in review {
                                        item.needsReview = false
                                        CategoryRole.applyGroup(for: item, categories: categories)
                                    }
                                }
                                try? context.save()
                                SyncService.performHousekeeping(context: context)
                            }
                            .buttonStyle(.glass)
                            .font(.caption.weight(.semibold))
                            .padding(.top, 8)
                        }
                        VStack(spacing: 12) {
                            ForEach(review) { item in
                                ReviewRow(item: item)
                                if item.id != review.last?.id { Divider() }
                            }
                        }
                        .card(padding: 14)
                    }
                }

                if !priceIncreases.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(priceIncreases) { item in
                            HStack(spacing: 12) {
                                IconBadge(systemImage: "arrow.up.circle.fill", color: .red, size: 34)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("\(item.name) went up").font(.subheadline.weight(.semibold))
                                    Text("\(item.previousAmount.currency) → \(item.amount.currency) · \((item.yearlyCost - item.previousAmount * item.frequency.occurrencesPerYear).currency) more per year")
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                                Button("Dismiss", systemImage: "xmark") {
                                    withAnimation { item.previousAmount = 0 }
                                }
                                .labelStyle(.iconOnly)
                                .buttonStyle(.glass)
                                .buttonBorderShape(.circle)
                            }
                            .card(padding: 14)
                        }
                    }
                }

                Picker("Type", selection: $filter) {
                    Text("Subscriptions").tag(RecurringKind.subscription)
                    Text("Bills").tag(RecurringKind.bill)
                    Text("Pay Yourself").tag(RecurringKind.payYourselfFirst)
                }
                .pickerStyle(.segmented)

                VStack(spacing: 0) {
                    if filtered.isEmpty {
                        Text(emptyMessage)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.vertical, 8)
                    }
                    ForEach(filtered) { item in
                        Button { editing = item } label: { RecurringRow(item: item) }
                            .buttonStyle(.plain)
                            .padding(.vertical, 8)
                        if item.id != filtered.last?.id { Divider().padding(.leading, 50) }
                    }
                }
                .card(padding: 14)

                Button {
                    showNew = true
                } label: {
                    Label("Add \(filter.displayName)", systemImage: "plus").frame(maxWidth: .infinity)
                }
                .buttonStyle(.glass)
                .controlSize(.large)
            }
            .padding(.horizontal)
            .padding(.bottom, 24)
        }
        .background(Color(.systemGroupedBackground))
        .navigationTitle("Subscriptions")
        .sheet(item: $editing) { RecurringEditor(item: $0, defaultKind: $0.kind) }
        .sheet(isPresented: $showNew) { RecurringEditor(item: nil, defaultKind: filter) }
    }

    private var emptyMessage: String {
        switch filter {
        case .subscription: "No subscriptions yet. Budgy finds them automatically once your bank is connected."
        case .bill: "Add rent, utilities, phone, and insurance so Safe to Spend can plan around them."
        case .payYourselfFirst: "Add your Roth IRA deposit so it's set aside before you spend."
        }
    }
}

private struct SubscriptionSummary: View {
    var items: [RecurringItem]

    var body: some View {
        let subscriptions = items.filter { $0.kind == .subscription }
        let monthly = subscriptions.reduce(0) { $0 + $1.monthlyCost }
        let bills = items.filter { $0.kind == .bill }.reduce(0) { $0 + $1.monthlyCost }
        VStack(alignment: .leading, spacing: 8) {
            Text("Subscriptions").font(.subheadline.weight(.medium)).foregroundStyle(.secondary)
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(monthly.currency)
                    .font(.system(size: 44, weight: .bold, design: .rounded))
                Text("/mo").font(.title3).foregroundStyle(.secondary)
            }
            Text("\((monthly * 12).currencyWhole) a year across \(subscriptions.count) subscription\(subscriptions.count == 1 ? "" : "s") · Bills \(bills.currencyWhole)/mo")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassEffect(.regular.tint(.purple.opacity(0.1)), in: .rect(cornerRadius: 28))
    }
}

private struct ReviewRow: View {
    @Environment(\.modelContext) private var context
    @Query private var categories: [Category]
    var item: RecurringItem

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                IconBadge(systemImage: item.systemImage, color: .purple, size: 34)
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.name).font(.subheadline.weight(.semibold))
                    Text("\(item.amount.currency) · \(item.frequency.displayName) · Looks like a \(item.kind.displayName.lowercased())")
                        .font(.caption).foregroundStyle(.secondary)
                    if item.hasPriceIncrease {
                        Text("Price went up from \(item.previousAmount.currency)")
                            .font(.caption.weight(.medium)).foregroundStyle(.red)
                    }
                }
                Spacer()
            }
            HStack {
                if item.kind == .payYourselfFirst {
                    Button("Pay Yourself First") { confirm(.payYourselfFirst) }
                } else {
                    Button("Subscription") { confirm(.subscription) }
                    Button("Bill") { confirm(.bill) }
                }
                Spacer()
                Button("Not Recurring", role: .destructive) {
                    // Keep it (inactive) so detection doesn't suggest it again.
                    withAnimation {
                        item.needsReview = false
                        item.isActive = false
                        // Its charges are regular spending again; let the Sort tab place them.
                        for transaction in item.transactions ?? [] where transaction.kind == .expense {
                            transaction.recurringItem = nil
                            transaction.category = nil
                            transaction.needsCategoryReview = true
                        }
                    }
                    try? context.save()
                }
            }
            .buttonStyle(.glass)
            .font(.caption.weight(.semibold))
        }
    }

    private func confirm(_ kind: RecurringKind) {
        withAnimation {
            item.kind = kind
            item.needsReview = false
            if item.systemImage == RecurringKind.subscription.systemImage { item.systemImage = kind.systemImage }
            CategoryRole.applyGroup(for: item, categories: categories)
        }
        try? context.save()
        SyncService.performHousekeeping(context: context)
    }
}

struct RecurringRow: View {
    var item: RecurringItem

    var body: some View {
        HStack(spacing: 12) {
            IconBadge(systemImage: item.systemImage, color: color, size: 38)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.name).font(.subheadline.weight(.semibold))
                Text(dueText).font(.caption).foregroundStyle(isSoon ? .orange : .secondary)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                Text(item.amount.currency).font(.subheadline.weight(.semibold).monospacedDigit())
                Text(item.frequency.displayName).font(.caption).foregroundStyle(.secondary)
            }
        }
        .contentShape(.rect)
    }

    private var color: Color {
        switch item.kind {
        case .subscription: .purple
        case .bill: .orange
        case .payYourselfFirst: .green
        }
    }

    private var isSoon: Bool {
        item.nextDueDate.timeIntervalSinceNow < 3 * 86_400
    }

    private var dueText: String {
        let relative = item.nextDueDate.relativeDayText
        return "\(item.kind == .payYourselfFirst ? "Next" : "Renews") \(relative) · \(item.nextDueDate.formatted(.dateTime.month(.abbreviated).day()))"
    }
}

struct RecurringEditor: View {
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @Query(sort: \Account.sortOrder) private var accounts: [Account]

    let item: RecurringItem?

    @State private var name: String
    @State private var amount: Double
    @State private var frequency: Frequency
    @State private var kind: RecurringKind
    @State private var nextDueDate: Date
    @State private var matchText: String
    @State private var remindDaysBefore: Int
    @State private var destinationID: UUID?
    @State private var isActive: Bool
    @State private var loggedContribution = false

    init(item: RecurringItem?, defaultKind: RecurringKind) {
        self.item = item
        self.name = item?.name ?? (defaultKind == .payYourselfFirst ? "Roth IRA Deposit" : "")
        self.amount = item?.amount ?? 0
        self.frequency = item?.frequency ?? (defaultKind == .payYourselfFirst ? .biweekly : .monthly)
        self.kind = item?.kind ?? defaultKind
        self.nextDueDate = item?.nextDueDate ?? .now
        self.matchText = item?.matchText ?? (defaultKind == .payYourselfFirst ? "schwab" : "")
        self.remindDaysBefore = item?.remindDaysBefore ?? 2
        self.destinationID = item?.destinationAccountID
        self.isActive = item?.isActive ?? true
    }

    private var investmentAccounts: [Account] { accounts.filter { $0.kind.isInvestment || $0.kind == .savings } }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Name", text: $name).font(.title3)
                    LabeledContent("Amount") {
                        TextField("Amount", value: $amount, format: .currency(code: "USD"))
                            .keyboardType(.decimalPad)
                            .multilineTextAlignment(.trailing)
                    }
                    Picker("Type", selection: $kind) {
                        ForEach(RecurringKind.allCases) { Label($0.displayName, systemImage: $0.systemImage).tag($0) }
                    }
                }

                Section {
                    Picker("Repeats", selection: $frequency) {
                        ForEach(Frequency.allCases) { Text($0.displayName).tag($0) }
                    }
                    DatePicker(kind == .payYourselfFirst ? "Next transfer" : "Next charge", selection: $nextDueDate, displayedComponents: .date)
                    if kind != .payYourselfFirst {
                        Stepper("Remind me \(remindDaysBefore) day\(remindDaysBefore == 1 ? "" : "s") before", value: $remindDaysBefore, in: 0...14)
                    }
                } footer: {
                    if kind == .payYourselfFirst {
                        Text("Tip: match this to your payday so it's set aside the moment you're paid.")
                    }
                }

                if kind == .payYourselfFirst {
                    Section {
                        Picker("Goes to", selection: $destinationID) {
                            Text("Choose account").tag(UUID?.none)
                            ForEach(investmentAccounts) { account in
                                Text("\(account.name) (\(account.institution))").tag(Optional(account.id))
                            }
                        }
                        if let item {
                            Button(loggedContribution ? "Logged ✓" : "Log a contribution now") {
                                logContribution(for: item)
                            }
                            .disabled(loggedContribution)
                        }
                    } header: {
                        Text("Destination")
                    } footer: {
                        Text("Pay Yourself First money leaves checking but isn't counted as spending. Contributions to a Roth IRA count toward your yearly limit on the Accounts tab.")
                    }
                }

                Section {
                    TextField("e.g. netflix", text: $matchText)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                } header: {
                    Text("Match bank transactions containing")
                } footer: {
                    Text("Budgy links charges with this text to this item, tracks price changes, and moves the due date forward when it's paid.")
                }

                if let item {
                    Section {
                        Toggle("Active", isOn: $isActive)
                        Button("Delete", role: .destructive) {
                            context.delete(item)
                            try? context.save()
                            SyncService.performHousekeeping(context: context)
                            dismiss()
                        }
                    } footer: {
                        if let last = item.lastChargedDate {
                            Text("Last charged \(last.formatted(date: .abbreviated, time: .omitted)).")
                        }
                    }
                }
            }
            .navigationTitle(item == nil ? "New \(kind.displayName)" : name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel", systemImage: "xmark") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save", systemImage: "checkmark", action: save).disabled(name.isEmpty || amount <= 0)
                }
            }
        }
    }

    private func save() {
        let target = item ?? {
            let new = RecurringItem(name: name, amount: amount, frequency: frequency, kind: kind, nextDueDate: nextDueDate, matchText: matchText)
            context.insert(new)
            return new
        }()
        if target.amount != amount && target.kind != .payYourselfFirst { target.previousAmount = 0 }
        target.name = name
        target.amount = amount
        target.frequency = frequency
        if target.kind != kind && target.systemImage == target.kind.systemImage { target.systemImage = kind.systemImage }
        target.kind = kind
        target.nextDueDate = Calendar.current.startOfDay(for: nextDueDate)
        target.matchText = matchText.isEmpty ? name.lowercased() : matchText.lowercased()
        target.remindDaysBefore = remindDaysBefore
        target.destinationAccountID = kind == .payYourselfFirst ? destinationID : nil
        target.isActive = isActive
        target.needsReview = false
        try? context.save()
        SyncService.performHousekeeping(context: context)
        dismiss()
    }

    /// For manual tracking: records a transfer and advances the schedule.
    private func logContribution(for item: RecurringItem) {
        let transaction = Transaction(name: item.name, amount: item.amount, date: .now, kind: .contribution)
        context.insert(transaction)
        transaction.recurringItem = item
        transaction.account = accounts.first { $0.kind == .checking }
        item.lastChargedDate = .now
        item.rollForward(past: .now)
        nextDueDate = item.nextDueDate
        loggedContribution = true
        try? context.save()
    }
}
