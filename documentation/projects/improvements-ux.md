# Projects — UX Improvements

- P1 | **Quick-complete skips the `In progress` state** | The checkbox only flips between `To do` and `Done`, so the three-state model is harder to use consistently. | Add a tri-state inline control or status chip picker that can move tasks through `To do → In progress → Done` without opening the edit dialog.

- P1 | **Cycle-prevention feedback is implicit** | Invalid parent tasks simply disappear from the dropdown, which can be confusing when users are reorganizing a large blocker tree. | Add helper text explaining why some parent options are unavailable and highlight that descendants cannot be selected.

- P2 | **Actionability rules are not explained in-product** | Users must infer that only direct-child blockers affect readiness, which can make the dashboard and actionable list feel surprising. | Add a short inline explainer or help affordance near the actionable sections.

- P2 | **Attachments cannot be removed or replaced from the task card view** | Once a task is saved, the only way to remove or update an attachment is to re-open the edit form. There is no quick-remove action on the image carousel or file chips. | Add a context menu or long-press action on task card attachments for quick removal without opening the full edit form.

- P2 | **No drag-and-drop or paste support for attachments** | Users must use the file picker; there is no way to drag a file into the form or paste an image from the clipboard. | Add paste-from-clipboard support (especially useful on desktop/web) and consider a drop-zone in the attachments section.
- P2 | **Multi-file uploads show only aggregate progress** | The task form displays a global progress indicator while files upload, so users cannot tell which file is progressing or whether one item is stalled. | Show per-file upload progress and a clear retry or remove action for a failed upload.

- P3 | **Hidden-attachment warning is informational only** | When non-trusted URLs are detected in `attachments`, a text notice appears but no action is offered. | Offer a **Remove hidden** button that strips untrusted attachment entries from the document in one tap.
