import AppKit
import Observation

@MainActor
@Observable
final class LaunchState {
    typealias Completion = @MainActor (String?) -> Void
    typealias OpenApplication = @MainActor (URL, @escaping Completion) -> Void

    private(set) var pendingApp: AppItem?
    private(set) var errorMessage: String?

    @ObservationIgnored private var presentationID = UUID()
    private let fileManager: FileManager
    private let openApplication: OpenApplication

    init(
        fileManager: FileManager = .default,
        openApplication: @escaping OpenApplication = { url, completion in
            NSWorkspace.shared.openApplication(
                at: url.resolvingSymlinksInPath(), configuration: NSWorkspace.OpenConfiguration()
            ) { application, error in
                let message = error?.localizedDescription
                    ?? (application == nil ? "macOS did not return a running application." : nil)
                Task { @MainActor in completion(message) }
            }
        }
    ) {
        self.fileManager = fileManager
        self.openApplication = openApplication
    }

    func clearError() {
        errorMessage = nil
    }

    func beginPresentation() {
        presentationID = UUID()
        clearError()
    }

    func launch(_ app: AppItem, state: RuntimeState, closeOnSuccess: @escaping @MainActor () -> Void) {
        guard pendingApp == nil else { return }
        errorMessage = nil
        guard bundleExists(at: app.id) else {
            showMissingApp(app)
            return
        }

        let launchPresentationID = presentationID
        pendingApp = app
        openApplication(app.id) { [self] error in
            // Ignore a duplicate completion from a launch provider.
            guard pendingApp == app else { return }
            pendingApp = nil
            if let error {
                if bundleExists(at: app.id) {
                    errorMessage = "Couldn’t open \(app.name). \(error)"
                } else {
                    showMissingApp(app)
                }
            } else {
                state.recordSearch(of: app.id)
                if presentationID == launchPresentationID {
                    closeOnSuccess()
                }
            }
        }
    }

    private func bundleExists(at url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        return fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory)
            && isDirectory.boolValue
    }

    private func showMissingApp(_ app: AppItem) {
        errorMessage = "Couldn’t open \(app.name). The app is missing. Run /refresh to update the app list."
    }
}
