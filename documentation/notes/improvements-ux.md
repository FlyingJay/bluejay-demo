# Notes — UX Improvements

## 1. Add in-app share management and unshare controls

**Current friction:** The UI lets users add more recipients, but not review and remove existing ones. Users cannot tell who currently has access without inspecting Firestore or remembering prior shares.

**Why it matters:** Sharing feels one-way and hard to manage, which is especially confusing for collaborative notes that change ownership expectations over time.

**Proposed improvement:** Add a "Manage sharing" sheet or section on `NoteDetailScreen` that shows current recipients and lets the author remove them.

## 2. Preserve drafts of brand-new notes

**Current friction:** Existing notes autosave a couple of seconds after typing stops and when the app or tab is hidden, but a brand-new note is only written when the user taps **Save**. A browser refresh, app kill, or tab close before that still discards it.

**Why it matters:** Users will trust Notes more for meeting capture and brainstorming if partial work survives interruptions from the first keystroke.

**Proposed improvement:** Keep a local draft of an unsaved new note (or create it on first pause in typing, with **Discard** deleting it) and offer to restore it the next time **New note** is opened.
