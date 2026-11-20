# Help Desk — Security Improvements (Forward-Looking)

## 1. Re-check the group's public settings when a link is used

`resolveLink` (`functions/_help_desk.js`) opens a public ticket from its token alone. It does not check that the group still has `publicIntake` on or that the group isn't frozen, so a signed-out requester can keep reading and replying for up to 180 days after a group closes its form or is frozen. `publicSettings` already enforces both for the form. Apply the same check (or a narrower "group not frozen" check, if replies on existing tickets should keep working after intake is turned off) in `resolveLink`, and decide the intended behaviour explicitly in the design doc.

## 2. Bound and revoke public ticket links

Every email to a public requester mints a new multi-use 180-day token (`mintLink`), and none are ever revoked. A forwarded or leaked email keeps working for months, and closing a ticket doesn't end access. Options: revoke a ticket's earlier tokens when a new one is minted (or keep one live token per ticket and extend it), set `revokedAtMs` on all of a ticket's tokens when it closes, and give the desk a "revoke links" action for a requester who reports a compromised mailbox.

## 3. Attribute system messages to the real actor

`addMessage` stamps `lastModifiedBy` from `authorUid`, and system messages have none, so status-change messages written by an agent, escalation notes and the auto-close message are all stamped `system:help-desk-public` on the audit trail. Pass the acting uid (or `SYSTEM_ACTORS.schedule`) to `stamp` separately from the visible `authorUid`, so the audit trail records who caused each system message.

## 4. Return less to the requester side

`ticketSummary` is sent whole to requesters and public pages, including `assigneeUid`, `assigneeName`, `deskKey`, `deskLabel` and `groupId`. A public requester learns the internal uid of the assigned agent. Build a requester view that omits `assigneeUid` (and the assignee name, unless the product wants it shown) and other desk-only fields.

## 5. Enforce the priority choices on the server

The member form offers only Normal and High, but `helpDeskCreateTicket` accepts `urgent` from any requester. Either restrict `urgent` to `target: 'upstream'` on the server, or offer it in the UI; the server should be the place that decides.

## 6. Rate-limit signed-in writes beyond ticket creation

Only ticket creation is limited for signed-in users. `helpDeskReply`, `helpDeskSetStatus` and `helpDeskAssign` each fan out notifications (and replies on public tickets send email), so a compromised or scripted account can flood a desk's agents or a public requester's inbox. Add per-uid limits on reply and status changes, sized well above normal conversation pace.

## 7. Limit IP-only read probing on the public form

`helpDeskPublicSubmit` reads the group and settings before applying the IP limit, and `helpDeskPublicDesk` shares the 30/minute read bucket with ticket reads. A scraper can enumerate which groups have public forms at 30 lookups a minute per IP. Apply the submit IP limit before any reads, and consider a lower separate bucket for desk lookups.

## 8. Cap the escalation body against its stored size

Escalation bodies may be up to 15,000 characters (`LIMITS.body * 3`), and with `shareThread` the quote is built from up to 500 messages before the cut. Validate the summary and forwarded thread sizes separately and tell the agent when the thread was shortened, so nothing that looks shared is silently dropped and no single message doc approaches Firestore's size limits.
