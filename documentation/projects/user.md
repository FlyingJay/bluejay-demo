# Projects — User Guide

Projects helps your group track shared projects, break them into blocker tasks, and surface the next tasks that are actually ready to work on.

## Before you start

| Requirement | Why it matters |
|---|---|
| Logged-in account | If no user is available, the app shows `Please log in to manage projects.` |
| Projects access in the active group | Anyone with the Projects app enabled for the active group can see that group's projects. |
| Active group selected in Bluejay | Project and blocker queries are limited to the active group. Firestore rules also enforce group and app access on reads and writes; the screen alone does not grant access. |

## What you can do in Projects

- Create a project with a name, goal, status, description, and optional due date.
- Duplicate an existing project's metadata to start a similar project faster.
- Add tags to projects (for example `urgent`, `redesign`, `q3`) and filter the dashboard by one or more tags.
- Link projects to the Bluejay apps they concern and, for platform admins, to client groups that use those apps.
- Break work into blocker tasks.
- Link blocker tasks into a dependency tree using **Blocked by task**.
- See a progress bar based on completed blocker tasks.
- See the most urgent actionable task (lowest priority number first) on the dashboard and up to five actionable tasks in the detail view.

## Core workflow

1. Open **Projects** from the launcher.
2. Tap **New project** — a form sheet slides up from the bottom.
3. Enter:
   - **Project name** (required)
   - **Goal** (optional)
   - **Description** (optional)
   - **Tags** (optional — add one or more and remove chips as needed)
   - **Status**: Planned / Active / On hold / Completed (tap a chip to select)
   - **Due date** (optional — tap **Pick date**)
4. Tap **Create project**.
5. Tap a project card to open the detail screen.
6. Add blocker tasks with **Add blocker** or the **Add** button — another form sheet slides up.
7. In the task form you can also:
   - Set status and priority via chips
   - Choose **Blocked by task** to create a dependency
   - Upload files with **Add files**
8. Mark tasks done as blockers clear so new highest-urgency work becomes actionable.

## Link a project to apps and client groups

When creating, editing, or duplicating a project, use **Apps** to select the Bluejay apps the work concerns. The picker shows apps installed in the active group. Saved app links remain visible if an app is later uninstalled; deselect a saved app to remove it.

Platform admins can also choose **Client groups**. Select one or more apps first; Projects then lists groups that have at least one selected app installed. The group names are saved with the project so they remain recognizable even when the groups are no longer returned by the picker. Non-admins can see existing client-group links but cannot change them. If a picker cannot load, any existing links are retained when the project is saved.

App and client-group links appear as chips on the project card and detail header. They describe the work's context; they do not grant access to those apps or client groups.

## How blocker planning works

Projects uses a blocker tree instead of a flat checklist.

- A task with no parent is a top-level blocker.
- A task with **Blocked by task** is treated as being blocked by that parent task.
- A task becomes **actionable** when it is **not done** and **all of its direct child blockers are done**.
- Lower priority numbers win first (P1 before P2); ties are broken by earliest due date, then alphabetical title.

In practice, this means the app encourages leaf-first execution: finish lower-level blockers first so higher-level work becomes ready.

## Dashboard behaviour

| Area | Current behaviour |
|---|---|
| Project visibility | You see every project in the active group when you have Projects access for that group. |
| Empty state | Shows **No projects yet** with guidance to create your first project. If projects exist but none match the filters, shows **No projects match these filters** with a **Clear filters** button. |
| Sorting | Non-completed projects appear before completed ones; within each group, earlier due dates appear first, then titles. |
| Status filters | A filter card at the top of the list lets you show **All** projects or a single status (Planned / Active / On hold / Completed). Each chip shows how many projects have that status, for example `Active · 3`. The selection is remembered while the screen is open. |
| Tag filters | The same card lets you select **Any tag** or one/more tags. Multi-tag selection uses **AND** logic (a project must contain every selected tag). With no tags in the group, it says so instead. |
| Clear filters | While any filter is on, the list header shows **Clear filters**, which resets both status and tags. |
| Project cards | Each card shows the title, goal, description, and pills for status, due date, tags, apps and client groups. A due date that has passed on an unfinished project reads **Overdue**. On wide screens, cards sit in two columns. |
| Next action | Each project card ends with the single most urgent actionable blocker and its priority (lowest priority number first), or `No actionable blocker right now.` |
| Project menu | Users with group edit/admin access get **Edit project** and **Delete project**. Users who can create can also **Duplicate project**. |
| Load errors | If projects or tags fail to load, the screen says so and offers **Try again**. |

## Project detail behaviour

