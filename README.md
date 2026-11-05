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

1. GitHub Actions builds an unsigned `.ipa` on every push to `main`/`master`, using the `xcode-27` runner with **Xcode 27.1** (`.github/workflows/build-ipa.yml`). Download it from the run's **Artifacts** (`DriftMail-ipa`), or push a tag such as `v1.0.0` to get it attached to a GitHub Release.
2. Sideload it with a free tool such as [Sideloadly](https://sideloadly.io) or [AltStore](https://altstore.io) and your Apple ID. With a free Apple ID, the app has to be re-signed every 7 days. AltStore can do this for you automatically.

The app requires iOS 27.1 or later, the first iOS release with the iPhone Duo APIs.

To build locally on a Mac with Xcode 27.1, run `brew install xcodegen && xcodegen generate && open DriftMail.xcodeproj`.

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

### Deploy the relay with one click

1. Create a free account at <https://dash.cloudflare.com/sign-up>. Open **Workers & Pages** once so Cloudflare sets up your `*.workers.dev` subdomain.
2. In Cloudflare, go to **My Profile → API Tokens → Create Token** and choose the **Edit Cloudflare Workers** template. Copy the token. Also copy your **Account ID**, shown on the Workers & Pages overview.
3. In your GitHub repo (your own fork if you're not the owner of this one), go to **Settings → Secrets and variables → Actions** and add three **repository secrets**:
   - `CLOUDFLARE_API_TOKEN`
   - `CLOUDFLARE_ACCOUNT_ID`
   - `RELAY_PAIRING_CODE`: a code you make up, at least 8 characters. Longer is better, for example four random words.

   Secrets are encrypted and never shown to anyone, even in a public repo. Never put these values in a file.
4. Go to **Actions → Deploy notification relay → Run workflow**. Logs of public repos are visible to everyone, so the workflow doesn't print your relay address. Copy it from the Cloudflare dashboard under **Workers & Pages → driftmail-relay**, for example `https://driftmail-relay.yourname.workers.dev`.
5. In DriftMail, open **Settings → Instant Notifications**:
   - Paste the relay address and your pairing code.
   - Install **ntfy**, tap **+**, and subscribe to the topic DriftMail shows (use **Copy topic**).
   - Tap **Connect Accounts to Relay**, then **Send Test Notification**.

**Who can use the relay.** Only a phone that presents the pairing code can pair with the relay. After that, the relay only answers that phone, which proves itself with a random token kept in its Keychain. Someone who finds the relay address can't do anything with it. Entering the pairing code on a new or reinstalled phone moves the relay to that phone.

**One relay per person.** Each relay serves one owner. If friends want DriftMail notifications, they fork the repo and deploy their own relay in their own free Cloudflare account.

### Deploy by hand (alternative)

```bash
cd worker
npm install
npx wrangler login
npx wrangler kv namespace create driftmail-kv   # paste the id into wrangler.toml
npx wrangler deploy
npx wrangler secret put PAIRING_CODE            # the code you'll type into the app
```

### Privacy and security notes

- To check mail for you, the relay stores your app passwords in **your own** Cloudflare KV, encrypted with AES-GCM. For a key you control, add a secret with `npx wrangler secret put ENC_KEY` before you connect. Otherwise the Worker generates a key and stores it in KV.
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
