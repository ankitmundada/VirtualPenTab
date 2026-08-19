import Cocoa
import SwiftUI
import DisplayCore

// MARK: - Frosted GroupBox Component

struct FrostedGroupBox<Content: View, Trailing: View>: View {
    let title: String
    var icon: String?
    @ViewBuilder let content: Content
    @ViewBuilder let trailing: Trailing

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                if let icon = icon {
                    Image(systemName: icon)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(.accentColor)
                }
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                Spacer()
                trailing
            }
            content
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(.ultraThinMaterial)
        }
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
        }
    }
}

extension FrostedGroupBox where Trailing == EmptyView {
    init(title: String, icon: String? = nil, @ViewBuilder content: () -> Content) {
        self.title = title
        self.icon = icon
        self.content = content()
        self.trailing = EmptyView()
    }
}

// MARK: - Visual Effect Blur

struct VisualEffectBlur: NSViewRepresentable {
    var material: NSVisualEffectView.Material
    var blendingMode: NSVisualEffectView.BlendingMode
    var state: NSVisualEffectView.State = .active

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material
        view.blendingMode = blendingMode
        view.state = state
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {
        nsView.material = material
        nsView.blendingMode = blendingMode
        nsView.state = state
    }
}


/// Removes the toolbar's sidebar toggle where the API exists.
///
/// The sidebar is pinned open, so the toggle would be inert — and worse, when
/// the column collapses the button jumps to the right-hand side as the layout
/// reflows. `toolbar(removing:)` is macOS 14+, so on Ventura the button stays
/// but the pinned binding keeps it from collapsing anything.
private extension View {
    @ViewBuilder
    func hidingSidebarToggle() -> some View {
        if #available(macOS 14.0, *) {
            self.toolbar(removing: .sidebarToggle)
        } else {
            self
        }
    }
}

// MARK: - Settings View

struct SettingsView: View {
    @ObservedObject var settings: DisplaySettings
    @State private var showPermissionAlert = false
    @State private var showResetConfirmation = false
    @State private var headerHovered = false
    // Plain strings for the custom resolution fields: TextField(value:format:)
    // only commits on Return/focus-loss, so clicking Apply read stale values,
    // and .number formatting injected locale grouping separators ("1,200").
    @State private var customWidthText = ""
    @State private var customHeightText = ""
    @State private var daemonEnabled = false

    private var customWidthValue: Int? { Int(customWidthText.trimmingCharacters(in: .whitespaces)) }
    private var customHeightValue: Int? { Int(customHeightText.trimmingCharacters(in: .whitespaces)) }
    private var customResolutionValid: Bool {
        guard let w = customWidthValue, let h = customHeightValue else { return false }
        return DisplaySettings.isValidCustomResolution(width: w, height: h)
    }
    @State private var page: SettingsPage = .connect

    var body: some View {
        // .doubleColumn rather than .automatic: with .automatic the toolbar's
        // sidebar toggle can collapse the column, and the button then jumps
        // across to the right-hand side as the layout reflows.
        NavigationSplitView(columnVisibility: .constant(.doubleColumn)) {
            sidebar
                .navigationSplitViewColumnWidth(min: 200, ideal: 216, max: 260)
                .hidingSidebarToggle()
        } detail: {
            detailPane
        }
        .navigationSplitViewStyle(.balanced)
        .navigationTitle("")
        .frame(minWidth: 900, minHeight: 620)
    }

