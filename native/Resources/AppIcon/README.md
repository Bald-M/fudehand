# App icon

`AppIcon-1024.png` is the 1024 × 1024 transparent source master for the bundled macOS icon. `background.png` contains the blue baseplate. `foreground.png` contains the glass globe, glass canvas layer, selection handles, and sparkle. The separate layers were reconstructed from the approved artwork for future editing.

Run `node scripts/build-icon.mjs` from the repository root on macOS to regenerate `native/Resources/AppIcon.icns` with `sips` and `iconutil`. Commit the regenerated file when the master changes. The native build copies it into the app bundle.
