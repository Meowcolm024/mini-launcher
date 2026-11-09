# Launcher

A minimal rofi-like app launcher for macOS 14+. It indexes apps under `/Applications`, `/System/Applications`, and `~/Applications` (including nested folders and symlinks to bundles), ranks matches with fuzzy search, and boosts apps you’ve launched this session.

## Usage

Requires macOS 14+ and Swift 6.4+.

```bash
swift run
```

| Action | Shortcut |
| --- | --- |
| Show / hide | Option+Space |
| Move selection | ↑ / ↓ |
| Launch | Return |
| Dismiss | Esc, or click away |

Duplicate names show their path prefix (e.g. `/Applications` vs `~/Applications`) beside the title.

Type `/` to list commands, then select one and press Return. Command matching accepts prefixes and ignores case.

| Command | Action |
| --- | --- |
| `/refresh` | Rescan the application folders |
| `/quit` | Quit Launcher |

Launcher scans in the background at startup and caches the app list. Run `/refresh` after installing, moving, or removing apps. Indexing checks that each app bundle has an executable, accepts symlinks to app bundles with or without the `.app` suffix, and scans each physical folder once.

If hotkey setup fails, Launcher reports the error and exits with status 1.

While an app is opening, Launcher shows progress and prevents repeated launch requests. A successful launch closes the panel and boosts that app’s ranking for the session. A failed launch keeps your query and shows the error; missing apps include a reminder to run `/refresh`.

## Development

Run the tests with:

```bash
swift test
```
