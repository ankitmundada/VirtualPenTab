import Cocoa
import SwiftUI
import Combine
import ApplicationServices
import os.log
import PenCore
import DisplayCore
@preconcurrency import ScreenCaptureKit

// Debug file logger - writes to /tmp/sidescreen.log
func debugLog(_ message: String) {
    let timestamp = DateFormatter.localizedString(from: Date(), dateStyle: .none, timeStyle: .medium)
    let line = "[\(timestamp)] \(message)\n"
    print(message)
    if let data = line.data(using: .utf8) {
        let url = URL(fileURLWithPath: "/tmp/sidescreen.log")
        if let handle = try? FileHandle(forWritingTo: url) {
            handle.seekToEndOfFile()
            handle.write(data)
            handle.closeFile()
        } else {
            try? data.write(to: url)
        }
    }
}

// MARK: - Gesture State Machine

enum GestureState {
    case idle
    case pending          // Touch down, waiting to determine gesture
    case scrolling        // 1-finger scroll
    case longPressReady   // Long press detected, waiting for drag or release
    case dragging         // Long press + drag (left mouse drag)
    case twoFingerScroll  // 2-finger scroll
    case pinching         // Pinch zoom
}

struct GestureThresholds {
    static let tapMaxDistance: CGFloat = 15
    static let tapMaxTime: UInt64 = 250_000_000       // 250ms
    static let doubleTapMaxTime: UInt64 = 400_000_000  // 400ms
    static let doubleTapMaxDistance: CGFloat = 20
    static let longPressTime: UInt64 = 500_000_000     // 500ms
    static let scrollSensitivity: CGFloat = 1.2
    static let pinchMinDistance: CGFloat = 20
    static let minTouchInterval: UInt64 = 8_000_000    // ~120Hz
}

class AppDelegate: NSObject, NSApplicationDelegate {
    var streamingServer: StreamingServer?
    var screenCapture: ScreenCapture?
    var virtualDisplayManager: VirtualDisplayManager?
    var settings = DisplaySettings()
    var settingsWindow: SettingsWindowController?
    var statusItem: NSStatusItem?
    let pairedDeviceStore = PairedDeviceStore()
    /// Name of the wireless device currently streaming (nil when no wireless client is active).
    /// Used to roll its `lastConnected` timestamp forward every status refresh tick so the UI
    /// shows "just now" while connected and freezes at the disconnect moment afterward.
    private var currentWirelessDevice: String?
    private var cancellables = Set<AnyCancellable>()
    private var permissionCheckTimer: Timer?
    private var statusRefreshTimer: Timer?
    /// Reentrancy latch for startServer() — a second Start (double-clicked menu
    /// item, auto-start racing a manual click) must not build a second virtual
    /// display / server. Main-actor confined.
    private var isStartingServer = false
    /// Prevents overlapping in-place display rebuilds.
    private var isReconfiguring = false
    /// Adapts bitrate to what the link actually carries. Only consulted in
    /// automatic mode — a manual bitrate is a deliberate choice to respect.
    private var bitrateController = BitrateController(ceilingMbps: 20)
    var isDaemonMode = false // Deprecated: keeping variable for ABI compatibility but unused

