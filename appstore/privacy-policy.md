# Bergr privacy policy

Effective November 10, 2026.

Bergr is an app for watching and talking to the coding agents on your own computers. It has no
account, no analytics, no advertising and no tracking.

## What stays on your device and your computers

Bergr connects directly from your iPhone, iPad or Mac to computers you add, over SSH. What it shows
(your agents' conversations, terminals, files and images) comes from those computers and goes back to
them. It is not sent to the developer or to anyone else.

Your SSH keys are made and kept on your device (in the Secure Enclave where possible) and never
leave it. The machines you add and your settings are stored on your device.

## Notifications and Live Activity through the helpers (optional)

Bergr can keep you informed while it isn't open in one of two ways, which you choose in Settings.

**Helpers on your computers.** A small helper on each computer sends updates to your phone through
Bergr's push relay. When you turn on notifications or the Live Activity this way, the relay stores:

- your device's push token from Apple,
- the app's identifier, and whether it's a development build,
- when the registration was made.

Notifications are encrypted on your computer with a key only your device has, and decrypted on your
device: the relay passes them to Apple's push service without being able to read them.

The Live Activity is not encrypted. With "Numbers only", the relay receives and keeps, for each
computer, how many agents need you, are working and are done. With "Numbers and names", it also
receives each agent's name and short status, and Apple's push service and the relay can read them.
The relay keeps only the latest update from each computer, drops a computer that stops sending
updates, and deletes all of it when the Live Activity ends or you turn it off.

To limit abuse, the relay limits registrations per network address, using a one-way hash of the
address rather than the address itself; Bergr doesn't store it. Turning both switches off, or
removing a computer's helper, deletes the registration.

The relay runs on Cloudflare Workers; updates are delivered by Apple Push Notification service.

**Bergr stays running.** Bergr keeps its connections to your computers open in the background and
shows notifications and the Live Activity itself; nothing goes through the relay. To stay running,
Bergr asks for "Always" location access. It uses the least precise location iOS offers, only to keep
running, and never stores or sends it.

## Children

Bergr is a developer tool and isn't directed at children.

## Changes and contact

Changes to this policy are published here, with a new effective date. Questions:
https://github.com/MaroonBrian1928/bergr/issues
