import AppKit
import SwiftUI

struct LauncherView: View {
    let state: RuntimeState
    let onClose: @Sendable () -> Void
    let onReindex: @Sendable () -> [AppItem]
    let onQuit: @Sendable () -> Void

    @State private var apps: [AppItem]
    @State private var query = ""
    @State private var selection = 0
    @FocusState private var focused: Bool

    init(
        apps: [AppItem],
        state: RuntimeState,
        onClose: @escaping @Sendable () -> Void,
        onReindex: @escaping @Sendable () -> [AppItem],
        onQuit: @escaping @Sendable () -> Void
    ) {
        self.state = state
        self.onClose = onClose
        self.onReindex = onReindex
        self.onQuit = onQuit
        _apps = State(initialValue: apps)
    }

    private var isCommandMode: Bool {
        query.hasPrefix("/")
    }

    private var appResults: [AppItem] {
        rankedResults(apps: apps, query: query, state: state)
    }

    private var commandResults: [LauncherCommand] {
        matchingCommands(for: query)
    }

    private var ambiguousNames: Set<String> {
        duplicateAppNames(in: apps)
    }

    var body: some View {
        let commands = commandResults
        let items = appResults
        let duplicates = ambiguousNames
        VStack(spacing: 0) {
            searchField(commands: commands, items: items)
            resultsView(commands: commands, items: items, duplicates: duplicates)
        }
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(.white.opacity(0.1)))
        .frame(width: 600)
        .frame(maxHeight: .infinity, alignment: .top)
        .onChange(of: query) { selection = 0 }
        .onAppear { DispatchQueue.main.async { focused = true } }
    }

    private func searchField(commands: [LauncherCommand], items: [AppItem]) -> some View {
        let resultCount = isCommandMode ? commands.count : items.count
        return TextField("Search apps…", text: $query)
            .textFieldStyle(.plain)
            .font(.system(size: 22))
            .padding(14)
            .focused($focused)
            .onSubmit { activate(commands: commands, items: items) }
            .onKeyPress(.downArrow) {
                selection = min(selection + 1, max(resultCount - 1, 0))
                return .handled
            }
            .onKeyPress(.upArrow) {
                selection = max(selection - 1, 0)
                return .handled
            }
            .onExitCommand { onClose() }
    }

    @ViewBuilder
    private func resultsView(
        commands: [LauncherCommand],
        items: [AppItem],
        duplicates: Set<String>
    ) -> some View {
        if isCommandMode {
            if !commands.isEmpty {
                Divider()
                VStack(spacing: 0) {
                    ForEach(Array(commands.enumerated()), id: \.element.id) { i, command in
                        HStack(spacing: 10) {
                            Text(command.token)
                                .font(.system(size: 16, design: .monospaced))
                            Text(command.summary)
                                .font(.system(size: 13))
                                .foregroundStyle(.secondary)
                            Spacer(minLength: 0)
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 6)
                        .background(i == selection ? Color.accentColor.opacity(0.35) : .clear)
                        .contentShape(Rectangle())
                        .onTapGesture {
                            selection = i
                            run(command)
                        }
                    }
                }
                .padding(.vertical, 4)
            }
        } else if !items.isEmpty {
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

    private func activate(commands: [LauncherCommand], items: [AppItem]) {
        if isCommandMode {
            guard commands.indices.contains(selection) else { return }
            run(commands[selection])
        } else {
            launch(items)
        }
    }

    private func run(_ command: LauncherCommand) {
        switch command {
        case .update:
            apps = onReindex()
            query = ""
            selection = 0
        case .quit:
            onQuit()
        }
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
