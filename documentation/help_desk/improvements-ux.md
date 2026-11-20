# Help Desk — UX Improvements (Forward-Looking)

## 1. Show the platform desk only the settings it uses

Bluejay desk settings show **Topics**, but tickets on the Bluejay desk never use them: staff-group tickets take the filing group's topics, and upstream tickets have none. Hide Topics for the platform desk, or start offering the platform desk's topics on the upstream form.

## 2. Record assignment in the conversation

Assigning or unassigning changes `assigneeUid` with no system message, so the thread doesn't show who handed a ticket to whom. Add an internal system note ("Jamie assigned this to Sam").

## 3. Keep the escalated state visible after a customer replies

A customer's reply on an escalated ticket moves it to **Needs reply**, and the list no longer shows that it's waiting on the level above. Keep a visible "Escalated" pill on list rows while `upstreamTicketId` points to an active ticket, and show the upstream ticket's status in the details card.

## 4. Let agents pass an upstream answer on in one step

When the level above replies, the group's agents see an internal note with the answer and then retype or paste it to the customer. Add "Reply to customer with this" on those notes, prefilling the composer for editing.

## 5. Show live counts without opening the app

Tab counts come from the loaded lists, so an agent only learns of new requests from notifications or by opening Help Desk. Surface the inbox's "needs reply" count as an app badge in the launcher.

## 6. Search and filter tickets

There is no search, and the only filter is open versus finished. Add search by subject and requester, and filters for assignee ("Assigned to me"), priority, topic and overdue.
