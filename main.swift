import Cocoa
import UniformTypeIdentifiers
import PDFKit
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
    let annotationView = AnnotationView()
    private let messageLabel = NSTextField(labelWithString: "")
    private let pauseBadge = NSView()
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

let subProductIDs = ["com.emerytech.BlueBirdDocuCam.yearly", "com.emerytech.BlueBirdDocuCam.monthly"]
let lifetimeProductID = "com.emerytech.BlueBirdDocuCam.lifetime"   // non-consumable: buy once, own forever

/// Subscription state. Plain class (not @MainActor) so the AppKit AppDelegate can touch it
/// freely; all published state is written back on the main actor, where the UI reads it.
final class Store {
    static let shared = Store()
    private(set) var products: [Product] = []       // subscriptions (monthly, yearly)
    private(set) var lifetimeProduct: Product?      // non-consumable lifetime unlock
    private(set) var isUnlocked = false             // active subscription OR owns lifetime
    var onChange: (() -> Void)?
    private var updatesTask: Task<Void, Never>?

    func start() {
        updatesTask = Task { [weak self] in
            for await update in Transaction.updates {
                if case .verified(let t) = update { await t.finish() }
                await self?.refresh()
            }
        }
        Task { await loadProducts(); await refresh() }
    }
    func loadProducts() async {
        let all = (try? await Product.products(for: subProductIDs + [lifetimeProductID])) ?? []
        let subs = all.filter { subProductIDs.contains($0.id) }.sorted { $0.price < $1.price }
        let life = all.first { $0.id == lifetimeProductID }
        await MainActor.run { self.products = subs; self.lifetimeProduct = life; self.onChange?() }
    }
    func refresh() async {
        var active = false
        for await result in Transaction.currentEntitlements {
            guard case .verified(let t) = result, t.revocationDate == nil else { continue }
            if t.productID == lifetimeProductID {
                active = true                                       // non-consumable: owned forever
            } else if subProductIDs.contains(t.productID) {
                if let exp = t.expirationDate { if exp > Date() { active = true } } else { active = true }
            }
        }
        let resolved = active
        await MainActor.run { self.isUnlocked = resolved; self.onChange?() }
    }
    @discardableResult
    func purchase(_ product: Product) async -> Bool {
        guard let result = try? await product.purchase() else { return false }
        if case .success(let verification) = result, case .verified(let t) = verification {
            await t.finish(); await refresh(); return true
        }
        return false
    }
    func restore() async { try? await AppStore.sync(); await refresh() }
}

/// Blocks the app until it's unlocked — an active subscription (a free trial counts) or the
/// one-time lifetime purchase.
final class Paywall: NSObject, NSWindowDelegate {
    static let shared = Paywall()
    private var window: NSWindow?

    func show() {
        let w = window ?? makeWindow()
        buildBody(in: w)                 // rebuild each time so it reflects loaded products / state
        window = w
        w.center(); w.makeKeyAndOrderFront(nil)
        if #available(macOS 14.0, *) { NSApp.activate() } else { NSApp.activate(ignoringOtherApps: true) }
    }
    func close() { window?.orderOut(nil) }

