import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';

import 'app_colors.dart';

/// 앱 설정에서 전체 화면(가이드·약관·탐색할 폴더 등)을 열 때:
/// 새 화면이 오른쪽에서 들어오면서 그 전 화면(설정 창과 그 뒤 서재)을 왼쪽으로 밀어냄
class PushAside {
  /// 0 = 제자리, 1 = 왼쪽으로 화면 너비만큼 밀려남 (밀려나는 쪽 화면들이 [PushAsideShift]로 따라 움직임)
  static final ValueNotifier<double> shift = ValueNotifier(0);
}

/// 밀려나는 쪽 화면: [PushAside.shift]만큼 왼쪽으로 옮겨 그림
class PushAsideShift extends StatelessWidget {
  const PushAsideShift({super.key, required this.child});
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<double>(
      valueListenable: PushAside.shift,
      // 밀리는 동안 화면을 매 장면 다시 그리지 않고 그려 둔 것을 옮기기만 (돌아올 때 덜 버벅임)
      child: RepaintBoundary(child: child),
      builder: (context, t, child) {
        // 밀려나지 않을 때도 같은 모양으로 감싸 둠: 감싸는 위젯이 바뀌면 그 안 화면이 새로 만들어져
        // 설정 창의 스크롤 위치 같은 상태가 사라짐
        final double w = MediaQuery.sizeOf(context).width;
        return Transform.translate(offset: Offset(-w * t.clamp(0.0, 1.0), 0), child: child);
      },
    );
  }
}

/// 밀어내며 들어오는 화면
class PushAsideRoute<T> extends PageRoute<T> {
  PushAsideRoute({required this.builder, this.swipeBack = true, this.fromLeft = false, super.settings});

  final WidgetBuilder builder;

  /// 화면을 오른쪽으로 밀어서 닫기 (설정처럼 화면을 꽉 채운 창). 파일 화면은 끔 (쪽 넘기기와 겹치지 않게)
  final bool swipeBack;

  /// true면 왼쪽에서 들어오며 이전 화면을 오른쪽으로 밀어냄 (이전 파일 이동용)
  final bool fromLeft;

  // ── 오른쪽으로 밀어서 닫기 ──
  bool _swiping = false;

  void _swipeStart() {
    if (!isCurrent || navigator == null || navigator!.userGestureInProgress) return;
    _swiping = true;
    navigator!.didStartUserGesture();
  }

  void _swipeUpdate(double fraction) {
    if (!_swiping) return;
    final AnimationController? c = controller;
    if (c == null) return;
    c.value = (c.value - fraction).clamp(0.0, 1.0);
  }

  void _swipeEnd(double velocity) {
    if (!_swiping) return;
    _swiping = false;
    final AnimationController? c = controller;
    final NavigatorState? nav = navigator;
    if (c == null || nav == null) return;
    // 빠르게 밀었으면 민 방향대로, 아니면 반 넘게 밀었는지로 닫기·제자리 정함
    final bool close = velocity.abs() >= 600 ? velocity > 0 : c.value < 0.5;
    // 손을 뗀 자리에서 남은 거리만큼만, 처음엔 빠르게 끝엔 천천히 (손가락 속도를 이어받는 느낌)
    if (close) {
      nav.pop();
      if (c.isAnimating) {
        c.animateBack(0.0, duration: Duration(milliseconds: (320 * c.value).clamp(90, 320).round()), curve: Curves.fastLinearToSlowEaseIn);
      }
    } else {
      c.animateTo(1.0, duration: Duration(milliseconds: (320 * (1 - c.value)).clamp(90, 320).round()), curve: Curves.fastLinearToSlowEaseIn);
    }
    // 움직임이 끝날 때까지는 손으로 끄는 중으로 둠 (그동안 곡선 없이 그대로 따라감 → 손을 떼는 순간 튀지 않음)
    if (c.isAnimating) {
      late final AnimationStatusListener done;
      done = (status) {
        if (status == AnimationStatus.completed || status == AnimationStatus.dismissed) {
          c.removeStatusListener(done);
          nav.didStopUserGesture();
        }
      };
      c.addStatusListener(done);
    } else {
      nav.didStopUserGesture();
    }
  }

  /// 손으로 끄는 중(놓은 뒤 움직임 포함)에는 곡선 없이 손가락 위치 그대로
  bool get _linear => navigator?.userGestureInProgress ?? false;

  /// 바로 아래가 같은 방식의 화면이 아니면(설정 창 위에서 처음 연 화면) 아래 화면 전체를 함께 밀어냄
  bool _drivesShift = false;
  /// 다음 화면이 왼쪽에서 들어오면 현재 화면은 오른쪽으로 밀려남
  bool _exitToRight = false;
  /// 다른 PushAsideRoute로 교체(pushReplacement)되는 중이면 dispose 때 서재 shift를 초기화하지 않음
  bool _replacedByPushAside = false;
  CurvedAnimation? _curve;

  static const Curve _in = Curves.easeOutCubic;
  static const Curve _out = Curves.easeInCubic;

  @override
  Duration get transitionDuration => Anim.off.value ? Duration.zero : const Duration(milliseconds: 320);

  @override
  Duration get reverseTransitionDuration => Anim.off.value ? Duration.zero : const Duration(milliseconds: 280);

  @override
  bool get opaque => true;

  @override
  bool get maintainState => true;

  @override
  Color? get barrierColor => null;

  @override
  String? get barrierLabel => null;

  @override
  void install() {
    super.install();
    _curve = CurvedAnimation(parent: animation!, curve: _in, reverseCurve: _out);
    _curve!.addListener(_sync);
  }

