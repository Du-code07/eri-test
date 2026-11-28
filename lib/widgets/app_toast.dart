import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';

import '../services/system_bars.dart';
import 'app_colors.dart';

OverlayEntry? _activeAppToast;

/// 알림(토스트)이 화면에 떠 있는지 — 쪽 화면을 그림으로 저장할 때 알림까지 찍히지 않게 씀
bool get appToastVisible => _activeAppToast != null;
Timer? _activeAppToastTimer;

/// 현재 떠 있는 상단 안내창을 즉시 닫음
void dismissAppToast() {
  _activeAppToastTimer?.cancel();
  _activeAppToastTimer = null;
  if (_activeAppToast?.mounted == true) {
    _activeAppToast!.remove();
  }
  _activeAppToast = null;
}

/// 모든 화면(메인·하위창·뷰어)에서 상단에 단 1개만 표시되는 통일 안내창.
/// 4.5초간 표시되며, 화면 어디든 터치하면 터치 동작을 방해하지 않고 바로 사라짐.
void showAppToast(
  BuildContext context,
  String message, {
  bool fromTop = true,
  bool aboveBottomBar = false,
  Duration duration = const Duration(milliseconds: 4500),
  Widget? content,
  String? actionLabel,
  VoidCallback? onAction,
}) {
  final overlay = Overlay.maybeOf(context, rootOverlay: true);
  if (overlay == null) return;

  dismissAppToast();

  final GlobalKey<_AppToastOverlayState> key = GlobalKey<_AppToastOverlayState>();
  final double topInset = math.max(MediaQuery.paddingOf(context).top, SystemBars.stableTop(context));
  final double topOffset = topInset + 56.0;

  late OverlayEntry entry;
  entry = OverlayEntry(
    builder: (ctx) => _AppToastOverlay(
      key: key,
      message: message,
      content: content,
      topOffset: topOffset,
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
  _activeAppToastTimer = Timer(const Duration(milliseconds: 4500), () {
    _activeAppToastTimer = null;
    key.currentState?.dismiss();
  });
}

class _AppToastOverlay extends StatefulWidget {
  const _AppToastOverlay({
    super.key,
    required this.message,
    this.content,
    required this.topOffset,
    required this.onDismissed,
  });

  final String message;
  final Widget? content;
  final double topOffset;
  final VoidCallback onDismissed;

  @override
  State<_AppToastOverlay> createState() => _AppToastOverlayState();
}

class _AppToastOverlayState extends State<_AppToastOverlay> with SingleTickerProviderStateMixin {
  late final AnimationController _ctrl = AnimationController(
    vsync: this,
    duration: Anim.off.value ? Duration.zero : const Duration(milliseconds: 300),
    reverseDuration: Anim.off.value ? Duration.zero : const Duration(milliseconds: 260),
  );
  late final Animation<Offset> _slide = Tween<Offset>(
    begin: const Offset(0, -1.25),
    end: Offset.zero,
  ).animate(CurvedAnimation(parent: _ctrl, curve: Curves.easeOutQuart, reverseCurve: Curves.easeInOutCubic));
  late final Animation<double> _fade = Tween<double>(begin: 0.25, end: 1.0).animate(
    CurvedAnimation(parent: _ctrl, curve: Curves.easeOut, reverseCurve: Curves.easeIn),
  );

  bool _dismissing = false;
  late final DateTime _shownAt = DateTime.now();

  void _onGlobalPointer(PointerEvent event) {
    if (_dismissing || event is! PointerDownEvent) return;
    // 알림을 띄운 직후 같은 터치 이벤트에 바로 닫히지 않도록 짧은 유예(120ms)
    if (DateTime.now().difference(_shownAt).inMilliseconds < 120) return;
    _activeAppToastTimer?.cancel();
    _activeAppToastTimer = null;
    dismiss();
  }

  @override
  void initState() {
    super.initState();
    _ctrl.forward();
    GestureBinding.instance.pointerRouter.addGlobalRoute(_onGlobalPointer);
  }

  Future<void> dismiss() async {
    if (_dismissing || !mounted) return;
    _dismissing = true;
    GestureBinding.instance.pointerRouter.removeGlobalRoute(_onGlobalPointer);
    try {
      await _ctrl.reverse();
    } catch (_) {}
    if (mounted) widget.onDismissed();
  }

  @override
  void dispose() {
    GestureBinding.instance.pointerRouter.removeGlobalRoute(_onGlobalPointer);
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final bool dark = Theme.of(context).brightness == Brightness.dark;
    final Widget body = widget.content ??
        Text(
          widget.message,
          textAlign: TextAlign.center,
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
        );
    final Widget pill = Material(
      color: dark ? const Color(0xF22B2F2D) : const Color(0xF22D2824),
      elevation: 6,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(20),
        side: BorderSide(color: dark ? Colors.white.withValues(alpha: 0.14) : Colors.transparent),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 10),
        child: DefaultTextStyle(
          style: const TextStyle(color: Colors.white, fontSize: 13.5, fontWeight: FontWeight.w600, height: 1.3),
          child: body,
        ),
      ),
    );

    return Positioned(
      left: 16,
      right: 16,
      top: widget.topOffset,
      child: IgnorePointer(
        child: ClipRect(
          child: Padding(
            padding: const EdgeInsets.only(bottom: 10),
            child: SlideTransition(
              position: _slide,
              child: FadeTransition(opacity: _fade, child: Center(child: pill)),
            ),
          ),
        ),
      ),
    );
  }
}
