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

## The API

Four routes of the [auth API](auth-api.md), one function
(`FeedbackHandler`), behind the Google JWT authorizer:

| Route | Who | Does |
|---|---|---|
| `GET /api/auth/feedback` | members | the caller's conversation, oldest first: `{"messages": [{"from": "user" \| "admin", "message", "sentAt"}]}` |
| `POST /api/auth/feedback` | members | adds the plain-text body (trimmed, 1 to 2000 characters; 400 otherwise); answers 201 with the message |
| `GET /api/auth/feedback/threads` | admins | every conversation, the latest active first: `{"threads": [{"email", "name", "messages": [{"from", "by", "message", "sentAt"}]}]}` |
| `POST /api/auth/feedback/reply` | admins | adds the form-encoded `message` (1 to 2000 characters) to `email`'s conversation; 404 if that email has none (admins answer, they don't start conversations); answers 201 with the reply |

- **Members** are callers with `presence_user` and a verified email (a
  linked account counts, and writes under its own email); anyone else
  gets 403. **Admins** need `presence_user` and `presence_admin`, as on
  the Admin routes; a member gets 403 from the admin routes.
- **Limits:** at most **20 messages a day** per member (their own, in the
  last 24 hours; replies don't count): 409 past that. The send route is
  throttled to 1 request/s (burst 5) for everyone, like the other routes
  anyone with a Google account can reach.
- **Privacy:** a member's answer never names the admin who replied
  (`by` is only in the admins' listing). The function doesn't call
  rbacr: premium doesn't matter here.
- **Storage:** `FeedbackTable`, one item per message, keyed by `email`
  (partition) and `sentAt` (sort, epoch ms), with `from` (`user` or
  `admin`), `message`, `name` (the member's Google profile name, cleaned
  to one line of 100 characters, on their messages) and `by` (the
  replying admin's email). Messages are only added, never changed or
  deleted. Two messages in the same millisecond each get their own (the
  later one moves on a millisecond; a conditional put). Like the other
  tables: on-demand, encrypted, point-in-time recovery, kept if the stack
  is deleted; its contents live only in AWS. The function may only get
  items from `UserRolesTable` and both profile tables, and query, scan and
  put in `FeedbackTable`. `GET /health` describes the table too.
- **Locally**, Floci's auth API ([local CDN](local-cdn.md)) has the same
  four routes when an OIDC client is set; in DEV there are none (and no
  Help tab).

## Tests

- `FeedbackTest` (JUnit): sending and reading one's own conversation,
  members only (no role, unverified, no token), empty and long messages,
  the daily limit (replies don't count, the day passes), same-millisecond
  messages, admins only for listing and replying (`presence_admin` alone
  isn't enough), the listing's order and its `by`, the member not seeing
  it, replies needing a conversation, an email and a message, unknown
  routes.
- `feedback_test.dart` (Flutter): the client's requests, bodies, token
  and errors; the tab's place and title; a member sending (Send disabled
  while blank, the field cleared) and reading a reply after Reload; a
  refused message keeping its text; no Help tab in DEV or without a role;
  an admin's list (order, awaiting-reply and answered icons), opening a
  conversation and replying (it moves first, answered).
