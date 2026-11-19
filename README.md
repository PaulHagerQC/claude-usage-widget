# ClaudeUsage — floating usage bars for macOS

A small always-on-top panel showing your Claude limits, one line per limit:

- **Current session** — the 5-hour limit
- **Weekly · all models**
- **Weekly · Fable** (or other per-model weekly limits your plan has)
- **Extra usage (credits)** — pay-as-you-go credits used this month, if enabled (hover for the dollar amounts)

Refreshes every 60 s.

Works on Apple Silicon and Intel Macs, macOS 12+.

Unofficial community tool — not affiliated with or endorsed by Anthropic.

## Install

1. Download `ClaudeUsage.zip` from the [latest release](https://github.com/PaulHagerQC/claude-usage-widget/releases/latest), unzip it and move `ClaudeUsage.app` to `~/Applications` (or `/Applications`).

   Optional — check the download is the published one: download `ClaudeUsage.zip.sha256` from the same release into the same folder and run
   ```bash
   cd ~/Downloads && shasum -a 256 -c ClaudeUsage.zip.sha256
   ```
   It should print `ClaudeUsage.zip: OK`. (The checksum is also in the release notes.) Prefer not to trust a prebuilt app at all? See [Build from source](#build-from-source).
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
2. Right-click the widget → **Refresh now**. There is no keychain prompt: the widget reads the login the same way Claude Code does.

After that the widget keeps itself signed in: when the login is about to expire (every ~8 hours) it renews it, the same way Claude Code does. You only need `/login` again if you log out of Claude Code or the renewal stops working.

If Claude Code is set up to use AWS Bedrock or an API key instead of a claude.ai login, there are no claude.ai limits to show, so the widget can't work for that setup.

## Using it

- **Drag** it anywhere — the position is remembered.
- **Resize it from any edge or corner**, like a normal window. Wider stretches the bars; taller makes the text bigger. When bars are shown/hidden the height adjusts and the text size stays.
- **Right-click** (or Ctrl-click) for all options:
  - **Refresh now**
  - **Show bars** — tick which limits to display
  - **Compact layout** — on by default: one line per bar with time to reset (e.g. `2h`, `6d`; hover for the exact time). Turn off for the larger layout with reset times under each bar
  - **Opacity** — slider, 20–100 %
  - **Show details** — percentages, reset times, "last updated" line
  - **Refresh every** — 30 s / 1 / 2 / 5 min
  - **Keep on top**, **Reset settings**, **Quit**

Settings are saved and kept across restarts.

## Security & permissions

The app asks for as little as possible:

| What | Access |
|---|---|
| **Keychain** | Uses one item, `Claude Code-credentials`, through Apple's `/usr/bin/security` tool — the same way Claude Code does. (Claude Code's item only trusts Apple's tools, so going through the keychain API would make macOS ask for your password on every refresh.) Keeps only the access token and its expiry in memory. When the login is about to expire it renews it and saves the new tokens back into the same item, changing only the token fields. |
| **Network** | Talks to exactly two Anthropic addresses: `https://api.anthropic.com/api/oauth/usage` (reads your usage) and `https://platform.claude.com/v1/oauth/token` (renews the login, about every 8 hours). Redirects are refused, nothing is cached, no cookies, no analytics. |
| **Files** | None. The app runs in the macOS **App Sandbox** with only the "outgoing network connections" permission, so it can't read your files, even if it wanted to. Its settings live in `~/Library/Containers/local.claude-usage-widget`. |
| **Other programs** | Only Apple's `/usr/bin/security`, to read that item when the token is missing or expired and to save a renewed login. It runs inside the same sandbox. The new tokens are passed to it through a pipe, never on the command line. |

Renewal tokens can only be used once. The widget re-reads the item right before renewing (Claude Code may just have done it) and only saves if nothing changed in between. If both still renew at the same instant, one of them can end up logged out — run `/login` again.

Note that the sandbox doesn't stop the widget from reading or changing that item: Claude Code's item lets Apple's `security` tool read it and any app change it. The limits above are kept by the code, which you can read.

What it *can't* restrict: the token itself. It's Claude Code's login token, which can do anything Claude Code can do with your account, not just read usage. Anthropic doesn't offer a read-only "usage" token, so the app protects it by the rules above instead. The code is one file — [ClaudeUsage.swift](ClaudeUsage.swift) — so you can check all of this yourself.

## Build from source

```bash
bash build.sh          # builds ClaudeUsage.app
bash build.sh --zip    # also makes ClaudeUsage.zip to share
```

Needs the Xcode Command Line Tools (`xcode-select --install`). The app is signed ad hoc with the sandbox entitlements in [ClaudeUsage.entitlements](ClaudeUsage.entitlements).

## Notes

It calls the same internal endpoint Claude Code uses for `/usage` (`api.anthropic.com/api/oauth/usage`), not a public API, so it could change. Every limit the endpoint reports becomes a bar, so new limits show up automatically. If something breaks, the error appears in the panel.

## License

MIT — see [LICENSE](LICENSE).
