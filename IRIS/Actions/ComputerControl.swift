//
//  ComputerControl.swift
//  IRIS — Actions lane
//
//  Lets IRIS control the Mac — type text, press keys, click — via Core Graphics events. This is
//  what makes "type that out for me" actually happen. Requires Accessibility permission (TCC),
//  which can't be granted in code; we prompt for it. Exposed to the realtime model as tools.
//
//  Safety: this can type/click anywhere, so it's gated behind `Settings.computerUseEnabled` and
//  the agent is instructed to confirm before anything destructive.
//

import AppKit
import CoreGraphics
import ApplicationServices

@MainActor
enum ComputerControl {

    /// Whether Accessibility (control-your-Mac) permission is granted. Pass `prompt: true` to
    /// surface the system prompt on first use.
    @discardableResult
    static func ensureAccessibility(prompt: Bool) -> Bool {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        return AXIsProcessTrustedWithOptions([key: prompt] as CFDictionary)
    }

    private static var notTrustedMessage: String {
        "I need Accessibility permission to control your Mac. Enable \(Persona.name) in System "
            + "Settings → Privacy & Security → Accessibility, then try again."
    }

    /// Type arbitrary text wherever the cursor is, using synthesized Unicode key events.
    static func typeText(_ text: String) -> String {
        guard ensureAccessibility(prompt: true) else { return notTrustedMessage }
        guard !text.isEmpty else { return "There was nothing to type." }

        let source = CGEventSource(stateID: .combinedSessionState)
        // Type in modest chunks so very long strings post reliably.
        for chunk in text.chunked(into: 200) {
            let utf16 = Array(chunk.utf16)
            guard let down = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: true),
                  let up = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: false) else { continue }
            utf16.withUnsafeBufferPointer { buf in
                if let base = buf.baseAddress {
                    down.keyboardSetUnicodeString(stringLength: buf.count, unicodeString: base)
                    up.keyboardSetUnicodeString(stringLength: buf.count, unicodeString: base)
                }
            }
            down.post(tap: .cghidEventTap)
            up.post(tap: .cghidEventTap)
        }
        return "Done typing."
    }

    /// Press a named key, optionally with modifiers (e.g. key "s" + ["command"] → ⌘S; "enter").
    static func pressKey(_ key: String, modifiers: [String]) -> String {
        guard ensureAccessibility(prompt: true) else { return notTrustedMessage }
        guard let code = keyCode(for: key.lowercased()) else { return "I don't know the key \(key)." }

        var flags: CGEventFlags = []
        for m in modifiers.map({ $0.lowercased() }) {
            switch m {
            case "command", "cmd", "⌘": flags.insert(.maskCommand)
            case "shift", "⇧": flags.insert(.maskShift)
            case "option", "alt", "⌥": flags.insert(.maskAlternate)
            case "control", "ctrl", "⌃": flags.insert(.maskControl)
            default: break
            }
        }
        let source = CGEventSource(stateID: .combinedSessionState)
        let down = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: true)
        let up = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: false)
        down?.flags = flags
        up?.flags = flags
        down?.post(tap: .cghidEventTap)
        up?.post(tap: .cghidEventTap)
        return "Done."
    }

    /// Click at a screen point (top-left origin, in points).
    static func click(x: Double, y: Double) -> String {
        guard ensureAccessibility(prompt: true) else { return notTrustedMessage }
        let point = CGPoint(x: x, y: y)
        let source = CGEventSource(stateID: .combinedSessionState)
        let down = CGEvent(mouseEventSource: source, mouseType: .leftMouseDown,
                           mouseCursorPosition: point, mouseButton: .left)
        let up = CGEvent(mouseEventSource: source, mouseType: .leftMouseUp,
                         mouseCursorPosition: point, mouseButton: .left)
        down?.post(tap: .cghidEventTap)
        up?.post(tap: .cghidEventTap)
        return "Clicked."
    }

    // MARK: - Key codes (common keys; extend as needed)

    private static func keyCode(for key: String) -> CGKeyCode? {
        let map: [String: CGKeyCode] = [
            "return": 36, "enter": 36, "tab": 48, "space": 49, "delete": 51, "backspace": 51,
            "escape": 53, "esc": 53, "left": 123, "right": 124, "down": 125, "up": 126,
            "a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7, "c": 8, "v": 9,
            "b": 11, "q": 12, "w": 13, "e": 14, "r": 15, "y": 16, "t": 17, "o": 31, "u": 32,
            "i": 34, "p": 35, "l": 37, "j": 38, "k": 40, "n": 45, "m": 46,
            "1": 18, "2": 19, "3": 20, "4": 21, "5": 23, "6": 22, "7": 26, "8": 28, "9": 25, "0": 29,
        ]
        return map[key]
    }
}

private extension String {
    func chunked(into size: Int) -> [String] {
        guard size > 0, count > size else { return [self] }
        var result: [String] = []
        var idx = startIndex
        while idx < endIndex {
            let end = index(idx, offsetBy: size, limitedBy: endIndex) ?? endIndex
            result.append(String(self[idx..<end]))
            idx = end
        }
        return result
    }
}
