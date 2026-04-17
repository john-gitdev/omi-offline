## 2026-04-17 - Added tooltips to icon-only buttons
**Learning:** In Flutter, adding `tooltip` properties to `IconButton` widgets automatically populates the `Semantics` label used by screen readers, making it a critical and easy win for accessibility.
**Action:** Always verify if newly created or existing `IconButton` widgets have `tooltip` properties set, especially those used for core actions (like Upload, Refresh, visibility toggle, back navigation).
