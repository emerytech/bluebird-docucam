import Cocoa
import UniformTypeIdentifiers
import PDFKit
import AVFoundation
import CoreMedia
import CoreVideo
import CoreImage
import QuartzCore
import ServiceManagement
import Vision
import IOKit.pwr_mgt

// MARK: - Brand / constants

let appName = "BlueBird DocuCam"
let appCopyright = "© 2026 Taylor Emery — ETS3D LLC. All rights reserved."
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
    /// Launch to the menu bar with no visible window (pairs with Open at login).
    static var startMinimized: Bool {
        get { d.bool(forKey: "startMinimized") }
        set { d.set(newValue, forKey: "startMinimized") }
    }
    /// Begin recording automatically once the camera is live after launch.
    static var autoStartRecording: Bool {
        get { d.bool(forKey: "autoStartRecording") }
        set { d.set(newValue, forKey: "autoStartRecording") }
    }
    /// Where finished recordings go, as a security-scoped bookmark so a user-chosen folder
    /// (including a mounted network share) survives relaunch and the App Sandbox.
    /// nil ⇒ ~/Downloads.
    static var recordFolderBookmark: Data? {
        get { d.data(forKey: "recordFolderBookmark") }
        set {
            if let v = newValue { d.set(v, forKey: "recordFolderBookmark") }
            else { d.removeObject(forKey: "recordFolderBookmark") }
        }
    }
    // Security-scoped bookmarks are mandatory under the sandbox (MAS build) and a harmless
    // no-op in the Developer ID build, so the options differ only by build flavor.
    static var bookmarkCreateOptions: URL.BookmarkCreationOptions {
        #if APP_STORE
        return [.withSecurityScope]
        #else
        return []
        #endif
    }
    static var bookmarkResolveOptions: URL.BookmarkResolutionOptions {
        #if APP_STORE
        return [.withSecurityScope]
        #else
        return []
        #endif
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
    let annotationView = AnnotationView()
    private let messageLabel = NSTextField(labelWithString: "")
    private let pauseBadge = NSView()
    private let recBadge = NSView()
    private let scanBadge = NSView()
    private let scanBadgeLabel = NSTextField(labelWithString: "")

    var scanCount = 0 {
        didSet {
            scanBadge.isHidden = scanCount == 0
            scanBadgeLabel.stringValue = "\(scanCount) page" + (scanCount == 1 ? "" : "s")
        }
    }

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
    var recording = false { didSet { recBadge.isHidden = !recording } }
    var zoom: CGFloat = 1 { didSet { needsLayout = true } }
    var panOffset = CGPoint.zero { didSet { needsLayout = true } }
    private var lastDrag: CGPoint?
    private var didPushCursor = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor

        previewLayer.videoGravity = .resizeAspect
        freezeLayer.isHidden = true
        freezeLayer.contentsGravity = .resizeAspect
        layer?.addSublayer(previewLayer)
        layer?.addSublayer(freezeLayer)

        annotationView.frame = bounds
        annotationView.autoresizingMask = [.width, .height]
        addSubview(annotationView)

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

        // Scan page-count badge — a pill in the top-left, shown while a PDF scan is in progress.
        scanBadge.wantsLayer = true
        scanBadge.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.55).cgColor
        scanBadge.layer?.cornerRadius = 9
        scanBadge.isHidden = true
        scanBadge.translatesAutoresizingMaskIntoConstraints = false
        let scanIcon = NSImageView()
        scanIcon.image = NSImage(systemSymbolName: "doc.on.doc", accessibilityDescription: "Scan pages")
        scanIcon.contentTintColor = .white
        scanIcon.translatesAutoresizingMaskIntoConstraints = false
        scanBadgeLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        scanBadgeLabel.textColor = .white
        let scanStack = NSStackView(views: [scanIcon, scanBadgeLabel])
        scanStack.orientation = .horizontal
        scanStack.spacing = 5
        scanStack.translatesAutoresizingMaskIntoConstraints = false
        scanBadge.addSubview(scanStack)
        addSubview(scanBadge)
        NSLayoutConstraint.activate([
            scanBadge.topAnchor.constraint(equalTo: topAnchor, constant: 16),
            scanBadge.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            scanStack.leadingAnchor.constraint(equalTo: scanBadge.leadingAnchor, constant: 11),
            scanStack.trailingAnchor.constraint(equalTo: scanBadge.trailingAnchor, constant: -11),
            scanStack.topAnchor.constraint(equalTo: scanBadge.topAnchor, constant: 6),
            scanStack.bottomAnchor.constraint(equalTo: scanBadge.bottomAnchor, constant: -6),
            scanIcon.widthAnchor.constraint(equalToConstant: 14),
            scanIcon.heightAnchor.constraint(equalToConstant: 12),
        ])

        // Recording indicator — red pill, top-center, shown while recording.
        recBadge.wantsLayer = true
        recBadge.layer?.backgroundColor = NSColor.systemRed.withAlphaComponent(0.92).cgColor
        recBadge.layer?.cornerRadius = 9
        recBadge.isHidden = true
        recBadge.translatesAutoresizingMaskIntoConstraints = false
        let recDot = NSView()
        recDot.wantsLayer = true
        recDot.layer?.backgroundColor = NSColor.white.cgColor
        recDot.layer?.cornerRadius = 4
        recDot.translatesAutoresizingMaskIntoConstraints = false
        let recLabel = NSTextField(labelWithString: "REC")
        recLabel.font = .systemFont(ofSize: 13, weight: .bold)
        recLabel.textColor = .white
        let recStack = NSStackView(views: [recDot, recLabel])
        recStack.orientation = .horizontal
        recStack.spacing = 6
        recStack.translatesAutoresizingMaskIntoConstraints = false
        recBadge.addSubview(recStack)
        addSubview(recBadge)
        NSLayoutConstraint.activate([
            recBadge.topAnchor.constraint(equalTo: topAnchor, constant: 16),
            recBadge.centerXAnchor.constraint(equalTo: centerXAnchor),
            recStack.leadingAnchor.constraint(equalTo: recBadge.leadingAnchor, constant: 11),
            recStack.trailingAnchor.constraint(equalTo: recBadge.trailingAnchor, constant: -11),
            recStack.topAnchor.constraint(equalTo: recBadge.topAnchor, constant: 6),
            recStack.bottomAnchor.constraint(equalTo: recBadge.bottomAnchor, constant: -6),
            recDot.widthAnchor.constraint(equalToConstant: 8),
            recDot.heightAnchor.constraint(equalToConstant: 8),
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
            l.position = CGPoint(x: b.midX + panOffset.x, y: b.midY + panOffset.y)
            var t = CATransform3DMakeRotation(CGFloat(rotation) * .pi / 180, 0, 0, 1)
            if flipH { t = CATransform3DScale(t, -1, 1, 1) }
            if flipV { t = CATransform3DScale(t, 1, -1, 1) }
            if zoom != 1 { t = CATransform3DScale(t, zoom, zoom, 1) }   // zoom in screen space
            l.transform = t
        }
        CATransaction.commit()
    }

    // MARK: Zoom & pan — scroll or pinch to zoom (anchored at the cursor), drag to pan, double-click to reset.

    override func scrollWheel(with event: NSEvent) {
        let delta = event.hasPreciseScrollingDeltas ? event.scrollingDeltaY : event.deltaY
        guard delta != 0 else { return }
        zoomBy(1 + delta * 0.008, at: convert(event.locationInWindow, from: nil))
    }
    override func magnify(with event: NSEvent) {
        zoomBy(1 + event.magnification, at: convert(event.locationInWindow, from: nil))
    }
    private func zoomBy(_ factor: CGFloat, at point: CGPoint) {
        let newZoom = min(max(zoom * factor, 1), 8)
        guard abs(newZoom - zoom) > 0.0001 else { return }
        let f = newZoom / zoom
        let cc = CGPoint(x: point.x - bounds.midX, y: point.y - bounds.midY)
        var newPan = CGPoint(x: cc.x * (1 - f) + f * panOffset.x,
                             y: cc.y * (1 - f) + f * panOffset.y)
        if newZoom == 1 { newPan = .zero }
        zoom = newZoom
        panOffset = clampPan(newPan, forZoom: newZoom)
    }
    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2 { resetZoom(); lastDrag = nil; return }
        lastDrag = convert(event.locationInWindow, from: nil)
        if zoom > 1 { NSCursor.closedHand.push(); didPushCursor = true }
    }
    override func mouseDragged(with event: NSEvent) {
        guard zoom > 1, let last = lastDrag else { return }
        let p = convert(event.locationInWindow, from: nil)
        panOffset = clampPan(CGPoint(x: panOffset.x + (p.x - last.x), y: panOffset.y + (p.y - last.y)), forZoom: zoom)
        lastDrag = p
    }
    override func mouseUp(with event: NSEvent) {
        if didPushCursor { NSCursor.pop(); didPushCursor = false }
        lastDrag = nil
    }
    private func clampPan(_ p: CGPoint, forZoom z: CGFloat) -> CGPoint {
        let mx = max(0, (z - 1) * bounds.width / 2), my = max(0, (z - 1) * bounds.height / 2)
        return CGPoint(x: min(max(p.x, -mx), mx), y: min(max(p.y, -my), my))
    }
    func resetZoom() { zoom = 1; panOffset = .zero }
    func stepZoom(_ factor: CGFloat) { zoomBy(factor, at: CGPoint(x: bounds.midX, y: bounds.midY)) }
}

// MARK: - Annotation overlay — draw on the image (freeze first for a still page)

final class AnnotationView: NSView {
    private struct Stroke { var points: [CGPoint]; var color: NSColor; var width: CGFloat }
    private var strokes: [Stroke] = []
    private var current: Stroke?

    var active = false { didSet { window?.invalidateCursorRects(for: self) } }
    var color: NSColor = .systemRed
    var highlighter = false

    override var isFlipped: Bool { false }
    // Pass mouse through to the preview (pan/zoom) unless we're actively annotating.
    override func hitTest(_ point: NSPoint) -> NSView? { active ? super.hitTest(point) : nil }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { active }

    override func mouseDown(with e: NSEvent) {
        let p = convert(e.locationInWindow, from: nil)
        current = Stroke(points: [p],
                         color: highlighter ? color.withAlphaComponent(0.35) : color,
                         width: highlighter ? 22 : 4)
    }
    override func mouseDragged(with e: NSEvent) {
        guard current != nil else { return }
        current?.points.append(convert(e.locationInWindow, from: nil))
        needsDisplay = true
    }
    override func mouseUp(with e: NSEvent) {
        if var s = current {
            if s.points.count == 1 { s.points.append(CGPoint(x: s.points[0].x + 0.5, y: s.points[0].y + 0.5)) }
            strokes.append(s)
        }
        current = nil
        needsDisplay = true
    }
    override func draw(_ dirtyRect: NSRect) {
        for s in strokes { drawStroke(s) }
        if let s = current { drawStroke(s) }
    }
    private func drawStroke(_ s: Stroke) {
        guard s.points.count > 1 else { return }
        let path = NSBezierPath()
        path.lineWidth = s.width
        path.lineCapStyle = .round
        path.lineJoinStyle = .round
        path.move(to: s.points[0])
        for p in s.points.dropFirst() { path.line(to: p) }
        s.color.setStroke()
        path.stroke()
    }
    override func resetCursorRects() { if active { addCursorRect(bounds, cursor: .crosshair) } }
    func clear() { strokes.removeAll(); current = nil; needsDisplay = true }
}

#if !APP_STORE   // GitHub build only: self-update + Ko-fi. The App Store build strips both.

// Direct builds report unless the user opts out in Settings.
private enum InstallCount {
    static let preference = "participatesInInstallCount"
    static var enabled: Bool { UserDefaults.standard.object(forKey: preference) as? Bool ?? true }
    private static var inFlight = false
    private static let session = URLSession(configuration: .ephemeral)

