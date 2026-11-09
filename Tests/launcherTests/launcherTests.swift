import Foundation
import Testing
@testable import launcher

private func app(_ name: String) -> AppItem {
    AppItem(id: URL(fileURLWithPath: "/Applications/\(name).app"), name: name)
}

private func createAppBundle(at url: URL) throws {
    let contents = url.appendingPathComponent("Contents")
    let macOS = contents.appendingPathComponent("MacOS")
    let executable = macOS.appendingPathComponent("fixture")
    try FileManager.default.createDirectory(at: macOS, withIntermediateDirectories: true)
    let info = ["CFBundleExecutable": "fixture", "CFBundlePackageType": "APPL"]
    let plist = try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
    try plist.write(to: contents.appendingPathComponent("Info.plist"))
    try Data("#!/bin/sh\nexit 0\n".utf8).write(to: executable)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
}

@Test @MainActor func launchHandlesPendingFailureAndSuccess() throws {
    let fm = FileManager.default
    let bundle = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".app")
    try fm.createDirectory(at: bundle, withIntermediateDirectories: true)
    defer { try? fm.removeItem(at: bundle) }
    let item = AppItem(id: bundle, name: "Example")
    let runtime = RuntimeState()
    var completion: LaunchState.Completion?
    var requests = 0
    var closes = 0
    let launch = LaunchState { _, callback in
        requests += 1
        completion = callback
    }

    launch.launch(item, state: runtime) { closes += 1 }
    launch.launch(item, state: runtime) { closes += 1 }
    #expect(requests == 1)
    #expect(launch.pendingApp == item)
    #expect(runtime.searchBoost(for: item.id) == 0)
    #expect(closes == 0)

    completion?("Permission denied")
    #expect(launch.pendingApp == nil)
    #expect(launch.errorMessage?.contains("Example") == true)
    #expect(launch.errorMessage?.contains("Permission denied") == true)
    #expect(runtime.searchBoost(for: item.id) == 0)
    #expect(closes == 0)

    launch.launch(item, state: runtime) { closes += 1 }
    #expect(launch.errorMessage == nil)
    completion?(nil)
    #expect(launch.pendingApp == nil)
    #expect(runtime.searchBoost(for: item.id) == 10)
    #expect(closes == 1)
}

@Test @MainActor func reopeningPanelKeepsPendingLaunchWithoutClosingNewPresentation() throws {
    let fm = FileManager.default
    let bundle = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".app")
    try fm.createDirectory(at: bundle, withIntermediateDirectories: true)
    defer { try? fm.removeItem(at: bundle) }
    let item = AppItem(id: bundle, name: "Example")
    let runtime = RuntimeState()
    var completions: [LaunchState.Completion] = []
    let launch = LaunchState { _, callback in completions.append(callback) }
    var panelIsVisible = true

    launch.beginPresentation()
    launch.launch(item, state: runtime) { panelIsVisible = false }

    launch.beginPresentation()
    #expect(launch.pendingApp == item)
    launch.launch(item, state: runtime) { panelIsVisible = false }
    try #require(completions.count == 1)

    completions[0](nil)
    #expect(panelIsVisible)
    #expect(launch.pendingApp == nil)
    #expect(runtime.searchBoost(for: item.id) == 10)

    launch.launch(item, state: runtime) { panelIsVisible = false }
    try #require(completions.count == 2)
    completions[1](nil)
    #expect(!panelIsVisible)
}

@Test @MainActor func launchSuggestsRefreshForMissingBundle() throws {
    let fm = FileManager.default
    let bundle = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".app")
    defer { try? fm.removeItem(at: bundle) }
    let item = AppItem(id: bundle, name: "Missing")
    let runtime = RuntimeState()
    var completion: LaunchState.Completion?
    var requests = 0
    var closes = 0
    let launch = LaunchState { _, callback in
        requests += 1
        completion = callback
    }

    launch.launch(item, state: runtime) { closes += 1 }
    #expect(requests == 0)
    #expect(launch.errorMessage?.contains("/refresh") == true)
    #expect(launch.pendingApp == nil)

    // Also handle an app disappearing after the launch request starts.
    try fm.createDirectory(at: bundle, withIntermediateDirectories: true)
    launch.launch(item, state: runtime) { closes += 1 }
    try fm.removeItem(at: bundle)
    completion?("Launch failed")
    #expect(launch.errorMessage?.contains("/refresh") == true)
    #expect(launch.pendingApp == nil)
    #expect(runtime.searchBoost(for: item.id) == 0)
    #expect(closes == 0)
}

