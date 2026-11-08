import AppKit
import SwiftUI

struct LauncherView: View {
    let apps: [AppItem]
    let state: RuntimeState
    let onClose: @Sendable () -> Void

    @State private var query = ""
    @State private var selection = 0
    @FocusState private var focused: Bool

    private var results: [AppItem] {
        rankedResults(apps: apps, query: query, state: state)
    }

    private var ambiguousNames: Set<String> {
        duplicateAppNames(in: apps)
    }

    var body: some View {
        let items = results
        let duplicates = ambiguousNames
        VStack(spacing: 0) {
            TextField("Search apps…", text: $query)
                .textFieldStyle(.plain)
                .font(.system(size: 22))
                .padding(14)
                .focused($focused)
                .onSubmit { launch(items) }
                .onKeyPress(.downArrow) {
                    selection = min(selection + 1, max(items.count - 1, 0))
                    return .handled
                }
                .onKeyPress(.upArrow) {
                    selection = max(selection - 1, 0)
                    return .handled
                }
                .onExitCommand { onClose() }

            if !items.isEmpty {
                Divider()
                VStack(spacing: 0) {
                    ForEach(Array(items.enumerated()), id: \.element.id) { i, app in
                        HStack(spacing: 10) {
                            Image(nsImage: NSWorkspace.shared.icon(forFile: app.id.path))
                                .resizable()
                                .frame(width: 28, height: 28)
                            HStack(alignment: .firstTextBaseline, spacing: 6) {
                                Text(app.name).font(.system(size: 16))
                                if duplicates.contains(app.name) {
                                    Text(app.pathPrefix)
                                        .font(.system(size: 13))
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                        .truncationMode(.middle)
                                }
                            }
                            Spacer(minLength: 0)
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 6)
                        .background(i == selection ? Color.accentColor.opacity(0.35) : .clear)
                        .contentShape(Rectangle())
                        .onTapGesture {
                            selection = i
                            launch(items)
                        }
                    }
                }
                .padding(.vertical, 4)
            }
        }
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(.white.opacity(0.1)))
        .frame(width: 600)
        .frame(maxHeight: .infinity, alignment: .top)
        .onChange(of: query) { selection = 0 }
        .onAppear { DispatchQueue.main.async { focused = true } }
    }

    private func launch(_ items: [AppItem]) {
        guard items.indices.contains(selection) else { return }
        let app = items[selection]
        state.recordSearch(of: app.id)
        NSWorkspace.shared.openApplication(
            at: app.id,
            configuration: NSWorkspace.OpenConfiguration()
        )
        onClose()
    }
}
