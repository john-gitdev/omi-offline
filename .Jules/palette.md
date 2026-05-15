## 2026-05-15 - Accessible Interactive Filter Bubbles
**Learning:** Custom interactive elements (like custom toggle bubbles for filters) using `GestureDetector` wrapped in `Container` lack visual feedback on tap and miss semantic a11y roles.
**Action:** Replace them with an `InkWell` wrapped in a `Material` (with `clipBehavior: Clip.antiAlias` and appropriate `shape` such as `RoundedRectangleBorder`), and wrap the `Material` with `Semantics(button: true)` and `Tooltip` to improve accessibility and touch responses.
