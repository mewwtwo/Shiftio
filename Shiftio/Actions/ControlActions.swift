import AppKit
import CoreWLAN
import CoreBluetooth
import IOBluetooth
import UniformTypeIdentifiers

/// A tile of the ⌘⇧ ring (Wi-Fi, Keyboard light…) or one of its options. A tile has `children`: choosing it
/// opens a second ring with them, like Control Center expanding a tile. Options are leaves that do something.
/// None of these take files.
struct ControlAction: FileAction {
    static let backID = "sys-back"

    let id: String
    let title: String
    let symbol: String?
    /// Tiles that need hardware this Mac doesn't have (keyboard backlight…) hide themselves.
    var isAvailable: @Sendable () -> Bool = { true }
    var stateProvider: @Sendable () -> Bool? = { nil }
    var symbolProvider: (@Sendable (Bool?) -> String?)?
    /// A picture instead of a symbol (an app's own icon).
    var image: NSImage?
    var childrenProvider: @Sendable () -> [ControlAction] = { [] }
    var performer: @Sendable () async throws -> Void = {}

    init(id: String, title: String, symbol: String?, isAvailable: @escaping @Sendable () -> Bool = { true },
         stateProvider: @escaping @Sendable () -> Bool? = { nil }, symbolProvider: (@Sendable (Bool?) -> String?)? = nil,
         childrenProvider: @escaping @Sendable () -> [ControlAction] = { [] },
         performer: @escaping @Sendable () async throws -> Void = {}) {
        self.id = id
        self.title = title
        self.symbol = symbol
        self.isAvailable = isAvailable
        self.stateProvider = stateProvider
        self.symbolProvider = symbolProvider
        self.childrenProvider = childrenProvider
        self.performer = performer
    }

    var inputTypes: [UTType] { [] }   // never offered for files
    var children: [ControlAction] { childrenProvider() }
    /// Tiles that list apps are only useful when there are some.
    var hasChildren: Bool { !childrenProvider().isEmpty }

    func state() -> Bool? { stateProvider() }
    func displaySymbol(isOn: Bool?) -> String? { symbolProvider?(isOn) ?? symbol }

    func run(_ urls: [URL], options: ActionOptions) async throws -> [URL] {
        try await performer()
        return []
    }
}

// MARK: Catalog

extension ControlAction {
    static let tiles: [ControlAction] = [wifi, bluetooth, appearance, keyboard, folders, keepAwake, systemSettings,
                                         suggestedApps, pinnedApps, screenshot, record]

    private static func option(_ id: String, _ title: String, _ symbol: String?, current: Bool? = nil,
                               _ perform: @escaping @Sendable () async throws -> Void) -> ControlAction {
        ControlAction(id: id, title: title, symbol: symbol, stateProvider: { current }, performer: perform)
    }

