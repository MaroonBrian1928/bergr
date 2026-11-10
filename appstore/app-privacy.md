# App Privacy answers (App Store Connect → App Privacy)

Based on what the app and the relay actually do (see privacy-policy.md and relay/src/index.js).

**Do you or your third-party partners collect data from this app?** Yes. The only thing collected
is the push token, and only when push alerts are turned on.

| Data type | Collected | Linked to the user | Tracking | Purpose |
|---|---|---|---|---|
| Identifiers → Device ID (the APNs push token) | Yes, only with push alerts on | No (no account; the relay knows nothing else about the person) | No | App Functionality |

Everything else: **not collected**. Specifically:

- Contact info, health, financial, location, contacts, browsing and search history, purchases: no.
- User content (agent conversations, terminal output, images): **not collected**. It travels
  directly between the device and the user's own computers over SSH; alerts through the relay are
  end-to-end encrypted, so the relay can't read them.
- Diagnostics, usage data: no analytics or crash reporting SDKs.
- The hashed IP address used for rate limiting is kept up to 2 hours and not linked to anything;
  Apple treats data processed only transiently like this as not collected.

**Tracking:** No. `PrivacyInfo.xcprivacy` declares `NSPrivacyTracking` false.

Note: whether an APNs token counts as a "Device ID" is a judgement call (it identifies the app
install, not the person). Declaring it is the conservative choice and costs nothing.
