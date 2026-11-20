# Development — UX Improvements

## 1. Say when the preview's data was copied

**Problem:** The sandbox copy can be refreshed or reset, and a requester who comes back to a preview can find their earlier test changes gone with no explanation.

**Proposal:** Show the time the group's copy was made next to **Try it**, and in the preview itself.

## 2. Warn when a preview depends on server changes

**Problem:** When the PR changes Cloud Functions or rules, the preview can't show that part, and the requester may ask for a tweak to something that already works.

**Proposal:** Flag such PRs in `dev_changes.preview` and show a short note on the Ready to try panel.
