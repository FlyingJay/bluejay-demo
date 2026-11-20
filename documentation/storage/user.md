# Storage — User Guide

Storage is a group-scoped file sharing app. Upload a file, keep it private to its group, or publish a copy that signed-in Bluejay users can read. You can also share a file directly with teammates, or, when your group's client portal includes Storage, with a client.

## What you can do

- Upload files of any type from your device or computer
- Choose **Public** (published for signed-in Bluejay users) or **Private** (available only to you and people you explicitly share with)
- Give each file a human-readable display name at upload time
- Keep your files in folders, and folders inside folders
- Share your files with specific users from within the app, or share a whole folder and everything in it
- Download any file you can see
- Delete files you own (Firestore record and Storage file are both removed)
- See how much storage space you have used, and the group's Storage plan (free tier or pay as you go)
- Receive files your clients send from the client portal, when the portal includes Storage
- View file details: chosen name, file type, size, upload date, visibility, original filename, and uploader details when available

---

## Before you start

- Sign in and select an active group to access that group's file records. The Public tab has no sign-in prompt, but published file reads require authentication.
- The **Public** tab lists files published by the active group. A published copy is readable by any signed-in Bluejay user, including users outside that group; it is not an internet search listing or anonymous access.
- Upload, share, and delete require a signed-in account. Sharing and deletion are checked by the server against current group membership, Storage access, and file ownership.
- Public files are copied into a separate published area. A copied Firebase download URL may be usable as a bearer link, so share it only with people who should have access.

---

## Tabs

| Tab | What it shows |
|-----|---------------|
| **Public** | Files published by the active group, newest first |
| **My Files** | Your folders and the files you uploaded (Public and Private): folders first by name, then files newest first |
| **Shared** | Files and folders other members have shared with you, laid out in the same folders |
| **From clients** | Files your group's clients sent from the client portal, newest first. Shown only when the portal gives clients Storage. |

The tab bar stays pinned at the top while the usage summary scrolls away. Each tab shows a header with the number of files, and on wide screens files are laid out in two columns. While a tab loads you see placeholder rows; if loading fails you see **Couldn't load files** with a **Try again** button.

### File rows

Each file row shows:

- An icon for the file's type (image, PDF, document, spreadsheet, slides, video, audio, archive, code, or a generic file), worked out from the file extension
- The display name, then **Uploaded by &lt;name&gt;** (or **Shared by &lt;name&gt;** on the Shared tab) and a short upload date. Files on the Public tab show only the date, because published copies don't include the uploader.
- A **Public** or **Private** pill and a size pill
- On your own files, a **Shared with N** pill once you've shared the file

On wider screens a **Download** button sits at the end of the row; on phones Download is in the row's menu. Every other action is in the **More actions** menu (⋮), always in this order: **File details**, **Copy link** (public files only), **Download**, **Move to folder** and **Share** (your files only, Move on My Files), **Delete** (your files only, shown in red).

---

## Folders

On **My Files**, **New folder** makes a folder in the one you have open. Tap a folder to open it; the bar above the list shows where you are, and tapping any name in it, or the up arrow, goes back up. Each folder row shows how many items are directly inside it.

- **Uploads** go into the folder open on My Files when you start the upload.
- **Move to folder** (in a file's or folder's menu) moves it into another of your folders, or back to the top level of Your files. A folder can't be moved into itself or a folder inside it.
- **Rename** changes a folder's name.
- **Share** on a folder shares the folder and everything of yours in it, including the folders inside it. Anything you add to a shared folder later, by uploading or moving it there, is shared with the same people. Moving a file out of a shared folder doesn't unshare it.
- **Delete** on a folder deletes it and everything of yours in it, all the way down, after a confirmation that says how many items go with it.

On **Shared**, folders shared with you open the same way, showing what is in them. A file shared with you on its own shows at the top level even when its owner keeps it in a folder. Folders are never public: they don't appear on the Public tab, though a public file can sit in a folder.

A client the portal gives Storage sees a shared folder's files in their list, without the folder, and gets one notification for the folder rather than one per file.

---

## Storage usage

When you are signed in, Storage shows a usage summary card above the tabs:

- **Your usage:** "&lt;size&gt; stored", with your file count and the group's plan underneath, for example "3 files · Free tier · 12.5 GB of 50 GB", "3 files · Pay as you go" or "3 files · Unlimited storage"
- **Group total (admins):** group admins also see the group's combined size and file count, a bar showing your share, and "Your files are N% of the group's storage"

