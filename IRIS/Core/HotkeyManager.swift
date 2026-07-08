//
//  HotkeyManager.swift
//  IRIS — global hotkeys
//
//  Two chords, monitored globally (other app focused) AND locally (IRIS focused —
//  global monitors don't observe our own events):
//    • Hold ⌥Space — push-to-talk: keyDown starts capture, keyUp routes what was heard.
//      Clicky-style: no wake phrase, no settle timeout, guaranteed capture.
//    • ⌥⎋ — interrupt: stop speech + cancel the in-flight foreground command.
//
//  Global key monitors require Accessibility/Input Monitoring; when denied, the wake
//  word still works (PermissionsManager surfaces the grant).
//

import AppKit

@MainActor
final class HotkeyManager {
    /// Escape's virtual keycode; Space's is 49. Both are stable hardware codes.
    static let escapeKeyCode: UInt16 = 53

    private var monitors: [Any] = []
    private var pttHeld = false

    var onPTTDown: (() -> Void)?
    var onPTTUp: (() -> Void)?
    var onInterrupt: (() -> Void)?

    private let pttKeyCode: UInt16
    private let pttModifiers: NSEvent.ModifierFlags

    init(settings: Settings) {
        self.pttKeyCode = settings.pttKeyCode
        self.pttModifiers = NSEvent.ModifierFlags(rawValue: UInt(settings.pttModifiers))
    }

    func install() {
        let handleDown: (NSEvent) -> Bool = { [weak self] event in
            guard let self else { return false }
            let mods = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            if event.keyCode == Self.escapeKeyCode && mods == .option {
                self.onInterrupt?()
                return true
            }
            if event.keyCode == self.pttKeyCode && mods == self.pttModifiers && !event.isARepeat {
                if !self.pttHeld {
                    self.pttHeld = true
                    self.onPTTDown?()
                }
                return true
            }
            return false
        }
        let handleUp: (NSEvent) -> Bool = { [weak self] event in
            guard let self, self.pttHeld, event.keyCode == self.pttKeyCode else { return false }
            self.pttHeld = false
            self.onPTTUp?()
            return true
        }

        monitors.append(NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { event in
            // Global monitors run off the main actor's static-isolation guarantee; hop on.
            Task { @MainActor in _ = handleDown(event) }
        } as Any)
        monitors.append(NSEvent.addGlobalMonitorForEvents(matching: .keyUp) { event in
            Task { @MainActor in _ = handleUp(event) }
        } as Any)
        monitors.append(NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            handleDown(event) ? nil : event   // swallow handled events (no error beep)
        } as Any)
        monitors.append(NSEvent.addLocalMonitorForEvents(matching: .keyUp) { event in
            handleUp(event) ? nil : event
        } as Any)
    }

    func uninstall() {
        for m in monitors { NSEvent.removeMonitor(m) }
        monitors.removeAll()
        pttHeld = false
    }
}
