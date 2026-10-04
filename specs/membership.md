# Membership

Who may use Presence, how people ask, and the voucher codes that let them
in without asking. Roles come from the
[auth API](auth-api.md):

| Who | Roles | Sees |
|---|---|---|
| Unknown user | none | the camera, the account button and **Sign up**: nothing else |
| Member | `presence_user` | every feature: tabs, camera buttons, cloud sync |
| Admin | `presence_user`, `presence_admin` | every feature, plus the **Admin** icon; creates Member vouchers |
| Root | `presence_user`, `presence_admin`, `presence_root` | as Admin, and also creates Admin vouchers |

Roots are the auth API's **root allowlist**: verified emails at one of
`PRESENCE_ROOT_DOMAINS` (`nu01.com`) or listed in `PRESENCE_ROOT_EMAILS`
(none by default). They get all three roles, and nothing else gives
`presence_root`. Everyone else starts unknown, and gets roles from an
administrator's grant or a voucher code. So admins are made only by roots
(or by hand in `UserRolesTable`), and admins can only add members.

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
  `GET /api/auth`, so the user gets in at once. An invalid, expired or
  used-up code (404) says "That code is invalid, expired or used up.";
  throttling (429) says to try again in a minute;
- **Check again** re-asks `GET /api/auth`, so a granted user gets in
  without signing out.

The API keeps one request per email in `MembershipTable` (email, Google
profile name cleaned to one line of 100 characters, message, time in epoch
milliseconds). No notification is sent: administrators see pending
requests when they open the Admin screen.

The Admin screen's app bar also has a **Log** button, which opens the
app's latest log messages (see [Log](log.md)).

## Voucher codes

A voucher grants a role to whoever redeems it:

- **Code:** `XXXX-XXXX-XXXX`, random (`SecureRandom`) from 32 characters
  without `0`, `O`, `1` or `I`: 60 bits. Typed codes ignore case, spaces
  and dashes.
- **Role:** `presence_user` (Member) or `presence_admin` (Admin). An Admin
  voucher also grants `presence_user`, since the Admin screen needs both.
  Only a `presence_root` may create an Admin voucher (403 for other
  admins), and no voucher grants `presence_root` (400).
- **Expiry:** an instant, in the future and at most 366 days away. The app
  picks a date and makes the code valid through the end of that day (local
  time).
- **Uses:** 1 to 1000. Each email may redeem a voucher once.

`VoucherTable` keeps one item per code: `code`, `role`, `expiresAt` and
`createdAt` (epoch ms), `maxUses`, `uses`, `redeemedBy` (a string set of
emails) and `createdBy`. Redeeming is one conditional update (the code
exists, `expiresAt` is after now, `uses < maxUses`, and the email isn't in
`redeemedBy`), so concurrent redemptions can't overspend a code. The role
is then merged into the user's roles in `UserRolesTable`; if that fails, the
use is given back. Every refused code gets the same 404, so answers don't
tell which codes exist, and the route is throttled (1 a second, burst 5).

## The Admin screen

The **Admin** icon (`Icons.admin_panel_settings`, tooltip "Admin") shows in
the app bar for users with both roles. It opens `AdminScreen`
([lib/auth/admin_screen.dart](../presence_app/lib/auth/admin_screen.dart)),
titled "Admin", one scrolling page with two sections.

**Membership requests:**

- the pending requests, oldest first, as cards: name, email, date and
  message;
- **Grant access** adds `presence_user` to that email's roles in
  `UserRolesTable` (merged with any it has, stored as a string set) and
  removes the request. **Dismiss** hides it: the row stays, marked
  `dismissed`, so the requester still waits out the hour before asking
  again. A message confirms either;
- "No pending requests." when there are none.

**Voucher codes**, after the requests:

- a form: **Grants** (Member by default; Admin is offered to roots only,
  and other admins are told "Only roots create Admin codes."), **Valid
  through** (a date picker, a week from today by default, up to 365 days),
  **Uses** (1 by default; digits only, 1 to 1000, else **Create code** is
  disabled) and **Create code**. The new code goes to the top of the list
  and a message names it;
- every voucher, newest first, as cards: the code (selectable, monospace;
  struck through with "Expired" or "Used up" when it can't be redeemed),
  its role, "N of M used", its expiry, who redeemed it, and **Copy code**
  and **Delete** buttons. "No vouchers." when there are none.

**Reload** (and pull to refresh) fetches both lists again; each section
shows its own loading error.

The admin routes check both roles themselves, as the app does, so hiding
the icon is not the only guard. `MembershipClient` ([lib/auth/membership_client.dart](../presence_app/lib/auth/membership_client.dart))
is the app's client (a fake in tests).

## Known limitations

- Administrators aren't told about new requests; they have to open the
  Admin screen.
- A request's **Grant access** gives `presence_user` only.
  `presence_admin` comes from the root allowlist, a root's Admin voucher,
  or editing `UserRolesTable` by hand.
- Changing the root allowlist takes a deploy (it's a stack parameter).
- Deleting a voucher, or its expiry, doesn't take back the roles it
  granted.
- Vouchers are listed with a table scan: fine for the few an
  administrator creates, not for thousands.
- There is no way to revoke access from the app; remove the role in the
  table.
- A user granted by an administrator sees it only after **Check again**
  or a new sign-in (a voucher re-checks at once).
- Anyone with a Google account can send a request (once an hour per
  email). The route's throttle (1 a second, burst 5) is shared, so a flood
  can delay real requests.
