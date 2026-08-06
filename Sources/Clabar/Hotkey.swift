import AppKit
import Carbon.HIToolbox

/// Global hotkey via Carbon RegisterEventHotKey — works without the
/// Accessibility permission (NSEvent global monitors would require it).
final class HotkeyCenter {
    static let shared = HotkeyCenter()

    var action: (() -> Void)?

    private var hotKeyRef: EventHotKeyRef?
    private var handlerInstalled = false

    /// ANSI virtual key codes for the configurable keys.
    static let keyCodes: [String: UInt32] = [
        "A": 0, "B": 11, "C": 8, "D": 2, "E": 14, "F": 3, "G": 5, "H": 4,
        "I": 34, "J": 38, "K": 40, "L": 37, "M": 46, "N": 45, "O": 31,
        "P": 35, "Q": 12, "R": 15, "S": 1, "T": 17, "U": 32, "V": 9,
        "W": 13, "X": 7, "Y": 16, "Z": 6,
        "0": 29, "1": 18, "2": 19, "3": 20, "4": 21, "5": 23, "6": 22,
        "7": 26, "8": 28, "9": 25,
    ]

    static let availableKeys: [String] = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789").map(String.init)

    func register(key: String, cmd: Bool, option: Bool, control: Bool, shift: Bool) {
        unregister()
        guard let keyCode = Self.keyCodes[key.uppercased()] else { return }
        var modifiers: UInt32 = 0
        if cmd { modifiers |= UInt32(cmdKey) }
        if option { modifiers |= UInt32(optionKey) }
        if control { modifiers |= UInt32(controlKey) }
        if shift { modifiers |= UInt32(shiftKey) }
        guard modifiers != 0 else { return } // an unmodified letter would eat typing

        installHandlerIfNeeded()
        let hotKeyID = EventHotKeyID(signature: OSType(0x434C_4252), id: 1) // 'CLBR'
        RegisterEventHotKey(keyCode, modifiers, hotKeyID, GetEventDispatcherTarget(), 0, &hotKeyRef)
    }

    func unregister() {
        if let hotKeyRef {
            UnregisterEventHotKey(hotKeyRef)
            self.hotKeyRef = nil
        }
    }

    private func installHandlerIfNeeded() {
        guard !handlerInstalled else { return }
        var spec = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        InstallEventHandler(GetEventDispatcherTarget(), { _, _, _ in
            DispatchQueue.main.async { HotkeyCenter.shared.action?() }
            return noErr
        }, 1, &spec, nil, nil)
        handlerInstalled = true
    }
}

/// Programmatically toggles the MenuBarExtra panel: SwiftUI has no public API,
/// so we click the status item's button.
@MainActor
enum MenuBarToggle {
    static func toggle() {
        guard let statusWindow = NSApp.windows.first(where: { $0.className.contains("StatusBarWindow") }),
              let contentView = statusWindow.contentView,
              let button = findButton(in: contentView) else { return }
        button.performClick(nil)
    }

    private static func findButton(in view: NSView) -> NSButton? {
        if let button = view as? NSButton { return button }
        for subview in view.subviews {
            if let button = findButton(in: subview) { return button }
        }
        return nil
    }
}
