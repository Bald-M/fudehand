# Web Projects Open Only in App Frames

> Superseded by [ADR 0006](0006-native-design-document.md): the web-project pipeline has been removed, and this document is kept only as a historical record.

2026-11-17. Fudehand is positioned so that web projects are viewed only in the App's frames (#36). Previously the frame title bar had an Open in Browser (在浏览器打开) button, cross-origin links, `window.open`, and `target=_blank` were handed to the default browser, and any browser could access the preview ports on `127.0.0.1` directly.

Frames no longer launch a browser: the title bar button is removed, and main-frame navigations and new-window requests that leave the web project's local server are ignored. The preview ports are guarded by a **preview token**:

- The App (`PreviewSession`) generates a 32-byte random token each time it starts the launcher and passes it to `native-preview.mjs` through the environment variable `UI_ATLAS_PREVIEW_TOKEN`; every example process the launcher starts on demand inherits it, and readiness checks carry the same cookie.
- While starting the launcher, the App writes the token into the session cookie `ui_atlas_preview` of the default `WKWebsiteDataStore` (one each for `127.0.0.1`, `localhost`, and `::1`; cookies are not port-specific). Until the write completes, a web project still shows as starting even if its example server is ready, so the cookie is always in place when the frame is created.
- Each example's `vite.config.ts` uses the `previewGate()` plugin from `scripts/preview-gate.mjs`, which rejects HTTP requests without that cookie (403) ahead of Vite's own middleware. The page, subresources, and the HMR client are all requested by the frame with the cookie, so hot updates are unaffected.

## Rejected Alternatives

- **A custom URL scheme, or dropping the HTTP dev server**: would require rewriting resource loading and hot updates, which is out of scope (an Issue non-goal).
- **Put the token in a query parameter of the frame URL and have the server set the cookie**: the token would appear in the page address and in the state returned to the agent, and same-origin navigation would need extra handling; writing the WKWebView cookie directly is simpler.
- **Have the launcher generate the token and pass it to the App over stdout**: would require extending the launcher's stdout protocol; the App already starts the launcher, so generating the token itself and passing it down through an environment variable is more direct.

## Consequences

- This makes the preview "not casually openable in a browser"; it is not a security boundary: other programs on the machine can still read the process environment or capture loopback traffic, which is outside the scope of protection.
- When running an example's `pnpm dev` on its own, without the App, there is no token and the plugin does not block, which makes debugging a single example easier.
- Non-Vite examples must implement the same cookie check themselves, or they can still be accessed directly from a browser.
- The built-in examples all use `127.0.0.1` (verified in the real App); cookies for `localhost` and `::1` are written as well, but `::1` has not yet been tested in WebKit.
- MCP's `get_preview_urls` returns addresses for reference only; use `frame_snapshot` to see the rendered result.