| Section | Current behaviour |
|---|---|
| Summary card | Shows the project goal, optional description, a progress bar with a percentage based on `done tasks / total tasks`, the `N of M blocker tasks completed` count, and status, due date, tag and link pills. |
| Actionable next tasks | Shows up to five actionable tasks with their priority, most urgent first, and how many more there are. On wide screens this list sits in a sidebar beside the blocker flow map. |
| Blocker flow map | Renders top-level tasks and nested child blockers, indented behind a coloured rail. Each task shows its status, priority and due date, and a task with unfinished blockers beneath it shows how many (for example `2 open blockers`). |
| Completed-task visibility | A **Hide completed** chip (showing how many tasks are done) lets you hide done tasks from the blocker flow map. When enabled, tasks whose parent is hidden are promoted to top-level so remaining unfinished work stays visible. If every task is done, the map says so and offers **Show completed**. |
| Task status | Tasks support **To do**, **In progress**, and **Done**. |
| Fast completion | The checkbox toggles only between **To do** and **Done**. Use **Edit** if you need to set **In progress**. |
| Task menu | Each task's **⋮** menu holds **Edit**, **Add blocker beneath this task**, **Create change request**, and **Delete**, depending on your access. |
| File attachments | Each task card shows uploaded images as a swipeable carousel and non-image files as tappable chips. |
| Related apps and client groups | Saved links are shown as chips; they are descriptive and do not change who can view the project. |
| Notifications | When someone adds a task to the project or closes one, everyone else in the group who can open Projects is notified. The bell in the project header turns these alerts on or off for you, for that project only. They're on by default. To silence every Projects alert, use your notification settings. |

## File attachments on tasks

You can attach files (images, PDFs, documents, and more) to any blocker task.

### Uploading files

1. Open the task create or edit form.
2. Scroll to the **Files** section at the bottom of the form.
3. Tap **Add files**.
4. Select one or more files from your device.
5. Files upload automatically while the form is open. A progress bar appears during upload.
6. Each uploaded file appears in the form list with its name and size.
7. To remove a file before saving, tap the × button next to it.
8. Save the task to commit the attachment list.

**File size limit:** Each file must be 10 MB or smaller. Files over 10 MB are skipped with a notification.

### Viewing attachments on a task card

After saving, attachments appear inside the task card in the blocker flow map:

- **Images** (`.png`, `.jpg`, `.jpeg`, `.gif`, `.webp`, `.bmp`, `.heic`, `.heif`) are shown in a swipeable **image carousel** at a fixed 160 px height. Dot indicators below the carousel show which image is active; tap a dot to jump to that image.
  - Tap any image to open a **fullscreen viewer** with pinch-to-zoom (up to 4×) and swipe navigation across images.
- **Non-image files** (PDFs, documents, spreadsheets, etc.) appear as tappable **file chips** labelled with the file name.
  - Tapping a chip opens a bottom sheet showing the file name and a tappable link to open the file in a browser or external app.

### Trusted-source security check

For security, the app only displays attachments from trusted Firebase Storage hosts:

- `firebasestorage.googleapis.com`
- `storage.googleapis.com`

Attachments from any other host are hidden and a notice appears in the task card: *"Some attachments are hidden because they are not from trusted https sources."* Attachments uploaded through the app's own **Add files** button always come from these trusted hosts.

## Who can do what

On the dashboard:

- Anyone with base Projects access in the active group can view group projects and create new projects and blocker tasks.
- Users with `:edit` or `:admin` access for the active group can edit and delete existing projects and blocker tasks.
- Platform admins can do everything.

Project, blocker, and attachment access is scoped to the active group and the Projects app. The screen hides actions a user cannot perform, and Firebase security rules independently reject unauthorized group/app operations.

Inside a project:

- Users with base Projects access can add new blocker tasks.
- Users with `:edit` or `:admin` access can edit, delete, and checkbox-complete existing blocker tasks.
- Platform admins can do everything.

## Create an Improve Apps change request from a task

If you can create tasks in the active group, a task without an existing request has **Create change request** in its **⋮** menu. Use it to submit the task as an Improve Apps bug or feature request, with its description and project context included.

1. Choose **Create change request**.
2. Select **Feature** or **Bug**, then choose the app the request concerns. If the project has related apps, those are offered; otherwise, the app must be installed in the active group.
   - For a **Bug**, fill in **Steps to reproduce** (required, at least 20 characters) and optionally **What did you expect?** / **What happened instead?** — the same section, with the same **See an example**, as the Improve Apps bug form.
3. Tap **File bug report** or **File feature request**. The request is filed in Improve Apps and linked back to the task. While it is being filed, the task shows `Filing change request…` and the menu item is greyed out so it can't be sent twice.

The task shows the linked request's lifecycle: **Filed**, **Queued**, **In review**, **Deploying**, **Live**, or **Closed**. When its change is live, the task is marked **Done** automatically. Closing a request without resolving it does not complete the task. If the task already has a linked request, the action is hidden; a failed submission may also report that one was already created.

The action is enforced by the server: the caller needs Projects access in the task's group, the app must exist, the task must have a title or description, and a bug must include steps to reproduce. To follow the request after it is filed (votes, comments, status), open it in Improve Apps; see the Improve Apps guide.

## Share a link to a project or task

When Chat is open over Projects, its **Link to where I am** attachment links to what you are looking at: the open project, or the task you are editing. A link that opened a task keeps pointing at that task. See the [Chat guide](../chats/user.md) for sending links.

