import Foundation
import Observation

struct AppItem: Identifiable, Hashable {
    let id: URL
    let name: String

    /// Parent directory of the bundle, with the home directory shortened to `~`.
    var pathPrefix: String {
        let parent = id.deletingLastPathComponent().path
        let home = NSHomeDirectory()
        if parent == home { return "~" }
        if parent.hasPrefix(home + "/") {
            return "~" + parent.dropFirst(home.count)
        }
        return parent
    }
}

/// Names that appear more than once in the catalog (case-sensitive, as on disk).
func duplicateAppNames(in apps: [AppItem]) -> Set<String> {
    var counts: [String: Int] = [:]
    for app in apps {
        counts[app.name, default: 0] += 1
    }
    return Set(counts.compactMap { $0.value > 1 ? $0.key : nil })
}

private func isAppPath(_ url: URL) -> Bool {
    url.pathExtension.caseInsensitiveCompare("app") == .orderedSame
}

func scanApps(in dirs: [String], fileManager: FileManager = .default) -> [AppItem] {
    let keys: Set<URLResourceKey> = [
        .isHiddenKey, .isSymbolicLinkKey, .isDirectoryKey, .isPackageKey,
    ]
    var visitedDirectories = Set<String>()
    var directoryLinks: [(logical: URL, physical: URL)] = []
    var seenApps = Set<URL>()
    var items: [AppItem] = []

    func record(_ logicalURL: URL, bundleAt physicalURL: URL) {
        guard let bundle = Bundle(url: physicalURL),
            let info = bundle.infoDictionary,
            // Legacy apps can use a same-name executable without CFBundleExecutable.
            info["CFBundleExecutable"] is String || info["CFBundlePackageType"] as? String == "APPL",
            let executable = bundle.executableURL?.resolvingSymlinksInPath(),
            (try? executable.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true,
            fileManager.isExecutableFile(atPath: executable.path)
        else { return }

        let id = URL(fileURLWithPath: logicalURL.standardizedFileURL.path)
        guard seenApps.insert(id).inserted else { return }
        let nameURL = isAppPath(id) ? id.deletingPathExtension() : id
        items.append(AppItem(id: id, name: nameURL.lastPathComponent))
    }

    func walk(logical: URL, physical: URL) {
        guard !isAppPath(physical),
            visitedDirectories.insert(physical.resolvingSymlinksInPath().standardizedFileURL.path)
                .inserted
        else { return }
        guard
            let children = try? fileManager.contentsOfDirectory(
                at: physical,
                includingPropertiesForKeys: Array(keys),
                options: []
            )
        else { return }

        for child in children.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            let logicalChild = logical.appendingPathComponent(child.lastPathComponent)
            guard let values = try? child.resourceValues(forKeys: keys) else { continue }
            let isLink = values.isSymbolicLink == true
            let target = isLink ? child.resolvingSymlinksInPath() : child

            // Keep the link's name, including links whose names lack a .app suffix.
            if isAppPath(child) || isAppPath(target) {
                record(logicalChild, bundleAt: target)
                continue
            }

            if values.isHidden == true { continue }
            if isLink {
                guard let targetValues = try? target.resourceValues(forKeys: keys),
                    targetValues.isDirectory == true, targetValues.isPackage != true
                else { continue }
                directoryLinks.append((logicalChild, target))
            } else if values.isDirectory == true, values.isPackage != true {
                walk(logical: logicalChild, physical: target)
            }
        }
    }

    for dir in dirs {
        let root = URL(
            fileURLWithPath: (dir as NSString).expandingTildeInPath,
            isDirectory: true
        )
        walk(logical: root, physical: root.resolvingSymlinksInPath())
    }

    // Prefer regular directory paths and only walk each physical directory once.
    while !directoryLinks.isEmpty {
        let links = directoryLinks
        directoryLinks.removeAll()
        for link in links {
            walk(logical: link.logical, physical: link.physical)
        }
    }

    return items.sorted {
        let byName = $0.name.localizedCaseInsensitiveCompare($1.name)
        if byName != .orderedSame { return byName == .orderedAscending }
        return $0.id.path < $1.id.path
    }
}

@MainActor
@Observable
final class AppCatalog {
    private(set) var apps: [AppItem] = []
    private(set) var isScanning = false
    private let paths: [String]

    init(paths: [String]) {
        self.paths = paths
    }

    func refresh() {
        guard !isScanning else { return }
        isScanning = true
        Task {
            apps = await Task.detached { [paths] in scanApps(in: paths) }.value
            isScanning = false
        }
    }
}

/// Simple subsequence fuzzy score; nil means no match.
func score(_ query: String, _ name: String) -> Int? {
    if query.isEmpty { return 0 }
    let q = Array(query.lowercased())
    let n = Array(name.lowercased())
    var qi = 0
    var s = 0
    var last = -2
    for (i, c) in n.enumerated() where qi < q.count && c == q[qi] {
        s += 1
        if i == last + 1 { s += 3 }  // consecutive
        if i == 0 || n[i - 1] == " " { s += 5 }  // word start
        last = i
        qi += 1
    }
    return qi == q.count ? s : nil
}

/// Session-scoped counts of apps the user has searched/launched.
@MainActor
final class RuntimeState {
    private(set) var searchHits: [URL: Int] = [:]

    func recordSearch(of id: URL) {
        searchHits[id, default: 0] += 1
    }

    func searchBoost(for id: URL, weight: Int = 10) -> Int {
        (searchHits[id] ?? 0) * weight
    }
}

/// Rank apps by fuzzy score plus runtime search boost; higher is better.
@MainActor
func rankedResults(
    apps: [AppItem],
    query: String,
    state: RuntimeState,
    limit: Int = 8
) -> [AppItem] {
    let scored: [(AppItem, Int)] = apps.compactMap { app in
        guard let s = score(query, app.name) else { return nil }
        return (app, s + state.searchBoost(for: app.id))
    }
    return scored
        .sorted { lhs, rhs in
            if lhs.1 != rhs.1 { return lhs.1 > rhs.1 }
            return lhs.0.name.localizedCaseInsensitiveCompare(rhs.0.name) == .orderedAscending
        }
        .prefix(limit)
        .map(\.0)
}

// MARK: - Slash commands

enum LauncherCommand: String, CaseIterable, Identifiable {
    case refresh
    case quit

    var id: String { rawValue }

    var token: String { "/\(rawValue)" }

    var summary: String {
        switch self {
        case .refresh: "Reindex apps"
        case .quit: "Quit launcher"
        }
    }
}

/// Prefix-match slash commands when `query` starts with `/`.
func matchingCommands(for query: String) -> [LauncherCommand] {
    guard query.hasPrefix("/") else { return [] }
    let needle = query.dropFirst().lowercased()
    if needle.isEmpty { return Array(LauncherCommand.allCases) }
    return LauncherCommand.allCases.filter { command in
        command.rawValue.hasPrefix(needle)
    }
}
