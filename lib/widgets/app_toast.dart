import 'dart:async';

import 'package:flutter/material.dart';

import '../services/system_bars.dart';

OverlayEntry? _activeAppToast;
Timer? _activeAppToastTimer;

/// 메인 화면에서는 하단에서 막대 전체가 위로 올라왔다가 아래로 스르륵 사라지고,
/// 파일 열람 중([fromTop]: true)에는 상단바 아래 가운데에 글자 크기에 맞게 나타났다가 위로 스르륵 사라지는 알림.
void showAppToast(
  BuildContext context,
  String message, {
  bool fromTop = false,
  Duration duration = const Duration(milliseconds: 1800),
  Widget? content,
}) {
  final overlay = Overlay.maybeOf(context, rootOverlay: true);
  if (overlay == null) return;

  _activeAppToastTimer?.cancel();
  _activeAppToastTimer = null;
  _activeAppToast?.remove();
  _activeAppToast = null;

  final GlobalKey<_AppToastOverlayState> key = GlobalKey<_AppToastOverlayState>();
  final double topOffset = fromTop ? (SystemBars.stableTop(context) + 56.0) : 0.0;
  final double bottomOffset = fromTop ? 0.0 : (MediaQuery.paddingOf(context).bottom + 18.0);

  late OverlayEntry entry;
  entry = OverlayEntry(
    builder: (ctx) => _AppToastOverlay(
      key: key,
      message: message,
      content: content,
      fromTop: fromTop,
      topOffset: topOffset,
      bottomOffset: bottomOffset,
      onDismissed: () {
        if (identical(_activeAppToast, entry)) {
          _activeAppToast = null;
        }
        if (entry.mounted) entry.remove();
      },
    ),
  );

  _activeAppToast = entry;
  overlay.insert(entry);
  _activeAppToastTimer = Timer(duration, () {
    _activeAppToastTimer = null;
    key.currentState?.dismiss();
  });
}

class _AppToastOverlay extends StatefulWidget {
  const _AppToastOverlay({
    super.key,
    required this.message,
    this.content,
    required this.fromTop,
    required this.topOffset,
    required this.bottomOffset,
    required this.onDismissed,
  });

  final String message;
  final Widget? content;
  final bool fromTop;
  final double topOffset;
  final double bottomOffset;
  final VoidCallback onDismissed;

  @override
  State<_AppToastOverlay> createState() => _AppToastOverlayState();
}

class _AppToastOverlayState extends State<_AppToastOverlay> with SingleTickerProviderStateMixin {
  late final AnimationController _ctrl = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 240),
    reverseDuration: const Duration(milliseconds: 260),
  );
  late final Animation<Offset> _slide = Tween<Offset>(
    begin: widget.fromTop ? const Offset(0, -1.8) : const Offset(0, 1.8),
    end: Offset.zero,
  ).animate(CurvedAnimation(parent: _ctrl, curve: Curves.easeOutCubic, reverseCurve: Curves.easeInCubic));

  bool _dismissing = false;

  @override
  void initState() {
    super.initState();
    _ctrl.forward();
  }

  Future<void> dismiss() async {
    if (_dismissing || !mounted) return;
    _dismissing = true;
    try {
      await _ctrl.reverse();
    } catch (_) {}
    if (mounted) widget.onDismissed();
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final bool dark = Theme.of(context).brightness == Brightness.dark;
    final Widget pill = Material(
      color: dark ? const Color(0xF02B2F2D) : const Color(0xF0242725),
      elevation: 8,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(widget.fromTop ? 20 : 18),
        side: BorderSide(color: dark ? Colors.white.withValues(alpha: 0.14) : Colors.transparent),
      ),
      child: Padding(
        padding: widget.fromTop
            ? const EdgeInsets.symmetric(horizontal: 20, vertical: 10)
            : const EdgeInsets.symmetric(horizontal: 18, vertical: 13),
        child: DefaultTextStyle(
          style: const TextStyle(color: Colors.white, fontSize: 13.5, fontWeight: FontWeight.w600, height: 1.3),
          child: widget.content ?? Text(widget.message, textAlign: widget.fromTop ? TextAlign.center : TextAlign.start),
        ),
      ),
    );

    return Positioned(
      left: 16,
      right: 16,
      top: widget.fromTop ? widget.topOffset : null,
      bottom: widget.fromTop ? null : widget.bottomOffset,
      child: IgnorePointer(
        ignoring: true,
        child: SlideTransition(
          position: _slide,
          child: widget.fromTop ? Center(child: pill) : pill,
        ),
      ),
    );
  }
}
