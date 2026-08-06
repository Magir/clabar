# CLAUDE.md — project guide

Clabar: macOS menu bar app (SwiftUI, macOS 14+, SPM executable — no Xcode
project). Shows Claude usage limits + receives Claude Code hook events as
native notifications. UI is localized RU/EN via inline `L("ру", "en")` pairs.

Conventions: **commit messages are written in English** (public repo). Code,
comments and docs are English too; only user-facing UI strings carry the
RU/EN pairs.

## Commands

```sh
swift test        # unit tests (fast, no network, no system writes)
make app          # release build → build/Clabar.app (ad-hoc signed, updater OFF)
make run          # build + open
make clean
```

**Dev launches must be isolated** — a plain launch auto-installs hooks into
`~/.claude/settings.json` and writes data to `~/.config/clabar`:

```sh
CLABAR_NO_AUTOINSTALL=1 CLABAR_DATA_DIR=/tmp/clabar-dev ./build/Clabar.app/Contents/MacOS/Clabar
```

`CLABAR_DEBUG_OPEN=settings|log` opens that window ~1s after launch and dumps
`clabar-debug window=... visible=... key=...` lines to **stderr** (stdout is
buffered and lost on SIGTERM) — use it to verify windows actually present.

Smoke-test the event pipeline without Claude:

```sh
curl -s http://127.0.0.1:8737/ping   # → "clabar"
curl -s -X POST http://127.0.0.1:8737/event -H "Content-Type: application/json" \
  --data '{"hook_event_name":"Stop","session_id":"s","cwd":"/tmp","last_assistant_message":"hi"}'
```

## Releases & versioning

Version comes from the git tag only — nothing in the repo carries it.

```sh
git tag vX.Y.Z && git push --tags
```

GitHub Actions (`release.yml`, runner macos-15) then: builds with
`APP_VERSION`, `SU_FEED_URL` and `SPARKLE_PUB_KEY` stamped into Info.plist,
runs a launch smoke test, generates the EdDSA-signed `appcast.xml` and
attaches BOTH `Clabar.zip` and `appcast.xml` to the GitHub Release. The feed
URL is `releases/latest/download/appcast.xml` — no GitHub Pages involved
(Pages was abandoned: its deployments queued 10-25 min against the deploy
action's hard 10-min cap, and a cancelled run's deployment once landed late
and overwrote a newer one). Requires repo variable `SPARKLE_PUBLIC_KEY` +
secret `SPARKLE_PRIVATE_KEY`; if missing, the release still publishes but
without auto-updates (warning). Builds ≤0.1.5 still point at the legacy
Pages feed — those users reinstall once via install.sh.
README's install link `releases/latest/download/Clabar.zip` always serves the
newest release; `install.sh` (curl one-liner in README) installs without
Gatekeeper friction — curl-downloaded files carry no quarantine attribute,
browser downloads do. To move a tag: delete it on the remote first
(`git push origin :refs/tags/vX.Y.Z`), then re-tag and push.

`build.yml` runs `swift build && swift test` on every push — CI Swift is
OLDER than local (stricter concurrency checks); a green local build does not
guarantee CI. Never commit secrets: the Sparkle private key lives only in the
GitHub secret and the owner's Keychain.


## Architecture

Two data flows:

1. **Usage**: `UsageService` (OAuth PKCE, ported from Blimp-Labs/claude-usage-bar,
   BSD-2 — see LICENSE) polls `api.anthropic.com/api/oauth/usage` →
   `UsageResponse.decode` parses the modern `limits[]` array (kinds `session`,
   `weekly_all`, `weekly_scoped` + `scope.model.display_name`, e.g. Fable) with
   a legacy top-level-fields fallback. Buckets are fully dynamic — new models
   appear without code changes. → `HistoryService` (chart datapoints, 30 days).

2. **Events**: Claude Code hooks run `~/.claude/hooks/clabar-hook.sh` → POST
   JSON to `127.0.0.1:8737/event` (`EventServer`, hand-rolled minimal HTTP) →
   `EventClassifier.classify` (kind: ask/done/error/info) → `EventStore.add`
   (recording filter, dedupe, JSON persistence) → `Notifier` (banners with an
   Open-session action) and UI. Env context (TERM_PROGRAM, bundle id,
   remote flag) travels as `X-Clabar-*` HTTP headers set by the hook script.

