import SwiftUI
import SwiftData

struct SavingsFormula {
    var checkingCash: Double
    var creditCards: Double
    var upcomingBills: Double
    var plannedSavings: Double
    var checkingBuffer: Double
    var expectedBasePay: Double = 0

    var safeToSpend: Double {
        checkingCash + expectedBasePay - creditCards - upcomingBills - plannedSavings - checkingBuffer
    }
}

struct SavingsCalculationTable: View {
    var formula: SavingsFormula
    var revealedRowCount: Int = .max

    private struct Row: Identifiable {
        var id: String
        var title: LocalizedStringResource
        var amount: Double
        var isSubtraction: Bool
    }

    private var rows: [Row] {
        var result = [
            Row(id: "cash", title: "Checking accounts", amount: formula.checkingCash, isSubtraction: false),
            Row(id: "cards", title: "Credit-card balances", amount: formula.creditCards, isSubtraction: true),
            Row(id: "bills", title: "Bills before the target date", amount: formula.upcomingBills, isSubtraction: true),
            Row(id: "savings", title: "Savings and investments", amount: formula.plannedSavings, isSubtraction: true),
            Row(id: "buffer", title: "Protected checking buffer", amount: formula.checkingBuffer, isSubtraction: true)
        ]
        if formula.expectedBasePay > 0 {
            result.append(Row(id: "income", title: "Expected base pay", amount: formula.expectedBasePay, isSubtraction: false))
        }
        return result
    }

    var body: some View {
        VStack(spacing: 10) {
            ForEach(Array(rows.prefix(revealedRowCount))) { row in
                HStack {
                    Text(row.title)
                    Spacer()
                    Text(row.amount, format: .currency(code: "USD").precision(.fractionLength(0)))
                        .monospacedDigit()
                        .foregroundStyle(row.isSubtraction ? .secondary : .primary)
                        .overlay(alignment: .leading) {
                            if row.isSubtraction {
                                Text("−")
                                    .offset(x: -10)
                            }
                        }
                }
                .font(.subheadline)
                .transition(.move(edge: .top).combined(with: .opacity))
            }

            if revealedRowCount >= rows.count {
                Divider().overlay(Color.hairline)
                HStack {
                    Text("Safe to Spend")
                        .font(.headline)
                    Spacer()
                    Text(formula.safeToSpend, format: .currency(code: "USD").precision(.fractionLength(0)))
                        .font(.headline.monospacedDigit())
                        .foregroundStyle(formula.safeToSpend < 0 ? .clay : .moss)
                        .contentTransition(.numericText(value: formula.safeToSpend))
                }
                .transition(.scale(scale: 0.96).combined(with: .opacity))
            }
        }
        .accessibilityElement(children: .contain)
    }
}

struct SavingsEducationDemo: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Binding private var savingsRate: Double
    @State private var revealedRowCount = 0

    var compact = false

    private let basePaycheck = 2_400.0

    init(savingsRate: Binding<Double> = .constant(0.33), compact: Bool = false) {
        self._savingsRate = savingsRate
        self.compact = compact
    }

    private var savingsPercent: Double { savingsRate * 100 }

    private var savingsPercentBinding: Binding<Double> {
        Binding(
            get: { savingsRate * 100 },
            set: { savingsRate = $0 / 100 }
        )
    }

    private var formula: SavingsFormula {
        SavingsFormula(
            checkingCash: 8_625,
            creditCards: 4_000,
            upcomingBills: 900,
            plannedSavings: basePaycheck * savingsPercent / 100,
            checkingBuffer: 500
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: compact ? 14 : 20) {
            SavingsSplitHeader(savingsPercent: savingsPercent)

            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Save from every base paycheck")
                        .font(.subheadline.weight(.semibold))
                    Spacer()
                    Text(savingsPercent / 100, format: .percent.precision(.fractionLength(0)))
                        .font(.headline.monospacedDigit())
                        .foregroundStyle(.moss)
                }
                Slider(value: savingsPercentBinding, in: 10...60, step: 1)
                    .tint(.moss)
                    .accessibilityLabel("Paycheck savings percentage")
                Text("Budgy protects \(basePaycheck * savingsPercent / 100, format: .currency(code: "USD").precision(.fractionLength(0))) from a \(basePaycheck, format: .currency(code: "USD").precision(.fractionLength(0))) base paycheck.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            SavingsCalculationTable(formula: formula, revealedRowCount: revealedRowCount)

            Text("Savings and investments are reserved first. Only the remainder becomes Safe to Spend.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .card()
        .task { await revealFormula() }
        .onChange(of: savingsPercent) { _, _ in
            withAnimation(Motion.quick) {
                revealedRowCount = 5
            }
        }
    }

    private func revealFormula() async {
        revealedRowCount = 0
        let delays = reduceMotion ? [0, 0, 0, 0, 0] : [520, 420, 300, 190, 120]
        for (index, delay) in delays.enumerated() {
            try? await Task.sleep(for: .milliseconds(delay))
            guard !Task.isCancelled else { return }
            withAnimation(Motion.animation(index < 2 ? Motion.gentle : Motion.standard, reduceMotion: reduceMotion)) {
                revealedRowCount = index + 1
            }
        }
    }
}

private struct SavingsSplitHeader: View {
    var savingsPercent: Double

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Pay yourself first", systemImage: "arrow.down.heart.fill")
                .font(.headline)
                .foregroundStyle(.moss)
            GeometryReader { proxy in
                HStack(spacing: 3) {
                    Capsule()
                        .fill(Color.positive)
                        .frame(width: max(proxy.size.width * savingsPercent / 100, 8))
                    Capsule()
                        .fill(Color.secondary.opacity(0.18))
                }
            }
            .frame(height: 12)
            .animation(Motion.gentle, value: savingsPercent)
        }
    }
}

struct SavingsEducationScreen: View {
    @Environment(\.modelContext) private var context
    @Query private var schedules: [PaySchedule]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("How Budgy Helps You Save")
                        .font(.largeTitle.weight(.bold))
                    Text("Choose how aggressively to save. Budgy protects that money, your bills, card payoff, and a checking buffer before showing what is safe to spend.")
                        .foregroundStyle(.secondary)
                }
                if let schedule = schedules.first {
                    @Bindable var schedule = schedule
                    SavingsEducationDemo(savingsRate: $schedule.savingsRate)
                } else {
                    SavingsEducationDemo()
                }
            }
            .padding()
        }
        .budgyCanvas(mist: false)
        .navigationTitle("Saving Plan")
        .navigationBarTitleDisplayMode(.inline)
        .onDisappear {
            try? context.save()
            SyncService.performHousekeeping(context: context)
        }
    }
}
