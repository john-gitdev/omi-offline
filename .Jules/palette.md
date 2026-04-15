## $(date +%Y-%m-%d) - Add Tooltips to Icon-Only Buttons
**Learning:** Many interactive icon-only elements (like the Bluetooth sync button, trash icons, and upload state buttons) lacked tooltip properties in Flutter, creating an accessibility gap for screen readers and missing context on hover.
**Action:** When adding or modifying `IconButton` widgets across the UI, I must ensure that `tooltip` is explicitly set to provide an ARIA-equivalent accessible label for icon-only interactions.
