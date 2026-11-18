import AppKit
import Foundation
import SwiftUI
import Testing
@testable import FudehandApp
@testable import FudehandCore

/// Selecting a layer in a large document (#142): the store change plus the SwiftUI update of the whole editor window until the
/// main thread is idle. Skipped unless `FUDEHAND_BENCHMARK=1`; run it with `pnpm bench:native`, which builds in release.
@Test(.enabled(if: CanvasBenchmark.enabled)) @MainActor func layerSelectionBenchmark() {
    for frames in [10, 100] {
        let store = FudehandStore(defaults: UserDefaults(suiteName: "fudehand-bench-\(UUID().uuidString)")!)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1400, height: 900), styleMask: [.titled, .resizable],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: WorkspaceView(store: store))
        window.orderFront(nil)
        /// Drains the main run loop (SwiftUI applies store changes from it), then lays out and draws the window.
        func settle() {
            for _ in 0..<50 where CFRunLoopRunInMode(.defaultMode, 0, true) == .handledSource {}
            window.layoutIfNeeded()
            window.displayIfNeeded()
            CATransaction.flush()
        }
        store.replace(CanvasBenchmark.document(frames: frames), url: nil)
        for _ in 0..<20 { RunLoop.main.run(until: Date().addingTimeInterval(0.01)); settle() }

        // Alternates between children of the topmost frame, which the layers panel lists first.
        let ids = ["f\(frames - 1)c49", "f\(frames - 1)c48"]
        for run in 0..<4 { store.setSelection([ids[run % 2]]); settle() }
        let select = CanvasBenchmark.time(20) { run in
            store.setSelection([ids[run % 2]])
            settle()
        }
        let idle = CanvasBenchmark.time(20) { _ in settle() }
        #expect(store.selection == [ids[1]])

        print(String(format: "[bench] layers=%d selectLayer=%.2fms (idle frame %.2fms)", store.document.nodeCount, select, idle))
        window.contentView = nil
        window.close()
    }
}
