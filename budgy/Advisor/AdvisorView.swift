import SwiftUI
import SwiftData
import FoundationModels
import Observation

struct ChatMessage: Identifiable, Equatable {
    enum Role { case user, assistant, error }
    let id = UUID()
    var role: Role
    var text: String
}

/// Runs the conversation with Apple's foundation model, giving it tools over your data.
@Observable
final class AdvisorService {
    var messages: [ChatMessage] = []
    var isResponding = false
    var plan: PaycheckPlan?

    private var session: LanguageModelSession?
    private var finance: FinanceContext?

    static var prefersPrivateCloudCompute: Bool { UserDefaults.standard.bool(forKey: SettingsKeys.usePrivateCloudCompute) }

    enum Availability: Equatable {
        case available(usingPCC: Bool)
        case unavailable(String)
    }

    var availability: Availability {
        if Self.prefersPrivateCloudCompute, PrivateCloudComputeLanguageModel().isAvailable {
            return .available(usingPCC: true)
        }
        switch SystemLanguageModel.default.availability {
        case .available:
            return .available(usingPCC: false)
        case .unavailable(.deviceNotEligible):
            return .unavailable("This iPhone doesn't support Apple Intelligence, which the Advisor needs.")
        case .unavailable(.appleIntelligenceNotEnabled):
            return .unavailable("Turn on Apple Intelligence in Settings to use the Advisor.")
        case .unavailable(.modelNotReady):
            return .unavailable("Apple Intelligence is still downloading. Try again in a little while.")
        case .unavailable:
            return .unavailable("The Advisor isn't available right now.")
        }
    }

    func prepare(with finance: FinanceContext) {
        self.finance = finance
        session = makeSession(finance)
    }

    private func makeSession(_ finance: FinanceContext) -> LanguageModelSession {
        let tools: [any Tool] = [
            OverviewTool(finance: finance), SpendingTool(finance: finance), GoalsTool(finance: finance),
            RecurringTool(finance: finance), AffordabilityTool(finance: finance), RetirementTool(finance: finance)
        ]
        let instructions = """
        You are Budgy, a friendly, encouraging personal finance advisor inside the user's budgeting app. \
        Use the tools to look up real numbers before answering; never invent figures. \
        Keep answers short (2–5 sentences or a brief list), specific, and in dollars. \
        Budgy budgets on a conservative base paycheck; overtime is extra. Safe to Spend already sets aside bills, \
        subscriptions, Roth IRA deposits, credit card balances, and goal contributions. \
        Money moves are suggestions only; the app never moves money. You are not a licensed financial advisor, \
        so for taxes or investments suggest checking with a professional when it matters.
        \(finance.briefing)
        """
        if Self.prefersPrivateCloudCompute, PrivateCloudComputeLanguageModel().isAvailable {
            return LanguageModelSession(model: PrivateCloudComputeLanguageModel(), tools: tools, instructions: instructions)
        }
        return LanguageModelSession(model: SystemLanguageModel.default, tools: tools, instructions: instructions)
    }

    func send(_ text: String) async {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let session else { return }
        messages.append(ChatMessage(role: .user, text: trimmed))
        isResponding = true
        defer { isResponding = false }
        do {
            let response = try await session.respond(to: trimmed)
            messages.append(ChatMessage(role: .assistant, text: response.content))
        } catch LanguageModelError.contextSizeExceeded {
            // The on-device model has a small context window; start fresh and retry once.
            if let finance { self.session = makeSession(finance) }
            if let fresh = self.session, let retry = try? await fresh.respond(to: trimmed) {
                messages.append(ChatMessage(role: .assistant, text: retry.content))
            } else {
                messages.append(ChatMessage(role: .error, text: "That conversation got too long. I started a new one. Try asking again."))
            }
        } catch {
            messages.append(ChatMessage(role: .error, text: "Sorry, I couldn't answer that. \(error.localizedDescription)"))
        }
    }

    /// Asks the model for a structured per-paycheck plan across your goals.
    func planPaycheck() async {
        guard let finance, !finance.goals.isEmpty else {
            messages.append(ChatMessage(role: .error, text: "Create a goal first, then I can plan your paycheck around it."))
            return
        }
        isResponding = true
        defer { isResponding = false }
        messages.append(ChatMessage(role: .user, text: "Plan how to split my next paycheck across my goals."))
        let goalList = finance.goals.map { goal in
            "\(goal.name): \(finance.money(goal.target - goal.saved)) remaining, currently \(finance.money(goal.perPaycheck)) per paycheck" +
                (goal.neededPerPaycheck.map { ", needs \(finance.money($0)) per paycheck for its deadline" } ?? "")
        }.joined(separator: "\n")
        let leftover = finance.safeToSpendUntilPayday
        let prompt = """
        Create a per-paycheck savings plan for these goals:
        \(goalList)
        Base paycheck: \(finance.money(finance.basePaycheck)). Current Safe to Spend (after existing goal contributions): \(finance.money(leftover)).
        Prioritize goals with deadlines, keep an emergency fund growing, and keep total goal contributions realistic so Safe to Spend stays positive.
        """
        do {
            let planSession = LanguageModelSession(model: SystemLanguageModel.default, instructions: "You are a careful budgeting assistant. Only use the goal names given.")
            let response = try await planSession.respond(to: prompt, generating: PaycheckPlan.self)
            plan = response.content
            messages.append(ChatMessage(role: .assistant, text: response.content.summary))
        } catch {
            messages.append(ChatMessage(role: .error, text: "I couldn't build a plan right now. \(error.localizedDescription)"))
        }
    }
}

// MARK: - View

