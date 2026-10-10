import Cocoa
import SwiftUI
import Combine

@MainActor
final class FullscreenOverlayController: ObservableObject {
    private var builtinWindow: KeyCatchingWindow?
    private var externalWindows: [KeyCatchingWindow] = []

    var window: NSWindow? { builtinWindow }
    @Published private(set) var isShowing: Bool = false
    @Published private(set) var isExternalShowing: Bool = false
    @Published private(set) var isExternalSettling: Bool = false
    var onExternalSettleCompleted: (() -> Void)?
    private var onDismissal: (() -> Void)?
    @Published var viewState = OverlayViewState()

    // External Monitor Tunable Parameters
    @Published var externalZoomOut: Float = 0.10
    @Published var externalBlur: Float = 1.00
    @Published var externalDarken: Float = 0.40
    @Published var isExternalAnimationEnabled: Bool = true

    var keyboardReflectionBinding: Binding<Bool> {
        Binding(
            get: { self.viewState.isKeyboardReflectionEnabled },
            set: { [weak self] newValue in
                guard let self = self else { return }
                self.viewState.isKeyboardReflectionEnabled = newValue
                if self.viewState.showCalibrator {
                    self.viewState.requestRender()
                }
            }
        )
    }

    var frostedGlassBinding: Binding<Bool> {
        Binding(
            get: { self.viewState.isFrostedGlassEnabled },
            set: { [weak self] newValue in
                guard let self = self else { return }
                self.viewState.isFrostedGlassEnabled = newValue
                if self.viewState.showCalibrator {
                    self.viewState.requestRender()
                }
            }
        )
    }

    var clockPositionBinding: Binding<ClockPosition> {
        Binding(
            get: { self.viewState.clockPosition },
            set: { [weak self] newValue in
                guard let self = self else { return }
                self.viewState.clockPosition = newValue
            }
        )
    }

    var clockSizeBinding: Binding<ClockSize> {
        Binding(
            get: { self.viewState.clockSize },
            set: { [weak self] newValue in
                guard let self = self else { return }
                self.viewState.clockSize = newValue
            }
        )
    }

    var standByStyleBinding: Binding<Bool> {
        Binding(
            get: { self.viewState.useStandByStyle },
            set: { [weak self] newValue in
                guard let self = self else { return }
                self.viewState.useStandByStyle = newValue
            }
        )
    }

    var isSettling: Bool {
        viewState.isSettling
    }

    /// Pre-warms the builtin overlay window once to avoid runtime allocation latency
    func prepareBuiltinWindow(sensor: LidSensor) {
        guard builtinWindow == nil else { return }
        guard let screen = NSScreen.main else { return }

        let newWindow = KeyCatchingWindow(
            contentRect: screen.frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        newWindow.setFrame(screen.frame, display: false)
        newWindow.alphaValue = 1.0
        newWindow.isOpaque = true
        newWindow.backgroundColor = .black
        newWindow.hasShadow = false

        newWindow.onEscape = { [weak self] in
            self?.dismiss()
        }
        newWindow.onToggleHUD = { [weak self] in
            self?.viewState.showHUD.toggle()
        }
        newWindow.onToggleCalibrator = { [weak self] in
            guard let self = self else { return }
            guard self.viewState.isSettingsWindowAvailable else { return }
            if !self.viewState.showCalibrator && sensor.displayAngle >= 90.0 {
                return
            }
            self.viewState.showCalibrator.toggle()
            if self.viewState.showCalibrator {
                self.viewState.requestRender()
            }
        }
        newWindow.onArrowUp = { [weak self] in
            guard let self = self, self.viewState.showCalibrator else { return }
            self.viewState.previousSetting()
        }
        newWindow.onArrowDown = { [weak self] in
            guard let self = self, self.viewState.showCalibrator else { return }
            self.viewState.nextSetting()
        }
        newWindow.onArrowLeft = { [weak self] in
            guard let self = self, self.viewState.showCalibrator else { return }
            self.viewState.adjustSelectedSetting(by: -1)
        }
        newWindow.onArrowRight = { [weak self] in
            guard let self = self, self.viewState.showCalibrator else { return }
            self.viewState.adjustSelectedSetting(by: 1)
        }
        newWindow.onReset = { [weak self] in
            guard let self = self, self.viewState.showCalibrator else { return }
            self.viewState.resetToDefaults()
        }
        newWindow.onToggleKeyboard = { [weak self] in
            guard let self = self else { return }
            self.viewState.isKeyboardReflectionEnabled.toggle()
            if self.viewState.showCalibrator {
                self.viewState.requestRender()
            }
        }
        newWindow.onToggleFrostedGlass = { [weak self] in
            guard let self = self else { return }
            self.viewState.isFrostedGlassEnabled.toggle()
            if self.viewState.showCalibrator {
                self.viewState.requestRender()
            }
        }

        newWindow.level = NSWindow.Level(Int(CGWindowLevelForKey(.screenSaverWindow)))
        newWindow.collectionBehavior = [
            .canJoinAllSpaces,
            .fullScreenAuxiliary,
            .stationary,
            .ignoresCycle
        ]

        let hostView = NSHostingView(
            rootView: FullscreenPerspectiveContainer(
                sensor: sensor,
                state: viewState,
                onDismiss: { [weak self] in
                    self?.dismiss()
                }
            )
            .ignoresSafeArea()
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        )

        newWindow.contentView = hostView
        self.builtinWindow = newWindow
    }

    /// Dynamically updates Metal textures in-place without touching window visibility
    func updateTextures(snapshots: MultiScreenSnapshots) {
        if let builtinSnapshot = snapshots.builtinSnapshot {
            viewState.currentSnapshot = builtinSnapshot
            viewState.currentTexture = snapshots.builtinTextures?.texture
            viewState.currentBlurredTexture = snapshots.builtinTextures?.blurredTexture
        }
    }

    func show(
        snapshots: MultiScreenSnapshots,
        sensor: LidSensor,
        showCalibrator: Bool = false,
        onDismiss: (() -> Void)? = nil
    ) {
        if isShowing {
            updateTextures(snapshots: snapshots)
            return
        }

        self.onDismissal = onDismiss

        // 1. Setup Built-in Display Overlay (Perspective 3D Warp)
        if let builtinSnapshot = snapshots.builtinSnapshot,
           let screen = snapshots.builtinScreen ?? NSScreen.main {
            // Reset settle state when showing fresh overlay
            viewState.activationCount += 1
            viewState.isSettling = false
            viewState.onSettleCompleted = nil
            viewState.showCalibrator = showCalibrator
            viewState.screenSize = screen.frame.size
            viewState.currentSnapshot = builtinSnapshot
            viewState.currentTexture = snapshots.builtinTextures?.texture
            viewState.currentBlurredTexture = snapshots.builtinTextures?.blurredTexture

            if showCalibrator {
                viewState.requestRender()
            }

            prepareBuiltinWindow(sensor: sensor)

            if let overlayWindow = builtinWindow {
                overlayWindow.setFrame(screen.frame, display: true)
                overlayWindow.alphaValue = 1.0
                overlayWindow.makeKeyAndOrderFront(nil)
            }
        }

        // 2. Setup External Monitor Overlays (Zoom Out, Progressive Blur, and Darken)
        if isExternalAnimationEnabled && !snapshots.externalSnapshots.isEmpty {
            isExternalSettling = false
            onExternalSettleCompleted = nil

            for ext in snapshots.externalSnapshots {
                let extWindow = KeyCatchingWindow(
                    contentRect: ext.screen.frame,
                    styleMask: [.borderless],
                    backing: .buffered,
                    defer: false
                )
                extWindow.setFrame(ext.screen.frame, display: true)
                extWindow.alphaValue = 1.0
                extWindow.isOpaque = true
                extWindow.backgroundColor = .black
                extWindow.hasShadow = false

                extWindow.onEscape = { [weak self] in
                    self?.dismiss()
                }

                // Clicking on an external window immediately auto-settles/fades it so it's instantly usable!
                extWindow.onMouseDown = { [weak self] in
                    self?.unwarpAndDismissExternal()
                }

                extWindow.level = NSWindow.Level(Int(CGWindowLevelForKey(.screenSaverWindow)))
                extWindow.collectionBehavior = [
                    .canJoinAllSpaces,
                    .fullScreenAuxiliary,
                    .stationary,
                    .ignoresCycle
                ]

                let extHostView = NSHostingView(
                    rootView: ExternalMonitorContainer(
                        snapshot: ext.image,
                        preloadedTexture: ext.textures?.texture,
                        preloadedBlurredTexture: ext.textures?.blurredTexture,
                        sensor: sensor,
                        controller: self,
                        onFirstFrame: nil
                    )
                    .ignoresSafeArea()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                )

                extWindow.contentView = extHostView
                extWindow.orderFront(nil)
                self.externalWindows.append(extWindow)
            }
            self.isExternalShowing = !self.externalWindows.isEmpty
        }

        self.isShowing = (builtinWindow != nil || !externalWindows.isEmpty)
    }

    /// Convenience show method for single snapshot
    func show(snapshot: CGImage, sensor: LidSensor, showCalibrator: Bool = false, onDismiss: (() -> Void)? = nil) {
        var snapshots = MultiScreenSnapshots()
        snapshots.builtinSnapshot = snapshot
        snapshots.builtinScreen = NSScreen.main
        show(snapshots: snapshots, sensor: sensor, showCalibrator: showCalibrator, onDismiss: onDismiss)
    }

    /// Unwarps both builtin and external overlays.
    func unwarpAndDismiss(completion: (() -> Void)? = nil) {
        unwarpAndDismissBuiltin()
        unwarpAndDismissExternal(completion: completion)
    }

    /// Smoothly unwarps and fades out only the external monitor(s) so they return to an interactive desktop.
    func unwarpAndDismissExternal(completion: (() -> Void)? = nil) {
        guard isExternalShowing, !isExternalSettling else {
            completion?()
            return
        }
        isExternalSettling = true
        onExternalSettleCompleted = { [weak self] in
            self?.fadeAndDismissExternal(completion: completion)
        }
    }

    /// Smoothly fades out external monitor overlay windows.
    func fadeAndDismissExternal(completion: (() -> Void)? = nil) {
        let windows = self.externalWindows
        self.externalWindows.removeAll()
        self.isExternalShowing = false
        self.isExternalSettling = false
        self.onExternalSettleCompleted = nil

        guard !windows.isEmpty else {
            completion?()
            return
        }

        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.14
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            for win in windows {
                win.isOpaque = false
                win.backgroundColor = .clear
                win.animator().alphaValue = 0.0
            }
        }, completionHandler: {
            for win in windows {
                win.orderOut(nil)
            }
            DispatchQueue.main.async {
                completion?()
            }
        })
    }

    /// Smoothly unwarps and fades out the built-in laptop screen overlay.
    func unwarpAndDismissBuiltin(completion: (() -> Void)? = nil) {
        guard builtinWindow != nil, !viewState.isSettling else {
            completion?()
            return
        }
        viewState.isSettling = true
        viewState.onSettleCompleted = { [weak self] in
            self?.fadeAndDismissBuiltin(completion: completion)
        }
    }

    /// Smoothly fades out the built-in overlay window to reveal the live desktop underneath.
    func fadeAndDismissBuiltin(completion: (() -> Void)? = nil) {
        guard let activeWindow = builtinWindow else {
            completion?()
            return
        }
        if externalWindows.isEmpty {
            isShowing = false
        }
        let handler = self.onDismissal
        if externalWindows.isEmpty {
            self.onDismissal = nil
        }

        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.10
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            activeWindow.animator().alphaValue = 0.0
        }, completionHandler: {
            activeWindow.orderOut(nil)
            activeWindow.alphaValue = 1.0
            DispatchQueue.main.async {
                if self.externalWindows.isEmpty {
                    handler?()
                }
                completion?()
            }
        })
    }

    /// Legacy / backward compatible method for fading and dismissing builtin
    func fadeAndDismiss(completion: (() -> Void)? = nil) {
        fadeAndDismissBuiltin(completion: completion)
    }

    /// Cancels settling in progress if user resumes moving the lid.
    func cancelSettling() {
        if viewState.isSettling {
            viewState.isSettling = false
            viewState.onSettleCompleted = nil
        }
        if isExternalSettling {
            isExternalSettling = false
            onExternalSettleCompleted = nil
        }
    }

    /// Activates the digital perspective clock mode (dims background and shows 3D clock)
    func activateClockMode() {
        guard isShowing, !viewState.isSettling, !viewState.showCalibrator else { return }
        viewState.isClockActive = true
    }

    /// Deactivates clock mode, restoring normal perspective view
    func deactivateClockMode() {
        viewState.isClockActive = false
    }

    /// Immediate dismissal of all overlays (e.g. lid opened past 90° or ESC pressed).
    func dismiss(completion: (() -> Void)? = nil) {
        cancelSettling()
        deactivateClockMode()
        let activeBuiltin = builtinWindow
        let activeExternals = externalWindows

        externalWindows.removeAll()
        isShowing = false
        isExternalShowing = false

        let handler = self.onDismissal
        self.onDismissal = nil

        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.10
            context.timingFunction = CAMediaTimingFunction(name: .easeIn)
            if let bWindow = activeBuiltin {
                bWindow.animator().alphaValue = 0.0
            }
            for extWindow in activeExternals {
                extWindow.animator().alphaValue = 0.0
            }
        }, completionHandler: {
            activeBuiltin?.orderOut(nil)
            activeBuiltin?.alphaValue = 1.0
            for extWindow in activeExternals {
                extWindow.orderOut(nil)
                extWindow.alphaValue = 1.0
            }
            DispatchQueue.main.async {
                handler?()
                completion?()
            }
        })
    }
}

