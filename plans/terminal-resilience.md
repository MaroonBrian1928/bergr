# Terminal resilience ideas

## Status (checked 2026-11-21)
- Connection revisions (`connectionRevision`): Done — bergr/Terminals/HostSession.swift:43-44, 586 (incremented on each successful connect).
- Revision-aware terminal reattachment: Done — bergr/Screen/TerminalScreenModel.swift:96-117 (`pumpConnectionRevision`); bergrIOS/Screen/TerminalScreenView.swift:185, 211 and bergrMac/App/ChatWindow.swift:75 observe it.
- Background recovery on foreground/wake: Done — HostSession.resumeAfterBackground (HostSession.swift ~417), pause/resume via intent; commit 8168e6d.
- Network-path-triggered recovery: Done (doc's "follow-up work" line is stale) — bergr/Terminals/NetworkWatcher.swift; bergrIOS/RootView.swift:190 calls `sessions.probeAll`; probe retries at once while backing off (ConnectionAttemptTests `probeRetriesAtOnceWhileBackingOff`); commits 49fa311, 2f9f223.
- Keep last frame and conversation visible during recovery: Partial — snapshot survives stop ("Reconnecting…") and bergr/Screen/ConnectionBar.swift shows state over the screen; not verified on device.
- Live / stale / reconnecting / needs-decision states with time since last server message: Partial — ConnectionBar.swift:10-40 shows state and "Last update <relative>" from `HostSession.lastHeardAt` (HostSession.swift:67-68, 595); no distinct "stale" state; host-key decision exists (`pendingHostKey`).
- Preserve drafts locally: Done — bergr/Chat/ReplyDrafts.swift; ChatView.swift:224-226 saves the draft on disappear; commit f1b36ab.
- No automatic replay of ambiguous commands or approvals: Partial — ReplyDelivery retry types text only when it is not already on screen (ReplyDelivery.swift retry); no general input-acknowledgement check for terminal input or approvals.
- Durable input acknowledgements: Not started — no acknowledgement protocol in HerdrKit or bergr sources.
- Coalesce display rendering while keeping every output byte: Partial — output coalescing exists (bergr/Screen/TerminalScreenModel.swift:492, "Coalesces bursts of output into one frame"); byte preservation not shown by a test.
- Measure input-to-screen latency and queued output: Not started — no latency or queue-depth metric found in bergr, bergrIOS, bergrMac, MacKit or HerdrKit sources.
- Adapt rendering to slow links; interrupt-responsiveness tests: Unclear — only network-cost-aware check intervals (HostSession.swift:389-400, 3 s / 6 s); no adaptive rendering or interrupt test found.
- Speculative local echo: Not started — no prediction code; only `inlinePredictionType = .no` in bergrIOS/Chat/ComposerField.swift:31.
- Required scenarios (locked phone, airplane mode, Wi-Fi/cellular, VPN, laptop sleep, keep-alive on/off, Windows/Linux/macOS hosts): Partial — keep-alive exists (bergrIOS/Background/KeepAlive.swift); Windows SSH fix in 8168e6d; no scenario test or device record in the repo, so the rest is Unclear.
- Simulate a quick reconnect between two view updates: Partial — `connectionRevision` exists for this; ConnectionAttemptTests has `connectedIsReportedBeforeTheDocumentsArrive` but no test for the coalesced-revision case.
- No Mosh source vendored or copied: Done — no mosh code in vendor/ or source folders; the only mentions are a comment (HostSession.swift:389) and an app name in demo data.
- Apache-2.0 licensing kept: Unclear — LICENSE and NOTICE exist at the repo root; not checked for changes.

Design references: [Mosh overview](https://github.com/mobile-shell/mosh/blob/master/README.md)
and [Mosh technical description](https://mosh.org/#techinfo).

Use these as behavioral references only. Implement independently against Bergr/herdr-core;
do not copy, translate, adapt, link or vendor Mosh source. Keep Bergr's Apache-2.0 licensing.

## First: recovery over the existing protocol

- Treat the remote terminal and conversation as durable state. A lost SSH connection replaces
  the transport, not the user's selected session, scroll position or draft.
- Keep the last frame and conversation visible during recovery. Show whether the connection is
  live, stale, reconnecting or requires a decision; include time since the last server message.
- On wake, foregrounding or a usable network-path change, reconnect, subscribe to a fresh
  snapshot, reattach the selected terminal, and restart its feed in place.
- Track connection revisions, not only connected/disconnected booleans. View updates can
  coalesce those booleans across suspension.
- Preserve drafts locally. Do not automatically replay an ambiguously delivered command or
  approval: the current protocol does not provide an exactly-once input acknowledgement.

The current change adds connection revisions, background recovery and revision-aware terminal
reattachment. Freshness UI (partial) and durable input acknowledgements remain follow-up work;
network-path-triggered recovery is in place (see Status).

## Then: responsiveness

- Coalesce display rendering while preserving every terminal byte sent through the emulator.
  Dropping arbitrary output bytes would lose terminal state. Latest-screen synchronization
  requires server support, not just discarding incoming SSH data.
- Measure input-to-screen latency and queued output. Adapt rendering to slow links and test
  interrupt responsiveness under sustained output.
- Explore speculative local echo only after recovery is reliable. Keep unconfirmed text
  visually distinct and reconcile it with authoritative terminal output. Password entry,
  full-screen programs, and agent approvals need explicit tests before enabling prediction.

## Required scenarios

Open chat, leave the app, let the agent continue, return without navigating. Repeat with
keep-alive enabled and disabled, phone locked, airplane mode, Wi-Fi/cellular switches, VPN
changes and laptop sleep. Repeat on native Windows, Linux and macOS hosts. Confirm no lost
drafts, repeated commands, duplicate approvals, stale input channels or navigation-dependent
recovery. Simulate a quick reconnect that occurs between two view updates.

Adopting Mosh's UDP transport would be a separate client/server protocol project. The first
improvements above fit Bergr's current SSH transport and persistent herdr terminals.
