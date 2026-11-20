# Development — Performance Improvements

## 1. Copy only what changed when reseeding

**Problem:** Reseeding a group copies all of its group-scoped collections, which grows with the group's data.

**Proposal:** Track the last seed time per group and copy only documents updated since then, deleting documents removed in production.
