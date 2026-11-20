# Help Desk — Interfaces

Every Help Desk read and write goes through callables in `functions/help_desk.js` (handlers in `functions/_help_desk.js`, model in `functions/_help_desk_model.js`). The client (`HelpDeskApi`, `packages/help_desk/lib/help_desk_api.dart`) never touches Firestore directly.

## Common behaviour

- Signed-in callables throw `unauthenticated` ("You must be signed in.") without a uid.
- Id arguments (`groupId`, `ticketId`, `assigneeUid`, `itemId`) must be non-empty, contain no `/`, and be at most 200 characters, else `invalid-argument` ("`<field>` is required.").
- Text arguments are trimmed and must be 1 to the field's limit, else `invalid-argument` ("`<field>` must be 1 to `<limit>` characters.").
- Ticket callables refuse with `permission-denied` ("You cannot open this ticket.") both when the ticket doesn't exist and when the caller is on neither side.
- `as` (optional on reply and set status): `"requester"` or `"desk"`, to choose a side when the caller is on both. Asking for a side the caller isn't on is `permission-denied` ("You cannot act on this ticket that way."). Default: desk when available.
- Rate limits throw `resource-exhausted`.
- Timestamps in responses are epoch milliseconds (`…AtMs`); in Firestore they are `Timestamp`s.
- Public (signed-out) callables answer `not-found` ("This help page is not available.") for every failure to find or open something.

## Shared shapes

### `TicketSummary` (list rows, and `ticket` in ticket responses)

```json
{
  "id": "abc123",
  "subject": "Can't export my report",
  "status": "open | pending | escalated | resolved | closed",
  "priority": "normal | high | urgent",
  "category": "Problem",
  "requesterKind": "person | group | public",
  "requesterName": "Sam Lee",
  "groupId": "acme",
  "groupName": "Acme",
  "deskKey": "group:acme | platform",
  "deskLabel": "Acme | Bluejay support",
  "assigneeUid": "uid_or_null",
  "assigneeName": "",
  "waitingOn": "desk | requester",
  "messageCount": 3,
  "createdAtMs": 1763220000000,
  "lastActivityAtMs": 1763223600000,
  "overdue": false,
  "escalated": false,
  "fromEscalation": false
}
```

- `overdue`: status `open`, no `firstResponseAt`, and older than the desk's `firstResponseHours` (list views use the desk's setting for `inbox` and `platform`, 24 hours otherwise).
- `escalated`: the ticket has an `upstreamTicketId`. `fromEscalation`: it has a `parentTicketId`.
- `groupName` is the ticket's stored `groupName`; `helpDeskList` falls back to the group doc's `name`, then the id, when it is empty. A `public` ticket stores the group's outward name (its legal name when set; see `help_tickets` below).

### `MessageView`

```json
{
  "id": "msg1",
  "side": "requester | desk | system",
  "internal": false,
  "authorName": "Sam Lee",
  "authorUid": "uid_or_null",
  "body": "…",
  "createdAtMs": 1763220000000
}
```

Messages are oldest first. The requester side and public pages never receive `internal: true` messages.

## Signed-in callables

### `helpDeskOverview`

What the caller can do in a group. Used by the Help Desk screen and by `contactHelpDesk` in other apps' help tab.

Request:

```json
{ "groupId": "acme" }
```

Response:

```json
{
  "groupId": "acme",
  "groupName": "Acme",
  "canFile": true,
  "deskLabel": "Acme",
  "routedToPlatform": false,
  "isAgent": true,
  "canContactUpstream": true,
  "upstreamLabel": "Bluejay support",
  "isStaff": false,
  "isPlatformAdmin": false,
  "isGuest": false,
  "categories": ["Question", "Problem", "Account", "Order", "Other"],
  "welcome": "We reply within one business day.",
  "publicFormUrl": "https://bluejay.gg/help/acme"
}
```

