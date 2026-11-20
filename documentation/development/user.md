# Development — User Guide

Bluejay builds changes to its apps when the people using them ask. This guide explains what happens to a request after you send it: how it moves through your queue, how it gets built and checked, how you try it before it goes live, and what to expect from the test version you try it in.

---

## Your queue

Every member of a group that handles its own requests has a personal **queue**: an ordered list of the changes they have asked for. Open it from the queue chip at the top of the home screen. The chip shows what is being worked on right now, for example "Building: Export to CSV".

The queue screen has three parts:

- **Now**: the request being worked on and the step it has reached.
- **Up next**: your other requests, in the order they will be picked up. You can reorder them.
- **Shipped**: changes of yours that have gone live.

New requests come from **Request a change** in an app, or from the **Request a change** button on the queue screen (which can also ask for a new app). After you send one, the confirmation tells you where it landed, for example **Added to your queue: #3**.

Your group has a set number of developer agents. Each one works on one request at a time, so when they are all busy your next request waits its turn and shows **Waiting for your developer agent**. While a request waits for one, and your group shares its developer agents, a note above **Up next** says so: group admins get an **Add a developer agent** button, which opens the **Billing** tab in Group Admin, and other members are told their admins can add one.

---

## From request to live

Each request shows a status word. You will see these, roughly in this order:

| Status | What it means |
| --- | --- |
| **Up next** | Waiting in your queue. A short note may say why, for example "Our team is looking into this". |
| **Waiting for your developer agent** | It is next, and starts when one of your group's developer agents is free. |
| **Building** | A developer agent is building the change. |
| **Checking** | The change is built and automatic checks are running on it. |
| **Waiting on you** | Someone has a question for you. Answer it from your queue so work can continue. |
| **Ready to try** | A test version with your change is ready. Try it, then approve it or ask for a tweak. |
| **Final review** | A Bluejay developer is reviewing the change. "Going live" means it has been approved and is on its way. |
| **Live** | The change is part of Bluejay for you and everyone else who uses the app. |
| **Declined** / **Closed** | The request will not go ahead. Declined requests come with a reason. A request closed as **Not ready to build yet** is wanted later but needs more detail first; it goes back in your queue if it is reopened. |

You get notifications at the main steps, including when a request needs you (**Waiting on you** or **Ready to try**) and when it goes live.

If you don't respond to a question or a ready-to-try request within about two business days, your developer agent moves on to your next request. Your request keeps waiting for you, and work continues once you respond.

---

## Trying a change before it goes live

When a bug fix or improvement you asked for reaches **Ready to try**, your queue shows:

- **Try it**: opens a preview, a separate test version of Bluejay that includes your change.
- **Approve**: tells the team the change does what you wanted. It then goes to final review.
- **Ask for a tweak**: describe what should be different. The change goes back to building, and you get a new version to try when it's ready.

If a newer version of the change arrives while you are looking at an older one, your queue tells you so. Open the newest one before you approve.

Bluejay developers reviewing a change can open the same preview.

If you asked for a new app, its preview has the new app installed in your group's test copy, so you can open it from the home screen there.

### Results that open in their own app

Some requests produce a result an app holds directly, such as a dashboard, instead of a change to an app's code. When one is ready, **Try it** and the **Ready to try** notification open it in that app. **Approve** makes it live straight away: there is no final review step, and you are told the change is live.

---

## What a preview is

A preview is a temporary copy of Bluejay with the new change in it. It runs on a separate test copy of your own group's data: your group's records, the accounts of your group's members, and the list of apps. Your real data is never touched. Other customers can't see or change your test copy, and you can't reach theirs.

Every screen of a preview has a **Preview** label in the corner, so you can tell it apart from the real Bluejay.

Sign in with the email address and password you normally use. Signing in with Google is not available in previews yet: choosing it shows a notice. If you only sign in with Google, you can try the change once it goes live.

Links you copy inside a preview, such as a client portal or form link, open the same preview.

### What works and what doesn't

- **No real payments.** Billing is switched off. Nothing you do in a preview charges a card.
- **No emails, texts or push notifications.** Nobody receives a message because of something done in a preview, so people in your group won't be contacted.
- **No AI features.** Features that use AI (for example summaries, suggestions or the help assistant) don't work in a preview.
- **The data is a copy.** Anything you add, change or delete in a preview stays there. It is never copied back to your real data.
- **The copy can be reset.** The test copy is refreshed or removed from time to time, so changes you made in it can disappear.
- **Some behind-the-scenes parts may be missing.** A preview shows the new screens. If the change also needs new work on Bluejay's servers, that part may not be in the preview yet, so a step that depends on it can behave as it does today. If something looks unfinished, say so in your request.
- **Previews expire.** A preview link stops working after about a week. Each new version of the change starts that week again.

### What to do

- Try the change the way you would use it for real: open the app, follow your usual steps, and check the part you asked about.
- If something is off, use **Ask for a tweak** and describe what you saw. If it does what you wanted, use **Approve**.

### What not to do

- Don't enter real payment details, even though nothing is charged.
- Don't rely on a preview for real work. Anything you do there is lost when the copy is reset.
- Don't share the preview link with people outside your group.

