# Upgrade to Premium

A free member upgrades to [Premium](premium.md) from the app: **Premium
monthly** (**US$20 a month, the first week free**) and **Premium yearly**
open the plan's Stripe checkout, on every platform (web, Android, iOS,
Linux). The links come from the [payments API](payments-api.md), and
admins set them in the Admin tab. Premium members, admins, users without
access and DEV never see the buttons.

## Where

- **The account sheet** ([Sign-in](sign-in.md)), in the plan box under the
  profile's devices (`PlanNotice`,
  [plan_notice.dart](../presence_app/lib/auth/plan_notice.dart)), for a
  free member only (not `isPremium` or `isAdmin`):
  - the Free text ends "Premium adds cloud backup and up to 50 devices:
    US$20 a month, the first week free.";
  - **Premium monthly** and **Premium yearly** (filled buttons, the
    `workspace_premium` icon), one per plan the payments API has a link
    for, open that plan's checkout in the browser, or copy its link where
    it can't open;
  - with neither link (the API didn't answer, or offers no plan), a single
    **Upgrade to Premium** opens https://nu01.com instead;
  - **Check again** beside it checks the roles again
    (`RolesService.refresh`), so once the subscription has reached rbacr
    the box turns Premium without signing out.
- **The Monitoring tab's** hidden-devices card (`DeviceLimitNotice`), for
  a free profile: "… Premium shows up to 50." and an **Upgrade** button to
  the monthly plan's checkout (the yearly's when there's no monthly link,
  nu01.com when neither).

## The checkout

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

## How it becomes Premium

Presence has no payment code of its own. The Payment Link belongs to the
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

## Setting it up

1. In the Stripe account rbacr syncs from: a product "Presence Premium",
   a monthly price of US$20 with a 7-day free trial and a yearly price,
   and a Payment Link for each. Their confirmation pages can send the
   customer back to https://presence.nu01.com/app/.
2. In rbacr: the `presence` system's `subscriberRole` set to `premium`.
3. The links: the deploy's defaults (`STRIPE_MONTHLY_LINK`,
   `STRIPE_YEARLY_LINK`; see [Payments API](payments-api.md#deploying)),
   or an admin's, saved in the Admin tab's Payments.

## Known limitations

- **Stripe on every platform.** Android and iOS open the Stripe checkout
  in the browser, not Google Play or App Store subscriptions: the apps
  aren't in either store (a side-loaded APK, development iOS builds), and
  a store purchase wouldn't reach rbacr. Once they're listed, the stores'
  rules require their own billing for in-app digital subscriptions; that
  needs store products and a server that verifies purchases and grants
  `premium` in rbacr, neither of which exists yet.
- **One Stripe account for everything.** rbacr's sync grants every
  system's subscriber role to any subscriber of that account, so a
  Presence subscriber also gets other systems' subscriber roles, and a
  newsletter subscriber gets Presence Premium.
- **The email must be the account's.** A subscription paid under another
  email (for example through another link) doesn't make this account
  premium; a linked account shares its profile owner's premium only
  ([Profiles](profiles.md)).
- **No manage or cancel button** in the app: customers manage their
  subscription from Stripe's receipts (or a customer portal, if one is set
  up in Stripe).
- **The yearly plan's price isn't shown**: the buttons name the plans,
  and only the monthly price is in the plan text; Stripe's checkout shows
  each.
- **It shows up after a check:** the app doesn't learn of the payment by
  itself; **Check again** right after paying may come before Stripe's
  webhook has reached rbacr (usually seconds).
