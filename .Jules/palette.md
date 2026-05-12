## 2024-05-12 - Custom Filter Bubbles lack feedback and semantics
**Learning:** Custom UI components like filter bubbles implemented with `GestureDetector` lack visual touch feedback (ripples) and semantic button roles for screen readers, making them feel unresponsive and inaccessible.
**Action:** Replace `GestureDetector` with an `InkWell` inside a transparent `Material` widget, and wrap it in `Semantics(button: true, label: ...)` to restore native material interactions and accessibility.
