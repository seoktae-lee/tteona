//
//  tteonaApp.swift
//  tteona
//
//  Created by 이석태 on 5/5/26.
//

import SwiftUI
import FirebaseCore

@main
struct TteonaApp: App {
    @StateObject private var authService = AuthService()

    init() {
        FirebaseApp.configure()
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(authService)
        }
    }
}
