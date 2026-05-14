## 2026-05-14 - Tap Ripples for Utility AppBar Widgets
**Learning:** Custom utility widgets in the AppBar (like battery indicators) that use GestureDetector directly lack visual tap feedback, even inside Tooltips.
**Action:** When adding interactivity to these items, wrap the action area in Material(color: Colors.transparent, clipBehavior: Clip.antiAlias) and use InkWell to provide native material visual touch responses while preserving background styling.