Opening a link that points into Projects:

- opens that project, if you can see it in that group;
- for a task link, scrolls to the task and outlines it, and turns off **Hide completed** if the task is already done;
- leaves you on the project list with "That project isn't available. It may have been deleted, or you can't see it." when the project is gone or hidden from you;
- shows "That task isn't in this project any more." when the task was deleted or moved to another project.

## Duplicating a project

Anyone who can create projects in the active group can open the card menu and choose **Duplicate project** to start a new project from an existing one.

- The duplicate form is pre-filled with the source project's name, goal, description, tags, status, and due date.
- You can change any of those fields before saving.
- Saving creates a brand-new project record with its own owner and fresh timestamps.
- The new project keeps the new creator as its owner, but visibility still comes from the active group rather than a project member list.
- Blocker tasks, task attachments, and member rosters are **not** copied.

## Project tags and filtering details

- Tags are optional and are managed from the project create/edit form.
- Tags are reusable within a group. Existing group tags appear as quick-pick suggestions whenever you create, edit, or duplicate a project.
- Duplicate tags are prevented case-insensitively (for example, `Urgent` and `urgent` are treated as the same tag).
- Extra whitespace is normalized automatically.
- Tags are shown directly on each project card.
- The dashboard tag filter works client-side across visible projects and can be combined with the status filter.

## Current safeguards and edge cases

- **Project name is required.** Saving with a blank title shows `Project name is required` under the field.
- **Task title is required.** Saving with a blank task title shows `Task title is required` under the field.
- **Deletes ask first and say what goes.** Deleting a project lists how many blocker tasks go with it; deleting a task says where its child blockers move and how many attachments are unlinked. Neither can be undone.
- **Dependency cycles are blocked in the task editor.** When you edit a task, the parent picker excludes the task itself and its descendants.
- **Existing cycles still render.** If saved tasks already form a cycle, the flow map shows each task once instead of looping.
- **Deleting a project deletes all of its blocker tasks** in the same operation.
- **Duplicating a project copies metadata only.** It does not clone blocker tasks, attachments, or additional members.
- **Deleting a blocker task reattaches its direct children** to the deleted task’s parent.
- **A task can have only one linked change request.** The server rejects a duplicate even if two clients race to submit it.
- **A linked request completes its task only when resolved/live.** A closed request leaves the task open.
- **Hide completed affects only blocker-map visibility.** Progress and actionable-task calculations still use the full task list.
- **Dates are date-only.** The UI displays `YYYY-MM-DD` and does not show time-of-day or time-zone text.

## Troubleshooting

| Problem | Likely cause | What to do |
|---|---|---|
| `Please log in to manage projects.` | No authenticated user was passed into the screen. | Sign in and reopen Projects. |
| `Couldn't load projects` (or tags, or this project's tasks) | A Firestore read failed, often a dropped connection or a permission change. | Tap **Try again**. If it keeps failing, check the active group and your Projects access. |
| You cannot find a project | You are in the wrong active group, or your group does not have Projects access. | Switch to the correct group or ask a group admin to grant the Projects app to your group. |
| A project or attachment operation is denied | Your account may not have an active Projects entitlement for this group, or the selected group may have changed. | Confirm the active group, refresh Projects, and ask a group admin to check your access. |
| A task is missing from the parent dropdown | The app is preventing an invalid self-reference or descendant cycle. | Choose a different parent or move the task higher in the tree first. |
| `No actionable tasks yet` even though tasks exist | Every remaining task still has an unfinished direct child blocker. | Finish child blockers first or edit the dependency tree. |
| A completed task seems missing in the blocker map | **Hide completed** is enabled. | Turn off **Hide completed** to show completed tasks again. |
| A task moved after delete | Children are intentionally reattached to the deleted task’s parent. | Edit those tasks if you want a different structure. |
| Files skipped during upload | Files were over the 10 MB per-file limit. | Compress or split large files before uploading. |
| *"Some attachments are hidden…"* notice appears | Attachments were saved with URLs not from Firebase Storage trusted hosts. | This can occur with older attachments or external URLs; upload through the **Add files** button to replace them. |
| Image shows broken icon in the carousel | The file was deleted from Storage or the download URL expired. | Re-upload the image from the task edit form. |

## Practical tips

- Keep blocker tasks small and specific so the actionable list stays meaningful.
- Use priorities consistently across your team; lower numbers are treated as more urgent.
- Use **In progress** for richer status tracking, but remember the checkbox shortcut does not cycle through that state.
- Reserve **Completed** for truly finished projects so dashboard sorting stays useful.
- Keep tag names short and consistent (for example, choose either `high-priority` or `urgent`, not both) so tag filters stay effective.
- Review the dependency tree after deleting or moving blocker tasks so the flow still matches reality.
- Upload reference images and supporting documents directly to a task so context stays with the work item.
- Images under 10 MB load most smoothly in the carousel; resize large photos before attaching.