@Test @MainActor func emptyQueryIsAlphabeticalWithoutSearchHistory() {
    let alpha = app("Alpha")
    let beta = app("Beta")
    let state = RuntimeState()

    let results = rankedResults(apps: [beta, alpha], query: "", state: state)

    #expect(results == [alpha, beta])
}

@Test @MainActor func searchedItemsRankHigherInDefaultView() {
    let alpha = app("Alpha")
    let beta = app("Beta")
    let gamma = app("Gamma")
    let state = RuntimeState()
    state.recordSearch(of: gamma.id)

    let results = rankedResults(apps: [alpha, beta, gamma], query: "", state: state)

    #expect(results.first == gamma)
    #expect(results == [gamma, alpha, beta])
}

@Test @MainActor func searchedItemsBoostFuzzyRanking() {
    let calculator = app("Calculator")
    let calendar = app("Calendar")
    let state = RuntimeState()
    state.recordSearch(of: calendar.id)

    // Both match "cal"; without boost Calculator often wins on consecutive chars,
    // but Calendar's search hit should lift it above.
    let results = rankedResults(
        apps: [calculator, calendar],
        query: "cal",
        state: state
    )

    #expect(results.first == calendar)
}

@Test @MainActor func moreSearchesIncreaseBoost() {
    let alpha = app("Alpha")
    let beta = app("Beta")
    let state = RuntimeState()
    state.recordSearch(of: alpha.id)
    state.recordSearch(of: beta.id)
    state.recordSearch(of: beta.id)

    let results = rankedResults(apps: [alpha, beta], query: "", state: state)

    #expect(results == [beta, alpha])
}

@Test @MainActor func rankedResultsRespectsLimit() {
    let apps = (0..<20).map { app(String(format: "App%02d", $0)) }
    let state = RuntimeState()

    let results = rankedResults(apps: apps, query: "", state: state, limit: 8)

    #expect(results.count == 8)
}

@Test func scanAppsFindsNestedAppsAndTreatsPathsAsDistinct() throws {
    let fm = FileManager.default
    let root = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? fm.removeItem(at: root) }

    let applications = root.appendingPathComponent("Applications", isDirectory: true)
    let homeApplications = root.appendingPathComponent("HomeApplications", isDirectory: true)
    let utilities = applications.appendingPathComponent("Utilities", isDirectory: true)

    try fm.createDirectory(at: utilities, withIntermediateDirectories: true)
    try fm.createDirectory(at: homeApplications, withIntermediateDirectories: true)

    let systemFoo = applications.appendingPathComponent("Foo.app", isDirectory: true)
    let homeFoo = homeApplications.appendingPathComponent("Foo.app", isDirectory: true)
    let nestedBar = utilities.appendingPathComponent("Bar.app", isDirectory: true)
    let nestedInsideBundle = systemFoo.appendingPathComponent("Contained.app", isDirectory: true)

    try createAppBundle(at: systemFoo)
    try createAppBundle(at: homeFoo)
    try createAppBundle(at: nestedBar)
    try createAppBundle(at: nestedInsideBundle)

    let items = scanApps(in: [applications.path, homeApplications.path], fileManager: fm)

    #expect(items.filter { $0.name == "Foo" }.count == 2)
    #expect(items.contains { $0.id.standardizedFileURL.path == systemFoo.standardizedFileURL.path })
    #expect(items.contains { $0.id.standardizedFileURL.path == homeFoo.standardizedFileURL.path })
    #expect(items.contains { $0.name == "Bar" })
    #expect(!items.contains { $0.name == "Contained" })
}