  @override
  void didChangePrevious(Route<dynamic>? previousRoute) {
    super.didChangePrevious(previousRoute);
    final bool wasDriver = _drivesShift;
    _drivesShift = previousRoute is! PushAsideRoute;
    if (!wasDriver && _drivesShift && animation != null) {
      PushAside.shift.value = _linear ? animation!.value : _curve!.value;
    }
  }

  @override
  void didChangeNext(Route<dynamic>? nextRoute) {
    super.didChangeNext(nextRoute);
    if (nextRoute is PushAsideRoute) {
      _exitToRight = nextRoute.fromLeft;
      _replacedByPushAside = true;
    } else if (nextRoute == null) {
      _exitToRight = false;
    }
  }

  void _sync() {
    if (_drivesShift) PushAside.shift.value = _linear ? animation!.value : _curve!.value;
  }

  /// 닫을 때: 바로 움직이지 않고 한 장면 동안 제자리에서 기다림.
  /// 그동안 가려져 있던 아래 화면(서재)을 이 화면 뒤에서 미리 배치·그려 둠 → 움직이기 시작한 뒤 첫 장면이 건너뛰지 않음
  bool _holding = false;

  @override
  bool didPop(T? result) {
    final bool done = super.didPop(result); // 여기서 닫히는 움직임이 시작되고 아래 화면이 보이게 됨
    final AnimationController? c = controller;
    if (c != null && !Anim.off.value && c.value >= 1.0 && !_linear) {
      c.stop(canceled: false);
      _holding = true;
      // 아래 화면을 배치·그리는 장면이 끝난 다음 장면부터 움직임
      SchedulerBinding.instance.addPostFrameCallback((_) {
        SchedulerBinding.instance.addPostFrameCallback((_) {
          if (!_holding) return;
          _holding = false;
          c.reverse();
        });
        SchedulerBinding.instance.scheduleFrame();
      });
      SchedulerBinding.instance.scheduleFrame();
    }
    return done;
  }

  @override
  void dispose() {
    _holding = false;
    if (_drivesShift && !_replacedByPushAside) PushAside.shift.value = 0;
    _curve?.removeListener(_sync);
    _curve?.dispose();
    super.dispose();
  }

  @override
  Widget buildPage(BuildContext context, Animation<double> animation, Animation<double> secondaryAnimation) =>
      swipeBack ? _SwipeBack(route: this, child: builder(context)) : builder(context);

  @override
  Widget buildTransitions(BuildContext context, Animation<double> animation, Animation<double> secondaryAnimation, Widget child) {
    // 들어올 때: 다음 파일·일반은 오른쪽 → 제자리, 이전 파일(fromLeft)은 왼쪽 → 제자리
    // 뒤로 가기(reverse)로 서재로 돌아갈 때는 항상 오른쪽으로 빠져나감
    // 위에 같은 방식의 화면이 열리면: 다음 화면 방향에 맞춰 왼쪽 또는 오른쪽으로 밀려남
    final bool linear = _linear;
    final bool popping = animation.status == AnimationStatus.reverse;
    final Offset enterBegin = (fromLeft && !popping) ? const Offset(-1, 0) : const Offset(1, 0);
    final Offset exitEnd = _exitToRight ? const Offset(1, 0) : const Offset(-1, 0);
    return SlideTransition(
      position: Tween<Offset>(begin: enterBegin, end: Offset.zero)
          .animate(linear ? animation : CurvedAnimation(parent: animation, curve: _in, reverseCurve: _out)),
      child: SlideTransition(
        position: Tween<Offset>(begin: Offset.zero, end: exitEnd)
            .animate(linear ? secondaryAnimation : CurvedAnimation(parent: secondaryAnimation, curve: _in, reverseCurve: _out)),
        // 움직이는 동안 파일 화면을 다시 그리지 않고 옮기기만
        child: RepaintBoundary(child: child),
      ),
    );
  }

  @override
  bool canTransitionTo(TransitionRoute<dynamic> nextRoute) => nextRoute is PushAsideRoute;

  /// 아래 화면이 자기 방식의 퇴장 효과(어두워지기 등)를 따로 쓰지 않게: 밀려나는 건 [PushAsideShift]가 맡음
  @override
  bool canTransitionFrom(TransitionRoute<dynamic> previousRoute) => previousRoute is PushAsideRoute;
}

/// 화면 어디서든 오른쪽으로 밀면 따라 움직이다가 놓으면 닫히거나 제자리로
/// (안쪽에서 가로로 끄는 것 — 밀대·가로 목록 — 이 먼저 잡으면 그쪽이 우선)
class _SwipeBack extends StatelessWidget {
  const _SwipeBack({required this.route, required this.child});
  final PushAsideRoute<dynamic> route;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return RawGestureDetector(
      behavior: HitTestBehavior.translucent,
      gestures: {
        HorizontalDragGestureRecognizer: GestureRecognizerFactoryWithHandlers<HorizontalDragGestureRecognizer>(
          () => HorizontalDragGestureRecognizer(debugOwner: this),
          (r) {
            r.onStart = (_) {
              route._swipeStart();
            };
            r.onUpdate = (d) {
              final double w = MediaQuery.sizeOf(context).width;
              if (w > 0) route._swipeUpdate((d.primaryDelta ?? 0) / w);
            };
            r.onEnd = (d) {
              route._swipeEnd(d.primaryVelocity ?? 0);
            };
            r.onCancel = () {
              route._swipeEnd(0);
            };
          },
        ),
      },
      child: child,
    );
  }
}