// MARK: - Clock Customization Enums
enum ClockPosition: String, CaseIterable, Identifiable, Codable {
    case topLeading = "Top Left"
    case top = "Top"
    case topTrailing = "Top Right"
    case leading = "Center Left"
    case center = "Center"
    case trailing = "Center Right"
    case bottomLeading = "Bottom Left"
    case bottom = "Bottom"
    case bottomTrailing = "Bottom Right"

    var id: String { rawValue }

    var alignment: Alignment {
        switch self {
        case .topLeading: return .topLeading
        case .top: return .top
        case .topTrailing: return .topTrailing
        case .leading: return .leading
        case .center: return .center
        case .trailing: return .trailing
        case .bottomLeading: return .bottomLeading
        case .bottom: return .bottom
        case .bottomTrailing: return .bottomTrailing
        }
    }

    var horizontalAlignment: HorizontalAlignment {
        switch self {
        case .topLeading, .leading, .bottomLeading: return .leading
        case .topTrailing, .trailing, .bottomTrailing: return .trailing
        default: return .center
        }
    }
}

enum ClockSize: String, CaseIterable, Identifiable, Codable {
    case small = "Small"
    case medium = "Medium"
    case large = "Large"
    case jumbo = "Jumbo"

    var id: String { rawValue }

    var scaleMultiplier: CGFloat {
        switch self {
        case .small: return 0.65
        case .medium: return 0.82
        case .large: return 1.00
        case .jumbo: return 1.25
        }
    }
}

// MARK: - Tunable Parameters
enum TunableSetting: Int, CaseIterable, Identifiable {
    // MARK: - Perspective & Display Settings
    case keystone = 0
    case stretch = 1
    case lowAngleCompensation = 2
    case lookahead = 3
    case blurIntensity = 4
    case shadowIntensity = 5
    case frostedGlass = 6

    // MARK: - Keyboard Reflection Settings
    case keyboardReflection = 7
    case keyboardTilt = 8
    case keyboardReach = 9
    case keyboardBacklight = 10
    case keyboardDepthBlur = 11
    case keyboardOffset = 12
    case keyboardWidth = 13

    var id: Int { rawValue }

    static var perspectiveSettings: [TunableSetting] {
        [.keystone, .stretch, .lowAngleCompensation, .lookahead, .blurIntensity, .shadowIntensity, .frostedGlass]
    }

    static var keyboardSettings: [TunableSetting] {
        [.keyboardReflection, .keyboardTilt, .keyboardReach, .keyboardBacklight, .keyboardDepthBlur, .keyboardOffset, .keyboardWidth]
    }

    var title: String {
        switch self {
        case .keystone: return "X balance"
        case .stretch: return "Y Balance"
        case .lowAngleCompensation: return "Low-Angle Compensation"
        case .lookahead: return "Hinge Delay Negation"
        case .blurIntensity: return "Blurring Effect"
        case .shadowIntensity: return "Shadow Effect"
        case .frostedGlass: return "Frosted Glass"
        case .keyboardReflection: return "Keyboard Reflection"
        case .keyboardTilt: return "Reflection Tilt"
        case .keyboardReach: return "Reflection Reach"
        case .keyboardBacklight: return "Key Backlight Glow"
        case .keyboardDepthBlur: return "Keyboard Depth Blur"
        case .keyboardOffset: return "Bottom Offset"
        case .keyboardWidth: return "Keyboard Width"
        }
    }
}

@MainActor
final class OverlayViewState: ObservableObject {
    // Cached snapshot and GPU textures for instant presentation
    @Published var currentSnapshot: CGImage?
    @Published var currentTexture: MTLTexture?
    @Published var currentBlurredTexture: MTLTexture?

