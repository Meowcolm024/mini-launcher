# Launcher

A minimal rofi-like app launcher for macOS 14+. It indexes apps under `/Applications`, `/System/Applications`, and `~/Applications` (including nested folders and symlinks to bundles), ranks matches with fuzzy search, and boosts apps you’ve launched this session.

## Usage

```bash
swift run
```

Grant **Accessibility** (or Input Monitoring) if macOS asks — needed for the global hotkey.

| Action | Shortcut |
| --- | --- |
| Show / hide | Option+Space |
| Move selection | ↑ / ↓ |
| Launch | Return |
| Dismiss | Esc, or click away |

Duplicate names show their path prefix (e.g. `/Applications` vs `~/Applications`) beside the title.