Files (Sources/Clabar/):

- `ClabarApp.swift` — scenes (MenuBarExtra + Window "log"/"settings"), menu bar
  label, `presentFront`, `DockPolicy`, debug auto-open hook
- `AppModel.swift` — singleton wiring of all services; `SettingsKeys` + defaults
- `UsageModel/UsageService/StoredCredentials/HistoryService` — usage core (ported)
- `Events.swift` — event model, classifier, store (recording filter lives here)
- `EventServer.swift` / `Notifier.swift` / `SessionFocus.swift` — pipeline
- `HookInstaller.swift` — hook script content, settings.json merge (idempotent,
  cleans its own stale registrations), devcontainer.json patcher
- `Nudge.swift` — burn-the-limit + running-low computations (pure functions)
- `PopoverView/LogWindowView/SettingsView/ChartView/IconRenderer` — UI
- `L10n.swift` — `L()`, `Lang.locale`, `LangObserver`
- `AppUpdater.swift` — Sparkle (configured only when CI stamps feed URL + key)

## Hard-won pitfalls — do not regress

- **Hook curl stays in the FOREGROUND.** Claude Code kills the hook's process
  group on script exit; a backgrounded curl (`&` + `exit 0`) dies before
  connecting and events are silently lost. Interactive-shell testing lies about
  this (orphans survive there). Non-blocking comes from `async:true` in the
  registration. Applies to both copies: `HookInstaller.scriptContent` and
  `extras/clabar-container-setup.sh`.
- **SessionEnd is deliberately not subscribed** — its reason `"other"` fires on
  normal quits too, producing false "crashed" notifications.
- **MenuBarExtra label**: only the first standalone `Image` renders; icons must
  be embedded into `Text` (`Text(Image(systemName:))`). Plain unicode glyphs
  like ✉ may have no glyph in the menu bar font (renders as ✖).
- **MenuBarExtra(.window) panel drifts downward**: the panel anchors its BOTTOM
  edge, so every content-height change lets the top sag further below the menu
  bar. `MenuBarPanelSnapper` (NSViewRepresentable in PopoverView) re-pins the
  top on each render — keep it attached to the popover root.
- **Window presentation from the popover**: use `presentFront {}` — it flips the
  activation policy BEFORE opening (flipping after makes the window vanish),
  opens, closes the popover, then activates. The `Settings` scene is unusable in
  an LSUIElement app (silently no-ops) — settings is a plain `Window`.
- **Localization** (7 languages): call sites carry the ru/en pair inline —
  `L("ру", "en")`; es/pt/fr/de/uk live in `Translations.table` keyed by the
  EXACT English string (missing key → English fallback, so adding a string
  without a table entry degrades gracefully). Parameterized strings use
  `LT("… {n} …", "… {n} …", ["n": value])` with `{placeholder}` keys in the
  table. A test asserts every table entry covers all five languages. Every
  view calling `L()` must hold
  `@ObservedObject private var lang = LangObserver.shared` or it won't
  re-render on language switch; date/number formatting needs
  `.environment(\.locale, Lang.locale)` at the window root; segmented
  pickers additionally need `.id(...)` keyed on the language (NSSegmentedControl
  caches titles); window titles must come from content-level `.navigationTitle`.
- **devcontainer.json** may be JSONC (comments → show snippet, never rewrite)
  and `mounts` entries may be objects, not strings — treat as `[Any]`. Existing
  `CLAUDE_CONFIG_DIR` is respected: hooks go into that dir when its host path
  resolves (see `resolveHostPath`).
- **UserDefaults keys in tests**: pin `appLanguage` (labels are localized) and
  clean up in tearDown; `EventStore(directory:)` takes a temp dir.
- Notification permission is user-granted; the app must degrade gracefully
  without it.

## Data locations (user machine)

`~/.config/clabar/` — credentials.json (0600), history.json, notifications.json.
`~/.claude/hooks/clabar-hook.sh` + registrations in `~/.claude/settings.json`
(backup `settings.json.clabar-backup`). Override data dir: `CLABAR_DATA_DIR`.
