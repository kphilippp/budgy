import SwiftUI
import SwiftData

/// Light/dark preference. Dark is the default.
enum AppAppearance: String, CaseIterable, Identifiable {
    case dark, light, system
    var id: String { rawValue }

    var title: String {
        switch self {
        case .dark: "Dark"
        case .light: "Light"
        case .system: "System"
        }
    }

    var colorScheme: ColorScheme? {
        switch self {
        case .dark: .dark
        case .light: .light
        case .system: nil
        }
    }
}

enum AppTab: String, Hashable {
    case home, budget, sort, goals, accounts
}

/// Lets any screen switch tabs (e.g. Home's "to sort" badge opens the Sort tab).
@Observable
final class AppNavigation {
    var selectedTab: AppTab = .home
}

struct RootView: View {
    @Environment(BiometricLock.self) private var lock
    @Environment(AccountStore.self) private var accounts
    @AppStorage(SettingsKeys.appearance) private var appearance: AppAppearance = .dark
    @AppStorage(SettingsKeys.themeColor) private var theme: AppTheme = .teal
    @Query(filter: #Predicate<Transaction> { $0.needsCategoryReview }) private var unsorted: [Transaction]
    @State private var navigation = AppNavigation()

    var body: some View {
        ZStack {
            if !accounts.hasCompletedOnboarding {
                OnboardingView()
                    .transition(.opacity)
            } else {
            TabView(selection: $navigation.selectedTab) {
                Tab("Today", systemImage: "sun.horizon", value: .home) {
                    HomeView()
                }
                Tab("Budget", systemImage: "chart.pie", value: .budget) {
                    BudgetView()
                }
                Tab("Sort", systemImage: "square.stack", value: .sort) {
                    SortView()
                }
                .badge(unsorted.count)
                Tab("Goals", systemImage: "mountain.2", value: .goals) {
                    GoalsView()
                }
                Tab("Accounts", systemImage: "building.columns", value: AppTab.accounts) {
                    AccountsView()
                }
            }
            .tabBarMinimizeBehavior(.onScrollDown)
            .environment(navigation)
            }

            if lock.isEnabled && !lock.isUnlocked {
                LockScreen()
                    .transition(.opacity)
            }
        }
        .animation(Motion.gentle, value: lock.isUnlocked)
        .animation(Motion.gentle, value: accounts.hasCompletedOnboarding)
        // Mineral ink instead of pure black/white; `.secondary` and `.tertiary` derive from it.
        .foregroundStyle(.ink)
        .tint(theme.color)
        .environment(\.themeColor, theme.color)
        .preferredColorScheme(appearance.colorScheme)
        #if DEBUG
        // `-BudgyTab budget` (any AppTab) opens that tab, for screenshots and design review.
        .onAppear {
            if let raw = UserDefaults.standard.string(forKey: "BudgyTab"), let tab = AppTab(rawValue: raw) {
                navigation.selectedTab = tab
            }
        }
        #endif
    }
}

/// Covers the app until Face ID succeeds.
private struct LockScreen: View {
    @Environment(BiometricLock.self) private var lock
    @Environment(\.themeColor) private var themeColor

    var body: some View {
        VStack(spacing: 18) {
            Spacer()
            IconBadge(systemImage: "lock.fill", color: themeColor, size: 76)
            Text("Budgy")
                .font(.display(.largeTitle))
            Text("Locked to keep your money private.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Spacer()
            Button {
                Task { await lock.unlock() }
            } label: {
                Label("Unlock with Face ID", systemImage: "faceid")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.glassProminent)
            .foregroundStyle(.white)
            .controlSize(.large)
            .padding(.horizontal, 24)
            .padding(.bottom, 32)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background { BudgyBackground() }
    }
}

/// Adds the Advisor (sparkles) and Settings buttons to a screen's navigation bar.
struct BudgyToolbar: ViewModifier {
    @State private var showAdvisor = false
    @State private var showSettings = false

    func body(content: Content) -> some View {
        content
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Ask Budgy", systemImage: "sparkles") { showAdvisor = true }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Settings", systemImage: "gearshape") { showSettings = true }
                }
            }
            .sheet(isPresented: $showAdvisor) {
                AdvisorView()
            }
            .sheet(isPresented: $showSettings) {
                SettingsView()
            }
    }
}

extension View {
    func budgyToolbar() -> some View { modifier(BudgyToolbar()) }
}

/// Builds a `FinanceEngine` from live queries so screens update automatically.
struct EngineReader<Content: View>: View {
    @Query private var accounts: [Account]
    @Query private var transactions: [Transaction]
    @Query(sort: \Category.sortOrder) private var categories: [Category]
    @Query private var recurring: [RecurringItem]
    @Query(sort: \Goal.sortOrder) private var goals: [Goal]
    @Query private var schedules: [PaySchedule]

    private let content: (FinanceEngine) -> Content

    init(@ViewBuilder content: @escaping (FinanceEngine) -> Content) {
        self.content = content
    }

    var body: some View {
        content(FinanceEngine(
            accounts: accounts, transactions: transactions, categories: categories,
            recurring: recurring, goals: goals, schedule: schedules.first
        ))
    }
}