    // MARK: - Sidebar

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                ZStack {
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .fill(Color.accentColor)
                        .frame(width: 30, height: 30)
                    Image(systemName: "rectangle.on.rectangle")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundColor(.white)
                }
                VStack(alignment: .leading, spacing: 1) {
                    Text("Side Screen")
                        .font(.system(size: 13, weight: .semibold))
                    Text(settings.isRunning ? "Running" : "Stopped")
                        .font(.system(size: 10))
                        .foregroundColor(settings.isRunning ? .green : .secondary)
                }
                Spacer()
            }
            .padding(.horizontal, 14)
            .padding(.top, 14)
            .padding(.bottom, 10)

            List(selection: $page) {
                ForEach(SettingsPage.allCases) { item in
                    Label(item.title, systemImage: item.icon)
                        .tag(item)
                }
            }
            .listStyle(.sidebar)

            Divider().opacity(0.4)

            HStack(spacing: 8) {
                Button {
                    showResetConfirmation = true
                } label: {
                    Label("Reset", systemImage: "arrow.counterclockwise")
                        .font(.system(size: 11))
                }
                .buttonStyle(.borderless)
                .help("Reset all settings to defaults")

                Spacer()

                Button {
                    NSApp.terminate(nil)
                } label: {
                    Label("Quit", systemImage: "power")
                        .font(.system(size: 11))
                }
                .buttonStyle(.borderless)
                .help("Quit Side Screen (⌘Q)")
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .alert("Reset Settings", isPresented: $showResetConfirmation) {
                Button("Cancel", role: .cancel) { }
                Button("Reset", role: .destructive) { settings.resetToDefaults() }
            } message: {
                Text("This will reset all settings to default values.")
            }
        }
    }

    // MARK: - Detail

    private var detailPane: some View {
        VStack(spacing: 0) {
            detailHeader
            Divider().opacity(0.4)
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    switch page {
                    case .connect:  connectPage
                    case .display:  displayPage
                    case .input:    inputPage
                    case .advanced: advancedPage
                    }
                }
                .padding(22)
                .frame(maxWidth: 760, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .topLeading)
            }
        }
    }

    /// Start/Stop lives here rather than in a page, so the primary action is
    /// reachable from every screen instead of below ten sections of settings.
    private var detailHeader: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(page.title)
                    .font(.system(size: 17, weight: .semibold))
                Text(page.subtitle)
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
            }

            Spacer()

            if settings.isRunning {
                HStack(spacing: 5) {
                    Circle().fill(Color.green).frame(width: 7, height: 7)
                    Text("Port \(settings.port)")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundColor(.secondary)
                }
            }

            Button {
                withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
                    settings.toggleServer()
                }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: settings.isRunning ? "stop.fill" : "play.fill")
                        .font(.system(size: 11))
                    Text(settings.isRunning ? "Stop" : "Start")
                        .font(.system(size: 13, weight: .medium))
                }
                .frame(width: 78)
            }
            .buttonStyle(.borderedProminent)
            .tint(settings.isRunning ? .red : .accentColor)
            .controlSize(.large)
            .disabled(!settings.hasScreenRecordingPermission)
            .help(settings.hasScreenRecordingPermission
                  ? "Start or stop the virtual display"
                  : "Screen Recording permission is required")
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 14)
    }

    // MARK: - Pages

    @ViewBuilder
    private var connectPage: some View {
        modePicker

        // Wireless pairing is the one thing that changes in this mode, so it
        // comes first instead of being buried below the fold.
        wirelessSection

        statusSection
        performanceSection
        networkSection
    }

    @ViewBuilder
    private var displayPage: some View {
        recommendedSection
        displaySection
        refreshSection
    }

    @ViewBuilder
    private var inputPage: some View {
        touchSection
    }

    @ViewBuilder
    private var advancedPage: some View {
        streamingSection
        gamingSection
        startupSection
    }

    private var modePicker: some View {
        HStack(spacing: 6) {
            ForEach(ConnectionMode.allCases, id: \.self) { mode in
                Button(action: { settings.connectionMode = mode }) {
                    HStack(spacing: 5) {
                        Image(systemName: mode == .usb ? "cable.connector" : "wifi")
                        Text(mode == .usb ? "USB" : "Wireless")
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 7)
                    .background(settings.connectionMode == mode ? Color.accentColor : Color.clear)
                    .foregroundColor(settings.connectionMode == mode ? .white : .primary)
                    .cornerRadius(6)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(4)
        .background(.ultraThinMaterial)
        .cornerRadius(8)
    }

    @ViewBuilder
    private var displaySection: some View {
        FrostedGroupBox(title: "Display Configuration", icon: "display") {
            VStack(alignment: .leading, spacing: 16) {
                // Resolution
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("Resolution")
                            .font(.system(size: 11))
                            .foregroundColor(.secondary)
                        Spacer()
                        Toggle("Show all", isOn: $settings.showAllResolutions)
                            .toggleStyle(.switch)
                            .controlSize(.mini)
                    }

                    // Deliberately not a ScrollView. This sits inside the page's
                    // own scroll view, and nesting the two means the inner list
                    // captures the wheel with no way to tell which will move.
                    // The window is resizable now, so the list can simply be as
                    // tall as it needs to be.
                    VStack(alignment: .leading, spacing: 0) {
                        Group {
                            if settings.showAllResolutions {
                                // Custom (Apply) values aren't in any preset group —
                                // surface them so the selection is visible in the list.
                                if !DisplaySettings.allResolutions.contains(settings.resolution) {
                                    HStack(spacing: 6) {
                                        Text("Custom")
                                            .font(.system(size: 11, weight: .semibold))
                                        Text("User defined")
                                            .font(.system(size: 10))
                                            .foregroundColor(.secondary)
                                    }
                                    .padding(.horizontal, 12)
                                    .padding(.vertical, 6)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .background(Color.primary.opacity(0.03))

                                    ResolutionRow(resolution: settings.resolution, isSelected: true) {}
                                }
                                ForEach(DisplaySettings.resolutionGroups) { group in
                                    HStack(spacing: 6) {
                                        Text(group.name)
                                            .font(.system(size: 11, weight: .semibold))
                                        Text(group.ratio)
                                            .font(.system(size: 10))
                                            .foregroundColor(.secondary)
                                    }
                                    .padding(.horizontal, 12)
                                    .padding(.vertical, 6)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .background(Color.primary.opacity(0.03))

                                    ForEach(group.resolutions, id: \.self) { res in
                                        ResolutionRow(resolution: res, isSelected: settings.resolution == res) {
                                            settings.resolution = res
                                        }
                                    }
                                }
                            } else {
                                ForEach(DisplaySettings.commonResolutions, id: \.self) { res in
                                    ResolutionRow(resolution: res, isSelected: settings.resolution == res) {
                                        settings.resolution = res
                                    }
                                }
                                // Current selection from the full list or a custom
                                // Apply — keep it visible in the compact list too.
                                if !DisplaySettings.commonResolutions.contains(settings.resolution) {
                                    ResolutionRow(resolution: settings.resolution, isSelected: true) {}
                                }
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.ultraThinMaterial)
                    .cornerRadius(8)
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .strokeBorder(Color.primary.opacity(0.1), lineWidth: 1)
                    )

                    if settings.showAllResolutions {
                        HStack(spacing: 8) {
                            TextField("W", text: $customWidthText)
                                .textFieldStyle(.roundedBorder)
                                .frame(width: 70)
                            Text("x")
                                .foregroundColor(.secondary)
                            TextField("H", text: $customHeightText)
                                .textFieldStyle(.roundedBorder)
                                .frame(width: 70)
                            Button("Apply") {
                                guard customResolutionValid,
                                      let w = customWidthValue,
                                      let h = customHeightValue else { return }
                                settings.customWidth = w
                                settings.customHeight = h
                                settings.applyCustomResolution()
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                            .disabled(!customResolutionValid)
                        }
                        .onAppear {
                            customWidthText = String(settings.customWidth)
                            customHeightText = String(settings.customHeight)
                        }
                        if !customResolutionValid {
                            Text("Supported range: 640–7680 × 480–4320")
                                .font(.system(size: 10))
                                .foregroundColor(.orange)
                        }
                    }
                }

                // HiDPI (Retina)
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("HiDPI (Retina)")
                            .font(.system(size: 11))
                            .foregroundColor(.secondary)
                        Text("Renders at 2× resolution for sharper text. Increases bandwidth.")
                            .font(.system(size: 10))
                            .foregroundColor(.secondary.opacity(0.7))
                    }
                    Spacer()
                    Toggle("", isOn: $settings.hiDPI)
                        .toggleStyle(.switch)
                        .controlSize(.mini)
                        .disabled(settings.isRunning)
                }

                // Rotation
                VStack(alignment: .leading, spacing: 8) {
                    Text("Rotation")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)

                    HStack(spacing: 12) {
                        ZStack {
                            RoundedRectangle(cornerRadius: 4)
                                .stroke(Color.accentColor.opacity(0.5), lineWidth: 1)
                                .frame(width: 80, height: 50)
                                .scaleEffect(x: settings.flipHorizontal ? -1 : 1, y: settings.flipVertical ? -1 : 1)
                                .rotationEffect(.degrees(Double(settings.rotation)))

                            Text(settings.rotation == 90 || settings.rotation == 270 ? "Portrait" : "Landscape")
                                .font(.system(size: 8))
                                .foregroundColor(.secondary)
                        }
                        .frame(width: 100, height: 80)

                        VStack(spacing: 6) {
                            HStack(spacing: 6) {
                                RotationButton(degrees: 270, label: "270", isSelected: settings.rotation == 270) {
                                    settings.rotation = 270
                                }
                                RotationButton(degrees: 0, label: "0", isSelected: settings.rotation == 0) {
                                    settings.rotation = 0
                                }
                                RotationButton(degrees: 90, label: "90", isSelected: settings.rotation == 90) {
                                    settings.rotation = 90
                                }
                            }
                            HStack(spacing: 6) {
                                Spacer()
                                RotationButton(degrees: 180, label: "180", isSelected: settings.rotation == 180) {
                                    settings.rotation = 180
                                }
                                Spacer()
                            }
                        }
                    }

                    if settings.rotation == 90 || settings.rotation == 270 {
                        Text("Display will be in portrait mode")
                            .font(.system(size: 10))
                            .foregroundColor(.accentColor)
                    }

                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Flip Horizontally")
                                    .font(.system(size: 11))
                                    .foregroundColor(.secondary)
                                Text("Mirror left and right")
                                    .font(.system(size: 10))
                                    .foregroundColor(.secondary.opacity(0.7))
                            }
                            Spacer()
                            Toggle("", isOn: $settings.flipHorizontal)
                                .toggleStyle(.switch)
                                .controlSize(.mini)
                        }

                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Flip Vertically")
                                    .font(.system(size: 11))
                                    .foregroundColor(.secondary)
                                Text("Mirror top and bottom")
                                    .font(.system(size: 10))
                                    .foregroundColor(.secondary.opacity(0.7))
                            }
                            Spacer()
                            Toggle("", isOn: $settings.flipVertical)
                                .toggleStyle(.switch)
                                .controlSize(.mini)
                        }
                    }
                    .padding(.top, 4)

                    HStack {
                        Spacer()
                        Button(action: {
                            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.displays?displayArrangement")!)
                        }) {
                            HStack(spacing: 4) {
                                Image(systemName: "rectangle.connected.to.line.below")
                                Text("Arrange Displays…")
                            }
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }
                    .padding(.top, 10)
                }

            }
        }
    }

    @ViewBuilder
    private var refreshSection: some View {
        FrostedGroupBox(title: "Refresh Rate", icon: "speedometer") {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Frame Rate")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                    Spacer()
                    Text("\(settings.refreshRate) Hz")
                        .font(.system(size: 11, weight: .medium))
                }

                HStack(spacing: 6) {
                    ForEach([30, 60, 90, 120], id: \.self) { rate in
                        BitrateButton(
                            label: "\(rate)",
                            value: rate,
                            currentValue: settings.refreshRate,
                            disabled: false
                        ) {
                            settings.refreshRate = rate
                        }
                    }
                }

                if settings.refreshRate >= 90 {
                    Text("High refresh rate for smooth experience")
                        .font(.system(size: 10))
                        .foregroundColor(.green)
                }
            }
        }
    }

    @ViewBuilder
    private var touchSection: some View {
        FrostedGroupBox(title: "Touch Control", icon: "hand.tap") {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Enable Touch Input")
                            .font(.system(size: 12, weight: .medium))
                        Text("Control Mac from tablet touch")
                            .font(.system(size: 10))
                            .foregroundColor(.secondary)
                    }
                    Spacer()
                    Toggle("", isOn: $settings.touchEnabled)
                        .labelsHidden()
                }

                if !settings.touchEnabled {
                    Text("Touch input is disabled — tablet is display-only")
                        .font(.system(size: 10))
                        .foregroundColor(.orange)
                }

                Divider()

                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Stylus Input")
                            .font(.system(size: 12, weight: .medium))
                        Text("Pressure and tilt from a tablet pen")
                            .font(.system(size: 10))
                            .foregroundColor(.secondary)
                    }
                    Spacer()
                    Toggle("", isOn: $settings.penInputEnabled)
                        .labelsHidden()
                }

                if !settings.penInputEnabled {
                    Text("Stylus falls back to regular touch gestures")
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                }
            }
        }
    }

    @ViewBuilder
    private var recommendedSection: some View {
        FrostedGroupBox(title: "Recommended Setup", icon: "wand.and.stars") {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("UI size on tablet")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                    Spacer()
                    Picker("", selection: $settings.uiSizePreference) {
                        Text("Larger").tag(UISizePreference.larger)
                        Text("Balanced").tag(UISizePreference.balanced)
                        Text("More space").tag(UISizePreference.moreSpace)
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)
                    .frame(width: 240)
                }

                if settings.hasRecommendation {
                    HStack {
                        Text("Tablet panel")
                            .font(.system(size: 11))
                            .foregroundColor(.secondary)
                        Spacer()
                        Text(settings.clientPanelSummary)
                            .font(.system(size: 11, design: .monospaced))
                    }
                    HStack {
                        Text("Suggested")
                            .font(.system(size: 11))
                            .foregroundColor(.secondary)
                        Spacer()
                        Text(settings.recommendedSummary)
                            .font(.system(size: 11, design: .monospaced))
                        Button("Apply") { settings.applyRecommendation() }
                            .controlSize(.small)
                            .disabled(settings.recommendationApplied)
                    }

                    // Changing the picker only updates the
                    // suggestion; without this the settings
                    // look applied when they are not.
                    if !settings.recommendationApplied {
                        Text("Not applied yet — currently \(settings.resolution)"
                            + (settings.hiDPI ? " HiDPI" : ""))
                            .font(.system(size: 10))
                            .foregroundColor(.orange)
                    }
                } else {
                    Text("Connect a client to measure its panel")
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                }
            }
        }
    }

    @ViewBuilder
    private var networkSection: some View {
        FrostedGroupBox(title: "Network Settings", icon: "network") {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Server Port")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                    Spacer()
                    TextField("Port", value: $settings.port, format: .number)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 80)
                        .disabled(settings.isRunning)
                }

                if settings.isRunning {
                    Text("Stop server to change port")
                        .font(.system(size: 10))
                        .foregroundColor(.orange)
                } else if settings.connectionMode == .wireless {
                    Text("Changing the port invalidates existing pairings — re-scan the QR on each tablet.")
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                } else if settings.port != 54321 {
                    Text("Custom port set — Android client must use the same port.")
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                }
            }
        }
    }

    @ViewBuilder
    private var wirelessSection: some View {
        // Wireless-mode-only: QR + Paired Devices.
        if settings.connectionMode == .wireless {
            WirelessSection(settings: settings,
                            pairedDeviceStore: (NSApp.delegate as? AppDelegate)?.pairedDeviceStore ?? PairedDeviceStore())
        }
    }

    @ViewBuilder
    private var startupSection: some View {
        FrostedGroupBox(title: "Startup", icon: "power") {
            VStack(alignment: .leading, spacing: 12) {
                if #available(macOS 13.0, *) {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Launch at Login")
                                .font(.system(size: 12, weight: .medium))
                            Text("Run SideScreen in the background automatically after you log in.")
                                .font(.system(size: 10))
                                .foregroundColor(.secondary)
                        }
                        Spacer()
                        Toggle("", isOn: Binding(
                            get: { daemonEnabled },
                            set: { newValue in
                                do {
                                    if newValue {
                                        try DaemonManager.shared.enable()
                                    } else {
                                        try DaemonManager.shared.disable()
                                    }
                                } catch {
                                    print("Daemon toggle failed: \(error)")
                                }
                                daemonEnabled = DaemonManager.shared.isEnabled
                            }
                        ))
                        .labelsHidden()
                    }
                    Divider()
                }

                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Auto-start streaming on launch")
                            .font(.system(size: 12, weight: .medium))
                        Text("Start the server automatically when the app opens, so the tablet can connect without touching the Mac.")
                            .font(.system(size: 10))
                            .foregroundColor(.secondary)
                    }
                    Spacer()
                    Toggle("", isOn: $settings.autoStartStreamingOnLaunch)
                        .labelsHidden()
                }

                Divider()

                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Startup mode")
                            .font(.system(size: 12, weight: .medium))
                        Text("Which connection mode to start in when auto-starting.")
                            .font(.system(size: 10))
                            .foregroundColor(.secondary)
                    }
                    Spacer()
                    Picker("", selection: $settings.startupMode) {
                        Text("USB").tag(ConnectionMode.usb)
                        Text("Wireless").tag(ConnectionMode.wireless)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .frame(width: 150)
                    .disabled(!settings.autoStartStreamingOnLaunch)
                }
            }
        }
    }

    @ViewBuilder
    private var gamingSection: some View {
        FrostedGroupBox(title: "Gaming Boost", icon: settings.gamingBoost ? "bolt.fill" : "bolt") {
            VStack(alignment: .leading, spacing: 16) {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Enable Gaming Mode")
                            .font(.system(size: 12, weight: .medium))
                        Text("Optimized for competitive gaming")
                            .font(.system(size: 10))
                            .foregroundColor(.secondary)
                    }
                    Spacer()
                    Toggle("", isOn: $settings.gamingBoost)
                        .labelsHidden()
                }

                if settings.gamingBoost {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(spacing: 4) {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundColor(.green)
                                .font(.system(size: 10))
                            Text("High bitrate (1000 Mbps)")
                                .font(.system(size: 11))
                        }
                        HStack(spacing: 4) {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundColor(.green)
                                .font(.system(size: 10))
                            Text("120 Hz refresh rate")
                                .font(.system(size: 11))
                        }
                        HStack(spacing: 4) {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundColor(.green)
                                .font(.system(size: 10))
                            Text("Ultra-low latency encoding")
                                .font(.system(size: 11))
                        }
                    }
                    .padding(.leading, 4)
                    .foregroundColor(.secondary)
                }
            }
        }
    }

    @ViewBuilder
    private var streamingSection: some View {
        FrostedGroupBox(title: "Streaming Settings", icon: "antenna.radiowaves.left.and.right") {
            VStack(alignment: .leading, spacing: 16) {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Automatic")
                            .font(.system(size: 12, weight: .medium))
                        Text(settings.autoEncoder
                             ? "Bitrate and quality chosen from your tablet and connection"
                             : "Set bitrate and quality yourself")
                            .font(.system(size: 10))
                            .foregroundColor(.secondary)
                    }
                    Spacer()
                    Toggle("", isOn: $settings.autoEncoder)
                        .labelsHidden()
                }

                if settings.autoEncoder {
                    HStack {
                        Text("In use")
                            .font(.system(size: 11))
                            .foregroundColor(.secondary)
                        Spacer()
                        Text(settings.isLinkThrottled && settings.adaptiveBitrate > 0
                             ? "\(settings.adaptiveBitrate) Mbps · reduced for this link"
                             : "\(settings.effectiveBitrate) Mbps · ultra-low latency")
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundColor(settings.isLinkThrottled ? .orange : .primary)
                    }
                    if settings.isLinkThrottled {
                        Text("The connection could not carry \(settings.effectiveBitrate) Mbps, "
                            + "so quality was lowered to keep latency down.")
                            .font(.system(size: 10))
                            .foregroundColor(.orange)
                    }
                    if settings.recommendedBitrate <= 0 {
                        Text("Using the manual value until a tablet connects and reports its panel.")
                            .font(.system(size: 10))
                            .foregroundColor(.secondary)
                    }
                }

                if !settings.autoEncoder {
                // Bitrate
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Text("Bitrate")
                            .font(.system(size: 11))
                            .foregroundColor(.secondary)
                        Spacer()
                        Text("\(settings.effectiveBitrate) Mbps")
                            .font(.system(size: 13, weight: .semibold, design: .monospaced))
                            .foregroundColor(.accentColor)
                    }

                    HStack(spacing: 6) {
                        BitrateButton(label: "100", value: 100, currentValue: settings.bitrate, disabled: settings.gamingBoost) {
                            settings.bitrate = 100
                        }
                        BitrateButton(label: "300", value: 300, currentValue: settings.bitrate, disabled: settings.gamingBoost) {
                            settings.bitrate = 300
                        }
                        BitrateButton(label: "500", value: 500, currentValue: settings.bitrate, disabled: settings.gamingBoost) {
                            settings.bitrate = 500
                        }
                        BitrateButton(label: "1000", value: 1000, currentValue: settings.bitrate, disabled: settings.gamingBoost) {
                            settings.bitrate = 1000
                        }
                        BitrateButton(label: "2000", value: 2000, currentValue: settings.bitrate, disabled: settings.gamingBoost) {
                            settings.bitrate = 2000
                        }
                    }

                    HStack(spacing: 8) {
                        Text("20")
                            .font(.system(size: 9))
                            .foregroundColor(.secondary)
                        Slider(value: Binding(
                            get: { Double(settings.bitrate) },
                            set: { settings.bitrate = Int($0) }
                        ), in: 20...5000, step: 10)
                        .disabled(settings.gamingBoost)
                        Text("5000")
                            .font(.system(size: 9))
                            .foregroundColor(.secondary)
                    }

                    if settings.gamingBoost {
                        HStack(spacing: 4) {
                            Image(systemName: "bolt.fill")
                                .font(.system(size: 10))
                            Text("Locked at 1000 Mbps in Gaming Boost")
                                .font(.system(size: 10))
                        }
                        .foregroundColor(.orange)
                    }
                }

                // Quality
                VStack(alignment: .leading, spacing: 8) {
                    Text("Quality Preset")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)

                    Picker("", selection: $settings.quality) {
                        Text("Ultra Low").tag("ultralow")
                        Text("Low").tag("low")
                        Text("Medium").tag("medium")
                        Text("High").tag("high")
                    }
                    .pickerStyle(.segmented)
                    .disabled(settings.gamingBoost)

                    if settings.gamingBoost {
                        Text("Quality locked to Ultra Low in Gaming Boost mode")
                            .font(.system(size: 10))
                            .foregroundColor(.orange)
                    } else if settings.quality == "ultralow" {
                        Text("Fastest encoding, lowest latency")
                            .font(.system(size: 10))
                            .foregroundColor(.green)
                    }
                }
                }
            }
        }
    }

    @ViewBuilder
    private var statusSection: some View {
        FrostedGroupBox(title: "Status", icon: "checkmark.circle") {
            VStack(alignment: .leading, spacing: 12) {
                StatusRow(title: "Virtual display",
                          status: settings.displayCreated ? "Active" : "Inactive",
                          color: settings.displayCreated ? .green : .secondary,
                          subtitle: "The screen the tablet shows. Created when you press Start.",
                          remedy: "Press Start to create it.",
                          isOK: settings.displayCreated)

                StatusRow(title: "Client connected",
                          status: settings.clientConnected ? "Yes" : "No",
                          color: settings.clientConnected ? .green : .secondary,
                          subtitle: "Whether the tablet app has an active stream.",
                          remedy: "Open Side Screen on the tablet and connect.",
                          isOK: settings.clientConnected)

                StatusRow(
                    title: ProcessInfo.processInfo.operatingSystemVersion.majorVersion >= 26
                        ? "Screen & system audio" : "Screen recording",
                    status: settings.hasScreenRecordingPermission ? "Granted" : "Required",
                    color: settings.hasScreenRecordingPermission ? .green : .red,
                    subtitle: "Needed to capture the virtual display. Streaming cannot start without it.",
                    remedy: "System Settings → Privacy & Security → Screen Recording.",
                    isOK: settings.hasScreenRecordingPermission)

                StatusRow(title: "Accessibility",
                          status: settings.hasAccessibilityPermission ? "Granted" : "Optional",
                          color: settings.hasAccessibilityPermission ? .green : .orange,
                          subtitle: "Needed for touch and stylus input. Video works without it.",
                          remedy: "System Settings → Privacy & Security → Accessibility. "
                                + "Without it the picture looks fine but the pen does nothing.",
                          isOK: settings.hasAccessibilityPermission)

                if settings.isRunning {
                    let usingFallback = settings.captureMethod.contains("fallback")
                    StatusRow(title: "Capture method",
                              status: settings.captureMethod,
                              color: usingFallback ? .orange : .green,
                              subtitle: "SCStream is the modern path; the older CGDisplayStream is a fallback.",
                              remedy: "Running on the fallback path — expect lower performance.",
                              isOK: !usingFallback)
                }

                Divider().padding(.vertical, 4)

                if settings.connectionMode == .usb {
                    StatusRow(title: "ADB installed",
                              status: settings.adbInstalled ? "Installed" : "Missing",
                              color: settings.adbInstalled ? .green : .red,
                              subtitle: "USB mode tunnels the stream through the cable using adb.",
                              remedy: "Install it, then press Start again.",
                              isOK: settings.adbInstalled)
                    if !settings.adbInstalled {
                        Text("brew install android-platform-tools")
                            .font(.system(size: 10, design: .monospaced))
                            .padding(6)
                            .background(Color.black.opacity(0.08))
                            .cornerRadius(4)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .textSelection(.enabled)
                    }

                    StatusRow(title: "USB tunnel",
                              status: settings.adbReverseConfigured ? "OK" : "Pending",
                              color: settings.adbReverseConfigured ? .green : .orange,
                              subtitle: "Port \(settings.port) forwarded to the tablet. Set up automatically.",
                              remedy: "Turns green a couple of seconds after the tablet is plugged in and authorised.",
                              isOK: settings.adbReverseConfigured)

                    StatusRow(title: "USB device",
                              status: settings.usbDeviceConnected ? "Detected" : "Not detected",
                              color: settings.usbDeviceConnected ? .green : .red,
                              subtitle: "A tablet visible to this Mac over USB.",
                              remedy: "Plug in the cable and tap Allow on the tablet's debugging prompt.",
                              isOK: settings.usbDeviceConnected)
                } else {
                    StatusRow(title: "Network",
                              status: settings.wifiConnected ? "Connected" : "Disconnected",
                              color: settings.wifiConnected ? .green : .red,
                              subtitle: "Wireless mode needs this Mac and the tablet on the same network.",
                              remedy: "Connect this Mac to Wi-Fi or Ethernet.",
                              isOK: settings.wifiConnected)

                    StatusRow(title: "Listening on",
                              status: settings.listeningAddress.map { "\($0):\(settings.port)" } ?? "—",
                              color: settings.listeningAddress != nil ? .green : .secondary,
                              subtitle: "The address the tablet connects to. The QR code contains it.",
                              remedy: "No LAN address yet — connect to a network first.",
                              isOK: settings.listeningAddress != nil)
                }
            }
        }
    }

    @ViewBuilder
    private var performanceSection: some View {
        // Performance (when connected)
        if settings.clientConnected {
            FrostedGroupBox(title: "Performance", icon: "speedometer") {
                HStack {
                    VStack(alignment: .leading) {
                        Text("FPS")
                            .font(.system(size: 10))
                            .foregroundColor(.secondary)
                        Text(String(format: "%.1f", settings.currentFPS))
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundColor(.green)
                    }
                    Spacer()
                    VStack(alignment: .leading) {
                        Text("Bitrate")
                            .font(.system(size: 10))
                            .foregroundColor(.secondary)
                        Text(String(format: "%.1f Mbps", settings.currentBitrate))
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundColor(.accentColor)
                    }
                }
            }
        }
    }


    /// Restart the app by launching a new instance and terminating current one
    private func restartApp() {
        // Get the app bundle path
        guard let appPath = Bundle.main.bundlePath as String? else {
            print("❌ Could not get app path")
            return
        }

        // Use Process to launch a new instance after a short delay
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/sh")
        task.arguments = ["-c", "sleep 0.5 && open \"\(appPath)\""]

        do {
            try task.run()
            // Terminate current app
            NSApp.terminate(nil)
        } catch {
            print("❌ Failed to restart: \(error)")
        }
    }
}

