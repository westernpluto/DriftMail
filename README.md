# DriftMail

A free, good-looking mail app for iPhone, built for **iPhone Duo**. It puts Gmail, iCloud, Yahoo, Fastmail, AOL, Zoho and any other IMAP account in one place. It can notify you the moment new mail arrives, using a free relay you run on Cloudflare.

- **Unified inbox** with per-account colours, search, swipe actions, flags, archive, trash and junk.
- **Live while open**: DriftMail keeps an IMAP IDLE connection to every inbox, so new mail appears right away.
- **Notifications while closed, free**: a Cloudflare Worker on the free plan stays connected to your inboxes and sends a push within seconds.
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

**With a paid Apple Developer account: TestFlight (recommended).** See [TestFlight](#testflight-paid-apple-developer-account) below. Every push to `main` lands in the TestFlight app automatically, with no 7-day limit and native notifications.

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
 your inboxes ──IMAP IDLE (live)──▶ Cloudflare Worker ──push──▶ ntfy app ──tap──▶ DriftMail opens the message
```

- **Delivery with ntfy (free, recommended).** The free [ntfy](https://apps.apple.com/app/ntfy/id1625396347) app receives the push. Tapping it opens DriftMail on that message (`driftmail://` link). This works with any free sideloaded build.
- **Native push.** If you sign DriftMail with a **paid** Apple Developer account, the Worker can send through Apple Push directly (see below). Apple doesn't allow push for free Apple IDs, which is why ntfy is the default.
- **Speed: seconds.** A free-plan Cron Trigger starts the Worker every minute. Each run catches up on anything new, then keeps the connection open in **IMAP IDLE** for about 50 seconds, so the mail server tells the Worker the instant a message lands. The next run takes over a few seconds later, and its catch-up step covers that short gap. Waiting doesn't count toward the free plan's CPU limit. If a provider doesn't support IDLE, the Worker falls back to checking once a minute. Up to 5 accounts can be watched live at once (the free plan allows 6 open connections per run).

### Set it up from the app (recommended, about 2 minutes)

Open **Settings → Instant Notifications** in DriftMail:

1. **Choose how you're notified:** **Apple Push** (DriftMail's own private notifications; needs the TestFlight build) or the **ntfy app** (works with any build). Nothing is set up until you choose, and you can switch later; the relay is updated automatically.
   - **Apple Push:** choose your `.p8` key file (see [Native notifications](#native-notifications-paid-apple-developer-account)).
   - **ntfy:** tap **Install ntfy**, then **Copy my topic**. In ntfy, tap **+**, paste the topic and subscribe.
2. **Cloudflare:** tap **Create a free Cloudflare account** if you don't have one. Then tap **Create a DriftMail token**. It opens Cloudflare with the right permissions already filled in. Tap **Continue to summary → Create Token**, copy the token, and paste it into DriftMail.
3. Tap **Set Up with Apple Push** or **Set Up with ntfy**. The button always names the method it will use.

DriftMail then does the rest:
- creates the storage and uploads the relay to your Cloudflare account
- schedules the relay so it stays connected to your inboxes
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

**Hardening checklist.** DriftMail → Instant Notifications → **Security** has all of these:

- **Give the relay its own app password** for each account. If your relay or Cloudflare account were ever compromised, you'd revoke only that password. Your phone keeps working, and your provider shows when the relay's password was last used. DriftMail checks the password before using it, and refuses to reuse the phone's.
- **Add a passkey or two-factor authentication to your Cloudflare account.** Control of that account is the realistic way someone could reach your relay.
- **Forget the Cloudflare token** if you'd rather the phone not store it. Notifications keep working; you paste a token again only to install relay updates. The app tells you when one is available.
- **Hide notification previews when locked** (iPhone Settings → Notifications → Show Previews → When Unlocked).
- Built in: the relay **locks pairing for an hour after 10 wrong codes**, and keeps **no request logs** in Cloudflare.

- To check mail for you, the relay stores your app passwords in **your own** Cloudflare KV, encrypted with AES-GCM. With in-app setup, the encryption key is a Worker secret that DriftMail generates and keeps in your Keychain. With manual setup, add `ENC_KEY` as a secret yourself (`npx wrangler secret put ENC_KEY`); otherwise the Worker generates a key and stores it in KV.
- App passwords can be revoked at any time and can't be used to sign in to your account's settings.
- Turn off **Show sender and subject** if you'd rather not have message details pass through ntfy.sh. You can also self-host ntfy and change the server under **Advanced**. Set an `NTFY_TOKEN` secret if your server requires auth.
- **Disconnect Relay** in the app deletes your accounts from the Worker.

### Native notifications (paid Apple Developer account)

Apple Push works in any DriftMail build signed with a **paid** developer account whose provisioning profile includes push:

- **TestFlight** (recommended): automatic updates, everything handled by the workflow.
- **Sideloaded with your paid account**, e.g. Sideloadly signed in with your developer Apple ID: signatures last a year instead of 7 days. Whether push survives depends on the tool keeping the `aps-environment` entitlement and enabling Push on the App ID it creates. DriftMail tells you: **Apple Push** only becomes selectable when the phone actually received a push token.

**Sideloading tools and the notification extension.** Private notifications need DriftMail's notification extension (`PlugIns/NotificationService.appex`) to be signed too. Some on-device signers, such as Feather (built on Zsign), sign with a single profile. They may not set the extension up correctly, so their documentation doesn't settle it. To check, tap **Send Test Notification**: "DriftMail is connected" means the extension works. If you see "New mail" instead, turn off **Private notifications** under Apple Push, and the relay includes sender and subject itself. DriftMail also falls back to the profile's default keychain group when a signer applies only the `TEAMID.*` wildcard.

DriftMail picks Apple's sandbox or production push servers from the build's own provisioning profile, and its Team ID from the signature, so all of these work without changes. Free Apple IDs can't receive Apple Push; use ntfy there.

When push is available, DriftMail detects it and shows **Native notifications** in place of the ntfy step:

1. In your developer account, go to **Keys → +** and create a key with **Apple Push Notifications service (APNs)** enabled. Download the `AuthKey_XXXXXXXXXX.p8` file and save it to the Files app (iCloud Drive works).
2. In DriftMail → **Instant Notifications**, tap **Choose the .p8 key file**. DriftMail reads the Key ID from the file name, and the Team ID and bundle ID from the app itself.
3. Paste your Cloudflare token and tap **Set Up Notifications**. If you already set up ntfy, tap **Switch to Native Notifications** instead.

The relay stores the key as an encrypted Worker secret and signs Apple Push requests with it. ntfy remains available under **Manual setup & advanced**.

**Private by design.** With native notifications, the relay never reads your mail's sender or subject, and Apple never sees them either:

- DriftMail creates a random 256-bit key on your phone. It's stored in a keychain group shared only with DriftMail's notification extension. A copy goes to your relay, where it's stored encrypted.
- When mail arrives, the relay asks your provider only for message numbers and read/unread flags. It then sends Apple a placeholder alert ("DriftMail: New mail") plus an AES-256-GCM-encrypted reference: which account, which message.
- On your phone, DriftMail's Notification Service Extension decrypts the reference and signs in to your provider itself over TLS. It fetches the sender, subject and a preview, and shows the full notification. This takes about a second.
- If the phone can't reach your provider at that moment, you see "New mail" plus the account, and tapping opens the message once you're online.

So sender, subject and content exist only at your mail provider and on your phone. What remains true: the relay holds your app passwords so it can watch the inbox. It never reads mail, but someone who took over your Cloudflare account could. App passwords can be revoked at any time. Regular email isn't end-to-end encrypted at the provider in the first place.

With ntfy, turning off **Show sender and subject** puts the relay in the same no-read mode, and ntfy only sees "New mail".

### Free-plan budget

| Resource | Free limit | DriftMail uses |
| --- | --- | --- |
| Worker requests | 100,000 / day | ~1,440 cron runs / day |
| KV reads | 100,000 / day | ~3 per run (~4,300 / day) |
| KV writes | 1,000 / day | only when new mail arrives or errors change, plus 1 status write every 30 min |
| Cron triggers | 5 | 1 |
| CPU per run | 10 ms | a few ms; time spent waiting in IDLE doesn't count |
| Wall time per cron run | 15 min | ~50 s |

## TestFlight (paid Apple Developer account)

`.github/workflows/testflight.yml` signs DriftMail with your team and uploads it to TestFlight on every push to `main`. Until it's configured it skips itself and shows a notice. Apple doesn't allow the first three steps to be automated, so do them once:

1. **Choose a bundle ID** you own, e.g. `com.yourname.driftmail`. In the repo, go to **Settings → Secrets and variables → Actions → Variables** and add `BUNDLE_ID`.
2. **Create an App Store Connect API key:** in [App Store Connect](https://appstoreconnect.apple.com) go to **Users and Access → Integrations → App Store Connect API → Team Keys → +**, with role **Admin** (needed for cloud signing). Download the `.p8`, and note the **Key ID** and **Issuer ID**.
3. **Create the app record:** in App Store Connect go to **Apps → + → New App**, platform iOS, any name (for example "DriftMail Yourname"), and your bundle ID. If the bundle ID isn't in the list yet, run the TestFlight workflow once. Xcode registers the bundle ID, with push enabled, during the signed build, and then the upload fails until the app record exists. Create the record, then re-run.
4. **Add repository secrets:** `ASC_KEY_ID`, `ASC_ISSUER_ID`, `ASC_KEY` (the full contents of the `.p8`), and `APPLE_TEAM_ID` (from Membership details).
5. **Add yourself as a tester:** in the app's **TestFlight** tab, create an internal group with yourself in it and turn on automatic distribution.
6. Run **Actions → TestFlight** (or just push to `main`). Install **TestFlight** on your iPhone and accept the invite. After that, every push to `main` shows up as an update within about 15 minutes, and TestFlight can install updates automatically.

The workflow uses automatic signing with the API key, so you don't manage certificates or provisioning profiles. `ITSAppUsesNonExemptEncryption` is already `false`, so builds skip the export-compliance question.

## Ad hoc IPA (signed with separate profiles, no re-signing)

With the TestFlight secrets set (see above), the same workflow also exports **`DriftMail-adhoc-<version>.ipa`** as a run artifact (**Actions → TestFlight → latest run → Artifacts**). Automatic signing gives the app and its notification extension their own ad hoc profiles, so push, private notifications and the shared keychain are all set up correctly. The run log lists the profile used for each part.

- It installs only on devices registered in your developer account. Register your iPhone under **Certificates, Identifiers & Profiles → Devices → +** with its UDID, then re-run the workflow.
- Install it **as-is, without re-signing**: on a Mac, connect the iPhone and drag the IPA onto it in Finder, or use Apple Configurator. Re-signing it with a single-profile tool would undo the point.
- Signatures last as long as the profile (up to a year).
- Only want this and not TestFlight? Set the repository variable `SKIP_TESTFLIGHT` to `true`. You then don't need the App Store Connect app record either.

**Signing by hand with two profiles** (on a Mac): create an ad hoc profile for `<your bundle ID>` (with Push) and one for `<your bundle ID>.NotificationService`, then re-sign the unsigned IPA with fastlane, giving each bundle its own profile:

```bash
fastlane sigh resign ./DriftMail.ipa \
  --signing_identity "Apple Distribution: Your Name (TEAMID)" \
  -p "app.driftmail.DriftMail=./app.mobileprovision" \
  -p "app.driftmail.DriftMail.NotificationService=./ext.mobileprovision"
```

The bundle IDs in the unsigned IPA are `app.driftmail.DriftMail` and `app.driftmail.DriftMail.NotificationService`. If your profiles use different IDs, the workflow route above is simpler, because it builds with your bundle ID from the start.

## Project layout

```
DriftMail/
  App/        App entry, notification + deep-link handling, background refresh
  Mail/       IMAP client and parser, SMTP client, MIME parser and builder
  Services/   MailStore (state), account sessions, Keychain, relay client
  Views/      SwiftUI screens (split view, list, message, compose, setup)
NotificationService/  Extension that decrypts end-to-end encrypted notifications
Shared/       Code shared by the app and the extension (keychain group secrets)
worker/       Cloudflare Worker relay (no dependencies)
project.yml   XcodeGen project spec
```
