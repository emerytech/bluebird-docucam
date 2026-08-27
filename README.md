# BlueBird DocuCam

A dead-simple document-camera viewer for macOS — a replacement for OverCam without the complexity of OBS. It opens a USB document camera (or any video device) and shows it on screen, full-screen for a projector.

## Install (classroom Mac)

1. Download **BlueBird-DocuCam.dmg** from the [latest release](https://github.com/emerytech/bluebird-docucam/releases/latest).
2. Open it and drag **BlueBird DocuCam** onto the **Applications** folder.
3. Launch it from Applications, click **Allow** on the camera prompt, plug in the doc cam, and go full screen.

It's signed with a Developer ID and notarized by Apple, so it opens with **no "unidentified developer" warning** — nothing to right-click or approve.

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
./build.sh          # universal build, ad-hoc signed (local testing)
./build.sh --sign   # Developer ID signed + notarized + stapled → BlueBird-DocuCam.dmg (+ .zip)
```
Produces a universal (Apple Silicon + Intel) app targeting macOS 13+. To support older Intel Macs, lower `MIN_MACOS` in `build.sh` (e.g. `11.0` for Big Sur).

`--sign` uses the `Developer ID Application: Taylor Emery (XK6QP975ZQ)` cert and the `axe` notarytool keychain profile (shared across the team's apps). Override with `TEAM_ID` / `NOTARYTOOL_PROFILE`, or `APPLE_ID` + `APP_PASSWORD`, via env or a `.env` file beside the script.

## Cut a new release
```bash
./build.sh --sign
gh release create v1.0.1 BlueBird-DocuCam.dmg BlueBird-DocuCam.zip --title "v1.0.1" --notes "…"
```
