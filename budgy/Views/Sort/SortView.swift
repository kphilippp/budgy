import SwiftUI
import SwiftData

/// Tinder-style sorting for transactions Budgy couldn't group on its own.
/// Swipe right to accept the suggestion, swipe left to pick a different group,
/// or tap a group below the card.
struct SortView: View {
    @Environment(\.modelContext) private var context
    @Query(filter: #Predicate<Transaction> { $0.needsCategoryReview }, sort: \Transaction.date, order: .reverse)
    private var pending: [Transaction]
    @Query(sort: \Category.sortOrder) private var groups: [Category]

    @State private var dragOffset: CGSize = .zero
    @State private var showPicker = false
    @State private var rememberMerchant = true
    @State private var lastAction: SortAction?
    @State private var showNewGroup = false

    /// Enough to undo one sort.
    struct SortAction {
        var transactions: [(Transaction, Category?, TransactionKind)]
        var rule: MerchantRule?
    }

    private var queue: [Transaction] { pending.filter { $0.kind == .expense } }

    var body: some View {
        NavigationStack {
            VStack(spacing: 20) {
                if let current = queue.first {
                    Text("\(queue.count) left to sort")
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(.secondary)
                        .contentTransition(.numericText(value: Double(queue.count)))

                    cardStack(current: current)
                        .frame(maxHeight: 380)

                    Toggle("Always group \(current.displayName) this way", isOn: $rememberMerchant)
                        .font(.subheadline)
                        .padding(.horizontal, 4)

                    groupChips(for: current)
                } else {
                    Spacer()
                    ContentUnavailableView {
                        Label("All sorted", systemImage: "checkmark.seal.fill")
                    } description: {
                        Text("Budgy will ask here when it isn't sure which group a purchase belongs in.")
                    }
                    Spacer()
                }
            }
            .padding()
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .background(Color(.systemGroupedBackground))
            .navigationTitle("Sort")
            .toolbar {
                if lastAction != nil {
                    ToolbarItem(placement: .topBarLeading) {
                        Button("Undo", systemImage: "arrow.uturn.backward") { undo() }
                    }
                }
            }
            .budgyToolbar()
            .sheet(isPresented: $showPicker) {
                if let current = queue.first {
                    GroupPickerSheet(transaction: current, groups: groups) { group in
                        sort(current, into: group)
                    } onNotSpending: {
                        markNotSpending(current)
                    }
                }
            }
            .sheet(isPresented: $showNewGroup) { CategoryEditor(category: nil) }
        }
    }

    // MARK: Cards

    private func cardStack(current: Transaction) -> some View {
        ZStack {
            // Peek at the next two cards behind the current one.
            ForEach(Array(queue.prefix(3).enumerated().reversed()), id: \.element.id) { index, transaction in
                if index == 0 {
                    SortCard(transaction: transaction, suggestion: transaction.category, swipe: dragOffset.width)
                        .offset(dragOffset)
                        .rotationEffect(.degrees(Double(dragOffset.width / 18)))
                        .gesture(swipeGesture(for: transaction))
                } else {
                    SortCard(transaction: transaction, suggestion: transaction.category, swipe: 0)
                        .scaleEffect(1 - CGFloat(index) * 0.05)
                        .offset(y: CGFloat(index) * 14)
                        .opacity(1 - Double(index) * 0.25)
                        .allowsHitTesting(false)
                }
            }
        }
        .animation(.spring(duration: 0.35), value: queue.first?.id)
    }

    private func swipeGesture(for transaction: Transaction) -> some Gesture {
        DragGesture()
            .onChanged { dragOffset = $0.translation }
            .onEnded { value in
                let threshold: CGFloat = 110
                if value.translation.width > threshold, let suggestion = transaction.category {
                    flyOff(direction: 1) { sort(transaction, into: suggestion) }
                } else if value.translation.width > threshold || value.translation.width < -threshold {
                    // No suggestion, or swiped left: choose a group.
                    withAnimation(.spring) { dragOffset = .zero }
                    showPicker = true
                } else {
                    withAnimation(.spring) { dragOffset = .zero }
                }
            }
    }

    private func flyOff(direction: CGFloat, then action: @escaping () -> Void) {
        withAnimation(.easeIn(duration: 0.2)) { dragOffset = CGSize(width: direction * 600, height: 40) }
        Task {
            try? await Task.sleep(for: .milliseconds(200))
            action()
            dragOffset = .zero
        }
    }

    // MARK: Group chips

    private func groupChips(for transaction: Transaction) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Or tap a group")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(groups) { group in
                        Button {
                            flyOff(direction: 1) { sort(transaction, into: group) }
                        } label: {
                            Label(group.name, systemImage: group.systemImage)
                        }
                        .buttonStyle(.glass)
                        .tint(BudgyColor.named(group.colorName))
                    }
                    Button("Not Spending", systemImage: "arrow.left.arrow.right") {
                        flyOff(direction: -1) { markNotSpending(transaction) }
                    }
                    .buttonStyle(.glass)
                    Button("New Group", systemImage: "plus") { showNewGroup = true }
                        .buttonStyle(.glass)
                }
                .font(.subheadline.weight(.medium))
            }
            .scrollClipDisabled()
        }
    }

    // MARK: Actions

    private func sort(_ transaction: Transaction, into group: Category) {
        var changed: [(Transaction, Category?, TransactionKind)] = [(transaction, transaction.category, transaction.kind)]
        transaction.category = group
        transaction.needsCategoryReview = false
        var rule: MerchantRule?
        if rememberMerchant {
            let key = transaction.displayName.merchantKey
            if !key.isEmpty {
                let newRule = MerchantRule(merchantKey: key, categoryID: group.id, kind: .expense)
                context.insert(newRule)
                rule = newRule
                // Sort the rest of this merchant's pending charges the same way.
                for other in queue where other.id != transaction.id && other.displayName.merchantKey == key {
                    changed.append((other, other.category, other.kind))
                    other.category = group
                    other.needsCategoryReview = false
                }
            }
        }
        lastAction = SortAction(transactions: changed, rule: rule)
        try? context.save()
    }

    private func markNotSpending(_ transaction: Transaction) {
        lastAction = SortAction(transactions: [(transaction, transaction.category, transaction.kind)], rule: nil)
        transaction.kind = .transfer
        transaction.category = nil
        transaction.needsCategoryReview = false
        try? context.save()
    }

    private func undo() {
        guard let lastAction else { return }
        withAnimation {
            for (transaction, category, kind) in lastAction.transactions {
                transaction.category = category
                transaction.kind = kind
                transaction.needsCategoryReview = true
            }
            if let rule = lastAction.rule { context.delete(rule) }
        }
        self.lastAction = nil
        try? context.save()
    }
}

