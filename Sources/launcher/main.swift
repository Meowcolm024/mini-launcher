// Minimal rofi-like app launcher for macOS 14+
// Hotkey: Option+Space  (Esc or clicking away hides it)

import AppKit
import Carbon.HIToolbox
import SwiftUI

struct Config {
    let lookupPaths: [String]
    let hotkeyKeyCode: UInt32
    let hotkeyModifiers: UInt32

    static let current = Config(
        lookupPaths: [
            "/Applications",
            "/System/Applications",
            NSHomeDirectory() + "/Applications",
        ],
        hotkeyKeyCode: UInt32(kVK_Space),
        hotkeyModifiers: UInt32(optionKey)
    )
}

// MARK: - Panel

final class Panel: NSPanel {
    override var canBecomeKey: Bool { true }
}

// MARK: - App delegate

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let config = Config.current
    let state = RuntimeState()
    var panel: Panel!
    var apps: [AppItem] = []
    var hotKeyRef: EventHotKeyRef?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)  // no Dock icon
        apps = scanApps(in: config.lookupPaths)

        panel = Panel(
            contentRect: NSRect(x: 0, y: 0, width: 600, height: 380),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.level = .floating
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

        // Hide when focus is lost
        NotificationCenter.default.addObserver(
            forName: NSWindow.didResignKeyNotification,
            object: panel, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.panel.orderOut(nil)
            }
        }

        registerHotKey()
    }

    func toggle() {
        if panel.isVisible {
            panel.orderOut(nil)
            return
        }

        apps = scanApps(in: config.lookupPaths)  // cheap enough; keeps list fresh
        // Fresh view each time resets query/selection/focus
        panel.contentView = NSHostingView(
            rootView: LauncherView(apps: apps, state: state) { [weak self] in
                guard let self else { return }
                Task { @MainActor in
                    self.panel.orderOut(nil)
                }
            }
        )

        let screen =
            NSScreen.screens.first { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) }
            ?? NSScreen.main ?? NSScreen.screens[0]
        let f = screen.visibleFrame
        panel.setFrame(
            NSRect(x: f.midX - 300, y: f.maxY - 380 - f.height * 0.15, width: 600, height: 380),
            display: true
        )
        panel.makeKeyAndOrderFront(nil)
    }

    private func registerHotKey() {
        var spec = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        InstallEventHandler(
            GetApplicationEventTarget(),
            { _, _, ctx in
                let d = Unmanaged<AppDelegate>.fromOpaque(ctx!).takeUnretainedValue()
                DispatchQueue.main.async { d.toggle() }
                return noErr
            }, 1, &spec, Unmanaged.passUnretained(self).toOpaque(), nil)

        let id = EventHotKeyID(signature: OSType(0x4C4E_4348), id: 1)
        RegisterEventHotKey(
            config.hotkeyKeyCode, config.hotkeyModifiers, id,
            GetApplicationEventTarget(), 0, &hotKeyRef)
    }
}

// MARK: - Entry point

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