    @Published var showHUD: Bool = false
    @Published var showCalibrator: Bool = false
    // Window Focus / State tracking for Calibrator activation guard
    @Published var isSettingsWindowOpen: Bool = false
    @Published var isSettingsWindowFocused: Bool = false
    weak var settingsWindow: NSWindow? = nil {
        didSet {
            guard let window = settingsWindow else { return }
            isSettingsWindowOpen = true
            isSettingsWindowFocused = true
            NotificationCenter.default.addObserver(
                forName: NSWindow.willCloseNotification,
                object: window,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.isSettingsWindowOpen = false
                    self?.isSettingsWindowFocused = false
                    self?.settingsWindow = nil
                }
            }
        }
    }
    @Published var keystoneStrength: Float = 0.18
    @Published var stretchBalance: Float = 0.56
    @Published var lowAngleCompensation: Float = 1.00
    @Published var lookaheadTime: Double = 0.4
    @Published var activationCount: Int = 0
    @Published var isKeyboardReflectionEnabled: Bool = true
    @Published var keyboardReflection: Float = 0.44
    @Published var isFrostedGlassEnabled: Bool = true
    @Published var frostedGlass: Float = 0.10
    @Published var keyboardTilt: Float = 0.40
    @Published var keyboardReach: Float = 0.38
    @Published var keyboardBacklight: Float = 1.50
    @Published var keyboardOffset: Float = -0.01
    @Published var keyboardWidth: Float = 0.88
    @Published var keyboardDepthBlur: Float = 0.30
    @Published var blurIntensity: Float = 1.00
    @Published var shadowIntensity: Float = 1.00

    // Calibrator State
    @Published var selectedSettingIndex: Int = 0
    @Published var menuImage: CGImage? = nil
    var screenSize: CGSize = CGSize(width: 1920, height: 1080)

    var isSettingsWindowAvailable: Bool {
        if isSettingsWindowOpen || isSettingsWindowFocused {
            return true
        }
        if let window = settingsWindow {
            return window.isVisible || window.windowNumber > 0
        }
        return NSApp.windows.contains { window in
            let title = window.title
            let id = window.identifier?.rawValue ?? ""
            return (title.contains("Settings") || id.contains("settings")) && (window.isVisible || window.windowNumber > 0)
        }
    }

    // Settle animation state
    @Published var isSettling: Bool = false
    var onSettleCompleted: (() -> Void)?

    func nextSetting() {
        let count = TunableSetting.allCases.count
        selectedSettingIndex = (selectedSettingIndex + 1) % count
        requestRender()
    }

    func previousSetting() {
        let count = TunableSetting.allCases.count
        selectedSettingIndex = (selectedSettingIndex - 1 + count) % count
        requestRender()
    }

    func adjustSelectedSetting(by direction: Int) {
        guard let setting = TunableSetting(rawValue: selectedSettingIndex) else { return }
        let step = Float(direction)
        switch setting {
        case .keystone:
            keystoneStrength = min(max(keystoneStrength + step * 0.01, 0.0), 1.0)
        case .stretch:
            stretchBalance = min(max(stretchBalance + step * 0.01, 0.01), 1.5)
        case .lowAngleCompensation:
            let newComp = round((lowAngleCompensation + step * 0.05) * 100) / 100
            lowAngleCompensation = min(max(newComp, 0.0), 2.0)
        case .lookahead:
            lookaheadTime = min(max(lookaheadTime + Double(direction) * 0.02, 0.0), 0.5)
        case .keyboardReflection:
            if direction > 0 && !isKeyboardReflectionEnabled {
                isKeyboardReflectionEnabled = true
            } else if direction < 0 && keyboardReflection <= 0.04 {
                isKeyboardReflectionEnabled = false
            } else {
                keyboardReflection = min(max(keyboardReflection + step * 0.02, 0.0), 1.0)
            }
        case .frostedGlass:
            if direction > 0 && !isFrostedGlassEnabled {
                isFrostedGlassEnabled = true
            } else if direction < 0 && frostedGlass <= 0.05 {
                isFrostedGlassEnabled = false
            } else {
                frostedGlass = min(max(frostedGlass + step * 0.05, 0.0), 1.0)
            }
        case .keyboardTilt:
            keyboardTilt = min(max(keyboardTilt + step * 0.05, 0.15), 2.0)
        case .keyboardReach:
            keyboardReach = min(max(keyboardReach + step * 0.02, 0.12), 0.65)
        case .keyboardBacklight:
            keyboardBacklight = min(max(keyboardBacklight + step * 0.05, 0.0), 2.5)
        case .keyboardOffset:
            keyboardOffset = min(max(keyboardOffset + step * 0.01, -0.10), 0.20)
        case .keyboardWidth:
            keyboardWidth = min(max(keyboardWidth + step * 0.02, 0.60), 1.00)
        case .keyboardDepthBlur:
            keyboardDepthBlur = min(max(keyboardDepthBlur + step * 0.05, 0.0), 3.0)
        case .blurIntensity:
            let newBlur = round((blurIntensity + step * 0.05) * 100) / 100
            blurIntensity = min(max(newBlur, 0.0), 2.0)
        case .shadowIntensity:
            let newShadow = round((shadowIntensity + step * 0.05) * 100) / 100
            shadowIntensity = min(max(newShadow, 0.0), 2.0)
        }
        requestRender()
    }

    func resetToDefaults() {
        keystoneStrength = 0.18
        stretchBalance = 0.56
        lowAngleCompensation = 1.00
        lookaheadTime = 0.4
        isKeyboardReflectionEnabled = true
        keyboardReflection = 0.44
        isFrostedGlassEnabled = true
        frostedGlass = 0.10
        keyboardTilt = 0.40
        keyboardReach = 0.38
        keyboardBacklight = 1.50
        keyboardOffset = -0.01
        keyboardWidth = 0.88
        keyboardDepthBlur = 0.30
        blurIntensity = 1.00
        shadowIntensity = 1.00
        requestRender()
    }

    private var appearanceSubscription: AnyCancellable?

    init() {
        if let app = NSApp {
            appearanceSubscription = app.publisher(for: \.effectiveAppearance)
                .receive(on: DispatchQueue.main)
                .sink { [weak self] _ in
                    self?.requestRender()
                }
        }
    }

    func requestRender() {
        guard showCalibrator else { return }
        let isDarkMode = NSApp.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        let view = WarpedSettingsCardContainer(state: self, isDarkMode: isDarkMode)
            .environment(\.colorScheme, isDarkMode ? .dark : .light)
            .frame(width: screenSize.width, height: screenSize.height)
        let renderer = ImageRenderer(content: view)
        renderer.scale = NSScreen.main?.backingScaleFactor ?? 2.0
        renderer.isOpaque = false
        renderer.proposedSize = ProposedViewSize(width: screenSize.width, height: screenSize.height)
        if let cgImage = renderer.cgImage {
            self.menuImage = cgImage
        }
    }

    // MARK: - Clock Mode State & Rendering
    @Published var isClockActive: Bool = false {
        didSet {
            if isClockActive {
                startClockUpdates()
            } else {
                stopClockUpdates()
            }
        }
    }
    @Published var clockImage: CGImage? = nil
    var currentLidAngle: Double = 90.0

    @Published var clockPosition: ClockPosition = {
        if let raw = UserDefaults.standard.string(forKey: "clockPosition"),
           let pos = ClockPosition(rawValue: raw) {
            return pos
        }
        return .center
    }() {
        didSet {
            UserDefaults.standard.set(clockPosition.rawValue, forKey: "clockPosition")
            if isClockActive {
                requestClockRender()
            }
        }
    }

    @Published var clockSize: ClockSize = {
        if let raw = UserDefaults.standard.string(forKey: "clockSize"),
           let size = ClockSize(rawValue: raw) {
            return size
        }
        return .large
    }() {
        didSet {
            UserDefaults.standard.set(clockSize.rawValue, forKey: "clockSize")
            if isClockActive {
                requestClockRender()
            }
        }
    }

    @Published var useStandByStyle: Bool = {
        UserDefaults.standard.bool(forKey: "useStandByStyle")
    }() {
        didSet {
            UserDefaults.standard.set(useStandByStyle, forKey: "useStandByStyle")
            if isClockActive {
                requestClockRender()
            }
        }
    }

    private var clockTimer: Timer?

    private func startClockUpdates() {
        requestClockRender()
        clockTimer?.invalidate()
        clockTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self = self, self.isClockActive else { return }
                self.requestClockRender()
            }
        }
    }

    private func stopClockUpdates() {
        clockTimer?.invalidate()
        clockTimer = nil
    }

    func requestClockRender() {
        let view = PerspectiveClockView(
            angle: currentLidAngle,
            date: Date(),
            screenSize: screenSize,
            position: clockPosition,
            size: clockSize,
            useStandByStyle: useStandByStyle
        )
        .frame(width: screenSize.width, height: screenSize.height)
        let renderer = ImageRenderer(content: view)
        renderer.scale = NSScreen.main?.backingScaleFactor ?? 2.0
        renderer.isOpaque = false
        renderer.proposedSize = ProposedViewSize(width: screenSize.width, height: screenSize.height)
        if let cgImage = renderer.cgImage {
            self.clockImage = cgImage
        }
    }
}

// MARK: - StandBy Month Calendar Info
struct MonthCalendarInfo {
    let weekdayHeader: String
    let monthShort: String
    let dayString: String
    let monthName: String
    let daysInMonth: Int
    let firstWeekdayOffset: Int
    let currentDay: Int

    static func current(from date: Date) -> MonthCalendarInfo {
        let cal = Calendar.current
        let day = cal.component(.day, from: date)
        let year = cal.component(.year, from: date)
        let month = cal.component(.month, from: date)

        let fmtDayOfWeek = DateFormatter()
        fmtDayOfWeek.dateFormat = "EEE"
        let weekdayHeader = fmtDayOfWeek.string(from: date)

        let fmtMonthShort = DateFormatter()
        fmtMonthShort.dateFormat = "MMM"
        let monthShort = fmtMonthShort.string(from: date)

        let fmtMonthFull = DateFormatter()
        fmtMonthFull.dateFormat = "MMMM"
        let monthName = fmtMonthFull.string(from: date).uppercased()

        let comps = DateComponents(year: year, month: month, day: 1)
        let firstDay = cal.date(from: comps) ?? date
        let firstWeekday = cal.component(.weekday, from: firstDay) // 1 = Sunday
        let offset = firstWeekday - 1

        let daysCount = cal.range(of: .day, in: .month, for: date)?.count ?? 30

        return MonthCalendarInfo(
            weekdayHeader: weekdayHeader,
            monthShort: monthShort,
            dayString: "\(day)",
            monthName: monthName,
            daysInMonth: daysCount,
            firstWeekdayOffset: offset,
            currentDay: day
        )
    }
}

// MARK: - StandBy Calendar & Squircle Clock (Apple StandBy Dual-Widget Layout)
struct StandByCalendarClockView: View {
    var date: Date = Date()
    var angle: Double = 45.0
    var sizeMultiplier: CGFloat = 1.0

    private var calendarInfo: MonthCalendarInfo {
        MonthCalendarInfo.current(from: date)
    }

    private var calendar: Calendar { Calendar.current }
    private var hour: Int { calendar.component(.hour, from: date) }
    private var minute: Int { calendar.component(.minute, from: date) }
    private var second: Int { calendar.component(.second, from: date) }

    private var hourAngle: Double {
        let h = Double(hour % 12)
        let m = Double(minute)
        return (h + m / 60.0) * 30.0
    }