/// One transaction to sort.
private struct SortCard: View {
    @Environment(\.themeColor) private var themeColor
    var transaction: Transaction
    var suggestion: Category?
    /// Horizontal drag, used to fade in the accept / choose hints.
    var swipe: CGFloat

    var body: some View {
        VStack(spacing: 18) {
            HStack {
                hint("Choose", systemImage: "square.grid.2x2", color: .orange)
                    .opacity(Double(max(-swipe, 0) / 110))
                Spacer()
                hint(suggestion.map { "Add to \($0.name)" } ?? "Choose", systemImage: "checkmark", color: themeColor)
                    .opacity(Double(max(swipe, 0) / 110))
            }
            .frame(height: 28)

            Spacer(minLength: 0)

            Text(transaction.amount.currency)
                .font(.system(size: 48, weight: .bold, design: .rounded))
                .monospacedDigit()
            VStack(spacing: 4) {
                Text(transaction.displayName)
                    .font(.title3.weight(.semibold))
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                Text([transaction.date.formatted(.dateTime.weekday(.wide).month().day()), transaction.account?.name]
                    .compactMap { $0 }.joined(separator: " · "))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 0)

            if let suggestion {
                HStack(spacing: 8) {
                    IconBadge(systemImage: suggestion.systemImage, color: BudgyColor.named(suggestion.colorName), size: 26)
                    Text("Looks like **\(suggestion.name)**")
                        .font(.subheadline)
                }
                Text("Swipe right to accept · left to choose")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Text("Swipe either way to choose a group")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .glassEffect(.regular, in: .rect(cornerRadius: 32))
        .accessibilityElement(children: .combine)
        .accessibilityHint("Swipe right to accept the suggestion, or use the group buttons below.")
    }

    private func hint(_ title: String, systemImage: String, color: Color) -> some View {
        Label(title, systemImage: systemImage)
            .font(.caption.weight(.bold))
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .foregroundStyle(color)
            .overlay { Capsule().stroke(color, lineWidth: 2) }
    }
}

/// Full list of groups, shown after a left swipe.
private struct GroupPickerSheet: View {
    @Environment(\.dismiss) private var dismiss
    var transaction: Transaction
    var groups: [Category]
    var onPick: (Category) -> Void
    var onNotSpending: () -> Void

    private let columns = Array(repeating: GridItem(.flexible(), spacing: 12), count: 3)

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVGrid(columns: columns, spacing: 16) {
                    ForEach(groups) { group in
                        Button {
                            onPick(group)
                            dismiss()
                        } label: {
                            VStack(spacing: 8) {
                                IconBadge(systemImage: group.systemImage, color: BudgyColor.named(group.colorName), size: 48)
                                Text(group.name)
                                    .font(.caption.weight(.medium))
                                    .multilineTextAlignment(.center)
                                    .lineLimit(2)
                            }
                            .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.plain)
                    }
                    Button {
                        onNotSpending()
                        dismiss()
                    } label: {
                        VStack(spacing: 8) {
                            IconBadge(systemImage: "arrow.left.arrow.right", color: .gray, size: 48)
                            Text("Not Spending").font(.caption.weight(.medium))
                        }
                        .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.plain)
                }
                .padding()
            }
            .navigationTitle(transaction.displayName)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel", systemImage: "xmark") { dismiss() } }
            }
        }
        .presentationDetents([.medium, .large])
    }
}
