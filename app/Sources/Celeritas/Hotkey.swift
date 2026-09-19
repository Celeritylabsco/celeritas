import Carbon.HIToolbox
import CeleritasKit
import Foundation

/// A system-wide chord. Carbon is a deliberate capability gap rather than
/// inertia: nothing modern registers a global hotkey, and `RegisterEventHotKey`
/// remains the public mechanism.
@MainActor
final class Hotkey {
    /// Control-Option-Space, spelled here so the call site does not need Carbon.
    ///
    /// Space because that is what every launcher trains people to press. Control
    /// on top of it because Option-Space is Raycast's and Alfred's default and
    /// also types a non-breaking space, and Command-Space is Spotlight's.
    ///
    /// Registration succeeding does not prove a chord is usable: macOS handles
    /// some of its own shortcuts before Carbon hotkeys are consulted, so
    /// Command-Space registers happily and then never fires.
    static let `default` = (key: UInt32(kVK_Space), modifiers: UInt32(controlKey | optionKey))

    /// Written out. The symbols for control, option and command look alike to
    /// anyone who has not had to learn them, and getting it wrong means the app
    /// appears not to work at all.
    static let defaultSpelled = "Control + Option + Space"
    static let defaultSymbols = "⌃⌥Space"

    /// The chord in force: whatever was recorded, or the built in one.
    static var current: Chord {
        Settings.hotkey ?? Chord(keyCode: Hotkey.default.key,
                                 modifiers: Hotkey.default.modifiers,
                                 label: Hotkey.defaultSpelled)
    }

    private var ref: EventHotKeyRef?
    private var handler: EventHandlerRef?
    private let action: @MainActor () -> Void

    /// False when something else already owns the chord. macOS refuses the second
    /// registration silently, so an app that ignores this looks broken with no
    /// explanation. Raycast and Alfred both default to Option-Space.
    public private(set) var registered = false

    /// Carbon calls back on a C function pointer, which cannot capture context, so
    /// the live instances are reachable through this table keyed by hotkey id.
    private static var registry: [UInt32: Hotkey] = [:]
    private static var nextID: UInt32 = 1

    init(keyCode: UInt32, modifiers: UInt32, action: @escaping @MainActor () -> Void) {
        self.action = action
        let id = Hotkey.nextID
        Hotkey.nextID += 1
        Hotkey.registry[id] = self

        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                      eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ -> OSStatus in
            var pressed = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject),
                              EventParamType(typeEventHotKeyID), nil,
                              MemoryLayout<EventHotKeyID>.size, nil, &pressed)
            let target = pressed.id
            DispatchQueue.main.async {
                MainActor.assumeIsolated { Hotkey.registry[target]?.action() }
            }
            return noErr
        }, 1, &eventType, nil, &handler)

        let hotKeyID = EventHotKeyID(signature: OSType(0x43454C52), id: id)  // 'CELR'
        let status = RegisterEventHotKey(keyCode, modifiers, hotKeyID,
                                         GetApplicationEventTarget(), 0, &ref)
        registered = status == noErr && ref != nil
    }

    /// Not a deinit: a deinit is nonisolated and cannot reach main-actor state.
    /// A hotkey lives as long as the app does, so teardown is explicit.
    func unregister() {
        if let ref { UnregisterEventHotKey(ref) }
        if let handler { RemoveEventHandler(handler) }
        ref = nil
        handler = nil
    }
}