    static func checkIn() {
        let defaults = UserDefaults.standard
        guard enabled, !inFlight else { return }
        if let last = defaults.object(forKey: "installCountLastSuccess") as? Date,
           (0..<86400).contains(Date().timeIntervalSince(last)) { return }
        let id = defaults.string(forKey: "installCountID") ?? UUID().uuidString.lowercased()
        defaults.set(id, forKey: "installCountID")
        var request = URLRequest(url: URL(string: "https://docucam-install-count.taylor-c24.workers.dev/v1/check-in")!)
        request.httpMethod = "POST"
        request.httpBody = Data(id.utf8)
        request.timeoutInterval = 15
        inFlight = true
        session.dataTask(with: request) { _, response, _ in
            DispatchQueue.main.async {
                inFlight = false
                if (response as? HTTPURLResponse)?.statusCode == 204 {
                    defaults.set(Date(), forKey: "installCountLastSuccess")
                }
            }
        }.resume()
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
                    a.informativeText = "\(appName) \(latest) is available. You have \(appVersion). Install it now?"
                    a.addButton(withTitle: "Install & Relaunch")
                    a.addButton(withTitle: "Later")
                    if a.runModal() == .alertFirstButtonReturn {
                        SelfUpdater.shared.install(version: latest)   // download + in-place swap + relaunch
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

// MARK: - In-place updater — download the release zip, atomically swap the bundle, relaunch.
// GitHub build only; the App Store build must never self-update (Apple handles updates there).

final class SelfUpdater: NSObject, NSWindowDelegate {
    static let shared = SelfUpdater()
    private var window: NSWindow?
    private var progressBar: NSProgressIndicator?
    private var statusLabel: NSTextField?
    private var downloadTask: URLSessionDownloadTask?
    private var cancelled = false

    func install(version: String) {
        cancelled = false
        showProgress(version: version)
        let urlStr = "https://github.com/emerytech/bluebird-docucam/releases/download/v\(version)/BlueBird-DocuCam.zip"
        guard let url = URL(string: urlStr) else { fail(); return }
        downloadTask = URLSession.shared.downloadTask(with: url) { [weak self] tmp, response, err in
            // URLSession deletes `tmp` once this handler returns — move it synchronously first.
            var savedZip: URL?
            if let tmp, err == nil, (response as? HTTPURLResponse)?.statusCode == 200 {
                let dst = URL(fileURLWithPath: NSTemporaryDirectory())
                    .appendingPathComponent("docucam-update-\(version).zip")
                try? FileManager.default.removeItem(at: dst)
                if (try? FileManager.default.moveItem(at: tmp, to: dst)) != nil { savedZip = dst }
            }
            DispatchQueue.main.async {
                guard let self, !self.cancelled else { return }
                guard let zip = savedZip else { self.fail(); return }
                self.statusLabel?.stringValue = "Installing…"
                let oldPID = ProcessInfo.processInfo.processIdentifier
                DispatchQueue.global(qos: .userInitiated).async {
                    let ok = Self.applyUpdate(from: zip, version: version, oldPID: oldPID)
                    DispatchQueue.main.async {
                        guard !self.cancelled else { return }
                        if ok {
                            self.statusLabel?.stringValue = "Relaunching…"
                            self.progressBar?.isHidden = true
                            NSApp.terminate(nil)   // the script waits for us to exit, then swaps + relaunches
                        } else { self.fail() }
                    }
                }
            }
        }
        downloadTask?.resume()
    }

    /// Unzip, then hand off to a detached shell script that swaps the bundle on the same
    /// volume (atomic rename, restore-on-failure) and relaunches once we've quit.
    private static func applyUpdate(from zip: URL, version: String, oldPID: Int32) -> Bool {
        let fm = FileManager.default
        let cur = Bundle.main.bundlePath
        let parent = (cur as NSString).deletingLastPathComponent
        guard fm.isWritableFile(atPath: parent) else { return false }   // e.g. not admin, or read-only volume

        let tmp = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("docucam-update-\(version)")
        try? fm.removeItem(at: tmp)
        guard (try? fm.createDirectory(at: tmp, withIntermediateDirectories: true)) != nil else { return false }

        let uz = Process()
        uz.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        uz.arguments = ["-x", "-k", zip.path, tmp.path]
        guard (try? uz.run()) != nil else { return false }
        uz.waitUntilExit()
        guard uz.terminationStatus == 0 else { return false }

        // Find the .app inside the extraction (don't assume the exact folder name).
        guard let appName = (try? fm.contentsOfDirectory(atPath: tmp.path))?.first(where: { $0.hasSuffix(".app") })
        else { return false }
        let newApp = tmp.appendingPathComponent(appName)

        let staging = parent + "/.DocuCam-update-new"
        let backup  = parent + "/.DocuCam-update-old"
        // No `set -e`: each step guards itself and restores the original bundle on any failure.
        let script = """
        #!/bin/bash
        while kill -0 \(oldPID) 2>/dev/null; do sleep 0.1; done   # wait for the old app to fully quit
        rm -rf \(staging.shellQuoted) \(backup.shellQuoted)
        /usr/bin/ditto \(newApp.path.shellQuoted) \(staging.shellQuoted) || { open \(cur.shellQuoted); exit 1; }
        mv \(cur.shellQuoted) \(backup.shellQuoted) || { rm -rf \(staging.shellQuoted); open \(cur.shellQuoted); exit 1; }
        mv \(staging.shellQuoted) \(cur.shellQuoted) || { mv \(backup.shellQuoted) \(cur.shellQuoted); open \(cur.shellQuoted); exit 1; }
        rm -rf \(backup.shellQuoted)
        open \(cur.shellQuoted)
        rm -rf \(tmp.path.shellQuoted)
        """
        let scriptURL = tmp.appendingPathComponent("install.sh")
        guard (try? script.write(to: scriptURL, atomically: true, encoding: .utf8)) != nil else { return false }
        try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptURL.path)

        let installer = Process()
        installer.executableURL = URL(fileURLWithPath: "/bin/bash")
        installer.arguments = [scriptURL.path]
        guard (try? installer.run()) != nil else { return false }
        return true
    }

    private func showProgress(version: String) {
        let W: CGFloat = 300
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: W, height: 110),
                         styleMask: [.titled, .closable, .fullSizeContentView],
                         backing: .buffered, defer: false)
        w.title = ""; w.titleVisibility = .hidden; w.titlebarAppearsTransparent = true
        w.isReleasedWhenClosed = false; w.level = .floating; w.delegate = self
        let root = NSStackView()
        root.orientation = .vertical; root.spacing = 10; root.alignment = .centerX
        root.edgeInsets = NSEdgeInsets(top: 20, left: 20, bottom: 16, right: 20)
        root.translatesAutoresizingMaskIntoConstraints = false
        w.contentView?.addSubview(root)
        NSLayoutConstraint.activate([
            root.topAnchor.constraint(equalTo: w.contentView!.topAnchor),
            root.leadingAnchor.constraint(equalTo: w.contentView!.leadingAnchor),
            root.trailingAnchor.constraint(equalTo: w.contentView!.trailingAnchor),
            root.bottomAnchor.constraint(equalTo: w.contentView!.bottomAnchor),
        ])
        let title = NSTextField(labelWithString: "Updating to \(appName) \(version)…")
        title.font = .systemFont(ofSize: 13, weight: .semibold)
        root.addArrangedSubview(title)
        let bar = NSProgressIndicator()
        bar.style = .bar; bar.isIndeterminate = true; bar.startAnimation(nil)
        bar.translatesAutoresizingMaskIntoConstraints = false
        bar.widthAnchor.constraint(equalToConstant: W - 40).isActive = true
        root.addArrangedSubview(bar); progressBar = bar
        let lbl = NSTextField(labelWithString: "Downloading…")
        lbl.font = .systemFont(ofSize: 11); lbl.textColor = .secondaryLabelColor
        root.addArrangedSubview(lbl); statusLabel = lbl
        let cancel = NSButton(title: "Cancel", target: self, action: #selector(cancelTapped))
        cancel.bezelStyle = .rounded
        root.addArrangedSubview(cancel)
        window = w
        w.center(); w.makeKeyAndOrderFront(nil)
        if #available(macOS 14.0, *) { NSApp.activate() } else { NSApp.activate(ignoringOtherApps: true) }
    }

    private func fail() {
        progressBar?.isHidden = true
        statusLabel?.stringValue = "Update failed — try again later."
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in self?.window?.close() }
    }
    @objc private func cancelTapped() { cancelled = true; downloadTask?.cancel(); window?.close() }
    func windowWillClose(_ n: Notification) { window = nil }
}

private extension String {
    /// Wraps a path in single quotes for safe shell interpolation.
    var shellQuoted: String { "'" + replacingOccurrences(of: "'", with: "'\\''") + "'" }
}

#endif  // !APP_STORE

// MARK: - StoreKit subscription + paywall (App Store build only)

#if APP_STORE
import StoreKit
import WebKit

let subProductIDs = ["com.emerytech.BlueBirdDocuCam.yearly", "com.emerytech.BlueBirdDocuCam.monthly"]
let lifetimeProductID = "com.emerytech.BlueBirdDocuCam.lifetime"   // non-consumable: buy once, own forever

/// Subscription state. Plain class (not @MainActor) so the AppKit AppDelegate can touch it
/// freely; all published state is written back on the main actor, where the UI reads it.
final class Store {
    static let shared = Store()
    private(set) var products: [Product] = []
    private(set) var countryCode: String?
    private(set) var lifetimeProduct: Product?
    private(set) var eligibleIntroIDs = Set<String>()
    private(set) var isUnlocked = false
    private(set) var ownsLifetime = false
    private(set) var trialEnd: Date?
    private(set) var renews = false
    private(set) var billingIssue = false
    private(set) var summary = "Checking your App Store subscription…"
    var onChange: (() -> Void)?
    private var saleDayObserver: NSObjectProtocol?
    private var updatesTask: Task<Void, Never>?
    private var refreshInFlight = false
    private var refreshAgain = false
    private var restoring = false

