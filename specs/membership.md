# Membership

Who may use Presence, how people get access (they subscribe at
nu01.com), and the voucher codes that let them in too. Roles come from
[rbacr](https://github.com/prodbytes/rbacr), the organisation's role
manager, through the [auth API](auth-api.md); its `presence` system's
roles, in brackets below:

| Who | Roles | Sees |
|---|---|---|
| Unknown user | none | the camera, the account button and **Sign up**: nothing else |
| Member (`free`) | `presence_user` | every feature: tabs, camera buttons; devices sync over live sync, at most every 30 s |
| Premium member (`premium`) | `presence_user`, `presence_premium` | as Member, and cloud sync |
| Admin (`admin`) | `presence_user`, `presence_premium`, `presence_admin` | every feature, plus the **Admin** tab; lists and deletes vouchers; live sync always connected |
| Root (rbacr's root list) | all four, `presence_root` too | as Admin, and also sees and deletes Admin vouchers |

Roots are **rbacr's roots**: the addresses and domains on rbacr's root
list (`@nu01.com` by default), configured in rbacr, not here. They get
every role, and nothing else gives `presence_root`. Everyone else starts
unknown, and gets roles by subscribing at nu01.com, from a voucher code
redeemed here (rbacr grants of `free` or `admin`), or from rbacr directly
(its pages, its own vouchers, and its Substack sync, which gives
`premium`). So in presence admins are made only by roots. An account linked to another's profile shares its membership
(`presence_user`) and premium only, never `presence_admin` or
`presence_root`.

Members are **premium** or **free** ([Premium and free](premium.md)):
premium profiles sync with the cloud; free ones' devices sync with each
other over live sync only. This app's vouchers grant membership or
admin, not premium alone. Roles also
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
  Enter redeems too. It posts the code as plain text to
  `POST /api/auth/voucher`. A valid code clears the field and re-asks
  `GET /api/auth`, so the user gets in at once. A valid code with a
  discount under 100% (402) says "That code gives 25% off. Paying the rest
  isn't available yet, so it can't let you in." and keeps the code. An
  invalid, not yet valid, expired or used-up code (404) says "That code
  is invalid, expired or used up."; the field takes up to 40 characters,
  as long as a chosen code may be. Too many tries (429: the route's
  throttle, or 10 wrong codes from this email within an hour) says "Too
  many tries. Wait a while and try again.";
- **Check again** re-asks `GET /api/auth`, so a user who just subscribed
  gets in without signing out.

The auth API's request routes (`POST /api/auth/membership`, and the
Admin's list, grant and dismiss) are gone with `MembershipHandler`. Its
table (`MembershipTable`) leaves the auth API's stack but is kept in AWS
(`DeletionPolicy: Retain`), with the requests sent before.

## Voucher codes

A voucher grants a role to whoever redeems it. Codes are created in
rbacr; the app only lists and deletes them (on the Admin tab) and redeems
them. The auth API's rules for a code:

- **Code:** random when left blank, or, for a Member voucher only, the
  admin's choice. The code
  is a voucher's only secret, so an **Admin voucher always gets a random
  code** (a chosen one is refused, 400), and a chosen code needs **at
  least 10 letters and digits** (dashes aside) and at most 40 characters:
  letters (A to Z), digits and dashes; it's stored upper case, its words
  joined by single dashes, so `autumn otter_4821` is `AUTUMN-OTTER-4821`.
  A taken code is refused (409). A random code is `XXXX-XXXX-XXXX`
  (`SecureRandom`) from 32 characters without `0`, `O`, `1` or `I`: 60
  bits. Typed codes ignore case and separators (spaces, dashes,
  underscores); twelve characters of that alphabet, typed whole or as
  three groups of four, take the random form. Redeeming and deleting take
  codes from 6 characters, for vouchers made before the 10-character rule.
- **Discount:** a percentage, 1 to 100, 100 by default. Only a 100%
  voucher grants its role. A valid voucher with less is answered 402 with
  its discount: no role is granted and no use is counted, because the
  user would pay the rest, and payment isn't built yet.
- **Role:** `presence_user` (Member) or `presence_admin` (Admin). An Admin
  voucher also grants `presence_user`, since the Admin tab needs both.
  Only a `presence_root` may create an Admin voucher (403 for other
  admins), and no voucher grants `presence_root` (400).
- **Validity:** a start (`startsAt`) and an end (`expiresAt`) instant.
  The end is in the future and at most 366 days away; the start is before
  the end, and may be up to 366 days in the past; without one,
  the voucher is valid from its creation. A code is redeemable from its
  start until its end.
- **Uses:** 1 to 1000. Each email may redeem a voucher once.

`VoucherTable` keeps one item per code: `code`, `role`, `startsAt`,
`expiresAt` and `createdAt` (epoch ms), `maxUses`, `uses`, `redeemedBy` (a
string set of emails), `createdBy` and `discount` (vouchers from before
discounts, which have none, are read as 100; vouchers from before start
dates, which have no `startsAt`, start at `createdAt`). Redeeming is one
conditional update (the code exists, `startsAt` is missing or not after
now, `expiresAt` is after now, `uses < maxUses`, and the email isn't in
`redeemedBy`), so concurrent redemptions can't overspend a code. The role
is then granted in rbacr (`free` for a Member voucher, `admin` for an
Admin one, to the redeemer's address, for good); if that fails (rbacr
down, refusing), the use is given back and the answer is 502. The answer
lists the app's roles the grant gives: `["presence_user"]`, or
`["presence_admin", "presence_premium", "presence_user"]`. Every other refused code gets the same 404, so it doesn't tell which
of unknown, not yet valid, expired, used up or already used it is, and the
route is throttled (1 a second, burst 5). The update's condition also
requires a full discount (or none stored, for vouchers from before
discounts); when it fails, the code is read back, and one this email could
otherwise redeem with a partial discount gets 402 instead of 404: a 402
does tell that such a code exists.

**Lockout:** each 404 counts against the email in its `UserRolesTable`
item (`voucherMisses` since `voucherMissesSince`, epoch ms; the table
holds nothing else now). After **10 wrong codes within an hour** of the first, the
email gets **429** "too many wrong codes; try again later" for the rest
of that hour, even for a good code; the next miss after it starts a new
hour. A 402 isn't a miss. With the shared throttle, guessing a random
code stays hopeless and a 10-character chosen one slow.

## The Admin tab

The **Admin** tab (`HomeTab.admin`, `Icons.admin_panel_settings`, tooltip
"Admin") is the last tab in the bottom navigation bar, after Settings, Help
(and the Log when shown), for signed-in users with both roles; never in DEV,
where there are no accounts. Like the other tabs it slides in when tapped,
with the app bar naming it "Admin", with no back button, and a browser refresh comes back to it. Its page is
`AdminView`
([lib/auth/admin_screen.dart](../presence_app/lib/auth/admin_screen.dart)),
a tab page with no scaffold or app bar of its own: one scrolling page,
up to 720 dp wide, with three sections: the [maintenance mode](maintenance.md#switching-it)
card (with Reload by its heading), the members'
[feedback](feedback.md#on-the-admin-tab) (their Help tab conversations,
with a Reply field each) and the voucher codes. It loads them each time
it's opened.

**Feedback**, after maintenance mode: every member's conversation, the
latest active first, each saying whether it awaits a reply; opened, the
whole conversation and **Reply**. See [Feedback and
Help](feedback.md#on-the-admin-tab).

**Voucher codes**, after the feedback:

- no form: **codes are created in rbacr**, not here. A line under the
  heading says so: "Whoever redeems a code on the Sign up sheet
  gets its role at once. Codes are created in rbacr.";
- every voucher, newest first, as cards: the code (selectable, monospace;
  struck through with "Expired", "Used up" or "Not yet valid" when it
  can't be redeemed), its role, its discount ("25% off"), "N of M used",
  "valid from" its start and "expires" its end, who redeemed it, and **Copy code**
  and **Delete** buttons. "No vouchers." when there are none. To an admin
  who isn't a root, an Admin voucher shows "Hidden code" with no buttons:
  the API sends it without its code (`"code": null, "hidden": true`) and
  refuses to delete it (403), so an admin can't pass the Admin role on.

**Reload** (a refresh icon beside the "Maintenance mode" heading, the
page's first) and pull to refresh fetch all three again; each section
shows its own loading error.

The admin routes check both roles themselves, as the app does, so hiding
the tab is not the only guard. `MembershipClient` ([lib/auth/membership_client.dart](../presence_app/lib/auth/membership_client.dart))
is the app's client (a fake in tests).

## Known limitations

- `presence_admin` comes from a root's Admin voucher or a grant of
  `admin` in rbacr, for the account's own email: never from the owner of
  a profile the account is linked to.
- Taking a role back, a domain or time-limited grant, and the root list
  are rbacr's: there's no screen for them here.
- Deleting a voucher, or its expiry, doesn't take back the roles it
  granted.
- When rbacr can't answer, nobody has a role (it fails closed): the app
  shows signed-in users as unknown until it answers again.
- The voucher codes themselves still live here (`VoucherTable`), not in
  rbacr, until rbacr can redeem a code for another address.
- The app no longer creates codes (that's rbacr's, 2026-10-10). Until
  rbacr creates the codes this app redeems, a new one can only be made
  through the auth API's `POST /api/auth/vouchers`, by an admin's token
  (see [Auth API](auth-api.md)); its rules are under **Code**,
  **Discount** and the dates above.
- Codes chosen through the API can be easier to guess than random ones
  (at least 10 letters and digits); keep few uses and short expiries on
  them.
- A code redeemed before its start gets the same 404 as an
  invalid one, so users aren't told it will work later.
- Vouchers under 100% can't be used yet: paying the rest isn't built.
  The 402 tells a valid partial code from an invalid one, but only for
  codes that work.
- Vouchers are listed with a table scan: fine for the few an
  administrator creates, not for thousands.
- There is no way to revoke access from the app; remove the role in the
  table.
- A user who just subscribed sees it only after **Check again** or a new
  sign-in (a voucher re-checks at once).
