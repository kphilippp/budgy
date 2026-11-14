import SwiftUI
import SwiftData
import AuthenticationServices

struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Group {
                    AccountSection()
                    Section {
                        NavigationLink { SavingsEducationScreen() } label: {
                            Label("How Budgy Helps You Save", systemImage: "chart.pie.fill")
                        }
                        NavigationLink { PayScheduleSettings() } label: {
                            Label("Paycheck", systemImage: "dollarsign.circle.fill")
                        }
                        NavigationLink { BankConnectionsView() } label: {
                            Label("Bank Connections", systemImage: "link.circle.fill")
                        }
                    }
                    PreferencesSection()
                    DataSection()
                    Section {
                        LabeledContent("Version", value: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0")
                    } footer: {
                        Text("Budgy keeps your data on this iPhone. Bank data passes through your own relay server; the Advisor runs on Apple's on-device model.")
                    }
                }
                .budgyRows()
            }
            .budgyList()
            .navigationTitle("Settings")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done", systemImage: "checkmark") { dismiss() } }
            }
        }
    }
}

// MARK: - Paycheck

private struct PayScheduleSettings: View {
    @Environment(\.modelContext) private var context
    @Query private var schedules: [PaySchedule]

    var body: some View {
        EngineReader { engine in
            Form {
                Group {
                    if let schedule = schedules.first {
                        PayScheduleForm(schedule: schedule, engine: engine)
                    } else {
                        Section {
                            Button("Set Up My Paycheck") {
                                let schedule = PaySchedule(employerName: "Paycheck", frequency: .biweekly, anchorPayDate: .now, estimatedAmount: 2_000)
                                context.insert(schedule)
                                try? context.save()
                            }
                        } footer: {
                            Text("Once your bank is connected, Budgy detects your paychecks automatically.")
                        }
                    }
                }
                .budgyRows()
            }
            .budgyList()
        }
        .navigationTitle("Paycheck")
    }
}

private struct PayScheduleForm: View {
    @Environment(\.modelContext) private var context
    @Bindable var schedule: PaySchedule
    var engine: FinanceEngine
    @State private var useOverride = false
    @State private var useIncomeOverride = false

    private func ordinal(_ day: Int) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .ordinal
        return formatter.string(from: NSNumber(value: day)) ?? "\(day)"
    }

    var body: some View {
        Section {
            TextField("Employer", text: $schedule.employerName)
            Picker("Paid", selection: Binding(get: { schedule.frequency }, set: { schedule.frequency = $0 })) {
                ForEach([Frequency.weekly, .biweekly, .semimonthly, .monthly]) { Text($0.displayName).tag($0) }
            }
            DatePicker("A recent payday", selection: $schedule.anchorPayDate, displayedComponents: .date)
            LabeledContent("Next payday", value: engine.nextPayday.formatted(.dateTime.weekday(.wide).month().day()))
        }
        .onAppear { useOverride = schedule.baseAmountOverride > 0 }
        .onChange(of: useOverride) { _, on in if !on { schedule.baseAmountOverride = 0 } }
        .onDisappear {
            try? context.save()
            SyncService.performHousekeeping(context: context)
        }

        Section {
            LabeledContent("Typical check") {
                CurrencyField("Amount", value: $schedule.estimatedAmount)
            }
            Toggle("Set base amount manually", isOn: $useOverride.animation())
            if useOverride {
                LabeledContent("Base paycheck") {
                    CurrencyField("Amount", value: $schedule.baseAmountOverride)
                }
            }
            LabeledContent("Budgy budgets on", value: engine.basePaycheck.currency)
        } header: {
            Text("Base Paycheck")
        } footer: {
            Text("Budgy starts with the amount you provide. If a lower paycheck arrives, that becomes your new base; anything above the base is extra pay you can send to a goal.")
        }

        Section {
            Picker("Starts on", selection: $schedule.budgetCycleDay) {
                Text(engine.detectedBudgetCycleDay.map { "Auto (the \(ordinal($0)))" } ?? "Auto").tag(0)
                ForEach(1...31, id: \.self) { Text("The \(ordinal($0))").tag($0) }
            }
            LabeledContent("This budget month") {
                let month = engine.budgetMonth()
                let end = Calendar.current.date(byAdding: .day, value: -1, to: month.end) ?? month.end
                Text("\(month.start.formatted(.dateTime.month(.abbreviated).day())) – \(end.formatted(.dateTime.month(.abbreviated).day()))")
            }
        } header: {
            Text("Budget Month")
        } footer: {
            Text("Your budget month starts the day you pay your credit card off to $0. Auto uses the day your card payments usually go out.")
        }

        Section {
            Toggle("Set monthly income manually", isOn: $useIncomeOverride.animation())
            if useIncomeOverride {
                LabeledContent("Monthly income") {
                    CurrencyField("Amount", value: $schedule.monthlyIncomeOverride)
                }
            }
            LabeledContent("Budgy budgets on", value: engine.monthlyIncome.currency)
        } header: {
            Text("Monthly Income")
        } footer: {
            Text("Estimated as \(engine.paychecksPerMonth) × your base paycheck (\(engine.basePaycheck.currency)) from deposits to your checking account. Months with an extra paycheck count it as bonus money.")
        }
        .onAppear { useIncomeOverride = schedule.monthlyIncomeOverride > 0 }
        .onChange(of: useIncomeOverride) { _, on in if !on { schedule.monthlyIncomeOverride = 0 } }

        Section {
            LabeledContent("Protected checking buffer") {
                CurrencyField("Buffer", value: $schedule.checkingBuffer)
            }
        } header: {
            Text("Safe to Spend")
        } footer: {
            Text("Budgy leaves this amount untouched in checking before showing money as safe to spend.")
        }

        Section {
            TextField("e.g. acme payroll", text: $schedule.matchText)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
        } header: {
            Text("Paycheck deposits contain")
        }

        if !engine.paychecks.isEmpty {
            Section("Recent Paychecks") {
                ForEach(engine.paychecks.prefix(6)) { paycheck in
                    HStack {
                        Text(paycheck.date.formatted(.dateTime.month(.abbreviated).day()))
                        Spacer()
                        Text((-paycheck.amount).currency).monospacedDigit()
                        let extra = -paycheck.amount - engine.basePaycheck
                        if extra > 25 {
                            Text("+\(extra.currencyWhole)")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.moss)
                        }
                    }
                }
            }
        }
    }
}