    func start() {
        UNUserNotificationCenter.current().delegate = TrialReminder.shared
        updatesTask = Task { [weak self] in
            for await update in Transaction.updates {
                if case .verified(let t) = update, subProductIDs.contains(t.productID) || t.productID == lifetimeProductID {
                    await t.finish()
                }
                await self?.refresh()
            }
        }
        saleDayObserver = NotificationCenter.default.addObserver(forName: .NSCalendarDayChanged, object: nil, queue: .main) { [weak self] _ in
            Task { await self?.loadProducts() }
        }
        Task { await loadProducts(); await refresh() }
    }
    func loadProducts() async {
        let country = await Storefront.current?.countryCode
        let all = (try? await Product.products(for: subProductIDs + [lifetimeProductID])) ?? []
        let subs = all.filter { subProductIDs.contains($0.id) }.sorted { $0.price < $1.price }
        let life = all.first { $0.id == lifetimeProductID }
        var eligible = Set<String>()
        for p in subs { if let s = p.subscription, await s.isEligibleForIntroOffer { eligible.insert(p.id) } }
        let ids = eligible
        await MainActor.run { self.countryCode = country; self.products = subs; self.lifetimeProduct = life; self.eligibleIntroIDs = ids; self.onChange?() }
    }
    func refresh() async {
        // Serialize refreshes; rerun if a transaction arrives during a refresh.
        let mayRun = await MainActor.run { () -> Bool in
            if self.refreshInFlight { self.refreshAgain = true; return false }
            self.refreshInFlight = true; return true
        }
        guard mayRun else { return }
        var active = false, lifetime = false
        var end: Date?, renewal = false, issue = false
        var text = "No active subscription found. Restore purchases if you have already subscribed."
        for await result in Transaction.currentEntitlements {
            guard case .verified(let t) = result, t.revocationDate == nil else { continue }
            if t.productID == lifetimeProductID { active = true; lifetime = true }
            else if subProductIDs.contains(t.productID), let exp = t.expirationDate, exp > Date() { active = true }
        }
        // Status and renewal information must BOTH be verified before granting grace-period access
        // or describing renewal settings. Deduplicate the subscription group across products.
        var groups = Set<String>()
        let products = await MainActor.run { self.products }
        for p in products {
            guard let info = p.subscription, groups.insert(info.subscriptionGroupID).inserted,
                  let statuses = try? await info.status else { continue }
            for status in statuses {
                guard case .verified(let t) = status.transaction,
                      case .verified(let r) = status.renewalInfo,
                      subProductIDs.contains(t.productID), t.revocationDate == nil else { continue }
                let isActive = status.state == .subscribed && (t.expirationDate ?? .distantPast) > Date()
                let inGrace = status.state == .inGracePeriod && (r.gracePeriodExpirationDate ?? .distantPast) > Date()
                if inGrace {
                    active = true; issue = true
                    text = "Payment needs attention. Access continues through Apple's billing grace period until \(Self.date(r.gracePeriodExpirationDate!)). Update your payment method to avoid interruption."
                } else if isActive {
                    active = true; renewal = r.willAutoRenew
                    let freeTrial: Bool
                    if #available(macOS 14.2, *) { freeTrial = t.offer?.paymentMode == .freeTrial }
                    else { freeTrial = t.offerPaymentModeStringRepresentation == "FREE_TRIAL" }
                    let exp = t.expirationDate!
                    if freeTrial { end = exp }
                    var terms = "See Apple’s subscription settings for your renewal price."
                    if let amount = r.renewalPrice, let currency = r.currency,
                       let product = products.first(where: { $0.id == (r.autoRenewPreference ?? t.productID) }),
                       let period = product.subscription?.subscriptionPeriod {
                        terms = "\(amount.formatted(.currency(code: currency.identifier))) / \(Self.period(period))"
                    }
                    text = freeTrial ? "Your free trial ends \(Self.date(exp))." : "Subscription access through \(Self.date(exp))."
                    text += r.willAutoRenew ? "\nRenews automatically: \(terms). Apple confirms the final renewal terms." : "\nAuto-renew is off. Access continues until the date above; no renewal is scheduled."
                } else if status.state == .inBillingRetryPeriod {
                    issue = true
                    if !active { text = "Apple could not renew your subscription. Update your payment method, then refresh your status. Access resumes when Apple confirms payment." }
                }
            }
        }
        if lifetime { end = nil; issue = false; text = "Lifetime unlock owned. No subscription renewal is required." }
        else if active && text.hasPrefix("No active") { text = "Your subscription is active. Renewal details are temporarily unavailable; check Apple's subscription settings." }
        let unlocked = active, lifeOwned = lifetime, trial = end, willRenew = renewal, needsPayment = issue, message = text
        let rerun = await MainActor.run { () -> Bool in
            self.isUnlocked = unlocked; self.ownsLifetime = lifeOwned; self.trialEnd = trial; self.renews = willRenew
            self.billingIssue = needsPayment; self.summary = message
            TrialReminder.shared.sync(end: willRenew ? trial : nil)
            SubscriptionWindow.shared.refreshIfVisible()
            self.onChange?()
            self.refreshInFlight = false
            let again = self.refreshAgain; self.refreshAgain = false
            return again
        }
        if rerun { await refresh() }
    }
    static func date(_ d: Date) -> String { d.formatted(date: .abbreviated, time: .omitted) }
    static func period(_ p: Product.SubscriptionPeriod) -> String {
        let unit: String
        switch p.unit { case .day: unit = "day"; case .week: unit = "week"; case .month: unit = "month"; case .year: unit = "year"; @unknown default: unit = "period" }
        return "\(p.value) \(unit)\(p.value == 1 ? "" : "s")"
    }
    static func recurringPrice(_ p: Product) -> String {
        guard let s = p.subscription else { return p.displayPrice }
        return "\(p.displayPrice) / \(period(s.subscriptionPeriod))"
    }
    func planTitle(_ p: Product) -> String {
        let price = Self.recurringPrice(p)
        if eligibleIntroIDs.contains(p.id), let intro = p.subscription?.introductoryOffer, intro.paymentMode == .freeTrial {
            return "\(Self.period(intro.period)) free — then \(price)"
        }
        return "Subscribe — \(price)"
    }
    @discardableResult
    func purchase(_ product: Product) async -> Bool {
        guard let result = try? await product.purchase() else { return false }
        if case .success(let verification) = result, case .verified(let t) = verification {
            await t.finish(); await loadProducts(); await refresh(); return true
        }
        return false
    }
    func restore() async {
        let progress = await MainActor.run { () -> NSPanel? in
            guard !self.restoring else { return nil }
            self.restoring = true
            let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 360, height: 100), styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
            panel.title = "Restore Purchases"; panel.isReleasedWhenClosed = false; panel.level = .normal
            let label = NSTextField(labelWithString: "Checking purchases with Apple…")
            label.frame = NSRect(x: 54, y: 40, width: 290, height: 20)
            let spinner = NSProgressIndicator(frame: NSRect(x: 22, y: 39, width: 20, height: 20))
            spinner.style = .spinning; spinner.startAnimation(nil)
            panel.contentView?.addSubview(label); panel.contentView?.addSubview(spinner)
            panel.center(); panel.makeKeyAndOrderFront(nil)
            return panel
        }
        guard let progress else { return }
        var syncError: Error?
        do { try await AppStore.sync() } catch { syncError = error }
        await loadProducts(); await refresh()
        while await MainActor.run(body: { self.refreshInFlight }) {
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        let error = syncError
        await MainActor.run {
            progress.close(); self.restoring = false
            let alert = NSAlert()
            if let error {
                alert.messageText = "Purchases could not be restored"
                alert.informativeText = "Apple could not complete the restore. \(error.localizedDescription)\n\nTry again using the Apple Account that redeemed your code or made the purchase. TestFlight uses separate test purchases."
            } else if self.isUnlocked {
                alert.messageText = "Purchases restored"
                alert.informativeText = self.ownsLifetime ? "Your lifetime unlock is available on this Mac." : "Your subscription access is available on this Mac."
            } else {
                alert.messageText = "No active purchase found"
                alert.informativeText = "Apple finished checking, but returned no active subscription or lifetime unlock for this app.\n\nIf you are using TestFlight, App Store purchases and redeemed unlock codes do not carry over to the test environment. Make a separate purchase inside the TestFlight app to test access; Apple does not charge for TestFlight purchases. Your App Store unlock remains separate.\n\nIn the public App Store app, use the Apple Account that redeemed the code or made the purchase."
            }
            RestoreResultWindow.shared.show(title: alert.messageText, message: alert.informativeText)
        }
    }
}

/// Blocks the app until it's unlocked — an active subscription (a free trial counts) or the
/// one-time lifetime purchase.
final class Paywall: NSObject, NSWindowDelegate, WKNavigationDelegate {
    static let shared = Paywall()
    private var window: NSWindow?
    private var dismissed = false

    func show(userInitiated: Bool = true) {
        guard userInitiated || !dismissed else { return }
        if userInitiated { dismissed = false }
        let w = window ?? makeWindow()
        if w.isMiniaturized { w.deminiaturize(nil) }
        buildBody(in: w)                 // rebuild each time so it reflects loaded products / state
        window = w
        w.center(); w.makeKeyAndOrderFront(nil)
        if #available(macOS 14.0, *) { NSApp.activate() } else { NSApp.activate(ignoringOtherApps: true) }
    }
    func close() { dismissed = false; window?.orderOut(nil) }

    private func makeWindow() -> NSWindow {
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 420, height: 470),
                         styleMask: [.titled, .closable, .miniaturizable, .fullSizeContentView], backing: .buffered, defer: false)
        w.titleVisibility = .hidden; w.titlebarAppearsTransparent = true
        w.isReleasedWhenClosed = false; w.level = .normal; w.delegate = self
        return w
    }
    private struct Offer: Decodable { let sale: String?; let regular: String? }
    private struct Territory: Decodable {
        let currency: String
        let monthly: Offer?
        let yearly: Offer?
        let lifetime: Offer?
    }
    private static let references: [String: Territory] = {
        guard let url = Bundle.main.url(forResource: "black-friday-2026", withExtension: "json"),
              let data = try? Data(contentsOf: url) else { return [:] }
        return (try? JSONDecoder().decode([String: Territory].self, from: data)) ?? [:]
    }()
    private var web: WKWebView?
    private static let css = Bundle.main.url(forResource: "paywall", withExtension: "css")
        .flatMap { try? String(contentsOf: $0, encoding: .utf8) } ?? ""
    private static let icon = Bundle.main.url(forResource: "app-icon", withExtension: "png")
        .flatMap { try? Data(contentsOf: $0) }?.base64EncodedString() ?? ""

    private func buildBody(in w: NSWindow) {
        guard let cv = w.contentView else { return }
        let view: WKWebView
        if let web { view = web } else {
            let config = WKWebViewConfiguration()
            config.websiteDataStore = .nonPersistent()
            config.defaultWebpagePreferences.allowsContentJavaScript = false
            view = WKWebView(frame: cv.bounds, configuration: config)
            view.autoresizingMask = [.width, .height]
            view.navigationDelegate = self
            cv.addSubview(view)
            web = view
        }
        let day = Calendar(identifier: .gregorian).dateComponents([.year,.month,.day], from: Date())
        let sale = day.year == 2026 && day.month == 11 && (26...30).contains(day.day ?? 0)
        let store = Store.shared
        let products = store.products + [store.lifetimeProduct].compactMap { $0 }
        let territory = Self.references[store.countryCode ?? ""]
        var cards = ""
        for p in products {
            let lifetime = p.id == lifetimeProductID
            let annual = p.id == subProductIDs[0]
            let name = lifetime ? "Lifetime" : annual ? "Annual" : "Monthly"
            let unit = lifetime ? "" : annual ? " / yr" : " / mo"
            let period = annual ? "year" : "month"
            var detail = lifetime ? "One-time purchase" : "Billed every " + period
            var later = ""
            let offer = lifetime ? territory?.lifetime : annual ? territory?.yearly : territory?.monthly
            if sale, (day.day ?? 0) >= (lifetime ? 27 : 28),
               territory?.currency == p.priceFormatStyle.currencyCode,
               let current = offer?.sale.flatMap({ Decimal(string: $0) }), current == p.price,
               let regular = offer?.regular.flatMap({ Decimal(string: $0) }), regular > current {
                let savings = (regular - current).formatted(p.priceFormatStyle)
                detail = "Save " + savings + (lifetime ? " · Pay once" : " per " + period)
                later = "<span class=later>" + regular.formatted(p.priceFormatStyle) + unit + " from Dec 1</span>"
            }
            var action = lifetime ? "Unlock forever" : "Subscribe"
            if store.eligibleIntroIDs.contains(p.id), let intro = p.subscription?.introductoryOffer, intro.paymentMode == .freeTrial {
                action = "Start trial"
                if intro.period.unit == .week && intro.period.value == 2 || intro.period.unit == .day && intro.period.value == 14 {
                    action = "Start 14-day trial"
                } else { detail += " · " + Store.period(intro.period) + " free" }
            }
            cards += """
            <div class=card><div><b>\(name)</b><small>\(detail)</small></div>
            <div><span class=price>\(p.displayPrice)</span>\(unit)\(later)</div>
            <a class=action href="docucam://buy/\(p.id)">\(action)</a></div>
            """
        }
        if cards.isEmpty { cards = "<p>Loading App Store prices…</p><a href='docucam://retry'>Reload plans</a>" }
        let html = """
        <!doctype html><meta charset=utf-8><meta name="color-scheme" content="light">
        <meta http-equiv="Content-Security-Policy" content="default-src 'none'; style-src 'unsafe-inline'; img-src data:">
        <style>\(Self.css)</style><main><header><div class=brand><img alt="" src="data:image/png;base64,\(Self.icon)">BlueBird DocuCam</div>
        <h1>\(sale ? "Black Friday pricing" : "Choose your plan")</h1>
        <p>\(sale ? "Choose your plan by November 30." : "Present, annotate, scan and record on your Mac.")</p></header><article>
        <h2>\(sale ? "Keep your subscription rate" : "Unlock BlueBird DocuCam")</h2>
        <p class=intro>\(sale ? "Subscribe at the sale price and keep that rate while your plan stays active." : "Choose a subscription or get lifetime access with one purchase.")</p>
        \(cards)
        \(sale ? "<p class=legal>December 1 subscription prices apply to new signups. Subscription pricing runs Nov 28–30. Lifetime pricing runs Nov 27–30.</p>" : "")
        <p class=legal>For eligible subscribers, payment starts after the free trial. Otherwise, Apple charges at purchase confirmation. Subscriptions renew automatically unless canceled at least 24 hours before renewal. Manage your subscription in your Apple account settings.</p>
        <div class=links><a href="docucam://restore">Restore Purchases</a><a href="docucam://terms">Terms of Use</a><a href="docucam://privacy">Privacy Policy</a></div></article></main>
        """
        let screen = w.screen?.visibleFrame.size ?? NSScreen.main?.visibleFrame.size ?? NSSize(width: 760, height: 710)
        w.setContentSize(NSSize(width: min(760, screen.width), height: min(sale ? 710 : 650, screen.height)))
        view.loadHTMLString(html, baseURL: nil)
    }

    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        guard let url = action.request.url, action.navigationType == .linkActivated else {
            decisionHandler(action.request.url?.absoluteString == "about:blank" ? .allow : .cancel)
            return
        }
        decisionHandler(.cancel)
        guard url.scheme == "docucam" else { return }
        switch url.host {
        case "restore": restoreTapped()
        case "terms": openTerms()
        case "privacy": openPrivacy()
        case "retry": Task { await Store.shared.loadProducts() }
        case "buy":
            let products = Store.shared.products + [Store.shared.lifetimeProduct].compactMap { $0 }
            if let p = products.first(where: { $0.id == url.lastPathComponent }) {
                Task { _ = await Store.shared.purchase(p) }
            }
        default: break
        }
    }
    @objc private func restoreTapped() { Task { await Store.shared.restore() } }
    @objc private func openTerms() {
        if let u = URL(string: "https://www.apple.com/legal/internet-services/itunes/dev/stdeula/") { NSWorkspace.shared.open(u) }
    }
    @objc private func openPrivacy() {
        if let u = URL(string: "https://emerytech.github.io/bluebird-docucam/privacy.html") { NSWorkspace.shared.open(u) }
    }
    func windowShouldClose(_ sender: NSWindow) -> Bool { dismissed = true; return true }
    func windowDidMiniaturize(_ notification: Notification) { dismissed = true }
    func windowDidDeminiaturize(_ notification: Notification) { dismissed = false }
}
#endif  // APP_STORE

// MARK: - First lesson and local classroom presets

// Shared with the existing About/Settings visual language: Brand.blue, system typography,
// compact section labels, native controls, and 24-point horizontal margins.
private enum RetentionUI {
    static let windowWidth: CGFloat = 500
    static let width: CGFloat = windowWidth - 48