    private var minuteAngle: Double {
        let m = Double(minute)
        let s = Double(second)
        return (m + s / 60.0) * 6.0
    }

    private var secondAngle: Double {
        Double(second) * 6.0
    }

    private var leftCardWidth: CGFloat {
        max(215, 250 * sizeMultiplier)
    }

    private var rightCardSize: CGFloat {
        max(235, 275 * sizeMultiplier)
    }

    private var cardHeight: CGFloat {
        rightCardSize
    }

    private let amberColor = Color(red: 1.0, green: 0.80, blue: 0.0)

    var body: some View {
        HStack(spacing: max(18, 28 * sizeMultiplier)) {
            // LEFT WIDGET: Date & Monthly Calendar
            VStack(alignment: .leading, spacing: 0) {
                // Top Left: Day of week + Month header
                HStack(spacing: 6 * sizeMultiplier) {
                    Text(calendarInfo.weekdayHeader)
                        .foregroundStyle(amberColor)
                    Text(calendarInfo.monthShort)
                        .foregroundStyle(Color.white.opacity(0.85))
                }
                .font(.system(size: max(18, 25 * sizeMultiplier), weight: .bold, design: .default))
                .shadow(color: Color.black.opacity(0.35), radius: 4, x: 0, y: 1)

                // Giant Date Number
                Text(calendarInfo.dayString)
                    .font(.system(size: max(60, 84 * sizeMultiplier), weight: .medium, design: .default))
                    .foregroundStyle(Color.white)
                    .shadow(color: Color.black.opacity(0.40), radius: 6, x: 0, y: 2)
                    .padding(.top, -4 * sizeMultiplier)
                    .padding(.bottom, 6 * sizeMultiplier)

                Spacer(minLength: 0)

                // Bottom Left: Month Name Header
                Text(calendarInfo.monthName)
                    .font(.system(size: max(9, 11 * sizeMultiplier), weight: .heavy, design: .default))
                    .tracking(1.2)
                    .foregroundStyle(amberColor)
                    .padding(.bottom, 4 * sizeMultiplier)

                // Weekday initials row: S M T W T F S
                let weekdays = ["S", "M", "T", "W", "T", "F", "S"]
                HStack(spacing: 0) {
                    ForEach(0..<7, id: \.self) { idx in
                        Text(weekdays[idx])
                            .font(.system(size: max(8, 10 * sizeMultiplier), weight: .bold, design: .default))
                            .foregroundStyle(Color.white.opacity(0.55))
                            .frame(maxWidth: .infinity)
                    }
                }
                .padding(.bottom, 3 * sizeMultiplier)

                // Calendar Day Grid
                let totalSlots = calendarInfo.firstWeekdayOffset + calendarInfo.daysInMonth
                let rows = (totalSlots + 6) / 7
                VStack(spacing: 3 * sizeMultiplier) {
                    ForEach(0..<rows, id: \.self) { row in
                        HStack(spacing: 0) {
                            ForEach(0..<7, id: \.self) { col in
                                let index = row * 7 + col
                                let dayNum = index - calendarInfo.firstWeekdayOffset + 1
                                if dayNum >= 1 && dayNum <= calendarInfo.daysInMonth {
                                    let isToday = (dayNum == calendarInfo.currentDay)
                                    ZStack {
                                        if isToday {
                                            Circle()
                                                .fill(amberColor)
                                                .frame(width: max(16, 20 * sizeMultiplier), height: max(16, 20 * sizeMultiplier))
                                        }
                                        Text("\(dayNum)")
                                            .font(.system(size: max(8.5, 11 * sizeMultiplier), weight: isToday ? .bold : .semibold, design: .default))
                                            .foregroundStyle(isToday ? Color.black : Color.white.opacity(0.85))
                                    }
                                    .frame(maxWidth: .infinity)
                                } else {
                                    Text("")
                                        .font(.system(size: max(8.5, 11 * sizeMultiplier)))
                                        .frame(maxWidth: .infinity)
                                }
                            }
                        }
                    }
                }
            }
            .padding(18 * sizeMultiplier)
            .frame(width: leftCardWidth, height: cardHeight, alignment: .topLeading)
            .background(
                RoundedRectangle(cornerRadius: max(24, 34 * sizeMultiplier), style: .continuous)
                    .fill(Color.black.opacity(0.36))
            )
            .overlay(
                RoundedRectangle(cornerRadius: max(24, 34 * sizeMultiplier), style: .continuous)
                    .strokeBorder(Color.white.opacity(0.18), lineWidth: 1.2)
            )
            .shadow(color: Color.black.opacity(0.40), radius: 24, x: 0, y: 10)

            // RIGHT WIDGET: Squircle Analog Clock
            ZStack {
                // Squircle Glass Dial Face
                RoundedRectangle(cornerRadius: max(24, 34 * sizeMultiplier), style: .continuous)
                    .fill(Color.black.opacity(0.36))
                    .overlay(
                        RoundedRectangle(cornerRadius: max(24, 34 * sizeMultiplier), style: .continuous)
                            .strokeBorder(Color.white.opacity(0.18), lineWidth: 1.2)
                    )
                    .shadow(color: Color.black.opacity(0.40), radius: 24, x: 0, y: 10)

                // Perimeter Minute and Hour Hash Marks
                let halfW = rightCardSize / 2
                ForEach(0..<60, id: \.self) { i in
                    let angleDeg = Double(i) * 6.0
                    let isCardinal = (i % 15 == 0) // 12, 3, 6, 9
                    let isHourTick = (i % 5 == 0 && !isCardinal) // 1, 2, 4, 5, 7, 8, 10, 11

                    if !isCardinal {
                        let tickLen: CGFloat = isHourTick ? max(14, 22 * sizeMultiplier) : max(4, 7 * sizeMultiplier)
                        let tickWidth: CGFloat = isHourTick ? max(2.5, 3.5 * sizeMultiplier) : max(1.2, 1.8 * sizeMultiplier)
                        let r = halfW - (16 * sizeMultiplier) - (tickLen / 2)

                        Capsule()
                            .fill(Color.white.opacity(isHourTick ? 0.90 : 0.50))
                            .frame(width: tickWidth, height: tickLen)
                            .offset(y: -r)
                            .rotationEffect(.degrees(angleDeg))
                    }
                }

                // Cardinal Hour Numerals: 12, 3, 6, 9
                let numRadius = halfW - (32 * sizeMultiplier)
                ForEach([12, 3, 6, 9], id: \.self) { num in
                    let ang = Double(num % 12) * 30.0 * .pi / 180.0
                    Text("\(num)")
                        .font(.system(size: max(18, 26 * sizeMultiplier), weight: .bold, design: .default))
                        .foregroundStyle(Color.white)
                        .shadow(color: Color.black.opacity(0.40), radius: 4, x: 0, y: 1)
                        .offset(x: CGFloat(sin(ang)) * numRadius, y: CGFloat(-cos(ang)) * numRadius)
                }

                // Hour Hand (White Rounded Capsule)
                Capsule()
                    .fill(Color.white)
                    .frame(width: max(5, 6.5 * sizeMultiplier), height: rightCardSize * 0.28)
                    .shadow(color: Color.black.opacity(0.45), radius: 6, x: 0, y: 3)
                    .offset(y: -rightCardSize * 0.14)
                    .rotationEffect(.degrees(hourAngle))

                // Minute Hand (White Rounded Capsule)
                Capsule()
                    .fill(Color.white)
                    .frame(width: max(3.5, 4.5 * sizeMultiplier), height: rightCardSize * 0.40)
                    .shadow(color: Color.black.opacity(0.45), radius: 6, x: 0, y: 3)
                    .offset(y: -rightCardSize * 0.20)
                    .rotationEffect(.degrees(minuteAngle))

                // Amber Second Hand Needle + Counter-Weight
                VStack(spacing: 0) {
                    Capsule()
                        .fill(amberColor)
                        .frame(width: max(1.6, 2.0 * sizeMultiplier), height: rightCardSize * 0.44)
                    Capsule()
                        .fill(amberColor)
                        .frame(width: max(1.6, 2.0 * sizeMultiplier), height: rightCardSize * 0.10)
                }
                .offset(y: -(rightCardSize * 0.44 - rightCardSize * 0.10) / 2)
                .shadow(color: Color.black.opacity(0.35), radius: 3, x: 0, y: 1)
                .rotationEffect(.degrees(secondAngle))

                // Amber Center Cap with Dark Core
                Circle()
                    .fill(amberColor)
                    .frame(width: max(8, 10 * sizeMultiplier), height: max(8, 10 * sizeMultiplier))
                    .overlay(
                        Circle()
                            .fill(Color.black.opacity(0.90))
                            .frame(width: max(2.5, 3.5 * sizeMultiplier), height: max(2.5, 3.5 * sizeMultiplier))
                    )
                    .shadow(color: Color.black.opacity(0.40), radius: 3, x: 0, y: 1)
            }
            .frame(width: rightCardSize, height: rightCardSize)
        }
    }
}

// MARK: - Perspective Clock View (Apple Native Liquid Glass Lock Screen Clock & StandBy Dual Widget)
struct PerspectiveClockView: View {
    var angle: Double = 45.0
    var date: Date = Date()
    var screenSize: CGSize = CGSize(width: 1920, height: 1080)
    var position: ClockPosition = .center
    var size: ClockSize = .large
    var useStandByStyle: Bool = false

    private var is24Hour: Bool {
        let format = DateFormatter.dateFormat(fromTemplate: "j", options: 0, locale: Locale.current) ?? ""
        return !format.contains("a")
    }

    private var timeString: String {
        let formatter = DateFormatter()
        formatter.locale = Locale.current
        formatter.dateFormat = is24Hour ? "HH:mm" : "h:mm"
        return formatter.string(from: date)
    }