- Refused ("You do not have access to this workspace.") when the group doesn't exist or the caller isn't in it; refused ("You do not have access to Help Desk here.") when the caller can't file, isn't an agent and isn't staff.
- `deskLabel` is where the caller's own tickets go (the group's name, or "Bluejay support" when routed to the platform).
- `upstreamLabel` is set only for agents. `publicFormUrl` is null unless `publicIntake` is on.

### `helpDeskList`

Request:

```json
{ "view": "mine | inbox | upstream | platform", "groupId": "acme", "active": true }
```

| View | Who | Query |
|---|---|---|
| `mine` | `inGroup` | `groupId == g`, `requesterUid == uid`; rows with `requesterKind != 'person'` are dropped after the query |
| `inbox` | agents of `g` | `deskKey == 'group:g'` |
| `upstream` | agents of `g` | `groupId == g`, `requesterKind == 'group'` |
| `platform` | staff (no `groupId` needed) | `deskKey == 'platform'` |

`active` defaults to true and adds `active == true`; `false` returns every status. Each query orders by `lastActivityAt desc` with limit 100.

Response:

```json
{ "tickets": [ /* TicketSummary */ ] }
```

Errors: `invalid-argument` for an unknown view; `permission-denied` with "The Bluejay desk is for Bluejay support staff.", "You do not have access to this workspace." or "Only the group's admins see this."

### `helpDeskSearch`

