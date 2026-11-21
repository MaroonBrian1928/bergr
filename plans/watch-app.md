# Handoff: native Apple Watch app

## Status (checked 2026-11-21)

- Watch app code (`bergrWatch/`, `SharedWatch/WatchLink.swift`): Done on branch `watch-app` — files present in its tree (`bergrWatch/AgentListView.swift`, `WatchModel.swift`, `BergrWatchApp.swift`); none on `main`.
- Complication (`BergrWatchWidget/`): Done on branch `watch-app` — `BergrWatchWidget/NeedsYouComplication.swift` reads the app-group defaults; not on `main`.
- WatchConnectivity data path (`updateApplicationContext` from `writeSnapshot`): Done on branch `watch-app` — `WatchBridge.swift` `push` (line 33); `LiveActivityController.swift` calls it from `writeSnapshot` (line 237 on branch). `main`'s `writeSnapshot` (line 236) has no push.
- Answers via `sendMessage`, sealed like the Live Activity, SSH fallback: Done on branch `watch-app` — `WatchModel.swift:57` `sendMessage`; `WatchBridge.swift:97-102`. The symbols it uses exist on `main`: `RemoteAnswer.intentAnswer`, `RemoteAnswerSender` (`bergr/Background/AnswerFlow.swift`).
- Replies via `AnswerFlow.reply`: Done on branch `watch-app` — `WatchBridge.swift:104-107` goes through `AgentIntentBridge.send`; `AnswerFlow.reply` is on `main` (`AnswerFlow.swift:256`).
- Dangerous commands and Esc get no buttons: Done on branch `watch-app` — `WatchBridge.swift:62` (no options when dangerous), `:93` (Esc refused); `DangerousCommand` is on `main` (`Shared/DangerousCommand.swift`); test `dangerousQuestionHasNoButtons`.
- Dictated reply field: Done on branch `watch-app` — `bergrWatch/AgentListView.swift` `TextField("Reply")`.
- Config (`Config/Watch*.plist`, entitlements with app group): Done on branch `watch-app` — both entitlements declare `group.$(BERGR_BUNDLE_ID_PREFIX).bergr`.
- Project targets and embed trap (`relative-path`): Done on branch `watch-app` — targets `bergrWatch` and `BergrWatchWidget` in `bergr.xcodeproj/project.xcproj`; embed copy uses `relative-path` `$(CONTENTS_FOLDER_PATH)/Watch` (line 74).
- `bergrTests/WatchBridgeTests` (9 tests): Done on branch `watch-app` (file present, 9 `@Test`s). That they pass is Unclear: not re-run here (no builds).
- Other "Verified" suites (LiveActivity, RemoteAnswer) and the unsigned device build: Unclear — not run here. `RemoteAnswerTests.swift` exists on `main`.
- Watch simulator / real-watch run: Not started — no watchOS runtime or run record in the repo.
- Signing blocker (Xcode accounts, development profiles for the new bundle ids): Unclear — profile state lives outside the repo; the entitlements that need it are on the branch.
- Fix: watch targets' `MARKETING_VERSION` equal to the iPhone app's: Not started — on `watch-app`, `bergrWatch` and `BergrWatchWidget` are 0.3.8 (project lines 262, 300) while the other targets are 0.3.9; `main` is 0.3.18 with no watch targets.
- Fix: watch in the dev profile, cached watch profiles deleted: Unclear — device registration and profile cache are outside the repo.
- Rebase onto `main`: Not started — `watch-app` tip `ac9429d` sits on `d0526c2` (Version 0.3.9), which is 52 commits behind `main`. The plan's base `ff654f1` is stale.
- Commit `abf1775`: Done on branch `watch-app`, under another hash — `abf1775` is on no branch or tag (reflog only). `ac9429d` carries identical watch paths (`git diff abf1775 ac9429d` is empty for them).
- Known limit "list shows at most 3 agents": Partial, plan number is stale — `WatchContext.maxAgents = 6` (`SharedWatch/WatchLink.swift:13`).
- Known limit "only the top agent gets answer buttons": Done on branch `watch-app` — options only for the prompt's row (`WatchBridge.swift:62`).
- Known limit "options other than Yes/No go over SSH": Done on branch `watch-app` — fallback at `WatchBridge.swift:101-102`; which options take the intent path is Unclear.
- Relay-driven or background updates for the watch list: Not started — no background or relay path on the branch; updates only come from `writeSnapshot`.

Status: **shelved (2026-11-15).** Built, tested, not merged. The code is on local branch `watch-app` (commit `abf1775`,
based on `ff654f1`; main has moved on, so rebase first). It is blocked only by signing.

