# Privacy policy and terms of service

The site serves Presence's **Privacy Policy** at **`/privacy`**, its
**Terms of Service** at **`/tos`** and how to **delete an account** at
**`/delete-account`** (https://presence.nu01.com/privacy,
https://presence.nu01.com/tos, https://presence.nu01.com/delete-account,
and the RC's), as static pages of the [site index](site-index.md) module:

- [presence_index/site/privacy/index.html](../presence_index/site/privacy/index.html),
  [site/tos/index.html](../presence_index/site/tos/index.html) and
  [site/delete-account/index.html](../presence_index/site/delete-account/index.html),
  with a shared stylesheet, [site/legal.css](../presence_index/site/legal.css).
  No scripts and no external fonts or images.
- **The app links to them** ([About](about.md)): the account sheet's
  About, the [consent](consent.md) screen, and signed out the bottom of
  the camera, on the same site as the app's API; on iOS and Android also
  next to the store purchase buttons ([Upgrade](upgrade.md)). Google's
  OAuth consent screen can point at them too. On the web the Delete
  account dialog links to the deletion page's subscriptions part
  ([Account deletion](account-deletion.md)).
- Each links to the others and to the app (`/app/`), with a canonical URL
  and an effective date (Privacy Policy and Terms 15 October 2026, the deletion page 14 October 2026). The operator is
  **ProdBytes**; the contact is julio@nu01.com.
- The look: the app's Gruvbox palette ([Theme](theme.md)), dark or light
  as the system is, a 44 rem column, and on phones (under 560 px) the
  privacy policy's data table stacks each row as a card ("From:",
  "Why:").

## What they say

- **Privacy Policy**: what's collected (the Google account's email, name,
  picture and ID; the profile and linked accounts; device IDs, OS,
  battery and location; recordings, clips and thumbnails; events, names
  and object tags; face and body features of named subjects, as numbers;
  settings; Feedback & Help messages; the subscription's status; a
  subscription bought in the app: its store, ID, product, end date and a
  random account number; logs), from where and why; that nothing is sold
  or used for ads, and Apple, Google or Stripe hold card details; where it's kept and for how long (on the device for
  the History setting, two weeks by default; Premium's uploads in AWS in
  the United States, videos archived after 67 days, everything erased after 365 days; free sync not stored; media
  encrypted on the device with AES-256-GCM, keys shared through the
  profile's settings, event details not encrypted); who else handles it
  (Google, AWS, Apple and Google for in-app purchases, which don't get the
  email from us, Stripe, rbacr, OpenStreetMap); recording other people
  (the user is responsible, as the [consent](consent.md) screen says, and
  is the controller of those recordings); rights (deleting the account in
  the app, which deletes the owner's whole profile or unlinks a linked
  account, linking to `/delete-account`; copy, correction and deletion by
  email within 30 days; cancelling Premium where it was bought: the App
  Store, Google Play or Stripe; GDPR-style objection, restriction and
  complaints, with the legal bases); accounts and feedback deleted with
  the account; no children under 16; changes; contact.
- **Delete your account** (`/delete-account`): how, in the app and by
  email from the account's address, what's deleted (owner and linked
  account), what's kept and for how long (payment records with Apple,
  Google or Stripe), and that Premium isn't cancelled (`#subscriptions`:
  in the App Store's or Google Play's subscription settings for one bought
  in the app, from a Stripe receipt for one bought on the web). See
  [Account deletion](account-deletion.md#without-the-app).
- **Terms of Service**: the service; accounts (a Google account, 16 or
  older); recording lawfully (only where allowed, telling people, no
  spying or recording where others expect privacy); acceptable use (the
  MIT licence covers the code, the terms the service); [Premium](upgrade.md)
  (monthly or yearly, at the price shown before buying; in the iPhone and
  Android apps bought from the App Store or Google Play; a free trial when
  offered, for the period shown; renewing until cancelled where it was
  bought, in the store's account settings at least 24 hours before the
  period ends; store refunds by Apple's and Google's policies, others
  only where the law requires; an in-app subscription gives Premium to
  the account signed in when buying and can't be moved; otherwise the
  subscribing email must be the Google account's; 30 days' notice of
  price changes; payments by Apple, Google or Stripe); content stays the user's (cloud
  videos archived after 67 days, every copy erased after 365); availability "as is", not an emergency
  system; liability capped at 12 months' payments; ending (a refund of an
  unused period if the service stops); changes; contact.

## Serving

- **AWS** ([Production deploy](deploy.md)): `scripts/deploy.sh` uploads
  all of `presence_index/site/` to the bucket's root (`aws s3 sync`,
  `no-cache`, never `app/*`). A CloudFront Function on the default
  behavior (`<stack>-pages`, viewer request) serves `/privacy`, `/tos` and
  `/delete-account`, with or without the slash, from their `index.html`;
  other paths pass as they are. The index's headers policy covers them,
  with `style-src 'self'` for the stylesheet. The deploy's smoke test
  checks that `/privacy`, `/tos` and `/delete-account` answer with their
  titles.
- **Locally**: `devbox services up` serves `site/` with Python's
  `http.server`, which redirects `/privacy` to `/privacy/` (and `/tos` and
  `/delete-account` likewise) and serves its `index.html`.

## Known limitations

- **Drafts, not legal advice.** The texts describe how Presence works as
  of the effective date; a lawyer should review them, and they name no
  governing law or registered address.
- **English only**, unlike the app.
