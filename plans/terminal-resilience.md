# Terminal resilience ideas

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
reattachment. Network-path-triggered recovery, freshness UI and durable input acknowledgements
remain follow-up work.

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
