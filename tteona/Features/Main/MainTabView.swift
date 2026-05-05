import SwiftUI

struct MainTabView: View {
    @EnvironmentObject private var authService: AuthService
    @EnvironmentObject private var courseService: CourseService
    @StateObject private var userService = UserService()

    var body: some View {
        TabView {
            MainView()
                .tabItem {
                    Label("홈", systemImage: "map.fill")
                }

            MyCourseView()
                .tabItem {
                    Label("나의 코스", systemImage: "heart.fill")
                }

            SettingsView()
                .tabItem {
                    Label("설정", systemImage: "gearshape.fill")
                }
        }
        .tint(.tteOrange)
        .environmentObject(userService)
        .task {
            if let uid = authService.currentUser?.uid {
                await userService.fetchUser(uid: uid)
            }
        }
    }
}
