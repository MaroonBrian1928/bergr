# App Review notes

Paste into App Store Connect → App Review Information → Notes. Sign-in required: **No**.

---

Bergr is a client for herdr, an open-source tool that runs AI coding agents (such as Claude Code,
Codex and Antigravity) on a developer's own computers. Bergr connects to those computers over SSH to
show the agents and their conversations. It has no account and no server of its own for content.

You don't need a server or an account to review it: Bergr has a built-in demo with three demo
machines and five agents. Everything in it is simulated on the device; nothing connects to the internet.

1. Launch Bergr and tap **Try the Demo** on the first screen (the empty Agents list).
2. The Agents list shows agents on three machines: two **Need you**, one is working, one has
   finished, one is idle.
3. Open **Add a dark mode toggle** (finished): a Claude conversation as a chat. Each group of tool
   steps has a one-line summary, one test run failed and was fixed, and suggested replies sit above
   the reply field. Drag the conversation left to see when each message was sent. The ± button shows
   the files the agent changed; the gauge shows usage (context, plan limits, a 24-hour chart).
4. Open **Run the database migration?**: Claude asks for permission. Tap **Yes**; the next step is a
   command that drops a table, which Bergr marks as dangerous with a one-sentence explanation.
5. Open **Where should product images be cached?**: Codex asks a question shown as a card, with a
   recommended option and a field to answer in your own words. Tap an option, or type a reply.
6. The terminal button at the top of any chat shows the agent's real terminal underneath the chat.

The one-line summaries and suggested replies come from Apple's on-device model on real machines; in
the demo they are fixed text, so they show even without Apple Intelligence.

With only the demo machine added, leaving the app shows the demo's agents in a Live Activity on the
Lock Screen. Notifications need a real computer running herdr and Bergr's helper, so they can't be
shown in the demo. Both are optional.

About location: Settings → When Bergr isn't open → "Updates come from" offers "Bergr stays running".
Only when the user picks it, Bergr asks for "Always" location access and runs a low-accuracy location
session, solely so iOS keeps the app running and its SSH connections to the user's computers open.
That lets Bergr show an agent's question on the Live Activity with buttons to answer it. The location
is never stored, shown or sent anywhere. Settings and the permission prompt both say this. The default,
"Helpers on your computers", uses no location at all.

The app names Claude, Codex and Antigravity only to say which agents it works with. It is not
affiliated with Anthropic, OpenAI or Google (stated in Settings → About and in the description).

Bergr is open source (https://github.com/MaroonBrian1928/bergr), based on Hirte under the Apache
License 2.0.
