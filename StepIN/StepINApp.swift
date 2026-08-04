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
        do {
            let container = try ModelContainer(for: Schema(StepINSchema.models))
            self.modelContainer = container
            // A local profile exists if one has already been created.
            let hasProfile = (try? container.mainContext.fetch(FetchDescriptor<UserProfile>()))?.isEmpty == false
            self._appState = State(initialValue: AppState(hasProfile: hasProfile))
        } catch {
            fatalError("Failed to create StepIN model container: \(error)")
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
}
