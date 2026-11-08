import Foundation
import Testing
@testable import launcher

private func app(_ name: String) -> AppItem {
    AppItem(id: URL(fileURLWithPath: "/Applications/\(name).app"), name: name)
}

@Test func emptyQueryIsAlphabeticalWithoutSearchHistory() {
    let alpha = app("Alpha")
    let beta = app("Beta")
    let state = RuntimeState()

    let results = rankedResults(apps: [beta, alpha], query: "", state: state)

    #expect(results == [alpha, beta])
}

@Test func searchedItemsRankHigherInDefaultView() {
    let alpha = app("Alpha")
    let beta = app("Beta")
    let gamma = app("Gamma")
    let state = RuntimeState()
    state.recordSearch(of: gamma.id)

    let results = rankedResults(apps: [alpha, beta, gamma], query: "", state: state)

    #expect(results.first == gamma)
    #expect(results == [gamma, alpha, beta])
}

@Test func searchedItemsBoostFuzzyRanking() {
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

@Test func moreSearchesIncreaseBoost() {
    let alpha = app("Alpha")
    let beta = app("Beta")
    let state = RuntimeState()
    state.recordSearch(of: alpha.id)
    state.recordSearch(of: beta.id)
    state.recordSearch(of: beta.id)

    let results = rankedResults(apps: [alpha, beta], query: "", state: state)

    #expect(results == [beta, alpha])
}

@Test func rankedResultsRespectsLimit() {
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

    try fm.createDirectory(at: systemFoo, withIntermediateDirectories: true)
    try fm.createDirectory(at: homeFoo, withIntermediateDirectories: true)
    try fm.createDirectory(at: nestedBar, withIntermediateDirectories: true)
    try fm.createDirectory(at: nestedInsideBundle, withIntermediateDirectories: true)

    let items = scanApps(in: [applications.path, homeApplications.path], fileManager: fm)

    #expect(items.filter { $0.name == "Foo" }.count == 2)
    #expect(items.contains { $0.id.standardizedFileURL == systemFoo.standardizedFileURL })
    #expect(items.contains { $0.id.standardizedFileURL == homeFoo.standardizedFileURL })
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
    let nestedInsideReal = realApp.appendingPathComponent("Contained.app", isDirectory: true)

    try fm.createDirectory(at: applications, withIntermediateDirectories: true)
    try fm.createDirectory(at: realApp, withIntermediateDirectories: true)
    try fm.createDirectory(at: nestedInsideReal, withIntermediateDirectories: true)
    try fm.createSymbolicLink(at: link, withDestinationURL: realApp)

    // Match system apps like /Applications/Safari.app, which are hidden symlinks.
    var mutableLink = link
    var values = URLResourceValues()
    values.isHidden = true
    try mutableLink.setResourceValues(values)

    let items = scanApps(in: [applications.path], fileManager: fm)

    #expect(items.contains { $0.name == "Safari" })
    #expect(items.contains { $0.id.standardizedFileURL == link.standardizedFileURL })
    #expect(!items.contains { $0.name == "Contained" })
    #expect(!items.contains { $0.id.standardizedFileURL == realApp.standardizedFileURL })
}