Record search over tickets: the tickets in one group matching a query, out of those the caller already sees in `helpDeskList`. Called by `HelpDeskRecordSearch` (the launcher's record search); see [Interfaces offered to other packages](#interfaces-offered-to-other-packages).

Request:

```json
{ "groupId": "acme", "q": "refund gus", "limit": 8 }
```

- `q` is cut to 100 characters and split into terms by `searchTerms` (`functions/_search_prefixes.js`). No usable term (for example a single letter) returns `{ "tickets": [] }`.
- `limit` is clamped to 1–8 (default 8).

| View searched | Who | Query |
|---|---|---|
| Own tickets | `inGroup` | `groupId == g`, `requesterUid == uid`; rows with `requesterKind != 'person'` are dropped |
| Desk inbox | agents of `g` | `deskKey == 'group:g'` |
| Upstream | agents of `g` | `groupId == g`, `requesterKind == 'group'` |

Each view adds `searchPrefixes array-contains <primaryTerm(terms)>` (the most selective term) and `limit`, with no ordering and no `active` filter, so resolved and closed tickets are found too. The other terms are matched in memory with `matchesAll`. Rows are de-duplicated by id, sorted by `lastActivityAtMs` descending and cut to `limit`. The query text is never logged.

Response:

```json
{ "tickets": [ /* TicketSummary */ ] }
```

Rows are built from the stored ticket only: `groupName` and `deskLabel` have no fallback, and `overdue` uses the 24-hour default rather than the desk's `firstResponseHours`.

Errors: `permission-denied` ("You do not have access to this workspace.") when the caller isn't in the group.

### `helpDeskGetTicket`

Request:

```json
{ "ticketId": "abc123" }
```

Response:

```json
{
  "ticket": {
    "...TicketSummary": "…",
    "context": { "appId": "notes", "appName": "Notes", "orderRef": "A1B2C3D4", "platform": "web", "appVersion": "1.2.3" },
    "requesterEmail": "",
    "parentTicketId": null,
    "upstreamTicketId": null,
    "linkedChanges": [ { "itemType": "bug", "itemId": "bug_1", "linkedBy": "uid", "linkedAtMs": 1763220000000 } ]
  },
  "messages": [ /* MessageView */ ],
  "sides": { "requester": false, "desk": true },
  "desk": {
    "agents": [ { "uid": "uid1", "name": "Jamie" } ],
    "savedReplies": [ { "title": "Reset link", "body": "…" } ],
    "canEscalate": true,
    "upstreamLabel": "Bluejay support",
    "isStaffDesk": false
  }
}
```

- `requesterEmail` is filled only for the desk side of a `public` ticket. `parentTicketId`, `upstreamTicketId` and `linkedChanges` are null/empty for a requester-only caller.
- `desk` is present only for the desk side. `canEscalate`: a group desk, no `upstreamTicketId`, status active. `isStaffDesk`: the platform desk and the caller is staff.
- Internal messages are included only for the desk side.

### `helpDeskCreateTicket`

Request:

```json
{
  "groupId": "acme",
  "target": "desk | upstream",
  "subject": "Can't export my report",
  "body": "When I press Export…",
  "category": "Problem",
  "priority": "normal | high | urgent",
  "context": { "appId": "notes", "appName": "Notes", "orderRef": "…", "platform": "…", "appVersion": "…" }
}
```

- `target` defaults to `desk`: requires `canFileIn`; desk from `resolveDesk`; `requesterKind: 'person'`.
- `target: 'upstream'`: requires `isGroupAgent`; desk from `upstreamDesk`; `requesterKind: 'group'`; `requesterName` is `"<group> (<person>)"`; category always empty.
- `category` is kept only when it is one of the group's categories (desk target). Unknown `priority` becomes `normal`. `context` keeps only the five listed keys (`sanitizeContext`).
- Rate limit: `uid_<uid>`, 20/hour and 60/day ("You have opened a lot of tickets recently. Please try again later.").

Response:

```json
{ "ticketId": "abc123", "deskLabel": "Acme" }
```

The client (`HelpDeskApi.create`) sends `target`, `priority` and `context` always, and `category` only when chosen.

### `helpDeskReply`

Request:

```json
{ "ticketId": "abc123", "body": "…", "as": "desk", "internal": false, "resolve": false }
```

- `internal` and `resolve` only apply on the desk side; `resolve` is ignored for internal notes.
- New status from `statusAfterMessage` (see the developer guide). The first non-internal desk reply sets `firstResponseAt`.

Response:

```json
{ "status": "pending" }
```

### `helpDeskSetStatus`

Request:

```json
{ "ticketId": "abc123", "status": "open | pending | resolved | closed", "as": "requester" }
```

Allowed moves (`canSetStatus`): never to `escalated` or to the current status; the desk may set any other; the requester may set `resolved`, or `open` from `pending`, `resolved` or `closed`. Otherwise `invalid-argument` ("You cannot move this ticket to "<status>".").

Response:

```json
{ "status": "resolved" }
```

### `helpDeskAssign`

Request:

```json
{ "ticketId": "abc123", "assigneeUid": "uid1" }
```

`assigneeUid: null` (or absent) unassigns. Desk side only ("Only the desk assigns tickets."). The assignee must be one of the desk's agents, else `invalid-argument` ("They do not answer this desk.").

Response:

```json
{ "assigneeUid": "uid1", "assigneeName": "Jamie" }
```

### `helpDeskEscalate`

Request:

```json
{ "ticketId": "abc123", "summary": "Exports fail for all users since Monday…", "shareThread": false }
```

- Desk side of a group desk only (`permission-denied`: "Only a group's desk can escalate.").
- `failed-precondition`: "This ticket is already escalated." or "Reopen the ticket to escalate it." (not active).

Response:

```json
{ "upstreamTicketId": "def456", "upstreamLabel": "Bluejay support" }
```

### `helpDeskLinkChange`

Records a bug report or idea the desk filed from the ticket (the item itself is created by Improve Apps' own forms).

Request:

```json
{ "ticketId": "abc123", "itemType": "bug | feature", "itemId": "bug_1" }
```

Desk side only. Linking the same item twice returns the list unchanged; more than 10 links is `invalid-argument`.

Response:

```json
{ "linkedChanges": [ { "itemType": "bug", "itemId": "bug_1", "linkedBy": "uid", "linkedAtMs": 1763220000000 } ] }
```

### `helpDeskGetSettings`

Request: `{ "groupId": "acme" }` (group agents or platform admins) or `{ "desk": "platform" }` (staff).

Response:

```json
{
  "routing": "self | platform",
  "guestIntake": false,
  "publicIntake": false,
  "categories": ["Question", "Problem", "Account", "Order", "Other"],
  "savedReplies": [ { "title": "…", "body": "…" } ],
  "firstResponseHours": 24,
  "welcome": "",
  "platformDesk": false,
  "canChangeRouting": false,
  "publicFormUrl": "https://bluejay.gg/help/acme"
}
```

`canChangeRouting` is true only for platform admins on a group desk. `publicFormUrl` is the form's address for any group desk (whether or not intake is on), null for the platform desk.

### `helpDeskSaveSettings`

Request:

```json
{ "groupId": "acme", "settings": { "guestIntake": true } }
```

or `{ "desk": "platform", "settings": { … } }`. Only the keys present are changed (`validateSettingsPatch`):

| Key | Rule |
|---|---|
| `routing` | `"self"` or `"platform"`; platform admins only ("Only platform admins can change where tickets go."); not on the platform desk |
| `guestIntake`, `publicIntake` | booleans; not on the platform desk |
| `categories` | list of up to 12, deduplicated, blanks dropped, each up to 40 |
| `savedReplies` | list of up to 30 `{title ≤ 60, body ≤ 2000}`, both required |
| `firstResponseHours` | integer 1–168 |
| `welcome` | up to 500 |

Any violation is `invalid-argument` with the rule's message. Response: the normalised settings (the first seven fields of `helpDeskGetSettings`, without `platformDesk`, `canChangeRouting` or `publicFormUrl`).

## Signed-out callables (`bluejay.gg/help/...`)

These accept an unauthenticated call. Rate limits are keyed by a hash of the client IP.

### `helpDeskPublicDesk`

Request: `{ "groupId": "acme" }`. Limit: 30/minute per IP.

Response:

```json
{ "groupId": "acme", "groupName": "Acme", "categories": ["…"], "welcome": "…" }
```

`groupName` is the group's outward name, `groupDocumentName` (`functions/_group_identity.js`): its `legalName` when set, else `name`, else the id. See [platform changes, PR #3319](../platform_changes/developer.md).

`not-found` unless the group exists, `publicIntake` is on and the group isn't frozen.

### `helpDeskPublicSubmit`

Request:

```json
{
  "groupId": "acme",
  "name": "Sam Lee",
  "email": "sam@example.com",
  "subject": "Order didn't arrive",
  "body": "…",
  "category": "Order",
  "orderRef": "A1B2C3D4"
}
```

- `name` 1–80; `email` lower-cased, must match `^[^\s@]+@[^\s@]+\.[^\s@]+$` and be at most 254 ("Enter a valid email address.").
- Limits: 5/hour and 20/day per IP; 5/day per email ("Too many requests from this email address today. Please try again tomorrow.").
- Creates a `public` ticket at `resolveDesk`, mints a link, and emails a confirmation.

Response:

```json
{ "ticketId": "abc123", "url": "https://bluejay.gg/help/acme/t/<token>" }
```

### `helpDeskPublicTicket`

Request: `{ "token": "<43-char token>" }`. Limit: 30/minute per IP.

Response:

```json
{
  "ticket": { "...TicketSummary": "…", "context": { "orderRef": "A1B2C3D4" } },
  "messages": [ /* MessageView, no internal notes */ ]
}
```

### `helpDeskPublicReply`

Request:

```json
{ "token": "<token>", "body": "Thanks, that worked", "resolve": false }
```

- `body` is required (1–5,000) unless `resolve` is true, when it is optional.
- Sets `open`, or `resolved` with `resolve` (adding a system message). Limit: 20/hour per IP.

Response: the same shape as `helpDeskPublicTicket`, after the change.

## Scheduled: `helpDeskAutoClose`

Daily at 03:17 platform time. Closes up to 400 tickets with `status == 'resolved'` and `resolvedAt` more than 7 days ago. Returns `{closed}` internally and logs `[helpDeskAutoClose] closed <n>`.

## Persistence

### `help_tickets/{ticketId}`

```json
{
  "appId": "help-desk",
  "deskKey": "group:acme | platform",
  "deskGroupId": "acme | null",
  "deskLabel": "Acme",
  "groupId": "acme",
  "groupName": "Acme",
  "requesterKind": "person | group | public",
  "requesterUid": "uid | null",
  "requesterName": "Sam Lee | Acme (Jamie)",
  "requesterEmail": "sam@example.com | null",
  "subject": "…",
  "category": "Problem | ''",
  "priority": "normal | high | urgent",
  "status": "open | pending | escalated | resolved | closed",
  "active": true,
  "waitingOn": "desk | requester",
  "resolvedAt": "Timestamp | null",
  "closedAt": "Timestamp | null",
  "assigneeUid": "uid | null",
  "assigneeName": "",
  "context": { "appId": "…", "appName": "…", "orderRef": "…", "platform": "…", "appVersion": "…" },
  "parentTicketId": "id | null",
  "upstreamTicketId": "id | null",
  "linkedChanges": [ { "itemType": "bug | feature", "itemId": "…", "linkedBy": "uid", "linkedAtMs": 0 } ],
  "firstResponseAt": "Timestamp | null",
  "createdAt": "Timestamp",
  "updatedAt": "Timestamp",
  "lastActivityAt": "Timestamp",
  "messageCount": 1,
  "lastModifiedBy": "uid | system:help-desk-public | system:help-desk-auto-close",
  "lastModifiedAt": "Timestamp",
  "searchPrefixes": ["re", "ref", "…", "sa", "sam", "…"]
}
```

`requesterUid` on a `group` ticket is the agent who opened it. `groupName` and `deskLabel` are copied at creation and not refreshed. `helpDeskPublicSubmit` stores the group's outward name (`groupDocumentName`: the legal name when set) as `groupName`, so the public ticket page, its emails and the desk's own view of that ticket all show it; every other ticket stores the group's `name`.

`searchPrefixes` is written by the audit-trail trigger (`functions/audit_trail.js`, `syncSearchPrefixes`) from the `search` block for `help_tickets` in `security/collections.json` (`subject`, `requesterName`), never by the Help Desk handlers, and is not recorded in the audit trail. `helpDeskSearch` queries it. A `person` ticket that `fileOnBluejayDesk` files without a group has `groupId: ''` and `groupName: ''`.

### `help_tickets/{ticketId}/help_messages/{messageId}`

```json
{
  "side": "requester | desk | system",
  "internal": false,
  "authorUid": "uid | null",
  "authorName": "…",
  "body": "…",
  "createdAt": "Timestamp",
  "lastModifiedBy": "uid | system:help-desk-public",
  "lastModifiedAt": "Timestamp"
}
```

System messages have no author (`lastModifiedBy` then falls back to `system:help-desk-public`).

### `help_desk_settings/{groupId | _platform}`

```json
{
  "routing": "self | platform",
  "guestIntake": false,
  "publicIntake": false,
  "categories": ["…"],
  "savedReplies": [ { "title": "…", "body": "…" } ],
  "firstResponseHours": 24,
  "welcome": "…",
  "groupId": "acme",
  "updatedAt": "Timestamp",
  "lastModifiedBy": "uid",
  "lastModifiedAt": "Timestamp"
}
```

Merged on save; missing fields read as defaults. `groupId` is omitted on `_platform`.

### `help_desk_links/{sha256(token)}`

```json
{
  "ticketId": "abc123",
  "groupId": "acme",
  "kind": "link",
  "singleUse": false,
  "createdAtMs": 1763220000000,
  "expiresAtMs": 1778772000000,
  "usedAtMs": null,
  "usedBy": null,
  "useCount": 0,
  "revokedAtMs": null
}
```

One per email sent to a public requester; 180-day expiry; never marked used.

### `help_desk_rate_limits/{key}`

```json
{ "recentAttemptTimes": [1763220000000], "updatedAt": "serverTimestamp" }
```

Keys: `uid_<uid>`, and `hashKey(<scope>, value)` for `read_ip`, `submit_ip`, `reply_ip`, `submit_email`.

### Reads of other features' data

| Collection | Why |
|---|---|
| `groups/{id}` | Name, `adminIds` (agents), `managedBy` / `devQueue.managedBy` (upstream desk), `isFrozen` (public form) |
| `users/{uid}` | Display names: `displayName`, then `name`, then the email's local part, then "Someone" |
| Access index (`getAccessIndex`) | `status`, `groups`, `guest_groups`, `denied_scopes`, `entitlements`, `roles` |
| Platform role holders (`listPlatformRoleHolders`) | Active `support`, else `admin` holders |

## Emitted notifications

Through `createNotifications(db, uids, payload, {idFor})`:

```json
{
  "groupId": "acme",
  "appId": "help-desk",
  "appName": "Help Desk",
  "type": "help_desk",
  "title": "New ticket: Can't export my report",
  "body": "Sam Lee asked for help.",
  "context": { "helpDeskTicketId": "abc123" }
}
```

Ids: `help_<ticketId>_<key>_<uid>`. Bodies over 240 characters are cut to 237 plus `...`. Titles: `New ticket: …`, `New reply: …`, `Resolved: …`, `Reply on: …`, `Solved: …`, `Reopened: …`, `Assigned to you: …`, `Update: …`. See the developer guide for recipients and keys.

## Action items (To do)

Group desks only, through `openActionItem` / `resolveActionItem`:

```json
{
  "key": "help_desk_ticket__abc123",
  "groupId": "acme",
  "appId": "help-desk",
  "appName": "Help Desk",
  "kind": "help_desk_ticket",
  "title": "Help Desk: Can't export my report",
  "body": "Sam Lee is waiting for an answer.",
  "audience": { "type": "app_admins", "appId": "help-desk" },
  "excludeUids": ["requesterUid"],
  "context": { "helpDeskTicketId": "abc123" }
}
```

Resolved with `{resolvedBy, outcome}` where `outcome` is `answered`, `resolved`, `escalated`, `pending` or `closed`.

## Emails

Through `sendEmail(db, {to, subject, text}, {triggeredBy: 'helpDesk', groupId, appId: 'help-desk', metadata: {ticketId}})`:

| When | Subject |
|---|---|
| Public submit | `We got your request: <subject>` |
| Desk reply on a public ticket | `Re: <subject>` (quotes the reply) |
| Escalation of a public ticket | `Update: <subject>` |

Each body ends with a fresh ticket link and the ticket's stored `groupName`, which for a public ticket is the group's legal name when set.

## Launch arguments and links

| Entry | Effect |
|---|---|
| Launch arg `ticket` (`ticketArg`; `AppRouter`, from notifications, To dos, record search and shared places) | `HelpDeskScreen(initialTicketId:)` opens that ticket over the lists |
| `/help/<groupId>` | `PublicHelpFormScreen` |
| `/help/<groupId>?order=<ref>` | The form with the order number filled in (and the `Order` topic when offered) |
| `/help/<groupId>/t/<token>` | `PublicHelpTicketScreen` |

## Interfaces offered to other packages

| Symbol | Used by | Contract |
|---|---|---|
| `contactHelpDesk(context, {appId, appName, groupId, api})` | `improve_bluejay` help tab | Loads the overview, opens the form with the app as context, confirms; returns the ticket id or null |
| `mayContactHelpDesk(UserAppEntitlements, groupId)` | `improve_bluejay` help tab | True for an active user with any `g:help-desk*` entitlement in a non-denied group |
| `publicHelpDeskScreenFor(Uri)` | `lib/routing/public_links.dart` | The public page for a `/help/...` URI, or null |
| `HelpDeskLink.formPath(groupId, {orderRef})` | Links to the form | `/help/<groupId>?order=<ref>` |
| `helpDeskRecordTypes` (`help_desk_record_types.dart`) | `lib/routing/record_types.dart` | One `RecordType`: id `help-desk.ticket`, collection `help_tickets`, label Ticket / Tickets, title the subject ("Untitled ticket" when empty), subtitle the requester's name, `launchArgs` `{ticket: id}` |
| `HelpDeskRecordSearch` | `helpDeskRecordTypes` | `RecordSearch.find(query, groupId:, limit:)`: `[]` without a group, else `HelpDeskApi.search` (`helpDeskSearch`) mapped to hits from `{subject, requesterName}` |
| `ticketArg` (`'ticket'`) | `lib/routing/app_router.dart` | The launch arg that opens one ticket |
| `PlaceMarker(args: {ticket: id}, title: subject)` on `HelpDeskTicketScreen` | Chat's "Link to where I am" ([platform changes, PR #3364](../platform_changes/developer.md)) | A shared link to an open ticket reopens that ticket through the `ticket` arg; the screen's own access checks decide what the teammate sees |
| `storefront.helpFormUrl` (`functions/_shop_storefront.js`) | Shop visitor checkout | `https://bluejay.gg/help/<groupId>` when `publicIntake` is on, else null |

## Interfaces offered to other server modules

`functions/_help_desk.js` exports `createHandlers(deps)` and `defaultDeps()`. A module that files tickets calls `createHandlers(defaultDeps()).fileOnBluejayDesk(args)`.

### `fileOnBluejayDesk`

Not a callable. Used by `onDeletionRequested` in `functions/_data_governance.js`.

Arguments:

```json
{
  "requesterUid": "uid",
  "requesterKind": "person | group",
  "groupId": "acme | ''",
  "subject": "Delete group data: Acme",
  "body": "…",
  "context": { "appId": "…", "appName": "Data & privacy" }
}
```

| Field | Rules |
|---|---|
| `requesterUid` | Required, else `unauthenticated` ("You must be signed in."). The caller has already authorised this person; no access index is read. |
| `requesterKind` | `person` (default) or `group`, else `invalid-argument` ("requesterKind must be \"person\" or \"group\"."). |
| `groupId` | Optional, default `''`. The group the request is about. |
| `subject`, `body` | Non-empty after trimming, at most 120 and 5000 characters, else `invalid-argument`. Over-long text is refused, never cut. |
| `context` | Optional. Reduced to the ticket `context` keys (`appId`, `appName`, `platform`, `appVersion`, `orderRef`); other keys are dropped. |

Writes one `help_tickets` doc and its first `help_messages` doc (`side: 'requester'`, authored by `requesterUid` under their display name):

| Ticket field | Value |
|---|---|
| `deskKey` / `deskLabel` | `platform` / `Bluejay support` |
| `groupId` / `groupName` | The given group and its name, or `''` / `''` |
| `requesterKind` / `requesterUid` | As given |
| `requesterName` | `group`: `<group name> (<person's name>)`; `person`: the person's name |
| `requesterEmail` | `null` |
| `category` / `priority` | `''` / `normal` |
| `lastModifiedBy` | `requesterUid` |

It then sends the `New ticket: <subject>` notification to the Bluejay desk's staff, leaving out `requesterUid`. No To do is opened (those are for group desks) and no rate limit applies.

Returns:

```json
{ "ticketId": "abc123", "deskLabel": "Bluejay support" }
```

## App manifest (`packages/help_desk/bluejay_app.json`)

```json
{
  "appId": "help-desk",
  "name": "Help Desk",
  "icon": "support_agent",
  "iconBgColor": "#0F766E",
  "categories": ["Business"],
  "sharedEditing": false,
  "isEmbeddable": true,
  "clientPortal": true,
  "embeddableAccessModes": ["public"],
  "securityTier": "regulated",
  "visibility": "public",
  "installInGroups": ["bluejay", "developer", "games"]
}
```
