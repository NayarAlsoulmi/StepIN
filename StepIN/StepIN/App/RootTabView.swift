//
//  RootTabView.swift
//  StepIN
//
//  Native tab shell for the four primary sections. The immersive interview
//  flow is presented modally (later phase) and is intentionally not a tab.
//

import SwiftUI
import SwiftData
import UIKit

struct RootTabView: View {
    @Environment(AppState.self) private var appState

    init() {
        UITabBar.appearance().unselectedItemTintColor = UIColor(
            red: 0x4A / 255,
            green: 0x4A / 255,
            blue: 0x4A / 255,
            alpha: 1
        )
    }

    var body: some View {
        @Bindable var appState = appState

        TabView(selection: $appState.selectedTab) {
            HomeView()
                .tabItem { Label(StepINTab.home.title, systemImage: StepINTab.home.systemImage) }
                .tag(StepINTab.home)

            InterviewsView()
                .tabItem { Label(StepINTab.interviews.title, systemImage: StepINTab.interviews.systemImage) }
                .tag(StepINTab.interviews)

            GoalsView()
                .tabItem { Label(StepINTab.goals.title, systemImage: StepINTab.goals.systemImage) }
                .tag(StepINTab.goals)
        }
        .tint(StepINColor.primary)
    }
}

#Preview {
    RootTabView()
        .environment(AppState(hasProfile: true))
        .modelContainer(PreviewData.container)
}
