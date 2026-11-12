# Mosh ideas for Bergr

Follow-up to `terminal-resilience.md`. Sources: the Mosh paper (USENIX ATC 2012), mosh.org and the
Mosh README, as behavioral references only. Mosh is GPL: nothing here is taken from its source, and
nothing should be. Mosh numbers below are quoted from memory of the paper; check them before using
them as constants. herdr-core's source was not read: what it does when a viewer runs out of credit
is an open question (marked "to confirm").

Fixed constraints: SSH + herdr-core stay, no UDP transport. herdr-core changes can be proposed.

## Ranking

| # | Idea | Where | Benefit | Cost | Verdict |
|---|------|-------|---------|------|---------|
| 1 | Last-contact indicator in the terminal view, driven by a faster liveness signal | client; optional core heartbeat option | No typing into a dead line; dead line seen in ~3-5 s instead of up to 40 s | small | do now |
| 2 | Round-trip time estimate per connection | client | Foundation for 1, 5, 7; a number for the "responsiveness" section | small | do now |
| 3 | Grant credit after the emulator consumed the bytes | client (HerdrKit) | Bounded memory, real backpressure, precondition for 4 | small | do now |
| 4 | Skip to the latest screen when a viewer is behind | herdr-core + small client part | Ctrl-C and typing stay responsive under output floods on slow links | medium (core) | needs herdr-core, propose first |
| 5 | Input sequence numbers with an echo acknowledgement | herdr-core + client | Exact "was my input delivered" after a reconnect; makes 6 reliable | medium (core) | needs herdr-core, propose with 4 |
| 6 | Predictive local echo in the terminal | client; much better with 5 | Typing feels instant on cellular | large, risky | later, after 2 and 5 |
| 7 | Output pacing by round-trip time on the core side | herdr-core | Less data on slow links, fewer wasted frames | medium | later, falls out of 4 |
| 8 | Incremental reattach (history and screen since a known state) | herdr-core + client | Faster, cheaper comeback on cellular | medium | later |
| 9 | Optimistic "sending" state for chat messages and approvals | client; exact with 5 | Chat feels immediate, no doubt about delivery | small-medium | later, check what exists |
| 10 | Roaming substitute: Multipath TCP | client + host setup | Wi-Fi to cellular without a reconnect | unknown | experiment only |
| 11 | UDP state-sync transport, own encryption | both | true roaming | very large | skip |
| 12 | Dropping scrollback, client-side byte dropping, local line editing | - | - | - | skip |

## 1. Last-contact indicator and faster liveness (do now)

Mosh: each side sends something at least every 3 s. When the client has heard nothing for a few
seconds it draws a bar over the top row, "last contact N seconds ago", and keeps the last screen up.
It also knows when its own packets are not being acknowledged, and says so separately.

Bergr today: the core's heartbeat comes every 15 s, the silence limit is 40 s
(`ConnectionAttempt.swift`, `silenceLimit`), a network change triggers a 3 s probe
(`HostSession.probe`), and the chat has a staleness bar. Between those, a line that dies without a
path change (tunnel, train, host asleep) looks live for up to 40 s, and the terminal view takes keys
into it.

Concretely:
- While a terminal or chat is on screen and the app is active, send a cheap request every ~3 s
  (what `probe` does now with `terminal.list`; a dedicated `ping` in the core would be lighter).
  Not in the background: battery, and iOS suspends the sockets anyway.
- Publish "last heard" from `ConnectionAttempt` (it already keeps `lastHeard`) through
  `HostSession`, counting any frame on any channel, and show the same bar in the terminal view
  (`TerminalCanvas.swift` overlay on iOS, the Mac equivalent) as in the chat.
- Two states, like Mosh: "no answer for N s" (still trying) and "reconnecting". An unanswered ping
  after ~2 x the measured round trip (floor 3 s) starts the existing `retry`.
