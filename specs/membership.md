# Membership

Who may use Presence, and how people ask. Roles come from the
[auth API](auth-api.md):

| Who | Roles | Sees |
|---|---|---|
| Unknown user | none | the camera, the account button and **Sign up**: nothing else |
| Member | `presence_user` | every feature: tabs, camera buttons, cloud sync |
| Admin | `presence_user`, `presence_admin` | every feature, plus the **Admin** icon |

For now only verified emails at `nu01.com` (the `AllowedDomains` of the
auth API) have roles, and they get both. Everyone else starts unknown.

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
- **Check again** re-asks `GET /api/auth`, so a granted user gets in
  without signing out.

The API keeps one request per email in `MembershipTable` (email, Google
profile name cleaned to one line of 100 characters, message, time in epoch
milliseconds) and publishes it to the `MembershipTopic` SNS topic, which
administrators subscribe to by hand (see the
[auth API's README](../presence_api_auth/README.md)). The email marks the
message as the requester's own words. If publishing fails, the request is
still kept (and on the Admin screen).

## The Admin screen

The **Admin** icon (`Icons.admin_panel_settings`, tooltip "Admin") shows in
the app bar for users with both roles. It opens `AdminScreen`
([lib/auth/admin_screen.dart](../presence_app/lib/auth/admin_screen.dart)),
"Membership requests":

- the pending requests, oldest first, as cards: name, email, date and
  message;
- **Grant access** adds `presence_user` to that email's roles in
  `UserRolesTable` (merged with any it has, stored as a string set) and
  removes the request. **Dismiss** hides it: the row stays, marked
  `dismissed`, so the requester still waits out the hour before asking
  again. A message confirms either;
- **Reload** (and pull to refresh) fetches the list again. "No pending
  requests." when there are none.

The admin routes check both roles themselves, as the app does, so hiding
the icon is not the only guard. `MembershipClient` ([lib/auth/membership_client.dart](../presence_app/lib/auth/membership_client.dart))
is the app's client (a fake in tests).

## Known limitations

- Admins can grant `presence_user` only. `presence_admin` is given by
  domain, or by editing `UserRolesTable` by hand.
- There is no way to revoke access from the app; remove the role in the
  table.
- A granted user sees it only after **Check again** or a new sign-in.
- Anyone with a Google account can send a request (once an hour per
  email). The route's throttle (1 a second, burst 5) is shared, so a flood
  can delay real requests.
