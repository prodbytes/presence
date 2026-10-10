# Membership

Who may use Presence, how people ask, and the voucher codes that let them
in without asking. Roles come from the
[auth API](auth-api.md):

| Who | Roles | Sees |
|---|---|---|
| Unknown user | none | the camera, the account button and **Sign up**: nothing else |
| Member | `presence_user` | every feature: tabs, camera buttons, cloud sync; live sync at most every 30 s |
| Admin | `presence_user`, `presence_admin` | every feature, plus the **Admin** tab; creates Member vouchers; live sync always connected |
| Root | `presence_user`, `presence_admin`, `presence_root` | as Admin, and also creates Admin vouchers |

Roots are the auth API's **root allowlist**: verified emails at one of
`PRESENCE_ROOT_DOMAINS` (`nu01.com`) from an account of that domain's
Google Workspace (the token's `hd` claim), or listed in
`PRESENCE_ROOT_EMAILS` (none by default; Gmail or Workspace addresses
only). A personal Google account registered with a `nu01.com` address
isn't a root (see [Auth API](auth-api.md)). Roots get all three roles,
and nothing else gives `presence_root`. Everyone else starts unknown, and
gets roles from an administrator's grant or a voucher code. So admins are
made only by roots (or by hand in `UserRolesTable`), and admins can only
add members. An account linked to another's profile shares its
membership (`presence_user`) only, never `presence_admin` or
`presence_root`.

Members are **premium** or **free** ([Premium and free](premium.md)):
rbacr, the organisation's role manager, says who is premium
(`presence_premium`, from its `premium` or `admin` role). Premium profiles
sync with the cloud; free ones' devices sync with each other over live
sync only. This app's vouchers grant membership or admin, not premium
(premium is granted in rbacr, which has vouchers of its own). Roles also
set limits: **Connect to live sync** is always connected for admins, and at
most every 30 s for members (see [Live sync](live-sync.md#when-it-connects)).

## Asking for access

The **Sign up** icon (`SignUpButton`, [lib/auth/account_sheet.dart](../presence_app/lib/auth/account_sheet.dart))
opens "Request access":

- a **Message** field (up to 1000 characters) and **Send request**,
  disabled while the message is blank. It posts the trimmed message as
  plain text to `POST /api/auth/membership` with the Google ID token;
- once sent, the sheet says "Request sent" and that an administrator will
  review it;
- a second request within the hour is refused (409), and the sheet says
  so; throttling (429) says to try again in a minute; other failures show
  their error;
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
- **Check again** re-asks `GET /api/auth`, so a granted user gets in
  without signing out.

The API keeps one request per email in `MembershipTable` (email, Google
profile name cleaned to one line of 100 characters, message, time in epoch
milliseconds). No notification is sent: administrators see pending
requests when they open the Admin tab.

## Voucher codes

A voucher grants a role to whoever redeems it:

- **Code:** random when left blank (the app's default), or, for a Member
  voucher only, the admin's choice; the app suggests the current season,
  an animal and a number (`AUTUMN-OTTER-4821`) only when asked. The code
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
  the end, and may be up to 366 days in the past (the start of the
  season); without one,
  the voucher is valid from its creation. A code is redeemable from its
  start until its end. The app picks two days, and makes the code valid
  from the start of the first through the end of the last (local time):
  the current season's first and last days by default.
- **Uses:** 1 to 1000. Each email may redeem a voucher once.

`VoucherTable` keeps one item per code: `code`, `role`, `startsAt`,
`expiresAt` and `createdAt` (epoch ms), `maxUses`, `uses`, `redeemedBy` (a
string set of emails), `createdBy` and `discount` (vouchers from before
discounts, which have none, are read as 100; vouchers from before start
dates, which have no `startsAt`, start at `createdAt`). Redeeming is one
conditional update (the code exists, `startsAt` is missing or not after
now, `expiresAt` is after now, `uses < maxUses`, and the email isn't in
`redeemedBy`), so concurrent redemptions can't overspend a code. The role
is then added to the user's roles in `UserRolesTable` (one atomic `ADD` to
the string set); if that fails, the use is given back and the answer is
502. Every other refused code gets the same 404, so it doesn't tell which
of unknown, not yet valid, expired, used up or already used it is, and the
route is throttled (1 a second, burst 5). The update's condition also
requires a full discount (or none stored, for vouchers from before
discounts); when it fails, the code is read back, and one this email could
otherwise redeem with a partial discount gets 402 instead of 404: a 402
does tell that such a code exists.

**Lockout:** each 404 counts against the email in its `UserRolesTable`
item (`voucherMisses` since `voucherMissesSince`, epoch ms; no role is
declared by it). After **10 wrong codes within an hour** of the first, the
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
up to 720 dp wide, with three sections: the membership requests, the
members' [feedback](feedback.md#on-the-admin-tab) (their Help tab
conversations, with a Reply field each) and the voucher codes. It loads
the three lists each time it's opened.

**Membership requests:**

- the pending requests, oldest first, as cards: name, email, date and
  message;
- **Grant access** adds `presence_user` to that email's roles in
  `UserRolesTable` (one atomic `ADD` to its string set; roles written by
  hand as a list or a string are rewritten as a set first) and
  removes the request. **Dismiss** hides it: the row stays, marked
  `dismissed`, so the requester still waits out the hour before asking
  again. A message confirms either;
- "No pending requests." when there are none.

**Feedback**, after the requests: every member's conversation, the
latest active first, each saying whether it awaits a reply; opened, the
whole conversation and **Reply**. See [Feedback and
Help](feedback.md#on-the-admin-tab).

**Voucher codes**, after the feedback:

- a form: **Code** (blank by default, "Blank for a random code (the
  safest)"; for a Member code the admin may type their own, at least 10
  letters and digits, or press the dice button, "Suggest a code (easier to
  guess)", for the season, an animal and a number, `AUTUMN-OTTER-4821`.
  Choosing **Admin** clears and disables the field, "Admin codes are
  always random", and the dice), **Grants**
  (Member by default; Admin is offered to roots only, and other admins
  are told "Only roots create Admin codes."), **Valid from** and **Valid
  through** (date pickers, the current season's first and last days by
  default; the first may be up to a year back, the last from today, or
  the first day when that's later, up to 365 days ahead; picking a first
  day after the last moves the last to it), **Uses** (1 by
  default; digits only, 1 to 1000), **Discount** (100 % by default; 1 to
  100) and **Create code**, disabled while a field is invalid. The new
  code goes to the top of the list and a message names it, and the code
  field is blank again (the dates stay). A taken code says "That code is
  taken; pick another.";
- the season is the northern hemisphere's meteorological one: winter is
  December to February, spring March to May, summer June to August,
  autumn September to November ([lib/auth/voucher_code.dart](../presence_app/lib/auth/voucher_code.dart)),
  so autumn runs from 1 September through 30 November;
- every voucher, newest first, as cards: the code (selectable, monospace;
  struck through with "Expired", "Used up" or "Not yet valid" when it
  can't be redeemed), its role, its discount ("25% off"), "N of M used",
  "valid from" its start and "expires" its end, who redeemed it, and **Copy code**
  and **Delete** buttons. "No vouchers." when there are none. To an admin
  who isn't a root, an Admin voucher shows "Hidden code" with no buttons:
  the API sends it without its code (`"code": null, "hidden": true`) and
  refuses to delete it (403), so an admin can't pass the Admin role on.

**Reload** (a refresh icon beside the "Membership requests" heading) and
pull to refresh fetch both lists again; each section
shows its own loading error.

The admin routes check both roles themselves, as the app does, so hiding
the tab is not the only guard. `MembershipClient` ([lib/auth/membership_client.dart](../presence_app/lib/auth/membership_client.dart))
is the app's client (a fake in tests).

## Known limitations

- Administrators aren't told about new requests; they have to open the
  Admin tab.
- A request's **Grant access** gives `presence_user` only.
  `presence_admin` comes from the root allowlist, a root's Admin voucher,
  or editing `UserRolesTable` by hand, for the account's own email: never
  from the owner of a profile the account is linked to.
- Changing the root allowlist takes a deploy (it's a stack parameter).
- Deleting a voucher, or its expiry, doesn't take back the roles it
  granted.
- Suggested codes are far easier to guess than random ones: with the
  season known, about 620,000 (63 animals, numbers 100 to 9999), against
  2^60. The per-email lockout (10 an hour) makes one account need years,
  but many Google accounts share only the route's throttle (1 a second),
  about a week for all of them; so the app suggests one only when asked,
  and only for Member codes. Keep few uses and short expiries on them.
  Codes an admin types can be weaker still, though at least 10 letters
  and digits.
- The suggested season, and the default validity, are the northern
  hemisphere's.
- The app picks whole days in the admin's time zone; the API takes any
  instants. A code redeemed before its start gets the same 404 as an
  invalid one, so users aren't told it will work later.
- Vouchers under 100% can't be used yet: paying the rest isn't built.
  The 402 tells a valid partial code from an invalid one, but only for
  codes that work.
- Vouchers are listed with a table scan: fine for the few an
  administrator creates, not for thousands.
- There is no way to revoke access from the app; remove the role in the
  table.
- A user granted by an administrator sees it only after **Check again**
  or a new sign-in (a voucher re-checks at once).
- Anyone with a Google account can send a request (once an hour per
  email). The route's throttle (1 a second, burst 5) is shared, so a flood
  can delay real requests (see [Throttling and
  floods](auth-api.md#throttling-and-floods)).
