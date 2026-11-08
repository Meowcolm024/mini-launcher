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

func scanApps(in dirs: [String], fileManager: FileManager = .default) -> [AppItem] {
    var seen = Set<URL>()
    var items: [AppItem] = []
    for dir in dirs {
        let root = URL(
            fileURLWithPath: (dir as NSString).expandingTildeInPath,
            isDirectory: true
        )
        // Do not use skipsHiddenFiles: symlinks to system apps (e.g. Safari.app) are
        // often marked hidden and would be skipped. skipsPackageDescendants still
        // prevents descending into .app bundles.
        guard
            let enumerator = fileManager.enumerator(
                at: root,
                includingPropertiesForKeys: [.isHiddenKey],
                options: [.skipsPackageDescendants]
            )
        else { continue }
        while let url = enumerator.nextObject() as? URL {
            let isApp = url.pathExtension.caseInsensitiveCompare("app") == .orderedSame
            if isApp {
                // Identity is the path: same display name under different roots are distinct.
                // Includes directory bundles and symlinks to bundles (symlink URL is kept).
                let id = url.standardizedFileURL
                if seen.insert(id).inserted {
                    let name = id.deletingPathExtension().lastPathComponent
                    items.append(AppItem(id: id, name: name))
                }
                enumerator.skipDescendants()
                continue
            }
            // Skip other hidden files/dirs so we don't walk junk like .Trash.
            if (try? url.resourceValues(forKeys: [.isHiddenKey]))?.isHidden == true {
                enumerator.skipDescendants()
            }
        }
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
