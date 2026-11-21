# App Store screenshots and preview video: shot list

## Status (checked 2026-11-21)
- Demo: three machines: Done — `DemoMachine` has three cases in HerdrKit/Sources/HerdrKit/DemoScript.swift; DemoShotsTests reads rows t3, t11, t21.
- Demo: named agents and logos: Done — DemoScript.swift has two claude-code, two codex, one antigravity; logo imagesets exist in BergrLiveActivity/Assets.xcassets and bergr/Agents/AgentLogo.swift.
- Demo: fixed on-device text: Done — DemoChat.swift `summaries`, `chips`, `digest`, `explanation(for:)`, `changesSummary`, applied by `seed()`; routing of the away card through OnDeviceTextWriting not traced.
- Demo: one story (website, shop-api, infra; the two kept beats): Done — `DemoBeat` folders in DemoScript.swift; "Run the database migration?" and "Upgraded Postgres to 18" (`timeline`).
- Demo: status bar 9:41, Wi-Fi, full battery: Done — scripts/simulator.sh line 44 sets 9:41, Wi-Fi and battery level 100 (state "discharging"); screenshots.sh clears it after the run.
- Conversation A (blocked migration, shop-api): Done — DemoScript `t3`: blocked, "Run the database migration?", msg "Add order totals endpoint".
- Conversation B (finished dark mode turn): Done — DemoScript `t1`: done, "Add a dark mode toggle", msg "20 files changed".
- Conversation C (Codex, working, 2 sub-agents): Done — DemoScript `t11`: working, "Running pg_upgrade checks"; DemoChat `runningSubagents` returns 2.
- Conversation D (Codex, blocked, worktree): Partial — `t12` is blocked on the cache question and its branch `codex/cache-images` matches (DemoChat `repos`), but its folder is `shop-api-cache-images`, not `shop-api`, and there is no separate title.
- Conversation E (Antigravity, idle): Done — DemoScript `t21`: idle, "Fix flaky checkout test"; folder is the Windows website path.
- 1. Agents list: Done — testListChatChangesUsage (DemoShotsTests) saves "01-agents"; asserts rows t3, t11, t21 and the "Wants to run the orders migration" card. Groupings and "· worktree" label (Worktrees.swift) not asserted by the test.
- 2. Chat with on-device summaries: Done — testListChatChangesUsage saves "02-chat-summaries"; asserts the three summaries and reply chips (DemoChat `summaries`, `chips`); context 80,000 of 200,000 is about 40%.
- 3. Answer card: Done — testAnswerCards saves "03-answer-card"; asserts the command and "don't ask again".
- 4. Risky command, explained: Done — testAnswerCards saves "04-dangerous-command"; asserts "Dangerous" and the explanation sentence. Confirm-before-Yes not asserted.
- 5. Lock Screen: Partial — Live Activity is drawn by scripts/widget-render (screenshots.sh copies "lock-live-activity"), but SiteWidgetFixture.swift shows "2 need you, 1 working, 1 done", not "1 needs you · 2 working"; the notification is never rendered (only the "1 Yes · 2 No" text in Shared/AnswerCategory.swift); testLockScreenLiveActivity is skipped by screenshots.sh.
- 6. Usage: Partial — testListChatChangesUsage saves "06-usage" and asserts only "Current session"; the test keeps the default 24-hour range, not "7 days". Values 62 / 41 / 18 and per-agent 40% / 73% are in DemoChat.swift. "At this rate… 15:10" is computed from the clock (UsageHistory.swift), so the time is Unclear.
- 7. Reply with a scan or your voice: Partial — testCodexQuestionAndLiveRun saves "07-codex-reply" with the typed draft and attachment (`-bergr.demoAttach`); no test taps the mic (Dictation.swift listening state); testLimitBarAndAttachMenu asserts only "Scan Document" (saves "08-attach-menu").
- 8. Widgets and Focus: Partial — home-widgets rendered by scripts/widget-render from SiteWidgetFixture.swift; the Agents widget counts and A/D names match, but the Usage widget reads "Limit at 3:10 PM" and "Resets Thu 9:00 AM", not "Limit at 15:10".
- 9. Changes: Done — testListChatChangesUsage saves "09-changes" and "09b-changes-diff"; the summary sentence is in DemoChat `changesSummary`; branch `feature/dark-mode` and 20 tracked files in DemoChat `repos`; "Last test run" section in bergr/Changes/ChangesView.swift. Not in the App Store set (screenshots.sh); site-shots.sh uses it.
- 10. iPad and Mac (iPad part): Partial — DemoPadShotsTests (p01 to p06) covers the list, answer card, dangerous command, side-by-side (`Open Beside`), usage and Codex reply; the pad captions in screenshots.sh differ from this plan; "C streaming with a tool row" not checked.
- 10. iPad and Mac (Mac part): Not started — no UI test or script captures the Mac window or the menu-bar popover; "Pair iPhone" sheet exists (bergr/Pairing/PairPhoneView.swift) but is not shot.
- Preview video (15 to 30 s): Partial — testVideoTour (class DemoTourTests, bergrUITests.swift) makes the README video; it has no "Show me what changed" tap, no Scan Document step and no end card; scripts/video.sh frames it for the README.
- Light pass of frames 1 to 3 for the README: Partial — screenshots.sh and DemoShotsTests accept an appearance, but they render all eight frames, not only 1 to 3.
- Things not to stage (30-day range): Done — no test selects 30 days; premise is out of date: bergr/Usage/UsageView.swift has a "30 days" option, offered once a week of readings exists.