// MARK: - Supporting Views

/// A status line with its explanation visible rather than behind an info button.
///
/// The subtitle says what the row means and is always shown. The remedy says
/// what to do about it and appears only when the row is not OK — advice for a
/// problem you do not have is noise, and advice you have to hover to find is
/// undiscoverable on a touch device.
struct StatusRow: View {
    let title: String
    let status: String
    let color: Color
    /// Short, always-visible description of what this row reports.
    var subtitle: String?
    /// What to do when it is wrong. Only rendered when `isOK` is false.
    var remedy: String?
    var isOK: Bool = true

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline) {
                Text(title)
                    .font(.system(size: 12))
                Spacer()
                HStack(spacing: 6) {
                    Circle()
                        .fill(color)
                        .frame(width: 6, height: 6)
                    Text(status)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(color)
                }
            }

            if let subtitle {
                Text(subtitle)
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if !isOK, let remedy {
                Text(remedy)
                    .font(.system(size: 10))
                    .foregroundColor(color == .red ? .red : .orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

struct ResolutionRow: View {
    let resolution: String
    let isSelected: Bool
    let action: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            HStack {
                Text(resolution.replacingOccurrences(of: "x", with: " x "))
                    .font(.system(size: 12))
                Spacer()
                if isSelected {
                    Image(systemName: "checkmark")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(.white)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(isSelected ? Color.accentColor : (isHovered ? Color.primary.opacity(0.05) : Color.clear))
            .foregroundColor(isSelected ? .white : .primary)
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
    }
}

struct BitrateButton: View {
    let label: String
    let value: Int
    let currentValue: Int
    let disabled: Bool
    let action: () -> Void
    @State private var isHovered = false

    var isSelected: Bool { currentValue == value }

    var body: some View {
        Button(action: action) {
            Text(label)
                .font(.system(size: 11, weight: isSelected ? .semibold : .regular))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 6)
                .background {
                    if isSelected {
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(Color.accentColor)
                    } else {
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(.ultraThinMaterial)
                            .overlay {
                                RoundedRectangle(cornerRadius: 6, style: .continuous)
                                    .strokeBorder(Color.primary.opacity(0.1), lineWidth: 1)
                            }
                    }
                }
                .foregroundColor(isSelected ? .white : (disabled ? .secondary : .primary))
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .opacity(disabled ? 0.5 : 1)
        .onHover { isHovered = $0 }
    }
}

struct RotationButton: View {
    let degrees: Int
    let label: String
    let isSelected: Bool
    let action: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            VStack(spacing: 2) {
                RoundedRectangle(cornerRadius: 2)
                    .stroke(isSelected ? Color.accentColor : Color.secondary.opacity(0.5), lineWidth: 1)
                    .frame(width: degrees == 90 || degrees == 270 ? 16 : 24, height: degrees == 90 || degrees == 270 ? 24 : 16)

                Text("\(label)")
                    .font(.system(size: 9))
                    .foregroundColor(isSelected ? .accentColor : .secondary)
            }
            .frame(width: 50, height: 40)
            .background {
                if isSelected {
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(Color.accentColor.opacity(0.15))
                        .overlay {
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .strokeBorder(Color.accentColor, lineWidth: 1)
                        }
                } else {
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(.ultraThinMaterial)
                        .overlay {
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .strokeBorder(Color.primary.opacity(0.1), lineWidth: 1)
                        }
                }
            }
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
    }
}

// MARK: - Display Settings

class DisplaySettings: ObservableObject {
    private let defaults = UserDefaults.standard
    private let keyPrefix = "SideScreen_"

    @Published var resolution: String {
        didSet { save("resolution", resolution) }
    }
    @Published var refreshRate: Int {
        didSet { save("refreshRate", refreshRate) }
    }
    @Published var hiDPI: Bool {
        didSet { save("hiDPI", hiDPI) }
    }
    @Published var bitrate: Int {
        didSet { save("bitrate", bitrate) }
    }
    @Published var quality: String {
        didSet { save("quality", quality) }
    }
    @Published var gamingBoost: Bool {
        didSet { save("gamingBoost", gamingBoost) }
    }
    @Published var port: UInt16 {
        didSet { save("port", Int(port)) }
    }
    @Published var rotation: Int {
        didSet { save("rotation", rotation) }
    }
    @Published var flipHorizontal: Bool {
        didSet { save("flipHorizontal", flipHorizontal) }
    }
    @Published var flipVertical: Bool {
        didSet { save("flipVertical", flipVertical) }
    }
    @Published var showAllResolutions: Bool {
        didSet { save("showAllResolutions", showAllResolutions) }
    }
    @Published var customWidth: Int {
        didSet { save("customWidth", customWidth) }
    }
    @Published var customHeight: Int {
        didSet { save("customHeight", customHeight) }
    }
    @Published var touchEnabled: Bool {
        didSet { save("touchEnabled", touchEnabled) }
    }
    @Published var penInputEnabled: Bool {
        didSet { save("penInputEnabled", penInputEnabled) }
    }
    /// How large the macOS UI should appear on the tablet. A preference, not a
    /// computed value — viewing distance and eyesight differ per person even
    /// on identical hardware.
    @Published var uiSizePreference: UISizePreference {
        didSet { save("uiSizePreference", uiSizePreference.rawValue) }
    }
    /// Let the advisor pick bitrate and quality.
    ///
    /// On by default. Most people have no way to judge whether 300 or 700 Mbps
    /// is right for their link, and the advisor already computes a cap from the
    /// panel, the decoder limits and the connection type.
    @Published var autoEncoder: Bool {
        didSet { save("autoEncoder", autoEncoder) }
    }

    // Populated from the client's reported panel; advisory only.
    /// Bitrate the adaptive controller settled on, when it differs from the cap.
    @Published var adaptiveBitrate: Int = 0
    @Published var isLinkThrottled: Bool = false

    @Published var clientPanelSummary: String = ""
    @Published var recommendedSummary: String = ""
    @Published var recommendedResolution: String = ""
    @Published var recommendedHiDPI: Bool = false
    @Published var recommendedRefreshRate: Int = 60
    @Published var recommendedBitrate: Int = 20

    var hasRecommendation: Bool { !recommendedResolution.isEmpty }

    /// Whether the live configuration already matches the suggestion. Bitrate
    /// is excluded — it is an upper bound, not a target to match exactly.
    var recommendationApplied: Bool {
        hasRecommendation
            && resolution == recommendedResolution
            && hiDPI == recommendedHiDPI
            && refreshRate == recommendedRefreshRate
    }

    func applyRecommendation() {
        guard hasRecommendation else { return }
        resolution = recommendedResolution
        hiDPI = recommendedHiDPI
        refreshRate = recommendedRefreshRate
        bitrate = recommendedBitrate
    }
    @Published var connectionMode: ConnectionMode {
        didSet { save("connectionMode", connectionMode.rawValue) }
    }
    @Published var autoStartStreamingOnLaunch: Bool {
        didSet { save("autoStartStreamingOnLaunch", autoStartStreamingOnLaunch) }
    }
    @Published var startupMode: ConnectionMode {
        didSet { save("startupMode", startupMode.rawValue) }
    }

    // Runtime state (not persisted)
    @Published var displayCreated = false
    @Published var clientConnected = false
    /// Device name of the wireless client currently streaming (nil when none).
    /// WirelessSection reads this to show a "Connected" badge on the matching row.
    @Published var currentWirelessDevice: String?
    @Published var hasScreenRecordingPermission = false
    @Published var hasAccessibilityPermission = false
    @Published var adbInstalled = false
    @Published var adbReverseConfigured = false
    @Published var usbDeviceConnected = false
    @Published var wifiConnected = false
    @Published var listeningAddress: String?
    @Published var isRunning = false
    @Published var currentFPS: Double = 0
    @Published var currentBitrate: Double = 0
    @Published var captureMethod: String = "Initializing..."

    var onToggleServer: (() -> Void)?

    init() {
        self.resolution = defaults.string(forKey: keyPrefix + "resolution") ?? "1920x1200"
        self.refreshRate = defaults.object(forKey: keyPrefix + "refreshRate") as? Int ?? 60  // Default: 60 — balanced for most tablets. 120 may saturate high-res panel pipelines.
        self.hiDPI = defaults.bool(forKey: keyPrefix + "hiDPI")
        self.bitrate = defaults.object(forKey: keyPrefix + "bitrate") as? Int ?? 1000  // Default: 1000 Mbps
        self.quality = defaults.string(forKey: keyPrefix + "quality") ?? "ultralow"  // Default: fastest encoding
        self.gamingBoost = defaults.bool(forKey: keyPrefix + "gamingBoost")
        // Default port 54321 (was 8888 in <=0.7.1; 8888 collides with jupyter/splunk/HP printers).
        // Existing users keep their saved value.
        self.port = UInt16(defaults.object(forKey: keyPrefix + "port") as? Int ?? 54321)
        self.rotation = defaults.object(forKey: keyPrefix + "rotation") as? Int ?? 0
        self.flipHorizontal = defaults.bool(forKey: keyPrefix + "flipHorizontal")
        self.flipVertical = defaults.bool(forKey: keyPrefix + "flipVertical")
        self.showAllResolutions = defaults.bool(forKey: keyPrefix + "showAllResolutions")
        self.customWidth = defaults.object(forKey: keyPrefix + "customWidth") as? Int ?? 1920
        self.customHeight = defaults.object(forKey: keyPrefix + "customHeight") as? Int ?? 1200
        self.touchEnabled = defaults.object(forKey: keyPrefix + "touchEnabled") as? Bool ?? true
        self.penInputEnabled = defaults.object(forKey: keyPrefix + "penInputEnabled") as? Bool ?? true
        self.autoEncoder = defaults.object(forKey: keyPrefix + "autoEncoder") as? Bool ?? true
        self.uiSizePreference = UISizePreference(
            rawValue: defaults.string(forKey: keyPrefix + "uiSizePreference") ?? ""
        ) ?? .balanced
        let modeRaw = defaults.string(forKey: keyPrefix + "connectionMode") ?? ConnectionMode.usb.rawValue
        self.connectionMode = ConnectionMode(rawValue: modeRaw) ?? .usb
        self.autoStartStreamingOnLaunch = defaults.object(forKey: keyPrefix + "autoStartStreamingOnLaunch") as? Bool ?? false
        let startupRaw = defaults.string(forKey: keyPrefix + "startupMode") ?? modeRaw
        self.startupMode = ConnectionMode(rawValue: startupRaw) ?? .usb

        print("Loaded settings: \(resolution) @ \(refreshRate)Hz, bitrate=\(bitrate), quality=\(quality)")
    }

    private func save(_ key: String, _ value: Any) {
        defaults.set(value, forKey: keyPrefix + key)
    }

    struct ResolutionGroup: Identifiable {
        let id = UUID()
        let name: String
        let ratio: String
        let resolutions: [String]
    }

    static let resolutionGroups: [ResolutionGroup] = [
        ResolutionGroup(name: "16:10", ratio: "Widescreen", resolutions: [
            "1280x800", "1440x900", "1680x1050", "1920x1200", "2560x1600"
        ]),
        ResolutionGroup(name: "16:9", ratio: "HD/4K", resolutions: [
            "1280x720", "1366x768", "1600x900", "1920x1080", "2560x1440", "3840x2160"
        ]),
        ResolutionGroup(name: "4:3", ratio: "Classic", resolutions: [
            "1024x768", "1280x960", "1600x1200"
        ]),
        ResolutionGroup(name: "3:2", ratio: "Surface/Pixel", resolutions: [
            "1920x1280", "2160x1440", "2736x1824"
        ]),
        ResolutionGroup(name: "5:3", ratio: "Tablet Wide", resolutions: [
            "2000x1200", "2560x1536", "2800x1680"
        ]),
        ResolutionGroup(name: "4:3", ratio: "iPad", resolutions: [
            "2048x1536", "2224x1668", "2388x1668", "2732x2048"
        ])
    ]

    static let commonResolutions = [
        "1920x1080", "1920x1200", "2560x1440", "2560x1600"
    ]

    static var allResolutions: [String] {
        resolutionGroups.flatMap { $0.resolutions }
    }

    var effectiveBitrate: Int {
        if gamingBoost { return 1000 }
        // recommendedBitrate is 0 until a client reports its panel; fall back
        // to the manual value until then rather than streaming at nothing.
        if autoEncoder, recommendedBitrate > 0 { return recommendedBitrate }
        return bitrate
    }

    var effectiveQuality: String {
        if gamingBoost { return "ultralow" }
        // Screen content is latency-sensitive, so automatic mode picks the
        // fastest encoder preset and lets the bitrate cap carry image quality.
        if autoEncoder { return "ultralow" }
        return quality
    }

    var effectiveRefreshRate: Int {
        return gamingBoost ? 120 : refreshRate
    }

    func toggleServer() {
        onToggleServer?()
    }

    func resetToDefaults() {
        let keys = ["resolution", "refreshRate", "hiDPI", "bitrate", "quality",
                    "gamingBoost", "port", "rotation", "flipHorizontal", "flipVertical", "showAllResolutions",
                    "customWidth", "customHeight", "touchEnabled", "penInputEnabled", "autoEncoder",
                    "autoStartStreamingOnLaunch", "startupMode"]
        for key in keys {
            defaults.removeObject(forKey: keyPrefix + key)
        }

        resolution = "1920x1200"
        refreshRate = 120  // Default: highest FPS
        hiDPI = false
        bitrate = 1000  // Default: 1000 Mbps
        quality = "ultralow"  // Default: fastest encoding
        gamingBoost = false
        port = 54321
        rotation = 0
        flipHorizontal = false
        flipVertical = false
        showAllResolutions = false
        customWidth = 1920
        customHeight = 1200
        touchEnabled = true
        penInputEnabled = true
        autoEncoder = true
        autoStartStreamingOnLaunch = false
        startupMode = .usb

        print("Settings reset to defaults")
    }

    var resolutionSize: (width: Int, height: Int) {
        let parts = resolution.split(separator: "x")
        let baseWidth = Int(parts[0]) ?? 1920
        let baseHeight = Int(parts[1]) ?? 1200
        if rotation == 90 || rotation == 270 {
            return (baseHeight, baseWidth)
        }
        return (baseWidth, baseHeight)
    }

    static func isValidCustomResolution(width: Int, height: Int) -> Bool {
        width >= 640 && width <= 7680 && height >= 480 && height <= 4320
    }

    func applyCustomResolution() {
        if DisplaySettings.isValidCustomResolution(width: customWidth, height: customHeight) {
            resolution = "\(customWidth)x\(customHeight)"
        }
    }
}

// MARK: - Window Controller

class SettingsWindowController: NSWindowController, NSWindowDelegate {
    convenience init(settings: DisplaySettings) {
        let window = ConstrainedWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1000, height: 700),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )

        window.title = "Side Screen"
        window.titlebarAppearsTransparent = true
        window.backgroundColor = .windowBackgroundColor
        window.isMovableByWindowBackground = true
        window.center()
        window.contentView = NSHostingView(rootView: SettingsView(settings: settings))
        window.isReleasedWhenClosed = false

        self.init(window: window)
        window.delegate = self
    }

    func windowDidMove(_ notification: Notification) {
        guard let window = notification.object as? NSWindow,
              let screen = window.screen ?? NSScreen.main else { return }

        var frame = window.frame
        let visibleFrame = screen.visibleFrame
        let minVisibleWidth: CGFloat = 100
        let minVisibleHeight: CGFloat = 50

        if frame.maxX < visibleFrame.minX + minVisibleWidth {
            frame.origin.x = visibleFrame.minX - frame.width + minVisibleWidth
        } else if frame.minX > visibleFrame.maxX - minVisibleWidth {
            frame.origin.x = visibleFrame.maxX - minVisibleWidth
        }

        if frame.maxY < visibleFrame.minY + minVisibleHeight {
            frame.origin.y = visibleFrame.minY - frame.height + minVisibleHeight
        } else if frame.minY > visibleFrame.maxY - minVisibleHeight {
            frame.origin.y = visibleFrame.maxY - minVisibleHeight
        }

        if window.frame != frame {
            window.setFrame(frame, display: true)
        }
    }
}

class ConstrainedWindow: NSWindow {
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
        guard let screen = screen ?? self.screen ?? NSScreen.main else {
            return frameRect
        }

        var constrainedRect = frameRect
        let visibleFrame = screen.visibleFrame
        let minVisibleWidth: CGFloat = 100
        let minVisibleHeight: CGFloat = 50

        if constrainedRect.maxX < visibleFrame.minX + minVisibleWidth {
            constrainedRect.origin.x = visibleFrame.minX - constrainedRect.width + minVisibleWidth
        } else if constrainedRect.minX > visibleFrame.maxX - minVisibleWidth {
            constrainedRect.origin.x = visibleFrame.maxX - minVisibleWidth
        }

        if constrainedRect.maxY < visibleFrame.minY + minVisibleHeight {
            constrainedRect.origin.y = visibleFrame.minY - constrainedRect.height + minVisibleHeight
        } else if constrainedRect.minY > visibleFrame.maxY - minVisibleHeight {
            constrainedRect.origin.y = visibleFrame.maxY - minVisibleHeight
        }

        return constrainedRect
    }
}

