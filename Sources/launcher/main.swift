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
    let catalog = AppCatalog(paths: Config.current.lookupPaths)
    let launchState = LaunchState()
    var panel: Panel!
    var hotKeyRef: EventHotKeyRef?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)  // no Dock icon

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
                guard let self, !self.panel.isKeyWindow else { return }
                self.panel.orderOut(nil)
            }
        }

        registerHotKey()
        catalog.refresh()
    }

    func toggle() {
        if panel.isVisible {
            panel.orderOut(nil)
            return
        }

        // Reset panel input while retaining the catalog and any pending launch.
        launchState.beginPresentation()
        panel.contentView = NSHostingView(
            rootView: LauncherView(
                catalog: catalog,
                state: state,
                launchState: launchState,
                onClose: { [weak self] in
                    guard let self, panel.isVisible else { return }
                    panel.orderOut(nil)
                },
                onQuit: {
                    NSApp.terminate(nil)
                }
            )
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
        let handlerStatus = InstallEventHandler(
            GetApplicationEventTarget(),
            { _, _, ctx in
                let d = Unmanaged<AppDelegate>.fromOpaque(ctx!).takeUnretainedValue()
                DispatchQueue.main.async { d.toggle() }
                return noErr
            }, 1, &spec, Unmanaged.passUnretained(self).toOpaque(), nil)
        guard handlerStatus == noErr else {
            hotKeySetupFailed("install the hotkey handler", status: handlerStatus)
        }

        let id = EventHotKeyID(signature: OSType(0x4C4E_4348), id: 1)
        let registrationStatus = RegisterEventHotKey(
            config.hotkeyKeyCode, config.hotkeyModifiers, id,
            GetApplicationEventTarget(), 0, &hotKeyRef)
        guard registrationStatus == noErr else {
            hotKeySetupFailed("register Option+Space", status: registrationStatus)
        }
    }

    private func hotKeySetupFailed(_ action: String, status: OSStatus) -> Never {
        let message = "Launcher couldn’t \(action) (OSStatus \(status)).\n"
        FileHandle.standardError.write(Data(message.utf8))
        exit(1)
    }
}

// MARK: - Entry point

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
