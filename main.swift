import Cocoa
import AVFoundation
import CoreMedia
import CoreVideo
import CoreImage
import QuartzCore
import ServiceManagement

// MARK: - Brand / constants

let appName = "BlueBird DocuCam"
let appCopyright = "© 2026 Taylor Emery — ETS3D LLC. All rights reserved."
let repoURL = "https://github.com/emerytech/bluebird-docucam"
let releasesURL = "https://github.com/emerytech/bluebird-docucam/releases/latest"
let latestReleaseAPI = "https://api.github.com/repos/emerytech/bluebird-docucam/releases/latest"
let kofiURL = "https://ko-fi.com/ets3d"

var appVersion: String { (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "1.0" }

enum Brand {
    /// Royal blue drawn from the app icon — the accent color throughout the UI.
    static let blue = NSColor(srgbRed: 0.16, green: 0.42, blue: 0.92, alpha: 1)   // ~#296BEB
}

// MARK: - Settings store

enum Settings {
    private static let d = UserDefaults.standard

    static var startFullScreen: Bool {
        get { d.bool(forKey: "startFullScreen") }
        set { d.set(newValue, forKey: "startFullScreen") }
    }
    static var hidePointerFullScreen: Bool {
        get { d.object(forKey: "hidePointerFullScreen") == nil ? true : d.bool(forKey: "hidePointerFullScreen") }
        set { d.set(newValue, forKey: "hidePointerFullScreen") }
    }
    /// Launch-at-login is owned by the system (SMAppService), not UserDefaults.
    static var launchAtLoginEnabled: Bool { SMAppService.mainApp.status == .enabled }
    /// Throws when the app isn't in a valid install location (e.g. run from the DMG or
    /// translocated) — the caller surfaces that instead of silently reverting.
    static func setLaunchAtLogin(_ on: Bool) throws {
        if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
    }
}

/// Purely cosmetic "supporter" flag — shows a badge, unlocks nothing. Honor-system
/// for now; the flag lives here so a real check (Ko-fi / license) can back it later
/// without touching the rest of the app.
enum Support {
    private static let d = UserDefaults.standard
    static var isSupporter: Bool {
        get { d.bool(forKey: "isSupporter") }
        set { d.set(newValue, forKey: "isSupporter") }
    }
}

// MARK: - Preview view (live video + freeze overlay, with rotation / flip / fill)

final class PreviewView: NSView {
    let previewLayer = AVCaptureVideoPreviewLayer()
    let freezeLayer = CALayer()
    private let messageLabel = NSTextField(labelWithString: "")
    private let pauseBadge = NSView()

    var rotation = 0 { didSet { needsLayout = true } }          // 0 / 90 / 180 / 270
    var flipH = false { didSet { needsLayout = true } }
    var flipV = false { didSet { needsLayout = true } }
    var fill = false {
        didSet {
            previewLayer.videoGravity = fill ? .resizeAspectFill : .resizeAspect
            freezeLayer.contentsGravity = fill ? .resizeAspectFill : .resizeAspect
            needsLayout = true
        }
    }
    var frozen = false { didSet { freezeLayer.isHidden = !frozen; pauseBadge.isHidden = !frozen } }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor

        previewLayer.videoGravity = .resizeAspect
        freezeLayer.isHidden = true
        freezeLayer.contentsGravity = .resizeAspect
        layer?.addSublayer(previewLayer)
        layer?.addSublayer(freezeLayer)

        messageLabel.font = .systemFont(ofSize: 22, weight: .medium)
        messageLabel.textColor = .white
        messageLabel.alignment = .center
        messageLabel.maximumNumberOfLines = 0
        messageLabel.isHidden = true
        messageLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(messageLabel)
        NSLayoutConstraint.activate([
            messageLabel.centerXAnchor.constraint(equalTo: centerXAnchor),
            messageLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            messageLabel.widthAnchor.constraint(lessThanOrEqualTo: widthAnchor, multiplier: 0.9),
        ])

        // Paused indicator — a pill in the top-right corner, shown only while frozen.
        // A plain subview (not a layer), so it stays put regardless of rotate/flip/fill.
        pauseBadge.wantsLayer = true
        pauseBadge.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.55).cgColor
        pauseBadge.layer?.cornerRadius = 9
        pauseBadge.isHidden = true
        pauseBadge.translatesAutoresizingMaskIntoConstraints = false
        let pauseIcon = NSImageView()
        pauseIcon.image = NSImage(systemSymbolName: "pause.fill", accessibilityDescription: "Paused")
        pauseIcon.contentTintColor = .white
        pauseIcon.translatesAutoresizingMaskIntoConstraints = false
        let pauseLabel = NSTextField(labelWithString: "Paused")
        pauseLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        pauseLabel.textColor = .white
        let pauseStack = NSStackView(views: [pauseIcon, pauseLabel])
        pauseStack.orientation = .horizontal
        pauseStack.spacing = 5
        pauseStack.translatesAutoresizingMaskIntoConstraints = false
        pauseBadge.addSubview(pauseStack)
        addSubview(pauseBadge)
        NSLayoutConstraint.activate([
            pauseBadge.topAnchor.constraint(equalTo: topAnchor, constant: 16),
            pauseBadge.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),
            pauseStack.leadingAnchor.constraint(equalTo: pauseBadge.leadingAnchor, constant: 11),
            pauseStack.trailingAnchor.constraint(equalTo: pauseBadge.trailingAnchor, constant: -11),
            pauseStack.topAnchor.constraint(equalTo: pauseBadge.topAnchor, constant: 6),
            pauseStack.bottomAnchor.constraint(equalTo: pauseBadge.bottomAnchor, constant: -6),
            pauseIcon.widthAnchor.constraint(equalToConstant: 12),
            pauseIcon.heightAnchor.constraint(equalToConstant: 12),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    func showMessage(_ text: String?) {
        if let text, !text.isEmpty {
            messageLabel.stringValue = text
            messageLabel.isHidden = false
        } else {
            messageLabel.isHidden = true
        }
    }

    func setFreezeImage(_ image: CGImage?) { freezeLayer.contents = image }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let b = bounds
        let swapped = rotation % 180 != 0
        let lb = swapped ? CGRect(x: 0, y: 0, width: b.height, height: b.width)
                         : CGRect(x: 0, y: 0, width: b.width, height: b.height)
        for l in [previewLayer, freezeLayer] {
            l.bounds = lb
            l.position = CGPoint(x: b.midX, y: b.midY)
            var t = CATransform3DMakeRotation(CGFloat(rotation) * .pi / 180, 0, 0, 1)
            if flipH { t = CATransform3DScale(t, -1, 1, 1) }
            if flipV { t = CATransform3DScale(t, 1, -1, 1) }
            l.transform = t
        }
        CATransaction.commit()
    }
}

