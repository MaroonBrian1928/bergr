# Handoff: native Apple Watch app

Status: **built, tested, not merged.** The code is on local branch `watch-app` (commit `abf1775`,
based on `ff654f1`; main has moved on, so rebase first). It is blocked only by signing.

## What it is

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

The new bundle ids (`com.brianriste.bergr.dev.watchkitapp` and its widget) with the App Group
`group.com.brianriste.bergr` need new development profiles. From the command line here, neither
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
profile then signs them). The complication would lose its shared count, so it would need another
source (e.g. the watch app writing its own `UserDefaults` via a shared container is not possible
without the group — consider showing only the app, no complication).

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
