# Agents

A small macOS overlay (macOS 14+) that shows Claude subscription usage (session / week / model-specific
weekly limits) for **multiple accounts** as a pixel strip in a warm Mechanoonna look (amber, red only for critical limits)
at the **right screen edge**. Hovering the strip expands it and shows
details (percentages, reset times). No Dock icon – just the overlay and a menu bar item.

## Build & run

```sh
swift build                 # debug build
scripts/build-app.sh        # release → build/Agents.app (ad-hoc signed)
scripts/run.sh              # build-app + (re)launch
scripts/run.sh --demo       # launch with demo data
```

CLI flags (directly on the binary, e.g. `build/Agents.app/Contents/MacOS/Agents`):

| Flag | Effect |
|---|---|
| `--dump` | print discovered accounts and parsed meters, then exit |
| `--snapshot <path.png>` | render the overlay to a PNG, then exit |
| `--demo` | demo data, no polling |

## Multiple accounts

Claude Code creates one keychain entry per config directory
(`Claude Code-credentials`, `Claude Code-credentials-<hash>`). Agents finds all of them automatically.

Add a new account:

```sh
CLAUDE_CONFIG_DIR=~/.claude-work claude    # then in Claude Code: /login
```

Handy as an alias in `~/.zshrc`:

```sh
alias claude-work='CLAUDE_CONFIG_DIR=~/.claude-work claude'
alias claude-privat='CLAUDE_CONFIG_DIR=~/.claude-privat claude'
```

The account shows up in the overlay on the next refresh. Names (aliases), visibility and
order are configured under **Settings…**.

## Menu (menu bar, or right/Option-click on the strip)

- One line per account, e.g. `KODE · WEEK 92% · FABLE 100%`
- Menu bar text: lowest **remaining** percentage across all accounts
- **Refresh now** (⌘R), **Show/Hide overlay**, **Scanlines** on/off
- **Screen** – which display the strip sits on (default: main display with the menu bar)
- **Settings…** – aliases, visible/hidden, order, poll interval (60/120/300 s), scanlines
- **Launch at login** (only from `Agents.app`, via `SMAppService`)
- **Add account…** – instructions + "Copy command"
- **Quit**

## Notes

- **Read-only:** tokens are read from the keychain (via `/usr/bin/security`) and **never** refreshed
  or written. If a token has expired, Agents shows the last values as "stale" –
  just start `claude` briefly in that account and Claude Code renews the token.
- Data source: `https://api.anthropic.com/api/oauth/usage` (the same one `/usage` in Claude Code uses).
- On first access macOS may ask for keychain permission for `security` – choose "Always Allow".
- Pixel font: Silkscreen (SIL Open Font License, see `Sources/Agents/Resources/OFL.txt`).