    /// Opens the matching pane of System Settings.
    private static func settings(_ pane: String) -> ControlAction {
        option("sys-settings-\(pane)", String(localized: "Settings"), "gearshape") {
            await MainActor.run { _ = NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:\(pane)")!) }
        }
    }

    private static var wifi: ControlAction {
        ControlAction(
            id: "sys-wifi", title: String(localized: "Wi-Fi"), symbol: "wifi",
            stateProvider: { CWWiFiClient.shared().interface()?.powerOn() },
            symbolProvider: { $0 == false ? "wifi.slash" : "wifi" },
            childrenProvider: {
                let on = CWWiFiClient.shared().interface()?.powerOn()
                return recentNetworks() + [
                    option("wifi-on", String(localized: "Turn On"), "wifi", current: on == true) { try setWiFi(true) },
                    option("wifi-off", String(localized: "Turn Off"), "wifi.slash", current: on == false) { try setWiFi(false) },
                    settings("com.apple.wifi-settings-extension"),
                ]
            })
    }

    /// Known networks, most recently preferred first; choosing one joins it (the password comes from the keychain).
    private static func recentNetworks() -> [ControlAction] {
        guard let interface = CWWiFiClient.shared().interface(), interface.powerOn(),
              let profiles = interface.configuration()?.networkProfiles.array as? [CWNetworkProfile] else { return [] }
        let current = interface.ssid()
        return profiles.compactMap(\.ssid).filter { $0 != current }.prefix(3).map { ssid in
            option("wifi-join-" + ssid, ssid, "wifi") {
                guard let interface = CWWiFiClient.shared().interface(),
                      let network = try interface.scanForNetworks(withSSID: Data(ssid.utf8)).first
                else { throw ShiftioError.unavailable(ssid) }
                try interface.associate(to: network, password: nil)
            }
        }
    }

    /// Recently connected Bluetooth devices; choosing one connects it.
    private static func recentBluetoothDevices() -> [ControlAction] {
        let devices = Bluetooth.knownDevices().map { device in
            option("bt-connect-" + device.address, device.name, "headphones") { Bluetooth.connect(address: device.address) }
        }
        // Without access there is nothing to read; choosing this asks for it once.
        guard !Bluetooth.isAllowed else { return devices }
        return [option("bt-allow", String(localized: "Show Recent"), "clock") { Bluetooth.requestAccess() }]
    }

    private static func setWiFi(_ on: Bool) throws {
        guard let interface = CWWiFiClient.shared().interface() else { throw ShiftioError.unavailable("Wi-Fi") }
        try interface.setPower(on)
    }

    private static var bluetooth: ControlAction {
        ControlAction(
            id: "sys-bluetooth", title: String(localized: "Bluetooth"), symbol: "dot.radiowaves.left.and.right",
            stateProvider: { Bluetooth.isOn },
            childrenProvider: {
                let on = Bluetooth.isOn
                return recentBluetoothDevices() + [
                    option("bt-on", String(localized: "Turn On"), "dot.radiowaves.left.and.right", current: on == true) { try Bluetooth.set(true) },
                    option("bt-off", String(localized: "Turn Off"), "nosign", current: on == false) { try Bluetooth.set(false) },
                    settings("com.apple.BluetoothSettings"),
                ]
            })
    }

    private static var isDark: Bool { UserDefaults.standard.string(forKey: "AppleInterfaceStyle") == "Dark" }
    private static let autoKey = "AppleInterfaceStyleSwitchesAutomatically"
    private static var isAuto: Bool { UserDefaults(suiteName: ".GlobalPreferences")?.bool(forKey: autoKey) ?? false }

    /// Light or Dark turn "Auto" off first, so the choice sticks.
    private static func setDark(_ dark: Bool) async throws {
        if isAuto { try await setAuto(false) }
        try await Shell.runAsync("/usr/bin/osascript", ["-e",
            "tell application \"System Events\" to tell appearance preferences to set dark mode to \(dark)"])
    }

    /// Auto follows the schedule (dark at night). It is the same switch as System Settings → Appearance → Auto.
    private static func setAuto(_ on: Bool) async throws {
        try await Shell.runAsync("/usr/bin/defaults", ["write", "-g", autoKey, "-bool", on ? "true" : "false"])
        // Ask the system to re-evaluate right away.
        DistributedNotificationCenter.default().postNotificationName(
            Notification.Name("AppleInterfaceThemeChangedNotification"), object: nil, userInfo: nil, deliverImmediately: true)
    }

    private static var appearance: ControlAction {
        ControlAction(
            id: "sys-appearance", title: String(localized: "Appearance"), symbol: "circle.lefthalf.filled",
            stateProvider: { isDark },
            childrenProvider: {
                let auto = isAuto
                return [
                    option("appearance-auto", String(localized: "Auto"), "circle.lefthalf.striped.horizontal", current: auto) { try await setAuto(true) },
                    option("appearance-light", String(localized: "Light"), "sun.max", current: !auto && !isDark) { try await setDark(false) },
                    option("appearance-dark", String(localized: "Dark"), "moon", current: !auto && isDark) { try await setDark(true) },
                    settings("com.apple.Appearance-Settings.extension"),
                ]
            })
    }

    private static var keyboard: ControlAction {
        ControlAction(
            id: "sys-keyboard", title: String(localized: "Keyboard"), symbol: "light.max",
            isAvailable: { KeyboardBacklight.keyboardID != nil },
            stateProvider: { KeyboardBacklight.level.map { $0 > 0.02 } },
            childrenProvider: {
                let level = KeyboardBacklight.level ?? 0
                let steps: [(String, String, Float)] = [(String(localized: "Off"), "light.min", 0), (String(localized: "Low"), "light.min", 0.25),
                                                        (String(localized: "Medium"), "light.max", 0.5), (String(localized: "High"), "light.max", 1)]
                let nearest = steps.min { abs($0.2 - level) < abs($1.2 - level) }?.2
                return steps.map { name, symbol, value in
                    option("kbd-\(name)", name, symbol, current: value == nearest) { try KeyboardBacklight.set(value) }
                } + [settings("com.apple.Keyboard-Settings.extension")]
            })
    }

    /// The user's pinned folders (Settings → Rings → Pop-up); choosing one opens it in Finder.
    private static var folders: ControlAction {
        ControlAction(
            id: "sys-folders", title: String(localized: "Folders"), symbol: "folder",
            childrenProvider: {
                let pins = MainActor.assumeIsolated { FolderPins.shared.items }
                return pins.compactMap { folder -> ControlAction? in
                    if let url = folder.url, !FileManager.default.fileExists(atPath: url.path) { return nil }
                    var option = ControlAction(id: "folder-" + folder.id, title: folder.title,
                                               symbol: folder.isRecents ? "clock" : "folder", performer: {
                        await MainActor.run { FolderPins.open(folder) }
                    })
                    option.image = folder.url == nil ? nil : FolderIcon.baseIcon(for: folder)
                    return option
                }
            })
    }

    /// One option per app; choosing it opens (or switches to) that app.
    private static func appOptions(_ bundleIDs: [String]) -> [ControlAction] {
        bundleIDs.compactMap { id -> ControlAction? in
            guard let app = ActionRegistry.action("app:" + id) as? AppAction, app.url != nil else { return nil }
            var option = ControlAction(id: "open-" + id, title: app.title, symbol: "app", performer: {
                _ = try await app.run([], options: ActionOptions())
            })
            option.image = app.icon
            return option
        }
    }

    /// Recent and most-used apps in one tile; Settings chooses which, and how many.
    private static var suggestedApps: ControlAction {
        ControlAction(id: "sys-suggestedapps", title: String(localized: "Recent"), symbol: "clock.arrow.circlepath",
                      childrenProvider: { appOptions(MainActor.assumeIsolated { SuggestedAppsMode.apps() }) })
    }

    /// The apps the user pinned in Settings.
    private static var pinnedApps: ControlAction {
        ControlAction(id: "sys-apps", title: String(localized: "Apps"), symbol: "square.grid.2x2",
                      childrenProvider: { appOptions(MainActor.assumeIsolated { AppPins.shared.ids }) + telegramOptions() })
    }

    /// One option per pinned Telegram chat; choosing it opens that conversation.
    private static func telegramOptions() -> [ControlAction] {
        let chats = MainActor.assumeIsolated { TelegramChats.shared.items }
        return chats.compactMap { chat -> ControlAction? in
            guard let url = chat.url else { return nil }
            var option = ControlAction(id: "telegram-" + chat.id.uuidString, title: chat.title, symbol: "paperplane.fill", performer: {
                await MainActor.run { _ = NSWorkspace.shared.open(url) }
            })
            option.image = MainActor.assumeIsolated { TelegramChats.shared.image(for: chat) }
            return option
        }
    }

    private static var keepAwake: ControlAction {
        ControlAction(
            id: "sys-keepawake", title: String(localized: "Keep Awake"), symbol: "cup.and.saucer",
            stateProvider: { KeepAwake.isActive },
            childrenProvider: {
                let active = KeepAwake.isActive
                return [
                    option("awake-15", String(localized: "15 Minutes"), "timer") { try KeepAwake.start(seconds: 15 * 60) },
                    option("awake-60", String(localized: "1 Hour"), "timer") { try KeepAwake.start(seconds: 3600) },
                    option("awake-240", String(localized: "4 Hours"), "timer") { try KeepAwake.start(seconds: 4 * 3600) },
                    option("awake-forever", String(localized: "Until Off"), "infinity") { try KeepAwake.start(seconds: nil) },
                    option("awake-stop", String(localized: "Allow Sleep"), "moon.zzz", current: !active) { KeepAwake.stop() },
                ]
            })
    }

    /// Screenshots like ⌘⇧3/4, saved where the system saves them and opened in Quick Look.
    private static var screenshot: ControlAction {
        ControlAction(id: "sys-screenshot", title: String(localized: "Screenshot"), symbol: "camera.viewfinder", childrenProvider: { [
            option("shot-selection", String(localized: "Selection"), "viewfinder") { await ScreenCapture.shared.screenshot(.selection) },
            option("shot-window", String(localized: "Window"), "macwindow") { await ScreenCapture.shared.screenshot(.window) },
            option("shot-screen", String(localized: "Screen"), "display") { await ScreenCapture.shared.screenshot(.screen) },
        ] })
    }

    /// Screen recording; stopping it opens the movie in Quick Look.
    private static var record: ControlAction {
        ControlAction(
            id: "sys-record", title: String(localized: "Record Video"), symbol: "record.circle",
            stateProvider: { ScreenCapture.shared.isRecording },
            symbolProvider: { $0 == true ? "stop.circle.fill" : "record.circle" },
            childrenProvider: {
                if ScreenCapture.shared.isRecording {
                    return [option("record-stop", String(localized: "Stop"), "stop.circle.fill") { await ScreenCapture.shared.stopRecording() }]
                }
                return [
                    option("record-screen", String(localized: "Screen"), "display") { await ScreenCapture.shared.startRecording() },
                    option("record-toolbar", String(localized: "Area…"), "rectangle.dashed.badge.record") {
                        await MainActor.run { _ = NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/Utilities/Screenshot.app")) }
                    },
                ]
            })
    }

    /// Opens System Settings itself.
    private static var systemSettings: ControlAction {
        ControlAction(id: "sys-settings", title: String(localized: "System Settings"), symbol: "gearshape", performer: {
            await MainActor.run { _ = NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/System Settings.app")) }
        })
    }
}

// MARK: Keep awake (public API: the caffeinate tool)

extension Notification.Name {
    static let keepAwakeChanged = Notification.Name("ShiftioKeepAwakeChanged")
}

enum KeepAwake {
    nonisolated(unsafe) private static var process: Process?
    nonisolated(unsafe) private(set) static var endsAt: Date?

    static var isActive: Bool { process?.isRunning == true }

    static func start(seconds: Int?) throws {
        stop()
        let caffeinate = Process()
        caffeinate.executableURL = URL(fileURLWithPath: "/usr/bin/caffeinate")
        // -w ties it to Shiftio: quitting the app lets the Mac sleep again.
        var arguments = ["-d", "-i", "-w", String(ProcessInfo.processInfo.processIdentifier)]
        if let seconds { arguments += ["-t", String(seconds)] }
        caffeinate.arguments = arguments
        // A timed session ends by itself; the menu needs to hear about that too.
        caffeinate.terminationHandler = { finished in
            DispatchQueue.main.async {
                guard process === finished else { return }
                process = nil
                endsAt = nil
                NotificationCenter.default.post(name: .keepAwakeChanged, object: nil)
            }
        }
        try caffeinate.run()
        process = caffeinate
        endsAt = seconds.map { Date.now.addingTimeInterval(TimeInterval($0)) }
        NotificationCenter.default.post(name: .keepAwakeChanged, object: nil)
    }

    static func stop() {
        let running = process
        process = nil
        endsAt = nil
        running?.terminate()
        NotificationCenter.default.post(name: .keepAwakeChanged, object: nil)
    }
}

// MARK: Undocumented system calls (loaded at run time, so a missing one degrades to "unavailable")

private enum CoreBrightness {
    static let loaded: Void = { dlopen("/System/Library/PrivateFrameworks/CoreBrightness.framework/CoreBrightness", RTLD_LAZY); }()

    static func client(_ name: String) -> NSObject? {
        _ = loaded
        return (NSClassFromString(name) as? NSObject.Type)?.init()
    }
}

enum KeyboardBacklight {
    nonisolated(unsafe) private static let client = CoreBrightness.client("KeyboardBrightnessClient")

    static var keyboardID: UInt64? {
        guard let client,
              let ids = client.perform(Selector(("copyKeyboardBacklightIDs")))?.takeRetainedValue() as? [NSNumber]
        else { return nil }
        return ids.first?.uint64Value
    }

    static var level: Float? {
        guard let client, let id = keyboardID else { return nil }
        typealias Get = @convention(c) (AnyObject, Selector, UInt64) -> Float
        let selector = Selector(("brightnessForKeyboard:"))
        guard let imp = client.method(for: selector) else { return nil }
        return unsafeBitCast(imp, to: Get.self)(client, selector, id)
    }

    static func set(_ level: Float) throws {
        guard let client, let id = keyboardID else { throw ShiftioError.unavailable(String(localized: "Keyboard backlight")) }
        typealias Set = @convention(c) (AnyObject, Selector, Float, UInt64) -> Bool
        let selector = Selector(("setBrightness:forKeyboard:"))
        guard let imp = client.method(for: selector),
              unsafeBitCast(imp, to: Set.self)(client, selector, min(1, max(0, level)), id)
        else { throw ShiftioError.unavailable(String(localized: "Keyboard backlight")) }
    }
}

enum Bluetooth {
    private typealias GetFunction = @convention(c) () -> Int32
    private typealias SetFunction = @convention(c) (Int32) -> Void

    nonisolated(unsafe) private static let handle = dlopen("/System/Library/Frameworks/IOBluetooth.framework/IOBluetooth", RTLD_LAZY)
    private static let usedKey = "bluetoothAccessRequested"

    /// Any Bluetooth call makes macOS ask for Bluetooth access (and ends the app if the Info.plist doesn't explain
    /// why). So the tile shows no state until the user has used Bluetooth here once; merely opening the ring
    /// must never raise a permission dialog.
    static var isOn: Bool? {
        guard isAllowed,
              let handle, let symbol = dlsym(handle, "IOBluetoothPreferenceGetControllerPowerState")
        else { return nil }
        return unsafeBitCast(symbol, to: GetFunction.self)() != 0
    }

    /// Bluetooth access has been granted (or Shiftio has used it before and macOS has since answered), so reading it raises no
    /// dialog. While macOS has not been asked yet, the "used before" flag is not trusted: reading would raise the question.
    static var isAllowed: Bool {
        let status = CBManager.authorization
        return status == .allowedAlways || (UserDefaults.standard.bool(forKey: usedKey) && status != .notDetermined)
    }

    /// Recently used devices first, then every other paired one; empty until Bluetooth access is allowed.
    static func knownDevices() -> [(name: String, address: String)] {
        guard isOn == true else { return [] }
        let recent = IOBluetoothDevice.recentDevices(0) as? [IOBluetoothDevice] ?? []
        let paired = IOBluetoothDevice.pairedDevices() as? [IOBluetoothDevice] ?? []
        var seen = Set<String>()
        return (recent + paired).compactMap { device in
            // Only audio gear, controllers, keyboards and wearables. Phones and computers are paired for calls and
            // tethering, and they report class 0 or "phone", so they are not something to switch to here.
            guard [kBluetoothDeviceClassMajorAudio, kBluetoothDeviceClassMajorPeripheral, kBluetoothDeviceClassMajorWearable,
                   kBluetoothDeviceClassMajorToy].contains(Int(device.deviceClassMajor)),
                  let address = device.addressString, seen.insert(address).inserted else { return nil }
            return (device.name ?? address, address)
        }
    }

    static func requestAccess() {
        UserDefaults.standard.set(true, forKey: usedKey)
        _ = knownDevices()
    }

    static func connect(address: String) {
        guard let device = IOBluetoothDevice(addressString: address) else { return }
        if device.isConnected() { device.closeConnection() } else { device.openConnection() }
    }

    static func set(_ on: Bool) throws {
        UserDefaults.standard.set(true, forKey: usedKey)
        guard let handle, let symbol = dlsym(handle, "IOBluetoothPreferenceSetControllerPowerState")
        else { throw ShiftioError.unavailable(String(localized: "Bluetooth")) }
        unsafeBitCast(symbol, to: SetFunction.self)(on ? 1 : 0)
    }
}