    static func text(_ string: String, width: CGFloat = width, size: CGFloat = 13,
                     weight: NSFont.Weight = .regular, color: NSColor = .labelColor) -> NSTextField {
        let label = NSTextField(wrappingLabelWithString: string)
        label.font = .systemFont(ofSize: size, weight: weight); label.textColor = color
        label.preferredMaxLayoutWidth = width
        label.translatesAutoresizingMaskIntoConstraints = false
        let attributed = NSAttributedString(string: string, attributes: [.font: label.font!])
        let measured = attributed.boundingRect(with: NSSize(width: width - 4, height: 10000), options: [.usesLineFragmentOrigin, .usesFontLeading])
        NSLayoutConstraint.activate([label.widthAnchor.constraint(equalToConstant: width),
                                     label.heightAnchor.constraint(equalToConstant: ceil(measured.height) + 4)])
        return label
    }
    static func stack(_ views: [NSView], width: CGFloat = width, spacing: CGFloat = 10) -> NSStackView {
        let stack = NSStackView(views: views); stack.orientation = .vertical
        stack.alignment = .leading; stack.spacing = spacing
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.widthAnchor.constraint(equalToConstant: width).isActive = true
        return stack
    }
    static func header(_ title: String, subtitle: String) -> NSView {
        let icon = NSImageView(); icon.image = NSApp.applicationIconImage
        icon.imageScaling = .scaleProportionallyUpOrDown
        NSLayoutConstraint.activate([icon.widthAnchor.constraint(equalToConstant: 44), icon.heightAnchor.constraint(equalToConstant: 44)])
        icon.setAccessibilityElement(false)
        let labels = stack([text(title, width: width - 58, size: 22, weight: .bold, color: Brand.blue),
                            text(subtitle, width: width - 58, size: 12, color: .secondaryLabelColor)], width: width - 58, spacing: 2)
        let row = NSStackView(views: [icon, labels]); row.orientation = .horizontal; row.alignment = .centerY; row.spacing = 14
        row.widthAnchor.constraint(equalToConstant: width).isActive = true
        return row
    }
    static func section(_ title: String) -> NSTextField { text(title, size: 10, weight: .semibold, color: Brand.blue) }
    static func founderNote(width: CGFloat = width, target: AnyObject, action: Selector) -> NSView {
        let heading = text("A NOTE FROM TAYLOR", width: width, size: 10, weight: .semibold, color: Brand.blue)
        let message = text("Hi, I’m Taylor. I built BlueBird DocuCam for our Science Department, and they enjoyed using it so much that I decided to share it with other classrooms.\n\nI’d love to hear how it works for you. If you have a suggestion, a feature idea, or something isn’t working, I’m all ears.", width: width, size: 12, color: .secondaryLabelColor)
        return stack([heading, message, link("Send Taylor Feedback", target: target, action: action)], width: width, spacing: 8)
    }
    static func separator() -> NSView {
        let line = NSBox(); line.boxType = .separator
        line.widthAnchor.constraint(equalToConstant: width).isActive = true
        return line
    }
    static func button(_ title: String, target: AnyObject, action: Selector, primary: Bool = false) -> NSButton {
        let button = NSButton(title: title, target: target, action: action)
        button.bezelStyle = .rounded; button.font = .systemFont(ofSize: 13, weight: primary ? .semibold : .regular)
        if primary {
            button.controlSize = .large; button.bezelColor = Brand.blue
            button.attributedTitle = NSAttributedString(string: title, attributes: [.font: NSFont.systemFont(ofSize: 13, weight: .semibold), .foregroundColor: NSColor.white])
        }
        return button
    }
    static func link(_ title: String, target: AnyObject, action: Selector) -> NSButton {
        let button = NSButton(title: title, target: target, action: action)
        button.isBordered = false; button.bezelStyle = .inline
        button.font = .systemFont(ofSize: 12, weight: .medium); button.contentTintColor = Brand.blue
        return button
    }
    static func actions(left: [NSView], right: [NSView]) -> NSView {
        let spacer = NSView(); spacer.setContentHuggingPriority(NSLayoutConstraint.Priority(1), for: .horizontal)
        let row = NSStackView(views: left + [spacer] + right)
        row.orientation = .horizontal; row.alignment = .centerY; row.spacing = 12
        row.widthAnchor.constraint(equalToConstant: width).isActive = true
        return row
    }
    static func install(_ views: [NSView], in window: NSWindow) {
        let root = NSStackView(views: views); root.orientation = .vertical; root.alignment = .leading; root.spacing = 16
        root.edgeInsets = NSEdgeInsets(top: 24, left: 24, bottom: 20, right: 24)
        root.translatesAutoresizingMaskIntoConstraints = false
        let content = window.contentView!
        content.subviews.forEach { $0.removeFromSuperview() }; content.addSubview(root)
        NSLayoutConstraint.activate([root.leadingAnchor.constraint(equalTo: content.leadingAnchor),
                                     root.trailingAnchor.constraint(equalTo: content.trailingAnchor), root.topAnchor.constraint(equalTo: content.topAnchor)])
        window.setContentSize(NSSize(width: windowWidth, height: 400))
        window.layoutIfNeeded()
        window.setContentSize(NSSize(width: windowWidth, height: ceil(root.fittingSize.height)))
    }
}