struct AdvisorView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var context
    @AppStorage("rothAnnualLimit") private var rothLimit: Double = 7_500
    @State private var advisor = AdvisorService()
    @State private var draft = ""
    @FocusState private var isInputFocused: Bool

    private let suggestions = [
        "Can I afford a $400 concert next month?",
        "Where did I overspend this month?",
        "Am I on track to max my Roth IRA?",
        "Which subscriptions should I cut?"
    ]

    var body: some View {
        NavigationStack {
            Group {
                switch advisor.availability {
                case .available(let usingPCC):
                    chat(usingPCC: usingPCC)
                case .unavailable(let message):
                    ContentUnavailableView("Advisor Unavailable", systemImage: "sparkles", description: Text(message))
                }
            }
            .navigationTitle("Ask Budgy")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done", systemImage: "checkmark") { dismiss() } }
            }
        }
        .task {
            let engine = FinanceEngine.fetch(from: context)
            advisor.prepare(with: engine.advisorContext(rothLimit: rothLimit))
        }
    }

    private func chat(usingPCC: Bool) -> some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    if advisor.messages.isEmpty {
                        welcome(usingPCC: usingPCC)
                    }
                    ForEach(advisor.messages) { message in
                        MessageBubble(message: message).id(message.id)
                    }
                    if let plan = advisor.plan {
                        PlanCard(plan: plan) { advisor.plan = nil }
                    }
                    if advisor.isResponding {
                        HStack(spacing: 8) {
                            ProgressView()
                            Text("Thinking…").font(.subheadline).foregroundStyle(.secondary)
                        }
                        .id("typing")
                    }
                }
                .padding()
            }
            .scrollDismissesKeyboard(.interactively)
            .onChange(of: advisor.messages) {
                withAnimation { proxy.scrollTo(advisor.messages.last?.id, anchor: .bottom) }
            }
            .safeAreaInset(edge: .bottom) { inputBar }
        }
    }

    private func welcome(usingPCC: Bool) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            Image(systemName: "sparkles")
                .font(.system(size: 36, weight: .semibold))
                .foregroundStyle(.tint)
            Text("Hi! I know your accounts, budget, goals, and subscriptions. What would you like to figure out?")
                .font(.title3.weight(.medium))
            Text(usingPCC ? "Running on Apple Private Cloud Compute." : "Running privately on your iPhone.")
                .font(.caption)
                .foregroundStyle(.secondary)

            Button {
                Task { await advisor.planPaycheck() }
            } label: {
                Label("Plan my paycheck", systemImage: "wand.and.stars").frame(maxWidth: .infinity)
            }
            .buttonStyle(.glassProminent)
            .controlSize(.large)

            ForEach(suggestions, id: \.self) { suggestion in
                Button {
                    Task { await advisor.send(suggestion) }
                } label: {
                    Text(suggestion)
                        .font(.subheadline)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.glass)
            }
        }
        .padding(.bottom, 8)
    }

    private var inputBar: some View {
        HStack(spacing: 10) {
            TextField("Ask about your money…", text: $draft, axis: .vertical)
                .lineLimit(1...4)
                .focused($isInputFocused)
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .glassEffect(.regular, in: .rect(cornerRadius: 22))
                .onSubmit(send)
            Button("Send", systemImage: "arrow.up", action: send)
                .labelStyle(.iconOnly)
                .font(.headline)
                .buttonStyle(.glassProminent)
                .buttonBorderShape(.circle)
                .disabled(draft.trimmingCharacters(in: .whitespaces).isEmpty || advisor.isResponding)
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
    }

    private func send() {
        let text = draft
        draft = ""
        Task { await advisor.send(text) }
    }
}

private struct MessageBubble: View {
    @Environment(\.themeColor) private var themeColor
    var message: ChatMessage

    var body: some View {
        HStack {
            if message.role == .user { Spacer(minLength: 40) }
            Text(LocalizedStringKey(message.text))
                .font(.body)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .foregroundStyle(message.role == .user ? .white : (message.role == .error ? .red : .primary))
                .background {
                    RoundedRectangle(cornerRadius: 20, style: .continuous)
                        .fill(message.role == .user ? AnyShapeStyle(themeColor.gradient) : AnyShapeStyle(.background.secondary))
                }
                .textSelection(.enabled)
            if message.role != .user { Spacer(minLength: 40) }
        }
    }
}

/// Shows a structured plan with a one-tap Apply that updates your goals.
private struct PlanCard: View {
    @Environment(\.modelContext) private var context
    @Query private var goals: [Goal]
    var plan: PaycheckPlan
    var onApplied: () -> Void
    @State private var applied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Suggested plan", systemImage: "wand.and.stars").font(.headline)
            ForEach(Array(plan.allocations.enumerated()), id: \.offset) { _, allocation in
                VStack(alignment: .leading, spacing: 2) {
                    HStack {
                        Text(allocation.goalName).font(.subheadline.weight(.semibold))
                        Spacer()
                        Text("\(Double(allocation.amountPerPaycheck).currencyWhole)/paycheck").font(.subheadline.monospacedDigit())
                    }
                    Text(allocation.reason).font(.caption).foregroundStyle(.secondary)
                }
            }
            Button(applied ? "Applied ✓" : "Apply to My Goals") { apply() }
                .buttonStyle(.glassProminent)
                .disabled(applied)
                .frame(maxWidth: .infinity)
        }
        .card()
    }

    private func apply() {
        for allocation in plan.allocations {
            if let goal = goals.first(where: { $0.name.localizedCaseInsensitiveCompare(allocation.goalName) == .orderedSame }) {
                goal.contributionPerPaycheck = Double(allocation.amountPerPaycheck)
            }
        }
        try? context.save()
        SyncService.performHousekeeping(context: context)
        applied = true
    }
}
