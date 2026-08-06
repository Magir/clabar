# Clabar

macOS menu bar app for Claude: usage limits at a glance + native notifications from Claude Code sessions.

The usage-tracking core is derived from [claude-usage-bar](https://github.com/Blimp-Labs/claude-usage-bar) (BSD-2-Clause), extended with a notification pipeline built on [Claude Code hooks](https://code.claude.com/docs/en/hooks).

## Features

- **Menu bar icon with a popover.** Customizable: mini usage bars, percentages as text (5-hour / weekly / Fable), unread notifications counter, 🔥/⚠️ status markers.
- **Usage limits**: the 5-hour window, the weekly window, and any per-model windows (Fable, Opus, …) the API reports — new limit types show up automatically. Usage history chart (1h–30d ranges).
- **Notifications from Claude Code** via hooks: asks (permission requests, questions, plan ready), task completion, failures — each with its own icon. System banners with action buttons on asks (Allow / Deny / Open). Clicking jumps to the app hosting the session (VS Code opens the right folder).
- **Notification history**: a separate window with a sortable table, filters by type / unread / free-text search. Double-click opens the session.
- **“Burn the limit” reminder**: when less than N% of the weekly window is used and the reset is under M hours away — 🔥 in the icon and a banner in the popover.
- **“Running low” warning**: the reverse — when any window (5-hour, weekly, per-model) is above a configurable threshold (85% by default), ⚠️ in the icon and a red banner.
- **Zero-config setup**: hooks are installed automatically on first launch. One-click DevContainer setup.
- **Localization**: English / Russian, auto-detected from the system with a manual override in Settings.

## Build & run

Requires macOS 14+ and Xcode (or Command Line Tools with Swift 5.9+).

```sh
make app          # builds build/Clabar.app
open build/Clabar.app
# optionally: cp -R build/Clabar.app /Applications/
```

First launch:

1. Allow **notifications** when prompted.
2. Click **“Sign in with Claude”** in the popover — OAuth in the browser, paste the code back.
3. Hooks are installed into `~/.claude/settings.json` automatically (backup: `settings.json.clabar-backup`).
4. For the experimental keystroke answers (⏎ Allow / ⎋ Deny actually pressing keys in the session), enable the option in Settings and grant Clabar the **Accessibility** permission. Off by default — the buttons just focus the session.

## How it works

Claude Code hooks (`Notification`, `Stop`, `PermissionRequest`, `PreToolUse` for AskUserQuestion/ExitPlanMode, `PostToolUseFailure`) invoke `~/.claude/hooks/clabar-hook.sh`, which POSTs the event JSON to `http://127.0.0.1:8737/event` (fire-and-forget — it never blocks or breaks the session). The app classifies the event, appends it to the log, and shows a banner.

## DevContainers (VS Code)

Settings → Integration → **“Set up a project…”** patches the project's `devcontainer.json`:

```jsonc
"mounts": [
  "source=${localEnv:HOME}/.claude,target=/clabar/claude-config,type=bind"
],
"containerEnv": {
  "CLAUDE_CONFIG_DIR": "/clabar/claude-config",
  "CLABAR_HOST": "host.docker.internal"
}
```

The host `~/.claude` is mounted into the container and `CLAUDE_CONFIG_DIR` makes Claude Code use it — settings, hooks and login travel both ways automatically. Notifications from the container reach the host via `host.docker.internal` (Docker Desktop). If `devcontainer.json` contains comments, the file is not rewritten — a snippet is shown for manual pasting. Rebuild the container after patching. The container needs `curl` (present almost everywhere).

If the project already sets its own `CLAUDE_CONFIG_DIR`, Clabar keeps it: only `CLABAR_HOST` is added, and the hooks are installed directly into that config when its host path can be resolved (a folder inside the workspace, or a declared bind mount). Existing `mounts` (including object entries) are preserved.

### Custom DevContainer (Claude config on a named volume)

If the container's `.claude` lives on a docker named volume and can't be replaced with a bind mount, Clabar can't reach it from the host — install the hooks **from inside the container**. The container needs three things:

1. the hook script and its registration in the `settings.json` of whatever config Claude Code actually uses in the container (`$CLAUDE_CONFIG_DIR`, `~/.claude` by default);
2. `CLABAR_HOST=host.docker.internal` so events reach the host;
3. `curl` in the image.

Step by step:

1. Copy [`extras/clabar-container-setup.sh`](extras/clabar-container-setup.sh) into your project's `.devcontainer/`. The script is idempotent: it writes `hooks/clabar-hook.sh` and carefully merges the hook registration into `settings.json` without touching your existing hooks (needs `python3` in the image — present in nearly all devcontainer images).

2. Add to `devcontainer.json`:

   ```jsonc
   "containerEnv": {
     "CLABAR_HOST": "host.docker.internal"
   },
   "postStartCommand": "sh .devcontainer/clabar-container-setup.sh"
   ```

   `postStartCommand` (not `postCreateCommand`) makes the setup self-healing on every start: the volume survives rebuilds, but a fresh `settings.json` after `claude logout`/reset doesn't.

3. Rebuild the container (**Dev Containers: Rebuild Container**). The startup log will show `Clabar hooks installed into …`.

Check from inside the container: `curl -s -m 2 http://host.docker.internal:8737/ping` should answer `clabar`. On Docker Desktop this works out of the box; on plain Docker/colima add `"runArgs": ["--add-host=host.docker.internal:host-gateway"]`.

If the image has no `python3`, add the hooks to the volume's `settings.json` manually once (create `clabar-hook.sh` with the same heredoc from `clabar-container-setup.sh`):

```json
"hooks": {
  "Notification":       [{ "hooks": [{ "type": "command", "command": "sh \"${CLAUDE_CONFIG_DIR:-$HOME/.claude}/hooks/clabar-hook.sh\"", "async": true, "timeout": 5 }] }],
  "Stop":               [{ "hooks": [{ "type": "command", "command": "sh \"${CLAUDE_CONFIG_DIR:-$HOME/.claude}/hooks/clabar-hook.sh\"", "async": true, "timeout": 5 }] }],
  "PermissionRequest":  [{ "hooks": [{ "type": "command", "command": "sh \"${CLAUDE_CONFIG_DIR:-$HOME/.claude}/hooks/clabar-hook.sh\"", "async": true, "timeout": 5 }] }],
  "PreToolUse":         [{ "matcher": "AskUserQuestion|ExitPlanMode", "hooks": [{ "type": "command", "command": "sh \"${CLAUDE_CONFIG_DIR:-$HOME/.claude}/hooks/clabar-hook.sh\"", "async": true, "timeout": 5 }] }],
  "PostToolUseFailure": [{ "hooks": [{ "type": "command", "command": "sh \"${CLAUDE_CONFIG_DIR:-$HOME/.claude}/hooks/clabar-hook.sh\"", "async": true, "timeout": 5 }] }]
}
```

Note: with a named volume, notifications and limits work fully, but the Claude login/settings inside the volume are not synced with the host — that's a property of named volumes, not something Clabar changes.

## Data locations

| What | Where |
|---|---|
| OAuth tokens | `~/.config/clabar/credentials.json` (0600) |
| Usage history | `~/.config/clabar/history.json` (30 days) |
| Notification log | `~/.config/clabar/notifications.json` (last 2000) |
| Hook script | `~/.claude/hooks/clabar-hook.sh` |

Nothing leaves your machine except the usage requests to the Anthropic API.

## Environment variables

- `CLABAR_DATA_DIR` — override the app data directory.
- `CLABAR_NO_AUTOINSTALL=1` — don't install hooks automatically.
- `CLABAR_HOST` / `CLABAR_PORT` — where the hook script sends events (containers / non-default port).

## Distribution & auto-updates

Releases are distributed via GitHub Releases; in-app auto-updates use [Sparkle](https://sparkle-project.org) with an appcast on GitHub Pages. Update archives are EdDSA-signed — no Apple Developer ID required (the app itself stays ad-hoc signed: on first launch of a downloaded build, right-click → Open to pass Gatekeeper).

One-time setup for a fork:

1. Push the repo to GitHub. In **Settings → Pages** set Source to **GitHub Actions**.
2. Generate Sparkle keys locally (stored in your Keychain):

   ```sh
   swift build   # fetches Sparkle and its tools
   .build/artifacts/sparkle/Sparkle/bin/generate_keys        # prints the public key
   .build/artifacts/sparkle/Sparkle/bin/generate_keys -x sparkle-private.key
   ```

3. In **Settings → Secrets and variables → Actions** add:
   - variable `SPARKLE_PUBLIC_KEY` — the printed public key;
   - secret `SPARKLE_PRIVATE_KEY` — contents of `sparkle-private.key` (then delete the file; the key also stays in your Keychain).
4. Ship: `git tag v0.1.0 && git push --tags`. The workflow builds the app with the feed URL and public key stamped in, attaches `Clabar.zip` to the release, and publishes `appcast.xml` to GitHub Pages. Installed release builds check for updates automatically and via Settings → “Check for updates…”.

Local `make app` builds have the updater disabled (no feed/key stamped) — Settings shows “Local build”.

## Development

```sh
swift test   # unit tests (bucket parsing, nudges, hook merging, classification, dedupe)
make app     # release .app build
```

## License

BSD 2-Clause — see [LICENSE](LICENSE). Portions derived from [claude-usage-bar](https://github.com/Blimp-Labs/claude-usage-bar) (BSD-2-Clause), original license reproduced in the LICENSE file.
