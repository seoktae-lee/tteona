//
//  tteonaApp.swift
//  tteona
//
//  Created by 이석태 on 5/5/26.
//

import SwiftUI
import FirebaseCore
import KakaoSDKCommon
import KakaoSDKAuth

@main
struct TteonaApp: App {
    @StateObject private var authService = AuthService()
    @StateObject private var notificationManager = AppNotificationManager.shared

    init() {
        FirebaseApp.configure()
        KakaoSDK.initSDK(appKey: "49d0d57217d4659334d500aa7a763ee4")
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(authService)
                .environmentObject(notificationManager)
                .onOpenURL { url in
                    if AuthApi.isKakaoTalkLoginUrl(url) {
                        AuthController.handleOpenUrl(url: url)
                    }
                    // tteona://capture 딥링크는 ImpromptuSessionView에서 처리
                }
        }
    }
}
