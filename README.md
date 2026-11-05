# DriftMail

A free, good-looking mail app for iPhone, built for **iPhone Duo**. It puts Gmail, iCloud, Yahoo, Fastmail, AOL, Zoho and any other IMAP account in one place. It can notify you the moment new mail arrives, using a free relay you run on Cloudflare.

- **Unified inbox** with per-account colours, search, swipe actions, flags, archive, trash and junk.
- **Live while open**: DriftMail keeps an IMAP IDLE connection to every inbox, so new mail appears right away.
- **Notifications while closed, free**: a Cloudflare Worker on the free plan checks your inboxes every minute and sends a push.
- **Compose** replies, reply-all and forwards, with photo and file attachments.
- **Private**: DriftMail talks to your providers directly and keeps passwords in the iOS Keychain. The relay is optional, and it runs in your own Cloudflare account.

## Built for iPhone Duo

DriftMail follows Apple's [Designing for iPhone Duo](https://developer.apple.com/design/human-interface-guidelines/designing-for-iphone-duo) and [Preparing your app for iPhone Duo](https://developer.apple.com/documentation/technologyoverviews/preparing-your-app-for-iphone-duo) guidance.

| Pose / display | What DriftMail does |
| --- | --- |
| Outer display (closed) | A single pane, like Mail: the message list, then the message. Toolbars move to the side by themselves. |
| Inner display (open) | `NavigationSplitView` shows mailboxes, list and message side by side. |
| Partially folded (book) | The split view adapts its columns to the fold. Custom views read `reservedRegions(kind: .division)` to stay off the fold. |
| Compose on the inner display | An `ArrangementView` (`.split.axes(.horizontal)`) shows the message you are replying to beside the editor. On the outer display you see only the editor. |
| Welcome screen | An `ArrangementView(.split)`: the hero sits above the sign-in choices on the outer display, beside them on the inner display, and on separate halves when folded. |

Details:

- **Vertical toolbars.** Every toolbar item is a `Label` with a title and an SF Symbol, so the system can show it vertically, horizontally or in the overflow menu. Compose and Reply use `.visibilityPriority(.high)` so they stay visible longest. Less-used actions go in `ToolbarOverflowMenu`. In sheets, Cancel uses `.cancellationAction` (top of the vertical bar) and Send or Sign In uses `.topBarPinnedTrailing`.
- **Reserved regions.** The in-app "new mail" toast uses `GeometryProxy.reservedRegions(kind:)`. It moves below a camera occlusion, and on a folded display it stays on the side away from the vertical toolbar (`\.toolbarVerticalEdge`).
- **Background extension.** The tinted message header and the welcome hero use `backgroundExtensionEffect()`, so they reach under the side bar.
- **Even grids.** The attachment and provider grids use 2 or 4 columns, so they split cleanly at the fold.
- **No fixed widths.** Layout uses size classes and safe areas. The app supports every orientation and multiple scenes.

## Install the app

Every push to `main` builds the app on GitHub's `xcode-27` runner with **Xcode 27.1** and publishes a numbered [release](../../releases/latest).