## What it is

The files named here are on the `watch-app` branch, not on `main`.

A watchOS 11 app embedded in the iOS app, plus a complication:

- the needs-you agents, with Yes/No on the top one, a dictated reply, and the needs-you count on the
  complication;
- data comes from the phone over WatchConnectivity (`updateApplicationContext` from
  `LiveActivityController.writeSnapshot`); no secrets on the watch;
- answers go to the phone (`sendMessage`), which seals them like the Live Activity does
  (`RemoteAnswer.intentAnswer` + `RemoteAnswerSender`), falling back to SSH; replies go through
  `AnswerFlow.reply` (the safe path: typed only when the agent takes free text, else a draft);
- dangerous commands and Esc never get buttons.

Read `git show abf1775 --stat` for the files. Main pieces: `bergrWatch/`, `BergrWatchWidget/`,
`SharedWatch/WatchLink.swift` (shared types; `Shared/` has iOS-only code that won't compile for
watchOS), `bergrIOS/Background/WatchBridge.swift`, `Config/Watch*.{plist,entitlements}`, two new
targets in `bergr.xcodeproj/project.xcproj`.

Project-file trap: the embed copy phase needs `"relative-path": "$(CONTENTS_FOLDER_PATH)/Watch"`;
`path`/`subpath` are silently ignored and the app lands outside the bundle.

## Verified

`bergrTests/WatchBridgeTests` (9), plus LiveActivity and RemoteAnswer suites, pass; the unsigned iOS
device build embeds the watch app; the watch scheme builds for the watchOS SDK; the Mac build is
unaffected. Not run in a watch simulator (no watchOS runtime installed: `xcodebuild -downloadPlatform watchOS`).

## The blocker: signing

The new bundle ids (`<prefix>.bergr.dev.watchkitapp` and its widget) with the App Group
`group.<prefix>.bergr` need new development profiles. From the command line here, neither
route can create them:

- `just build` / `just phone`: "No Accounts" (Xcode's signed-in account isn't visible to
  `xcodebuild`), then the wildcard "iOS Team Provisioning Profile: *" lacks App Groups.
- Adding `-authenticationKeyPath/-ID/-IssuerID` (the ASC key from `.envrc.local`): "Authentication
  failed … bearer token" for `build`, although the same key works for `just archive true`.

Unblock (one time, needs the user): Xcode → Settings → Accounts signed in; check out the branch, open
the project, scheme **bergr**, **Any iOS Device**, Product → Build. Xcode creates and caches the
profiles; after that `just phone` works from the CLI. Then also run `just archive true` once to see
that distribution signing covers the watch targets.

Alternative if profiles can't be made: drop the App Group from the two watch targets (the wildcard
profile then signs them). The complication would lose its shared count and would need another source.
Without the group the watch app cannot read a shared container, so either find another source
or ship the app without a complication.

## Shelved, and why (2026-11-15)

It installed on the real watch only after three fixes, then was shelved: the watch list only
updates while the phone app runs, so without background keep-running it is mostly stale, and
alerts on the watch already carry answer buttons. Worth reviving only with relay-driven updates.

Fixes needed to install it (not on the branch yet; redo them):
- Signing: be signed in to Xcode → Settings → Accounts; then `just build` creates the profiles.
- The watch must be in the dev profile: it was registered through the App Store Connect API
  (its UDID); delete the cached watch profiles so new ones include it.
- Every target's `MARKETING_VERSION`/`CURRENT_PROJECT_VERSION` must equal the iPhone app's: the
  watch targets were still 0.3.8 (2) and the watch silently refused the install (progress fills,
  then back to "Install").

## Still to check on a real watch

Install via `just phone`; WatchConnectivity waking a backgrounded phone; dictation in the reply field;
complication refresh; the App Group shared between the watch app and complication.

Known limits: only the Live Activity's top agent gets answer buttons (the only question whose screen
the phone has read); the list shows at most 3 agents; numbered options other than Yes/No go over SSH
and the watch says "Sent" before knowing the press worked.

## Suggested skills

- `write-swift` — watchOS/WatchConnectivity concurrency and `@MainActor` isolation.
- `mattpocock-skills:diagnosing-bugs` — if signing or WatchConnectivity misbehaves on device.
- `apple-design` — watch layout once it runs on a real watch.
- `brians-skills:delegating-to-subagents` — if the rebase/fixes are split up.

Repo rules: `AGENTS.md` (bump `MARKETING_VERSION` before any install batch; install on phone and Mac).
