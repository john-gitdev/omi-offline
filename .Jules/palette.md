## 2024-10-18 - Added tap ripple feedback to AppBar action utility widget
**Learning:** In Flutter, custom utility widgets in the AppBar (like battery indicators or connection statuses) that use `GestureDetector` directly inside a `Tooltip` lack tap ripples.
**Action:** Wrap the action area in `Material(color: Colors.transparent, clipBehavior: Clip.antiAlias)` and use `InkWell` instead of `GestureDetector` to provide native material visual touch responses while preserving the background styling.
