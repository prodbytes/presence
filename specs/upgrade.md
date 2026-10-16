# Upgrade to Premium (and Pro)

A free member upgrades to [Premium](premium.md) from the app, where its
build sells it; a premium member upgrades to Pro on the web, once Pro is
configured ([Pro](#pro)):

| Build | How Premium is bought |
|---|---|
| Web | **Stripe**: Premium monthly (**US$20 a month, the first week free**) and Premium yearly open the plan's Stripe checkout ([below](#on-the-web-stripe)) |
| iOS | the **App Store**: two auto-renewing subscriptions ([below](#on-ios-and-android-the-stores)) |
| Android | **Google Play**: the same two subscriptions |
| Linux, macOS and others | not sold: no purchase buttons |

`PurchaseChannel.current`
([store_billing.dart](../presence_app/lib/auth/store_billing.dart)) decides:
`stripe` on the web, `appStore` on iOS, `googlePlay` on Android, `none`
elsewhere. Premium members, admins, users without access and DEV never see
purchase buttons. Someone already Premium some other way (Stripe on the
web, a voucher, an admin's grant) just sees Premium on every platform.

The iOS and Android apps never show, link to or mention Stripe,
nu01.com's sign-up page or a web price (App Store 3.1.1, Google Play's
payments policy): not in the plan box, the Profile tab's hidden-devices
line, the fallback when the payments API doesn't answer, or the sign-up
sheet, which offers [Join free](membership.md#getting-access-join-free-or-subscribe)
in the app instead.

## Where

- **The account sheet** ([Sign-in](sign-in.md)), in the plan box under the
  profile's devices (`PlanNotice`,
  [plan_notice.dart](../presence_app/lib/auth/plan_notice.dart)), for a
  free member only (not `isPremium` or `isAdmin`):
  - **Web**: the Free text ends "Premium adds cloud backup and up to 25
    devices: US$20 a month, the first week free. Pro: up to 50 devices."; **Premium monthly** and
    **Premium yearly** (filled buttons, the `workspace_premium` icon), one
    per plan the payments API has a link for, open that plan's checkout in
    the browser, or copy its link where it can't open; with neither link
    (the API didn't answer, or offers no plan), a single **Upgrade to
    Premium** opens https://nu01.com instead.
  - **iOS and Android**: the Free text without a price ("… Premium adds
    cloud backup and up to 25 devices."), then the store's plans
    (`StorePlans`, [store_plans.dart](../presence_app/lib/auth/store_plans.dart)).
  - **Elsewhere**: the Free text without a price, and no purchase button.
  - **Check again** beside them checks the roles again
    (`RolesService.refresh`), so once the subscription has reached rbacr
    the box turns Premium without signing out.
  - A member who is Premium through a subscription verified in this
    store (iOS, Android) gets **Manage subscription** in the box.
- **The account sheet's** hidden-devices line (`HiddenDevicesLine`),
  just above the plan box when devices are hidden: "3 devices hidden ·
  **Upgrade**", small and muted. On the web only, Upgrade opens, for a
  free profile, the monthly plan's checkout (the yearly's when there's no
  monthly link, nu01.com when neither), and for a premium profile with a
  Pro link, Pro's checkout ([below](#pro)); on iOS, Android and elsewhere
  no link. The Monitoring tab has no upgrade notice.

## Pro

A premium member upgrades to [Pro](premium.md) (50 devices instead of
25, everything else as Premium) **on the web only**, and only once it's
configured: nothing about Pro's prices or products is in this repo.

- **The links** are data, as Premium's: the payments API's `GET
  /api/payments/links` answers **`proMonthly`** and **`proYearly`** too
  (empty until an admin saves them; they have no deploy defaults), and the
  Admin tab's Payments section has a **Pro monthly plan link** and a **Pro
  yearly plan link** field ([Payments API](payments-api.md)). Each must be
  empty or a Stripe HTTPS link, as Premium's.
- **The buttons**: a premium member's plan box shows **Pro monthly** and
  **Pro yearly**, one per Pro link set, opening the checkout as Premium's
  do (`PremiumCheckout.checkout`: the email locked, the profile as
  `client_reference_id`). With no Pro link, no Pro button, though the plan
  text still says Pro has 50 devices. A free member sees Premium's buttons
  only; a Pro member or an admin, none.
- **How it becomes Pro**: rbacr's Stripe sync must grant the `presence`
  system's **`pro`** role to a Pro subscriber (and `premium` to a Premium
  one). Today rbacr grants one `subscriberRole` per system to every
  subscriber of its Stripe account, so selling Pro needs rbacr to map
  Pro's Stripe product (or price) to `pro`. Until then, **don't save Pro's
  links**: a Pro checkout would grant `premium`.
- **Not in the stores yet**: there are no Pro App Store or Google Play
  products; the iOS and Android apps don't offer or mention Pro, and the
  payments API's store verification knows Premium's products only (and
  grants `premium`). Selling Pro there needs its products in both stores,
  their IDs in `StorePurchase.PRODUCTS` and `StoreBilling`, and the grant
  of `pro` for them.
- **Switching from Premium to Pro** on the web is a second Stripe
  subscription: the member cancels Premium's in Stripe themselves.

## On the web: Stripe

`PremiumCheckout.checkout`
([premium_checkout.dart](../presence_app/lib/auth/premium_checkout.dart))
builds the checkout from the plan's Stripe Payment Link
(`PaymentsService.links`, from the [payments API](payments-api.md)):

- `prefilled_email` is the signed-in account's email, and
  `locked_prefilled_email=true` keeps the customer from changing it:
  rbacr matches subscribers by email only.
- `client_reference_id` is the profile ID
  (`automatic_paranoid_axolotl`), when it's one Stripe takes (letters,
  digits, `-`, `_`, up to 200), so a payment can be traced to a profile.
- The link's own parameters are kept.
- Only an HTTPS link on `stripe.com` (or a subdomain, such as
  `buy.stripe.com`) is used. Without one, the button opens
  https://nu01.com, as the old Sign up button did.

The prices and the trial are the Payment Links', set in Stripe: the
monthly plan a recurring price of US$20 a month, with a 7-day free trial
(`subscription_data.trial_period_days`). The app only says so (the
`authPlanFreeText` string, in English, Spanish and Portuguese).

### How it becomes Premium

Presence has no Stripe code of its own. The Payment Link belongs to the
Stripe account rbacr syncs subscriptions from (rbacr's Q1 to Q3):

    Upgrade to Premium -> Stripe checkout (email locked) -> subscription (trialing)
      -> customer.subscription.* webhook -> rbacr POST /webhooks/stripe
      -> grant of the presence system's subscriberRole (premium) to the email

- A subscription that is `trialing`, `active` or `past_due` grants the
  `presence` system's `subscriberRole`, which must be `premium`
  (`PATCH /api/systems/presence`, a root). The grant runs for the billing
  period (the trial week first), and moves with each renewal.
- A cancelled or unpaid subscription revokes it; the profile becomes free
  ([Premium and free](premium.md#what-each-syncs)).
- The app sees it at its next roles check: **Check again**, a new sign-in,
  or reloading the app.

## On iOS and Android: the stores

Two auto-renewing subscriptions, with the **same product IDs in both
stores**:

| Product ID | Renews | Trial |
|---|---|---|
| `presence.premium.monthly` | every month | 1 week free (set up in each store) |
| `presence.premium.yearly` | every year | none |

The app uses the official [`in_app_purchase`](https://pub.dev/packages/in_app_purchase)
plugin (pinned: 3.3.1, with `in_app_purchase_storekit` 0.4.13+2, StoreKit
2, and `in_app_purchase_android` 0.5.4, Play Billing). `StoreBilling`
([store_billing.dart](../presence_app/lib/auth/store_billing.dart)) runs
it, for the signed-in account:

- **At sign-in** it asks the payments API which stores it verifies and
  the account's token (`GET /api/payments/store`), then the store for the
  two products. Without the API's go-ahead for this store (store purchases
  not configured, or the API didn't answer), or when the store doesn't
  answer, the box says "Purchases aren't available right now." and offers
  nothing to buy.
- **The plans** (`StorePlans`): a filled button per product the store
  returns, "Premium monthly: US$19.99 / month", with the store's own
  localized price and period, never hardcoded; under it, when the store
  gives this user a free trial, "1 week free, then US$19.99 / month."
  (Google Play lists the trial as its own offer, only to users who may
  have it; on iOS the introductory offer shows when StoreKit says the user
  is eligible). Then:
  - **Restore purchases** (Apple requires it): the store's current
    subscriptions are verified again; "Your subscription is restored." or
    "No active subscription to restore.";
  - **Manage subscription**: https://apps.apple.com/account/subscriptions
    on iOS; on Android
    https://play.google.com/store/account/subscriptions?sku=<product>&package=com.nu01.presence
    (the product once one is verified);
  - **Check again**;
  - "Subscriptions renew automatically until you cancel them in your App
    Store (Google Play) account settings, at least 24 hours before the
    period ends.";
  - **Terms of Service** and **Privacy Policy**, the site's `/tos` and
    `/privacy` ([Legal](legal.md)), next to the purchase buttons (App
    Store 3.1.2).
- **Buying** passes the account's token as the purchase's
  `applicationUserName`: StoreKit 2's `appAccountToken`, Play's
  `obfuscatedAccountId`. It's a random UUID the payments API made for the
  account (not the email or anything personal), so the purchase is bound
  to it in the store's records too.
- **Every purchase the store reports** (bought, renewed, restored) goes
  to `POST /api/payments/store/verify` with the store's own proof (the
  plugin's `serverVerificationData`: StoreKit 2's signed transaction, or
  Play's purchase token). Only once the API has verified it with the
  store and granted Premium is the purchase **completed** (StoreKit's
  `finish`, Play's acknowledgement); a purchase the API couldn't check
  (502, 503, offline) stays unfinished, so the store reports it again and
  it's tried again. Then the roles are checked again, so the app turns
  Premium at once.
- **Renewals.** At sign-in, and **once a day while running** (unattended
  phones), it restores the current subscriptions quietly and verifies them
  again: each renewal moves the rbacr grant to the new period's end. On
  iOS, StoreKit also reports renewals as they happen while the app runs,
  and the App Store's server notifications reach the API directly.
- **What it says**: "Purchase pending: Premium starts once the store
  confirms it.", "Thank you! Premium is on.", "This subscription belongs
  to another Presence account." (409), "The store didn't confirm this
  purchase." (400), "Couldn't confirm the purchase with Presence yet.
  It's tried again automatically." (502, 503, offline), "The purchase
  didn't go through." (a store error). The quiet checks say nothing.
- Signed out, nothing is bought or verified; a purchase reported then
  stays unfinished until someone signs in.

### How it becomes Premium

    Buy in the app (appAccountToken / obfuscatedAccountId = the account's token)
      -> store purchase -> POST /api/payments/store/verify (signed transaction / purchase token)
      -> the payments API checks it with the store (Apple's signature, Google's API)
      -> bound to the caller's verified email -> rbacr grant of premium until the period's end + 2 days
      -> the app finishes the purchase and checks its roles

See [Payments API](payments-api.md#store-purchases) for what's checked.

## Setting it up

### Stripe (the web)

1. In the Stripe account rbacr syncs from: a product "Presence Premium",
   a monthly price of US$20 with a 7-day free trial and a yearly price,
   and a Payment Link for each. Their confirmation pages can send the
   customer back to https://presence.nu01.com/app/.
2. In rbacr: the `presence` system's `subscriberRole` set to `premium`.
3. The links: the deploy's defaults (`STRIPE_MONTHLY_LINK`,
   `STRIPE_YEARLY_LINK`; see [Payments API](payments-api.md#deploying)),
   or an admin's, saved in the Admin tab's Payments.
4. **Pro** (when it's to be sold): in rbacr, the `presence` system's
   `pro` role, and a Stripe sync that grants it to Pro's subscribers;
   in Stripe, a product "Presence Pro" with its prices and a Payment Link
   each; then the links saved in the Admin tab's Pro fields
   ([Pro](#pro)).

### App Store Connect (iOS)

1. The app record for bundle ID `com.nu01.presence`, and the Paid
   Applications agreement, banking and tax forms signed (subscriptions
   can't be sold, or tested in the sandbox, without them).
2. **Subscriptions**: a subscription group (for example "Presence
   Premium") with two auto-renewable subscriptions, product IDs
   `presence.premium.monthly` (1 month) and `presence.premium.yearly` (1
   year), each with its price, localized display name and description
   (English, Spanish, Portuguese) and a review screenshot. Both in the
   same group, so a member holds one at a time and can switch.
3. **The trial**: on `presence.premium.monthly`, an introductory offer,
   "Free", duration 1 week, for new subscribers in every territory.
4. **App Store Server Notifications**: Version 2, production URL
   https://presence.nu01.com/api/payments/store/apple-notifications and
   sandbox URL https://rc.presence.nu01.com/api/payments/store/apple-notifications.
   Use **Request a Test Notification** to check (the API answers 200 to a
   `TEST`).
5. Sandbox testers (Users and Access → Sandbox) to try purchases with the
   RC or a TestFlight build.
6. Submit both subscriptions with the app version that first sells them.

### Google Play Console (Android)

1. The app `com.nu01.presence` in Play Console, a payments profile, and an
   App Bundle uploaded to a testing track (Play lists products only for
   an app with an uploaded build that has the Billing library).
2. **Subscriptions** (Monetize → Products → Subscriptions): two, product
   IDs `presence.premium.monthly` and `presence.premium.yearly`, each with
   **one auto-renewing base plan** (billing period 1 month, and 1 year),
   prices and localized names; activate the base plans.
3. **The trial**: on the monthly subscription's base plan, an offer with
   a **free trial phase of 1 week**, eligibility "New customer acquisition
   (never had this subscription)"; activate it.
4. **A service account** for the payments API: in Google Cloud (a
   project linked to Play Console), enable the **Google Play Android
   Developer API**, create a service account, and add a JSON key. In Play
   Console → **Users and permissions**, invite the service account's email
   with the app's permissions **View financial data, orders, and
   cancellation survey responses** and **Manage orders and
   subscriptions**. (It can take up to a day to start working.)
5. Store the key file in AWS Secrets Manager, in the stage's account and
   region, named under its prefix, for example
   `aws secretsmanager create-secret --name presence/google-play-service-account --secret-string file://key.json`
   (and `presence-rc/google-play-service-account` for the RC), encrypted
   with the default `aws/secretsmanager` key; then set
   `GOOGLE_PLAY_SECRET` ([Payments API](payments-api.md#deploying)) and
   delete the downloaded key.
6. License testers (Settings → License testing) to buy without being
   charged on the RC.

### rbacr and the deploy

1. An rbacr API token owned by an **rbacr root** (only roots may grant;
   the auth API's `RBACR_TOKEN` is a root's and works) as
   `RBACR_GRANT_TOKEN`: the `RBACR_GRANT_TOKEN` repository secret (CI)
   and `.env`. Until it's set, store purchases are off.
2. Re-apply `presence-github-deploy` (it lets the payments function read
   the stage's secrets), then deploy.

## Known limitations

- **One Stripe account for everything (web).** rbacr's sync grants every
  system's subscriber role to any subscriber of that account, so a
  Presence subscriber also gets other systems' subscriber roles, and a
  newsletter subscriber gets Presence Premium.
- **The email must be the account's (web).** A subscription paid under
  another email (for example through another link) doesn't make this
  account premium; a linked account shares its profile owner's premium
  only ([Profiles](profiles.md)).
- **No manage or cancel button on the web**: Stripe customers manage
  their subscription from Stripe's receipts (or a customer portal, if one
  is set up in Stripe).
- **The yearly Stripe plan's price isn't shown**: the web buttons name the
  plans, and only the monthly price is in the plan text; Stripe's
  checkout shows each.
- **It shows up after a check (web):** the app doesn't learn of a Stripe
  payment by itself; **Check again** right after paying may come before
  Stripe's webhook has reached rbacr (usually seconds).
- **A store purchase belongs to the account that made it.** It can't be
  moved to another Presence account (409), even by its Apple or Google
  account's owner; support would have to change the binding in the
  payments table.
- **Switching plans in the store** (monthly to yearly) isn't offered in
  the app: the plan buttons show only to free members. On iOS both are in
  one group, so the App Store's subscription page switches them; on
  Android buying the other plan would be a second subscription.
- **Not shown in the iOS app before it's eligible**: the plugin doesn't
  give the introductory offer's eligibility on old iOS versions; then no
  trial line shows, though the App Store's sheet still offers it.
- **Google Play's renewals and refunds reach the API only through the
  app**: a renewal while the app doesn't run extends Premium at the
  app's next start or daily check (the 2-day grace covers a day's gap); a
  Google refund or revocation isn't seen until the grant runs out.
  Real-time developer notifications (Pub/Sub) are a follow-up.
- **Untested against the real stores**: tested with a fake store and a
  fake Apple certificate chain; the products, notifications and service
  account don't exist yet.