// MARK: - Bank connections

struct BankConnectionsView: View {
    @Environment(\.modelContext) private var context
    @Environment(SyncService.self) private var sync
    @Environment(\.webAuthenticationSession) private var webAuthenticationSession
    @Query private var items: [PlaidItem]

    @AppStorage(SettingsKeys.serverURL) private var serverURL = ""
    @AppStorage(SettingsKeys.demoBankEnabled) private var demoBankEnabled = false
    @State private var appToken = Keychain.read(SettingsKeys.appToken) ?? ""
    @State private var status: String?
    @State private var isWorking = false

    var body: some View {
        Form {
            Group {
                Section {
                    if demoBankEnabled {
                        Button("Disconnect Demo Bank", systemImage: "xmark.circle", role: .destructive) {
                            sync.disconnectDemoBank(context: context)
                            status = "Demo Bank disconnected."
                        }
                    } else {
                        Button {
                            Task {
                                isWorking = true
                                status = "Connecting to Demo Bank…"
                                await sync.connectDemoBank(context: context)
                                isWorking = false
                                status = sync.lastError.map { "❌ \($0)" } ?? "✅ Connected Wells Fargo, Capital One, and Charles Schwab (demo). Review recurring charges in Budget → Bills & Subscriptions, and sort the rest in the Sort tab."
                            }
                        } label: {
                            Label("Connect Demo Bank", systemImage: "testtube.2")
                        }
                        .disabled(isWorking)
                    }
                } header: {
                    Text("Testing")
                } footer: {
                    Text("Pretends you linked a checking, savings, and credit card account plus Schwab retirement accounts, with 4 months of paychecks, bills, and subscriptions. Uses the same sync, categorizing, and subscription detection as a real bank. Replaces the sample data.")
                }

                Section {
                    TextField("https://budgy-relay.you.workers.dev", text: $serverURL)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    SecureField("App token", text: $appToken)
                        .onChange(of: appToken) { _, value in Keychain.save(value, for: SettingsKeys.appToken) }
                    Button("Test Connection") { Task { await test() } }
                        .disabled(serverURL.isEmpty || appToken.isEmpty || isWorking)
                } header: {
                    Text("Relay Server")
                } footer: {
                    Text("Your Plaid keys live on your own Cloudflare Worker. See Server/README.md in the project for the 10-minute setup.")
                }

                Section {
                    Button {
                        Task { await connect(investments: false) }
                    } label: {
                        Label("Connect a Bank or Card", systemImage: "building.columns")
                    }
                    Button {
                        Task { await connect(investments: true) }
                    } label: {
                        Label("Connect Schwab / Investments", systemImage: "chart.line.uptrend.xyaxis")
                    }
                } footer: {
                    Text("Each connected login is one Plaid \"item\" (about $0.30–0.60/month in production, free on the Trial plan).")
                }
                .disabled(PlaidService.configured == nil || isWorking || demoBankEnabled)

                if let status {
                    Section { Text(status).font(.subheadline) }
                }

                if !items.isEmpty {
                    Section {
                        ForEach(items) { item in
                            VStack(alignment: .leading, spacing: 2) {
                                Text(item.institutionName).font(.headline)
                                if !item.lastError.isEmpty {
                                    Text(item.lastError).font(.caption).foregroundStyle(.clay)
                                } else if let synced = item.lastSynced {
                                    Text("Synced \(synced.formatted(.relative(presentation: .named)))").font(.caption).foregroundStyle(.secondary)
                                } else {
                                    Text(item.isInvestments ? "Investments" : "Waiting for first sync").font(.caption).foregroundStyle(.secondary)
                                }
                            }
                            .swipeActions {
                                Button("Disconnect", role: .destructive) {
                                    Task { await sync.disconnect(item, context: context) }
                                }
                            }
                        }
                        Button {
                            Task { await sync.sync(context: context) }
                        } label: {
                            if sync.isSyncing {
                                HStack { ProgressView(); Text("Syncing…") }
                            } else {
                                Label("Sync Now", systemImage: "arrow.clockwise")
                            }
                        }
                        .disabled(sync.isSyncing)
                    } header: {
                        Text("Connected")
                    } footer: {
                        if let error = sync.lastError {
                            Text(error).foregroundStyle(.clay)
                        } else if let last = sync.lastSynced {
                            Text("Last synced \(last.formatted(.relative(presentation: .named))). Swipe to disconnect, which also stops Plaid billing for it.")
                        }
                    }
                }
            }
            .budgyRows()
        }
        .budgyList()
        .navigationTitle("Bank Connections")
    }

