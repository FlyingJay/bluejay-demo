# Notes — Feature Improvements

## 1. Add read-only sharing roles

**Current limitation:** Recipients of a shared note currently receive edit access, not just visibility.

**Why it matters:** Many note-sharing scenarios are informational rather than collaborative. Users often want to publish a note without allowing every recipient to rewrite or delete it.

**Proposed improvement:** Add a share mode model such as `viewerIds` and `editorIds`, then disable editing actions for view-only recipients.

## 2. Add pinning, archiving, and lightweight categorization

**Current limitation:** All notes appear in one flat, most-recently-edited list.

**Why it matters:** As note volume grows, users need a way to separate active notes from long-lived references and to keep high-value notes easy to reach.

**Proposed improvement:** Add fields such as `isPinned`, `isArchived`, and optional `tags`, then expose list filters for those states.

## 3. Support richer content such as Markdown or checklists

**Current limitation:** Notes is plain text only.

**Why it matters:** Users often want at least minimal structure like headings, bullets with completion state, or rendered checklists without graduating to a heavier document workflow.

**Proposed improvement:** Add a lightweight rich-text or Markdown subset, or introduce checklist blocks while keeping the current quick-capture feel.

## 4. Add note templates for recurring workflows

**Current limitation:** Repeated note types such as meeting agendas, handoff checklists, and call notes must be rewritten from scratch each time.

**Why it matters:** Templates would increase adoption for operational team workflows and make Notes more useful than a generic scratch pad.

**Proposed improvement:** Let users create reusable starter templates and prefill new notes from a template picker.