**Easiest: AltStore or SideStore (automatic updates).** In [AltStore](https://altstore.io) or [SideStore](https://sidestore.io), add this source once:

```
https://github.com/westernpluto/DriftMail/releases/latest/download/altstore-source.json
```

Then install DriftMail from it. New versions appear as updates, and AltStore/SideStore re-sign the app in the background before the free 7-day signature expires. If you use a fork, swap in your own `owner/repo`.

**Alternative: Sideloadly.** Download `DriftMail.ipa` from the [latest release](../../releases/latest) and install it with [Sideloadly](https://sideloadly.io). With a free Apple ID you have to repeat this every 7 days.

The app requires iOS 27.1 or later, the first release with the iPhone Duo APIs. To build locally on a Mac with Xcode 27.1, run `brew install xcodegen && xcodegen generate && open DriftMail.xcodeproj`.

## Add your accounts

DriftMail signs in with an **app password**, which works with every major provider and needs no developer registration:

| Provider | Where to create an app password |
| --- | --- |
| Google / Gmail | Turn on 2-Step Verification, then go to <https://myaccount.google.com/apppasswords> |
| iCloud | <https://account.apple.com>: Sign-In and Security → App-Specific Passwords |
| Yahoo / AOL | Account Security → Generate app password |
| Fastmail | Settings → Privacy & Security → App passwords |
| Zoho | Enable IMAP, then Security → App passwords |

The app has a button that opens the right page for each provider.

> Outlook.com / Hotmail personal accounts no longer accept app passwords for IMAP, so DriftMail cannot sign in to them yet.

## Instant notifications (free)

iOS won't let a free, sideloaded app keep a mail connection open in the background. So DriftMail uses a small relay that you run yourself on **Cloudflare Workers' free plan**. No credit card is needed.

```
 your inboxes ──IMAP (every minute)──▶ Cloudflare Worker ──push──▶ ntfy app ──tap──▶ DriftMail opens the message
```

- **Delivery with ntfy (free, recommended).** The free [ntfy](https://apps.apple.com/app/ntfy/id1625396347) app receives the push. Tapping it opens DriftMail on that message (`driftmail://` link). This works with any free sideloaded build.
- **Native push.** If you sign DriftMail with a **paid** Apple Developer account, the Worker can send through Apple Push directly (see below). Apple doesn't allow push for free Apple IDs, which is why ntfy is the default.
- **Speed.** The Worker checks every minute, the shortest interval the free plan allows, so a notification arrives at most about a minute after the email does. While DriftMail is open, new mail shows up right away over IMAP IDLE.

### Set it up from the app (recommended, about 2 minutes)

Open **Settings → Instant Notifications** in DriftMail:

1. **ntfy:** tap **Install ntfy**, then **Copy my topic**. In ntfy, tap **+**, paste the topic and subscribe.
2. **Cloudflare:** tap **Create a free Cloudflare account** if you don't have one. Then tap **Create a DriftMail token**. It opens Cloudflare with the right permissions already filled in. Tap **Continue to summary → Create Token**, copy the token, and paste it into DriftMail.
3. Tap **Set Up Notifications**.

DriftMail then does the rest:
- creates the storage and uploads the relay to your Cloudflare account
- schedules the once-a-minute check
- turns on the relay's `workers.dev` address
- pairs the relay with your phone using a random secret code
- uploads your accounts and sends a test notification

Nothing goes into GitHub, and you never type an address or a pairing code. When a new DriftMail version includes relay changes, the app redeploys the relay automatically.

The token can only manage Workers and KV storage (plus read basic account info). DriftMail keeps it in the iOS Keychain so it can update the relay. You can delete the token in Cloudflare at any time; the relay keeps working, it just won't auto-update.

**One relay per person.** Each relay serves one phone. Friends set up their own relay in their own free Cloudflare account, which takes the same three steps.

### Deploy from GitHub Actions (alternative)

1. In your repo (a fork, if this one isn't yours), go to **Settings → Secrets and variables → Actions** and add three repository secrets: `CLOUDFLARE_API_TOKEN` (made from the **Edit Cloudflare Workers** template), `CLOUDFLARE_ACCOUNT_ID`, and `RELAY_PAIRING_CODE` (a code you make up, at least 8 characters). Secrets stay encrypted and hidden, even in a public repo.
2. Run **Actions → Deploy notification relay**. Logs of public repos are visible to everyone, so the workflow doesn't print the address. Copy it from the Cloudflare dashboard under **Workers & Pages → driftmail-relay**.
3. In DriftMail, open **Instant Notifications → Manual setup & advanced**, enter the address and pairing code, and tap **Connect with these settings**.

### Deploy by hand (alternative)

```bash
cd worker
npm install
npx wrangler login
npx wrangler kv namespace create driftmail-kv   # paste the id into wrangler.toml
npx wrangler deploy
npx wrangler secret put PAIRING_CODE            # the code you'll type into the app
```

**Who can use a relay.** A phone can only pair with the relay if it presents the pairing code. After that, the relay only answers that phone. Someone who finds the relay address can't do anything with it.

### Privacy and security notes

- To check mail for you, the relay stores your app passwords in **your own** Cloudflare KV, encrypted with AES-GCM. With in-app setup, the encryption key is a Worker secret that DriftMail generates and keeps in your Keychain. With manual setup, add `ENC_KEY` as a secret yourself (`npx wrangler secret put ENC_KEY`); otherwise the Worker generates a key and stores it in KV.
- App passwords can be revoked at any time and can't be used to sign in to your account's settings.
- Turn off **Show sender and subject** if you'd rather not have message details pass through ntfy.sh. You can also self-host ntfy and change the server under **Advanced**. Set an `NTFY_TOKEN` secret if your server requires auth.
- **Disconnect Relay** in the app deletes your accounts from the Worker.

### Native Apple push (optional, paid developer account)

1. Sign DriftMail with your team. The app already includes the `aps-environment` entitlement.
2. Create an APNs key (.p8) in your developer account.
3. Add the repo secrets `APNS_KEY` (the .p8 contents), `APNS_KEY_ID`, `APNS_TEAM_ID` and `APNS_BUNDLE_ID` (your bundle ID). Re-run **Deploy notification relay**.
4. In DriftMail, set **Deliver with** to **Native push** and tap **Connect**.

### Free-plan budget

| Resource | Free limit | DriftMail uses |
| --- | --- | --- |
| Worker requests | 100,000 / day | ~1,440 cron runs / day |
| KV reads | 100,000 / day | ~3 per run (~4,300 / day) |
| KV writes | 1,000 / day | only when new mail arrives or errors change, plus 1 status write every 30 min |
| Cron triggers | 5 | 1 |

## Project layout

```
DriftMail/
  App/        App entry, notification + deep-link handling, background refresh
  Mail/       IMAP client and parser, SMTP client, MIME parser and builder
  Services/   MailStore (state), account sessions, Keychain, relay client
  Views/      SwiftUI screens (split view, list, message, compose, setup)
worker/       Cloudflare Worker relay (no dependencies)
project.yml   XcodeGen project spec
```
