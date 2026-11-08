import Foundation

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
    var seenApps = Set<URL>()
    var items: [AppItem] = []

    func record(_ logicalURL: URL) {
        // Path-based file URLs avoid /var vs /private/var inequality from mixed URL sources.
        let id = URL(fileURLWithPath: logicalURL.standardizedFileURL.path)
        guard seenApps.insert(id).inserted else { return }
        items.append(
            AppItem(id: id, name: id.deletingPathExtension().lastPathComponent)
        )
    }

    /// `logical` is the path shown/launched; `physical` is where we list (symlinks resolved).
    /// `stack` tracks physical dirs on the current walk to break symlink cycles.
    func walk(logical: URL, physical: URL, stack: Set<URL>) {
        let dirKey = physical.standardizedFileURL
        guard !stack.contains(dirKey) else { return }
        var nextStack = stack
        nextStack.insert(dirKey)

        let keys: Set<URLResourceKey> = [
            .isHiddenKey, .isSymbolicLinkKey, .isDirectoryKey, .isPackageKey,
        ]
        guard
            let children = try? fileManager.contentsOfDirectory(
                at: physical,
                includingPropertiesForKeys: Array(keys),
                options: []
            )
        else { return }

        for child in children {
            let logicalChild = logical.appendingPathComponent(child.lastPathComponent)
            let values = try? child.resourceValues(forKeys: keys)

            // Index .app bundles and symlinks named *.app; never descend into them.
            if isAppPath(logicalChild) || isAppPath(child) {
                record(logicalChild)
                continue
            }

            // Symlinks to system apps are often hidden; still skip other hidden entries.
            if values?.isHidden == true { continue }

            if values?.isSymbolicLink == true {
                let resolved = child.resolvingSymlinksInPath().standardizedFileURL
                var isDir: ObjCBool = false
                guard fileManager.fileExists(atPath: resolved.path, isDirectory: &isDir),
                    isDir.boolValue
                else { continue }
                // Follow directory symlinks only when the target is not an app bundle.
                if isAppPath(resolved) { continue }
                walk(logical: logicalChild, physical: resolved, stack: nextStack)
                continue
            }

            if values?.isDirectory == true {
                // Do not recurse into packages/bundles that aren't handled as apps above.
                if values?.isPackage == true { continue }
                walk(logical: logicalChild, physical: child, stack: nextStack)
            }
        }
    }

    for dir in dirs {
        let root = URL(
            fileURLWithPath: (dir as NSString).expandingTildeInPath,
            isDirectory: true
        )
        walk(logical: root, physical: root.resolvingSymlinksInPath(), stack: [])
    }

    return items.sorted {
        let byName = $0.name.localizedCaseInsensitiveCompare($1.name)
        if byName != .orderedSame { return byName == .orderedAscending }
        return $0.id.path < $1.id.path
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
