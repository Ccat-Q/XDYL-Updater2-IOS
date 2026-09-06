import SwiftUI

/// Small compatibility helpers for the iOS 26 design language.
///
/// Standard SwiftUI navigation, controls, sheets, lists, and forms adopt Liquid
/// Glass automatically when built with the iOS 26 SDK. Keep custom glass here so
/// content views don't accumulate availability checks or nested glass effects.
extension View {
    @ViewBuilder
    func appTabBarMinimization() -> some View {
#if compiler(>=6.2)
        if #available(iOS 26.0, *) {
            self.tabBarMinimizeBehavior(.onScrollDown)
        } else {
            self
        }
#else
        self
#endif
    }

    @ViewBuilder
    func appFunctionalSurface(cornerRadius: CGFloat = 20) -> some View {
#if compiler(>=6.2)
        if #available(iOS 26.0, *) {
            self.glassEffect(.regular, in: .rect(cornerRadius: cornerRadius))
        } else {
            self.background(.regularMaterial, in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        }
#else
        self.background(.regularMaterial, in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
#endif
    }

    func appContentBackground() -> some View {
        background(Color(uiColor: .systemGroupedBackground).ignoresSafeArea())
    }

    func appSurfaceCard(cornerRadius: CGFloat = 18) -> some View {
        background(
            Color(uiColor: .secondarySystemGroupedBackground),
            in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        )
    }
}
