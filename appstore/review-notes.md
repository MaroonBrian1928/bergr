# App Review notes

Paste into App Store Connect → App Review Information → Notes. Sign-in required: **No**.

---

Bergr is a client for herdr, an open-source tool that runs AI coding agents (such as Claude Code,
Codex and Antigravity) on a developer's own computers. Bergr connects to those computers over SSH to
show the agents and their conversations. It has no account and no server of its own for content.

You don't need a server to review it: Bergr has a built-in demo machine.

1. Launch Bergr and tap **Try the Demo** on the first screen (the empty Agents list).
2. The Agents list shows several demo agents. One is marked **Needs you**.
3. Tap an agent to open its conversation as a chat. Type a reply and send it: the demo agent
   answers.
4. On the agent that needs you, tap one of the answer buttons (for example **Yes**).
5. The terminal button at the top shows the agent's real terminal underneath the chat.

Everything in the demo is simulated on the device; nothing connects to the internet.

Notifications and the Live Activity need a real computer running herdr, so they can't be shown in
the demo. Both are optional and off by default.

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
