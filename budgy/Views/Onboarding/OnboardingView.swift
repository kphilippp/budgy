import SwiftUI
import SwiftData

/// First-run setup: welcome → account → connect bank → budget month → saving plan → preferences → done.
/// A Testing menu in the bottom-right corner skips straight in.
struct OnboardingView: View {
    @Environment(AccountStore.self) private var accounts
    @Environment(SyncService.self) private var sync
    @Environment(\.modelContext) private var context
    @Environment(\.themeColor) private var themeColor

    enum Step: Int, CaseIterable {
        case welcome, account, bank, budget, savings, preferences, done
    }

    @State private var step: Step = .welcome
    @State private var accountMode: AccountForm.Mode = .signUp
    @State private var isWorking = false

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            VStack(spacing: 0) {
                if step != .welcome {
                    header
                }
                Group {
                    switch step {
                    case .welcome:
                        WelcomeStep { mode in
                            accountMode = mode
                            advance(to: .account)
                        }
                    case .account:
                        AccountForm(mode: $accountMode) { signedInWithExistingData in
                            advance(to: signedInWithExistingData ? .done : .bank)
                        }
                    case .bank:
                        BankStep { advance(to: .budget) }
                    case .budget:
                        BudgetMonthStep { advance(to: .savings) }
                    case .savings:
                        SavingsPlanStep { advance(to: .preferences) }
                    case .preferences:
                        PreferencesStep { advance(to: .done) }
                    case .done:
                        DoneStep { finish() }
                    }
                }
                .transition(.asymmetric(insertion: .move(edge: .trailing).combined(with: .opacity), removal: .move(edge: .leading).combined(with: .opacity)))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }

            TestingMenu(isWorking: isWorking) {
                finish()
            } useTestAccount: {
                Task { await useTestAccount() }
            }
            .padding(.trailing, 20)
            .padding(.bottom, 12)
        }
        .budgyCanvas()
        .dismissesKeyboardOnTap()
    }

    private var header: some View {
        HStack {
            Button("Back", systemImage: "chevron.left") {
                if let previous = Step(rawValue: step.rawValue - 1) { advance(to: previous) }
            }
            .labelStyle(.iconOnly)
            .buttonStyle(.glass)
            .buttonBorderShape(.circle)
            .opacity(step == .done ? 0 : 1)
            Spacer()
            HStack(spacing: 6) {
                ForEach(Step.allCases.dropFirst(), id: \.self) { item in
                    Capsule()
                        .fill(item.rawValue <= step.rawValue ? AnyShapeStyle(themeColor) : AnyShapeStyle(.quaternary))
                        .frame(width: item == step ? 22 : 8, height: 8)
                }
            }
            .animation(Motion.standard, value: step)
            .accessibilityElement()
            .accessibilityLabel("Step \(step.rawValue) of \(Step.allCases.count - 1)")
            Spacer()
            Color.clear.frame(width: 44, height: 44)
        }
        .padding(.horizontal)
        .padding(.top, 8)
    }

    private func advance(to next: Step) {
        withAnimation(Motion.standard) { step = next }
    }

    private func finish() {
        SampleData.ensureDefaultCategories(context: context)
        SyncService.performHousekeeping(context: context)
        withAnimation(Motion.gentle) { accounts.completeOnboarding() }
    }

    private func useTestAccount() async {
        isWorking = true
        accounts.signInWithTestAccount()
        await sync.connectDemoBank(context: context)
        isWorking = false
        finish()
    }
}

// MARK: - Testing shortcut

private struct TestingMenu: View {
    var isWorking: Bool
    var skip: () -> Void
    var useTestAccount: () -> Void

    var body: some View {
        Menu {
            Button("Sign In with Test Account", systemImage: "person.crop.circle.badge.checkmark", action: useTestAccount)
            Button("Skip Onboarding", systemImage: "forward.end", action: skip)
        } label: {
            if isWorking {
                ProgressView().frame(width: 20, height: 20)
            } else {
                Label("Testing", systemImage: "hammer.fill")
                    .font(.caption.weight(.semibold))
            }
        }
        .buttonStyle(.glass)
        .disabled(isWorking)
        .accessibilityHint("Skip setup or sign in with a test account that uses the Demo Bank")
    }
}

// MARK: - Steps