- Also trigger a ping on the first key after a pause of more than a few seconds: the moment the user
  cares most.

## 2. Round-trip estimate (do now)

Mosh: timestamps in every packet give a smoothed round-trip time and its variation, TCP style; send
rate, retransmit timeout and the prediction display all depend on it.

Bergr: time every request/response in `HerdrClient.call` (the id is already matched) and keep a
smoothed value and variation per client; the 3 s pings from idea 1 keep it fresh. Expose it on
`HostSession`. Use it for the probe deadline, for the staleness bar, later for prediction (6). Show
it in a debug overlay first: that is the "measure input-to-screen latency" item in the resilience
plan. Caveat: over TCP a lost packet shows up as a latency spike, not as loss; treat spikes as the
signal.

Input-to-echo latency for a typed key can only be measured exactly with idea 5.

## 3. Credit after consumption (do now, small)

Mosh: nothing queues. The sender always sends the newest state, so there is no backlog to drain.

Bergr: `HerdrClient.attach` yields a chunk into an unbounded `AsyncThrowingStream` and sends the
CREDIT frame at once, before `TerminalScreenModel.run` has fed it to the emulator. The core's flow
control therefore never sees a slow client: under sustained output the backlog sits in the app's
memory, and every byte of it is parsed before the screen is current. Send the credit when the
consumer has taken the chunk (after `vt.write`), or bound the stream. Rendering is already coalesced
(8 ms while drawing, 100 ms otherwise, `scheduleRender`), which matches Mosh's finding that a short
collection window after the first write avoids drawing half-finished updates.

## 4. Skip to the latest screen (needs herdr-core; the main Mosh idea)

Mosh: the server keeps the terminal's screen as an object and sends the difference between the
state the client is known to have and the current one, at a paced rate. Intermediate states are
never sent. That is why Ctrl-C works at once after `cat bigfile`: there is no queue of output
between the key and its effect.

Bergr: the core already emulates the terminal (attach starts with "the current screen", the first
paint). What is missing is using that mid-stream. Proposal to herdr-core:
- Per viewer, when unsent output exceeds a threshold (no credit, or more than about one screen's
  worth of repaint queued), drop that viewer's backlog and send a marker plus a fresh first paint
  of the current screen. To confirm: what the core does today without credit (block the program,
  buffer without bound, or drop the viewer).
- Feature flag in `hello.features` (like `automatic_input`), opt-in per attach.
- Client: on the marker, reset the `VirtualTerminal` and feed the paint, as on attach. Scrolled-off
  lines that were skipped are lost to this viewer unless the paint includes history (see 8).
- Input must not wait behind output: confirm the core reads viewer input while its output side is
  blocked.

This is the byte-stream version of state sync: full repaint on demand instead of general diffs.
Full diffs between numbered states are not worth it over TCP: delivery is reliable and ordered, so
the only useful "diff base" is "what I already sent".

The client alone cannot do this: dropping bytes corrupts emulator state (already noted in the
resilience plan).

## 5. Input sequence and echo acknowledgement (needs herdr-core)

Mosh: keystrokes are a numbered stream. The server reports which input it has delivered to the
program, and marks it only after the program had ~50 ms to react. The client uses that to decide
whether a prediction was right, and never needs to guess from timing.

Proposal to herdr-core: an input frame kind carrying a client sequence number, and an ack (frame on
the same channel, or a field in the next output frame) "input up to N was written to the program,
at least T ms ago". Persist the last N per viewer identity across reattach.

Uses in Bergr:
- The "durable input acknowledgements" follow-up in the resilience plan: after a reconnect the
  client asks for the last delivered N and knows whether a command or approval went through, so it
  can resend what did not, exactly once (`TerminalScreenModel.pendingInput`, chat answers).
- Exact input-to-screen latency.
- Confirmation rule for predictions (6).

Note: `TerminalScreenModel.send` starts one unstructured `Task` per key; sequence numbers need a
single ordered sender.