// MARK: - Wireless Section

struct WirelessSection: View {
    @ObservedObject var settings: DisplaySettings
    let pairedDeviceStore: PairedDeviceStore
    @State private var qrImage: NSImage?
    @State private var pairedDevices: [PairedDevice] = []
    @State private var showResetConfirm = false
    /// Used to force the relative-time labels to recompute every tick even when
    /// the underlying lastConnected timestamp hasn't changed (e.g. while a
    /// device is disconnected and we still want "5 minutes ago" to count up).
    @State private var nowTick: Date = Date()

    var body: some View {
        VStack(spacing: 12) {
            if !settings.isRunning {
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundColor(.orange)
                    Text("Click Start at the top to begin listening, then scan the QR.")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                    Spacer()
                }
                .padding(8)
                .background(Color.orange.opacity(0.12))
                .cornerRadius(6)
            }
            FrostedGroupBox(title: "Pair Device", icon: "qrcode") {
                VStack(spacing: 8) {
                    if let qr = qrImage {
                        Image(nsImage: qr)
                            .interpolation(.none)
                            .resizable()
                            .scaledToFit()
                            .frame(width: 180, height: 180)
                            .padding(8)
                            .background(Color.white)
                            .cornerRadius(8)
                    } else {
                        Text("Generating QR…").foregroundColor(.secondary)
                    }
                    Text("Scan this QR from Side Screen Android (Wireless tab)")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                    Text(LANAddressResolver.primaryIPv4().map { "Listening: \($0):\(settings.port)" } ?? "WiFi disconnected — no LAN address")
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity)
            }

            FrostedGroupBox(
                title: "Paired Devices (\(pairedDevices.count))",
                icon: "ipad.and.iphone",
                content: {
                if pairedDevices.isEmpty {
                    Text("No devices paired yet.")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    VStack(spacing: 6) {
                        ForEach(pairedDevices, id: \.name) { device in
                            let isLive = settings.currentWirelessDevice == device.name
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(device.name).font(.system(size: 12, weight: .medium))
                                    HStack(spacing: 4) {
                                        Circle()
                                            .fill(isLive ? Color.green : Color.secondary)
                                            .frame(width: 6, height: 6)
                                        Text(isLive ? "Connected" : relativeTimeString(from: device.lastConnected, to: nowTick))
                                            .font(.system(size: 10))
                                            .foregroundColor(isLive ? .green : .secondary)
                                    }
                                }
                                Spacer()
                                Button("Forget") {
                                    pairedDeviceStore.forget(name: device.name)
                                    refreshPaired()
                                }
                                .buttonStyle(.bordered)
                                .controlSize(.small)
                            }
                            .padding(6)
                            .background(.ultraThinMaterial)
                            .cornerRadius(6)
                        }
                    }
                }
                Button("Reset Token (forget all)") {
                    showResetConfirm = true
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .foregroundColor(.red)
                .padding(.top, 6)
            },
            trailing: {
                Button(action: {
                    nowTick = Date()
                    refreshPaired()
                }) {
                    Image(systemName: "arrow.counterclockwise")
                        .font(.system(size: 12, weight: .semibold))
                }
                .buttonStyle(.borderless)
                .help("Refresh list and timestamps")
            })
        }
        .onAppear {
            refreshQR()
            refreshPaired()
            nowTick = Date()
        }
        // One-parameter onChange(of:perform:) works on macOS 13+. The
        // two-parameter form requires macOS 14 and would block Ventura.
        // Deprecation is a compile-time warning only on Xcode 15+ SDKs.
        .onChange(of: settings.port) { _ in refreshQR() }
        .onReceive(Timer.publish(every: 5, on: .main, in: .common).autoconnect()) { now in
            nowTick = now
            refreshPaired()
        }
        .alert("Reset Token?", isPresented: $showResetConfirm) {
            Button("Cancel", role: .cancel) { }
            Button("Reset", role: .destructive) {
                _ = WirelessAuth.reset()
                pairedDeviceStore.clear()
                refreshQR()
                refreshPaired()
            }
        } message: {
            Text("This will disconnect all paired devices. They will need to scan the new QR to connect again.")
        }
    }

    private func refreshQR() {
        let token = WirelessAuth.loadOrCreate()
        let host = LANAddressResolver.primaryIPv4() ?? "0.0.0.0"
        let name = Host.current().localizedName ?? "Mac"
        let url = PairingURL.build(host: host, port: settings.port, token: token, name: name)
        qrImage = QRRenderer.render(url: url, size: 180)
    }

    private func refreshPaired() {
        pairedDevices = pairedDeviceStore.all()
    }

    private func relativeTimeString(from past: Date, to now: Date) -> String {
        let elapsed = max(0, now.timeIntervalSince(past))
        if elapsed < 30 { return "just now" }
        if elapsed < 60 { return "\(Int(elapsed)) seconds ago" }
        if elapsed < 3600 {
            let m = Int(elapsed / 60)
            return "\(m) minute\(m == 1 ? "" : "s") ago"
        }
        if elapsed < 86400 {
            let h = Int(elapsed / 3600)
            return "\(h) hour\(h == 1 ? "" : "s") ago"
        }
        let d = Int(elapsed / 86400)
        return "\(d) day\(d == 1 ? "" : "s") ago"
    }
}