    private func test() async {
        guard let service = PlaidService.configured else {
            status = "Enter an https:// server URL and your app token."
            return
        }
        isWorking = true
        defer { isWorking = false }
        do {
            let health = try await service.health()
            status = health.ok ? "✅ Connected to your relay (\(health.env ?? "sandbox") mode)." : "The server responded but isn't healthy."
        } catch {
            status = "❌ \(error.localizedDescription)"
        }
    }

    private func connect(investments: Bool) async {
        guard let service = PlaidService.configured else { return }
        isWorking = true
        defer { isWorking = false }
        do {
            let session = try await service.createLink(investments: investments)
            guard let url = URL(string: session.hosted_link_url) else { throw PlaidService.ServiceError.server("Plaid didn't return a link URL.") }
            // Plaid's Hosted Link runs in a secure system browser sheet and redirects to budgy:// when done.
            // If you close the sheet yourself, the bank may still have been linked, so check either way.
            do {
                _ = try await webAuthenticationSession.authenticate(using: url, callbackURLScheme: "budgy")
            } catch let error as ASWebAuthenticationSessionError where error.code == .canceledLogin {
                // Fall through and ask Plaid whether the session finished.
            }
            status = "Finishing up…"
            let linked = try await service.completeLink(session)
            if linked.isEmpty {
                status = "No account was connected."
                return
            }
            await sync.registerLinkedItems(linked, context: context)
            status = "✅ Connected \(linked.map(\.institution_name).joined(separator: ", "))."
        } catch {
            status = "❌ \(error.localizedDescription)"
        }
    }
}

// MARK: - Preferences

private struct PreferencesSection: View {
    @Environment(\.modelContext) private var context
    @AppStorage(SettingsKeys.faceIDEnabled) private var faceID = false
    @AppStorage(SettingsKeys.notificationsEnabled) private var notifications = false
    @AppStorage(SettingsKeys.usePrivateCloudCompute) private var usePCC = false
    @AppStorage("rothAnnualLimit") private var rothLimit: Double = 7_500
    @AppStorage(SettingsKeys.appearance) private var appearance: AppAppearance = .dark
    @AppStorage(SettingsKeys.themeColor) private var theme: AppTheme = .blue