// MARK: - Updater (lightweight: checks the GitHub latest release)

enum Updater {
    static func check(userInitiated: Bool) {
        guard let url = URL(string: latestReleaseAPI) else { return }
        var req = URLRequest(url: url)
        req.timeoutInterval = 10
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        URLSession.shared.dataTask(with: req) { data, _, err in
            DispatchQueue.main.async {
                guard let data, err == nil,
                      let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let tag = obj["tag_name"] as? String else {
                    if userInitiated { alert("Couldn’t check for updates", "Please try again later.") }
                    return
                }
                let latest = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
                if isNewer(latest, than: appVersion) {
                    let a = NSAlert()
                    a.messageText = "Update available"
                    a.informativeText = "\(appName) \(latest) is available. You have \(appVersion)."
                    a.addButton(withTitle: "Download")
                    a.addButton(withTitle: "Later")
                    if a.runModal() == .alertFirstButtonReturn, let u = URL(string: releasesURL) {
                        NSWorkspace.shared.open(u)
                    }
                } else if userInitiated {
                    alert("You’re up to date", "\(appName) \(appVersion) is the latest version.")
                }
            }
        }.resume()
    }

    /// Compare dotted numeric versions, e.g. "1.10.0" > "1.9.0".
    private static func isNewer(_ a: String, than b: String) -> Bool {
        let x = a.split(separator: ".").map { Int($0) ?? 0 }
        let y = b.split(separator: ".").map { Int($0) ?? 0 }
        for i in 0 ..< max(x.count, y.count) {
            let xi = i < x.count ? x[i] : 0
            let yi = i < y.count ? y[i] : 0
            if xi != yi { return xi > yi }
        }
        return false
    }

    private static func alert(_ t: String, _ m: String) {
        let a = NSAlert(); a.messageText = t; a.informativeText = m; a.runModal()
    }
}

// MARK: - About window

final class AboutWindow: NSObject, NSWindowDelegate {
    static let shared = AboutWindow()
    private var window: NSWindow?

