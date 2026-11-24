import 'dart:async';

import 'package:flutter/material.dart';

import '../services/system_bars.dart';

OverlayEntry? _activeAppToast;
Timer? _activeAppToastTimer;

/// 메인 화면에서는 하단 내비게이션 막대 뒤에서 전체 막대가 위로 스르륵 올라왔다가 다시 아래로 스르륵 사라지고,
/// 파일 열람 중([fromTop]: true)에는 상단바 아래 가운데에 글자 크기에 맞게 나타났다가 위로 스르륵 사라지는 알림.
void showAppToast(
  BuildContext context,
  String message, {
  bool fromTop = false,
  bool aboveBottomBar = false,
  Duration duration = const Duration(milliseconds: 2200),
  Widget? content,
  String? actionLabel,
  VoidCallback? onAction,
}) {
  final overlay = Overlay.maybeOf(context, rootOverlay: true);
  if (overlay == null) return;

  _activeAppToastTimer?.cancel();
  _activeAppToastTimer = null;
  _activeAppToast?.remove();
  _activeAppToast = null;

  final GlobalKey<_AppToastOverlayState> key = GlobalKey<_AppToastOverlayState>();
  final double topOffset = fromTop ? (SystemBars.stableTop(context) + 56.0) : 0.0;
  final double sysBottom = MediaQuery.viewPaddingOf(context).bottom;
  final double navBarHeight = aboveBottomBar ? (66.0 + (sysBottom > 32 ? sysBottom : 0.0)) : MediaQuery.paddingOf(context).bottom;
  final double bottomOffset = fromTop ? 0.0 : navBarHeight;

  late OverlayEntry entry;
  entry = OverlayEntry(
    builder: (ctx) => _AppToastOverlay(
      key: key,
      message: message,
      content: content,
      fromTop: fromTop,
      topOffset: topOffset,
      bottomOffset: bottomOffset,
      actionLabel: actionLabel,
      onAction: onAction,
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
    this.actionLabel,
    this.onAction,
    required this.onDismissed,
  });

  final String message;
  final Widget? content;
  final bool fromTop;
  final double topOffset;
  final double bottomOffset;
  final String? actionLabel;
  final VoidCallback? onAction;
  final VoidCallback onDismissed;

  @override
  State<_AppToastOverlay> createState() => _AppToastOverlayState();
}

class _AppToastOverlayState extends State<_AppToastOverlay> with SingleTickerProviderStateMixin {
  late final AnimationController _ctrl = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 380),
    reverseDuration: const Duration(milliseconds: 360),
  );
  late final Animation<Offset> _slide = Tween<Offset>(
    begin: widget.fromTop ? const Offset(0, -1.25) : const Offset(0, 1.15),
    end: Offset.zero,
  ).animate(CurvedAnimation(parent: _ctrl, curve: Curves.easeOutQuart, reverseCurve: Curves.easeInOutCubic));
  late final Animation<double> _fade = Tween<double>(begin: 0.35, end: 1.0).animate(
    CurvedAnimation(parent: _ctrl, curve: Curves.easeOut, reverseCurve: Curves.easeIn),
  );

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
    final bool hasAction = widget.actionLabel != null && widget.onAction != null;
    final Widget body = widget.content ??
        Text(
          widget.message,
          textAlign: widget.fromTop ? TextAlign.center : TextAlign.start,
        );
    final Widget pill = Material(
      color: dark ? const Color(0xF22B2F2D) : const Color(0xF22D2824),
      elevation: 6,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(widget.fromTop ? 20 : 18),
        side: BorderSide(color: dark ? Colors.white.withValues(alpha: 0.14) : Colors.transparent),
      ),
      child: Padding(
        padding: widget.fromTop
            ? const EdgeInsets.symmetric(horizontal: 20, vertical: 10)
            : EdgeInsets.fromLTRB(18, hasAction ? 6 : 14, hasAction ? 8 : 18, hasAction ? 6 : 14),
        child: DefaultTextStyle(
          style: const TextStyle(color: Colors.white, fontSize: 13.5, fontWeight: FontWeight.w600, height: 1.3),
          child: hasAction
              ? Row(
                  children: [
                    Expanded(child: body),
                    TextButton(
                      onPressed: () {
                        widget.onAction?.call();
                        dismiss();
                      },
                      style: TextButton.styleFrom(
                        foregroundColor: Colors.white,
                        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                        minimumSize: Size.zero,
                        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                      ),
                      child: Text(widget.actionLabel!, style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 13.5)),
                    ),
                  ],
                )
              : body,
        ),
      ),
    );

    if (widget.fromTop) {
      return Positioned(
        left: 16,
        right: 16,
        top: widget.topOffset,
        child: IgnorePointer(
          ignoring: !hasAction,
          child: ClipRect(
            child: Padding(
              padding: const EdgeInsets.only(bottom: 10),
              child: SlideTransition(
                position: _slide,
                child: Center(child: pill),
              ),
            ),
          ),
        ),
      );
    }

    // 하단 안내창: 하단 내비게이션 막대 바로 위 경계에서 ClipRect로 잘라
    // 막대 전체가 아래에서 위로 올라왔다가 다시 아래로 스르륵 들어가게 표현
    return Positioned(
      left: 12,
      right: 12,
      bottom: widget.bottomOffset,
      child: IgnorePointer(
        ignoring: !hasAction,
        child: ClipRect(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(4, 12, 4, 10),
            child: SlideTransition(
              position: _slide,
              child: FadeTransition(opacity: _fade, child: pill),
            ),
          ),
        ),
      ),
    );
  }
}
