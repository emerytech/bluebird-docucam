import Cocoa
import AVFoundation
import CoreMedia
import CoreVideo
import CoreImage
import QuartzCore

let appName = "BlueBird DocuCam"

// MARK: - Preview view (live video + freeze overlay, with rotation / flip / fill)

final class PreviewView: NSView {
    let previewLayer = AVCaptureVideoPreviewLayer()
    let freezeLayer = CALayer()
    private let messageLabel = NSTextField(labelWithString: "")

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
    var frozen = false { didSet { freezeLayer.isHidden = !frozen } }

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

// MARK: - App

final class AppDelegate: NSObject, NSApplicationDelegate, AVCaptureVideoDataOutputSampleBufferDelegate {
    private var window: NSWindow!
    private var preview: PreviewView!

    private let session = AVCaptureSession()
    private let sessionQueue = DispatchQueue(label: "docucam.session")
    private let frameQueue = DispatchQueue(label: "docucam.frames")
    private let videoOutput = AVCaptureVideoDataOutput()
    private var currentInput: AVCaptureDeviceInput?

    private var latestPixelBuffer: CVPixelBuffer?
    private let bufferLock = NSLock()
    private let ciContext = CIContext()

    private var cameraMenu: NSMenu!
    private var freezeItem: NSMenuItem!
    private var flipHItem: NSMenuItem!
    private var flipVItem: NSMenuItem!
    private var fillItem: NSMenuItem!

    private let kDevice = "deviceID", kRotation = "rotation"
    private let kFlipH = "flipH", kFlipV = "flipV", kFill = "fill"

    // MARK: Lifecycle

    func applicationDidFinishLaunching(_ note: Notification) {
        buildWindow()
        buildMenus()

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

        checkPermissionAndStart()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ s: NSApplication) -> Bool { true }

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
        preview = PreviewView(frame: rect)
        window.contentView = preview
        window.center()
        window.makeKeyAndOrderFront(nil)
    }

    // MARK: Menus

    private func buildMenus() {
        let main = NSMenu()

        let appItem = NSMenuItem(); main.addItem(appItem)
        let appMenu = NSMenu()
        add(appMenu, "About \(appName)", #selector(about))
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
        let activeID = currentInput?.device.uniqueID
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
    }

    private func syncViewMenu() {
        freezeItem.title = preview.frozen ? "Unfreeze (Go Live)" : "Freeze"
        flipHItem.state = preview.flipH ? .on : .off
        flipVItem.state = preview.flipV ? .on : .off
        fillItem.state = preview.fill ? .on : .off
    }

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

    private func configureAndStart() {
        session.beginConfiguration()
        session.sessionPreset = .high
        videoOutput.alwaysDiscardsLateVideoFrames = true
        videoOutput.setSampleBufferDelegate(self, queue: frameQueue)
        if session.canAddOutput(videoOutput) { session.addOutput(videoOutput) }
        session.commitConfiguration()

        preview.previewLayer.session = session

        let saved = UserDefaults.standard.string(forKey: kDevice)
        let devices = availableCameras()
        if let device = devices.first(where: { $0.uniqueID == saved }) ?? preferredDefault(devices) {
            selectDevice(device)
        } else {
            preview.showMessage("No camera found.\n\nPlug in your document camera — it will connect automatically.")
        }
        rebuildCameraMenu()
        sessionQueue.async { if !self.session.isRunning { self.session.startRunning() } }
    }

    private func selectDevice(_ device: AVCaptureDevice) {
        session.beginConfiguration()
        if let cur = currentInput, session.inputs.contains(cur) { session.removeInput(cur) }
        do {
            let input = try AVCaptureDeviceInput(device: device)
            if session.canAddInput(input) { session.addInput(input); currentInput = input }
            preview.showMessage(nil)
        } catch {
            preview.showMessage("Could not open that camera:\n\(error.localizedDescription)")
        }
        session.commitConfiguration()
        UserDefaults.standard.set(device.uniqueID, forKey: kDevice)
        rebuildCameraMenu()
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
        guard let pb = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        bufferLock.lock(); latestPixelBuffer = pb; bufferLock.unlock()
    }

    // MARK: Actions

    @objc private func pickCamera(_ sender: NSMenuItem) {
        if let dev = sender.representedObject as? AVCaptureDevice { selectDevice(dev) }
    }

    @objc private func refreshCameras() {
        rebuildCameraMenu()
        if currentInput == nil, let dev = preferredDefault(availableCameras()) { selectDevice(dev) }
    }

    @objc private func devicesChanged() {
        DispatchQueue.main.async {
            let cams = self.availableCameras()
            let stillHere = self.currentInput.map { cur in cams.contains { $0.uniqueID == cur.device.uniqueID } } ?? false
            if !stillHere {
                self.currentInput = nil
                if let dev = self.preferredDefault(cams) { self.selectDevice(dev) }
                else { self.preview.showMessage("No camera found.\n\nPlug in your document camera — it will connect automatically.") }
            }
            self.rebuildCameraMenu()
        }
    }

    @objc private func toggleFreeze() {
        if !preview.frozen {
            bufferLock.lock(); let pb = latestPixelBuffer; bufferLock.unlock()
            if let pb, let cg = ciContext.createCGImage(CIImage(cvPixelBuffer: pb),
                                                        from: CIImage(cvPixelBuffer: pb).extent) {
                preview.setFreezeImage(cg)
                preview.frozen = true
            }
        } else {
            preview.frozen = false
        }
        syncViewMenu()
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

    @objc private func about() {
        let a = NSAlert()
        a.messageText = appName
        a.informativeText = """
        A simple document-camera viewer.

        Space   Freeze / Go live
        R           Rotate 90°
        H           Flip horizontal (fix backwards text)
        V           Flip vertical
        F           Fill screen / Fit
        ⌃⌘F      Full screen
        ⌘1–9    Choose camera
        """
        a.runModal()
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.regular)
app.activate(ignoringOtherApps: true)
app.run()
