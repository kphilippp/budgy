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
    @State private var showNew = false
    @Namespace private var zoom

    private var active: [RecurringItem] { items.filter { $0.isActive && !$0.needsReview } }
    private var review: [RecurringItem] { items.filter(\.needsReview) }
    private var priceIncreases: [RecurringItem] { active.filter(\.hasPriceIncrease) }
    private var filtered: [RecurringItem] { active.filter { $0.kind == filter } }

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                SubscriptionSummary(items: active)

                EngineReader { engine in
                    SubscriptionInsightsSection(insights: engine.subscriptionInsights)
                }

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
                                if item.id != review.last?.id { Divider().overlay(Color.hairline) }
                            }
                        }
                        .card(padding: 14)
                    }
                }

                if !priceIncreases.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(priceIncreases) { item in
                            HStack(spacing: 12) {
                                IconBadge(systemImage: "arrow.up.circle.fill", color: .clay, size: 34)
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
                        NavigationLink {
                            RecurringReserveDetailView(item: item)
                                .zoomDestination(item.id, in: zoom)
                        } label: {
                            RecurringRow(item: item)
                                .zoomSource(item.id, in: zoom, cornerRadius: Radius.field)
                        }
                            .buttonStyle(.plain)
                            .padding(.vertical, 8)
                        if item.id != filtered.last?.id { Divider().overlay(Color.hairline).padding(.leading, 50) }
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
        .budgyCanvas()
        .navigationTitle("Subscriptions")
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

/// Charges after cancelling, upcoming annual renewals, and subscriptions that seem to have stopped.
private struct SubscriptionInsightsSection: View {
    @Environment(\.modelContext) private var context
    var insights: SubscriptionInsights

    var body: some View {
        if !insights.isEmpty {
            VStack(spacing: 8) {
                ForEach(insights.chargedAfterCancel) { charge in
                    InsightRow(
                        systemImage: "exclamationmark.triangle.fill",
                        color: .clay,
                        title: "\(charge.item.name) charged after you cancelled",
                        detail: "\(charge.transaction.amount.currency) on \(charge.transaction.date.formatted(.dateTime.month(.abbreviated).day())). Contact them to stop it and ask for a refund."
                    ) {
                        Button("Dismiss", systemImage: "xmark") {
                            // Only flag charges newer than this one from now on.
                            withAnimation(Motion.standard) { charge.item.cancelledAt = charge.transaction.date }
                            try? context.save()
                        }
                        .labelStyle(.iconOnly)
                        .buttonBorderShape(.circle)
                    }
                }

                ForEach(insights.renewingSoon) { item in
                    InsightRow(
                        systemImage: "calendar.badge.exclamationmark",
                        color: .ochre,
                        title: "\(item.name) renews \(item.nextDueDate.relativeDayText)",
                        detail: "\(item.amount.currency) \(item.frequency.displayName.lowercased()) on \(item.nextDueDate.formatted(.dateTime.month(.abbreviated).day())). Cancel before then if you don't use it."
                    ) { EmptyView() }
                }

                ForEach(insights.noRecentCharge) { item in
                    InsightRow(
                        systemImage: "zzz",
                        color: .secondary,
                        title: "No charge from \(item.name) lately",
                        detail: item.lastChargedDate.map { "Last charged \($0.formatted(.dateTime.month(.abbreviated).day().year())). If you cancelled it, mark it ended so Budgy stops reserving money for it." } ?? ""
                    ) {
                        Button("Ended") {
                            withAnimation(Motion.standard) {
                                item.isActive = false
                                item.cancelledAt = .now
                            }
                            try? context.save()
                            SyncService.performHousekeeping(context: context)
                        }
                        .font(.caption.weight(.semibold))
                    }
                }
            }
        }
    }
}

private struct InsightRow<Action: View>: View {
    var systemImage: String
    var color: Color
    var title: String
    var detail: String
    @ViewBuilder var action: () -> Action

    var body: some View {
        HStack(spacing: 12) {
            IconBadge(systemImage: systemImage, color: color, size: 34)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.subheadline.weight(.semibold))
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            action()
                .buttonStyle(.glass)
        }
        .card(padding: 14)
    }
}

private struct SubscriptionSummary: View {
    var items: [RecurringItem]

    var body: some View {
        let subscriptions = items.filter { $0.kind == .subscription }
        let monthly = subscriptions.reduce(0) { $0 + $1.monthlyCost }
        let bills = items.filter { $0.kind == .bill }.reduce(0) { $0 + $1.monthlyCost }
        VStack(alignment: .leading, spacing: 6) {
            Text("Subscriptions each month").font(.subheadline.weight(.medium)).foregroundStyle(.secondary)
            MoneyText(monthly, size: 56, showsCents: true)
            Text("\((monthly * 12).currencyWhole) a year across \(subscriptions.count) subscription\(subscriptions.count == 1 ? "" : "s") · bills \(bills.currencyWhole)/mo")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.top, 4)
        .padding(.bottom, 6)
    }
}

private struct ReviewRow: View {
    @Environment(\.modelContext) private var context
    @Query private var categories: [Category]
    var item: RecurringItem

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                IconBadge(systemImage: item.systemImage, color: .heather, size: 34)
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.name).font(.subheadline.weight(.semibold))
                    Text("\(item.amount.currency) · \(item.frequency.displayName) · Looks like a \(item.kind.displayName.lowercased())")
                        .font(.caption).foregroundStyle(.secondary)
                    if item.hasPriceIncrease {
                        Text("Price went up from \(item.previousAmount.currency)")
                            .font(.caption.weight(.medium)).foregroundStyle(.clay)
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
                Text(dueText).font(.caption).foregroundStyle(isSoon ? .ochre : .secondary)
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
        case .subscription: .heather
        case .bill: .ochre
        case .payYourselfFirst: .moss
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

private struct RecurringReserveDetailView: View {
    var item: RecurringItem
    @State private var showEditor = false

    private var cycleStart: Date {
        item.frequency.retreat(item.nextDueDate)
    }

    private var isPaid: Bool {
        guard let lastChargedDate = item.lastChargedDate else { return false }
        return lastChargedDate >= cycleStart && lastChargedDate < item.nextDueDate
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                VStack(spacing: 6) {
                    Image(systemName: isPaid ? "checkmark.circle.fill" : "clock.badge.checkmark.fill")
                        .scaledFont(size: 34, weight: .semibold)
                        .foregroundStyle(isPaid ? .moss : .ochre)
                        .contentTransition(.symbolEffect(.replace))
                    Text(isPaid ? "Paid" : "Reserved, not paid yet")
                        .font(.display(.title2))
                    Text(isPaid
                         ? "The charge used the cash Budgy reserved for it."
                         : "This cash stays out of Spending Room until the charge arrives.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .padding(.top, 12)

                RecurringReserveFlow(item: item, isPaid: isPaid)

                VStack(spacing: 0) {
                    LabeledContent("Amount", value: item.amount.currency)
                    Divider().overlay(Color.hairline).padding(.vertical, 12)
                    LabeledContent("Frequency", value: item.frequency.displayName)
                    Divider().overlay(Color.hairline).padding(.vertical, 12)
                    LabeledContent(isPaid ? "Paid on" : "Due on") {
                        Text((isPaid ? item.lastChargedDate ?? item.nextDueDate : item.nextDueDate)
                            .formatted(date: .abbreviated, time: .omitted))
                    }
                    Divider().overlay(Color.hairline).padding(.vertical, 12)
                    LabeledContent("Next due") {
                        Text(item.nextDueDate.formatted(date: .abbreviated, time: .omitted))
                    }
                }
                .font(.subheadline)
                .card(padding: 16)

                Text("Budgy reserves this amount from available checking cash. It is not charged twice: after the matching transaction is detected, the reserve is consumed by the payment.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding()
        }
        .budgyCanvas(mist: false)
        .navigationTitle(item.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button("Edit", systemImage: "slider.horizontal.3") { showEditor = true }
            }
        }
        .sheet(isPresented: $showEditor) {
            RecurringEditor(item: item, defaultKind: item.kind)
        }
    }
}

private struct RecurringReserveFlow: View {
    var item: RecurringItem
    var isPaid: Bool

    var body: some View {
        VStack(spacing: 18) {
            HStack(spacing: isPaid ? -22 : 12) {
                ReserveNode(
                    title: "Reserved cash",
                    detail: item.amount.currency,
                    systemImage: "banknote.fill",
                    color: .lake
                )

                if !isPaid {
                    Image(systemName: "arrow.right")
                        .font(.title3.weight(.bold))
                        .foregroundStyle(.secondary)
                        .accessibilityHidden(true)
                }

                ReserveNode(
                    title: item.name,
                    detail: isPaid ? "Paid" : "Awaiting payment",
                    systemImage: isPaid ? "checkmark" : item.systemImage,
                    color: isPaid ? .moss : .heather
                )
                .zIndex(1)
            }
            .animation(Motion.gentle, value: isPaid)

            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Reserved")
                        .font(.caption.weight(.semibold))
                    Text("For this billing cycle")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 2) {
                    Text(isPaid ? "Payment matched" : "Payment expected")
                        .font(.caption.weight(.semibold))
                    Text((isPaid ? item.lastChargedDate ?? item.nextDueDate : item.nextDueDate)
                        .formatted(date: .abbreviated, time: .omitted))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .card(padding: 18)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(isPaid
                            ? "\(item.amount.currency) reserve consumed by paid \(item.name) charge"
                            : "\(item.amount.currency) reserved for \(item.name), not yet paid")
    }
}

private struct ReserveNode: View {
    var title: String
    var detail: String
    var systemImage: String
    var color: Color

    var body: some View {
        VStack(spacing: 8) {
            IconBadge(systemImage: systemImage, color: color, size: 84)

            Text(title)
                .font(.caption.weight(.semibold))
                .lineLimit(1)
            Text(detail)
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
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
                Group {
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
                .budgyRows()
            }
            .budgyList()
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
        if target.isActive && !isActive { target.cancelledAt = .now }
        if isActive { target.cancelledAt = nil }
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
