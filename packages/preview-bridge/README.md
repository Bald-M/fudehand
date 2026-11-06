# Preview bridge

This tiny workspace package lets Escape return focus from a trusted local iframe to the Atlas canvas.

```ts
import { installPreviewBridge } from "@ui-atlas/preview-bridge";
const cleanup = installPreviewBridge("http://127.0.0.1:4400");
```

Pass the exact shell origin when changing its host or port. Both built-in cases read it from `catalog.json`. The bridge does nothing outside an iframe. It sends only `{ type: 'ui-atlas:exit-preview' }` to that exact origin; the shell must also check the message's origin and source window. The visible shell exit button works without this bridge. A case can call `event.preventDefault()` on Escape before the window listener if it needs to consume that key locally.

When a native `<dialog>` is open, Escape is left to the dialog so the browser can close it before the preview exits. After the dialog closes, a subsequent Escape returns to the canvas.
