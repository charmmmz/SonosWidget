import SwiftUI

/// Bottom-anchored, ultraThinMaterial pill toast that auto-dismisses after a
/// short hold. Used by the detail views to confirm transient actions like
/// "Playing next" / "Added to Favorites" without yanking focus.
///
/// Usage:
/// ```
/// @State private var toastMessage: String?
/// ...
/// .toast($toastMessage)
/// // somewhere in an action handler:
/// showToast("Playing next")
/// ```
/// where `showToast` is the convenience helper below.
struct ToastModifier: ViewModifier {
    @Binding var message: String?

    /// Hold duration before the toast fades out. ~1.8s is the sweet spot
    /// between "long enough to read" and "out of the way before the user
    /// taps something else".
    static let displaySeconds: Double = 1.8
    static let fadeAnimation: Animation = .easeInOut(duration: 0.25)

    func body(content: Content) -> some View {
        content.overlay(alignment: .bottom) {
            if let msg = message {
                Text(msg)
                    .font(.subheadline.weight(.medium))
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .background(.ultraThinMaterial, in: Capsule())
                    .shadow(radius: 4)
                    .padding(.bottom, 80)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                    .onAppear {
                        DispatchQueue.main.asyncAfter(
                            deadline: .now() + Self.displaySeconds
                        ) {
                            withAnimation(Self.fadeAnimation) { message = nil }
                        }
                    }
            }
        }
    }
}

extension View {
    /// Attaches a bottom-anchored auto-dismiss toast bound to `message`.
    /// Set `message` to a non-nil string (typically via the `showToast`
    /// helper on `Binding<String?>`) to surface a confirmation.
    func toast(_ message: Binding<String?>) -> some View {
        modifier(ToastModifier(message: message))
    }
}

extension Binding where Value == String? {
    /// Animated assignment helper so callers don't repeat the
    /// `withAnimation(.easeInOut...)` boilerplate at every action site.
    func showToast(_ text: String) {
        withAnimation(ToastModifier.fadeAnimation) { wrappedValue = text }
    }
}