    private func makeWindow() -> NSWindow {
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 420, height: 470),
                         styleMask: [.titled, .fullSizeContentView], backing: .buffered, defer: false)
        w.titleVisibility = .hidden; w.titlebarAppearsTransparent = true
        w.isReleasedWhenClosed = false; w.level = .floating; w.delegate = self
        return w
    }
    private func buildBody(in w: NSWindow) {
        guard let cv = w.contentView else { return }
        cv.subviews.forEach { $0.removeFromSuperview() }

        let icon = NSImageView(); icon.image = NSApp.applicationIconImage
        icon.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([icon.widthAnchor.constraint(equalToConstant: 82),
                                     icon.heightAnchor.constraint(equalToConstant: 82)])
        let title = NSTextField(labelWithString: appName)
        title.font = .systemFont(ofSize: 22, weight: .bold); title.textColor = Brand.blue
        let sub = NSTextField(labelWithString: "Document Camera & PDF Scanner")
        sub.font = .systemFont(ofSize: 13); sub.textColor = .secondaryLabelColor

        let bullets = NSTextField(wrappingLabelWithString:
            "•  Use your iPhone or iPad as a document camera\n•  Zoom, freeze, rotate & flip\n•  Snapshot to image or clipboard\n•  Scan pages to one PDF\n•  Annotate with pen & highlighter")
        bullets.font = .systemFont(ofSize: 13)

        let plans = NSStackView(); plans.orientation = .vertical; plans.spacing = 8; plans.alignment = .centerX
        if Store.shared.products.isEmpty {
            plans.addArrangedSubview(NSTextField(labelWithString: "Loading plans…"))
        } else {
            for (i, p) in Store.shared.products.enumerated() {
                let b = NSButton(title: planTitle(p), target: self, action: #selector(buy(_:)))
                b.bezelStyle = .rounded; b.controlSize = .large; b.tag = i
                b.widthAnchor.constraint(equalToConstant: 300).isActive = true
                plans.addArrangedSubview(b)
            }
        }
        // One-time lifetime unlock (non-consumable), shown beneath the subscriptions.
        let lifetime: NSView
        if let lp = Store.shared.lifetimeProduct {
            let orLbl = NSTextField(labelWithString: "— or —")
            orLbl.font = .systemFont(ofSize: 11, weight: .medium); orLbl.textColor = .tertiaryLabelColor
            let lb = NSButton(title: "Unlock Forever — \(lp.displayPrice)", target: self, action: #selector(buyLifetime))
            lb.bezelStyle = .rounded; lb.controlSize = .large
            lb.widthAnchor.constraint(equalToConstant: 300).isActive = true
            let oneTime = NSTextField(labelWithString: "One-time purchase · no subscription")
            oneTime.font = .systemFont(ofSize: 10); oneTime.textColor = .tertiaryLabelColor
            let s = NSStackView(views: [orLbl, lb, oneTime])
            s.orientation = .vertical; s.alignment = .centerX; s.spacing = 6
            lifetime = s
        } else {
            lifetime = NSView()
        }

        let restore = NSButton(title: "Restore Purchases", target: self, action: #selector(restoreTapped))
        restore.isBordered = false; restore.contentTintColor = Brand.blue
        let note = NSTextField(wrappingLabelWithString:
            "Educators: email for a 50%-off code and redeem it in the App Store. A free version is also available on GitHub. Subscriptions renew until cancelled; the lifetime unlock is a one-time purchase. Manage purchases in the App Store.")
        note.font = .systemFont(ofSize: 10); note.textColor = .tertiaryLabelColor; note.alignment = .center

        let root = NSStackView(views: [icon, title, sub, bullets, plans, lifetime, restore, note])
        root.orientation = .vertical; root.alignment = .centerX; root.spacing = 10
        root.setCustomSpacing(16, after: bullets)
        root.setCustomSpacing(14, after: plans)
        root.edgeInsets = NSEdgeInsets(top: 26, left: 26, bottom: 18, right: 26)
        root.translatesAutoresizingMaskIntoConstraints = false
        cv.addSubview(root)
        NSLayoutConstraint.activate([
            root.leadingAnchor.constraint(equalTo: cv.leadingAnchor),
            root.trailingAnchor.constraint(equalTo: cv.trailingAnchor),
            root.topAnchor.constraint(equalTo: cv.topAnchor),
        ])
        w.layoutIfNeeded()
        w.setContentSize(NSSize(width: 420, height: max(root.fittingSize.height, 440)))
    }
    private func planTitle(_ p: Product) -> String {
        if let intro = p.subscription?.introductoryOffer, intro.paymentMode == .freeTrial {
            return "Start Free Trial — then \(p.displayPrice)"
        }
        return "Subscribe — \(p.displayPrice)"
    }
    @objc private func buy(_ sender: NSButton) {
        guard sender.tag < Store.shared.products.count else { return }
        let p = Store.shared.products[sender.tag]
        Task { _ = await Store.shared.purchase(p) }
    }
    @objc private func buyLifetime() {
        guard let lp = Store.shared.lifetimeProduct else { return }
        Task { _ = await Store.shared.purchase(lp) }
    }
    @objc private func restoreTapped() { Task { await Store.shared.restore() } }
    // Can't close the paywall without subscribing.
    func windowShouldClose(_ sender: NSWindow) -> Bool { false }
}
#endif  // APP_STORE

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

        let github = linkButton("View on GitHub", #selector(openGitHub))
#if APP_STORE
        let links = NSStackView(views: [github])   // App Store handles updates
#else
        let updates = linkButton("Check for Updates…", #selector(checkUpdates))
        let links = NSStackView(views: [github, updates])
#endif
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

final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate, NSMenuDelegate, AVCaptureVideoDataOutputSampleBufferDelegate {
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
    private var pendingSnapshotSave = false             // guarded by bufferLock
    private var pendingSnapshotCopy = false             // guarded by bufferLock
    private var pendingAddPage = false                  // guarded by bufferLock
    private var frozenCGImage: CGImage?                 // main thread; the displayed frozen frame
    private var scanPages: [CGImage] = []               // main thread; collected PDF pages (oriented)
    private let bufferLock = NSLock()
    private let ciContext = CIContext()

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
        checkPermissionAndStart()
#endif

        if Settings.startFullScreen {
            DispatchQueue.main.async { self.window.toggleFullScreen(nil) }
        }
    }

#if APP_STORE
    private var cameraStarted = false
    /// Called on launch and whenever the subscription state changes: reveal the app when
    /// subscribed, otherwise block it behind the paywall.
    private func updateAccess() {
        if Store.shared.isUnlocked {
            Paywall.shared.close()
            window.makeKeyAndOrderFront(nil)
            if !cameraStarted { cameraStarted = true; checkPermissionAndStart() }
        } else {
            window.orderOut(nil)
            Paywall.shared.show()
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
        viewItem.submenu = viewMenu

        let capItem = NSMenuItem(); main.addItem(capItem)
        let capMenu = NSMenu(title: "Capture")
        add(capMenu, "Save Image…", #selector(saveSnapshot), "s", [.command])
        add(capMenu, "Copy Image", #selector(copySnapshot), "c", [.command])
        capMenu.addItem(.separator())
        add(capMenu, "Add Page to Scan", #selector(addScanPage), "a", [.command, .shift])
        add(capMenu, "Save Scan as PDF…", #selector(saveScanPDF), "p", [.command, .shift])
        add(capMenu, "Clear Scan", #selector(clearScan))
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
                self.preview.resetZoom()
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
        // Only convert a frame when something needs it — never hold a pool buffer.
        bufferLock.lock()
        let doFreeze = pendingFreeze; if doFreeze { pendingFreeze = false }
        let doSave = pendingSnapshotSave; if doSave { pendingSnapshotSave = false }
        let doCopy = pendingSnapshotCopy; if doCopy { pendingSnapshotCopy = false }
        let doAddPage = pendingAddPage; if doAddPage { pendingAddPage = false }
        bufferLock.unlock()
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
                do { try png.write(to: url) } catch { self.flashToast("Couldn’t save the image") }
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
        scanPages.append(orientedSnapshot(cg))
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
        }
    }
    @objc private func clearScan() {
        scanPages.removeAll()
        preview.scanCount = 0
        flashToast("Scan cleared")
    }

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

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.regular)
if #available(macOS 14.0, *) { app.activate() } else { app.activate(ignoringOtherApps: true) }
app.run()
