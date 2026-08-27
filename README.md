# BlueBird Doc Camera

A dead-simple document-camera viewer for macOS — a replacement for OverCam without the complexity of OBS. It opens a USB document camera (or any video device) and shows it on screen, full-screen for a projector.

## Install (classroom Mac)

Paste this into Terminal — it downloads the latest release, clears the download quarantine, and drops it in Applications:

```bash
cd /tmp && curl -L -o BBDocCam.zip https://github.com/emerytech/bluebird-doc-camera/releases/latest/download/BlueBird-Doc-Camera.zip && ditto -x -k BBDocCam.zip . && xattr -dr com.apple.quarantine "BlueBird Doc Camera.app" && rm -rf "/Applications/BlueBird Doc Camera.app" && mv "BlueBird Doc Camera.app" /Applications/ && open "/Applications/BlueBird Doc Camera.app"
```

On first launch it asks for **Camera** permission — click **Allow**. Then plug in the document camera and go full screen.

> Prefer clicking? Download `BlueBird-Doc-Camera.zip` from the [latest release](https://github.com/emerytech/bluebird-doc-camera/releases/latest), unzip, drag to Applications. Because it's ad-hoc signed (not notarized), the first open may be blocked — either right-click → Open, or approve it under **System Settings ▸ Privacy & Security ▸ Open Anyway**. The Terminal command above skips that by clearing the quarantine flag.

## Features
- Live full-window / full-screen view of the document camera
- Auto-picks the external (document) camera over the built-in FaceTime camera
- Auto-connects when you plug the camera in
- **Freeze** a frame to talk over it, then go live again
- **Rotate** 90° (doc cams are often mounted sideways)
- **Flip horizontal** to fix backwards / mirrored text, **flip vertical** for upside-down
- **Fill vs Fit**
- Remembers your camera + rotation/flip/fill between launches

## Keyboard shortcuts
| Key | Action |
|-----|--------|
| `Space` | Freeze / Go live |
| `R` | Rotate 90° |
| `H` | Flip horizontal (fix backwards text) |
| `V` | Flip vertical |
| `F` | Fill screen / Fit |
| `⌃⌘F` | Full screen (or the green window button) |
| `⌘1`–`⌘9` | Choose camera |

## Build from source
```bash
./build.sh
```
Produces `build/BlueBird Doc Camera.app` — a universal (Apple Silicon + Intel) app targeting macOS 13+, ad-hoc signed. To support older Intel Macs, lower `MIN_MACOS` in `build.sh` (e.g. `11.0` for Big Sur).

## Cut a new release
```bash
./build.sh
ditto -c -k --sequesterRsrc --keepParent "build/BlueBird Doc Camera.app" "BlueBird-Doc-Camera.zip"
gh release create v1.0.1 "BlueBird-Doc-Camera.zip" --title "v1.0.1" --notes "…"
```

## Optional: notarized (no-prompt) install
For a completely frictionless install, sign with a Developer ID and notarize (Apple Developer account required); then the quarantine step isn't needed. Ad-hoc signing is fine for a school-internal tool.
