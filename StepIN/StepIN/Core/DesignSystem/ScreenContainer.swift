//
//  ScreenContainer.swift
//  StepIN
//
//  Created by Salma on 23/02/1448 AH.
//

import SwiftUI

struct ScreenContainer<Content: View>: View {

    @ViewBuilder let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        ZStack {

            Background()

            content

        }
    }
}
