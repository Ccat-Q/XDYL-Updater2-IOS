import SwiftUI

struct RootView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        Group {
            if model.isAuthenticated {
                MainTabView()
            } else {
                AuthView()
            }
        }
        .animation(.easeInOut, value: model.isAuthenticated)
    }
}

private struct MainTabView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        TabView {
            NavigationStack { HomeView() }
                .tabItem { Label("首页", systemImage: "house") }
            NavigationStack { CommunityView() }
                .tabItem { Label("社区", systemImage: "bubble.left.and.bubble.right") }
            NavigationStack { DownloadsView() }
                .tabItem { Label("资源", systemImage: "arrow.down.circle") }
            NavigationStack { ServicesView() }
                .tabItem { Label("服务", systemImage: "square.grid.2x2") }
            NavigationStack { ProfileView() }
                .tabItem { Label("我的", systemImage: "person.crop.circle") }
                .badge(model.unreadCount)
        }
        .tint(.accentColor)
        .appTabBarMinimization()
    }
}

struct LoadingOverlay: ViewModifier {
    let visible: Bool
    func body(content: Content) -> some View {
        content.overlay {
            if visible {
                ZStack {
                    Color.black.opacity(0.08).ignoresSafeArea()
                    ProgressView()
                        .controlSize(.large)
                        .padding(22)
                        .appFunctionalSurface(cornerRadius: 18)
                }
            }
        }
    }
}

extension View {
    func loading(_ visible: Bool) -> some View { modifier(LoadingOverlay(visible: visible)) }
}

struct EmptyStateView: View {
    let icon: String
    let title: String
    let message: String

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: icon).font(.system(size: 42)).foregroundStyle(.secondary)
            Text(title).font(.headline)
            Text(message).font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(32)
        .accessibilityElement(children: .combine)
    }
}
