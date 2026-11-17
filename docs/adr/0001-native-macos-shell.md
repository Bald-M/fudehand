# Native macOS Canvas Keeps the Web Examples

2026-11-06: the user chose to deliver a macOS App first. SwiftUI provides the web-project sidebar, toolbar, and theme; AppKit handles precise canvas input; WKWebView displays the existing Vue/React examples. This keeps the ability to import front-end source code while removing the need to run a browser tab and the Vue shell server; rewriting every example in SwiftUI would change what the project teaches and what it can import.

`catalog.json` remains the single source of web projects, frames, and launch configuration. Node only manages the example dev servers, and the App owns their lifecycle. Native preferences are stored separately, and browser localStorage is not migrated automatically. Keeping live web pages means WebKit rendering overhead remains; this decision does not promise unmeasured memory or performance improvements.
