import UIKit

extension UIApplication {
    @MainActor
    var sonosPresentationWindow: UIWindow? {
        let scenes = connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .filter { scene in
                scene.activationState == .foregroundActive ||
                scene.activationState == .foregroundInactive
            }
        let windows = scenes.flatMap(\.windows)
        return windows.first(where: \.isKeyWindow) ?? windows.first
    }
}
