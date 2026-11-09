import SwiftUI
import SwiftData

@main struct BudgyApp: App {
    @Environment(\.scenePhase) private var scenePhase
    @State private var sync = SyncService()
    @State private var lock = BiometricLock()

    let container: ModelContainer

    init() {
        do {
            container = try ModelContainer(for: Schema(BudgySchema.models))
        } catch {
            fatalError("Could not open Budgy's database: \(error)")
        }
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(sync)
                .environment(lock)
                .task {
                    let context = container.mainContext
                    SampleData.seedIfNeeded(context: context)
                    SampleData.ensureDefaultCategories(context: context)
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