#if APP_STORE
/// Modeless result: users can close, minimize, switch apps or dismiss with OK.
final class RestoreResultWindow: NSObject {
    static let shared = RestoreResultWindow()
    private var window: NSWindow?
    func show(title: String, message: String) {
        let w = window ?? NSWindow(contentRect: NSRect(x: 0, y: 0, width: RetentionUI.windowWidth, height: 300), styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
        w.title = "Restore Purchases"; w.isReleasedWhenClosed = false
        let done = RetentionUI.button("OK", target: self, action: #selector(dismiss), primary: true)
        done.keyEquivalent = "\r"
        RetentionUI.install([RetentionUI.text(title, size: 18, weight: .semibold),
            RetentionUI.text(message), RetentionUI.actions(left: [], right: [done])], in: w)
        let isNew = window == nil; window = w
        if isNew { w.center() }; if w.isMiniaturized { w.deminiaturize(nil) }
        w.makeKeyAndOrderFront(nil)
    }
    @objc private func dismiss() { window?.close() }
}
#endif

final class GettingStarted: NSObject {
    static let shared = GettingStarted()
    private var window: NSPanel?
    private var stepIcons: [NSImageView] = []
    private var actions: [() -> Void] = []
    var progress: LessonProgress {
        get { UserDefaults.standard.data(forKey: "lessonProgress").flatMap { try? JSONDecoder().decode(LessonProgress.self, from: $0) } ?? LessonProgress() }
        set { UserDefaults.standard.set(try? JSONEncoder().encode(newValue), forKey: "lessonProgress"); refresh() }
    }
    func record(camera: Bool = false, presentation: Bool = false, saved: Bool = false) {
        var p = progress; p.sawCamera = p.sawCamera || camera; p.presented = p.presented || presentation; p.savedWork = p.savedWork || saved
        if p != progress { progress = p }
    }
    func show(actions: [() -> Void]) {
        self.actions = actions; UserDefaults.standard.set(true, forKey: "gettingStartedSeen")
        if let w = window { refresh(); w.makeKeyAndOrderFront(nil); return }
        let w = NSPanel(contentRect: NSRect(x: 0, y: 0, width: RetentionUI.windowWidth, height: 430), styleMask: [.titled, .closable, .utilityWindow], backing: .buffered, defer: false)
        w.title = "\(appName) — Getting Started"; w.isReleasedWhenClosed = false; w.hidesOnDeactivate = true
        stepIcons = []
        let connect = step("Connect your camera", detail: "Use a USB camera or a nearby iPhone.", buttons: [("Choose…", 0)], controlsWidth: 92)
        let present = step("Present to your class", detail: "Use full screen for your projector.", buttons: [("Present", 1)], controlsWidth: 92)
        let save = step("Save a useful result", detail: "Add a page, then save your scan as a PDF.", buttons: [("Add Page", 2), ("Save PDF…", 3)], controlsWidth: 170)
        let steps = RetentionUI.stack([connect, RetentionUI.separator(), present, RetentionUI.separator(), save], spacing: 14)
        let tips = RetentionUI.stack([RetentionUI.section("QUICK TIPS"),
            RetentionUI.text("Space freezes the page. Scroll to zoom. For a narrated lesson, choose Capture → Start Recording.", size: 12, color: .secondaryLabelColor),
            RetentionUI.text("Keep your setup in View → Classroom Presets. This checklist is always available in Help.", size: 12, color: .secondaryLabelColor)], spacing: 6)
        let done = RetentionUI.button("Done", target: self, action: #selector(close), primary: true); done.keyEquivalent = "\r"
        RetentionUI.install([RetentionUI.header("Your first lesson", subtitle: "Three steps to get ready for class."),
            RetentionUI.section("GET STARTED"), steps, tips, RetentionUI.separator(),
            RetentionUI.founderNote(target: self, action: #selector(sendTaylorFeedback)),
            RetentionUI.actions(left: [RetentionUI.link("Camera setup help…", target: self, action: #selector(cameraHelp))], right: [done])], in: w)
        window = w; refresh(); w.center(); w.makeKeyAndOrderFront(nil)
    }
    private func step(_ title: String, detail: String, buttons: [(String, Int)], controlsWidth: CGFloat) -> NSView {
        let icon = NSImageView(); icon.imageScaling = .scaleProportionallyUpOrDown
        NSLayoutConstraint.activate([icon.widthAnchor.constraint(equalToConstant: 20), icon.heightAnchor.constraint(equalToConstant: 20)])
        stepIcons.append(icon)
        let textWidth = RetentionUI.width - 20 - 24 - controlsWidth
        let labels = RetentionUI.stack([RetentionUI.text(title, width: textWidth, weight: .medium),
            RetentionUI.text(detail, width: textWidth, size: 11, color: .secondaryLabelColor)], width: textWidth, spacing: 2)
        let controls = NSStackView(views: buttons.map { title, index in
            let b = RetentionUI.button(title, target: self, action: #selector(runStep(_:))); b.tag = index; return b
        })
        controls.orientation = .horizontal; controls.spacing = 6
        controls.widthAnchor.constraint(equalToConstant: controlsWidth).isActive = true
        let row = NSStackView(views: [icon, labels, controls]); row.orientation = .horizontal; row.alignment = .centerY; row.spacing = 12
        row.widthAnchor.constraint(equalToConstant: RetentionUI.width).isActive = true
        return row
    }
    private func refresh() {
        let p = progress
        for (i, complete) in [p.sawCamera, p.presented, p.savedWork].enumerated() where stepIcons.indices.contains(i) {
            stepIcons[i].image = NSImage(systemSymbolName: complete ? "checkmark.circle.fill" : "circle", accessibilityDescription: complete ? "Completed" : "Not completed")
            stepIcons[i].contentTintColor = complete ? .systemGreen : .tertiaryLabelColor
        }
    }
    @objc private func runStep(_ sender: NSButton) { if actions.indices.contains(sender.tag) { actions[sender.tag]() } }
    @objc private func sendTaylorFeedback() { window?.orderOut(nil); FeedbackWindow.shared.show() }
    @objc private func close() { window?.orderOut(nil) }
    @objc private func cameraHelp() {
        let alert = NSAlert(); alert.messageText = "Connect a document camera"
        alert.informativeText = "Plug in a USB camera, then use Choose to select it.\n\nFor Continuity Camera, bring your iPhone near this Mac. Both devices need Wi-Fi and Bluetooth enabled and the same Apple Account.\n\nIf camera access is denied, allow DocuCam in System Settings → Privacy & Security → Camera."
        alert.addButton(withTitle: "Got It"); alert.runModal()
    }
}

final class FeedbackWindow: NSObject {
    static let shared = FeedbackWindow()
    private var window: NSWindow?
    private var reason: NSPopUpButton!
    func show() {
        if let w = window { w.makeKeyAndOrderFront(nil); return }
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: RetentionUI.windowWidth, height: 300), styleMask: [.titled, .closable], backing: .buffered, defer: false)
        w.title = "\(appName) — Feedback"; w.isReleasedWhenClosed = false
        reason = NSPopUpButton(); reason.addItems(withTitles: ["Trouble connecting or setting up", "Missing a feature I need", "Price / subscription preference", "No longer need a document camera", "Other"])
        reason.widthAnchor.constraint(equalToConstant: RetentionUI.width).isActive = true
        reason.setAccessibilityLabel("Main reason for feedback")
        let experience = RetentionUI.stack([RetentionUI.section("YOUR EXPERIENCE"),
            RetentionUI.text("What could work better for you?", weight: .medium), reason,
            RetentionUI.text("Sharing feedback is optional and does not change or cancel your subscription.", size: 12, color: .secondaryLabelColor)], spacing: 8)
        let email = RetentionUI.button("Create Email…", target: self, action: #selector(compose), primary: true)
        let cancel = RetentionUI.button("Not Now", target: self, action: #selector(close)); cancel.keyEquivalent = "\u{1b}"
        RetentionUI.install([RetentionUI.header("Help improve DocuCam", subtitle: "Tell us what would make a difference."), experience,
            RetentionUI.separator(),
            RetentionUI.text("Nothing is sent automatically. Review and send the draft in your email app, which may include your address and signature.", size: 11, color: .secondaryLabelColor),
            RetentionUI.actions(left: [], right: [cancel, email])], in: w)
        window = w; w.center(); w.makeKeyAndOrderFront(nil)
    }
    @objc private func close() { window?.orderOut(nil) }
    @objc private func compose() {
        var url = URLComponents(); url.scheme = "mailto"; url.path = "admin@emerytechsolutions.com"
        url.queryItems = [URLQueryItem(name: "subject", value: "DocuCam feedback"), URLQueryItem(name: "body", value: "Main reason: \(reason.titleOfSelectedItem ?? "Other")\n\nOptional details:\n")]
        if let u = url.url, NSWorkspace.shared.open(u) { window?.orderOut(nil) }
        else { let a = NSAlert(); a.messageText = "Could not open an email app"; a.informativeText = "You can email feedback to admin@emerytechsolutions.com."; a.runModal() }
    }
}

#if APP_STORE
import UserNotifications

final class TrialReminder: NSObject, UNUserNotificationCenterDelegate {
    static let shared = TrialReminder()
    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification, withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound])
    }
    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse, withCompletionHandler completionHandler: @escaping () -> Void) {
        DispatchQueue.main.async { SubscriptionWindow.shared.show(); Task { await Store.shared.refresh() } }
        completionHandler()
    }
    private var generation = 0
    private var scheduledKey: String?
    var enabled: Bool { UserDefaults.standard.bool(forKey: "trialReminderEnabled") }
    func setEnabled(_ on: Bool) { UserDefaults.standard.set(on, forKey: "trialReminderEnabled"); scheduledKey = nil; sync(end: Store.shared.renews ? Store.shared.trialEnd : nil) }
    func sync(end: Date?) {
        let key = "\(enabled)-\(end?.timeIntervalSince1970 ?? 0)"
        guard key != scheduledKey else { return }
        scheduledKey = key; generation += 1; let version = generation
        Task { @MainActor in
            let center = UNUserNotificationCenter.current()
            let pending = await center.pendingNotificationRequests()
            guard version == self.generation else { return }
            center.removePendingNotificationRequests(withIdentifiers: pending.filter { $0.identifier.hasPrefix("docucam.trial.") }.map(\.identifier))
            guard self.enabled, let end, let fire = TrialReminderPolicy.fireDate(end: end) else { return }
            let settings = await center.notificationSettings()
            guard version == self.generation else { return }
            guard settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional else {
                self.scheduledKey = nil; return
            }
            let content = UNMutableNotificationContent()
            content.title = "Your DocuCam trial ends soon"
            content.body = "Your trial ends \(Store.date(end)). Check Subscription & Trial in DocuCam for renewal terms. Try saving a scan or recording before then."
            content.sound = .default
            let id = "docucam.trial.\(UUID().uuidString)"
            let trigger = UNTimeIntervalNotificationTrigger(timeInterval: max(1, fire.timeIntervalSinceNow), repeats: false)
            do {
                try await center.add(UNNotificationRequest(identifier: id, content: content, trigger: trigger))
                if version != self.generation { center.removePendingNotificationRequests(withIdentifiers: [id]) }
            } catch { self.scheduledKey = nil }
        }
    }
}

final class SubscriptionWindow: NSObject {
    static let shared = SubscriptionWindow()
    private var window: NSWindow?
    func refreshIfVisible() { if window?.isVisible == true { show(bringToFront: false) } }
    func show(bringToFront: Bool = true) {
        let w = window ?? NSWindow(contentRect: NSRect(x: 0, y: 0, width: RetentionUI.windowWidth, height: 360), styleMask: [.titled, .closable], backing: .buffered, defer: false)
        w.title = "\(appName) — Subscription & Trial"; w.isReleasedWhenClosed = false
        let store = Store.shared
        let statusTitle = store.ownsLifetime ? "LIFETIME UNLOCK" : store.billingIssue ? "PAYMENT NEEDS ATTENTION" : store.trialEnd != nil ? "FREE TRIAL" : store.isUnlocked ? "SUBSCRIPTION ACTIVE" : "SUBSCRIPTION STATUS"
        let statusHeader = RetentionUI.section(statusTitle)
        if store.billingIssue { statusHeader.textColor = .systemOrange }
        var statusViews: [NSView] = [statusHeader, RetentionUI.text(store.summary)]
        if store.billingIssue {
            statusViews.append(RetentionUI.button("Update Payment Method…", target: self, action: #selector(payment), primary: true))
        }
        var views: [NSView] = [RetentionUI.header("Subscription & Trial", subtitle: "Your plan, renewal and payment settings."), RetentionUI.stack(statusViews, spacing: 8)]
        if (store.trialEnd != nil && store.renews) || TrialReminder.shared.enabled {
            let toggle = NSSwitch(); toggle.target = self; toggle.action = #selector(remind(_:))
            toggle.state = TrialReminder.shared.enabled ? .on : .off
            toggle.setAccessibilityLabel("Remind me before my trial ends")
            let row = RetentionUI.actions(left: [RetentionUI.text("Remind me before my trial ends", width: 350)], right: [toggle])
            views.append(RetentionUI.stack([RetentionUI.section("TRIAL REMINDER"), row,
                RetentionUI.text("An optional notification on this Mac, about two days before your trial ends.", size: 12, color: .secondaryLabelColor)], spacing: 8))
        }
        views.append(RetentionUI.separator())
        var secondary: [NSView] = []
        if store.isUnlocked && !store.ownsLifetime {
            secondary.append(RetentionUI.link("Take a break…", target: self, action: #selector(takeBreak)))
        }
        let manage = RetentionUI.button("Manage Subscription…", target: self, action: #selector(manage), primary: !store.billingIssue)
        views.append(RetentionUI.actions(left: secondary, right: [manage]))
        views.append(RetentionUI.text("Manage, cancel or resubscribe in Apple's settings. Changes made on another device appear after you refresh.", size: 11, color: .secondaryLabelColor))
        views.append(RetentionUI.actions(left: [RetentionUI.link("Share Feedback…", target: self, action: #selector(feedback))], right: [RetentionUI.link("Refresh Status", target: self, action: #selector(refresh))]))
        RetentionUI.install(views, in: w)
        let isNew = window == nil; window = w; if isNew { w.center() }
        if bringToFront {
            w.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
            w.makeKeyAndOrderFront(nil)
            if #available(macOS 14.0, *) { NSApp.activate() } else { NSApp.activate(ignoringOtherApps: true) }
        }
    }
    @objc private func takeBreak() {
        let a = NSAlert(); a.messageText = "Take a break from DocuCam"
        a.informativeText = "To stop future charges, turn off renewal in Apple's subscription settings. DocuCam cannot schedule an automatic pause or restart.\n\nApple shows when access ends; canceling a free trial may end access early. Unused time is not refunded or saved for later. Your saved files and classroom presets stay on your Mac.\n\nResubscribe through Apple when you're ready, at the terms shown then. Opening settings alone changes nothing. Return here and refresh to confirm any changes."
        a.addButton(withTitle: "Open Apple Subscription Settings"); a.addButton(withTitle: "Not Now")
        if a.runModal() == .alertFirstButtonReturn { manage() }
    }
    @objc private func manage() { if let u = URL(string: "macappstore://apps.apple.com/account/subscriptions") { NSWorkspace.shared.open(u) } }
    @objc private func payment() { if let u = URL(string: "https://apps.apple.com/account/billing") { NSWorkspace.shared.open(u) } }
    @objc private func refresh() { Task { await Store.shared.loadProducts(); await Store.shared.refresh() } }
    @objc private func feedback() { FeedbackWindow.shared.show() }
    @objc private func remind(_ sender: NSSwitch) {
        if sender.state == .off { TrialReminder.shared.setEnabled(false); return }
        Task { @MainActor in
            do {
                let allowed = try await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])
                TrialReminder.shared.setEnabled(allowed)
                if !allowed { self.notificationError("Notifications are disabled. Enable notifications for DocuCam in System Settings to receive a reminder.") }
            } catch { self.notificationError("A reminder could not be enabled. Try again in System Settings → Notifications.") }
            self.refreshIfVisible()
        }
    }
    private func notificationError(_ text: String) { let a = NSAlert(); a.messageText = "Trial reminder"; a.informativeText = text; a.runModal() }
}
#endif

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

        // ── Support block ──
        let supportBlock: NSStackView
#if APP_STORE
        // App Store build: subscription management, no Ko-fi.
        let manage = linkButton("Manage Subscription", #selector(manageSubscription))
        let restore = linkButton("Restore Purchases", #selector(restorePurchases))
        restore.font = .systemFont(ofSize: 11)
        supportBlock = NSStackView(views: [manage, restore])
#else
        // GitHub build: cosmetic supporter badge (Ko-fi), no feature gating.
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
#endif
        supportBlock.orientation = .vertical
        supportBlock.alignment = .centerX
        supportBlock.spacing = 8

        var aboutItems: [NSView] = [icon, title, version, tagline, supportBlock]
#if !APP_STORE
        let updates = linkButton("Check for Updates…", #selector(checkUpdates))
        aboutItems.append(updates)
#endif

        let sep = NSBox(); sep.boxType = .separator

        let copy = NSTextField(labelWithString: appCopyright)
        copy.font = .systemFont(ofSize: 10)
        copy.textColor = .tertiaryLabelColor
        copy.alignment = .center
        wrap(copy)

        let founder = RetentionUI.founderNote(width: 304, target: self, action: #selector(sendTaylorFeedback))
        let root = NSStackView(views: aboutItems + [founder, sep, copy])
        root.orientation = .vertical
        root.alignment = .centerX
        root.spacing = 8
        root.setCustomSpacing(4, after: title)
        root.setCustomSpacing(18, after: tagline)
        root.setCustomSpacing(18, after: supportBlock)
#if !APP_STORE
        root.setCustomSpacing(18, after: updates)
#endif
        root.setCustomSpacing(18, after: founder)
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
    @objc private func sendTaylorFeedback() { FeedbackWindow.shared.show() }
#if APP_STORE
    @objc private func restorePurchases() { Task { await Store.shared.restore() } }
    @objc private func manageSubscription() {
        if let u = URL(string: "macappstore://apps.apple.com/account/subscriptions") { NSWorkspace.shared.open(u) }
    }
#else
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
#endif
}

// MARK: - Settings window

final class SettingsWindow: NSObject, NSWindowDelegate {
    static let shared = SettingsWindow()
    private var window: NSWindow?
    private weak var owner: AppDelegate?
    private var cameraPopup: NSPopUpButton?
    private weak var loginSwitch: NSSwitch?
    private weak var recordFolderButton: NSButton?

    func show(owner: AppDelegate) {
        self.owner = owner
        if let w = window { resync(); w.makeKeyAndOrderFront(nil); activate(); return }

        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 460, height: 440),
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

        let folderBtn = NSButton(title: recordFolderTitle(), target: self, action: #selector(chooseRecordFolder(_:)))
        folderBtn.bezelStyle = .rounded
        recordFolderButton = folderBtn
        let resetBtn = NSButton(title: "Reset", target: self, action: #selector(resetRecordFolder(_:)))
        resetBtn.bezelStyle = .rounded
        let folderControls = NSStackView(views: [folderBtn, resetBtn])
        folderControls.orientation = .horizontal
        folderControls.spacing = 6

        let camRow = row("Default camera", camPopup)
        let fsRow = row("Start in full screen", makeSwitch(Settings.startFullScreen, #selector(startFSChanged(_:))))
        let folderRow = row("Save recordings to", folderControls)
        let form = NSStackView(views: [
            header("CAMERA"),
            camRow,
            header("STARTUP"),
            row("Open at login", loginSw),
            row("Start minimized (menu bar only)", makeSwitch(Settings.startMinimized, #selector(startMinChanged(_:)))),
            row("Start recording on launch", makeSwitch(Settings.autoStartRecording, #selector(autoRecChanged(_:)))),
            fsRow,
            header("RECORDING"),
            folderRow,
            header("FULL SCREEN"),
            row("Hide the pointer when idle", makeSwitch(Settings.hidePointerFullScreen, #selector(hidePtrChanged(_:)))),
        ])
#if !APP_STORE
        form.addArrangedSubview(header("PRIVACY"))
        let participation = makeSwitch(InstallCount.enabled, #selector(toggleInstallCount(_:)))
        participation.toolTip = "Send a random installation ID daily while DocuCam runs."
        form.addArrangedSubview(row("Include this install in the active count", participation))
#endif
        form.orientation = .vertical
        form.alignment = .leading
        form.spacing = 10
        form.setCustomSpacing(16, after: camRow)
        form.setCustomSpacing(16, after: fsRow)
        form.setCustomSpacing(16, after: folderRow)
        form.edgeInsets = NSEdgeInsets(top: 20, left: 24, bottom: 20, right: 24)
        form.translatesAutoresizingMaskIntoConstraints = false
        cv.addSubview(form)
        NSLayoutConstraint.activate([
            form.topAnchor.constraint(equalTo: cv.topAnchor),
            form.leadingAnchor.constraint(equalTo: cv.leadingAnchor),
            form.trailingAnchor.constraint(equalTo: cv.trailingAnchor),
            form.bottomAnchor.constraint(equalTo: cv.bottomAnchor),
        ])

#if !APP_STORE
        w.setContentSize(NSSize(width: w.frame.width, height: form.fittingSize.height))
#endif
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
        recordFolderButton?.title = recordFolderTitle()
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
#if !APP_STORE
    @objc private func toggleInstallCount(_ sender: NSSwitch) {
        UserDefaults.standard.set(sender.state == .on, forKey: InstallCount.preference)
        InstallCount.checkIn()
    }
#endif
    @objc private func startFSChanged(_ s: NSSwitch) { Settings.startFullScreen = (s.state == .on) }
    @objc private func hidePtrChanged(_ s: NSSwitch) { Settings.hidePointerFullScreen = (s.state == .on) }
    @objc private func startMinChanged(_ s: NSSwitch) { Settings.startMinimized = (s.state == .on) }
    @objc private func autoRecChanged(_ s: NSSwitch) { Settings.autoStartRecording = (s.state == .on) }

    /// Display name of the current recording folder (default "Downloads").
    private func recordFolderTitle() -> String {
        if let data = Settings.recordFolderBookmark {
            var stale = false
            if let url = try? URL(resolvingBookmarkData: data, options: Settings.bookmarkResolveOptions,
                                  relativeTo: nil, bookmarkDataIsStale: &stale) {
                return url.lastPathComponent
            }
        }
        return "Downloads"
    }
    @objc private func chooseRecordFolder(_ sender: NSButton) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.prompt = "Choose"
        panel.message = "Choose where \(appName) saves recordings — a folder on this Mac or a mounted network share."
        panel.begin { resp in
            guard resp == .OK, let url = panel.url else { return }
            do {
                let data = try url.bookmarkData(options: Settings.bookmarkCreateOptions,
                                                includingResourceValuesForKeys: nil, relativeTo: nil)
                Settings.recordFolderBookmark = data
                sender.title = url.lastPathComponent
            } catch {
                let a = NSAlert()
                a.messageText = "Couldn’t use that folder"
                a.informativeText = error.localizedDescription
                a.runModal()
            }
        }
    }
    @objc private func resetRecordFolder(_ sender: NSButton) {
        Settings.recordFolderBookmark = nil
        recordFolderButton?.title = "Downloads"
    }

    func windowWillClose(_ n: Notification) { window = nil; cameraPopup = nil; loginSwitch = nil; recordFolderButton = nil }
    private func activate() {
        if #available(macOS 14.0, *) { NSApp.activate() } else { NSApp.activate(ignoringOtherApps: true) }
    }
}

// MARK: - App

final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate, NSMenuDelegate, AVCaptureVideoDataOutputSampleBufferDelegate, AVCaptureFileOutputRecordingDelegate {
    private var window: NSWindow!
    private var preview: PreviewView!
    private var statusItem: NSStatusItem!

    private let session = AVCaptureSession()
    private let sessionQueue = DispatchQueue(label: "docucam.session")
    private let frameQueue = DispatchQueue(label: "docucam.frames")
    private let videoOutput = AVCaptureVideoDataOutput()
    private var currentInput: AVCaptureDeviceInput?     // mutated only on sessionQueue
    // Recording: camera + mic → .mov, added to the live session lazily on first record.
    private let movieOutput = AVCaptureMovieFileOutput()
    private var movieOutputAdded = false                // sessionQueue
    private var micInput: AVCaptureDeviceInput?         // sessionQueue
    private var isRecording = false                     // main
    private var recordItem: NSMenuItem?
    // Keep the Mac awake while recording so capture survives an idle display/system sleep.
    // We block *system* idle sleep only — the display is still free to turn off.
    private var sleepAssertionID: IOPMAssertionID = IOPMAssertionID(0)
    private var sleepAssertionActive = false            // main
    private var didAutoStart = false                    // main; auto-record fires once per launch
    private var activeDeviceID: String?                 // UI source of truth; main thread only

    private var pendingFreeze = false                   // guarded by bufferLock
    private var pendingSnapshotSave = false             // guarded by bufferLock
    private var pendingSnapshotCopy = false             // guarded by bufferLock
    private var pendingAddPage = false                  // guarded by bufferLock
    private var frozenCGImage: CGImage?                 // main thread; the displayed frozen frame
    private var scanPages: [CGImage] = []               // main thread; collected PDF pages (oriented)
    private let bufferLock = NSLock()
    private let ciContext = CIContext()
    // Batch-scan enhancement (auto-crop/deskew + scanner look). Persisted in UserDefaults.
    private var scanAutoEnhance = UserDefaults.standard.object(forKey: "scanAutoEnhance") as? Bool ?? true
    private var scanMode = ScanMode(rawValue: UserDefaults.standard.integer(forKey: "scanMode")) ?? .color
    private let scanQueue = DispatchQueue(label: "docucam.scan", qos: .userInitiated)
    private var autoEnhanceItem: NSMenuItem?
    private var scanModeItems: [NSMenuItem] = []

    private var presetMenu: NSMenu?
    private var firstFrameObserved = false // guarded by bufferLock
    private var hasLaunched = false
    private var subscriptionTimer: Timer?
    private var cameraMenu: NSMenu!
    private var freezeItem: NSMenuItem!
    private var flipHItem: NSMenuItem!
    private var flipVItem: NSMenuItem!
    private var fillItem: NSMenuItem!
    private var annotateItem: NSMenuItem!
    private var penItem: NSMenuItem!
    private var highlighterItem: NSMenuItem!
    private var colorItems: [NSMenuItem] = []

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

#if APP_STORE
        // Gate the app behind an active subscription (a free trial counts as active).
        Store.shared.onChange = { [weak self] in self?.updateAccess() }
        Store.shared.start()
        updateAccess()
#else
        InstallCount.checkIn()
        Timer.scheduledTimer(withTimeInterval: 3600, repeats: true) { _ in InstallCount.checkIn() }
        checkPermissionAndStart()
        showGettingStartedIfNeeded()
#endif

        hasLaunched = true
#if APP_STORE
        subscriptionTimer = Timer.scheduledTimer(withTimeInterval: 300, repeats: true) { _ in Task { await Store.shared.refresh() } }
#endif
        if Settings.startFullScreen && !Settings.startMinimized {
            DispatchQueue.main.async { self.window.toggleFullScreen(nil) }
        }
    }

#if APP_STORE
    private var cameraStarted = false
    private var accessWasUnlocked = false
    /// Called on launch and whenever the subscription state changes: reveal the app when
    /// subscribed, otherwise block it behind the paywall.
    private func updateAccess() {
        let unlocked = Store.shared.isUnlocked
        let becameUnlocked = unlocked && !accessWasUnlocked
        accessWasUnlocked = unlocked
        if unlocked {
            Paywall.shared.close()
            // A status refresh must not steal focus from Subscription & Trial (or
            // reopen a camera window the user closed/minimized).
            if becameUnlocked && !Settings.startMinimized { window.makeKeyAndOrderFront(nil) }
            if !cameraStarted { cameraStarted = true; checkPermissionAndStart(); showGettingStartedIfNeeded() }
        } else {
            window.orderOut(nil)
            Paywall.shared.show(userInitiated: false)
        }
    }
#endif

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
        // Start minimized ⇒ stay in the menu bar with no visible window. The capture
        // session and recording run regardless of whether the window is on screen.
        if !Settings.startMinimized { window.makeKeyAndOrderFront(nil) }
    }

    @objc private func showMainWindow() {
#if APP_STORE
        guard Store.shared.isUnlocked else { Paywall.shared.show(); return }
#endif
        window.makeKeyAndOrderFront(nil)
        if #available(macOS 14.0, *) { NSApp.activate() } else { NSApp.activate(ignoringOtherApps: true) }
        sessionQueue.async { if !self.session.isRunning { self.session.startRunning() } }
    }

    // Releasing the camera when the window is closed (app stays in the menu bar).
    func windowWillClose(_ n: Notification) {
        if (n.object as? NSWindow) === window {
            bufferLock.lock()
            pendingFreeze = false; pendingSnapshotSave = false; pendingSnapshotCopy = false; pendingAddPage = false
            bufferLock.unlock()
            sessionQueue.async { if self.session.isRunning { self.session.stopRunning() } }
        }
    }

    // MARK: Menus

    private func buildMenus() {
        let main = NSMenu()

        let appItem = NSMenuItem(); main.addItem(appItem)
        let appMenu = NSMenu()
        add(appMenu, "About \(appName)", #selector(showAbout))
#if APP_STORE
        add(appMenu, "Restore Purchases", #selector(restoreSub))
        add(appMenu, "Subscription & Trial…", #selector(showSubscription))
#else
        add(appMenu, "Check for Updates…", #selector(checkForUpdates))
        add(appMenu, "Support the Developer…", #selector(openKofi))
#endif
        appMenu.addItem(.separator())
        add(appMenu, "Settings…", #selector(openSettings), ",", [.command])
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Hide \(appName)", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        appMenu.addItem(withTitle: "Quit \(appName)", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu

        let camItem = NSMenuItem(); main.addItem(camItem)
        cameraMenu = NSMenu(title: "Camera")
        cameraMenu.delegate = self   // rebuild the device list every time the menu opens
        camItem.submenu = cameraMenu

        let viewItem = NSMenuItem(); main.addItem(viewItem)
        let viewMenu = NSMenu(title: "View")
        freezeItem = add(viewMenu, "Freeze", #selector(toggleFreeze), " ", [])
        add(viewMenu, "Rotate", #selector(rotate), "r", [])
        flipHItem = add(viewMenu, "Flip Horizontal", #selector(toggleFlipH), "h", [])
        flipVItem = add(viewMenu, "Flip Vertical", #selector(toggleFlipV), "v", [])
        fillItem = add(viewMenu, "Fill Screen", #selector(toggleFill), "f", [])
        viewMenu.addItem(.separator())
        add(viewMenu, "Zoom In", #selector(zoomIn), "=", [.command])
        add(viewMenu, "Zoom Out", #selector(zoomOut), "-", [.command])
        add(viewMenu, "Actual Size", #selector(actualSize), "0", [.command])
        viewMenu.addItem(.separator())
        viewMenu.addItem(withTitle: "Enter Full Screen",
                         action: #selector(NSWindow.toggleFullScreen(_:)), keyEquivalent: "f")
            .keyEquivalentModifierMask = [.command, .control]
        viewMenu.addItem(.separator())
        let presetItem = NSMenuItem(title: "Classroom Presets", action: nil, keyEquivalent: "")
        presetMenu = NSMenu(title: "Classroom Presets"); presetItem.submenu = presetMenu
        viewMenu.addItem(presetItem); rebuildPresetMenu()
        viewItem.submenu = viewMenu

        let capItem = NSMenuItem(); main.addItem(capItem)
        let capMenu = NSMenu(title: "Capture")
        add(capMenu, "Save Image…", #selector(saveSnapshot), "s", [.command])
        add(capMenu, "Copy Image", #selector(copySnapshot), "c", [.command])
        capMenu.addItem(.separator())
        add(capMenu, "Add Page to Scan", #selector(addScanPage), "a", [.command, .shift])
        add(capMenu, "Save Scan as PDF…", #selector(saveScanPDF), "p", [.command, .shift])
        add(capMenu, "Clear Scan", #selector(clearScan))
        capMenu.addItem(.separator())
        autoEnhanceItem = add(capMenu, "Auto-Crop & Enhance", #selector(toggleAutoEnhance))
        autoEnhanceItem?.state = scanAutoEnhance ? .on : .off
        let modeItem = NSMenuItem(title: "Scan Look", action: nil, keyEquivalent: "")
        let modeMenu = NSMenu(title: "Scan Look")
        for (nm, m) in [("Color", ScanMode.color), ("Grayscale", .gray), ("Black & White", .bw)] {
            let it = add(modeMenu, nm, #selector(setScanMode(_:)))
            it.representedObject = m.rawValue
            it.state = (m == scanMode) ? .on : .off
            scanModeItems.append(it)
        }
        modeItem.submenu = modeMenu
        capMenu.addItem(modeItem)
        capMenu.addItem(.separator())
        recordItem = add(capMenu, "Start Recording", #selector(toggleRecording), "r", [.command, .option])
        capItem.submenu = capMenu

        let annItem = NSMenuItem(); main.addItem(annItem)
        let annMenu = NSMenu(title: "Annotate")
        annotateItem = add(annMenu, "Annotate", #selector(toggleAnnotate), "d", [])
        annMenu.addItem(.separator())
        penItem = add(annMenu, "Pen", #selector(setPen)); penItem.state = .on
        highlighterItem = add(annMenu, "Highlighter", #selector(setHighlighter))
        annMenu.addItem(.separator())
        let colors: [(String, NSColor)] = [("Red", .systemRed), ("Orange", .systemOrange),
            ("Yellow", .systemYellow), ("Green", .systemGreen), ("Blue", .systemBlue),
            ("White", .white), ("Black", .black)]
        for (i, (nm, col)) in colors.enumerated() {
            let it = add(annMenu, nm, #selector(setAnnotationColor(_:)))
            it.representedObject = col
            if i == 0 { it.state = .on }   // Red is the default
            colorItems.append(it)
        }
        annMenu.addItem(.separator())
        add(annMenu, "Clear Annotations", #selector(clearAnnotations))
        annItem.submenu = annMenu

        let helpItem = NSMenuItem(); main.addItem(helpItem)
        let helpMenu = NSMenu(title: "Help")
        add(helpMenu, "Your First Lesson…", #selector(showGettingStarted))
        add(helpMenu, "Share Feedback…", #selector(shareFeedback))
        helpItem.submenu = helpMenu
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
#if !APP_STORE
        add(m, "Check for Updates…", #selector(checkForUpdates))
        add(m, "Support the Developer…", #selector(openKofi))
#endif
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

    // Rebuild the camera list whenever the Camera menu opens, so a just-connected device
    // (e.g. an iPhone via Continuity Camera, which may not fire a connect notification) shows up.
    func menuNeedsUpdate(_ menu: NSMenu) {
        if menu === cameraMenu { rebuildCameraMenu() }
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
        if #available(macOS 14.0, *) {
            types.append(.external)
            types.append(.continuityCamera)   // iPhone/iPad as a document camera
        } else {
            types.append(.externalUnknown)
        }
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
                DispatchQueue.main.async { self.autoStartRecordingIfNeeded() }
            } else {
                DispatchQueue.main.async {
                    self.preview.showMessage("No camera found.\n\nPlug in a document camera — or use your iPhone/iPad: hold it near this Mac (same Apple ID, Wi‑Fi + Bluetooth on) and it appears in the Camera menu.")
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
    private func applyDeviceLocked(_ device: AVCaptureDevice, preset: ClassroomPreset? = nil) {
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
                self.preview.resetZoom()
                self.preview.showMessage(nil)
                if let preset { self.applyPresetView(preset) }
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
        // Only convert a frame when something needs it — never hold a pool buffer.
        bufferLock.lock()
        let firstFrame = !firstFrameObserved; firstFrameObserved = true
        let doFreeze = pendingFreeze; if doFreeze { pendingFreeze = false }
        let doSave = pendingSnapshotSave; if doSave { pendingSnapshotSave = false }
        let doCopy = pendingSnapshotCopy; if doCopy { pendingSnapshotCopy = false }
        let doAddPage = pendingAddPage; if doAddPage { pendingAddPage = false }
        bufferLock.unlock()
        if firstFrame { DispatchQueue.main.async { GettingStarted.shared.record(camera: true) } }
        guard doFreeze || doSave || doCopy || doAddPage,
              let pb = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        let ci = CIImage(cvPixelBuffer: pb)
        guard let cg = ciContext.createCGImage(ci, from: ci.extent) else { return }
        DispatchQueue.main.async {
            if doFreeze {
                self.frozenCGImage = cg
                self.preview.setFreezeImage(cg)
                self.preview.frozen = true
                self.syncViewMenu()
            }
            if doSave { self.deliverSnapshot(cg, save: true) }
            if doCopy { self.deliverSnapshot(cg, save: false) }
            if doAddPage { self.appendScanPage(cg) }
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
                else { self.preview.showMessage("No camera found.\n\nPlug in a document camera — or use your iPhone/iPad: hold it near this Mac (same Apple ID, Wi‑Fi + Bluetooth on) and it appears in the Camera menu.") }
            }
            self.rebuildCameraMenu()
        }
    }

    @objc private func toggleFreeze() {
        if preview.frozen {
            preview.frozen = false
            frozenCGImage = nil
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

    @objc private func zoomIn() { preview.stepZoom(1.25) }
    @objc private func zoomOut() { preview.stepZoom(0.8) }
    @objc private func actualSize() { preview.resetZoom() }

    // MARK: Snapshot (save to file / copy to clipboard)

    @objc private func copySnapshot() { captureSnapshot(save: false) }
    @objc private func saveSnapshot() { captureSnapshot(save: true) }

    private func captureSnapshot(save: Bool) {
        if preview.frozen, let cg = frozenCGImage {
            deliverSnapshot(cg, save: save)                 // use the displayed frozen frame
        } else {
            bufferLock.lock()
            if save { pendingSnapshotSave = true } else { pendingSnapshotCopy = true }
            bufferLock.unlock()                             // grabbed on the next captured frame
        }
    }

    private func deliverSnapshot(_ cg: CGImage, save: Bool) {
        let img = orientedSnapshot(cg)
        let nsImage = NSImage(cgImage: img, size: NSSize(width: img.width, height: img.height))
        if save {
            let panel = NSSavePanel()
            panel.allowedContentTypes = [.png]
            panel.nameFieldStringValue = "DocuCam \(snapshotStamp).png"
            panel.canCreateDirectories = true
            panel.begin { resp in
                guard resp == .OK, let url = panel.url,
                      let tiff = nsImage.tiffRepresentation,
                      let rep = NSBitmapImageRep(data: tiff),
                      let png = rep.representation(using: .png, properties: [:]) else { return }
                do { try png.write(to: url); GettingStarted.shared.record(saved: true) } catch { self.flashToast("Couldn’t save the image") }
            }
        } else {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.writeObjects([nsImage])
            flashToast("Copied to clipboard")
        }
    }

    /// Bakes the current rotation + flip into the saved/copied image so it matches the screen.
    private func orientedSnapshot(_ cg: CGImage) -> CGImage {
        if preview.rotation == 0 && !preview.flipH && !preview.flipV { return cg }
        // Flips before rotation, to match layout()'s CATransform3DScale(rotation) composition
        // (otherwise rotation 90/270 + a flip comes out mirrored).
        var xf = CGAffineTransform.identity
        if preview.flipH { xf = xf.concatenating(CGAffineTransform(scaleX: -1, y: 1)) }
        if preview.flipV { xf = xf.concatenating(CGAffineTransform(scaleX: 1, y: -1)) }
        xf = xf.concatenating(CGAffineTransform(rotationAngle: CGFloat(preview.rotation) * .pi / 180))
        let out = CIImage(cgImage: cg).transformed(by: xf)
        return ciContext.createCGImage(out, from: out.extent) ?? cg
    }

    private var snapshotStamp: String {
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd HH.mm.ss"; return f.string(from: Date())
    }
    private func flashToast(_ text: String) {
        preview.showMessage(text)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { self.preview.showMessage(nil) }
    }

    // MARK: PDF scan — collect pages, then export one multi-page PDF

    @objc private func addScanPage() {
        if preview.frozen, let cg = frozenCGImage { appendScanPage(cg) }
        else { bufferLock.lock(); pendingAddPage = true; bufferLock.unlock() }
    }
    private func appendScanPage(_ cg: CGImage) {
        let oriented = orientedSnapshot(cg)             // bake rotation/flip first (matches the screen)
        guard scanAutoEnhance else {
            DispatchQueue.main.async { self.finishScanPage(oriented) }
            return
        }
        let mode = scanMode
        scanQueue.async {                               // Vision + Core Image off the capture/main thread
            let cleaned = DocScanner.clean(oriented, mode: mode) ?? oriented
            DispatchQueue.main.async { self.finishScanPage(cleaned) }
        }
    }
    private func finishScanPage(_ cg: CGImage) {        // always on main; scanPages is main-thread
        scanPages.append(cg)
        preview.scanCount = scanPages.count
        flashToast("Added page \(scanPages.count)")
    }
    @objc private func saveScanPDF() {
        guard !scanPages.isEmpty else { flashToast("No pages yet — use Add Page to Scan (⇧⌘A)"); return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.pdf]
        panel.nameFieldStringValue = "Scan \(snapshotStamp).pdf"
        panel.canCreateDirectories = true
        let pages = scanPages
        panel.begin { resp in
            guard resp == .OK, let url = panel.url else { return }
            let doc = PDFDocument()
            for cg in pages {
                let img = NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
                if let page = PDFPage(image: img) { doc.insert(page, at: doc.pageCount) }
            }
            if !doc.write(to: url) { self.flashToast("Couldn’t save the PDF") }
            else { GettingStarted.shared.record(saved: true) }
        }
    }
    @objc private func clearScan() {
        scanPages.removeAll()
        preview.scanCount = 0
        flashToast("Scan cleared")
    }
    @objc private func toggleAutoEnhance() {
        scanAutoEnhance.toggle()
        UserDefaults.standard.set(scanAutoEnhance, forKey: "scanAutoEnhance")
        autoEnhanceItem?.state = scanAutoEnhance ? .on : .off
        flashToast(scanAutoEnhance ? "Auto-crop & enhance on" : "Auto-crop & enhance off")
    }
    @objc private func setScanMode(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? Int, let m = ScanMode(rawValue: raw) else { return }
        scanMode = m
        UserDefaults.standard.set(raw, forKey: "scanMode")
        for it in scanModeItems { it.state = (it === sender) ? .on : .off }
        flashToast("Scan look: \(sender.title)")
    }

    // MARK: Record — camera + mic to a .mov, then save/share

    @objc private func toggleRecording() {
        if isRecording { stopRecording() } else { startRecording() }
    }
    private func startRecording() {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("DocuCam \(snapshotStamp).mov")
        sessionQueue.async {
            self.session.beginConfiguration()
            if self.micInput == nil, let mic = AVCaptureDevice.default(for: .audio),
               let inp = try? AVCaptureDeviceInput(device: mic), self.session.canAddInput(inp) {
                self.session.addInput(inp); self.micInput = inp
            }
            if !self.movieOutputAdded, self.session.canAddOutput(self.movieOutput) {
                self.session.addOutput(self.movieOutput); self.movieOutputAdded = true
            }
            self.session.commitConfiguration()
            guard self.movieOutputAdded, self.movieOutput.connection(with: .video) != nil else {
                DispatchQueue.main.async { self.flashToast("Can’t record — no camera") }
                return
            }
            self.movieOutput.startRecording(to: url, recordingDelegate: self)
        }
    }
    private func stopRecording() {
        sessionQueue.async { if self.movieOutput.isRecording { self.movieOutput.stopRecording() } }
    }
    func fileOutput(_ output: AVCaptureFileOutput, didStartRecordingTo fileURL: URL,
                    from connections: [AVCaptureConnection]) {
        DispatchQueue.main.async {
            self.isRecording = true
            self.recordItem?.title = "Stop Recording"
            self.preview.recording = true
            self.preventIdleSleep()
            self.flashToast("Recording…")
        }
    }
    func fileOutput(_ output: AVCaptureFileOutput, didFinishRecordingTo outputFileURL: URL,
                    from connections: [AVCaptureConnection], error: Error?) {
        DispatchQueue.main.async {
            self.isRecording = false
            self.recordItem?.title = "Start Recording"
            self.preview.recording = false
            self.allowIdleSleep()
            // AVFoundation reports a non-nil error even on a normal stop if the movie is still
            // usable; only bail when the file didn't actually get written.
            let ok = FileManager.default.fileExists(atPath: outputFileURL.path)
            if !ok { self.flashToast("Recording failed"); return }
            self.presentRecording(outputFileURL)
        }
    }
    // Finished recordings drop straight into the chosen folder (default ~/Downloads) — no
    // save panel, so a classroom recording doesn't block on a dialog. The recording was
    // captured to a local temp file and only moved here on finish, so a network share never
    // sees a half-written file. If the folder is unreachable (share unmounted, sandbox lost
    // access), fall back to letting the user pick a spot.
    private func presentRecording(_ url: URL) {
        let fm = FileManager.default
        let (folder, scoped) = resolveRecordFolder()
        defer { if scoped { folder.stopAccessingSecurityScopedResource() } }

        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: folder.path, isDirectory: &isDir), isDir.boolValue else {
            presentRecordingSavePanel(url); return
        }
        let dest = uniqueURL(folder.appendingPathComponent(url.lastPathComponent))
        do {
            try fm.moveItem(at: url, to: dest)
            GettingStarted.shared.record(saved: true)
            flashToast("Saved to \(folder.lastPathComponent)")
        } catch {
            presentRecordingSavePanel(url)
        }
    }
    /// The folder finished recordings go to, plus whether a security scope was started
    /// (the caller must stop it when done). Falls back to ~/Downloads.
    private func resolveRecordFolder() -> (url: URL, scoped: Bool) {
        let fm = FileManager.default
        if let data = Settings.recordFolderBookmark {
            var stale = false
            if let url = try? URL(resolvingBookmarkData: data, options: Settings.bookmarkResolveOptions,
                                  relativeTo: nil, bookmarkDataIsStale: &stale) {
                let scoped = url.startAccessingSecurityScopedResource()
                if stale, let fresh = try? url.bookmarkData(options: Settings.bookmarkCreateOptions,
                                                            includingResourceValuesForKeys: nil, relativeTo: nil) {
                    Settings.recordFolderBookmark = fresh
                }
                return (url, scoped)
            }
        }
        let downloads = (try? fm.url(for: .downloadsDirectory, in: .userDomainMask,
                                     appropriateFor: nil, create: true))
            ?? fm.homeDirectoryForCurrentUser.appendingPathComponent("Downloads")
        return (downloads, false)
    }
    /// Kick off recording automatically once per launch when the camera is live.
    private func autoStartRecordingIfNeeded() {
        guard Settings.autoStartRecording, !didAutoStart, !isRecording else { return }
        didAutoStart = true
        // Give the freshly-started session a beat to settle before capturing.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            guard !self.isRecording else { return }
            self.startRecording()
        }
    }
    private func presentRecordingSavePanel(_ url: URL) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.quickTimeMovie]
        panel.nameFieldStringValue = url.lastPathComponent
        panel.canCreateDirectories = true
        panel.begin { resp in
            guard resp == .OK, let dest = panel.url else { try? FileManager.default.removeItem(at: url); return }
            try? FileManager.default.removeItem(at: dest)
            do { try FileManager.default.moveItem(at: url, to: dest); GettingStarted.shared.record(saved: true); self.flashToast("Saved recording") }
            catch { self.flashToast("Couldn’t save recording") }
        }
    }
    // Append " 2", " 3", … before the extension if the name is already taken.
    private func uniqueURL(_ url: URL) -> URL {
        let fm = FileManager.default
        guard fm.fileExists(atPath: url.path) else { return url }
        let dir = url.deletingLastPathComponent()
        let base = url.deletingPathExtension().lastPathComponent
        let ext = url.pathExtension
        var n = 2
        while true {
            let candidate = dir.appendingPathComponent(ext.isEmpty ? "\(base) \(n)" : "\(base) \(n).\(ext)")
            if !fm.fileExists(atPath: candidate.path) { return candidate }
            n += 1
        }
    }

    // MARK: Stay awake while recording (main thread)

    private func preventIdleSleep() {
        guard !sleepAssertionActive else { return }
        let ok = IOPMAssertionCreateWithName(
            kIOPMAssertPreventUserIdleSystemSleep as CFString,
            IOPMAssertionLevel(kIOPMAssertionLevelOn),
            "BlueBird DocuCam is recording" as CFString,
            &sleepAssertionID)
        sleepAssertionActive = (ok == kIOReturnSuccess)
    }
    private func allowIdleSleep() {
        guard sleepAssertionActive else { return }
        IOPMAssertionRelease(sleepAssertionID)
        sleepAssertionActive = false
    }

    // MARK: First lesson / classroom presets

    private var presets: [ClassroomPreset] {
        get { UserDefaults.standard.data(forKey: "classroomPresets").flatMap { try? JSONDecoder().decode([ClassroomPreset].self, from: $0) } ?? [] }
        set { UserDefaults.standard.set(try? JSONEncoder().encode(newValue), forKey: "classroomPresets"); rebuildPresetMenu() }
    }
    private func rebuildPresetMenu() {
        guard let menu = presetMenu else { return }
        menu.removeAllItems()
        add(menu, "Save Current Setup…", #selector(saveClassroomPreset))
        if !presets.isEmpty {
            menu.addItem(.separator())
            for (i,p) in presets.enumerated() { let item = add(menu, p.name, #selector(applyClassroomPreset(_:))); item.tag = i }
            menu.addItem(.separator()); add(menu, "Delete a Preset…", #selector(deleteClassroomPreset))
        }
    }
    @objc private func saveClassroomPreset() {
        guard let camera = activeDeviceID else { flashToast("Connect a camera before saving a preset"); return }
        let a = NSAlert(); a.messageText = "Save classroom setup"; a.informativeText = "Remember this camera, rotation, flips, fit/fill, zoom and pan. Recording and full-screen mode are not changed by presets."
        let name = NSTextField(frame: NSRect(x: 0, y: 0, width: 300, height: 24)); name.placeholderString = "For example: Period 1 — math"
        a.accessoryView = name; a.addButton(withTitle: "Save"); a.addButton(withTitle: "Cancel")
        a.window.initialFirstResponder = name
        guard a.runModal() == .alertFirstButtonReturn else { return }
        let title = String(name.stringValue.trimmingCharacters(in: .whitespacesAndNewlines).prefix(80))
        guard !title.isEmpty else { return }
        var list = presets
        let preset = ClassroomPreset(name: title, cameraID: camera, rotation: preview.rotation, flipH: preview.flipH, flipV: preview.flipV, fill: preview.fill, zoom: Double(preview.zoom), panX: Double(preview.panOffset.x / max(1,preview.bounds.width)), panY: Double(preview.panOffset.y / max(1,preview.bounds.height)))
        if let i = list.firstIndex(where: { $0.name.caseInsensitiveCompare(title) == .orderedSame }) {
            let confirm = NSAlert(); confirm.messageText = "Replace “\(list[i].name)”?"; confirm.addButton(withTitle: "Replace"); confirm.addButton(withTitle: "Cancel")
            guard confirm.runModal() == .alertFirstButtonReturn else { return }; list[i] = preset
        } else { list.append(preset) }
        presets = list; flashToast("Saved classroom preset")
    }
    @objc private func applyClassroomPreset(_ sender: NSMenuItem) {
        let list = presets; guard list.indices.contains(sender.tag) else { return }
        guard !isRecording else { flashToast("Stop recording before switching classroom setups"); return }
        let p = list[sender.tag]
        guard let device = availableCameras().first(where: { $0.uniqueID == p.cameraID }) else {
            let a = NSAlert(); a.messageText = "Preset camera is unavailable"; a.informativeText = "Connect the camera for “\(p.name)”, then try again. Your current setup has been kept."; a.runModal(); return
        }
        if activeDeviceID == device.uniqueID { applyPresetView(p) }
        else { sessionQueue.async { self.applyDeviceLocked(device, preset: p) } }
    }
    private func applyPresetView(_ p: ClassroomPreset) {
        preview.rotation = [0,90,180,270].contains(p.rotation) ? p.rotation : 0
        preview.flipH = p.flipH; preview.flipV = p.flipV; preview.fill = p.fill
        preview.zoom = CGFloat(p.safeZoom)
        preview.panOffset = CGPoint(x: CGFloat(p.safePan(p.panX)) * preview.bounds.width, y: CGFloat(p.safePan(p.panY)) * preview.bounds.height)
        let d = UserDefaults.standard
        d.set(preview.rotation, forKey: kRotation); d.set(p.flipH, forKey: kFlipH); d.set(p.flipV, forKey: kFlipV); d.set(p.fill, forKey: kFill)
        syncViewMenu(); flashToast("Applied \(p.name)")
    }
    @objc private func deleteClassroomPreset() {
        var list = presets; guard !list.isEmpty else { return }
        let a = NSAlert(); a.messageText = "Delete a classroom preset"; a.informativeText = "This removes the saved setup, not any scans or recordings."
        let choices = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 300, height: 28)); choices.addItems(withTitles: list.map(\.name)); a.accessoryView = choices
        a.addButton(withTitle: "Delete"); a.addButton(withTitle: "Cancel")
        guard a.runModal() == .alertFirstButtonReturn, list.indices.contains(choices.indexOfSelectedItem) else { return }
        list.remove(at: choices.indexOfSelectedItem); presets = list
    }
    private func showGettingStartedIfNeeded() {
        guard !Settings.startMinimized, !Settings.startFullScreen, !UserDefaults.standard.bool(forKey: "gettingStartedSeen") else { return }
        showGettingStarted()
    }
    @objc private func showGettingStarted() {
#if APP_STORE
        guard Store.shared.isUnlocked else { Paywall.shared.show(); return }
#endif
        GettingStarted.shared.show(actions: [
            { [weak self] in guard let self else { return }; self.rebuildCameraMenu(); self.cameraMenu.popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil) },
            { [weak self] in guard let self else { return }; self.showMainWindow(); if !self.window.styleMask.contains(.fullScreen) { self.window.toggleFullScreen(nil) } },
            { [weak self] in self?.addScanPage() },
            { [weak self] in self?.saveScanPDF() }
        ])
    }
    @objc private func shareFeedback() { FeedbackWindow.shared.show() }
    func windowDidEnterFullScreen(_ notification: Notification) { if (notification.object as? NSWindow) === window { GettingStarted.shared.record(presentation: true) } }
#if APP_STORE
    @objc private func showSubscription() { SubscriptionWindow.shared.show(); Task { await Store.shared.loadProducts(); await Store.shared.refresh() } }
    func applicationDidBecomeActive(_ notification: Notification) { if hasLaunched { Task { await Store.shared.refresh() } } }
#endif

    // MARK: Annotation

    @objc private func toggleAnnotate() {
        preview.annotationView.active.toggle()
        annotateItem.state = preview.annotationView.active ? .on : .off
        flashToast(preview.annotationView.active
            ? "Annotating — drag to draw. Freeze (Space) first for a still page."
            : "Annotation off")
    }
    @objc private func setPen() {
        preview.annotationView.highlighter = false; penItem.state = .on; highlighterItem.state = .off
    }
    @objc private func setHighlighter() {
        preview.annotationView.highlighter = true; penItem.state = .off; highlighterItem.state = .on
    }
    @objc private func setAnnotationColor(_ sender: NSMenuItem) {
        if let c = sender.representedObject as? NSColor { preview.annotationView.color = c }
        for it in colorItems { it.state = (it === sender) ? .on : .off }
    }
    @objc private func clearAnnotations() { preview.annotationView.clear() }

    @objc private func fullScreenFromStatus() {
        showMainWindow()
        window.toggleFullScreen(nil)
    }

    @objc private func openSettings() { SettingsWindow.shared.show(owner: self) }
    @objc private func showAbout() { AboutWindow.shared.show() }
#if APP_STORE
    @objc private func restoreSub() { Task { await Store.shared.restore() } }
#else
    @objc private func checkForUpdates() { Updater.check(userInitiated: true) }
    @objc private func openKofi() { if let u = URL(string: kofiURL) { NSWorkspace.shared.open(u) } }
#endif
}

// MARK: - Batch scan cleanup (auto-crop / deskew / scanner enhance)

enum ScanMode: Int { case color = 0, gray = 1, bw = 2 }

/// Turns a raw captured page into a scanner-style page: detects the document edges,
/// flattens perspective (deskew), and enhances contrast. Pure + thread-safe — call off
/// the main thread. Returns nil only if Core Image can't render; callers fall back to raw.
enum DocScanner {
    private static let ctx = CIContext()

    static func clean(_ cg: CGImage, mode: ScanMode) -> CGImage? {
        var ci = CIImage(cgImage: cg)
        if let flat = detectAndFlatten(ci) { ci = flat }
        ci = enhance(ci, mode: mode)
        return ctx.createCGImage(ci, from: ci.extent)
    }

    private static func detectAndFlatten(_ ci: CIImage) -> CIImage? {
        let req = VNDetectDocumentSegmentationRequest()
        let handler = VNImageRequestHandler(ciImage: ci, options: [:])
        guard (try? handler.perform([req])) != nil,
              let obs = req.results?.first else { return nil }
        let w = ci.extent.width, h = ci.extent.height
        func px(_ p: CGPoint) -> CGPoint { CGPoint(x: p.x * w, y: p.y * h) }   // normalized (bottom-left origin) → pixels
        let tl = px(obs.topLeft), tr = px(obs.topRight), br = px(obs.bottomRight), bl = px(obs.bottomLeft)
        // Skip degenerate or near-full-frame detections that would just warp the image.
        let frame = w * h
        guard frame > 0 else { return nil }
        let ratio = quadArea(tl, tr, br, bl) / frame
        guard ratio > 0.15, ratio < 0.999 else { return nil }
        return ci.applyingFilter("CIPerspectiveCorrection", parameters: [
            "inputTopLeft": CIVector(cgPoint: tl), "inputTopRight": CIVector(cgPoint: tr),
            "inputBottomRight": CIVector(cgPoint: br), "inputBottomLeft": CIVector(cgPoint: bl)])
    }

    private static func enhance(_ ci: CIImage, mode: ScanMode) -> CIImage {
        switch mode {
        case .color:
            return ci.applyingFilter("CIColorControls",
                parameters: [kCIInputContrastKey: 1.06, kCIInputSaturationKey: 1.06])
        case .gray:
            return ci.applyingFilter("CIColorControls",
                parameters: [kCIInputSaturationKey: 0.0, kCIInputContrastKey: 1.14])
        case .bw:                                      // whiten paper, darken ink — photocopier look
            return ci.applyingFilter("CIColorControls",
                parameters: [kCIInputSaturationKey: 0.0, kCIInputContrastKey: 1.55, kCIInputBrightnessKey: 0.14])
        }
    }

    // Shoelace area over the 4 corners in tl,tr,br,bl order.
    private static func quadArea(_ a: CGPoint, _ b: CGPoint, _ c: CGPoint, _ d: CGPoint) -> CGFloat {
        let s = (a.x*b.y - b.x*a.y) + (b.x*c.y - c.x*b.y) + (c.x*d.y - d.x*c.y) + (d.x*a.y - a.x*d.y)
        return abs(s) / 2
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.regular)
if #available(macOS 14.0, *) { app.activate() } else { app.activate(ignoringOtherApps: true) }
app.run()
