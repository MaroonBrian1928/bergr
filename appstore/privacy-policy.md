# Bergr privacy policy

Effective November 9, 2026.

Bergr is an app for watching and talking to the coding agents on your own computers. It has no
account, no analytics, no advertising and no tracking.

## What stays on your device and your computers

Bergr connects directly from your iPhone, iPad or Mac to computers you add, over SSH. What it shows
(your agents' conversations, terminals, files and images) comes from those computers and goes back to
them. It is not sent to the developer or to anyone else.

Your SSH keys are made and kept on your device (in the Secure Enclave where possible) and never
leave it. The machines you add and your settings are stored on your device.

## Push alerts (optional)

If you turn on push alerts, Bergr registers your device with Bergr's push relay so alerts can reach
it when the app isn't open. The relay stores:

- your device's push token from Apple,
- the app's identifier, and whether it's a development build,
- when the registration was made.

Alerts are encrypted on your computer with a key only your device has, and decrypted on your device:
the relay passes them to Apple's push service without being able to read them. To limit abuse, the
relay counts registrations per network address for up to two hours, using a one-way hash of the
address rather than the address itself. Turning push alerts off, or removing a computer's helper,
deletes the registration.

The relay runs on Cloudflare Workers; alerts are delivered by Apple Push Notification service.

## Purchases

Purchases are handled by Apple. Bergr receives only what Apple's StoreKit provides to confirm a
purchase, never your payment details.

## Children

Bergr is a developer tool and isn't directed at children.

## Changes and contact

Changes to this policy are published here, with a new effective date. Questions:
https://github.com/MaroonBrian1928/bergr/issues
