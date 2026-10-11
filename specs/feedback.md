# Feedback and Help

Members write to the administrators from the app, and read their replies
there. Each member has **one conversation**, kept by their email; admins
see every conversation on the [Admin tab](membership.md#the-admin-tab) and
answer it. There are no notifications: a member sees a reply when they
open or reload the Help tab, and an admin sees new messages when they open
or reload the Admin tab.

## The Help tab

The **Help** tab (`HomeTab.help`, `Icons.help_outline` / `Icons.help`,
tooltip and label "Help") sits after Settings in the bottom navigation bar,
before the Log and Admin tabs (see [Navigation](navigation.md)). The
navigation bar's label is the short "Help", so six tabs still fit a
320 dp phone; the app bar names the screen **"Feedback & Help"**
(`HomeTab.title`).

- **Who sees it:** signed-in users with access (`presence_user`, or an
  account linked to a member's profile). Never in DEV, where there are no
  accounts to write from, and never signed out or without a role (there's
  no navigation bar then).
- **The page** (`HelpView`,
  [lib/feedback/help_view.dart](../presence_app/lib/feedback/help_view.dart)):
  a tab page like Settings, no scaffold of its own, up to 720 dp wide.
  A heading, "Write to the Presence team", with **Reload** beside it
  (pulling down reloads too), and a line saying an administrator will
  answer here. Then the conversation, oldest first, as chat bubbles
  (`FeedbackConversation`): the member's own messages on the right (the
  accent container color), replies on the left, each with "You" or
  "Presence team" and its date and time (`2026-10-10 14:05`, local). The
  member isn't told which admin replied. "No messages yet." when it's
  empty.
- **Writing** (`FeedbackComposer`): a **Message** field (2 to 6 lines,
  up to 2000 characters, with a counter) and **Send**, disabled while the
  field is blank or a message is on its way. A sent message joins the
  conversation and the field clears. A refused one keeps its text and
  says why in a snackbar: past the day's limit (409) "You've sent a lot
  today. Try again tomorrow.", throttled (429) "Too many tries. Wait a
  minute.", otherwise the error.

## On the Admin tab

The Admin tab's **Feedback** section, between maintenance mode and
the voucher codes (see [Membership](membership.md#the-admin-tab)), lists
every conversation, **the latest active first** (by its newest message),
as cards (`FeedbackThreadCard`,
[lib/feedback/feedback_inbox.dart](../presence_app/lib/feedback/feedback_inbox.dart)):

- the member's name (or email), their email and the newest message's
  time, with an icon saying whether it's **awaiting a reply** (the member
  wrote last: a filled chat icon in the accent color) or **answered**;
- tapped, the card opens on the whole conversation, from the admin's side:
  the member's messages on the left ("Member"), replies on the right, each
  naming the admin who wrote it (their email);
- a **Reply** field and button, as on the Help tab. A sent reply joins the
  conversation, the card moves to the top (staying open) and shows as
  answered. A failure says "Couldn't reply to <email> (<error>)" and keeps
  the text.
- "No feedback yet." when there's none. The section loads with the rest
  of the tab, and Reload reloads it too.

## Storage and access: no API

Since 2026-10-10 the app reads and writes the conversations itself,
straight to DynamoDB with the profile's AWS credentials (the same
Cognito credentials cloud sync uses, from `POST /api/auth/credentials`);
there are no feedback routes in the [auth API](auth-api.md).
`DynamoFeedbackClient`
([lib/feedback/feedback_client.dart](../presence_app/lib/feedback/feedback_client.dart))
calls DynamoDB's JSON API, signed with SigV4
([lib/cloud/dynamodb.dart](../presence_app/lib/cloud/dynamodb.dart)).

- **The table:** `FeedbackTable` in the `presence-user-data` stack
  ([presence_infra/user-data.yaml](../presence_infra/user-data.yaml)),
  one item per message: `conversation` (partition: the profile's
  Cognito identity ID, so **one conversation per profile**, shared by its
  linked accounts), `sentAt` (sort, epoch ms), `message`, and on a
  member's message their `email` and `name` (as their app gives them),
  on a reply `fromAdmin` (true) and `by` (the admin's email). On-demand,
  encrypted, point-in-time recovery, kept if the stack is deleted. The
  app gets its name at build time (`FEEDBACK_TABLE`, from the stack's
  output, through `scripts/deploy.sh` or `.env`); empty, feedback is off
  (it answers "unavailable").
- **Who may do what** is IAM's, on the identity pool's authenticated role
  ([presence_infra/identity.yaml](../presence_infra/identity.yaml),
  `own-feedback`):
  - **members** (credentials the auth API issued, which carry the `tier`
    tag: members only, never a Google sign-in straight to the pool)
    `Query` and `PutItem` only items whose partition is their own
    identity (`dynamodb:LeadingKeys`). Reading must name its attributes
    (`Select: SPECIFIC_ATTRIBUTES`), and `by` isn't among them, so a
    member never learns which admin replied; writing may only set
    `conversation`, `sentAt`, `message`, `email` and `name`, so a member
    can't write as an administrator;
  - **admins**: the credentials route tags their credentials `admin`
    `true` (from their own email's rbacr roles; a linked account never
    gets it from its owner). With it they `Scan` every conversation,
    `Query` any, and `PutItem` replies into any.
- **Sending:** the message, trimmed, 1 to 2000 characters (400
  otherwise); a conditional put (`attribute_not_exists(sentAt)`) moves a
  message on a millisecond when another has the same time.
- **Limits:** at most **20 messages a day** per member, counted by the
  app before it sends (409 past that).
- **Admin listing:** a `Scan` of the whole table (every page), grouped by
  conversation, the latest active first; each named by the member's
  latest own message (email, name).
- **Errors:** AWS's AccessDenied is 403, throttling 429, no table or no
  credentials 503.
- **Locally**, Floci has no Cognito Identity, so local builds reach the
  real table only with real credentials; in DEV there's no Help tab.

### Known limitations

- The daily limit and the message length are the app's: IAM can't count
  or measure, so a modified client could send more.
- The email and name on a member's messages are what their app says, not
  checked by a server; the conversation itself is the profile's (IAM).
- A member can overwrite their own conversation's items (a put on an
  existing time), including turning an admin's reply into their own
  message (without `fromAdmin`), but only in their own conversation.
- The admin listing scans the whole table: fine for hundreds of
  conversations, slow for many thousands.
- Conversations from before 2026-10-10 (the auth API's table, keyed by
  email) weren't moved; that table is kept in AWS, unused.

## Tests

- `ProfileTest`, `ProfileBackendTest` (JUnit): only an administrator's
  own credentials are tagged `admin`.
- `feedback_test.dart` (Flutter): the DynamoDB client's requests (a
  member's query of their own conversation, never `by`; a send as the
  member; blank, long and over-the-limit messages refused; the admin's
  paged scan, its order and naming; a reply as the admin) and errors
  (AccessDenied, no table); the tab's place and title; a member sending (Send disabled
  while blank, the field cleared) and reading a reply after Reload; a
  refused message keeping its text; no Help tab in DEV or without a role;
  an admin's list (order, awaiting-reply and answered icons), opening a
  conversation and replying (it moves first, answered).