private struct StepLayout<Content: View, Footer: View>: View {
    var systemImage: String
    var title: String
    var subtitle: String
    @ViewBuilder var content: Content
    @ViewBuilder var footer: Footer
    @Environment(\.themeColor) private var themeColor

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    IconBadge(systemImage: systemImage, color: themeColor, size: 64)
                        .padding(.top, 24)
                    VStack(alignment: .leading, spacing: 8) {
                        Text(title).font(.display(.largeTitle))
                        Text(subtitle).font(.body).foregroundStyle(.secondary)
                    }
                    content
                }
                .padding(.horizontal, 24)
                .padding(.bottom, 24)
            }
            .scrollDismissesKeyboard(.interactively)
            footer
                .padding(.horizontal, 24)
                .padding(.bottom, 64) // room for the Testing button
        }
    }
}

private struct PrimaryButton: View {
    var title: String
    var isEnabled = true
    var isWorking = false
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            Group {
                if isWorking { ProgressView() } else { Text(title).font(.headline) }
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 6)
        }
        .buttonStyle(.glassProminent)
        .foregroundStyle(.white)
        .controlSize(.large)
        .disabled(!isEnabled || isWorking)
    }
}

private struct WelcomeStep: View {
    @Environment(\.themeColor) private var themeColor
    var onContinue: (AccountForm.Mode) -> Void

    var body: some View {
        VStack(spacing: 28) {
            Spacer()
            Image("IconPreview-Teal")
                .resizable()
                .frame(width: 112, height: 112)
                .clipShape(.rect(cornerRadius: 26, style: .continuous))
                .shadow(color: .black.opacity(0.25), radius: 16, y: 8)
                .accessibilityHidden(true)
            VStack(spacing: 10) {
                Text("Budgy").scaledFont(size: 52, weight: .semibold, design: .serif)
                Text("Know exactly what you can spend,\nevery day of the month.")
                    .font(.title3)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
            }
            VStack(alignment: .leading, spacing: 14) {
                feature("calendar", "A monthly budget that starts when your card is paid off")
                feature("chart.pie.fill", "Spending groups, sorted automatically")
                feature("repeat.circle.fill", "Every subscription and bill in one place")
                feature("lock.fill", "Private: your data stays on your iPhone")
            }
            .padding(.horizontal, 8)
            Spacer()
            VStack(spacing: 12) {
                PrimaryButton(title: "Get Started") { onContinue(.signUp) }
                Button("I already have an account") { onContinue(.signIn) }
                    .font(.subheadline.weight(.medium))
            }
            .padding(.bottom, 64)
        }
        .padding(.horizontal, 24)
    }