    func applicationDidFinishLaunching(_ notification: Notification) {
        print("✅ App launched")

        // Create menu bar item
        setupMenuBar()

        // Setup settings window
        setupSettingsWindow()

        // Setup settings observers
        setupSettingsObservers()

        // Check permissions
        Task {
            await checkPermissions()
        }

        // Periodic status refresh for the per-mode checklist (ADB / WiFi / Listening IP).
        statusRefreshTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.refreshStatusIndicators()
            }
        }
        // Initial refresh so the UI isn't blank for 2 seconds.
        Task { @MainActor in
            refreshStatusIndicators()
        }

        if #available(macOS 13.0, *) {
            if DaemonManager.shared.isEnabled {
                print("🚀 Launch at Login is enabled - starting silently in background")
                // Do not show settings window automatically.
                // applicationShouldHandleReopen will show it if the user manually launched the app.
            } else {
                showSettings()
            }
        } else {
            showSettings()
        }

        // Declarative auto-start (no Mac interaction): start the server in the
        // chosen Startup mode if enabled. No blocking permission modal here —
        // it cannot be acted on when the Mac is headless.
        if settings.autoStartStreamingOnLaunch {
            settings.connectionMode = settings.startupMode
            Task {
                await self.checkPermissions()
                if self.settings.hasScreenRecordingPermission {
                    await self.startServer()
                } else {
                    debugLog("Auto-start skipped: Screen Recording permission not granted")
                }
            }
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag {
            showSettings()
        }
        return true
    }

    @MainActor
    private func refreshStatusIndicators() {
        settings.adbInstalled = StatusDetector.adbInstalled()
        settings.wifiConnected = StatusDetector.wifiReachable()
        settings.listeningAddress = LANAddressResolver.primaryIPv4()

        // While a wireless client is actively streaming, keep its lastConnected
        // rolling forward so the UI shows "just now". On disconnect, the
        // onClientDisconnected handler clears currentWirelessDevice — from that
        // point lastConnected stays frozen at the disconnect moment, so the
        // "X minutes ago" label counts up correctly.
        if let name = currentWirelessDevice {
            pairedDeviceStore.upsert(name: name, lastConnected: Date())
        }

        let port = Int(settings.port)
        Task.detached { [weak self] in
            let devices = StatusDetector.usbDevices()
            let reverseOK = StatusDetector.adbReverseConfigured(port: port)
            await MainActor.run { [weak self] in
                guard let self = self else { return }
                
                let isConnected = !devices.isEmpty

                self.settings.usbDeviceConnected = isConnected
                self.settings.adbReverseConfigured = reverseOK

                // Self-healing USB bridge (level-triggered, not edge-triggered):
                // whenever we are in USB mode with the server running and a
                // device present but adb reverse missing, (re)establish it.
                // Covers replug, adb-server restart, etc. The server lifecycle
                // is NOT tied to device events — it stays up and the tablet
                // reconnects via its own connect button.
                if self.settings.connectionMode == .usb
                    && isConnected
                    && self.settings.isRunning
                    && !reverseOK {
                    debugLog("🔌 USB bridge missing while running — (re)establishing adb reverse")
                    Task { await self.setupADBReverse() }
                }
            }
        }
    }

    @MainActor
    private func handleConnectionModeChange(to mode: ConnectionMode) async {
        debugLog("Connection mode changed to: \(mode.rawValue)")
        // Disconnect any active client immediately (per spec §6 / fix #2).
        let wasRunning = settings.isRunning
        if wasRunning {
            stopServer()
        }
        if mode == .wireless {
            // Generate token if missing; the QR will reflect it.
            _ = WirelessAuth.loadOrCreate()
        }
        if wasRunning {
            await startServer()
        }
    }

    /// Check permissions on demand (called when settings window opens or manually)
    func refreshPermissions() {
        Task {
            await checkPermissions()
        }
    }

    /// Rebuilds the virtual display and capture pipeline in place, keeping the
    /// client's TCP connection alive.
    ///
    /// A resolution change genuinely requires a new CGVirtualDisplay — its
    /// modes are fixed at creation — but that is no reason to drop the client.
    /// Tearing down StreamingServer closes the socket, so the tablet
    /// disconnects, the user re-pairs, and window positions are lost, which
    /// makes trying different settings needlessly painful.
    ///
    /// The client already handles this: it reinitialises its decoder whenever a
    /// displayConfig arrives, so it just needs the new geometry and a keyframe.
    @MainActor
    func reconfigureDisplay() async {
        guard settings.isRunning, let server = streamingServer, !isReconfiguring else { return }
        isReconfiguring = true
        defer { isReconfiguring = false }

        debugLog("♻️ Reconfiguring display in place — keeping client connected")

        // Display bounds are about to change; a held pen button mapped to the
        // old geometry must not survive into the new one.
        penInjector.reset()

        screenCapture?.stopStreaming()
        screenCapture = nil

        virtualDisplayManager?.saveDisplayPosition()
        virtualDisplayManager?.destroyDisplay()

        do {
            virtualDisplayManager = VirtualDisplayManager()
            let size = settings.resolutionSize
            try virtualDisplayManager?.createDisplay(
                width: size.width,
                height: size.height,
                refreshRate: settings.refreshRate,
                hiDPI: settings.hiDPI,
                name: "SideScreen"
            )
            try? virtualDisplayManager?.disableMirrorMode()

            // Give the window server a moment to register the new display
            // before asking ScreenCaptureKit to find it.
            try? await Task.sleep(nanoseconds: 500_000_000)
            virtualDisplayManager?.restoreDisplayPosition()
            virtualDisplayManager?.applyPreferredMode(
                logicalWidth: size.width, logicalHeight: size.height, hiDPI: settings.hiDPI)

            guard let displayID = virtualDisplayManager?.displayID else {
                debugLog("❌ Reconfigure failed: no display ID — falling back to full restart")
                await restartServerFully()
                return
            }

            screenCapture = try await ScreenCapture()
            screenCapture?.onCaptureMethodChanged = { [weak self] method in
                guard let self = self else { return }
                debugLog("Capture method: \(method)")
                Task { @MainActor in self.settings.captureMethod = method }
            }
            try await screenCapture?.setupForVirtualDisplay(
                displayID, refreshRate: settings.effectiveRefreshRate)

            settings.displayCreated = true

            screenCapture?.startStreaming(
                to: server,
                bitrateMbps: settings.effectiveBitrate,
                quality: settings.effectiveQuality,
                gamingBoost: settings.gamingBoost,
                frameRate: settings.effectiveRefreshRate
            )

            // Tell the still-connected client the new geometry, then force a
            // keyframe so its freshly reinitialised decoder has a reference.
            server.sendDisplaySize()
            screenCapture?.requestKeyframeOrReplayCachedFrame(force: true)

            debugLog("♻️ Reconfigure complete — client stayed connected")
        } catch {
            debugLog("❌ Reconfigure failed: \(error) — falling back to full restart")
            await restartServerFully()
        }
    }

    /// Last resort when an in-place reconfigure cannot complete.
    @MainActor
    private func restartServerFully() async {
        stopServer()
        await startServer()
    }

    func setupSettingsObservers() {
        // Observer cho gaming boost changes
        settings.$gamingBoost
            .dropFirst() // Skip initial value
            .sink { [weak self] gamingBoost in
                guard let self = self, self.settings.isRunning else { return }
                print("🎮 Gaming Boost \(gamingBoost ? "ENABLED" : "DISABLED")")
                self.screenCapture?.updateEncoderSettings(
                    bitrateMbps: self.settings.effectiveBitrate,
                    quality: self.settings.effectiveQuality,
                    gamingBoost: gamingBoost
                )
            }
            .store(in: &cancellables)

        // Encoder settings. Reads the *effective* values rather than the raw
        // ones, so automatic mode picks up a new advisor recommendation the
        // moment a client reports its panel — otherwise auto mode would sit on
        // whatever the manual bitrate happened to be.
        Publishers.Merge4(
            settings.$bitrate.map { _ in () },
            settings.$quality.map { _ in () },
            settings.$autoEncoder.map { _ in () },
            settings.$recommendedBitrate.map { _ in () }
        )
        .dropFirst()
        .sink { [weak self] _ in
            guard let self = self, self.settings.isRunning, !self.settings.gamingBoost else { return }
            let bitrate = self.settings.effectiveBitrate
            let quality = self.settings.effectiveQuality
            print("⚙️ Encoder updated: \(bitrate)Mbps, \(quality)"
                + (self.settings.autoEncoder ? " (automatic)" : ""))
            self.screenCapture?.updateEncoderSettings(
                bitrateMbps: bitrate,
                quality: quality,
                gamingBoost: false
            )
        }
        .store(in: &cancellables)

        Publishers.CombineLatest3(settings.$rotation, settings.$flipHorizontal, settings.$flipVertical)
            .dropFirst()
            .sink { [weak self] rotation, flipHorizontal, flipVertical in
                guard let self = self, self.settings.isRunning else { return }
                print("🔄 Display transform changed: \(rotation)°, h=\(flipHorizontal), v=\(flipVertical)")
                self.streamingServer?.updateDisplayTransform(rotation: rotation, flipHorizontal: flipHorizontal, flipVertical: flipVertical)
            }
            .store(in: &cancellables)

        // Observer cho touch enable/disable - propagate to streaming server so
        // incoming touch frames from the client are dropped early when off.
        settings.$touchEnabled
            .dropFirst()
            .sink { [weak self] enabled in
                self?.streamingServer?.touchEnabled = enabled
            }
            .store(in: &cancellables)

        // Same for stylus input. Turning it off mid-stroke must release any
        // button the pen is holding, or it stays down system-wide.
        settings.$penInputEnabled
            .dropFirst()
            .sink { [weak self] enabled in
                self?.streamingServer?.penInputEnabled = enabled
                if !enabled { self?.penInjector.reset() }
            }
            .store(in: &cancellables)

        // Re-run the advisor when the size preference changes, so the
        // suggestion tracks the picker instead of going stale until reconnect.
        settings.$uiSizePreference
            .dropFirst()
            .sink { [weak self] _ in
                guard let self = self, let panel = self.lastPanelInfo else { return }
                DispatchQueue.main.async { self.handlePanelInfo(panel) }
            }
            .store(in: &cancellables)

        // Observer cho connection mode changes — restart server with new auth/ADB policy.
        settings.$connectionMode
            .dropFirst()
            .sink { [weak self] mode in
                guard let self = self else { return }
                Task { @MainActor in
                    await self.handleConnectionModeChange(to: mode)
                }
            }
            .store(in: &cancellables)

        // Observer cho resolution changes — the virtual display is created at
        // server start, so a new resolution (list row or custom Apply) needs a
        // stop/start cycle to take effect, same as a connection-mode change.
        // Without this, changing resolution mid-run silently did nothing.
        // Resolution, HiDPI and refresh rate all require a new virtual display.
        //
        // Merged and debounced on purpose: applying a recommendation sets
        // several of these at once, and without debouncing each one would kick
        // off its own display rebuild. hiDPI and refreshRate previously had no
        // observer at all, so changing them did nothing until a manual restart.
        // Rotation belongs here too: resolutionSize swaps width and height for
        // 90/270, but that is only read when the display is created. Updating
        // just the client transform left macOS with a landscape desktop being
        // squeezed into a portrait view — the picture came out deformed until
        // the server was restarted by hand.
        Publishers.Merge4(
            settings.$resolution.dropFirst().removeDuplicates().map { _ in () },
            settings.$hiDPI.dropFirst().removeDuplicates().map { _ in () },
            settings.$refreshRate.dropFirst().removeDuplicates().map { _ in () },
            settings.$rotation.dropFirst().removeDuplicates().map { _ in () }
        )
        .debounce(for: .milliseconds(350), scheduler: DispatchQueue.main)
        .sink { [weak self] _ in
            guard let self = self else { return }
            Task { @MainActor in
                guard self.settings.isRunning else { return }
                await self.reconfigureDisplay()
            }
        }
        .store(in: &cancellables)
    }

    func setupMenuBar() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

        if let button = statusItem?.button {
            button.image = NSImage(systemSymbolName: "display.2", accessibilityDescription: "Side Screen")
        }

        // Items are rebuilt on every open (menuNeedsUpdate) so the menu always
        // reflects live server/connection state.
        let menu = NSMenu()
        menu.delegate = self
        menu.autoenablesItems = false
        statusItem?.menu = menu

        // Dim the menu bar icon while the server is stopped — at-a-glance
        // state without opening the menu.
        settings.$isRunning
            .receive(on: DispatchQueue.main)
            .sink { [weak self] running in
                self?.statusItem?.button?.appearsDisabled = !running
            }
            .store(in: &cancellables)
    }

    @objc private func toggleServerFromMenu() {
        if settings.isRunning {
            stopServer()
        } else {
            Task { [weak self] in
                await self?.startServer()
            }
        }
    }

    @objc private func selectUSBMode() {
        guard settings.connectionMode != .usb else { return }
        settings.connectionMode = .usb
    }

    @objc private func selectWirelessMode() {
        guard settings.connectionMode != .wireless else { return }
        settings.connectionMode = .wireless
    }

    func setupSettingsWindow() {
        settingsWindow = SettingsWindowController(settings: settings)

        settings.onToggleServer = { [weak self] in
            guard let self else { return }
            if self.settings.isRunning {
                self.stopServer()
            } else {
                Task { [weak self] in
                    await self?.startServer()
                }
            }
        }
    }

    @objc func showSettings() {
        settingsWindow?.showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func checkPermissions() async {
        let version = ProcessInfo.processInfo.operatingSystemVersion
        debugLog("checkPermissions — macOS \(version.majorVersion).\(version.minorVersion).\(version.patchVersion)")

        // Check Screen Recording permission using CoreGraphics API
        let hasScreenCapture = CGPreflightScreenCaptureAccess()
        await MainActor.run {
            settings.hasScreenRecordingPermission = hasScreenCapture
        }
        if hasScreenCapture {
            debugLog("Screen recording permission granted (CGPreflight)")

            // On macOS 26+, also verify ScreenCaptureKit is actually functional
            if version.majorVersion >= 26 {
                do {
                    let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
                    debugLog("SCShareableContent verification OK — \(content.displays.count) displays found")
                } catch {
                    debugLog("WARNING: CGPreflight OK but SCShareableContent failed on macOS 26: \(error.localizedDescription)")
                    debugLog("CGDisplayStream fallback will likely activate at capture time")
                }
            }
        } else {
            debugLog("Screen recording permission not granted yet")
            CGRequestScreenCaptureAccess()
        }

        // Check Accessibility permission (required for touch/mouse injection)
        await checkAccessibilityPermission()
    }

    func checkAccessibilityPermission() async {
        let trusted = AXIsProcessTrusted()
        await MainActor.run {
            settings.hasAccessibilityPermission = trusted
        }
        if trusted {
            print("✅ Accessibility permission granted")
        } else {
            print("⚠️  Accessibility permission not granted - touch control will not work")
        }
    }

    @MainActor
    func promptAccessibilityPermission() {
        // This will show the system prompt to grant Accessibility permission
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        let trusted = AXIsProcessTrustedWithOptions(options)
        settings.hasAccessibilityPermission = trusted

        if !trusted {
            print("⚠️  User needs to grant Accessibility permission in System Settings")
        }
    }

    /// Setup ADB reverse port forwarding for USB connection
    func setupADBReverse() async {
        let port = settings.port
        print("🔌 Setting up ADB reverse for port \(port)...")
        debugLog("🔌 setupADBReverse() invoked for port \(port)...")

        await Task.detached(priority: .utility) {
            // Try common adb paths
            let adbPaths = [
                "/usr/local/bin/adb",
                "/opt/homebrew/bin/adb",
                "~/Library/Android/sdk/platform-tools/adb",
                "/Users/\(NSUserName())/Library/Android/sdk/platform-tools/adb"
            ]

            var adbPath: String?
            for path in adbPaths {
                let expandedPath = NSString(string: path).expandingTildeInPath
                if FileManager.default.fileExists(atPath: expandedPath) {
                    adbPath = expandedPath
                    break
                }
            }

            // Also try 'which adb' to find it in PATH
            if adbPath == nil {
                let whichProcess = Process()
                whichProcess.executableURL = URL(fileURLWithPath: "/usr/bin/which")
                whichProcess.arguments = ["adb"]
                let whichPipe = Pipe()
                whichProcess.standardOutput = whichPipe
                whichProcess.standardError = FileHandle.nullDevice

                do {
                    try whichProcess.run()
                    whichProcess.waitUntilExit()
                    let data = whichPipe.fileHandleForReading.readDataToEndOfFile()
                    if let path = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
                       !path.isEmpty {
                        adbPath = path
                    }
                } catch {
                    // Ignore
                }
            }

            guard let finalAdbPath = adbPath else {
                print("⚠️  ADB not found - USB connection may not work")
                print("💡 Install Android SDK or run manually: adb reverse tcp:\(port) tcp:\(port)")
                return
            }

            print("📱 Found ADB at: \(finalAdbPath)")

            // Retry adb reverse up to 3 times — handles first-install authorization delay
            for attempt in 1...3 {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: finalAdbPath)
                process.arguments = ["reverse", "tcp:\(port)", "tcp:\(port)"]

                let pipe = Pipe()
                process.standardOutput = pipe
                process.standardError = pipe

                do {
                    try process.run()
                    process.waitUntilExit()

                    let data = pipe.fileHandleForReading.readDataToEndOfFile()
                    let output = String(data: data, encoding: .utf8) ?? ""

                    if process.terminationStatus == 0 {
                        print("✅ ADB reverse setup successful: tcp:\(port) -> tcp:\(port)")
                        return
                    } else {
                        print("⚠️  ADB reverse attempt \(attempt)/3 failed: \(output.trimmingCharacters(in: .whitespacesAndNewlines))")
                        if attempt < 3 {
                            try? await Task.sleep(nanoseconds: 1_000_000_000)
                        }
                    }
                } catch {
                    print("⚠️  Failed to run ADB (attempt \(attempt)/3): \(error.localizedDescription)")
                    if attempt < 3 {
                        try? await Task.sleep(nanoseconds: 1_000_000_000)
                    }
                }
            }

            print("💡 Make sure Android device is connected via USB with debugging enabled")
        }.value
    }

    @MainActor
    func showPermissionAlert() {
        let version = ProcessInfo.processInfo.operatingSystemVersion
        let isMacOS26 = version.majorVersion >= 26

        let alert = NSAlert()
        if isMacOS26 {
            alert.messageText = "Screen & System Audio Recording Permission Required"
            alert.informativeText = "Please grant Screen & System Audio Recording permission in System Settings > Privacy & Security."
        } else {
            alert.messageText = "Screen Recording Permission Required"
            alert.informativeText = "Please grant Screen Recording permission in System Settings > Privacy & Security."
        }
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Open System Settings")
        alert.addButton(withTitle: "Later")

        let response = alert.runModal()
        if response == .alertFirstButtonReturn {
            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!)
        }
    }

    func startServer() async {
        let canStart = await MainActor.run { () -> Bool in
            guard !isStartingServer, !settings.isRunning else { return false }
            isStartingServer = true
            return true
        }
        guard canStart else {
            debugLog("startServer() ignored — already starting or already running")
            return
        }
        defer {
            Task { @MainActor [weak self] in self?.isStartingServer = false }
        }
        debugLog("🚀 startServer() invoked. Check permission: \(settings.hasScreenRecordingPermission)")
        guard settings.hasScreenRecordingPermission else {
            debugLog("❌ startServer aborted: Missing Screen Recording permission")
            await showPermissionAlert()
            return
        }

        do {
            // Create virtual display and run ADB setup in parallel
            virtualDisplayManager = VirtualDisplayManager()
            let size = settings.resolutionSize
            try virtualDisplayManager?.createDisplay(
                width: size.width,
                height: size.height,
                refreshRate: settings.refreshRate,
                hiDPI: settings.hiDPI,
                name: "SideScreen"
            )

            // Disable mirror mode (may fail if already in extend mode)
            do {
                try virtualDisplayManager?.disableMirrorMode()
            } catch {
                // Not critical - continue anyway
            }

            await MainActor.run {
                settings.displayCreated = true
            }

            // Run ADB setup (USB only) and display init wait in parallel.
            // For wireless mode, skip ADB entirely — the auth handshake gates LAN connections instead.
            await withTaskGroup(of: Void.self) { group in
                if settings.connectionMode == .usb {
                    group.addTask { await self.setupADBReverse() }
                } else {
                    debugLog("Wireless mode: skipping ADB setup")
                }
                group.addTask { try? await Task.sleep(nanoseconds: 500_000_000) }
            }

            virtualDisplayManager?.restoreDisplayPosition()

            // macOS otherwise adopts the 1x anchor mode and the desktop comes
            // up at double the intended point size.
            let logical = settings.resolutionSize
            virtualDisplayManager?.applyPreferredMode(
                logicalWidth: logical.width, logicalHeight: logical.height, hiDPI: settings.hiDPI)

            // Verify display is registered in the system
            if let vdm = virtualDisplayManager {
                let registered = vdm.verifyDisplayRegistered()
                if !registered {
                    debugLog("WARNING: Virtual display not found in online display list — capture may fail")
                }
            }

            // Setup capture
            guard let displayID = virtualDisplayManager?.displayID else { return }
            screenCapture = try await ScreenCapture()
            screenCapture?.onCaptureMethodChanged = { [weak self] method in
                guard let self = self else { return }
                debugLog("Capture method: \(method)")
                Task { @MainActor in
                    self.settings.captureMethod = method
                }
            }
            try await screenCapture?.setupForVirtualDisplay(displayID, refreshRate: settings.effectiveRefreshRate)

            // Setup server
            streamingServer = StreamingServer(port: settings.port)
            streamingServer?.touchEnabled = settings.touchEnabled
            streamingServer?.penInputEnabled = settings.penInputEnabled
            if settings.connectionMode == .wireless {
                streamingServer?.expectedAuthToken = WirelessAuth.loadOrCreate()
                streamingServer?.onWirelessClientPaired = { [weak self] deviceName in
                    guard let self = self else { return }
                    Task { @MainActor in
                        self.currentWirelessDevice = deviceName
                        self.settings.currentWirelessDevice = deviceName
                        self.pairedDeviceStore.upsert(name: deviceName, lastConnected: Date())
                    }
                }
            }
            // Send the LOGICAL resolution that the user picked. The H.264 SPS in
            // the stream still carries the true physical pixel dimensions, so the
            // Android decoder/MediaCodec sets up correctly regardless. Sending the
            // logical dimensions here makes the resolution overlay on Android
            // match the Mac's resolution dropdown (e.g. "2560x1600" instead of
            // the HiDPI-doubled "5120x3200").
            streamingServer?.setDisplaySize(width: size.width, height: size.height, rotation: settings.rotation, flipHorizontal: settings.flipHorizontal, flipVertical: settings.flipVertical)
            streamingServer?.onClientConnected = { [weak self] in
                guard let self = self else { return }
                self.screenCapture?.requestKeyframeOrReplayCachedFrame(force: true)
                Task { @MainActor in
                    self.settings.clientConnected = true
                }
            }
            // Runs synchronously on the server's network queue BEFORE the
            // display config is sent, so the config below carries the right
            // dimensions for the negotiated codec.
            streamingServer?.onCodecNegotiated = { [weak self] codec in
                guard let self = self, let capture = self.screenCapture else { return }
                capture.negotiate(codec: codec, clientLimit: self.streamingServer?.clientDecodeLimits)
                let enc = capture.encodeSize(for: codec)
                // Unclamped HEVC keeps the logical user-picked resolution,
                // exactly as at startup; any clamped size (client decoder
                // limit, or the AVC floor) must match what the stream's SPS
                // will carry so the client sizes its decoder correctly.
                let unclampedHevc = codec == .hevc && enc == (capture.displayWidth, capture.displayHeight)
                let (w, h) = unclampedHevc ? (size.width, size.height) : (enc.width, enc.height)
                self.streamingServer?.setDisplaySize(width: w, height: h, rotation: self.settings.rotation, flipHorizontal: self.settings.flipHorizontal, flipVertical: self.settings.flipVertical)
            }
            streamingServer?.onKeyframeRequested = { [weak self] force in
                self?.screenCapture?.requestKeyframeOrReplayCachedFrame(force: force)
            }

            streamingServer?.onClientDisconnected = { [weak self] in
                guard let self = self else { return }
                // Unplugging the cable mid-stroke gives us no touch-up, so
                // release the held button before anything else.
                self.penInjector.reset()
                Task { @MainActor in
                    self.settings.clientConnected = false
                    // Final lastConnected snapshot at the disconnect moment, then
                    // freeze (currentWirelessDevice = nil stops the rolling update
                    // in refreshStatusIndicators).
                    if let name = self.currentWirelessDevice {
                        self.pairedDeviceStore.upsert(name: name, lastConnected: Date())
                        self.currentWirelessDevice = nil
                        self.settings.currentWirelessDevice = nil
                    }
                }
            }

            streamingServer?.onTouchEvent = { [weak self] x, y, action, pointerCount, x2, y2 in
                self?.handleTouch(x: x, y: y, action: action, pointerCount: pointerCount, x2: x2, y2: y2)
            }

            streamingServer?.onPenEvent = { [weak self] sample in
                self?.handlePen(sample)
            }

            streamingServer?.onPanelInfo = { [weak self] info in
                self?.handlePanelInfo(info)
            }

            streamingServer?.onCongestionSample = { [weak self] peakInFlight in
                self?.handleCongestionSample(peakInFlight)
            }

            streamingServer?.onStats = { [weak self] fps, mbps in
                let captured = self
                Task { @MainActor in
                    captured?.settings.currentFPS = fps
                    captured?.settings.currentBitrate = mbps
                }
            }

            streamingServer?.start()
            screenCapture?.startStreaming(
                to: streamingServer,
                bitrateMbps: settings.effectiveBitrate,
                quality: settings.effectiveQuality,
                gamingBoost: settings.gamingBoost,
                frameRate: settings.effectiveRefreshRate
            )

            await MainActor.run {
                settings.isRunning = true
            }

            print("✅ Server started on port \(settings.port)")
        } catch {
            print("❌ Failed to start: \(error)")
            await MainActor.run {
                settings.isRunning = false
                settings.displayCreated = false

                let alert = NSAlert()
                alert.messageText = "Failed to Start Server"
                alert.informativeText = error.localizedDescription
                alert.alertStyle = .critical
                alert.runModal()
            }
        }
    }

    func stopServer() {
        // Before anything else: a stroke in progress must not leave its mouse
        // button held down once the server is gone.
        penInjector.reset()

        // Save display position before destroying
        virtualDisplayManager?.saveDisplayPosition()

        screenCapture?.stopStreaming()
        streamingServer?.stop()
        virtualDisplayManager?.destroyDisplay()

        settings.isRunning = false
        settings.displayCreated = false
        settings.clientConnected = false
        settings.currentFPS = 0
        settings.currentBitrate = 0

        print("⏹️ Server stopped")
    }

    // MARK: - Gesture Properties

    private let eventSource = CGEventSource(stateID: .hidSystemState)
    /// Stylus events bypass the gesture state machine below entirely.
    private let penInjector = PenInjector()
    private var accessibilityWarningShown = false
    private var gestureState: GestureState = .idle
    private var lastTouchTime: UInt64 = 0

    // Touch tracking
    private var touchStartPosition: CGPoint = .zero
    private var touchLastPosition: CGPoint = .zero
    private var touchStartTime: UInt64 = 0
    private var touchLastMoveTime: UInt64 = 0
    private var lastScrollDeltaX: CGFloat = 0
    private var lastScrollDeltaY: CGFloat = 0

    // Double tap tracking
    private var lastTapTime: UInt64 = 0
    private var lastTapPosition: CGPoint = .zero

    // Long press timer
    private var longPressTimer: DispatchWorkItem?

    // 2-finger tracking
    private var initialPinchDistance: CGFloat = 0
    private var lastPinchDistance: CGFloat = 0

    // Momentum scrolling
    private var momentumTimer: Timer?
    private var momentumVelocityX: CGFloat = 0
    private var momentumVelocityY: CGFloat = 0
    private var lastMomentumPosition: CGPoint = .zero

    // MARK: - Touch Entry Point

    func handleTouch(x: Float, y: Float, action: Int, pointerCount: Int = 1, x2: Float = 0, y2: Float = 0) {
        guard settings.touchEnabled else { return }

        if !AXIsProcessTrusted() {
            if !accessibilityWarningShown {
                accessibilityWarningShown = true
                print("⚠️  Accessibility not granted - touch ignored")
                Task { @MainActor in
                    settings.hasAccessibilityPermission = false
                }
            }
            return
        }

        guard let displayID = virtualDisplayManager?.displayID else { return }
        let bounds = CGDisplayBounds(displayID)

        let p1 = CGPoint(
            x: bounds.origin.x + CGFloat(x) * bounds.width,
            y: bounds.origin.y + CGFloat(y) * bounds.height
        )
        let p2 = CGPoint(
            x: bounds.origin.x + CGFloat(x2) * bounds.width,
            y: bounds.origin.y + CGFloat(y2) * bounds.height
        )

        if pointerCount >= 2 {
            handleTwoFingerTouch(p1: p1, p2: p2, action: action)
        } else {
            handleOneFingerTouch(at: p1, action: action)
        }
    }

    // MARK: - Congestion

    /// Feeds the send backlog to the bitrate controller and applies the result.
    ///
    /// Automatic mode only. If someone has chosen a bitrate by hand, silently
    /// overriding it would be worse than the stutter — the manual setting is an
    /// instruction, not a suggestion.
    private func handleCongestionSample(_ peakInFlightBytes: Int) {
        guard settings.isRunning, settings.autoEncoder, !settings.gamingBoost else { return }

        let ceiling = settings.recommendedBitrate > 0 ? settings.recommendedBitrate : settings.bitrate
        if bitrateController.ceilingMbps != ceiling {
            bitrateController.updateCeiling(ceiling)
        }

        let previous = bitrateController.currentMbps
        let next = bitrateController.observe(inFlightBytes: peakInFlightBytes)
        guard next != previous else { return }

        debugLog("📉 Link \(next < previous ? "congested" : "recovering"): "
            + "\(previous) → \(next) Mbps (backlog \(peakInFlightBytes / 1024) KB)")

        screenCapture?.updateEncoderSettings(
            bitrateMbps: next,
            quality: settings.effectiveQuality,
            gamingBoost: false
        )

        Task { @MainActor in
            self.settings.adaptiveBitrate = next
            self.settings.isLinkThrottled = self.bitrateController.isThrottled
        }
    }

    // MARK: - Panel Info

    /// Computes a settings recommendation from the client's real panel.
    ///
    /// Advisory only — it is surfaced in Settings rather than applied, because
    /// the "right" UI size depends on viewing distance and eyesight and so
    /// cannot be derived from geometry alone.
    /// Last panel the client reported, kept so the recommendation can be
    /// recomputed when the UI size preference changes without waiting for a
    /// reconnect.
    private var lastPanelInfo: PanelInfo?

    private func handlePanelInfo(_ info: PanelInfo) {
        lastPanelInfo = info
        let recommendation = DisplayAdvisor.recommend(
            panel: info,
            decoderMax: streamingServer?.clientDecodeLimits,
            link: settings.connectionMode == .wireless ? .wireless : .usb,
            preference: settings.uiSizePreference
        )

        debugLog(String(format: "📐 Client panel: %dx%d, %.1f in, %.0f ppi, %d Hz",
                        info.widthPx, info.heightPx, info.diagonalInches,
                        info.ppi, info.refreshHz))
        debugLog("📐 Recommended: \(recommendation.width)x\(recommendation.height)"
            + (recommendation.hiDPI ? " HiDPI" : "")
            + " @ \(recommendation.refreshHz)Hz, \(recommendation.bitrateMbps) Mbps"
            + (recommendation.pixelExact ? " (pixel-exact)" : ""))
        for note in recommendation.notes { debugLog("📐   note: \(note)") }

        Task { @MainActor in
            self.settings.clientPanelSummary = String(
                format: "%dx%d · %.1f in · %.0f ppi · %d Hz",
                info.widthPx, info.heightPx, info.diagonalInches, info.ppi, info.refreshHz)
            self.settings.recommendedSummary = "\(recommendation.width)x\(recommendation.height)"
                + (recommendation.hiDPI ? " HiDPI" : "")
                + " · \(recommendation.refreshHz) Hz · \(recommendation.bitrateMbps) Mbps"
            self.settings.recommendedResolution = "\(recommendation.width)x\(recommendation.height)"
            self.settings.recommendedHiDPI = recommendation.hiDPI
            self.settings.recommendedRefreshRate = recommendation.refreshHz
            self.settings.recommendedBitrate = recommendation.bitrateMbps
        }
    }

    // MARK: - Pen Entry Point

    /// Stylus samples go straight to PenInjector — no gesture recognition, no
    /// long-press wait, no scroll heuristic. See docs/pen-support-design.md §6.
    func handlePen(_ sample: PenSample) {
        guard settings.touchEnabled, settings.penInputEnabled else { return }

        guard AXIsProcessTrusted() else {
            if !accessibilityWarningShown {
                accessibilityWarningShown = true
                print("⚠️  Accessibility not granted - pen input ignored")
                Task { @MainActor in
                    settings.hasAccessibilityPermission = false
                }
            }
            return
        }

        guard let displayID = virtualDisplayManager?.displayID else { return }
        penInjector.handle(sample, in: CGDisplayBounds(displayID))
    }

    // MARK: - 1-Finger Gesture State Machine

    private func handleOneFingerTouch(at point: CGPoint, action: Int) {
        switch action {
        case 0: oneFingerDown(at: point)
        case 1: oneFingerMove(to: point)
        case 2: oneFingerUp(at: point)
        default: break
        }
    }

    private func oneFingerDown(at point: CGPoint) {
        stopMomentumScroll()
        cancelLongPressTimer()

        touchStartPosition = point
        touchLastPosition = point
        touchStartTime = DispatchTime.now().uptimeNanoseconds
        touchLastMoveTime = touchStartTime
        gestureState = .pending

        // Move cursor to touch position (absolute)
        moveCursor(to: point)

        // Start long press timer
        let timer = DispatchWorkItem { [weak self] in
            guard let self, self.gestureState == .pending else { return }
            self.gestureState = .longPressReady
        }
        longPressTimer = timer
        DispatchQueue.main.asyncAfter(
            deadline: .now() + .nanoseconds(Int(GestureThresholds.longPressTime)),
            execute: timer
        )
    }

    private func oneFingerMove(to point: CGPoint) {
        let now = DispatchTime.now().uptimeNanoseconds
        if now - lastTouchTime < GestureThresholds.minTouchInterval { return }
        lastTouchTime = now

        let deltaX = point.x - touchLastPosition.x
        let deltaY = point.y - touchLastPosition.y
        let totalDistance = hypot(point.x - touchStartPosition.x, point.y - touchStartPosition.y)

        switch gestureState {
        case .pending:
            if totalDistance > GestureThresholds.tapMaxDistance {
                cancelLongPressTimer()
                gestureState = .scrolling
                let sx = deltaX * GestureThresholds.scrollSensitivity
                let sy = deltaY * GestureThresholds.scrollSensitivity
                injectScrollEvent(deltaX: sx, deltaY: sy, at: point)
                lastScrollDeltaX = sx
                lastScrollDeltaY = sy
            }

        case .longPressReady:
            if totalDistance > GestureThresholds.tapMaxDistance {
                // Long press + drag → left mouse drag
                gestureState = .dragging
                injectMouseDown(at: touchStartPosition)
                injectMouseDragged(to: point)
            }

        case .scrolling:
            let sx = deltaX * GestureThresholds.scrollSensitivity
            let sy = deltaY * GestureThresholds.scrollSensitivity
            injectScrollEvent(deltaX: sx, deltaY: sy, at: point)
            let timeDelta = now - touchLastMoveTime
            if timeDelta > 0 && timeDelta < 100_000_000 {
                lastScrollDeltaX = sx
                lastScrollDeltaY = sy
            }

        case .dragging:
            injectMouseDragged(to: point)

        default:
            break
        }

        touchLastPosition = point
        touchLastMoveTime = now
    }

    private func oneFingerUp(at point: CGPoint) {
        cancelLongPressTimer()
        let now = DispatchTime.now().uptimeNanoseconds
        let elapsed = now - touchStartTime
        let distance = hypot(point.x - touchStartPosition.x, point.y - touchStartPosition.y)

        switch gestureState {
        case .pending:
            // Quick release, no movement → tap or double tap
            if distance < GestureThresholds.tapMaxDistance && elapsed < GestureThresholds.tapMaxTime {
                // Check double tap
                let timeSinceLastTap = now - lastTapTime
                let distFromLastTap = hypot(point.x - lastTapPosition.x, point.y - lastTapPosition.y)

                if timeSinceLastTap < GestureThresholds.doubleTapMaxTime
                    && distFromLastTap < GestureThresholds.doubleTapMaxDistance {
                    performDoubleClick(at: point)
                    lastTapTime = 0  // Reset so triple tap doesn't trigger
                } else {
                    performClick(at: point)
                    lastTapTime = now
                    lastTapPosition = point
                }
            }

        case .longPressReady:
            // Held long but didn't drag → right click
            performRightClick(at: point)

        case .scrolling:
            // Check momentum
            let timeSinceLastMove = now - touchLastMoveTime
            if timeSinceLastMove < 50_000_000 {
                let threshold: CGFloat = 2.0
                if abs(lastScrollDeltaX) > threshold || abs(lastScrollDeltaY) > threshold {
                    startMomentumScroll(
                        velocityX: lastScrollDeltaX * 6.0,
                        velocityY: lastScrollDeltaY * 6.0,
                        at: point
                    )
                }
            }

        case .dragging:
            injectMouseUp(at: point)

        default:
            break
        }

        gestureState = .idle
    }

    // MARK: - 2-Finger Gestures

    private func handleTwoFingerTouch(p1: CGPoint, p2: CGPoint, action: Int) {
        let distance = hypot(p2.x - p1.x, p2.y - p1.y)
        let midpoint = CGPoint(x: (p1.x + p2.x) / 2, y: (p1.y + p2.y) / 2)

        switch action {
        case 0: // Down
            cancelLongPressTimer()
            stopMomentumScroll()
            gestureState = .idle  // Reset so 2-finger detection starts fresh
            initialPinchDistance = distance
            lastPinchDistance = distance
            touchLastPosition = midpoint

        case 1: // Move
            let distanceChange = abs(distance - initialPinchDistance)
            let midDelta = hypot(midpoint.x - touchLastPosition.x, midpoint.y - touchLastPosition.y)

            // Determine mode if not yet decided
            if gestureState != .twoFingerScroll && gestureState != .pinching {
                if distanceChange > GestureThresholds.pinchMinDistance {
                    gestureState = .pinching
                } else if midDelta > GestureThresholds.tapMaxDistance {
                    gestureState = .twoFingerScroll
                }
            }

            switch gestureState {
            case .twoFingerScroll:
                let dx = (midpoint.x - touchLastPosition.x) * GestureThresholds.scrollSensitivity
                let dy = (midpoint.y - touchLastPosition.y) * GestureThresholds.scrollSensitivity
                injectScrollEvent(deltaX: dx, deltaY: dy, at: midpoint)

            case .pinching:
                let scaleDelta = distance - lastPinchDistance
                // Cmd + scroll = zoom in most Mac apps
                let zoomAmount = Int32(scaleDelta * 0.5)
                if zoomAmount != 0 {
                    injectZoomEvent(delta: zoomAmount, at: midpoint)
                }
                lastPinchDistance = distance

            default:
                break
            }

            touchLastPosition = midpoint

        case 2: // Up
            gestureState = .idle
            // Reset 1-finger tracking so leftover moves don't trigger scroll
            touchStartPosition = .zero
            touchLastPosition = .zero

        default:
            break
        }
    }

    // MARK: - Event Injection

    private func moveCursor(to point: CGPoint) {
        if let event = CGEvent(mouseEventSource: eventSource, mouseType: .mouseMoved, mouseCursorPosition: point, mouseButton: .left) {
            event.post(tap: .cghidEventTap)
        }
    }

    private func performClick(at point: CGPoint) {
        if let down = CGEvent(mouseEventSource: eventSource, mouseType: .leftMouseDown, mouseCursorPosition: point, mouseButton: .left) {
            down.setIntegerValueField(.mouseEventClickState, value: 1)
            down.post(tap: .cghidEventTap)
        }
        if let up = CGEvent(mouseEventSource: eventSource, mouseType: .leftMouseUp, mouseCursorPosition: point, mouseButton: .left) {
            up.setIntegerValueField(.mouseEventClickState, value: 1)
            up.post(tap: .cghidEventTap)
        }
    }

    private func performDoubleClick(at point: CGPoint) {
        if let down = CGEvent(mouseEventSource: eventSource, mouseType: .leftMouseDown, mouseCursorPosition: point, mouseButton: .left) {
            down.setIntegerValueField(.mouseEventClickState, value: 2)
            down.post(tap: .cghidEventTap)
        }
        if let up = CGEvent(mouseEventSource: eventSource, mouseType: .leftMouseUp, mouseCursorPosition: point, mouseButton: .left) {
            up.setIntegerValueField(.mouseEventClickState, value: 2)
            up.post(tap: .cghidEventTap)
        }
    }

    private func performRightClick(at point: CGPoint) {
        if let down = CGEvent(mouseEventSource: eventSource, mouseType: .rightMouseDown, mouseCursorPosition: point, mouseButton: .right) {
            down.post(tap: .cghidEventTap)
        }
        if let up = CGEvent(mouseEventSource: eventSource, mouseType: .rightMouseUp, mouseCursorPosition: point, mouseButton: .right) {
            up.post(tap: .cghidEventTap)
        }
    }

    private func injectMouseDown(at point: CGPoint) {
        if let event = CGEvent(mouseEventSource: eventSource, mouseType: .leftMouseDown, mouseCursorPosition: point, mouseButton: .left) {
            event.setIntegerValueField(.mouseEventClickState, value: 1)
            event.post(tap: .cghidEventTap)
        }
    }

    private func injectMouseDragged(to point: CGPoint) {
        if let event = CGEvent(mouseEventSource: eventSource, mouseType: .leftMouseDragged, mouseCursorPosition: point, mouseButton: .left) {
            event.post(tap: .cghidEventTap)
        }
    }

    private func injectMouseUp(at point: CGPoint) {
        if let event = CGEvent(mouseEventSource: eventSource, mouseType: .leftMouseUp, mouseCursorPosition: point, mouseButton: .left) {
            event.post(tap: .cghidEventTap)
        }
    }

    private func injectScrollEvent(deltaX: CGFloat, deltaY: CGFloat, at position: CGPoint) {
        guard let scrollEvent = CGEvent(
            scrollWheelEvent2Source: eventSource,
            units: .pixel,
            wheelCount: 2,
            wheel1: Int32(deltaY),
            wheel2: Int32(deltaX),
            wheel3: 0
        ) else { return }
        scrollEvent.location = position
        scrollEvent.post(tap: .cghidEventTap)
    }

    private func injectZoomEvent(delta: Int32, at position: CGPoint) {
        guard let scrollEvent = CGEvent(
            scrollWheelEvent2Source: eventSource,
            units: .pixel,
            wheelCount: 1,
            wheel1: delta,
            wheel2: 0,
            wheel3: 0
        ) else { return }
        scrollEvent.location = position
        // Set Cmd flag for zoom
        scrollEvent.flags = .maskCommand
        scrollEvent.post(tap: .cghidEventTap)
    }

    // MARK: - Long Press Timer

    private func cancelLongPressTimer() {
        longPressTimer?.cancel()
        longPressTimer = nil
    }

    // MARK: - Momentum Scrolling

    private func startMomentumScroll(velocityX: CGFloat, velocityY: CGFloat, at position: CGPoint) {
        stopMomentumScroll()
        momentumVelocityX = velocityX
        momentumVelocityY = velocityY
        lastMomentumPosition = position
        momentumTimer = Timer.scheduledTimer(withTimeInterval: 0.016, repeats: true) { [weak self] _ in
            self?.momentumTick()
        }
    }

    private func momentumTick() {
        let decay: CGFloat = 0.92
        let minVelocity: CGFloat = 0.5

        if abs(momentumVelocityX) < minVelocity && abs(momentumVelocityY) < minVelocity {
            stopMomentumScroll()
            return
        }

        injectScrollEvent(deltaX: momentumVelocityX, deltaY: momentumVelocityY, at: lastMomentumPosition)
        momentumVelocityX *= decay
        momentumVelocityY *= decay
    }

    private func stopMomentumScroll() {
        momentumTimer?.invalidate()
        momentumTimer = nil
        momentumVelocityX = 0
        momentumVelocityY = 0
    }

    func applicationWillTerminate(_ notification: Notification) {
        // Stop momentum scrolling
        stopMomentumScroll()

        // Stop server and cleanup
        stopServer()

        // Cancel all combine subscriptions
        cancellables.removeAll()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        return false
    }
}