@Test func pathPrefixShortensHomeAndDuplicateNamesAreDetected() {
    let home = NSHomeDirectory()
    let system = AppItem(
        id: URL(fileURLWithPath: "/Applications/Foo.app"),
        name: "Foo"
    )
    let user = AppItem(
        id: URL(fileURLWithPath: home + "/Applications/Foo.app"),
        name: "Foo"
    )
    let unique = AppItem(
        id: URL(fileURLWithPath: "/Applications/Bar.app"),
        name: "Bar"
    )

    #expect(system.pathPrefix == "/Applications")
    #expect(user.pathPrefix == "~/Applications")
    #expect(duplicateAppNames(in: [system, user, unique]) == ["Foo"])
}

@Test func scanAppsIndexesSymlinksToAppBundlesEvenIfHidden() throws {
    let fm = FileManager.default
    let root = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? fm.removeItem(at: root) }

    let applications = root.appendingPathComponent("Applications", isDirectory: true)
    let realApp = root.appendingPathComponent("RealSafari.app", isDirectory: true)
    let link = applications.appendingPathComponent("Safari.app")
    let extensionlessLink = applications.appendingPathComponent("Browser")
    let nestedInsideReal = realApp.appendingPathComponent("Contained.app", isDirectory: true)

    try fm.createDirectory(at: applications, withIntermediateDirectories: true)
    try createAppBundle(at: realApp)
    try createAppBundle(at: nestedInsideReal)
    try fm.createSymbolicLink(at: link, withDestinationURL: realApp)
    try fm.createSymbolicLink(at: extensionlessLink, withDestinationURL: realApp)

    // Match system apps like /Applications/Safari.app, which are hidden symlinks.
    var mutableLink = link
    var values = URLResourceValues()
    values.isHidden = true
    try mutableLink.setResourceValues(values)

    let items = scanApps(in: [applications.path], fileManager: fm)

    #expect(items.contains { $0.name == "Safari" })
    #expect(items.contains { $0.id.standardizedFileURL.path == link.standardizedFileURL.path })
    #expect(items.contains {
        $0.name == "Browser" && $0.id.path == extensionlessLink.path
    })
    #expect(!items.contains { $0.name == "Contained" })
    #expect(!items.contains { $0.id.standardizedFileURL.path == realApp.standardizedFileURL.path })
}

@Test func scanAppsRecursesThroughSymlinkedDirectoriesButNotAppBundles() throws {
    let fm = FileManager.default
    let root = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? fm.removeItem(at: root) }

    let applications = root.appendingPathComponent("Applications", isDirectory: true)
    let realDir = root.appendingPathComponent("RealDir", isDirectory: true)
    let nestedApp = realDir.appendingPathComponent("Foo.app", isDirectory: true)
    let nestedInsideApp = nestedApp.appendingPathComponent("Contained.app", isDirectory: true)
    let dirLink = applications.appendingPathComponent("Extra")
    let appLinkTarget = root.appendingPathComponent("RealBar.app", isDirectory: true)
    let appLink = applications.appendingPathComponent("Bar.app")

    try fm.createDirectory(at: applications, withIntermediateDirectories: true)
    try createAppBundle(at: nestedApp)
    try createAppBundle(at: nestedInsideApp)
    try createAppBundle(at: appLinkTarget)
    try fm.createSymbolicLink(at: dirLink, withDestinationURL: realDir)
    try fm.createSymbolicLink(
        at: applications.appendingPathComponent("ExtraCopy"), withDestinationURL: realDir
    )
    try fm.createSymbolicLink(at: appLink, withDestinationURL: appLinkTarget)

    let items = scanApps(in: [applications.path], fileManager: fm)
    let logicalFoo = dirLink.appendingPathComponent("Foo.app").standardizedFileURL

    #expect(items.count == 2)
    #expect(items.contains { $0.id.standardizedFileURL.path == logicalFoo.path })
    #expect(items.contains { $0.id.standardizedFileURL.path == appLink.standardizedFileURL.path })
    #expect(!items.contains { $0.name == "Contained" })
    #expect(!items.contains { $0.id.standardizedFileURL.path == nestedApp.standardizedFileURL.path })

    let includingRealDir = scanApps(in: [applications.path, realDir.path], fileManager: fm)
    #expect(includingRealDir.filter { $0.name == "Foo" }.map(\.id.path) == [nestedApp.path])
}