---

## Storage plan

Each group is on one of three plans:

| Plan | What it means |
|------|---------------|
| **Free tier** (the default) | The whole group can store up to the free amount (50 GB unless Bluejay sets otherwise) at no charge. An upload that would take the group past it is refused before it starts. |
| **Pay as you go** | No limit. The first part up to the free amount stays free; the rest is billed each month to the admin who turned it on, at the price per GB shown. |
| **Unlimited storage** | Granted by Bluejay. No limit and no charge. |

Open the plan with the **Storage plan** button (the usage icon in the top-right corner), or from **Storage plan** in the group's App settings. The screen shows:

- How much the group stores, with a bar against the free amount ("N% of the free 50 GB", or "The free tier is full: uploads are paused")
- **Plan:** the free tier and pay as you go as two options. Only group admins can change it; everyone else sees "Only the group's admins can change the plan."
- **Price:** the price per GB per month, the free amount, and the price per 100 GB per month. Usage is averaged over the month, so a file kept for a week costs a quarter as much as one kept all month.
- **Billing** (pay as you go only): who it's billed to and what this month would cost at today's usage. It is charged at the start of each month for the month before, with your other Bluejay invoices in Wallet.

**Turning on pay as you go (admins):** you need a default card in Wallet first; the screen warns you if you don't have one. Confirm **Turn on**, and you become the payer at the price you were shown. If the price changed since you opened the screen, Storage asks you to review the new price and try again.

**Switching back to the free tier (admins):** the group must already store less than the free amount. Storage used on pay as you go earlier in the month is still billed.

Other group admins get a notification when the plan changes.

### When the group is out of free space

On the free tier, if the file you pick would take the group past the free amount, Storage shows **Not enough storage** instead of the upload dialog. Admins are told to delete files or turn on pay as you go; everyone else is asked to contact a group admin. **See storage plan** opens the plan screen.

---

## Uploading a file