    var body: some View {
        Section {
            Picker(selection: $appearance) {
                ForEach(AppAppearance.allCases) { Text($0.title).tag($0) }
            } label: {
                Label("Appearance", systemImage: "circle.lefthalf.filled")
            }
            // Menu pickers cache their tint; rebuild when the theme changes.
            .id(theme)
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Label("Theme Color", systemImage: "paintpalette.fill")
                    Spacer()
                    Text(theme.title).foregroundStyle(.secondary)
                }
                ThemeSwatches(selection: $theme)
            }
            .padding(.vertical, 4)
            NavigationLink {
                AppIconPicker()
            } label: {
                Label("App Icon", systemImage: "app.badge.fill")
            }
        } header: {
            Text("Display")
        }

        Section {
            Toggle(isOn: $faceID) { Label("Require Face ID", systemImage: "faceid") }
            Toggle(isOn: $notifications) { Label("Bill & Payday Reminders", systemImage: "bell.badge.fill") }
                .onChange(of: notifications) { _, on in
                    Task {
                        if on { notifications = await NotificationService.shared.requestAuthorization() }
                        SyncService.performHousekeeping(context: context)
                    }
                }
            LabeledContent {
                TextField("Limit", value: $rothLimit, format: .currency(code: "USD").precision(.fractionLength(0)))
                    .keyboardType(.numberPad)
                    .multilineTextAlignment(.trailing)
            } label: {
                Label("Roth IRA yearly limit", systemImage: "leaf.fill")
            }
        } header: {
            Text("Preferences")
        } footer: {
            Text("The 2026 IRS limit is $7,500 ($8,600 if you're 50 or older).")
        }

        Section {
            Toggle(isOn: $usePCC) { Label("Use Private Cloud Compute", systemImage: "cloud.fill") }
        } header: {
            Text("Advisor")
        } footer: {
            Text("Apple's larger server model with the same privacy guarantees. Requires the Private Cloud Compute entitlement from Apple; Budgy falls back to the on-device model if it's unavailable.")
        }
    }
}

// MARK: - Data

private struct DataSection: View {
    @Environment(\.modelContext) private var context
    @Query(filter: #Predicate<Account> { $0.isSample }) private var sampleAccounts: [Account]
    @State private var confirmErase = false

    var body: some View {
        Section("Data") {
            if !sampleAccounts.isEmpty {
                Button("Remove Sample Data") {
                    SampleData.removeSampleData(context: context)
                    SyncService.performHousekeeping(context: context)
                }
            }
            Button("Erase All Data", role: .destructive) { confirmErase = true }
                .confirmationDialog("Erase everything in Budgy?", isPresented: $confirmErase, titleVisibility: .visible) {
                    Button("Erase All Data", role: .destructive) { eraseAll() }
                } message: {
                    Text("This deletes accounts, transactions, goals, and settings on this iPhone. Bank connections on your relay server are not removed.")
                }
        }
    }

    private func eraseAll() {
        for model in BudgySchema.models {
            try? context.delete(model: model)
        }
        try? context.save()
        SampleData.ensureDefaultCategories(context: context)
        SyncService.performHousekeeping(context: context)
    }
}

// MARK: - Account

private struct AccountSection: View {
    @Environment(AccountStore.self) private var accounts
    @Environment(SyncService.self) private var sync
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @State private var confirmDelete = false

    var body: some View {
        Section {
            if let user = accounts.currentUser {
                HStack(spacing: 14) {
                    // The initial on a pebble of the user's own: same shape every time for the same name.
                    Text(String(user.firstName.prefix(1)).uppercased())
                        .font(.display(.title2))
                        .foregroundStyle(.tint)
                        .frame(width: 52, height: 52)
                        .background(Pebble(seed: user.email.stableHash).fill(.tint.opacity(0.16)))
                    VStack(alignment: .leading, spacing: 2) {
                        Text(user.name).font(.headline)
                        Text(user.email).font(.subheadline).foregroundStyle(.secondary)
                        if user.isTestAccount {
                            Tag("Test account", color: .caution)
                        }
                    }
                }
                .padding(.vertical, 4)
                Button("Sign Out") {
                    dismiss()
                    accounts.signOut()
                }
                Button("Delete Account", role: .destructive) { confirmDelete = true }
                    .confirmationDialog("Delete your Budgy account?", isPresented: $confirmDelete, titleVisibility: .visible) {
                        Button("Delete Account and Data", role: .destructive) {
                            dismiss()
                            accounts.deleteAccount(context: context, sync: sync)
                        }
                    } message: {
                        Text("This removes the account and all of Budgy's data on this iPhone. Banks connected through your relay stay connected there.")
                    }
            } else {
                Button("Sign In or Create Account") {
                    dismiss()
                    accounts.signOut()
                }
            }
        } header: {
            Text("Account")
        }
    }
}
