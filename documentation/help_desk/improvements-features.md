# Help Desk — Feature Ideas (Forward-Looking)

## 1. Reply by email

Public requesters, and members who prefer email, could answer by replying to the notification email. An inbound email route that maps a per-ticket reply address to `helpDeskPublicReply` (or `helpDeskReply` for a signed-in requester) would remove the trip to the link.

## 2. Satisfaction rating

After a ticket is resolved, ask the requester to rate the answer (one to five, optional comment). Store it on the ticket and show per-desk averages to the group's admins.

## 3. Desk reports

A reports view for each desk: tickets opened and resolved per week, median first-response time against the `firstResponseHours` target, overdue counts, tickets per topic, and per-agent workload. Staff get the same for the Bluejay desk plus escalations per group.

## 4. Business hours and response targets per priority

Let a desk set business hours and holidays, so overdue time only counts while the desk is open, and set separate first-response targets for High and Urgent.

## 5. Automatic assignment

Round-robin or least-loaded assignment of new tickets among a desk's agents, with an option to assign by topic.

## 6. Canned answers from guides

When an agent replies, suggest matching guide sections (reusing the guide ranking the request form already uses) and insert a link with one tap.

## 7. Embeddable help widget

A small script or iframe that groups put on their own website, opening the public form in place with the page URL as context.

## 8. Merge duplicate tickets

Let an agent merge a ticket into another from the same requester, moving its messages and closing the duplicate with a note.

## 9. Escalation status for the customer

Optionally tell a customer, in plain words, when the level above has answered (without sharing the content), so long escalations don't look abandoned.

## 10. Attachments

Requesters and agents can't attach screenshots or files. Add attachments to messages (Storage under a server-checked, per-ticket path, served through the callables like the rest of the ticket), starting with images.
