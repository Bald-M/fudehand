# App icon

`AppIcon-1024.png` is the 1024 × 1024 transparent source master for the bundled macOS icon: an ink-wash painting on rice paper of mountains receding in three ink tones under a red sun. It is drawn by `icon.html`, a self-contained canvas script; edit the script to change the artwork.

To regenerate the master, render `icon.html` at 1024 × 1024 on a transparent background with headless Chrome, from the repository root:

```bash
"/Applications/Google Chrome.app/Contents/MacOS/Google Chrome" --headless=new --hide-scrollbars --window-size=1024,1024 --default-background-color=00000000 --screenshot="$PWD/native/Resources/AppIcon/AppIcon-1024.png" "file://$PWD/native/Resources/AppIcon/icon.html"
```

Then run `node scripts/build-icon.mjs` on macOS to regenerate `native/Resources/AppIcon.icns` with `sips` and `iconutil`. Commit the regenerated files when the artwork changes. The native build copies the `.icns` into the app bundle.
