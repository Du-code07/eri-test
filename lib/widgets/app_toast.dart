import 'dart:async';
import 'dart:math' as math;

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
/// 새 안내가 호출되면 이전 안내는 즉시 교체되어 겹치지 않음.
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
    this.actionLabel,
    this.onAction,
    required this.onDismissed,
  });

  final String message;
  final Widget? content;
  final double topOffset;
  final String? actionLabel;
  final VoidCallback? onAction;
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
        padding: hasAction
            ? const EdgeInsets.fromLTRB(18, 6, 8, 6)
            : const EdgeInsets.symmetric(horizontal: 20, vertical: 10),
        child: DefaultTextStyle(
          style: const TextStyle(color: Colors.white, fontSize: 13.5, fontWeight: FontWeight.w600, height: 1.3),
          child: hasAction
              ? Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Flexible(child: body),
                    const SizedBox(width: 6),
                    TextButton(
                      onPressed: () {
                        widget.onAction?.call();
                        dismiss();
                      },
                      style: TextButton.styleFrom(
                        foregroundColor: Colors.white,
                        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
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

    return Positioned(
      left: 16,
      right: 16,
      top: widget.topOffset,
      child: ClipRect(
        child: Padding(
          padding: const EdgeInsets.only(bottom: 10),
          child: SlideTransition(
            position: _slide,
            child: FadeTransition(
              opacity: _fade,
              child: Center(
                child: GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTap: dismiss,
                  child: pill,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