    private var dateString: String {
        let formatter = DateFormatter()
        formatter.locale = Locale.current
        formatter.dateFormat = "EEEE, MMMM d"
        return formatter.string(from: date)
    }

    private var timeFontSize: CGFloat {
        let base = min(screenSize.width * 0.22, screenSize.height * 0.32)
        let raw = max(180, min(base, 260)) * size.scaleMultiplier
        return raw
    }

    private var dateFontSize: CGFloat {
        return max(18, min(timeFontSize * 0.165, 34))
    }

    private var horizontalPadding: CGFloat {
        switch position {
        case .topLeading, .leading, .bottomLeading: return 70
        case .topTrailing, .trailing, .bottomTrailing: return 70
        default: return 40
        }
    }

    private var verticalPadding: CGFloat {
        switch position {
        case .top, .topLeading, .topTrailing: return 75
        case .bottom, .bottomLeading, .bottomTrailing: return 60
        case .center, .leading, .trailing: return 40
        }
    }

    var body: some View {
        ZStack(alignment: position.alignment) {
            Color.clear

            if useStandByStyle {
                // StandBy Dual-Widget: Date & Monthly Calendar (Left) + Squircle Clock (Right)
                StandByCalendarClockView(date: date, angle: angle, sizeMultiplier: size.scaleMultiplier)
                    .padding(.horizontal, horizontalPadding)
                    .padding(.vertical, verticalPadding)
            } else {
                // Pure Apple Lock Screen Liquid Glass Clock
                VStack(alignment: position.horizontalAlignment, spacing: max(2, 6 * size.scaleMultiplier)) {
                    // Top Date Header — Apple Lock Screen Typography (No icon, Title Case)
                    Text(dateString)
                        .font(.system(size: dateFontSize, weight: .semibold, design: .default))
                        .foregroundStyle(Color.white.opacity(0.96))
                        .shadow(color: Color.black.opacity(0.45), radius: 8, x: 0, y: 2)

                    // Hero Digital Clock — Apple Lock Screen Liquid Glass
                    Text(timeString)
                        .font(.system(size: timeFontSize, weight: .semibold, design: .default))
                        .foregroundStyle(
                            LinearGradient(
                                stops: [
                                    .init(color: Color(red: 1.0, green: 0.99, blue: 0.94).opacity(0.96), location: 0.0),
                                    .init(color: Color(white: 0.98).opacity(0.88), location: 0.35),
                                    .init(color: Color(red: 0.93, green: 0.95, blue: 1.0).opacity(0.72), location: 0.65),
                                    .init(color: Color(red: 0.88, green: 0.91, blue: 0.98).opacity(0.82), location: 1.0)
                                ],
                                startPoint: .top,
                                endPoint: .bottom
                            )
                        )
                        .shadow(color: Color.black.opacity(0.42), radius: 18, x: 0, y: 8)
                        .shadow(color: Color.black.opacity(0.25), radius: 4, x: 0, y: 2)
                }
                .padding(.horizontal, horizontalPadding)
                .padding(.vertical, verticalPadding)
            }
        }
    }
}

// MARK: - Key-Catching Window
private class KeyCatchingWindow: NSWindow {
    var onEscape: (() -> Void)?
    var onToggleHUD: (() -> Void)?
    var onToggleCalibrator: (() -> Void)?
    var onToggleClock: (() -> Void)?
    var onToggleKeyboard: (() -> Void)?
    var onToggleFrostedGlass: (() -> Void)?
    var onArrowUp: (() -> Void)?
    var onArrowDown: (() -> Void)?
    var onArrowLeft: (() -> Void)?
    var onArrowRight: (() -> Void)?
    var onReset: (() -> Void)?
    var onMouseDown: (() -> Void)?
    var onActivity: (() -> Void)?

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }

    override func mouseDown(with event: NSEvent) {
        onActivity?()
        if let onMouseDown = onMouseDown {
            onMouseDown()
        } else {
            super.mouseDown(with: event)
        }
    }

    override func keyDown(with event: NSEvent) {
        onActivity?()
        switch event.keyCode {
        case 53: // ESC
            onEscape?()
        case 17: // 'T' key (Time / Clock toggle)
            onToggleClock?()
        case 126: // Up Arrow
            onArrowUp?()
        case 125: // Down Arrow
            onArrowDown?()
        case 123: // Left Arrow
            onArrowLeft?()
        case 124: // Right Arrow
            onArrowRight?()
        case 8: // 'C' key
            onToggleCalibrator?()
        case 40: // 'K' key
            onToggleKeyboard?()
        case 3: // 'F' key
            onToggleFrostedGlass?()
        case 15: // 'R' key
            onReset?()
        default:
            let char = event.charactersIgnoringModifiers?.lowercased()
            if char == "c" {
                onToggleCalibrator?()
            } else if char == "t" {
                onToggleClock?()
            } else if char == "k" {
                onToggleKeyboard?()
            } else if char == "f" {
                onToggleFrostedGlass?()
            } else if char == "h" {
                onToggleHUD?()
            } else {
                super.keyDown(with: event)
            }
        }
    }
}

// MARK: - Fullscreen Perspective Container
private struct FullscreenPerspectiveContainer: View {
    let sensor: LidSensor
    @ObservedObject var state: OverlayViewState
    var onFirstFrame: (() -> Void)? = nil
    let onDismiss: () -> Void

    var body: some View {
        ZStack(alignment: .topTrailing) {
            // Fullscreen Metal Canvas
            PerspectiveMetalView(
                snapshot: state.currentSnapshot,
                preloadedTexture: state.currentTexture,
                preloadedBlurredTexture: state.currentBlurredTexture,
                calibratorImage: state.menuImage,
                showCalibrator: state.showCalibrator,
                clockImage: state.clockImage,
                isClockActive: state.isClockActive,
                sensor: sensor,
                fallbackAngle: sensor.currentAngle,
                lookahead: state.lookaheadTime,
                activationCount: state.activationCount,
                keystoneStrength: state.keystoneStrength,
                stretchBalance: state.stretchBalance,
                lowAngleCompensation: state.lowAngleCompensation,
                keyboardReflection: state.isKeyboardReflectionEnabled ? state.keyboardReflection : 0.0,
                keyboardTilt: state.keyboardTilt,
                keyboardReach: state.keyboardReach,
                keyboardBacklight: state.keyboardBacklight,
                keyboardOffset: state.keyboardOffset,
                keyboardWidth: state.keyboardWidth,
                keyboardDepthBlur: state.keyboardDepthBlur,
                frostedGlass: state.isFrostedGlassEnabled ? state.frostedGlass : 0.0,
                blurIntensity: state.blurIntensity,
                shadowIntensity: state.shadowIntensity,
                isSettling: state.isSettling,
                onSettleCompleted: {
                    state.onSettleCompleted?()
                },
                onFirstFrame: onFirstFrame
            )
            .ignoresSafeArea()

            // Traditional Floating Tweaker Panel (Optional fallback via 'H' key)
            if state.showHUD {
                floatingHudPanel
            }
        }
        .ignoresSafeArea()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .animation(.easeInOut(duration: 0.2), value: state.showHUD)
        .onAppear {
            state.currentLidAngle = sensor.displayAngle
            if state.showCalibrator {
                state.requestRender()
            }
            if state.isClockActive {
                state.requestClockRender()
            }
        }
    }

    private var floatingHudPanel: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Perspective Tuner (Side HUD)")
                    .font(.headline)
                Spacer()
                Button("Close") { state.showHUD = false }
                    .font(.caption)
                    .buttonStyle(.borderless)
            }
            Divider()
            Text("Press [H] to toggle this panel, or press [C] when lid is tilted to show the perspective calibrator.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(14)
        .frame(width: 280)
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
    }
}

// MARK: - External Monitor Container
private struct ExternalMonitorContainer: View {
    let snapshot: CGImage
    var preloadedTexture: MTLTexture? = nil
    var preloadedBlurredTexture: MTLTexture? = nil
    let sensor: LidSensor
    @ObservedObject var controller: FullscreenOverlayController
    var onFirstFrame: (() -> Void)? = nil

