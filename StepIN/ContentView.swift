//
//  ContentView.swift
//  StepIN
//
//  The app entry point is RootTabView (see StepINApp). This preview
//  entry is kept only as a convenience shim.
//

import SwiftUI
import SwiftData

struct ContentView: View {
    var body: some View {
        RootTabView()
            .environment(AppState(hasProfile: true))
            .modelContainer(PreviewData.container)
    }
}

#Preview {
    ContentView()
}
