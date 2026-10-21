import SwiftUI

/// Small compatibility helpers for the iOS 26 design language.
///
/// Standard SwiftUI navigation, controls, sheets, lists, and forms adopt Liquid
/// Glass automatically when built with the iOS 26 SDK. Keep custom glass here so
/// content views don't accumulate availability checks or nested glass effects.
extension View {
    /// Lists below a separate header already have their spacing supplied by
    /// that header. Keep the tab bar's bottom safe area under system control.
    @ViewBuilder
    func appListBelowHeader() -> some View {
        if #available(iOS 17.0, *) {
            self.contentMargins(.top, 0, for: .scrollContent)
        } else {
            self
        }
    }

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

    func appChatControlSurface(cornerRadius: CGFloat, prominent: Bool = false) -> some View {
        modifier(ChatControlSurface(cornerRadius: cornerRadius, prominent: prominent))
    }
}

/// Separate functional glass shapes share one renderer, without nesting glass
/// inside glass. Spacing stays below the composer's gap so text and send remain
/// distinct at rest. Older SDKs never have to type-check iOS 26 APIs.
struct AppGlassControls<Content: View>: View {
    @ViewBuilder let content: () -> Content
    var body: some View {
#if compiler(>=6.2)
        if #available(iOS 26.0, *) { GlassEffectContainer(spacing: 8) { content() } }
        else { content() }
#else
        content()
#endif
    }
}

private struct ChatControlSurface: ViewModifier {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast
    let cornerRadius: CGFloat
    let prominent: Bool
    func body(content: Content) -> some View {
        surface(content)
            .overlay {
                if contrast == .increased || reduceTransparency {
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .strokeBorder(Color.primary.opacity(0.35), lineWidth: 1).allowsHitTesting(false)
                }
            }
    }
    @ViewBuilder private func surface(_ content: Content) -> some View {
        if reduceTransparency {
            content.background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        } else {
#if compiler(>=6.2)
            if #available(iOS 26.0, *) {
                content.glassEffect(prominent ? .regular.tint(.accentColor).interactive() : .regular, in: .rect(cornerRadius: cornerRadius))
            } else {
                content.background(.regularMaterial, in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            }
#else
            content.background(.regularMaterial, in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
#endif
        }
    }
}
