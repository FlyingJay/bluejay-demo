# Projects — Performance Improvements

- P1 | **Dashboard next-action lookup is an N+1 read pattern** | The dashboard streams projects, then performs an extra blocker query per visible project card to compute its next action. | Maintain a compact project summary or compute next-action data from a shared blocker stream so the dashboard avoids one query per card.

- P1 | **Deleting a project can exceed Firestore batch limits** | `_deleteProject` reads all blockers and deletes them with the project in one batch. Projects with more than the Firestore batch limit cannot be deleted successfully in this path. | Delete blockers in bounded batches or use a backend deletion job with progress and retry handling.

- P2 | **Detail-screen graph calculations repeatedly scan the task list** | Child lookup and descendant traversal scan the complete blocker list repeatedly as the tree is rendered or parent choices are prepared. Cost grows with both task count and tree depth. | Build a parent-to-children index once per snapshot and reuse it for child lookup, actionability, descendant traversal, and rendering.

- P2 | **Image attachments are loaded from the network on every task card render without a local cache** | `Image.network` in `_TaskImageCarousel` and `_TaskFullscreenImageViewer` makes fresh network requests each time a card is rendered or the fullscreen viewer is opened. On slow connections, multiple large task cards each with image carousels can saturate bandwidth. | Integrate a caching image package (e.g., `cached_network_image`) to serve images from the local disk cache after first load, reducing repeated network fetches.

- P2 | **Removed attachments leave orphaned Storage objects** | Editing a task replaces its Firestore attachment list but does not delete removed objects. Unreferenced files continue to consume Storage and may incur billing. | Add a safe cleanup process that verifies an object is no longer referenced before deleting it; account for shared or reused URLs and retries.
