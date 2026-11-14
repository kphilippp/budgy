import SwiftUI
import SwiftData
import UIKit

@main struct BudgyApp: App {
    @Environment(\.scenePhase) private var scenePhase
    @State private var sync = SyncService()
    @State private var lock = BiometricLock()
    @State private var accounts = AccountStore()

    let container: ModelContainer

    init() {
        do {
            container = try ModelContainer(for: Schema(BudgySchema.models))
        } catch {
            fatalError("Could not open Budgy's database: \(error)")
        }
        Self.configureNavigationTitles()
    }

    /// Navigation titles in New York, matching Budgy's serif display type and mineral ink.
    private static func configureNavigationTitles() {
        let ink = UIColor { $0.userInterfaceStyle == .dark ? UIColor(hex: 0xE6EEEA) : UIColor(hex: 0x13201C) }
        func serif(_ style: UIFont.TextStyle, weight: UIFont.Weight) -> UIFont {
            let base = UIFont.preferredFont(forTextStyle: style).fontDescriptor
            let descriptor = (base.withDesign(.serif) ?? base)
                .addingAttributes([.traits: [UIFontDescriptor.TraitKey.weight: weight]])
            return UIFont(descriptor: descriptor, size: 0)
        }
        let bar = UINavigationBar.appearance()
        bar.largeTitleTextAttributes = [.font: serif(.largeTitle, weight: .semibold), .foregroundColor: ink]
        bar.titleTextAttributes = [.font: serif(.headline, weight: .semibold), .foregroundColor: ink]
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(sync)
                .environment(lock)
                .environment(accounts)
                .task {
                    let context = container.mainContext
                    SampleData.ensureDefaultCategories(context: context)
                    #if DEBUG
                    // `-BudgyDemo YES` skips onboarding with the test account and Demo Bank (design review, screenshots).
                    if UserDefaults.standard.bool(forKey: "BudgyDemo") && !accounts.hasCompletedOnboarding {
                        accounts.signInWithTestAccount()
                        await sync.connectDemoBank(context: context)
                        SyncService.performHousekeeping(context: context)
                        accounts.completeOnboarding()
                    }
                    #endif
                    await lock.unlock()
                    await sync.sync(context: context)
                }
        }
        .modelContainer(container)
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .background:
                lock.lockIfNeeded()
            case .active:
                Task {
                    if !lock.isUnlocked { await lock.unlock() }
                    await sync.sync(context: container.mainContext)
                }
            default:
                break
            }
        }
    }
}