## 6. Predictive local echo (later)

Mosh's rules, as behavior:
- Predicted: printable characters, backspace, left/right arrow. Everything else is not.
- Predictions belong to an epoch. A new epoch starts at anything that may change how the program
  reacts: Enter, Escape, up/down, control keys, a resize. A new epoch is tentative: its predictions
  are computed but hidden until the server confirms one of them. So at a password prompt (no echo)
  or in a program that does not echo, the first prediction never confirms and nothing is shown.
- Confirmed by comparing the predicted cells with the authoritative screen once the echo ack covers
  the key. A wrong prediction is removed at once, and the epoch goes back to tentative.
- Display is adaptive: nothing below roughly 30 ms round trip; shown above; underlined above
  roughly 80 ms or when a prediction stays unconfirmed for long. Hysteresis on both thresholds.
- No prediction across the right margin (wrap is ambiguous), and conservative with wide characters.
- Paper result: about 70% of keys shown at once, under 1% wrong, median latency from ~500 ms to
  near zero on a cellular link.

Bergr: an overlay layer in `TerminalScreenModel` on top of `ScreenFrame` (never written into the
emulator), drawn by `TerminalCanvas` with the underline. Extra off-switches Bergr has and Mosh
lacks: `inLogin` (already computed), alternate screen and mouse modes from libghostty-vt, the
foreground program from the core's `foreground` event (off for agents' approval prompts), and
`watching`. Without idea 5 confirmation is by timeout and screen comparison only, which is where
mispredictions come from: build it after 5, behind a setting, default off, with the tests the
resilience plan lists (password, full-screen programs, approvals).

Value check: agents are driven mostly through the chat composer, already local editing.
Prediction pays only for shell work in the terminal view on bad links.

## 7-10. Later

- **7, output pacing (core).** Mosh's frame interval is half the smoothed round trip, between 20
  and 250 ms, with acks delayed ~100 ms to ride along with data. Over TCP the transport does most
  of this; the rest is per-viewer coalescing in the core, which idea 4 gives in its simplest form.
- **8, incremental reattach (core).** Every reattach asks for 1000 history lines (`historyLines`)
  plus the paint: the visible comeback delay on cellular. Proposal: a history position in the
  attach result and "history since P" on the next attach, so the client keeps its emulator and
  scrollback while P is valid.
- **9, optimistic chat state.** The chat analogue of prediction: a sent message or approval shows
  at once as "sending", is confirmed by the transcript (`ChatFeed`), and after a reconnect turns
  into "not delivered, send again?" instead of being replayed. Exact with idea 5. Not checked how
  much `ChatFeed` already does.
- **10, roaming.** Mosh roams because the server answers to whatever address the latest authentic
  packet came from; TCP cannot. Bergr's substitute is the fast replace already built, made quicker
  by 1 and cheaper by 8. One experiment: Multipath TCP (handover mode) on iOS with an MPTCP-enabled
  sshd on Linux hosts. Unverified whether Citadel's transport exposes it. Do not plan around it.

## 11-12. Skipped, and what Mosh itself rejected

- UDP transport and own encryption: a separate protocol project, as the resilience plan says.
- No scrollback: Mosh syncs only the visible screen, its best-known weakness. Keep herdr's history.
- Dropping bytes on the client: breaks emulator state.
- Local line editing (telnet LINEMODE style): Mosh rejected it because raw-mode programs do their
  own echo. Bergr's chat composer is the place where local editing is right.
- Mosh rejected TCP for head-of-line blocking and unskippable queues. Bergr keeps TCP, so 3 and 4
  are how to get the same effect at the application layer.

## Order of work

Client now: 3, 2, 1. Proposal to herdr-core as one feature set: 4 (resync on backlog), 5 (input
sequence and echo ack), optional `ping`. Then 6 behind a setting, then 8 and 9.
