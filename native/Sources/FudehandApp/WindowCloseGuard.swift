import AppKit
import SwiftUI

/// Asks `shouldClose` before the window holding this view closes from its close button or ⌘W (`performClose:`), so the
/// closing can be cancelled or followed up. SwiftUI owns the window's delegate, so the guard sits in front of it and
/// forwards every other delegate message to it unchanged. Closing the window from code (`close()`) does not ask.
struct WindowCloseGuard: NSViewRepresentable {
    let shouldClose: () -> Bool

    func makeNSView(context: Context) -> GuardView { GuardView() }

    func updateNSView(_ view: GuardView, context: Context) {
        view.proxy.shouldClose = shouldClose
    }

    final class GuardView: NSView {
        let proxy = Proxy()

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard let window, window.delegate !== proxy else { return }
            proxy.original = window.delegate
            window.delegate = proxy
        }
    }

    final class Proxy: NSObject, NSWindowDelegate {
        weak var original: NSWindowDelegate?
        var shouldClose: () -> Bool = { true }

        func windowShouldClose(_ sender: NSWindow) -> Bool {
            guard original?.windowShouldClose?(sender) ?? true else { return false }
            return shouldClose()
        }

        override func responds(to selector: Selector!) -> Bool {
            super.responds(to: selector) || original?.responds(to: selector) == true
        }

        override func forwardingTarget(for selector: Selector!) -> Any? {
            original?.responds(to: selector) == true ? original : nil
        }
    }
}
