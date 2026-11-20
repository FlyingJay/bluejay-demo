# Notes — User Guide

Notes is Bluejay's lightweight note pad for quick text-only notes inside your current group. Use it for reminders, meeting bullets, handoff notes, and anything else you want to capture without creating a larger document.

## What Notes is good for

- Quick personal reminders inside your current Bluejay group
- Shared scratch notes for a small set of teammates
- Lightweight lists, agendas, or follow-ups that do not need formatting
- Fast capture from mobile or desktop without leaving the launcher

Notes is intentionally plain text. There is no Markdown preview, folders, tags, or attachment support.

## Before you start

- You must be signed in.
- You must have an active Bluejay group selected.
- Notes are stored in the active group only.
- The share picker lists people from the active group.

A note is private to you and the people you share it with. Other members of your group cannot open it, except your group's Notes administrators, who can see every note in the group.

## Open the Notes app

1. Open the Bluejay app launcher.
2. Choose **Notes**.
3. The main screen shows notes you created plus notes shared with you.

## Create a note

1. Tap **New note** in the bottom corner (or the **New note** button on the empty screen when you have no notes yet).
2. Enter an optional title.
3. Type your note content.
4. Tap **Save** in the top-right.

### What happens if the note is blank?

- If a **new** note has an empty title and empty body, saving simply closes the screen and nothing is created.
- If an **existing** note is cleared out completely, saving asks **Delete this empty note?**. Choose **Delete note** to remove it or **Keep editing** to go back to it.

## Edit a note

1. Tap a note from the list.
2. Change the title or body.
3. Tap **Save** to save and return to the list.

### Autosave

Changes to a note that already exists save on their own about two seconds after you stop typing, and also when you switch away from the app or browser tab. The note stays open, the pill changes to **Saved**, and the "Edited" time updates. People the note is shared with see the autosaved text too.

Autosave does not cover everything:

- A **new** note is not stored until you tap **Save** (or **Share**). Closing or refreshing before that loses it.
- A note you have cleared out completely is not autosaved. Tap **Save** to get the **Delete this empty note?** prompt.
- If an autosave fails (for example, with no connection), no error appears. The pill keeps showing **Unsaved changes**; tap **Save** to try again and see any error.

### Save status

The editor shows a status pill above the title:

| Pill | Meaning |
|---|---|
| **Not saved yet** | A new note that has never been saved |
| **Unsaved changes** | You have edits that are not saved (the **Save** button also shows a dot) |
| **Saving…** | The note is being saved, by you or by autosave |
| **Saved** | What you see matches the stored note |

Next to the pill, an existing note shows when it was last edited ("Edited Today 4:30 PM", "Edited Yesterday", or a date).

If you try to leave with unsaved edits, Notes asks **Save your changes?** and offers:

- **Keep editing** to stay on the note
- **Discard** to leave without saving; the last saved version is kept. On an existing note that includes anything autosave already stored, so only your most recent unsaved typing is dropped
- **Save and exit**

## Share a note

You can share a note with one or more people in the same group.

1. Open the note.
2. Tap **Share** on the sharing line under the title.
3. Search for group members.
4. Select one or more people.
5. Confirm your selection.

The picker searches group member names and email addresses. It excludes your own account and people already on the note's share list.

After sharing:

- The note appears in the recipient's Notes list.
- Notes asks Bluejay to notify the newly selected recipients. They must still belong to the same group when the notification is sent.
- Recipients can view and edit the note.

The note is saved before the notification request. If notification delivery fails, the share remains in place. Bluejay may also skip a recipient who is no longer an active member of the group.

### See who a note is shared with

The line under the title shows who has the note: **Only you** with a lock icon when it is not shared, or small initials avatars and a label such as "Shared with bob and carol" or "Shared with bob, carol +2". Names are the part of each person's email before the `@`.

### Sharing a new note before saving

If you tap **Share** on a new note:

- Notes first creates the note automatically.
- Then it opens the user picker.
- If you cancel without choosing anyone, the note remains created but unshared.

### Sharing an empty note

If both title and body are empty, Notes will not let you share the note and asks you to add a title or some text first.

## Delete a note

1. Open the note.
2. Open the **More actions** (**…**) menu in the top-right and choose **Delete note**.
3. Review the confirmation and tap **Delete note**.

The confirmation lists what deleting takes away: the title and text are deleted for good, the people it is shared with lose it too, and, for a note someone else shared with you, the person who shared it loses it as well.

Important: deleting is permanent inside the app. There is no undo or recycle bin.

## Understand the list screen

The main screen shows your notes as a grid of cards: notes you created and notes shared with you, sorted by **most recently edited** first. The grid uses more columns on wider screens.

### Search and filter

- Type in **Search notes** to narrow the grid to notes whose title or text contains your words (not case-sensitive).
- Use the filter chips to show **All**, **My notes**, or **Shared with me**. The **Shared with me** chip appears only when someone has shared a note with you.
- The heading above the grid shows how many notes match. If none do, Notes says **No notes match**.

### Visual cues

| What you see | Meaning |
|---|---|
| **Shared with you** pill | The note was created by someone else and shared with you |
| **Shared · 3** pill | You shared your note with that many people |
| `(Untitled)` | The note has no title |
| *No text yet* | The note has a title but no body |
| Up to five lines of text | The first part of the note body |
| "Today 4:30 PM", "Yesterday", or a date | When the note was last edited |

If your notes can't load, the screen says **Couldn't load your notes** with a **Try again** button.

## Common situations

### "I saved a note and now I can't find it"

Check these possibilities:

- The note was completely blank, so nothing was saved.
- You are in a different active group than the one where the note was created.
- The note title is empty, so it may appear as **(Untitled)**.
- A search term or the **My notes** / **Shared with me** filter is hiding it.

### "I got a notification for a shared note"

Tapping the notification opens the note directly when you are in the group the note belongs to.

### "I shared a note but the other person didn't get notified"

The share itself may still have succeeded. Notification delivery is best-effort, and a recipient who left the group may be skipped. Check the recipient's Notes list while they are in the correct group.

### "Can I remove someone I already shared with?"

No. Notes lets you add recipients but has no way to remove them from a note's share list.

## Practical tips

- Use short, descriptive titles so shared notes are easy to spot.
- Add at least a title or a line of content before sharing a new note.
- If a note matters long-term or needs formatting, move it to a richer app such as Documents.
- Share only with people you trust to edit the note, since every recipient can change it.