    private func feature(_ systemImage: String, _ text: String) -> some View {
        HStack(spacing: 14) {
            IconBadge(systemImage: systemImage, color: themeColor, size: 34)
            Text(text)
                .font(.subheadline)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

struct AccountForm: View {
    enum Mode: String, CaseIterable, Identifiable {
        case signUp = "Create Account"
        case signIn = "Sign In"
        var id: String { rawValue }
    }

    @Environment(AccountStore.self) private var accounts
    @Query private var existingAccounts: [Account]
    @Binding var mode: Mode
    /// Called with `true` when signing in to an account that already has data on this iPhone.
    var onDone: (Bool) -> Void

    @State private var name = ""
    @State private var email = ""
    @State private var password = ""
    @State private var errorMessage: String?
    @FocusState private var focused: Field?

    enum Field { case name, email, password }

    private var canSubmit: Bool {
        !email.isEmpty && !password.isEmpty && (mode == .signIn || !name.isEmpty)
    }

    var body: some View {
        StepLayout(
            systemImage: "person.crop.circle.fill",
            title: mode == .signUp ? "Create your account" : "Welcome back",
            subtitle: mode == .signUp ? "Your account keeps Budgy private to you." : "Sign in to pick up where you left off."
        ) {
            Picker("Mode", selection: $mode) {
                ForEach(Mode.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .onChange(of: mode) { errorMessage = nil }

            VStack(spacing: 12) {
                if mode == .signUp {
                    field("Name", text: $name, field: .name)
                        .textContentType(.name)
                }
                field("Email", text: $email, field: .email)
                    .textContentType(.emailAddress)
                    .keyboardType(.emailAddress)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                SecureField("Password", text: $password)
                    .textContentType(mode == .signUp ? .newPassword : .password)
                    .focused($focused, equals: .password)
                    .submitLabel(.go)
                    .onSubmit(submit)
                    .fieldStyle()
            }

            if let errorMessage {
                Label(errorMessage, systemImage: "exclamationmark.circle.fill")
                    .font(.subheadline)
                    .foregroundStyle(.clay)
            }

            Text("Accounts are stored securely on this iPhone for now.")
                .font(.caption)
                .foregroundStyle(.secondary)
        } footer: {
            PrimaryButton(title: mode.rawValue, isEnabled: canSubmit, action: submit)
        }
    }

    private func field(_ title: String, text: Binding<String>, field: Field) -> some View {
        TextField(title, text: text)
            .focused($focused, equals: field)
            .submitLabel(.next)
            .fieldStyle()
    }

    private func submit() {
        guard canSubmit else { return }
        do {
            switch mode {
            case .signUp:
                try accounts.signUp(name: name, email: email, password: password)
                onDone(false)
            case .signIn:
                try accounts.signIn(email: email, password: password)
                onDone(!existingAccounts.isEmpty)
            }
        } catch {
            withAnimation { errorMessage = error.localizedDescription }
        }
    }
}

private struct BankStep: View {
    @Environment(\.themeColor) private var themeColor
    @Environment(SyncService.self) private var sync
    @Environment(\.modelContext) private var context
    @Query private var items: [PlaidItem]
    @State private var showBankConnections = false
    @State private var isConnectingDemo = false
    var onContinue: () -> Void

    var body: some View {
        StepLayout(
            systemImage: "building.columns.fill",
            title: "Connect your bank",
            subtitle: "Link your checking, savings, credit card, and Schwab accounts so Budgy can track spending automatically."
        ) {
            VStack(spacing: 12) {
                option("Connect with Plaid", detail: "Your real banks, through your Budgy relay", systemImage: "link") {
                    showBankConnections = true
                }
                option("Try the Demo Bank", detail: "Realistic sample accounts for testing", systemImage: "testtube.2", isWorking: isConnectingDemo) {
                    Task {
                        isConnectingDemo = true
                        await sync.connectDemoBank(context: context)
                        isConnectingDemo = false
                    }
                }
            }

            if !items.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Connected").font(.subheadline.weight(.semibold))
                    ForEach(items) { item in
                        Label(item.institutionName, systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.moss)
                    }
                }
                .card(padding: 14)
            }
        } footer: {
            VStack(spacing: 10) {
                PrimaryButton(title: items.isEmpty ? "Skip for Now" : "Continue", action: onContinue)
            }
        }
        .sheet(isPresented: $showBankConnections) {
            NavigationStack {
                BankConnectionsView()
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) {
                            Button("Done", systemImage: "checkmark") { showBankConnections = false }
                        }
                    }
            }
        }
    }

    private func option(_ title: String, detail: String, systemImage: String, isWorking: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 14) {
                IconBadge(systemImage: systemImage, color: themeColor, size: 40)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.headline)
                    Text(detail).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if isWorking { ProgressView() } else { Image(systemName: "chevron.right").foregroundStyle(.tertiary) }
            }
            .card(padding: 16)
        }
        .buttonStyle(.pressable)
        .disabled(isWorking)
    }
}

private struct BudgetMonthStep: View {
    @Environment(\.modelContext) private var context
    @Query private var schedules: [PaySchedule]
    var onContinue: () -> Void

    var body: some View {
        EngineReader { engine in
            StepLayout(
                systemImage: "calendar",
                title: "Your budget month",
                subtitle: "Budgy budgets month to month, starting the day you pay your credit card off to $0."
            ) {
                if let schedule = schedules.first {
                    BudgetMonthFields(schedule: schedule, engine: engine)
                } else {
                    ProgressView()
                }
            } footer: {
                PrimaryButton(title: "Continue") {
                    try? context.save()
                    onContinue()
                }
            }
        }
        .onAppear(perform: ensureSchedule)
    }

    /// Bank sync usually creates the pay schedule; make one if it didn't.
    private func ensureSchedule() {
        guard schedules.isEmpty else { return }
        context.insert(PaySchedule(employerName: "Paycheck", frequency: .biweekly, anchorPayDate: .now, estimatedAmount: 0))
        try? context.save()
    }
}

private struct BudgetMonthFields: View {
    @Bindable var schedule: PaySchedule
    var engine: FinanceEngine

