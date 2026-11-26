import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/widgets.dart';
import 'package:flutter/services.dart';

/// 서재(첫 화면)에서는 상태표시줄(과 버튼식 내비게이션 바)을 늘 보이고,
/// 파일을 열어 보는 동안에는 모두 숨긴다.
/// 전환 애니메이션 도중에 시스템 바를 바꾸면 화면이 깜빡이므로,
/// 열 때는 전환 직후에 숨기고 닫을 때는 화면이 정리된 뒤 복원한다.
class SystemBars {
  static const _channel = MethodChannel('ebook_reader/pdf_renderer');
  static int _viewers = 0;
  static bool _status = false;
  static bool _inViewerMode = false;
  static Timer? _enterTimer;

  static Future<void> _set(bool library) async {
    try {
      await _channel.invokeMethod('setLibraryBars', {'on': library});
    } catch (_) {}
  }

  /// 뷰어 화면이 열릴 때 (initState) — 슬라이드 전환(320ms)이 끝난 직후 바를 숨겨 깜빡임 방지
  static void enterViewer() {
    _viewers++;
    _status = false;
    if (_viewers == 1 && !_inViewerMode) {
      _enterTimer?.cancel();
      _enterTimer = Timer(const Duration(milliseconds: 340), () {
        if (_viewers > 0 && !_inViewerMode) {
          _inViewerMode = true;
          _set(false);
        }
      });
    }
  }

  static void leaveViewer() {
    if (_viewers > 0) _viewers--;
    if (_viewers == 0) {
      _enterTimer?.cancel();
      _enterTimer = null;
      _status = false;
      if (_inViewerMode) {
        _inViewerMode = false;
        _set(true);
      }
    }
  }

  /// 파일 열람 중 메뉴(위아래 막대)를 띄운 동안에는 상태표시줄도 보임. 같은 값이면 다시 보내지 않음
  static void viewerStatus(bool show) {
    if (_viewers == 0 || !_inViewerMode || show == _status) return;
    _status = show;
    () async {
      try {
        await _channel.invokeMethod('setViewerStatusBar', {'show': show});
      } catch (_) {}
    }();
  }

  /// 상태표시줄이 보일 때의 위쪽 여백 (가로·세로 따로). 서재에서 본 값을 기억해 둠
  static final Map<Orientation, double> _statusTop = {};

  /// 상태표시줄을 보였다 숨겼다 해도 바뀌지 않는 위쪽 여백.
  static double stableTop(BuildContext context) {
    final Orientation o = MediaQuery.orientationOf(context);
    final double cur = MediaQuery.paddingOf(context).top;
    final double v = math.max(_statusTop[o] ?? 0.0, cur);
    _statusTop[o] = v;
    return v;
  }
}
