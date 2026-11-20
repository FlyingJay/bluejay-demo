# Notes — Performance Improvements

## 1. Add indexed ordering and pagination when membership queries are redesigned

**Current cost:** Notes sorts results client-side after every snapshot merge. That is acceptable for small lists, but it shifts ordering work to every client and makes pagination/incremental loading harder later.

**Why it matters:** If Notes evolves into a larger dataset per user, client-only sorting will become a limiting factor for responsiveness and read efficiency.

**Proposed improvement:** When redesigning the membership query shape, ensure it supports an indexed `orderBy('lastEdited', descending: true)` path and cursor-based pagination. Keep the required `groupId` and membership fields in the composite index, and preserve ordering across owned and shared notes.