    private func ordinal(_ day: Int) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .ordinal
        return formatter.string(from: NSNumber(value: day)) ?? "\(day)"
    }

    var body: some View {
        VStack(spacing: 16) {
            VStack(alignment: .leading, spacing: 12) {
                Text("Starts on").font(.subheadline.weight(.semibold))
                Picker("Starts on", selection: $schedule.budgetCycleDay) {
                    Text(engine.detectedBudgetCycleDay.map { "Auto (the \(ordinal($0)))" } ?? "Auto").tag(0)
                    ForEach(1...31, id: \.self) { Text("The \(ordinal($0))").tag($0) }
                }
                .pickerStyle(.menu)
                Text(engine.detectedBudgetCycleDay != nil
                     ? "Detected from your credit card payments."
                     : "Pick the day you usually pay your card off.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .card()

            VStack(alignment: .leading, spacing: 12) {
                Text("Paychecks").font(.subheadline.weight(.semibold))
                Picker("Paid", selection: Binding(get: { schedule.frequency }, set: { schedule.frequency = $0 })) {
                    ForEach([Frequency.weekly, .biweekly, .semimonthly, .monthly]) { Text($0.displayName).tag($0) }
                }
                if engine.paychecks.count < 2 {
                    LabeledContent("Typical paycheck") {
                        CurrencyField("Amount", value: $schedule.estimatedAmount)
                    }
                    DatePicker("A recent payday", selection: $schedule.anchorPayDate, displayedComponents: .date)
                }
                Divider().overlay(Color.hairline)
                LabeledContent("Monthly income", value: engine.monthlyIncome.currency)
                    .font(.headline)
                Text("\(engine.paychecksPerMonth) × \(engine.basePaycheck.currency) base paycheck. You can change this anytime in Settings → Paycheck.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .card()
        }
    }
}

private struct SavingsPlanStep: View {
    @Query private var schedules: [PaySchedule]
    var onContinue: () -> Void

    var body: some View {
        StepLayout(
            systemImage: "arrow.down.heart.fill",
            title: "Save before you spend",
            subtitle: "Budgy gives every base paycheck a job, protects the money you want to keep, and makes the remainder easy to understand."
        ) {
            if let schedule = schedules.first {
                @Bindable var schedule = schedule
                SavingsEducationDemo(savingsRate: $schedule.savingsRate, compact: true)
            } else {
                SavingsEducationDemo(compact: true)
            }
        } footer: {
            PrimaryButton(title: "Use This Approach", action: onContinue)
        }
    }
}

private struct PreferencesStep: View {
    @Environment(\.modelContext) private var context
    @AppStorage(SettingsKeys.faceIDEnabled) private var faceID = false
    @AppStorage(SettingsKeys.notificationsEnabled) private var notifications = false
    var onContinue: () -> Void

    var body: some View {
        StepLayout(
            systemImage: "slider.horizontal.3",
            title: "A few preferences",
            subtitle: "You can change these anytime in Settings."
        ) {
            VStack(spacing: 0) {
                Toggle(isOn: $faceID) {
                    Label("Require Face ID", systemImage: "faceid")
                }
                .padding(.vertical, 10)
                Divider().overlay(Color.hairline)
                Toggle(isOn: $notifications) {
                    Label("Bill & Payday Reminders", systemImage: "bell.badge.fill")
                }
                .padding(.vertical, 10)
                .onChange(of: notifications) { _, on in
                    Task {
                        if on { notifications = await NotificationService.shared.requestAuthorization() }
                        SyncService.performHousekeeping(context: context)
                    }
                }
            }
            .card(padding: 14)
        } footer: {
            PrimaryButton(title: "Continue", action: onContinue)
        }
    }
}

private struct DoneStep: View {
    @Environment(\.themeColor) private var themeColor
    @Environment(AccountStore.self) private var accounts
    var onFinish: () -> Void

    var body: some View {
        VStack(spacing: 24) {
            Spacer()
            IconBadge(systemImage: "checkmark.seal.fill", color: themeColor, size: 96)
                .symbolEffect(.bounce, options: .nonRepeating)
            VStack(spacing: 8) {
                Text(accounts.currentUser.map { "You're all set, \($0.firstName)!" } ?? "You're all set!")
                    .font(.display(.largeTitle))
                    .multilineTextAlignment(.center)
                Text("Budgy will keep your Safe to Spend up to date as you spend.")
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            Spacer()
            PrimaryButton(title: "Start Budgeting", action: onFinish)
                .padding(.bottom, 64)
        }
        .padding(.horizontal, 24)
    }
}
