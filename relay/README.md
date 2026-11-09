# bergr-relay

A small Cloudflare Worker that relays push notifications from a user's machine to the Bergr iOS app through APNs. The APNs signing keys live only in Workers secrets; a user's machine holds just a per-device secret obtained by registering the device token.

## Deploy

1. `npm i`
2. `npx wrangler login`
3. `npx wrangler kv namespace create REGISTRATIONS`, then paste the id into `wrangler.toml`.
4. Set each secret with `npx wrangler secret put <NAME>`: `APNS_TEAM_ID`, `APNS_SANDBOX_KEY_ID`, `APNS_SANDBOX_KEY`, `APNS_PRODUCTION_KEY_ID`, `APNS_PRODUCTION_KEY`. For the keys, pipe the .p8 file, e.g. `npx wrangler secret put APNS_SANDBOX_KEY < ~/.config/bergr/AuthKey_XXXX.p8`. Either environment may be left out; pushes for it then return 503.
5. Optional: set `ALLOWED_BUNDLE_IDS` (comma list) as a var in `wrangler.toml` to restrict registration.
6. `npx wrangler deploy`
7. Optional: attach a custom domain in the Cloudflare dashboard.

Run the tests with `npm test` (no wrangler needed).

## API

- `POST /v1/register` `{"token","bundle_id","sandbox"}` returns `{"secret"}`.
- `DELETE /v1/register` with `Authorization: Bearer <secret>` returns 204.
- `POST /v1/push` with `Authorization: Bearer <secret>` and `{"title","body","address","host"}` (or `{"e","address","host"}` with `e` an end-to-end encrypted base64 blob of at most 3000 characters) returns `{"ok":true}`. 410 `{"error":"unregistered"}` means the device is gone; drop the secret.

Limits: 4 KB bodies, 120 pushes per secret per hour, 20 registrations per IP per hour.

## Privacy

The relay stores only device tokens and secret hashes, and, for plain `title`/`body` pushes, sees alert text in transit. Pushes with `e` carry only an opaque blob: the relay and Apple show a generic "An agent needs you" and the phone's Notification Service Extension decrypts the real text.
