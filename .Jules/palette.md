## 2024-05-30 - Filter Bubble InkWell Refactor
**Learning:** Custom UI elements like filter bubbles frequently use `GestureDetector` lacking visual feedback and semantics. Replacing them with an `InkWell` wrapped in a `Material` and `Semantics(button: true)` improves accessibility.
**Action:** When adding tap ripples over styled containers, use a `Material` widget to preserve borders and `clipBehavior: Clip.antiAlias` to correctly constrain the ripple.
