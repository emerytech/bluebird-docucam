# BlueBird DocuCam

A dead-simple document-camera viewer for **macOS, Windows, and Linux** — a replacement for OverCam without the complexity of OBS. It opens a USB document camera (or any video device) and shows it on screen, full-screen for a projector.

**macOS is stable and tested.** Windows and Linux are currently an **alpha** — they build and run, but the live camera output hasn't been verified on real hardware yet.

### macOS — stable
Download **BlueBird-DocuCam.dmg** from the [**latest release**](https://github.com/emerytech/bluebird-docucam/releases/latest), open it, and drag **BlueBird DocuCam** onto **Applications**. Signed with a Developer ID and **notarized by Apple** — no "unidentified developer" warning. Launch it, click **Allow** on the camera prompt, plug in the doc cam, go full screen.

### Windows — alpha
From the [**Windows/Linux alpha release**](https://github.com/emerytech/bluebird-docucam/releases/tag/v1.1.0-alpha), download **BlueBird-DocuCam-Setup-*.exe** and run it. Not code-signed yet, so Windows SmartScreen shows *"Windows protected your PC"* — click **More info → Run anyway** (a one-time step). Then allow camera access.

### Linux — alpha
From the [**alpha release**](https://github.com/emerytech/bluebird-docucam/releases/tag/v1.1.0-alpha), download **BlueBird-DocuCam-*.AppImage** (universal — `chmod +x` and run) or **BlueBird-DocuCam-*.deb** for Debian/Ubuntu (`sudo dpkg -i`). Grant camera access when prompted.

> **Note:** macOS runs the native Swift app (repo root); Windows and Linux run an Electron build (`electron/`) — same features and look.

## Features
- Live full-window / full-screen view of the document camera
- Auto-picks the external (document) camera over the built-in FaceTime camera
- Auto-connects when you plug the camera in
- **Use your iPhone/iPad as the document camera** (Continuity Camera — no extra hardware)
- **Zoom & pan** — scroll or pinch to zoom into detail, drag to pan
- **Freeze** a frame to talk over it (with a "⏸ Paused" indicator), then go live again
- **Rotate** 90°, **flip** horizontal/vertical (fix backwards / upside-down text), **fill vs fit**
- **Snapshot** — save the frame to PNG or copy to the clipboard
- **PDF scanner** — capture multiple pages and export them as one PDF
- **Annotate** — draw with a pen or highlighter over the image (freeze first for a still page)
- **Menu-bar icon** for quick access (freeze, full screen, reopen) — stays running when the window is closed
- **Settings** (`⌘,`): open at login, start in full screen, hide the pointer when idle
- **About** window with version and a one-tap **Check for Updates**
- Remembers your camera + rotation/flip/fill between launches
- Free — with an optional [Ko‑fi](https://ko-fi.com/ets3d) tip jar to support the developer

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
| `⌘,` | Settings |
| `⌘+` / `⌘−` / `⌘0` | Zoom in / out / actual size |
| `⌘S` / `⌘C` | Save image / Copy image |
| `⇧⌘A` / `⇧⌘P` | Add page to scan / Save scan as PDF |
| `D` | Toggle annotation |

## Repo layout
- **`/` (root)** — the **native macOS** app (Swift/AppKit/AVFoundation). Best macOS experience; signed + notarized.
- **`electron/`** — the **Windows + Linux** app (Electron). Same features and look; built by CI.

## Build from source

### macOS (native)
```bash
./build.sh          # universal build, ad-hoc signed (local testing)
./build.sh --sign   # Developer ID signed + notarized + stapled → BlueBird-DocuCam.dmg (+ .zip)
```
Universal (Apple Silicon + Intel), macOS 13+. Lower `MIN_MACOS` in `build.sh` for older Intel Macs. `--sign` uses the `Developer ID Application: Taylor Emery (XK6QP975ZQ)` cert and the `axe` notarytool keychain profile.

### Windows / Linux (Electron)
```bash
cd electron
npm install
npm run dist:win     # → dist/BlueBird-DocuCam-Setup-<ver>.exe   (build on Windows)
npm run dist:linux   # → dist/BlueBird-DocuCam-<ver>.AppImage + .deb   (build on Linux)
npm start            # run locally for development
```
Windows and Linux installers are normally built by CI, not locally.

## Cut a new release
1. **macOS:** `./build.sh --sign`, then `gh release create vX.Y.Z BlueBird-DocuCam.dmg BlueBird-DocuCam.zip --title "vX.Y.Z" --notes "…"`
2. **Windows + Linux:** push the `vX.Y.Z` tag (or run the **Build Windows & Linux installers** Action with that tag). CI builds the `.exe`, `.AppImage`, and `.deb` and attaches them to that same release.

Keep `electron/package.json` `version` in sync with the macOS app's `CFBundleShortVersionString`.
