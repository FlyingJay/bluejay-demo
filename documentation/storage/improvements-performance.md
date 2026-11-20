# Storage — Performance Improvements

## 1. Enforce upload size limits before transfer

**Risk:** Any file size is accepted. Very large uploads can stall web tabs, consume memory, and dramatically increase Storage egress/retention costs.

**Impact:** Slow UX, higher failure rates on weak networks, and unpredictable billing spikes.

**Proposal:** Add configurable max-size validation (`file.size`) before upload starts, with app-level config so limits can differ by environment.

## 2. Replace full-collection fallback summations with paged aggregation jobs

**Risk:** When usage rollup docs are missing, `_loadUsageFromFiles()` scans all file docs in the scoped collection.

**Impact:** Large groups will pay higher read costs and may see slow storage-usage dialogs.

**Proposal:** Add an on-demand backfill job (or scheduled function) that precomputes missing `storage_usage` docs, minimizing expensive full-collection fallback reads.

## 3. Add bounded query pagination for large tabs

**Risk:** Public/My Files/Shared tabs currently fetch full result sets with `.get()`.

**Impact:** Initial load time and memory use grow linearly with file count.

**Proposal:** Add paging (`limit`, cursor-based `startAfterDocument`) plus infinite scroll to keep first paint fast for large groups.