Ten frames. Frames 1 to 8 are the App Store set, in this order (the first three show in search
results, so they carry the pitch). Frames 9 and 10 are for the site and the iPad and Mac slots.
Captions are at most six words; the subcaption is optional and goes under it in the frame, as
`scripts/screenshots.sh` does today.

All frames come from the demo machine (`-bergr.demo YES`), English, dark appearance for the store
set, with a light pass of frames 1 to 3 for the README.

## What the demo needs, in general

- **Three machines**, so "your machines" reads at a glance: `studio` (a Mac), `buildbox` (Linux),
  `winbox` (Windows). The current demo has one.
- **Named agents with their logos**: two Claude Code, two Codex, one Antigravity. The current demo
  rows are a generic "agent".
- **Fixed on-device text.** Tool summaries, reply suggestions, titles, the command explanation,
  the changes summary and the away digest are written by Apple's on-device model. It is not
  deterministic and may be unavailable in the simulator. For screenshots, the demo has to supply
  these strings itself (every one of them goes through `OnDeviceTextWriting`, which tests already
  fake). The exact strings to stage are given per frame.
- **One story across the frames**: a small shop. Projects `website`, `shop-api` and `infra`, as in
  `HerdrKit/Sources/HerdrKit/DemoScript.swift` now. Keep the existing "Run the database migration?" and "Upgraded Postgres
  to 18" beats; they already read well.
- Status bar: 9:41, full battery, Wi-Fi (`simctl status_bar`, as the script does).

## The demo conversations

| Id | Machine | Agent | Folder | Title | State |
| --- | --- | --- | --- | --- | --- |
| A | studio | Claude Code | ~/projects/shop-api | Add order totals endpoint | blocked: "Run the database migration?" |
| B | studio | Claude Code | ~/projects/website | Add a dark mode toggle | done, 20 files changed |
| C | buildbox | Codex | ~/projects/infra | Upgrade Postgres to 18 | working, "Running pg_upgrade checks", 2 sub-agents |
| D | buildbox | Codex | ~/projects/shop-api (worktree `codex/cache-images`) | Cache product images | blocked on a Codex question |
| E | winbox | Antigravity | projects\website | Fix flaky checkout test | idle |

## Frames

### 1. Agents list

- **Screen:** Agents, sorted by what needs you.
- **State:** all five conversations. A and D under "Needs you" on top, B under "Finished", C
  under "Working" with its sub-agent count, E idle. Machine names visible on the rows, D's row
  showing its branch with "· worktree". The "While you were away" card on top with two rows:
  "Dark mode toggle is ready; 20 files changed, tests pass" (B) and "Wants to run the orders
  migration" (A).
- **Caption:** Your whole herd, one list
- **Subcaption:** Every machine, sorted by what needs you.

### 2. Chat with on-device summaries

- **Screen:** conversation B (Claude Code, website), scrolled to the end of the finished turn.
- **State:** user message "add a dark mode toggle to the header". Then three tool rows, each with
  a staged one-line summary under its title:
  - `npm test` → "48 tests passed in 12 seconds"
  - `git diff --stat` → "20 files changed, mostly header and theme styles"
  - `npm run build` → "Build succeeded; bundle grew by 2 KB"
  Then the agent's reply: a short paragraph ending "Dark mode toggle is ready. It follows the
  system setting by default." Two reply suggestion chips above the reply field: "Show me what
  changed" and "Run it on the staging site". Context ring in the header at about 40%.
- **Caption:** Summaries written on your iPhone
- **Subcaption:** Apple Intelligence, on device. Nothing leaves it.

### 3. Answer card

- **Screen:** conversation A (Claude Code, shop-api), the permission prompt as a card.
- **State:** the agent's last message says it added the endpoint and needs a new column. The card
  asks "Run the database migration?" with the command `npm run migrate -- --name add_order_totals`
  and the buttons Yes, "Yes, and don't ask again", No. Not a dangerous command, so Yes is offered
  directly.
- **Caption:** Answer in one tap
- **Subcaption:** Questions become buttons.

### 4. Risky command, explained

- **Screen:** conversation A, a second prompt later in the same conversation.
- **State:** the agent wants to run `psql shop -c "DROP TABLE order_totals_old"`. The card is
  marked as dangerous with the pattern's reason, and under it the staged explainer sentence:
  "Permanently deletes the order_totals_old table and all its rows from the shop database." The
  card asks to confirm before Yes.
