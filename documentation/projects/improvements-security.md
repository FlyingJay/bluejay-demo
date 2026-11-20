# Projects — Security Improvements

- P1 | **Task-file uploads have client-only size and MIME checks** | The form skips files larger than 10 MB and derives `contentType` from the filename, but a modified client can bypass those checks. The group/app Storage policy enforces tenant access and object metadata, but Projects does not currently enforce its file-size limit or content-type allowlist in a trusted upload path. | Add server-side or Storage-rule validation for file size and accepted content types, and cover allowed and rejected uploads with Storage emulator tests.

- P2 | **Attachment MIME type is trusted from the task document** | `TaskAttachment.contentType` is saved in Firestore and helps decide whether an attachment is rendered as an image. The value comes from the client and is not checked against the uploaded object's metadata. | Resolve the object's trusted Storage metadata before treating it as an image, or persist server-verified metadata and ignore mismatches.

- P2 | **Uploaded attachment content is not scanned** | Group/app access controls limit who can upload or read task files, but uploaded files are not checked for malware before users open or download them. | Add a Cloud Storage scanning workflow for supported file types and make scan status explicit before exposing a file as ready to open.

- P2 | **A trusted Storage hostname does not prove that an attachment belongs to the task's group** | The renderer accepts HTTPS URLs from Firebase Storage hosts, but the host check alone does not verify that the URL or object path belongs to the current group's Projects folder. | Validate that uploaded object paths match the task's `groupId`, `appId: projects`, and `projects_hub_task_files` namespace before exposing the download URL.