    func show() {
        if let w = window { w.makeKeyAndOrderFront(nil); activate(); return }

        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 360, height: 430),
                         styleMask: [.titled, .closable, .fullSizeContentView],
                         backing: .buffered, defer: false)
        w.title = "About \(appName)"
        w.titleVisibility = .hidden
        w.titlebarAppearsTransparent = true
        w.isReleasedWhenClosed = false
        w.delegate = self
        guard let cv = w.contentView else { return }

        let icon = NSImageView()
        icon.image = NSApp.applicationIconImage
        icon.imageScaling = .scaleProportionallyUpOrDown
        icon.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            icon.widthAnchor.constraint(equalToConstant: 96),
            icon.heightAnchor.constraint(equalToConstant: 96),
        ])

        let title = NSTextField(labelWithString: appName)
        title.font = .systemFont(ofSize: 22, weight: .bold)
        title.textColor = Brand.blue

        let version = NSTextField(labelWithString: "Version \(appVersion)")
        version.font = .systemFont(ofSize: 12)
        version.textColor = .secondaryLabelColor

        let tagline = NSTextField(labelWithString: "Your document camera, up on the big screen.")
        tagline.font = .systemFont(ofSize: 12)
        tagline.textColor = .secondaryLabelColor
        tagline.alignment = .center
        wrap(tagline)

        // ── Support (Ko-fi) — cosmetic supporter badge, no feature gating ──
        let supportBlock: NSStackView
        if Support.isSupporter {
            let badge = NSTextField(labelWithString: "💙  Supporter — thank you!")
            badge.font = .systemFont(ofSize: 13, weight: .semibold)
            badge.textColor = Brand.blue
            let kofiSmall = linkButton("Open Ko‑fi", #selector(openKofi))
            kofiSmall.font = .systemFont(ofSize: 11)
            supportBlock = NSStackView(views: [badge, kofiSmall])
        } else {
            let nudge = NSTextField(labelWithString: "Find DocuCam useful? Consider supporting the developer.")
            nudge.font = .systemFont(ofSize: 12)
            nudge.textColor = .secondaryLabelColor
            nudge.alignment = .center
            wrap(nudge)

            let kofi = NSButton(title: "♥  Support on Ko‑fi", target: self, action: #selector(openKofi))
            kofi.bezelStyle = .rounded
            kofi.controlSize = .large
            kofi.bezelColor = Brand.blue
            kofi.attributedTitle = NSAttributedString(
                string: "♥  Support on Ko‑fi",
                attributes: [.foregroundColor: NSColor.white,
                             .font: NSFont.systemFont(ofSize: 13, weight: .semibold)])

            let mark = linkButton("I’ve already supported", #selector(markSupporter))
            mark.font = .systemFont(ofSize: 10)
            mark.contentTintColor = .tertiaryLabelColor

            supportBlock = NSStackView(views: [nudge, kofi, mark])
        }
        supportBlock.orientation = .vertical
        supportBlock.alignment = .centerX
        supportBlock.spacing = 8

        let github = linkButton("View on GitHub", #selector(openGitHub))
        let updates = linkButton("Check for Updates…", #selector(checkUpdates))
        let links = NSStackView(views: [github, updates])
        links.orientation = .horizontal
        links.spacing = 18

        let sep = NSBox(); sep.boxType = .separator

        let copy = NSTextField(labelWithString: appCopyright)
        copy.font = .systemFont(ofSize: 10)
        copy.textColor = .tertiaryLabelColor
        copy.alignment = .center
        wrap(copy)

        let root = NSStackView(views: [icon, title, version, tagline, supportBlock, links, sep, copy])
        root.orientation = .vertical
        root.alignment = .centerX
        root.spacing = 8
        root.setCustomSpacing(4, after: title)
        root.setCustomSpacing(18, after: tagline)
        root.setCustomSpacing(18, after: supportBlock)
        root.setCustomSpacing(14, after: links)
        root.edgeInsets = NSEdgeInsets(top: 26, left: 28, bottom: 20, right: 28)
        root.translatesAutoresizingMaskIntoConstraints = false
        cv.addSubview(root)

        NSLayoutConstraint.activate([
            root.leadingAnchor.constraint(equalTo: cv.leadingAnchor),
            root.trailingAnchor.constraint(equalTo: cv.trailingAnchor),
            root.topAnchor.constraint(equalTo: cv.topAnchor),
            sep.widthAnchor.constraint(equalTo: root.widthAnchor, constant: -56),
        ])

        // Size the window to fit its content rather than a hard-coded height.
        w.layoutIfNeeded()
        w.setContentSize(NSSize(width: 360, height: max(root.fittingSize.height, 300)))

        window = w
        w.center()
        w.makeKeyAndOrderFront(nil)
        activate()
    }

    private func linkButton(_ t: String, _ sel: Selector) -> NSButton {
        let b = NSButton(title: t, target: self, action: sel)
        b.isBordered = false
        b.bezelStyle = .inline
        b.font = .systemFont(ofSize: 12, weight: .medium)
        b.contentTintColor = Brand.blue
        return b
    }

    /// Bound a centered label to the window width so it wraps instead of clipping.
    private func wrap(_ l: NSTextField, width: CGFloat = 300) {
        l.lineBreakMode = .byWordWrapping
        l.maximumNumberOfLines = 2
        l.preferredMaxLayoutWidth = width
    }

    func windowWillClose(_ n: Notification) { window = nil }
    private func activate() {
        if #available(macOS 14.0, *) { NSApp.activate() } else { NSApp.activate(ignoringOtherApps: true) }
    }
    @objc private func openGitHub() { if let u = URL(string: repoURL) { NSWorkspace.shared.open(u) } }
    @objc private func checkUpdates() { Updater.check(userInitiated: true) }
    @objc private func openKofi() { if let u = URL(string: kofiURL) { NSWorkspace.shared.open(u) } }
    @objc private func markSupporter() {
        Support.isSupporter = true
        // Defer teardown so it runs after the button's own event handling unwinds.
        DispatchQueue.main.async {
            if let w = self.window { w.close() }   // windowWillClose sets window = nil
            self.show()                            // rebuild to show the supporter badge
        }
    }
}

// MARK: - Settings window

final class SettingsWindow: NSObject, NSWindowDelegate {
    static let shared = SettingsWindow()
    private var window: NSWindow?
    private weak var owner: AppDelegate?
    private var cameraPopup: NSPopUpButton?
    private weak var loginSwitch: NSSwitch?

    func show(owner: AppDelegate) {
        self.owner = owner
        if let w = window { resync(); w.makeKeyAndOrderFront(nil); activate(); return }

        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 460, height: 300),
                         styleMask: [.titled, .closable], backing: .buffered, defer: false)
        w.title = "\(appName) Settings"
        w.isReleasedWhenClosed = false
        w.delegate = self
        guard let cv = w.contentView else { return }

        let camPopup = NSPopUpButton(frame: .zero, pullsDown: false)
        camPopup.target = self
        camPopup.action = #selector(cameraChanged(_:))
        cameraPopup = camPopup

        let loginSw = makeSwitch(Settings.launchAtLoginEnabled, #selector(loginChanged(_:)))
        loginSwitch = loginSw
        let form = NSStackView(views: [
            header("CAMERA"),
            row("Default camera", camPopup),
            header("STARTUP"),
            row("Open at login", loginSw),
            row("Start in full screen", makeSwitch(Settings.startFullScreen, #selector(startFSChanged(_:)))),
            header("FULL SCREEN"),
            row("Hide the pointer when idle", makeSwitch(Settings.hidePointerFullScreen, #selector(hidePtrChanged(_:)))),
        ])
        form.orientation = .vertical
        form.alignment = .leading
        form.spacing = 10
        form.setCustomSpacing(16, after: form.arrangedSubviews[1])
        form.setCustomSpacing(16, after: form.arrangedSubviews[4])
        form.edgeInsets = NSEdgeInsets(top: 20, left: 24, bottom: 20, right: 24)
        form.translatesAutoresizingMaskIntoConstraints = false
        cv.addSubview(form)
        NSLayoutConstraint.activate([
            form.topAnchor.constraint(equalTo: cv.topAnchor),
            form.leadingAnchor.constraint(equalTo: cv.leadingAnchor),
            form.trailingAnchor.constraint(equalTo: cv.trailingAnchor),
            form.bottomAnchor.constraint(equalTo: cv.bottomAnchor),
        ])

        rebuildCameraPopup()
        window = w
        w.center()
        w.makeKeyAndOrderFront(nil)
        activate()
    }

    /// Keep the popup + login switch in sync when devices/system state change while open.
    func refreshIfOpen() { if window != nil { resync() } }

    /// Re-read state the system or app can change out from under the open window.
    private func resync() {
        rebuildCameraPopup()
        loginSwitch?.state = Settings.launchAtLoginEnabled ? .on : .off
    }

    private func rebuildCameraPopup() {
        guard let pop = cameraPopup, let owner else { return }
        // Build via NSMenuItems — NSPopUpButton.addItem(withTitle:) de-dupes by title,
        // which would collapse two identically named USB doc-cams into a single entry.
        let menu = NSMenu()
        let cams = owner.listCameras()
        if cams.isEmpty {
            let it = NSMenuItem(title: "No cameras found", action: nil, keyEquivalent: "")
            it.isEnabled = false
            menu.addItem(it)
            pop.menu = menu
            pop.isEnabled = false
            return
        }
        pop.isEnabled = true
        let current = owner.currentCameraID()
        var selected: NSMenuItem?
        for cam in cams {
            let it = NSMenuItem(title: cam.localizedName, action: nil, keyEquivalent: "")
            it.representedObject = cam.uniqueID
            menu.addItem(it)
            if cam.uniqueID == current { selected = it }
        }
        pop.menu = menu
        if let selected { pop.select(selected) }
    }

    private func header(_ t: String) -> NSTextField {
        let l = NSTextField(labelWithString: t)
        l.font = .systemFont(ofSize: 10, weight: .semibold)
        l.textColor = Brand.blue
        return l
    }

    private func row(_ label: String, _ control: NSView) -> NSView {
        let l = NSTextField(labelWithString: label)
        l.font = .systemFont(ofSize: 13)
        l.setContentHuggingPriority(.defaultHigh, for: .horizontal)
        let spacer = NSView()
        spacer.setContentHuggingPriority(NSLayoutConstraint.Priority(1), for: .horizontal)
        let h = NSStackView(views: [l, spacer, control])
        h.orientation = .horizontal
        h.alignment = .centerY
        h.spacing = 8
        h.translatesAutoresizingMaskIntoConstraints = false
        h.widthAnchor.constraint(equalToConstant: 412).isActive = true
        return h
    }

    private func makeSwitch(_ on: Bool, _ sel: Selector) -> NSSwitch {
        let s = NSSwitch()
        s.state = on ? .on : .off
        s.target = self
        s.action = sel
        return s
    }

    @objc private func cameraChanged(_ sender: NSPopUpButton) {
        guard let id = sender.selectedItem?.representedObject as? String,
              let cam = owner?.listCameras().first(where: { $0.uniqueID == id }) else { return }
        owner?.selectCamera(cam)
    }
    @objc private func loginChanged(_ s: NSSwitch) {
        do {
            try Settings.setLaunchAtLogin(s.state == .on)
        } catch {
            let a = NSAlert()
            a.messageText = "Couldn’t change “Open at login”"
            a.informativeText = "Make sure \(appName) is in your Applications folder, then try again.\n\n\(error.localizedDescription)"
            a.runModal()
        }
        // reflect the system's actual state (registration can fail from the DMG / Downloads)
        s.state = Settings.launchAtLoginEnabled ? .on : .off
    }
    @objc private func startFSChanged(_ s: NSSwitch) { Settings.startFullScreen = (s.state == .on) }
    @objc private func hidePtrChanged(_ s: NSSwitch) { Settings.hidePointerFullScreen = (s.state == .on) }

    func windowWillClose(_ n: Notification) { window = nil; cameraPopup = nil; loginSwitch = nil }
    private func activate() {
        if #available(macOS 14.0, *) { NSApp.activate() } else { NSApp.activate(ignoringOtherApps: true) }
    }
}

// MARK: - App

final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate, AVCaptureVideoDataOutputSampleBufferDelegate {
    private var window: NSWindow!
    private var preview: PreviewView!
    private var statusItem: NSStatusItem!

    private let session = AVCaptureSession()
    private let sessionQueue = DispatchQueue(label: "docucam.session")
    private let frameQueue = DispatchQueue(label: "docucam.frames")
    private let videoOutput = AVCaptureVideoDataOutput()
    private var currentInput: AVCaptureDeviceInput?     // mutated only on sessionQueue
    private var activeDeviceID: String?                 // UI source of truth; main thread only

    private var pendingFreeze = false                   // guarded by bufferLock
    private let bufferLock = NSLock()
    private let ciContext = CIContext()

    private var cameraMenu: NSMenu!
    private var freezeItem: NSMenuItem!
    private var flipHItem: NSMenuItem!
    private var flipVItem: NSMenuItem!
    private var fillItem: NSMenuItem!

    // pointer-hiding in full screen
    private var lastMouseMove = Date()
    private var idleTimer: Timer?
    private var mouseMonitor: Any?

    private let kDevice = "deviceID", kRotation = "rotation"
    private let kFlipH = "flipH", kFlipV = "flipV", kFill = "fill"

    // MARK: Lifecycle

    func applicationDidFinishLaunching(_ note: Notification) {
        buildWindow()
        buildMenus()
        buildStatusItem()

        let d = UserDefaults.standard
        preview.rotation = d.integer(forKey: kRotation)
        preview.flipH = d.bool(forKey: kFlipH)
        preview.flipV = d.bool(forKey: kFlipV)
        preview.fill = d.bool(forKey: kFill)
        syncViewMenu()

        let nc = NotificationCenter.default
        nc.addObserver(self, selector: #selector(devicesChanged),
                       name: Notification.Name("AVCaptureDeviceWasConnectedNotification"), object: nil)
        nc.addObserver(self, selector: #selector(devicesChanged),
                       name: Notification.Name("AVCaptureDeviceWasDisconnectedNotification"), object: nil)

        // pointer auto-hide in full screen
        mouseMonitor = NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged]) { [weak self] e in
            self?.lastMouseMove = Date(); return e
        }
        idleTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            guard let self else { return }
            if self.window.styleMask.contains(.fullScreen),
               Settings.hidePointerFullScreen,
               Date().timeIntervalSince(self.lastMouseMove) > 3 {
                NSCursor.setHiddenUntilMouseMoves(true)
            }
        }

        checkPermissionAndStart()

        if Settings.startFullScreen {
            DispatchQueue.main.async { self.window.toggleFullScreen(nil) }
        }
    }

    // Keep running in the menu bar after the window is closed.
    func applicationShouldTerminateAfterLastWindowClosed(_ s: NSApplication) -> Bool { false }

    func applicationShouldHandleReopen(_ s: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { showMainWindow() }
        return true
    }

    // MARK: Window

    private func buildWindow() {
        let size = NSSize(width: 1280, height: 800)
        let screen = NSScreen.main?.frame ?? NSRect(x: 0, y: 0, width: size.width, height: size.height)
        let rect = NSRect(x: screen.midX - size.width / 2, y: screen.midY - size.height / 2,
                          width: size.width, height: size.height)
        window = NSWindow(contentRect: rect,
                          styleMask: [.titled, .closable, .miniaturizable, .resizable],
                          backing: .buffered, defer: false)
        window.title = appName
        window.backgroundColor = .black
        window.collectionBehavior.insert(.fullScreenPrimary)
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.acceptsMouseMovedEvents = true
        preview = PreviewView(frame: rect)
        window.contentView = preview
        window.setFrameAutosaveName("DocuCamMainWindow")
        window.makeKeyAndOrderFront(nil)
    }

    @objc private func showMainWindow() {
        window.makeKeyAndOrderFront(nil)
        if #available(macOS 14.0, *) { NSApp.activate() } else { NSApp.activate(ignoringOtherApps: true) }
        sessionQueue.async { if !self.session.isRunning { self.session.startRunning() } }
    }

    // Releasing the camera when the window is closed (app stays in the menu bar).
    func windowWillClose(_ n: Notification) {
        if (n.object as? NSWindow) === window {
            sessionQueue.async { if self.session.isRunning { self.session.stopRunning() } }
        }
    }

    // MARK: Menus

    private func buildMenus() {
        let main = NSMenu()

        let appItem = NSMenuItem(); main.addItem(appItem)
        let appMenu = NSMenu()
        add(appMenu, "About \(appName)", #selector(showAbout))
        add(appMenu, "Check for Updates…", #selector(checkForUpdates))
        add(appMenu, "Support the Developer…", #selector(openKofi))
        appMenu.addItem(.separator())
        add(appMenu, "Settings…", #selector(openSettings), ",", [.command])
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Hide \(appName)", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        appMenu.addItem(withTitle: "Quit \(appName)", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu

        let camItem = NSMenuItem(); main.addItem(camItem)
        cameraMenu = NSMenu(title: "Camera")
        camItem.submenu = cameraMenu

        let viewItem = NSMenuItem(); main.addItem(viewItem)
        let viewMenu = NSMenu(title: "View")
        freezeItem = add(viewMenu, "Freeze", #selector(toggleFreeze), " ", [])
        add(viewMenu, "Rotate", #selector(rotate), "r", [])
        flipHItem = add(viewMenu, "Flip Horizontal", #selector(toggleFlipH), "h", [])
        flipVItem = add(viewMenu, "Flip Vertical", #selector(toggleFlipV), "v", [])
        fillItem = add(viewMenu, "Fill Screen", #selector(toggleFill), "f", [])
        viewMenu.addItem(.separator())
        viewMenu.addItem(withTitle: "Enter Full Screen",
                         action: #selector(NSWindow.toggleFullScreen(_:)), keyEquivalent: "f")
            .keyEquivalentModifierMask = [.command, .control]
        viewItem.submenu = viewMenu

        NSApp.mainMenu = main
        rebuildCameraMenu()
    }

    private func buildStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let btn = statusItem.button {
            let img = NSImage(systemSymbolName: "doc.viewfinder", accessibilityDescription: appName)
            img?.isTemplate = true
            btn.image = img
        }
        let m = NSMenu()
        add(m, "Open \(appName)", #selector(showMainWindow))
        m.addItem(.separator())
        add(m, "Freeze / Go Live", #selector(toggleFreeze))
        add(m, "Enter Full Screen", #selector(fullScreenFromStatus))
        m.addItem(.separator())
        add(m, "Settings…", #selector(openSettings))
        add(m, "About \(appName)", #selector(showAbout))
        add(m, "Check for Updates…", #selector(checkForUpdates))
        add(m, "Support the Developer…", #selector(openKofi))
        m.addItem(.separator())
        add(m, "Quit \(appName)", #selector(NSApplication.terminate(_:)))
        statusItem.menu = m
    }

    @discardableResult
    private func add(_ menu: NSMenu, _ title: String, _ action: Selector,
                     _ key: String = "", _ mods: NSEvent.ModifierFlags? = nil) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        if let mods { item.keyEquivalentModifierMask = mods }
        item.target = self
        menu.addItem(item)
        return item
    }

    private func rebuildCameraMenu() {
        cameraMenu.removeAllItems()
        let devices = availableCameras()
        let activeID = activeDeviceID
        if devices.isEmpty {
            let none = NSMenuItem(title: "No cameras found", action: nil, keyEquivalent: "")
            none.isEnabled = false
            cameraMenu.addItem(none)
        } else {
            for (i, dev) in devices.enumerated() {
                let item = NSMenuItem(title: dev.localizedName, action: #selector(pickCamera(_:)),
                                      keyEquivalent: i < 9 ? "\(i + 1)" : "")
                item.keyEquivalentModifierMask = [.command]
                item.representedObject = dev
                item.target = self
                item.state = dev.uniqueID == activeID ? .on : .off
                cameraMenu.addItem(item)
            }
        }
        cameraMenu.addItem(.separator())
        add(cameraMenu, "Refresh Cameras", #selector(refreshCameras), "r", [.command])
        SettingsWindow.shared.refreshIfOpen()
    }

    private func syncViewMenu() {
        freezeItem.title = preview.frozen ? "Unfreeze (Go Live)" : "Freeze"
        flipHItem.state = preview.flipH ? .on : .off
        flipVItem.state = preview.flipV ? .on : .off
        fillItem.state = preview.fill ? .on : .off
    }

    // MARK: Bridges for the Settings window

    func listCameras() -> [AVCaptureDevice] { availableCameras() }
    func currentCameraID() -> String? { activeDeviceID }
    func selectCamera(_ device: AVCaptureDevice) { selectDevice(device) }

    // MARK: Camera plumbing

    private func availableCameras() -> [AVCaptureDevice] {
        var types: [AVCaptureDevice.DeviceType] = [.builtInWideAngleCamera]
        if #available(macOS 14.0, *) { types.append(.external) } else { types.append(.externalUnknown) }
        return AVCaptureDevice.DiscoverySession(deviceTypes: types, mediaType: .video,
                                                position: .unspecified).devices
    }

    private func isExternal(_ d: AVCaptureDevice) -> Bool {
        if #available(macOS 14.0, *) { return d.deviceType == .external }
        return d.deviceType == .externalUnknown
    }

    private func preferredDefault(_ devices: [AVCaptureDevice]) -> AVCaptureDevice? {
        devices.first(where: isExternal) ?? devices.first   // prefer the doc cam over the built-in FaceTime cam
    }

    private func checkPermissionAndStart() {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            configureAndStart()
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { granted in
                DispatchQueue.main.async {
                    if granted { self.configureAndStart() }
                    else { self.preview.showMessage("Camera access was denied.\n\nEnable it in System Settings ▸ Privacy & Security ▸ Camera, then reopen \(appName).") }
                }
            }
        default:
            preview.showMessage("Camera access is turned off.\n\nEnable it in System Settings ▸ Privacy & Security ▸ Camera, then reopen \(appName).")
        }
    }

    /// Called on main. All session mutation runs on sessionQueue (AVCam pattern);
    /// only UI / CALayer work stays on main.
    private func configureAndStart() {
        preview.previewLayer.session = session          // CALayer op — main thread
        let saved = UserDefaults.standard.string(forKey: kDevice)
        sessionQueue.async {
            self.session.beginConfiguration()
            self.session.sessionPreset = .high
            self.videoOutput.alwaysDiscardsLateVideoFrames = true
            self.videoOutput.setSampleBufferDelegate(self, queue: self.frameQueue)
            if self.session.canAddOutput(self.videoOutput) { self.session.addOutput(self.videoOutput) }
            self.session.commitConfiguration()

            let devices = self.availableCameras()
            if let device = devices.first(where: { $0.uniqueID == saved }) ?? self.preferredDefault(devices) {
                self.applyDeviceLocked(device)          // already on sessionQueue
            } else {
                DispatchQueue.main.async {
                    self.preview.showMessage("No camera found.\n\nPlug in your document camera — it will connect automatically.")
                    self.rebuildCameraMenu()
                }
            }
            if !self.session.isRunning { self.session.startRunning() }
        }
    }

    /// Called on main; performs the switch on the sessionQueue.
    private func selectDevice(_ device: AVCaptureDevice) {
        sessionQueue.async { self.applyDeviceLocked(device) }
    }

    /// MUST run on sessionQueue. Validates the new input BEFORE tearing down the old one,
    /// so a failed switch never leaves the session with no input (silent black screen).
    private func applyDeviceLocked(_ device: AVCaptureDevice) {
        let newInput: AVCaptureDeviceInput
        do {
            newInput = try AVCaptureDeviceInput(device: device)
        } catch {
            DispatchQueue.main.async {
                self.preview.showMessage("Could not open that camera:\n\(error.localizedDescription)")
            }
            return
        }
        session.beginConfiguration()
        let previous = currentInput
        if let previous, session.inputs.contains(previous) { session.removeInput(previous) }
        if session.canAddInput(newInput) {
            session.addInput(newInput)
            currentInput = newInput
            session.commitConfiguration()
            UserDefaults.standard.set(device.uniqueID, forKey: kDevice)
            DispatchQueue.main.async {
                self.activeDeviceID = device.uniqueID
                self.preview.showMessage(nil)
                self.rebuildCameraMenu()
            }
        } else {
            // Couldn't add the new input — restore the previous one if possible.
            if let previous, session.canAddInput(previous) { session.addInput(previous); currentInput = previous }
            else { currentInput = nil }
            session.commitConfiguration()
            let restored = currentInput?.device.uniqueID
            DispatchQueue.main.async {
                self.activeDeviceID = restored
                self.preview.showMessage("That camera is unavailable — it may be in use by another app.")
                self.rebuildCameraMenu()
            }
        }
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
        // Only convert a frame when a freeze is pending — never hold a pool buffer.
        bufferLock.lock()
        let want = pendingFreeze
        if want { pendingFreeze = false }
        bufferLock.unlock()
        guard want, let pb = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        let ci = CIImage(cvPixelBuffer: pb)
        guard let cg = ciContext.createCGImage(ci, from: ci.extent) else { return }
        DispatchQueue.main.async {
            self.preview.setFreezeImage(cg)
            self.preview.frozen = true
            self.syncViewMenu()
        }
    }

    // MARK: Actions

    @objc private func pickCamera(_ sender: NSMenuItem) {
        if let dev = sender.representedObject as? AVCaptureDevice { selectDevice(dev) }
    }

    @objc private func refreshCameras() {
        rebuildCameraMenu()
        if activeDeviceID == nil, let dev = preferredDefault(availableCameras()) { selectDevice(dev) }
    }

    @objc private func devicesChanged() {
        DispatchQueue.main.async {
            let cams = self.availableCameras()
            let stillHere = self.activeDeviceID.map { id in cams.contains { $0.uniqueID == id } } ?? false
            if !stillHere {
                self.activeDeviceID = nil
                if let dev = self.preferredDefault(cams) { self.selectDevice(dev) }
                else { self.preview.showMessage("No camera found.\n\nPlug in your document camera — it will connect automatically.") }
            }
            self.rebuildCameraMenu()
        }
    }

    @objc private func toggleFreeze() {
        if preview.frozen {
            preview.frozen = false
            syncViewMenu()
        } else {
            // Capture the next incoming frame; `frozen` flips true when it arrives.
            bufferLock.lock(); pendingFreeze = true; bufferLock.unlock()
        }
    }

    @objc private func rotate() {
        preview.rotation = (preview.rotation + 90) % 360
        UserDefaults.standard.set(preview.rotation, forKey: kRotation)
    }

    @objc private func toggleFlipH() {
        preview.flipH.toggle()
        UserDefaults.standard.set(preview.flipH, forKey: kFlipH)
        syncViewMenu()
    }

    @objc private func toggleFlipV() {
        preview.flipV.toggle()
        UserDefaults.standard.set(preview.flipV, forKey: kFlipV)
        syncViewMenu()
    }

    @objc private func toggleFill() {
        preview.fill.toggle()
        UserDefaults.standard.set(preview.fill, forKey: kFill)
        syncViewMenu()
    }

    @objc private func fullScreenFromStatus() {
        showMainWindow()
        window.toggleFullScreen(nil)
    }

    @objc private func openSettings() { SettingsWindow.shared.show(owner: self) }
    @objc private func showAbout() { AboutWindow.shared.show() }
    @objc private func checkForUpdates() { Updater.check(userInitiated: true) }
    @objc private func openKofi() { if let u = URL(string: kofiURL) { NSWorkspace.shared.open(u) } }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.regular)
if #available(macOS 14.0, *) { app.activate() } else { app.activate(ignoringOtherApps: true) }
app.run()
