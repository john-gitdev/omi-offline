## 2025-02-28 - Adding Tooltips to IconButtons

**Learning:** When adding or modifying `IconButton` widgets in the Flutter codebase, explicitly setting the `tooltip` property is critical. Custom or icon-only buttons lack them by default, reducing accessibility for screen reader users and missing visual cues on hover/long-press.
**Action:** When adding or modifying `IconButton` components, always verify and include a `tooltip` attribute. When analyzing existing `IconButton`s for missing tooltips, use multi-line search techniques (like `awk`) rather than simple `grep` because Flutter widget definitions often span multiple lines.