- **Caption:** Know what you're approving
- **Subcaption:** One sentence on what the command does.

### 5. Lock Screen: notification and Live Activity

- **Screen:** Lock Screen (a device capture or a composed frame; the simulator can't show a
  Live Activity from the demo, see the note in `appstore/review-notes.md`).
- **State:** the Live Activity shows "1 needs you · 2 working" and conversation A's question "Run
  the database migration?" with Yes and No buttons. Above it one notification titled
  "studio · Claude Code" with the body "Wants to run the orders migration. 1 Yes  2 No" and its
  numbered buttons expanded.
- **Caption:** Answer from the Lock Screen
- **Subcaption:** No need to open the app.

### 6. Usage

- **Screen:** Usage, range set to "7 days".
- **State:** one Claude account with "Current session" at 62% and the line "At this rate you'll
  hit the limit at 15:10", "Weekly" at 41% with "Resets Thu 09:00". One Codex account with a
  session meter at 18%. The 7-day chart for the Claude session shows a rising line broken by two
  "Reset" marks. Under the accounts, the per-agent context rows: B at 40%, C at 73%.
- **Caption:** See the limit coming
- **Subcaption:** Session, weekly and context, with a forecast.

### 7. Reply with a scan or your voice

- **Screen:** conversation D (Codex), reply field focused.
- **State:** Codex's open question shows as a card: "Where should product images be cached?" with
  the choices "On disk" and "In Redis". Above the reply field, one attached thumbnail of a scanned
  page (a hand-drawn cache diagram), and the draft reads "Use Redis, like in this sketch". The mic
  button is in its listening state. For the video, open the "+" menu first so Photo Library, Take
  Photo, Scan Document and Paste Image are seen.
- **Caption:** Talk, scan or paste
- **Subcaption:** A reply doesn't need a keyboard.

### 8. Widgets and Focus

- **Screen:** Home Screen (composed frame): the medium Agents widget and the small Usage widget.
- **State:** Agents widget: "2 need you, 1 working, 1 done" with A and D named. Usage widget:
  "Claude session 62%" and "Limit at 15:10" (this is the widget's own placeholder data, so it
  matches frame 6).
- **Caption:** Always in view
- **Subcaption:** Widgets, Live Activity, encrypted alerts.

### 9. Changes

- **Screen:** conversation B, the Changes sheet, scope "Last turn".
- **State:** staged summary on top: "Adds a dark mode toggle to the header and theme variables
  for both appearances." Status line with the branch `feature/dark-mode` and "20 files changed".
  "Last test run": `npm test`, passed, 48 tests. One file open, `src/components/Header.tsx`, with
  about twelve diff lines: the toggle button added, one import changed.
- **Caption:** Review before you approve
- **Subcaption:** Diffs and the last test run.

### 10. iPad and Mac

- **Screen (iPad, landscape):** Agents list beside two conversations, A on the left with its
  answer card, C on the right while it works. This replaces `assets/ipad-*.png`.
- **Screen (Mac):** the native app's main window on conversation B, with the menu-bar popover open
  showing "2 · 1!" and the two agents that need you.
- **State:** as in frames 2 and 3; C streaming a reply with one tool row running.
- **Caption:** iPhone, iPad and Mac
- **Subcaption:** Native on each.

## Preview video (15 to 30 seconds, portrait, no narration)

One continuous take on the demo machine, cut from frames 1, 2, 3, 6 and 7. On-screen captions are
the frame captions.

1. **0 to 4 s.** Agents list (frame 1). Hold, then the away card's rows fade in.
2. **4 to 10 s.** Tap B. The chat opens at the end of the turn; the three tool summaries are
   there; the two reply chips appear. Tap "Show me what changed": the draft fills.
3. **10 to 16 s.** Back, tap A. The answer card (frame 3). Tap Yes. The card records the answer and
   the agent goes back to working.
4. **16 to 22 s.** Open D. Tap "+", choose Scan Document, the page lands as a thumbnail; tap the
   mic and the draft fills with "Use Redis, like in this sketch". Send: the Codex question shows
   as answered.
5. **22 to 27 s.** Usage (frame 6): the meters, then the forecast line.
6. **27 to 30 s.** Back to the Agents list: nothing under "Needs you". End card: the logo and "The
   shepherd for your agent herd."

Video constraints: App Store previews may only show the app itself, so the Lock Screen and Home
Screen frames (5 and 8) stay out of the video. The camera and the scanner can't run in the
simulator; stage the scanned page as a pre-attached image in the demo, or record step 4 on a
device with `just video-device`.

## Things not to stage

They would show something the app doesn't do:

- A 30-day range in the Usage chart. The picker has "24 hours" and "7 days".
- Answer buttons for a Codex question on a notification or the Live Activity. Codex's questions
  are answered in the chat.
- A tool summary under a short tool output. Only output longer than four lines gets one.
- More than two reply chips, or a chip longer than ten words.
- An explainer sentence on a command that isn't flagged as dangerous.
