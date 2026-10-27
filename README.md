# Skitch Redux

A native macOS replacement for Evernote's abandoned Skitch: snap, mark up with big friendly arrows, drag it out.

Skitch was the fastest way to grab a bit of the screen, slap an arrow and a label on it, and drag the result straight into an email or chat. Evernote stopped developing it years ago and it has steadily rotted on modern macOS. Skitch Redux rebuilds that workflow, and the Skitch 2.x look, as a small, dependency-free AppKit app.

## Build & install

```sh
./scripts/build-app.sh            # → build/Skitch Redux.app
./scripts/build-app.sh --install  # also copies it to /Applications
```

Requires Xcode / Swift 5.10+, macOS 14+. No dependencies.

On first capture macOS will ask for **Screen Recording** permission (System Settings → Privacy & Security → Screen & System Audio Recording). The build is ad-hoc signed, so macOS treats each rebuild as a new app and you'll need to re-allow it. To avoid that, run `./scripts/make-signing-cert.sh` once: it creates a self-signed "Skitch Redux Local Signing" identity in your login keychain, which `build-app.sh` then uses automatically (or set `SIGN_IDENTITY` to any other identity).

## Using it

| | |
|---|---|
| ⌃⌘5 | Crosshair snapshot (space toggles window mode, Esc cancels) |
| ⌃⌘7 | Window snapshot |
| ⌃⌘6 | Fullscreen snapshot (main display) |
| ⌘N | New from clipboard |
| ⌘O | Open image (or drop images on the Dock icon) |

Hotkeys work globally; there's also a menu bar icon.

**Tools** (single-key shortcuts while the canvas has focus): Select `V`, Arrow `A`, Text `T`, Rectangle `R`, Rounded rectangle `U`, Ellipse `O`, Line `L`, Pen `P`, Highlighter `H`, Pixelate `X`, Crop `C`.

- Shift while dragging snaps lines to 45° and boxes to squares.
- Everything stays editable: click an annotation to select it, drag to move, drag handles to reshape, Delete to remove, arrow keys to nudge (Shift = 10pt). Changing colour/size applies to the selection.
- Text: click to type, Return to finish, ⌥Return for a new line, Esc to cancel. Double-click text (or click it with the Text tool) to edit.
- Crop: drag a region, Return to apply.
- Unlimited undo/redo.

**Getting it out:** drag the **Drag me** tab at the bottom into Finder, Mail, Slack, etc.; ⌘C copies the annotated image; ⌘S saves PNG or JPEG (at full retina resolution); or use Share.

## Code layout

- `Model.swift` — tools, annotation model, hit testing
- `Renderer.swift` — draws annotations; shared by the canvas and export so they always match
- `CanvasView.swift` — editing interaction, text editing, crop, undo
- `EditorWindowController.swift` — toolbar, save/share
- `Chrome.swift` — Skitch 2.x look: tool rail, snap button, chrome bar
- `Controls.swift` — colour swatches, drag-out tab
- `ImageIO.swift` — loading images from files, data and the clipboard
- `Capture.swift` — ScreenCaptureKit capture and Carbon global hotkeys
- `AppDelegate.swift` — menus, menu bar item, launcher window

## License

MIT — see [LICENSE](LICENSE).