    var body: some View {
        ExternalDisplayMetalView(
            snapshot: snapshot,
            preloadedTexture: preloadedTexture,
            preloadedBlurredTexture: preloadedBlurredTexture,
            sensor: sensor,
            fallbackAngle: sensor.currentAngle,
            lookahead: controller.viewState.lookaheadTime,
            activationCount: controller.viewState.activationCount,
            maxZoomOut: controller.externalZoomOut,
            maxBlur: controller.externalBlur,
            maxDarken: controller.externalDarken,
            isSettling: controller.isExternalSettling,
            onSettleCompleted: {
                controller.onExternalSettleCompleted?()
            },
            onFirstFrame: onFirstFrame
        )
        .ignoresSafeArea()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Warped Settings Card (Rendered directly into Metal Texture)
private struct WarpedSettingsCardContainer: View {
    @ObservedObject var state: OverlayViewState
    var isDarkMode: Bool

    var body: some View {
        ZStack {
            // Transparent backdrop for entire screen canvas
            Color.clear

            // Simulated MacBook Bezel with Blue Outline on frame perimeter
            macbookBezelFrame

            // 8 Calibration Squares around the screen perimeter & Prominent Dashed Hairline
            calibrationSquares

            // Centered Native Apple Settings Card
            VStack(spacing: 14) {
                // Header: macOS Settings / Inspector style
                HStack(spacing: 12) {
                    // App / Tool icon in Apple squircle
                    ZStack {
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(Color.accentColor.opacity(isDarkMode ? 0.25 : 0.15))
                            .frame(width: 34, height: 34)

                        Image(systemName: "slider.horizontal.2.square")
                            .font(.system(size: 18, weight: .medium))
                            .foregroundStyle(Color.accentColor)
                    }

                    VStack(alignment: .leading, spacing: 2) {
                        Text("Perspective Calibrator")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(Color.primary)

                        Text("Tune the shader based on your distance and preference")
                            .font(.system(size: 11, weight: .regular))
                            .foregroundStyle(Color.secondary)
                    }

                    Spacer()

                    // Native status pill
                    HStack(spacing: 5) {
                        Circle()
                            .fill(Color.green)
                            .frame(width: 6, height: 6)

                        Text("Active")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(Color.secondary)
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(
                        Capsule()
                            .fill(Color.primary.opacity(isDarkMode ? 0.08 : 0.05))
                    )
                }
                .padding(.bottom, 2)

                Divider()

                // Parameter rows grouped by category
                VStack(spacing: 3) {
                    // Section 1: Perspective & Display
                    sectionHeader(title: "PERSPECTIVE & DISPLAY", icon: "cube.transparent")

                    ForEach(TunableSetting.perspectiveSettings) { setting in
                        SettingRow(
                            setting: setting,
                            isSelected: state.selectedSettingIndex == setting.rawValue,
                            valueText: formattedValue(for: setting),
                            progress: progress(for: setting),
                            isDarkMode: isDarkMode
                        )
                    }

                    // Separation between groups
                    HStack(spacing: 8) {
                        Rectangle()
                            .fill(Color.primary.opacity(isDarkMode ? 0.14 : 0.08))
                            .frame(height: 1)
                    }
                    .padding(.vertical, 4)
                    .padding(.horizontal, 6)

                    // Section 2: Keyboard Reflection
                    sectionHeader(title: "KEYBOARD REFLECTION", icon: "keyboard")

                    ForEach(TunableSetting.keyboardSettings) { setting in
                        SettingRow(
                            setting: setting,
                            isSelected: state.selectedSettingIndex == setting.rawValue,
                            valueText: formattedValue(for: setting),
                            progress: progress(for: setting),
                            isDarkMode: isDarkMode
                        )
                    }
                }

                Divider()

                // Native Apple Keyboard Shortcut Keycaps Footer
                HStack(spacing: 12) {
                    KeycapHint(keys: ["↑", "↓"], label: "Select", isDarkMode: isDarkMode)
                    Spacer()
                    KeycapHint(keys: ["←", "→"], label: "Adjust", isDarkMode: isDarkMode)
                    Spacer()
                    KeycapHint(keys: ["F"], label: "Frosted", isDarkMode: isDarkMode)
                    Spacer()
                    KeycapHint(keys: ["K"], label: "Keyboard", isDarkMode: isDarkMode)
                    Spacer()
                    KeycapHint(keys: ["R"], label: "Reset", isDarkMode: isDarkMode)
                    Spacer()
                    KeycapHint(keys: ["C"], label: "Toggle", isDarkMode: isDarkMode)
                    Spacer()
                    KeycapHint(keys: ["ESC"], label: "Exit", isDarkMode: isDarkMode)
                }
                .padding(.horizontal, 4)
                .padding(.top, 2)
            }
            .padding(18)
            .frame(width: 550)
            .background(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(isDarkMode ? Color(red: 0.12, green: 0.13, blue: 0.15).opacity(0.88) : Color(red: 0.96, green: 0.97, blue: 0.98).opacity(0.92))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .stroke(
                        LinearGradient(
                            colors: isDarkMode
                                ? [Color.white.opacity(0.25), Color.white.opacity(0.06), Color.white.opacity(0.15)]
                                : [Color.white.opacity(0.85), Color.black.opacity(0.06), Color.black.opacity(0.14)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ),
                        lineWidth: 1
                    )
            )
            .shadow(
                color: Color.black.opacity(isDarkMode ? 0.40 : 0.16),
                radius: 20,
                x: 0,
                y: 8
            )
        }
    }

    // MARK: - Simulated MacBook Bezel & Frame Perimeter Blue Outline
    private var macbookBezelFrame: some View {
        let bezelWidth: CGFloat = 20
        let cornerRadius: CGFloat = 18

        return ZStack {
            // 1. Outermost Perimeter - Vibrant Blue Outline (Perimeter of the Frame)
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .strokeBorder(Color(red: 0.0, green: 0.52, blue: 1.0), lineWidth: 3.0)
                .padding(2)

            // Outer Electric Blue Glow along perimeter
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .stroke(Color(red: 0.0, green: 0.52, blue: 1.0).opacity(0.40), lineWidth: 2.0)
                .blur(radius: 4)
                .padding(2)

            // 2. Simulated MacBook Lid Bezel - Outer Anodized Aluminum Lip
            RoundedRectangle(cornerRadius: cornerRadius - 1, style: .continuous)
                .strokeBorder(
                    LinearGradient(
                        colors: isDarkMode ? [
                            Color(white: 0.28),
                            Color(white: 0.16),
                            Color(white: 0.12)
                        ] : [
                            Color(white: 0.82),
                            Color(white: 0.70),
                            Color(white: 0.60)
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    ),
                    lineWidth: 2.0
                )
                .padding(4)

            // 3. Simulated MacBook Matte Glass Bezel Band
            RoundedRectangle(cornerRadius: cornerRadius - 2, style: .continuous)
                .strokeBorder(
                    Color(red: 0.04, green: 0.04, blue: 0.05).opacity(isDarkMode ? 0.95 : 0.88),
                    lineWidth: bezelWidth
                )
                .padding(5)

            // 4. Inner Display Gasket / Active Screen Rim
            RoundedRectangle(cornerRadius: max(cornerRadius - 6, 8), style: .continuous)
                .stroke(
                    isDarkMode ? Color.white.opacity(0.18) : Color.black.opacity(0.15),
                    lineWidth: 1.0
                )
                .padding(5 + bezelWidth)

            // 5. MacBook Camera Notch at Top Center
            VStack {
                HStack {
                    Spacer()
                    ZStack {
                        // Notch Body (rounded bottom corners)
                        UnevenRoundedRectangle(
                            topLeadingRadius: 0,
                            bottomLeadingRadius: 10,
                            bottomTrailingRadius: 10,
                            topTrailingRadius: 0,
                            style: .continuous
                        )
                        .fill(Color(red: 0.04, green: 0.04, blue: 0.05))
                        .frame(width: 140, height: 26)

                        // Notch Border Rim
                        UnevenRoundedRectangle(
                            topLeadingRadius: 0,
                            bottomLeadingRadius: 10,
                            bottomTrailingRadius: 10,
                            topTrailingRadius: 0,
                            style: .continuous
                        )
                        .stroke(
                            isDarkMode ? Color.white.opacity(0.16) : Color.black.opacity(0.18),
                            lineWidth: 1.0
                        )
                        .frame(width: 140, height: 26)

                        // Camera & Sensors
                        HStack(spacing: 12) {
                            // Ambient light sensor
                            Circle()
                                .fill(Color.white.opacity(0.15))
                                .frame(width: 3.5, height: 3.5)

                            // FaceTime Camera Lens with anti-reflective AR coating
                            ZStack {
                                Circle()
                                    .fill(Color(red: 0.08, green: 0.08, blue: 0.12))
                                    .frame(width: 9, height: 9)
                                Circle()
                                    .stroke(Color(red: 0.20, green: 0.35, blue: 0.60).opacity(0.8), lineWidth: 1.0)
                                    .frame(width: 7, height: 7)
                                Circle()
                                    .fill(Color(red: 0.15, green: 0.40, blue: 0.70).opacity(0.6))
                                    .frame(width: 3, height: 3)
                            }

                            // Green status indicator LED
                            Circle()
                                .fill(Color(red: 0.20, green: 0.85, blue: 0.35).opacity(0.7))
                                .frame(width: 3.5, height: 3.5)
                        }
                    }
                    Spacer()
                }
                Spacer()
            }
            .padding(.top, 4)

            // 6. MacBook Pro Chin Monogram at Bottom Center
            VStack {
                Spacer()
                Text("MacBook Pro")
                    .font(.system(size: 8.5, weight: .semibold, design: .default))
                    .foregroundStyle(isDarkMode ? Color.white.opacity(0.25) : Color.black.opacity(0.20))
                    .tracking(1.5)
                    .padding(.bottom, 8)
            }
        }
    }

    private var calibrationSquares: some View {
        let padding: CGFloat = 28
        let squareSize: CGFloat = 46
        let lineInset = padding + squareSize / 2

        return ZStack {
            // Prominent, non-subtle alignment border guide connecting corners and edges
            // 1. Soft glowing backdrop stroke
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(
                    Color(red: 0.05, green: 0.58, blue: 1.0).opacity(0.40),
                    style: StrokeStyle(lineWidth: 4.5, lineCap: .round, dash: [10, 8])
                )
                .blur(radius: 2.0)
                .padding(lineInset)

            // 2. High-contrast, vivid dashed hairline
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(
                    Color(red: 0.05, green: 0.60, blue: 1.0).opacity(isDarkMode ? 0.95 : 0.85),
                    style: StrokeStyle(lineWidth: 2.0, lineCap: .round, dash: [10, 8])
                )
                .padding(lineInset)

            // 1. Top-Leading (Corner)
            CalibrationSquare(isDarkMode: isDarkMode, size: squareSize, label: "TL")
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .padding(padding)

            // 2. Top-Center (Edge)
            CalibrationSquare(isDarkMode: isDarkMode, size: squareSize, label: "TC")
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                .padding(.top, padding)

            // 3. Top-Trailing (Corner)
            CalibrationSquare(isDarkMode: isDarkMode, size: squareSize, label: "TR")
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                .padding(padding)

            // 4. Center-Leading (Edge)
            CalibrationSquare(isDarkMode: isDarkMode, size: squareSize, label: "CL")
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
                .padding(.leading, padding)

            // 5. Center-Trailing (Edge)
            CalibrationSquare(isDarkMode: isDarkMode, size: squareSize, label: "CR")
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .trailing)
                .padding(.trailing, padding)

            // 6. Bottom-Leading (Corner)
            CalibrationSquare(isDarkMode: isDarkMode, size: squareSize, label: "BL")
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
                .padding(padding)

            // 7. Bottom-Center (Edge)
            CalibrationSquare(isDarkMode: isDarkMode, size: squareSize, label: "BC")
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                .padding(.bottom, padding)

            // 8. Bottom-Trailing (Corner)
            CalibrationSquare(isDarkMode: isDarkMode, size: squareSize, label: "BR")
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                .padding(padding)
        }
    }

    private func sectionHeader(title: String, icon: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: icon)
                .font(.system(size: 9.5, weight: .semibold))
                .foregroundStyle(Color.accentColor)

            Text(title)
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(Color.secondary)
                .tracking(0.6)

            Spacer()
        }
        .padding(.horizontal, 8)
        .padding(.top, 3)
        .padding(.bottom, 1)
    }

    private func formattedValue(for setting: TunableSetting) -> String {
        switch setting {
        case .keystone: return String(format: "%.2f", state.keystoneStrength)
        case .stretch: return String(format: "%.2f", state.stretchBalance)
        case .lowAngleCompensation:
            return state.lowAngleCompensation <= 0.01 ? "Off" : String(format: "%.2f", state.lowAngleCompensation)
        case .lookahead: return String(format: "%.2fs", state.lookaheadTime)
        case .keyboardReflection:
            return state.isKeyboardReflectionEnabled ? String(format: "%.2f", state.keyboardReflection) : "Off"
        case .frostedGlass:
            return state.isFrostedGlassEnabled ? String(format: "%.2f", state.frostedGlass) : "Off"
        case .keyboardTilt: return String(format: "%.2f", state.keyboardTilt)
        case .keyboardReach: return String(format: "%.2f", state.keyboardReach)
        case .keyboardBacklight: return String(format: "%.2f", state.keyboardBacklight)
        case .keyboardOffset: return String(format: "%+.2f", state.keyboardOffset)
        case .keyboardWidth: return String(format: "%.2f", state.keyboardWidth)
        case .keyboardDepthBlur: return String(format: "%.2f", state.keyboardDepthBlur)
        case .blurIntensity:
            return state.blurIntensity <= 0.01 ? "Off" : String(format: "%.2f", state.blurIntensity)
        case .shadowIntensity:
            return state.shadowIntensity <= 0.01 ? "Off" : String(format: "%.2f", state.shadowIntensity)
        }
    }

    private func progress(for setting: TunableSetting) -> Double {
        switch setting {
        case .keystone: return Double(state.keystoneStrength / 1.0)
        case .stretch: return Double((state.stretchBalance - 0.01) / 1.49)
        case .lowAngleCompensation: return Double(state.lowAngleCompensation / 2.0)
        case .lookahead: return Double(state.lookaheadTime / 0.5)
        case .keyboardReflection:
            return state.isKeyboardReflectionEnabled ? Double(state.keyboardReflection / 1.0) : 0.0
        case .frostedGlass:
            return state.isFrostedGlassEnabled ? Double(state.frostedGlass / 1.0) : 0.0
        case .keyboardTilt: return Double((state.keyboardTilt - 0.15) / 1.85)
        case .keyboardReach: return Double((state.keyboardReach - 0.12) / 0.53)
        case .keyboardBacklight: return Double(state.keyboardBacklight / 2.5)
        case .keyboardOffset: return Double((state.keyboardOffset + 0.10) / 0.30)
        case .keyboardWidth: return Double((state.keyboardWidth - 0.60) / 0.40)
        case .keyboardDepthBlur: return Double(state.keyboardDepthBlur / 3.0)
        case .blurIntensity: return Double(state.blurIntensity / 2.0)
        case .shadowIntensity: return Double(state.shadowIntensity / 2.0)
        }
    }
}

// MARK: - Liquid Glass Slider
private struct LiquidGlassSlider: View {
    let progress: Double
    let isSelected: Bool
    let isDarkMode: Bool

    // Slider metrics
    private let trackHeight: CGFloat = 6.0
    private let thumbWidth: CGFloat = 26.0
    private let thumbHeight: CGFloat = 17.0

    var body: some View {
        GeometryReader { geo in
            let totalWidth = geo.size.width
            let clampedProgress = min(max(CGFloat(progress), 0.0), 1.0)
            // Center of thumb travels from thumbWidth / 2 to totalWidth - thumbWidth / 2
            let travelDistance = max(0, totalWidth - thumbWidth)
            let thumbX = (thumbWidth / 2.0) + clampedProgress * travelDistance
            let thumbLeft = thumbX - (thumbWidth / 2.0)

            ZStack(alignment: .leading) {
                // 1. Inactive Track (Full Width)
                Capsule()
                    .fill(isDarkMode ? Color(white: 0.24).opacity(0.7) : Color(white: 0.88))
                    .frame(height: trackHeight)
                    .overlay(
                        Capsule()
                            .stroke(
                                isDarkMode ? Color.white.opacity(0.12) : Color.black.opacity(0.06),
                                lineWidth: 0.5
                            )
                    )

                // 2. Active Track (Leading edge up to thumb's entry point)
                if clampedProgress > 0.001 {
                    let activeWidth = max(0, min(thumbLeft + (isSelected ? 3.0 : thumbWidth / 2.0), totalWidth))
                    if activeWidth > 0 {
                        Capsule()
                            .fill(
                                LinearGradient(
                                    colors: isSelected ? [
                                        Color(red: 0.08, green: 0.52, blue: 1.0),
                                        Color(red: 0.00, green: 0.44, blue: 0.92)
                                    ] : [
                                        Color.primary.opacity(isDarkMode ? 0.38 : 0.28),
                                        Color.primary.opacity(isDarkMode ? 0.32 : 0.22)
                                    ],
                                    startPoint: .top,
                                    endPoint: .bottom
                                )
                            )
                            .frame(width: activeWidth, height: trackHeight)
                            .overlay(
                                // Subtle top highlight sheen along active track
                                Capsule()
                                    .fill(
                                        LinearGradient(
                                            colors: [Color.white.opacity(isSelected ? 0.35 : 0.15), Color.clear],
                                            startPoint: .top,
                                            endPoint: .bottom
                                        )
                                    )
                                    .frame(width: activeWidth, height: trackHeight * 0.45)
                                    .offset(y: -trackHeight * 0.25)
                            )
                    }
                }

                // 3. Thumb (Solid White when unselected, Liquid Glass when selected)
                LiquidGlassThumb(
                    thumbWidth: thumbWidth,
                    thumbHeight: thumbHeight,
                    trackHeight: trackHeight,
                    hasFluid: clampedProgress > 0.001,
                    isSelected: isSelected,
                    isDarkMode: isDarkMode
                )
                .offset(x: thumbLeft, y: (geo.size.height - thumbHeight) / 2.0)
            }
            .frame(maxHeight: .infinity, alignment: .center)
        }
        .frame(height: 20)
    }
}

// MARK: - Liquid Glass Thumb
private struct LiquidGlassThumb: View {
    let thumbWidth: CGFloat
    let thumbHeight: CGFloat
    let trackHeight: CGFloat
    let hasFluid: Bool
    let isSelected: Bool
    let isDarkMode: Bool

    var body: some View {
        Group {
            if isSelected {
                // Activated Liquid Glass State
                ZStack {
                    // 1. Dual-layer realistic drop shadows
                    Capsule()
                        .fill(Color.clear)
                        .shadow(
                            color: Color.black.opacity(isDarkMode ? 0.55 : 0.20),
                            radius: 4.5,
                            x: 0,
                            y: 2.5
                        )
                        .shadow(
                            color: Color.black.opacity(isDarkMode ? 0.35 : 0.10),
                            radius: 1.5,
                            x: 0,
                            y: 1.0
                        )

                    // 2. Translucent glass substrate (rear wall of the lens)
                    Capsule()
                        .fill(
                            LinearGradient(
                                colors: isDarkMode ? [
                                    Color.white.opacity(0.32),
                                    Color.white.opacity(0.08),
                                    Color.white.opacity(0.18)
                                ] : [
                                    Color.white.opacity(0.85),
                                    Color.white.opacity(0.40),
                                    Color.white.opacity(0.60)
                                ],
                                startPoint: .top,
                                endPoint: .bottom
                            )
                        )

                    // 3. Inactive track passing through the right half of the glass lens
                    Capsule()
                        .fill(isDarkMode ? Color(white: 0.28).opacity(0.5) : Color(white: 0.85).opacity(0.8))
                        .frame(width: thumbWidth * 0.55, height: trackHeight)
                        .offset(x: thumbWidth * 0.22)
                        .clipShape(Capsule())

                    // 4. Liquid blue meniscus & internal tongue (refracted inside glass)
                    if hasFluid {
                        LiquidMeniscusShape()
                            .fill(
                                LinearGradient(
                                    colors: [
                                        Color(red: 0.08, green: 0.52, blue: 1.0),
                                        Color(red: 0.00, green: 0.44, blue: 0.92)
                                    ],
                                    startPoint: .top,
                                    endPoint: .bottom
                                )
                            )
                            .clipShape(Capsule())
                    }

                    // 5. Glass body translucency & volumetric refraction
                    Capsule()
                        .fill(
                            LinearGradient(
                                stops: [
                                    .init(color: Color.white.opacity(isDarkMode ? 0.30 : 0.45), location: 0.0),
                                    .init(color: Color.white.opacity(isDarkMode ? 0.05 : 0.12), location: 0.40),
                                    .init(color: Color.white.opacity(isDarkMode ? 0.12 : 0.25), location: 1.0)
                                ],
                                startPoint: .top,
                                endPoint: .bottom
                            )
                        )

                    // 6. Top Specular Glare (Signature Apple liquid glass highlight)
                    Capsule()
                        .fill(
                            LinearGradient(
                                stops: [
                                    .init(color: Color.white.opacity(isDarkMode ? 0.90 : 0.98), location: 0.0),
                                    .init(color: Color.white.opacity(isDarkMode ? 0.45 : 0.60), location: 0.45),
                                    .init(color: Color.white.opacity(0.0), location: 1.0)
                                ],
                                startPoint: .top,
                                endPoint: .bottom
                            )
                        )
                        .frame(width: thumbWidth - 3.5, height: thumbHeight * 0.48)
                        .offset(y: -thumbHeight * 0.22)

                    // 7. Hotspot specular gleam near top-center
                    Ellipse()
                        .fill(Color.white.opacity(isDarkMode ? 0.80 : 0.95))
                        .frame(width: 7.0, height: 2.8)
                        .offset(x: -1.0, y: -thumbHeight * 0.32)
                        .blur(radius: 0.4)

                    // 8. Bottom ground-bounce rim reflection
                    Capsule()
                        .fill(
                            LinearGradient(
                                colors: [
                                    Color.clear,
                                    Color.white.opacity(isDarkMode ? 0.18 : 0.35)
                                ],
                                startPoint: .top,
                                endPoint: .bottom
                            )
                        )
                        .frame(width: thumbWidth - 4.0, height: thumbHeight * 0.28)
                        .offset(y: thumbHeight * 0.32)

                    // 9. Inner glass refraction border (glass thickness simulation)
                    Capsule()
                        .strokeBorder(
                            LinearGradient(
                                stops: [
                                    .init(color: Color.white.opacity(isDarkMode ? 0.30 : 0.50), location: 0.0),
                                    .init(color: Color.clear, location: 0.45),
                                    .init(color: Color.white.opacity(isDarkMode ? 0.12 : 0.25), location: 1.0)
                                ],
                                startPoint: .top,
                                endPoint: .bottom
                            ),
                            lineWidth: 0.6
                        )
                        .padding(1.0)

                    // 10. Outer Beveled Rim Stroke (Illuminated top, dark bottom)
                    Capsule()
                        .strokeBorder(
                            LinearGradient(
                                stops: [
                                    .init(color: Color.white.opacity(isDarkMode ? 0.85 : 0.98), location: 0.0),
                                    .init(color: Color.white.opacity(isDarkMode ? 0.28 : 0.45), location: 0.45),
                                    .init(color: isDarkMode ? Color.black.opacity(0.40) : Color.black.opacity(0.12), location: 1.0)
                                ],
                                startPoint: .top,
                                endPoint: .bottom
                            ),
                            lineWidth: 1.0
                        )

                    // 11. Selection pulse / glow
                    Capsule()
                        .stroke(Color.accentColor.opacity(isDarkMode ? 0.35 : 0.25), lineWidth: 1.5)
                        .blur(radius: 1.0)
                }
            } else {
                // Inactive State: Solid White Capsule
                ZStack {
                    // Soft drop shadow
                    Capsule()
                        .fill(Color.clear)
                        .shadow(
                            color: Color.black.opacity(isDarkMode ? 0.40 : 0.16),
                            radius: 3.5,
                            x: 0,
                            y: 1.5
                        )
                        .shadow(
                            color: Color.black.opacity(isDarkMode ? 0.25 : 0.08),
                            radius: 1.0,
                            x: 0,
                            y: 0.5
                        )

                    // Solid white capsule body
                    Capsule()
                        .fill(Color.white)

                    // Subtle rim stroke for crisp definition
                    Capsule()
                        .strokeBorder(
                            LinearGradient(
                                stops: [
                                    .init(color: Color.white, location: 0.0),
                                    .init(color: Color.black.opacity(isDarkMode ? 0.20 : 0.08), location: 1.0)
                                ],
                                startPoint: .top,
                                endPoint: .bottom
                            ),
                            lineWidth: 0.6
                        )
                }
            }
        }
        .frame(width: thumbWidth, height: thumbHeight)
    }
}

// MARK: - Liquid Meniscus Shape
private struct LiquidMeniscusShape: Shape {
    func path(in rect: CGRect) -> Path {
        var p = Path()
        let w = rect.width
        let h = rect.height
        let midY = h / 2.0
        let trackHalf: CGFloat = 3.0
        let topTrack = midY - trackHalf
        let botTrack = midY + trackHalf

        // Semicircular cap center on the horizontal tongue
        let capCenterX = min(w * 0.52, w - 8.0)

        // Path starts outside the left boundary to be seamlessly clipped to the capsule rim
        p.move(to: CGPoint(x: -2.0, y: 1.5))
        // Smoothly neck from the outer rim into the top edge of the track
        p.addCurve(
            to: CGPoint(x: 5.5, y: topTrack),
            control1: CGPoint(x: 0.5, y: 2.5),
            control2: CGPoint(x: 3.5, y: topTrack)
        )
        // Straight top edge of the fluid tongue
        p.addLine(to: CGPoint(x: capCenterX, y: topTrack))
        // Rounded end cap
        p.addArc(
            center: CGPoint(x: capCenterX, y: midY),
            radius: trackHalf,
            startAngle: Angle(degrees: -90),
            endAngle: Angle(degrees: 90),
            clockwise: false
        )
        // Straight bottom edge of the fluid tongue
        p.addLine(to: CGPoint(x: 5.5, y: botTrack))
        // Smoothly flare from bottom edge of the track out to the outer rim
        p.addCurve(
            to: CGPoint(x: -2.0, y: h - 1.5),
            control1: CGPoint(x: 3.5, y: botTrack),
            control2: CGPoint(x: 0.5, y: h - 2.5)
        )
        p.addLine(to: CGPoint(x: -2.0, y: 1.5))
        p.closeSubpath()
        return p
    }
}

private struct SettingRow: View {
    let setting: TunableSetting
    let isSelected: Bool
    let valueText: String
    let progress: Double
    let isDarkMode: Bool

    var body: some View {
        HStack(spacing: 10) {
            // Selection chevron
            Image(systemName: "chevron.right")
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(isSelected ? Color.accentColor : Color.clear)
                .frame(width: 10)

            // Parameter name
            Text(setting.title)
                .font(.system(size: 12, weight: isSelected ? .semibold : .medium))
                .foregroundStyle(isSelected ? Color.primary : Color.primary.opacity(0.85))
                .frame(width: 160, alignment: .leading)

            // Progress bar
            LiquidGlassSlider(
                progress: progress,
                isSelected: isSelected,
                isDarkMode: isDarkMode
            )

            // Value readout (monospaced digits for alignment, Apple system font)
            Text(valueText)
                .font(.system(size: 12, weight: isSelected ? .semibold : .regular).monospacedDigit())
                .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)
                .frame(width: 58, alignment: .trailing)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(isSelected ? Color.accentColor.opacity(isDarkMode ? 0.20 : 0.12) : Color.clear)
        )
    }
}

// MARK: - Native Apple Keycap Hint
private struct KeycapHint: View {
    let keys: [String]
    let label: String
    let isDarkMode: Bool

