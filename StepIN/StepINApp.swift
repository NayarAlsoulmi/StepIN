//
//  StepINApp.swift
//  StepIN
//
//  App entry point. Sets up the SwiftData container and shared app state.
//

import SwiftUI
import SwiftData

@main
struct StepINApp: App {
    @State private var appState: AppState
    private let modelContainer: ModelContainer

    init() {
        let schema = Schema(StepINSchema.models)
        do {
            let container = try ModelContainer(for: schema)
            self.modelContainer = container
            // A local profile exists if one has already been created.
            let hasProfile = (try? container.mainContext.fetch(FetchDescriptor<UserProfile>()))?.isEmpty == false
            self._appState = State(initialValue: AppState(hasProfile: hasProfile))
        } catch {
            // The persistent store couldn't be opened (schema drift during development is the
            // most common cause). In debug builds, wipe the store and start fresh so the
            // simulator never shows a black screen. In release builds, crash loudly so the
            // problem is caught before shipping.
            #if DEBUG
            Self.wipePersistentStore()
            guard let container = try? ModelContainer(for: schema) else {
                fatalError("StepIN: cannot create model container after store reset: \(error)")
            }
            self.modelContainer = container
            self._appState = State(initialValue: AppState(hasProfile: false))
            #else
            fatalError("StepIN: cannot create model container: \(error)")
            #endif
        }
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(appState)
                .tint(StepINColor.primary)
        }
        .modelContainer(modelContainer)
    }

    // MARK: - Store recovery

    private static func wipePersistentStore() {
        let fm = FileManager.default
        guard let supportDir = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else { return }
        let extensions: Set<String> = ["sqlite", "sqlite-shm", "sqlite-wal", "store", "store-shm", "store-wal"]
        let items = (try? fm.contentsOfDirectory(at: supportDir, includingPropertiesForKeys: nil)) ?? []
        for url in items where extensions.contains(url.pathExtension) {
            try? fm.removeItem(at: url)
        }
    }
}
