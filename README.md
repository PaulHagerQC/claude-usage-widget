# ClaudeUsage — floating usage bars for macOS

A small always-on-top panel showing your Claude limits: current session (5-hour), weekly (all models), and any other limit your account reports (e.g. per-model weekly limits, extra usage). Refreshes every 60 s.

Works on Apple Silicon and Intel Macs, macOS 12+.

Unofficial community tool — not affiliated with or endorsed by Anthropic.

## Install

1. Download `ClaudeUsage.zip` from the [latest release](https://github.com/PaulHagerQC/claude-usage-widget/releases/latest), unzip it and move `ClaudeUsage.app` to `~/Applications` (or `/Applications`).
2. The app isn't notarized by Apple, so the first time macOS will block it. Either:
   - right-click the app → **Open** → **Open**, or if that doesn't offer Open, go to System Settings → Privacy & Security and click **Open Anyway**; or
   - run once in Terminal:
     ```bash
     xattr -dr com.apple.quarantine ~/Applications/ClaudeUsage.app
     ```
3. Open it. It has no Dock icon — look for the panel in the top-right corner of your screen.

Optional: System Settings → General → Login Items → add ClaudeUsage so it starts at login.

## Sign in (one time)

The widget reads your usage through the **Claude Code** login in your keychain. Signing in to the Claude desktop app is not enough — the terminal `claude` command needs to be signed in to your claude.ai account:

1. In Terminal run `claude`, type `/login`, pick your **Claude account** and finish in the browser.
   (No Claude Code yet? Install it from https://claude.com/claude-code.)
2. Right-click the widget → **Refresh now**. When macOS asks whether ClaudeUsage may use the "Claude Code-credentials" keychain item, choose **Always Allow**.

The login lasts about 8 hours and is renewed whenever `claude` runs. If the widget says the login expired, run `claude` in Terminal for a moment, then **Refresh now**.

If Claude Code is set up to use AWS Bedrock or an API key instead of a claude.ai login, there are no claude.ai limits to show, so the widget can't work for that setup.

## Using it

- **Drag** it anywhere — the position is remembered.
- **Resize it from any edge or corner**, like a normal window. Wider stretches the bars; taller makes the text bigger. When bars are shown/hidden the height adjusts and the text size stays.
- **Right-click** (or Ctrl-click) for all options:
  - **Refresh now**
  - **Show bars** — tick which limits to display
  - **Size** — Small / Medium / Large presets (or resize from the edges for anything in between)
  - **Compact layout** — one line per bar (hover a bar to see its reset time)
  - **Opacity** — 100 / 85 / 70 / 50 %
  - **Show details** — percentages, reset times, "last updated" line
  - **Refresh every** — 30 s / 1 / 2 / 5 min
  - **Keep on top**, **Reset settings**, **Quit**

Settings are saved and kept across restarts.

## Build from source

```bash
bash build.sh          # builds ClaudeUsage.app
bash build.sh --zip    # also makes ClaudeUsage.zip to share
```

Needs the Xcode Command Line Tools (`xcode-select --install`).

## Notes

It calls the same internal endpoint Claude Code uses for `/usage` (`api.anthropic.com/api/oauth/usage`), not a public API, so it could change. Every field with a `utilization` value becomes a bar, so new limits show up automatically. If something breaks, the error appears in the panel. Your token never leaves your Mac except to that endpoint.