    var body: some View {
        HStack(spacing: 5) {
            HStack(spacing: 2) {
                ForEach(keys, id: \.self) { key in
                    Text(key)
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(Color.primary.opacity(0.9))
                        .padding(.horizontal, 4)
                        .padding(.vertical, 2)
                        .background(
                            RoundedRectangle(cornerRadius: 4, style: .continuous)
                                .fill(isDarkMode ? Color.white.opacity(0.12) : Color.black.opacity(0.08))
                        )
                }
            }
            Text(label)
                .font(.system(size: 10, weight: .regular))
                .foregroundStyle(Color.secondary)
        }
    }
}
// MARK: - Calibration Square
private struct CalibrationSquare: View {
    let isDarkMode: Bool
    var size: CGFloat = 46
    var label: String? = nil

    var body: some View {
        ZStack {
            // Background plate
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(isDarkMode ? Color(red: 0.13, green: 0.13, blue: 0.14).opacity(0.88) : Color(red: 0.97, green: 0.97, blue: 0.98).opacity(0.92))

            // Outer border
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(isDarkMode ? Color.white.opacity(0.25) : Color.black.opacity(0.20), lineWidth: 1)

            // Concentric inner calibration square
            RoundedRectangle(cornerRadius: 3, style: .continuous)
                .stroke(Color.accentColor.opacity(0.75), lineWidth: 1)
                .frame(width: size * 0.44, height: size * 0.44)

            // Precision crosshair lines
            Rectangle()
                .fill(Color.accentColor.opacity(0.60))
                .frame(width: size * 0.72, height: 1)

            Rectangle()
                .fill(Color.accentColor.opacity(0.60))
                .frame(width: 1, height: size * 0.72)

            // Center fiducial pin
            Circle()
                .fill(Color.accentColor)
                .frame(width: 4, height: 4)

            // Subtle label badge
            if let label = label {
                Text(label)
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(Color.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                    .padding(3)
            }
        }
        .frame(width: size, height: size)
        .shadow(color: Color.black.opacity(isDarkMode ? 0.35 : 0.12), radius: 8, x: 0, y: 3)
    }
}

