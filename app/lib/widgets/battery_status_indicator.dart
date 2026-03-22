import 'package:flutter/material.dart';

/// Small battery status dot + percentage shown in the AppBar when Omi is connected.
///
/// Dot color:
///   - Blinking green (1 s cycle, matching firmware LED) when charging
///   - Solid green when not charging and level > 80 %
///   - Solid yellow when not charging and 20 % ≤ level ≤ 80 %
///   - Solid red when not charging and level < 20 %
class BatteryStatusIndicator extends StatefulWidget {
  final int batteryLevel;
  final bool isCharging;
  final VoidCallback? onTap;

  const BatteryStatusIndicator({
    super.key,
    required this.batteryLevel,
    required this.isCharging,
    this.onTap,
  });

  @override
  State<BatteryStatusIndicator> createState() => _BatteryStatusIndicatorState();
}

class _BatteryStatusIndicatorState extends State<BatteryStatusIndicator> with SingleTickerProviderStateMixin {
  late final AnimationController _blinkController;

  @override
  void initState() {
    super.initState();
    // 1 000 ms matches firmware k_msleep(500) toggle → 500 ms on / 500 ms off
    _blinkController = AnimationController(vsync: this, duration: const Duration(milliseconds: 1000));
    if (widget.isCharging) _blinkController.repeat();
  }

  @override
  void didUpdateWidget(BatteryStatusIndicator oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.isCharging != oldWidget.isCharging) {
      if (widget.isCharging) {
        _blinkController.repeat();
      } else {
        _blinkController.stop();
        _blinkController.value = 0;
      }
    }
  }

  @override
  void dispose() {
    _blinkController.dispose();
    super.dispose();
  }

  Color get _dotColor {
    if (widget.batteryLevel < 0) return Colors.grey;
    if (widget.isCharging) return Colors.green;
    if (widget.batteryLevel > 80) return Colors.green;
    if (widget.batteryLevel >= 20) return const Color(0xFFFFCC00);
    return Colors.red;
  }

  Widget _dot() => Container(
        width: 8,
        height: 8,
        decoration: BoxDecoration(color: _dotColor, shape: BoxShape.circle),
      );

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: widget.onTap,
      child: Padding(
        // Vertical padding to match IconButton's 48-px minimum tap target.
        padding: const EdgeInsets.symmetric(horizontal: 8.0, vertical: 14.0),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (widget.isCharging)
              AnimatedBuilder(
                animation: _blinkController,
                builder: (context, child) => Opacity(
                  opacity: _blinkController.value < 0.5 ? 1.0 : 0.0,
                  child: child,
                ),
                child: _dot(),
              )
            else
              _dot(),
            const SizedBox(width: 4),
            Text(
              widget.batteryLevel >= 0 ? '${widget.batteryLevel}%' : '--',
              style: const TextStyle(color: Colors.white, fontSize: 11, fontWeight: FontWeight.w500),
            ),
          ],
        ),
      ),
    );
  }
}
