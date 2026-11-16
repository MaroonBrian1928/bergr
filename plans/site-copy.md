# Site copy for bergr.dev

The site's source is not in this repository (the README and the App Store listing only link to
bergr.dev and bergr.dev/privacy.html), so this is the copy on its own. Every claim here was checked
against the code; the file named under each section is where it lives.

Voice: plain, short sentences. No hype words, no emoji.

## Hero

**Headline:** The shepherd for your agent herd.

**Subhead:** Your coding agents run on your own machines. Bergr watches all of them from your
iPhone, iPad and Mac, tells you which ones need you, and lets you answer in a tap.

**Supporting line:** Apple Intelligence reads along on your device. Nothing it reads leaves it.

**Primary button:** Download on the App Store
**Secondary link:** Try the built-in demo, no server needed

**Visual:** the hero clip (shot list, frames 1 to 3): the Agents list with one agent marked "Needs
you", a tap into its chat, the question answered with one button, the row turning to working.
Dark appearance, iPhone, 8 to 10 seconds, looping.

## 1. On-device intelligence

**Headline:** It reads the output so you don't have to.

Long tool output becomes one line in the chat. When an agent finishes, Bergr suggests what you
might say next, and before you approve a risky command it tells you in one sentence what the
command would do. All of it is written by Apple's on-device model, so the text never leaves your
device.

**Small print:** Needs a device with Apple Intelligence turned on. Without it, Bergr works the
same and leaves the summaries out.

**Needs:** screenshot of a chat with three tool rows, each with a one-line summary under its
title, and two reply suggestion chips above the reply field (shot list, frame 2). Second image,
smaller: the answer card for a dangerous command with the explainer sentence (frame 4).

Code: `Shared/OnDeviceText.swift`, `bergr/Intelligence/`.

## 2. Answers in a tap

**Headline:** A question becomes a button.

When Claude Code or Codex asks for permission, Bergr shows the choices as buttons: in the chat, on
the notification, and on the Lock Screen while Bergr stays running. Commands you trust can be
allowed for one project on one machine. Commands that are hard to undo always ask.

**Needs:** clip of a notification arriving on the Lock Screen with numbered answer buttons, then
the Live Activity showing the question with Yes and No (frame 5). Still: the chat's answer card
(frame 3).

Code: `bergr/Chat/AnswerCard.swift`, `bergr/Background/AnswerFlow.swift`,
`Shared/AnswerCategory.swift`, `bergr/Approvals/ApprovalRule.swift`,
`bergr/Chat/CodexQuestionReply.swift`.

Do not write: that Codex's own questions are answered from the Lock Screen. A reply to a Codex
question from a notification opens the chat, where it is answered.

## 3. Usage

**Headline:** Know when you'll hit the limit.

Bergr shows the context window and your plan's session and weekly usage for every running agent.
Charts cover the last 24 hours or 7 days with each reset marked, and a forecast says when you'll
reach the limit at the current pace. A widget keeps the closest limit on your Home Screen.

**Needs:** screenshot of the Usage screen with a session meter at about 62%, the weekly meter, a
7-day chart showing two reset marks, and the line "At this rate you'll hit the limit at 15:10"
(frame 6). Second image: the small Usage widget.

Code: `bergr/Usage/`, `BergrLiveActivity/UsageWidget.swift`.

## 4. Say it, snap it, paste it

**Headline:** Reply without a keyboard.

Dictate a reply and it stops when you pause. Take a photo of a whiteboard, scan a page, or paste a
screenshot from the clipboard, and it goes to the agent with your message. Siri can tell you what
needs you, send a message to an agent, and read its latest reply aloud.

**Needs:** clip of the "+" menu opening (Photo Library, Take Photo, Scan Document, Paste Image),
a scanned page landing as a thumbnail above the reply field, then the mic button filling the draft
(frame 7).

Code: `bergr/Chat/Dictation.swift`, `bergrIOS/Chat/Attachments.swift`, `bergrIOS/Chat/Camera.swift`,
`SharedIOS/AgentIntents.swift`.

## 5. Stays with you

**Headline:** Close the app. Keep the herd in view.

A Live Activity, widgets and a Control Center button show what needs you. Optional push alerts come
from a small helper that Bergr installs on your Mac, Linux or Windows machines, encrypted end to
end so the relay that delivers them can't read them. Focus filters and quiet hours decide what gets
through, and a watchdog tells you when a working agent has gone quiet.

**Needs:** a Lock Screen composition: the Live Activity with counts (1 needs you, 2 working), one
alert whose title names the machine, and the medium Agents widget on a Home Screen beside it
(frame 8).

Code: `BergrLiveActivity/`, `bergr/Push/`, `relay/`, `bergrIOS/FocusFilter.swift`,
`bergr/Background/NotificationPrefs.swift`.

## 6. See the work

**Headline:** Check the diff before you say yes.

Changes shows what an agent touched: git status, a diff per file and the last test run, with a
one-sentence summary on top. Start a session in its own git worktree, and drop to a real terminal,
powered by Ghostty, whenever the chat isn't enough.

**Needs:** screenshot of the Changes sheet with the summary sentence, "Last test run" showing a
pass, and one file's diff open (frame 9).

Code: `bergr/Changes/`, `bergr/Agents/Worktrees.swift`, `bergrIOS/Screen/`.

## 7. Native on every Apple device

**Headline:** One app, three sizes.

On iPad, your agents sit beside the conversation and a second conversation opens next to the
first. On the Mac, Bergr is a native app with a menu-bar item that counts the agents that work or
wait, and it can use the SSH setup you already have. Pair your iPhone from the Mac with a QR code.

**Needs:** the existing iPad two-conversation shot (`assets/ipad-dark.png`), a Mac window with the
menu-bar popover open, and the "Pair iPhone" QR sheet (frame 10).

Code: `bergrMac/`, `bergr/Pairing/`.

## Privacy strip (between sections 7 and the CTA)

**Headline:** Your machines. Your keys. Your device.

No account and no tracking. Bergr connects straight to your machines over SSH, with keys kept in
the Secure Enclave. The intelligence runs on the device, and alerts are encrypted before they
leave your machine.

Link: What the relay stores, and nothing else (bergr.dev/privacy.html).

## Closing CTA

**Headline:** Lead the herd from anywhere.

**Line:** Free to try with the built-in demo machine. To use it with your own computers, install
herdr on them.

**Primary button:** Download on the App Store
**Secondary link:** Source on GitHub

**Footer line:** Bergr is an independent, open-source app (Apache-2.0), based on Hirte. It is not
affiliated with Anthropic, OpenAI, Google, Apple or the herdr project.

## Claims to leave out

- "30-day charts". History is kept for 30 days, but the charts show 24 hours or 7 days.
- "AI command suggestions". The slash-command and skill cards are plain prefix matching. The
  on-device model only explains commands that are hard to undo.
- "Hands-free mode". There is dictation that stops on a pause, Read Aloud, and Siri phrases, but
  no continuous voice mode.
- "Summaries on every alert". The on-device sentence is on alerts Bergr posts itself. Pushes from
  the helper carry the helper's own text.
- Pricing. "Free to try" above only covers the demo; confirm the price before publishing.
