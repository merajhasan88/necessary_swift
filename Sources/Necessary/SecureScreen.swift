import Foundation
#if os(iOS)
import UIKit
#endif

/// Protects the app's window while a secret is typed. iOS lets no app block screenshots: the window
/// the person sees is covered whenever the screen is recorded, mirrored or sent to AirPlay.
///
/// Calls nest: each `protect(true)` needs its `protect(false)`, and the protection lasts until the
/// last one ends. The cover is placed again whenever a window becomes key, visible or hidden, or a
/// scene comes to the foreground, so it follows the window the person sees when that window is
/// replaced -- and protection asked for before any window exists covers the first one. Answers what
/// the window has now: `held`, `secure` (false on iOS: screenshots are never blocked) and
/// `covered_while_captured`.
@MainActor
public enum SecureScreen {
    @discardableResult
    public static func protect(_ on: Bool) -> [String: Bool] {
        #if os(iOS)
        return ScreenCovers.shared.protect(on)
        #else
        return [:]
        #endif
    }
}

#if os(iOS)
@MainActor
final class ScreenCovers: NSObject {
    static let shared = ScreenCovers()

    /// Callers holding the protection: it lasts until the last one is done.
    private var holders = 0
    private var protected = false
    /// The covers in place now, one per window covered.
    private var covers: [UIView] = []
    /// What moves the covers: the capture starting or stopping, and a window or a scene coming or
    /// going -- so that a cover follows the window the person sees when that window is replaced, or
    /// appears only later.
    private static let events: [Notification.Name] = [
        UIScreen.capturedDidChangeNotification,
        UIWindow.didBecomeKeyNotification,
        UIWindow.didBecomeVisibleNotification,
        UIWindow.didBecomeHiddenNotification,
        UIScene.willEnterForegroundNotification,
        UIScene.didActivateNotification,
        UIScene.didDisconnectNotification,
    ]

    func protect(_ on: Bool) -> [String: Bool] {
        if on {
            holders += 1
        } else if holders > 0 {
            holders -= 1
        }
        setProtection(holders > 0)
        return ["held": holders > 0, "secure": false, "covered_while_captured": holders > 0]
    }

    private func setProtection(_ on: Bool) {
        protected = on
        for name in ScreenCovers.events {
            NotificationCenter.default.removeObserver(self, name: name, object: nil)
            if on {
                NotificationCenter.default.addObserver(
                    self, selector: #selector(coverEvent(_:)), name: name, object: nil)
            }
        }
        updateCovers()
    }

    @objc private func coverEvent(_ notification: Notification) {
        updateCovers()
    }

    /// Covers, in each of the app's scenes whose screen is captured, the window the person sees -- its
    /// key window, or else its first visible window at the normal level -- and nothing else. The covers
    /// are made again at every change, so that none stays on a window replaced and none is missing from
    /// a window that appeared after the protection began.
    private func updateCovers() {
        for cover in covers { cover.removeFromSuperview() }
        covers = []
        guard protected else { return }
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        for scene in scenes where scene.screen.isCaptured {
            guard let window = scene.windows.first(where: { $0.isKeyWindow })
                ?? scene.windows.first(where: { !$0.isHidden && $0.windowLevel == .normal })
            else { continue }
            let view = UIView(frame: window.bounds)
            view.backgroundColor = .black
            view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            window.addSubview(view)
            covers.append(view)
        }
    }
}
#endif