// MARK: - Menu bar quick actions

extension AppDelegate: NSMenuDelegate {
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()

        // Live status line (not clickable)
        let statusTitle: String
        if settings.isRunning {
            if settings.clientConnected {
                let device = settings.currentWirelessDevice ?? "tablet"
                statusTitle = "🟢 Connected — \(device)"
            } else {
                statusTitle = "🟡 Waiting for tablet on port \(settings.port)"
            }
        } else {
            statusTitle = "⚪️ Server stopped"
        }
        let statusLine = NSMenuItem(title: statusTitle, action: nil, keyEquivalent: "")
        statusLine.isEnabled = false
        menu.addItem(statusLine)
        menu.addItem(.separator())

        // Start / Stop
        let toggle = NSMenuItem(
            title: settings.isRunning ? "Stop Streaming" : "Start Streaming",
            action: #selector(toggleServerFromMenu),
            keyEquivalent: "t"
        )
        toggle.target = self
        // Mirror the settings-window Start button: starting needs the Screen
        // Recording permission, stopping is always allowed.
        toggle.isEnabled = settings.isRunning || settings.hasScreenRecordingPermission
        menu.addItem(toggle)

        // Connection mode (switching while running restarts the server, same
        // as changing it in the settings window)
        let modeMenu = NSMenu()
        modeMenu.autoenablesItems = false
        let usb = NSMenuItem(title: "USB", action: #selector(selectUSBMode), keyEquivalent: "")
        usb.target = self
        usb.state = settings.connectionMode == .usb ? .on : .off
        modeMenu.addItem(usb)
        let wireless = NSMenuItem(title: "Wireless", action: #selector(selectWirelessMode), keyEquivalent: "")
        wireless.target = self
        wireless.state = settings.connectionMode == .wireless ? .on : .off
        modeMenu.addItem(wireless)
        let modeItem = NSMenuItem(title: "Connection Mode", action: nil, keyEquivalent: "")
        modeItem.submenu = modeMenu
        menu.addItem(modeItem)

        menu.addItem(.separator())

        let settingsItem = NSMenuItem(title: "Settings…", action: #selector(showSettings), keyEquivalent: "s")
        settingsItem.target = self
        menu.addItem(settingsItem)

        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit Side Screen", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
    }
}
