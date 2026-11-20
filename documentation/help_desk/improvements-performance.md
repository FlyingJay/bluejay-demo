# Help Desk — Performance Improvements (Forward-Looking)

## 1. Stop resolving every agent on each ticket open and notification

`deskAgents` re-reads the group doc and one access index per admin (or per support/admin role holder for the Bluejay desk) on every `helpDeskGetTicket` for the desk side, every reply, every status change and every assignment. `getTicket` then reads each agent's user doc for names. Cache the agent list per call (several handlers resolve it twice), and consider a small denormalised `help_desk_agents` view per desk refreshed by the access-index rebuild.

## 2. Fill the `mine` page before the limit

`helpDeskList` with `view: 'mine'` queries `groupId + requesterUid`, takes 100 rows, then drops `requesterKind: 'group'` rows. An admin with many upstream tickets sees a short or empty page while older person tickets exist. Add `requesterKind == 'person'` to the query (with a matching composite index) so the limit applies to the right rows.

## 3. Page lists and messages

Lists stop at 100 rows and tickets at their first 500 messages, with no cursor. A busy desk can't reach older closed tickets, and a long-running ticket hides its newest messages (the read is oldest first). Add `startAfter` cursors to `helpDeskList`, and read messages newest first with a "load earlier" cursor.

## 4. Make ticket updates transactional

Replies and status changes read the ticket, then `update` with `messageCount` computed from that read. Two replies at the same moment both write the same count, and both notifications get the same key (`m<n>`), so the second notification is deduplicated away. Use `FieldValue.increment(1)` for `messageCount`, or a transaction that reads the count and writes the message and ticket together, and key notifications on the message id.

## 5. Stop minting a token per email

Each email to a public requester writes a new `help_desk_links` doc, and none are deleted. Long public conversations grow the collection without bound. Reuse a ticket's live token (extending `expiresAtMs`) and add a TTL policy or cleanup for expired tokens.

## 6. Batch the auto-close

`helpDeskAutoClose` writes a message and an update per ticket sequentially, up to 400 per run, and anything beyond 400 waits a day. Use a `BulkWriter` or batched writes, and loop until the query is empty.
