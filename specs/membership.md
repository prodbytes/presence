# Membership

Who may use Presence, how people get access (they subscribe at
nu01.com), and the voucher codes that let them in too. Roles come from
[rbacr](https://github.com/prodbytes/rbacr), the organisation's role
manager, which the app asks directly with the user's Google ID token
(see [Sign-in](sign-in.md)); its `presence` system's roles, in brackets
below:

| Who | Roles | Sees |
|---|---|---|
| Unknown user | none | the camera, the account button and **Sign up**: nothing else |
| Member (`free`) | `presence_user` | every feature: tabs, camera buttons; devices sync over live sync, at most every 30 s |
| Premium member (`premium`) | `presence_user`, `presence_premium` | as Member, and cloud sync |
| Admin (`admin`) | `presence_user`, `presence_premium`, `presence_admin` | every feature, plus the **Admin** tab (feedback, and a link to rbacr); live sync always connected |
| Root (rbacr's root list) | all four, `presence_root` too | as Admin |

Roots are **rbacr's roots**: the addresses and domains on rbacr's root
list (`@nu01.com` by default), configured in rbacr, not here. They get
every role, and nothing else gives `presence_root`. Everyone else starts
unknown, and gets roles by subscribing at nu01.com (rbacr's Substack
sync gives `premium`), by redeeming a voucher code, or from a grant in
rbacr's pages. Admins (rbacr's `admin` in the `presence` system) are
made in rbacr. An account linked to another's profile shares its
membership (`presence_user`) and premium only, never `presence_admin` or
`presence_root`: the auth API answers them as `shared` in
`GET /api/auth/profile` (see [Profiles](profiles.md)).

Members are **premium** or **free** ([Premium and free](premium.md)):
premium profiles sync with the cloud; free ones' devices sync with each
other over live sync only. Roles also
set limits: **Connect to live sync** is always connected for admins, and at
most every 30 s for members (see [Live sync](live-sync.md#when-it-connects)).

## Getting access: subscribe

Nobody asks for access any more (2026-10-10): **users subscribe at
nu01.com** to become members (Free) or Premium, and rbacr gives the role.
The **Sign up** icon (`SignUpButton`, [lib/auth/account_sheet.dart](../presence_app/lib/auth/account_sheet.dart))
opens "Subscribe" (`SignUpSheet`):

- "<email> doesn't have access to Presence yet. Subscribe at nu01.com:
  Free, or Premium for cloud backup and more devices. Then check again
  here.", and **Subscribe at nu01.com**, which opens https://nu01.com
  (`DeviceSlots.signUp`) in the browser, or copies the link where it
  can't open;
- **Voucher code** and **Redeem** (below a divider, "Have a voucher code?
  Redeem it to get in right away."): disabled while the field is blank;
  Enter redeems too. The field takes up to 64 characters (hint
  `2026Q4-OTTER-FALCON-LEMUR`). It redeems the code with **rbacr**, `POST
  /api/vouchers/redeem` `{"code": "..."}` with the user's ID token, which
  grants the voucher's roles to the caller (see [Voucher
  codes](#voucher-codes)). A valid code clears the field and checks the
  roles again, so the user gets in at once; if they still have no
  access, the roles are checked once more 2 s later, since rbacr's role
  lookups take about a second to see a new grant (rbacr's D3). Refusals:
  - 404 (unknown) and 409 (not started, expired, used up or disabled, or
    already redeemed by this account): "That code is invalid, expired or
    used up.";
  - 402 (a discount under 100%): "That code gives 25% off. Paying the rest
    isn't available yet, so it can't let you in." with rbacr's
    `payment.discountPercent`, or "That code needs a payment, which isn't
    available yet, so it can't let you in." when rbacr gives no percent;
    the code is kept;
  - 429: "Too many tries. Wait a while and try again.";
  - anything else: "Couldn't redeem the code (…)".
- **Check again** asks rbacr and the auth API again, so a user who just
  subscribed gets in without signing out.

The auth API's request routes (`POST /api/auth/membership`, and the
Admin's list, grant and dismiss) are gone with `MembershipHandler`. Its
table (`MembershipTable`) leaves the auth API's stack but is kept in AWS
(`DeletionPolicy: Retain`), with the requests sent before.

## Voucher codes

Vouchers are **rbacr's** (its rules V1 to V9): admins and roots create,
disable and audit them in rbacr's pages, and rbacr redeems them.
Presence keeps no codes and has no voucher routes. In short:

- a code is chosen by a root or made up by rbacr from the quarter and
  three animal names (`2026Q4-OTTER-FALCON-LEMUR`); 6 to 40 letters and
  digits, matched ignoring case and separators;
- a voucher grants one or more roles (for Presence, `free`, `premium` or
  `admin` in the `presence` system, or a global voucher's system roles),
  from a start to an end date, up to a number of uses, once per account;
- only a 100% discount grants: under 100% rbacr answers 402 and grants
  and counts nothing, since payment isn't built;
- every redemption and failed attempt is recorded in rbacr.

Presence's own vouchers were removed on 2026-10-10: `VoucherHandler`,
`POST /api/auth/voucher` (with its throttle and per-email lockout),
`GET`/`POST /api/auth/vouchers` and `/api/auth/vouchers/delete`. Their
tables (`VoucherTable`, and `UserRolesTable` with the lockout's counts)
left the auth API's stack but are kept in AWS (`DeletionPolicy: Retain`)
until deleted by hand.

## The Admin tab

The **Admin** tab (`HomeTab.admin`, `Icons.admin_panel_settings`, tooltip
"Admin") is the last tab in the bottom navigation bar, after Settings, Help
(and the Log when shown), for signed-in users with both roles; never in DEV,
where there are no accounts. Like the other tabs it slides in when tapped,
with the app bar naming it "Admin", with no back button, and a browser refresh comes back to it. Its page is
`AdminView`
([lib/auth/admin_screen.dart](../presence_app/lib/auth/admin_screen.dart)),
a tab page with no scaffold or app bar of its own: one scrolling page,
up to 720 dp wide, with two sections. It loads the feedback each time
it's opened.

**Feedback**, first, with **Reload** (a refresh icon) by its heading:
every member's conversation, the latest active first, each saying
whether it awaits a reply; opened, the whole conversation and **Reply**.
See [Feedback and Help](feedback.md#on-the-admin-tab). Pull to refresh
reloads it too.

**Vouchers and maintenance**, after it: "Voucher codes and maintenance
mode are managed in rbacr, which keeps every role. Members redeem codes
on the Sign up sheet." and a button **Open <rbacr's host>** (e.g. "Open
rbacr.nu01.com"), which opens the build's rbacr (`RbacrConfig.baseUrl`;
see [Configuration](configuration.md#build-time-settings-rbacr)) in the
browser, or copies the link where it can't open. See [Maintenance
mode](maintenance.md).

## Known limitations

- `presence_admin` comes from a grant of `admin` in rbacr (or a voucher
  for it), for the account's own email: never from the owner of a profile
  the account is linked to.
- Taking a role back, a domain or time-limited grant, vouchers and the
  root list are rbacr's: there's no screen for them here, only the link.
- When rbacr can't answer, the roles check fails (deny): the app shows
  signed-in users without access, and retries, until it answers again.
- Vouchers under 100% can't be used yet: paying the rest isn't built.
- Guessing codes is rbacr's to slow (its throttle answers 429; failed
  attempts are recorded).
- A user who just subscribed sees it only after **Check again** or a new
  sign-in (a voucher re-checks at once, and once more 2 s later).