1. Tap the **Upload** button (bottom-right corner). If My Files is empty, you can also use the **Upload a file** button in its empty state.
2. Pick a file from your device using the system file picker. On the free tier, Storage first checks that the group has room for it (see [When the group is out of free space](#when-the-group-is-out-of-free-space)).
3. In the **Upload a file** dialog, check the **File name** (pre-filled with the part of the filename before the first dot; edit as needed).
4. Under **Who can see it?**, pick **Public** or **Private**. Neither is selected for you, and **Upload** stays disabled until you pick one and the name isn't blank.
5. Tap **Upload**. The button shows a progress ring and "Uploading N%" while the upload runs, and can't be pressed again until it finishes.
6. On completion a "File uploaded" confirmation appears and all three tabs refresh automatically.

> **Web:** Upload progress is tracked in real-time (0 → 100 %).  
> **Mobile:** Progress jumps straight to 100 % after the upload finishes.

---

## Sharing a file with specific users

For a private file, sharing grants access to selected group members without publishing it. A public file is already published to signed-in Bluejay users.

1. Find your file in **My Files**.
2. Open the file's **More actions** menu (⋮) and choose **Share**.
3. If your group's client portal includes Storage, choose **People in your group** or **A client** first.
4. For people in your group, search for and select one or more users in the User Search screen, then tap **Done**. For a client, pick one client from the list; clients the file is already shared with are left out.
5. Storage confirms "Shared with 1 person" or "Shared with N people" (for a folder, "Shared with N people, with everything in it"), or "No new people were added". The file appears in each selected user's **Shared** tab, and Storage sends an in-app notification when notification delivery succeeds.

> A client sees a file shared with them on the group's client portal, under **Shared with you**, and is notified.
> Only the file **owner** can share a file. The picker shows eligible group members, excludes you and users already on the file, and the server checks that each recipient has Storage access.
> If a notification cannot be delivered, the file remains shared; ask the recipient to refresh their **Shared** tab.

---

## Files from clients

When your group's client portal includes Storage, clients can send files to the group from the portal. Every Storage member of the group can see and download them on the **From clients** tab, which shows who sent each file. Client uploads are private: they never appear on the Public tab.

---

## Using Storage as a client

If you are a client of a group whose portal includes Storage, Storage opens as a **Files** page for that group:

- **Shared with you:** files the group shared with you
- **Sent by you:** files you sent the group

Tap a file (or its download button) to download it. Tap **Upload** to send a file to the group. Clients can send photos, PDFs, text files and Office documents up to 25 MB each; anything else is refused with a message before it uploads. The portal home shows a **New files** card counting the files shared with you in the last two weeks.

---

## Downloading a file

- On wider screens, tap the **Download** button on the file row, **or**
- Choose **Download** from the row's **More actions** menu (⋮), **or**
- Tap the file row to open its details, then tap **Download**.

---

## Viewing file details

Tap any file row (or choose **File details** from its menu) to open the file's details:

- Display name (or original filename when no custom name was set) as the title, with a **Public** / **Private** pill
- **Type** (from the file extension) and **Size** (human-readable)
- **Uploaded by** (username taken from the email on My Files and Shared; not shown for Public-tab files, because published copies do not expose the uploader's identity)
- **Uploaded** date and time
- **Original name**, when it differs from the display name
- Public files: "Anyone signed in to Bluejay can open this file's link." with a **Copy link** button (the URL is resolved from the published copy, not stored in the `files` record)
- Private files: "Private files must be downloaded from inside Bluejay." Downloads are authorized by the server.
- **Close** and **Download** buttons

---

## Deleting a file

1. In **My Files**, open the file’s **More actions** menu (⋮) and choose **Delete**.
2. The confirmation lists what you'll lose: the file is deleted for good; if you shared it, the people you shared it with lose access right away; and if it's public, its public link stops working and it leaves the Public tab. Tap **Delete file** to confirm.
3. The file is removed from Firestore and its Storage objects are deleted. If it was published, the server also removes the published copy. "File deleted" appears and the list refreshes automatically.

> Only the file owner sees **Delete**. Deletion is permanent; there is no recycle bin.

---

## Refreshing the list

The file lists load once when you open each tab. To pick up new uploads from teammates, tap the **Refresh** button (↺) in the top-right corner, or pull down on any tab.

---

## Common issues

| Symptom | Likely cause | Fix |
|---------|--------------|-----|
| A tab shows "Couldn't load files" | A missing Firestore index, a permission problem, or a network issue | Tap **Try again**. If it keeps failing, ask an admin to check the composite indexes (see Developer Guide) |
| Upload button shows "Uploading N%" and doesn't respond | An upload is already in progress | Wait for the current upload to finish |
| **Upload** is disabled in the upload dialog | No visibility picked yet, or the file name is blank | Pick **Public** or **Private** and enter a name |
| Shared tab is empty | No one has shared files with you yet, or the list needs a refresh | Tap ↺ to refresh |
| File not visible after upload | You're on the wrong tab (e.g. private file won't appear in Public) | Check **My Files** tab |
| Public files fail to load while signed out | The tab has no explicit sign-in prompt, but published file reads require authentication | Sign in and confirm that the group whose files you want to browse is active |
| Delete fails | Storage permission error or network issue | Check your connection; ensure you own the file |
| "Failed to download file: …" message on download | The published copy or file metadata is unavailable, or there is a network issue | Retry; if the problem persists, ask the file owner to re-publish or re-upload the file |
| No **Copy link** option for a file | Copy link is offered only for public files | Download the private file from inside Bluejay; its download request is authenticated and checked against your access |
| **Not enough storage** when picking a file | The group is on the free tier and the file would take it past the free amount | Delete files, or ask a group admin to turn on pay as you go |
| "Add a default card in Wallet before turning on pay as you go." | The admin has no default card in Wallet | Add one in Wallet, then try again |
| Can't switch back to the free tier | The group stores more than the free amount | Delete files until the group is under it |
| A client gets "Send a photo, PDF, text or Office document." or "Files can be up to 25 MB." | Client uploads accept only those types, up to 25 MB | Send a supported file, or split or compress it |
| "Failed to copy link: …" on a public file | The published copy isn't ready yet ("This file isn't published yet") or a network issue | Wait a moment and try again |

---

## Best practices

- Use descriptive display names — the original filename is often a UUID or device default.
- Mark files **Private** by default; switch to Public to publish a copy that signed-in users outside the group can read.
- Tap ↺ or pull down after a teammate uploads a file to see it immediately.
- Treat a copied public Firebase URL as sensitive; private files do not have a copyable link in the app.
