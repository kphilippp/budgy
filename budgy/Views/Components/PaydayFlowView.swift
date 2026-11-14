import SwiftUI
import SwiftData

struct PaydayFlowView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var context
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @Bindable var schedule: PaySchedule
    var paycheck: Transaction
    var savingsAmount: Double
    var reservedCharges: [UpcomingCharge]
    var safeToSpend: Double
    var nextPayday: Date

    @State private var step = 0
    @State private var confirmedSavings = false
    @State private var finished = false

    var body: some View {
        ZStack {
            BudgyBackground()
            VStack(spacing: 0) {
                PaydayProgress(step: step)
                    .padding(.horizontal, 24)
                    .padding(.top, 16)

                Group {
                    switch step {
                    case 0:
                        PaydayWelcomeStep(amount: -paycheck.amount)
                    case 1:
                        PaydaySavingsStep(
                            amount: savingsAmount,
                            rate: schedule.savingsRate,
                            isConfirmed: confirmedSavings,
                            confirm: { confirmedSavings = true }
                        )
                    case 2:
                        PaydayReservesStep(charges: reservedCharges)
                    default:
                        PaydaySpendingRoomStep(
                            amount: safeToSpend,
                            nextPayday: nextPayday
                        )
                    }
                }
                .id(step)
                .transition(.asymmetric(
                    insertion: .move(edge: .trailing).combined(with: .opacity),
                    removal: .move(edge: .leading).combined(with: .opacity)
                ))

                PaydayFooter(
                    step: step,
                    canContinue: step != 1 || confirmedSavings,
                    action: advance
                )
                .padding(24)
            }
        }
        .interactiveDismissDisabled()
        // Money moved and the plan is set: the two moments in this flow worth feeling.
        .sensoryFeedback(.success, trigger: confirmedSavings) { _, confirmed in confirmed }
        .sensoryFeedback(.success, trigger: finished) { _, done in done }
    }

    private func advance() {
        if step < 3 {
            // The first reveal is a bigger moment, so it gets the slower spring.
            withAnimation(Motion.animation(step == 0 ? Motion.gentle : Motion.standard, reduceMotion: reduceMotion)) {
                step += 1
            }
        } else {
            finished = true
            schedule.lastSavingsTransferPaycheckID = paycheck.id
            try? context.save()
            SyncService.performHousekeeping(context: context)
            dismiss()
        }
    }
}

private struct PaydayProgress: View {
    @Environment(\.themeColor) private var themeColor
    var step: Int

    var body: some View {
        HStack(spacing: 6) {
            ForEach(0..<4, id: \.self) { index in
                Capsule()
                    .fill(index <= step ? themeColor : Color.ink.opacity(0.1))
                    .frame(height: 5)
            }
        }
        .animation(Motion.standard, value: step)
        .accessibilityLabel("Payday step \(step + 1) of 4")
    }
}

/// One payday step: a pebble, a serif headline, the figure, and a quiet explanation.
private struct PaydayStepLayout<Accessory: View>: View {
    var systemImage: String
    var color: Color
    var title: String
    var amount: Double?
    var amountColor: Color?
    var detail: String
    var celebrates = false
    @ViewBuilder var accessory: Accessory

    var body: some View {
        VStack(spacing: 18) {
            Spacer()
            IconBadge(systemImage: systemImage, color: color, size: 92)
                .symbolEffect(.bounce, options: .nonRepeating, isActive: celebrates)
            Text(title)
                .font(.display(.largeTitle))
                .multilineTextAlignment(.center)
            if let amount {
                MoneyText(amount, size: 60)
                    .foregroundStyle(amountColor.map { AnyShapeStyle($0) } ?? AnyShapeStyle(.primary))
            }
            Text(detail)
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            accessory
            Spacer()
        }
        .padding(28)
    }
}

private struct PaydayWelcomeStep: View {
    @Environment(\.themeColor) private var themeColor
    var amount: Double

    var body: some View {
        PaydayStepLayout(
            systemImage: "party.popper.fill",
            color: themeColor,
            title: "Ayy, you just got paid!",
            amount: amount,
            detail: "Let's protect your future first, reserve what is already spoken for, and then reveal what you can spend.",
            celebrates: true
        ) { EmptyView() }
    }
}

private struct PaydaySavingsStep: View {
    var amount: Double
    var rate: Double
    var isConfirmed: Bool
    var confirm: () -> Void

    var body: some View {
        PaydayStepLayout(
            systemImage: "arrow.down.heart.fill",
            color: .positive,
            title: "Move your money first",
            amount: amount,
            amountColor: .positive,
            detail: "\(rate.formatted(.percent.precision(.fractionLength(0)))) of your base paycheck goes to savings or investments before anything becomes spending money."
        ) {
            Button(action: confirm) {
                Label(isConfirmed ? "Transfer confirmed" : "I moved the money", systemImage: isConfirmed ? "checkmark.circle.fill" : "arrow.right.circle.fill")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.glass)
            .controlSize(.large)
            .disabled(isConfirmed)
            .padding(.top, 6)
        }
    }
}

private struct PaydayReservesStep: View {
    var charges: [UpcomingCharge]

    private var total: Double { charges.reduce(0) { $0 + $1.amount } }

    var body: some View {
        ScrollView {
            VStack(spacing: 18) {
                IconBadge(systemImage: "tray.full.fill", color: .caution, size: 92)
                    .padding(.top, 36)
                Text("Now reserve your commitments")
                    .font(.display(.largeTitle))
                    .multilineTextAlignment(.center)
                MoneyText(total, size: 48)
                Text("Held back for bills and recurring charges before your next paycheck.")
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)

                VStack(spacing: 0) {
                    if charges.isEmpty {
                        Text("No recurring charges are due before payday.")
                            .foregroundStyle(.secondary)
                            .padding()
                    }
                    ForEach(charges) { charge in
                        HStack(spacing: 12) {
                            IconBadge(systemImage: charge.systemImage, color: .caution, size: 34)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(charge.name).font(.subheadline.weight(.semibold))
                                Text(charge.date.formatted(.dateTime.weekday(.abbreviated).month().day()))
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Text(charge.amount.currency).monospacedDigit()
                        }
                        .padding(.vertical, 10)
                        if charge.id != charges.last?.id { Divider().overlay(Color.hairline).padding(.leading, 46) }
                    }
                }
                .card(padding: 14)
            }
            .padding(.horizontal, 24)
        }
    }
}

private struct PaydaySpendingRoomStep: View {
    var amount: Double
    var nextPayday: Date

    var body: some View {
        PaydayStepLayout(
            systemImage: "checkmark.seal.fill",
            color: amount < 0 ? .negative : .positive,
            title: "Your spending room",
            amount: amount,
            amountColor: amount < 0 ? .negative : nil,
            detail: "Available until your next payday on \(nextPayday.formatted(.dateTime.month().day())). Savings, cards, bills, and your buffer are already protected.",
            celebrates: true
        ) { EmptyView() }
    }
}

private struct PaydayFooter: View {
    var step: Int
    var canContinue: Bool
    var action: () -> Void

    var body: some View {
        VStack(spacing: 8) {
            Button(action: action) {
                Text(step == 3 ? "Finish" : "Continue")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.glassProminent)
            .foregroundStyle(.white)
            .controlSize(.large)
            .disabled(!canContinue)
            if step == 1 && !canContinue {
                Text("Confirm the transfer above to continue.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}