@Test func scanAppsSkipsInvalidAppBundlesAndSymlinks() throws {
    let fm = FileManager.default
    let root = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? fm.removeItem(at: root) }

    try fm.createDirectory(at: root, withIntermediateDirectories: true)
    let validApp = root.appendingPathComponent("Valid.APP", isDirectory: true)
    try createAppBundle(at: validApp)
    let ordinaryFolder = root.appendingPathComponent("Folder.app", isDirectory: true)
    try fm.createDirectory(at: ordinaryFolder, withIntermediateDirectories: true)
    let missingExecutable = root.appendingPathComponent("MissingExecutable.app", isDirectory: true)
    try createAppBundle(at: missingExecutable)
    try fm.removeItem(at: missingExecutable.appendingPathComponent("Contents/MacOS/fixture"))
    let file = root.appendingPathComponent("File.app")
    try Data().write(to: file)
    try fm.createSymbolicLink(
        at: root.appendingPathComponent("FileLink.app"), withDestinationURL: file
    )
    try fm.createSymbolicLink(
        at: root.appendingPathComponent("Broken.app"),
        withDestinationURL: root.appendingPathComponent("Missing.app")
    )
    try fm.createSymbolicLink(
        at: root.appendingPathComponent("ValidLink.app"), withDestinationURL: validApp
    )
    try fm.createSymbolicLink(
        at: root.appendingPathComponent("FolderLink.app"), withDestinationURL: ordinaryFolder
    )

    let items = scanApps(in: [root.path], fileManager: fm)

    #expect(items.map(\.name) == ["Valid", "ValidLink"])
}

@Test func scanAppsAcceptsLegacyAppWithSameNameExecutable() throws {
    let fm = FileManager.default
    let root = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? fm.removeItem(at: root) }

    let legacy = root.appendingPathComponent("Legacy.app", isDirectory: true)
    try createAppBundle(at: legacy)
    let info = try PropertyListSerialization.data(
        fromPropertyList: ["CFBundlePackageType": "APPL"], format: .xml, options: 0
    )
    try info.write(to: legacy.appendingPathComponent("Contents/Info.plist"))
    try fm.moveItem(
        at: legacy.appendingPathComponent("Contents/MacOS/fixture"),
        to: legacy.appendingPathComponent("Legacy")
    )

    #expect(scanApps(in: [root.path]).map(\.name) == ["Legacy"])
}

@Test func scanAppsDetectsSymlinkCycles() throws {
    let fm = FileManager.default
    let root = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? fm.removeItem(at: root) }

    let applications = root.appendingPathComponent("Applications", isDirectory: true)
    let other = root.appendingPathComponent("Other", isDirectory: true)
    let app = applications.appendingPathComponent("Foo.app", isDirectory: true)
    let toOther = applications.appendingPathComponent("toOther")
    let back = other.appendingPathComponent("back")

    try createAppBundle(at: app)
    try fm.createDirectory(at: other, withIntermediateDirectories: true)
    try fm.createSymbolicLink(at: toOther, withDestinationURL: other)
    try fm.createSymbolicLink(at: back, withDestinationURL: applications)

    // Must terminate despite Applications ↔ Other symlink cycle.
    let items = scanApps(in: [applications.path], fileManager: fm)

    #expect(items.contains { $0.name == "Foo" })
    #expect(items.count == 1)
}

@Test func matchingCommandsRequiresSlashPrefix() {
    #expect(matchingCommands(for: "").isEmpty)
    #expect(matchingCommands(for: "refresh").isEmpty)
    #expect(matchingCommands(for: "/") == LauncherCommand.allCases)
}

@Test func matchingCommandsFiltersByPrefix() {
    #expect(matchingCommands(for: "/r") == [.refresh])
    #expect(matchingCommands(for: "/ref") == [.refresh])
    #expect(matchingCommands(for: "/q") == [.quit])
    #expect(matchingCommands(for: "/REFRESH") == [.refresh])
    #expect(matchingCommands(for: "/refresh") == [.refresh])
    #expect(matchingCommands(for: "/update").isEmpty)
    #expect(matchingCommands(for: "/quit") == [.quit])
    #expect(matchingCommands(for: "/xyz").isEmpty)
}
