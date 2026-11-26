import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'text_select.dart';

/// 그림(쪽 그림·TXT 종이) 위의 낱말 한 개: 글자와 자리(0~1, 이 층 크기 대비)
class SelectableWord {
  const SelectableWord(this.text, this.rect);
  final String text;
  final Rect rect;

  static SelectableWord? fromJson(Object? m) {
    if (m is! Map) return null;
    double v(Object? x) => (x as num?)?.toDouble() ?? 0;
    final t = '${m['t'] ?? ''}';
    if (t.isEmpty) return null;
    return SelectableWord(t, Rect.fromLTWH(v(m['x']), v(m['y']), v(m['w']), v(m['h'])));
  }
}

/// 한글·워드 파일처럼 글을 길게 눌러 고르기:
/// 길게 누르면 그 낱말이 골라지며 양쪽 물방울 손잡이와 [복사 | 모두 선택 | 공유] 막대가 바로 표시됨.
/// 하이라이트가 있는 상태에서도 스크롤·줌이 자유롭게 되며, 화면이 움직이는 동안은 손잡이가 잠깐 숨겨졌다가 멈추면 다시 나타남.
class WordSelectionLayer extends StatefulWidget {
  const WordSelectionLayer({
    super.key,
    required this.loadWords,
    required this.tr,
    required this.child,
    this.highlight = '',
    this.onEdgeAutoScroll,
  });

  /// 파일 내 단어 찾기에서 찾은 낱말을 형광펜으로 (빈 글이면 없음)
  final String highlight;

  final Future<List<SelectableWord>> Function() loadWords;
  final String Function(String ko, String en, String zh, String ja) tr;
  final Widget child;

  /// 손잡이를 화면 위·아래 끝으로 끌 때 스크롤 모드를 부드럽게 이동
  final void Function(double dy)? onEdgeAutoScroll;

  /// 어느 쪽에서든 글이 골라져 있는가 (보는 화면이 탭으로 메뉴를 열지 않게)
  static final ValueNotifier<bool> active = ValueNotifier<bool>(false);

  /// 손잡이를 끄는 중인가 (스크롤·줌 잠금용)
  static final ValueNotifier<bool> dragging = ValueNotifier<bool>(false);

  /// 스크롤·줌으로 화면이 움직이는 중인가 (움직이는 동안 손잡이·막대 숨김)
  static final ValueNotifier<bool> scrolling = ValueNotifier<bool>(false);
  static Timer? _scrollIdleTimer;

  static void notifyScrolling() {
    if (!active.value || dragging.value) return;
    if (!scrolling.value) scrolling.value = true;
    _scrollIdleTimer?.cancel();
    _scrollIdleTimer = Timer(const Duration(milliseconds: 180), () {
      scrolling.value = false;
    });
  }

  static bool get locked => active.value || dragging.value;
  static final List<VoidCallback> _clearers = [];
  static BuildContext? _activeContext;

  /// 이 화면 자리가 글을 골라 둔 쪽 안인가 (밖을 누르면 고른 글을 지움)
  static bool containsGlobal(Offset global) {
    final box = _activeContext?.findRenderObject() as RenderBox?;
    if (box == null || !box.attached) return false;
    final local = box.globalToLocal(global);
    return (Offset.zero & box.size).inflate(44).contains(local);
  }

  /// 골라 둔 글을 모두 지움
  static void clearAll() {
    for (final c in List<VoidCallback>.of(_clearers)) {
      c();
    }
  }

  @override
  State<WordSelectionLayer> createState() => _WordSelectionLayerState();
}

class _WordSelectionLayerState extends State<WordSelectionLayer> {
  List<SelectableWord>? _words;
  int? _a, _b; // 고른 범위 (낱말 번호)
  bool _menu = false;
  Size _size = Size.zero;

  int? _dragPointer;
  bool _dragStart = false;
  Offset? _dragGlobal;
  Timer? _autoScrollTimer;

  @override
  void initState() {
    super.initState();
    WordSelectionLayer._clearers.add(_clear);
    WordSelectionLayer.scrolling.addListener(_onScrollState);
    _loadForHighlight();
  }

  void _onScrollState() {
    if (mounted && _a != null) setState(() {});
  }

  @override
  void didUpdateWidget(covariant WordSelectionLayer oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.highlight != widget.highlight) {
      _hlFor = null;
      _loadForHighlight();
    }
  }

  void _loadForHighlight() {
    if (widget.highlight.trim().isEmpty || _words != null) return;
    _ensureWords().then((_) {
      if (mounted) setState(() {});
    });
  }

  // 찾은 낱말 자리 (찾는 말이 바뀔 때만 다시 계산)
  String? _hlFor;
  List<Rect> _hlRects = const [];
  List<Rect> _highlightRects() {
    final q = widget.highlight.replaceAll(RegExp(r'\s+'), '').toLowerCase();
    final words = _words;
    if (q.isEmpty || words == null || words.isEmpty) return const [];
    if (_hlFor == q) return _hlRects;
    final owner = <int>[];
    final buf = StringBuffer();
    for (int i = 0; i < words.length; i++) {
      final t = words[i].text.replaceAll(RegExp(r'\s+'), '').toLowerCase();
      buf.write(t);
      for (int k = 0; k < t.length; k++) {
        owner.add(i);
      }
    }
    final all = buf.toString();
    final out = <Rect>[];
    for (int at = all.indexOf(q); at >= 0; at = all.indexOf(q, at + q.length)) {
      final a = owner[at], b = owner[at + q.length - 1];
      for (int i = a; i <= b; i++) {
        final w = words[i];
        final t = w.text.replaceAll(RegExp(r'\s+'), '');
        final start = i == a ? at - owner.indexOf(i) : 0;
        final end = i == b ? (at + q.length - 1) - owner.indexOf(i) + 1 : t.length;
        final r = w.rect;
        final n = t.isEmpty ? 1 : t.length;
        out.add(Rect.fromLTWH(r.left + r.width * start / n, r.top, r.width * (end - start) / n, r.height));
      }
    }
    _hlFor = q;
    _hlRects = out;
    return out;
  }

  @override
  void dispose() {
    _stopAutoScroll();
    WordSelectionLayer.scrolling.removeListener(_onScrollState);
    WordSelectionLayer._clearers.remove(_clear);
    if (_a != null) WordSelectionLayer.active.value = false;
    if (_dragPointer != null) WordSelectionLayer.dragging.value = false;
    super.dispose();
  }

  void _stopAutoScroll() {
    _autoScrollTimer?.cancel();
    _autoScrollTimer = null;
  }

  void _clear() {
    _stopAutoScroll();
    _dragPointer = null;
    if (_a == null) return;
    if (WordSelectionLayer._activeContext == context) WordSelectionLayer._activeContext = null;
    if (mounted) {
      setState(() {
        _a = _b = null;
        _menu = false;
      });
    }
    WordSelectionLayer.active.value = false;
    WordSelectionLayer.dragging.value = false;
    WordSelectionLayer.scrolling.value = false;
  }

  Future<List<SelectableWord>> _ensureWords() async {
    final w = _words;
    if (w != null) return w;
    try {
      _words = await widget.loadWords();
    } catch (_) {
      _words = const [];
    }
    return _words!;
  }

  /// 손가락 자리에서 가장 가까운 낱말 (같은 줄을 우선)
  int? _wordAt(Offset local) {
    final words = _words;
    if (words == null || words.isEmpty || _size.isEmpty) return null;
    final p = Offset(local.dx / _size.width, local.dy / _size.height);
    int? best;
    double bestD = double.infinity;
    for (int i = 0; i < words.length; i++) {
      final r = words[i].rect;
      final dx = p.dx < r.left ? r.left - p.dx : (p.dx > r.right ? p.dx - r.right : 0.0);
      final dy = p.dy < r.top ? r.top - p.dy : (p.dy > r.bottom ? p.dy - r.bottom : 0.0);
      final d = dx * dx * 0.25 + dy * dy * 4;
      if (d < bestD) {
        bestD = d;
        best = i;
      }
    }
    return best;
  }

  int get _lo => (_a! < _b! ? _a : _b)!;
  int get _hi => (_a! < _b! ? _b : _a)!;

  String _selectedText() {
    final words = _words;
    if (words == null || _a == null) return '';
    final buf = StringBuffer();
    for (int i = _lo; i <= _hi; i++) {
      final w = words[i];
      if (i > _lo) {
        final prev = words[i - 1].rect;
        final newLine = w.rect.top > prev.bottom - prev.height * 0.3 || w.rect.left < prev.left - prev.height;
        if (newLine) {
          buf.write('\n');
        } else if (w.rect.left - prev.right > prev.height * 0.15) {
          buf.write(' ');
        }
      }
      buf.write(w.text);
    }
    return buf.toString();
  }

  Future<void> _start(Offset local) async {
    WordSelectionLayer.clearAll();
    await _ensureWords();
    final i = _wordAt(local);
    if (i == null || !mounted) return;
    HapticFeedback.selectionClick();
    setState(() {
      _a = _b = i;
      _menu = true;
    });
    WordSelectionLayer.active.value = true;
    WordSelectionLayer.scrolling.value = false;
    WordSelectionLayer._activeContext = context;
  }

  void _extend(Offset local, {bool start = false}) {
    if (_a == null) return;
    final i = _wordAt(local);
    if (i == null) return;
    if (start && _b == i && _a == _hi) return;
    if (!start && _b == i && _a == _lo) return;
    setState(() {
      if (start) {
        final hi = _hi;
        _a = hi;
        _b = i;
      } else {
        final lo = _lo;
        _a = lo;
        _b = i;
      }
    });
  }

  /// 현재 위젯이 FittedBox 등으로 축소/확대된 실제 배율 계산 (TXT 800x1100 종이 보정용)
  double _visualScale() {
    final box = context.findRenderObject() as RenderBox?;
    if (box == null || !box.hasSize) return 1.0;
    final o = box.localToGlobal(Offset.zero);
    final x = box.localToGlobal(const Offset(100, 0));
    final s = (x - o).distance / 100.0;
    return s.isFinite && s > 0.15 ? s : 1.0;
  }

  void _updateDragAtGlobal(Offset global) {
    final box = context.findRenderObject() as RenderBox?;
    if (box == null || !box.hasSize) return;
    final double inv = 1.0 / _visualScale();
    // 손가락이 손잡이를 가리지 않게 화면 기준 24px 위의 글자를 가리킴
    final Offset local = box.globalToLocal(global) - Offset(0, 24.0 * inv);
    _extend(local, start: _dragStart);
  }

  void _checkEdgeAutoScroll(Offset global) {
    final cb = widget.onEdgeAutoScroll;
    if (cb == null) return;
    final double screenH = MediaQuery.sizeOf(context).height;
    const double edge = 76.0;
    double step = 0;
    if (global.dy > screenH - edge) {
      step = ((global.dy - (screenH - edge)) / edge).clamp(0.2, 1.0) * 14.0;
    } else if (global.dy < edge) {
      step = -((edge - global.dy) / edge).clamp(0.2, 1.0) * 14.0;
    }
    if (step == 0) {
      _stopAutoScroll();
      return;
    }
    _autoScrollTimer ??= Timer.periodic(const Duration(milliseconds: 24), (_) {
      if (!mounted || _dragPointer == null || _dragGlobal == null) {
        _stopAutoScroll();
        return;
      }
      final g = _dragGlobal!;
      final double sh = MediaQuery.sizeOf(context).height;
      double dy = 0;
      if (g.dy > sh - edge) {
        dy = ((g.dy - (sh - edge)) / edge).clamp(0.2, 1.0) * 14.0;
      } else if (g.dy < edge) {
        dy = -((edge - g.dy) / edge).clamp(0.2, 1.0) * 14.0;
      }
      if (dy == 0) {
        _stopAutoScroll();
        return;
      }
      cb(dy);
      _updateDragAtGlobal(g);
    });
  }

  Rect _px(Rect r) => Rect.fromLTWH(r.left * _size.width, r.top * _size.height, r.width * _size.width, r.height * _size.height);

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(builder: (context, c) {
      _size = Size(c.maxWidth, c.maxHeight);
      final children = <Widget>[
        Positioned.fill(child: widget.child),
      ];
      final words = _words;
      final hl = _highlightRects();
      if (hl.isNotEmpty) {
        children.add(Positioned.fill(child: IgnorePointer(child: CustomPaint(painter: _SelectionPainter([for (final r in hl) _px(r)], color: const Color(0x77FFC107))))));
      }
      if (_a != null && words != null && words.isNotEmpty) {
        final rects = [for (int i = _lo; i <= _hi; i++) _px(words[i].rect)];
        children.add(Positioned.fill(child: IgnorePointer(child: CustomPaint(painter: _SelectionPainter(rects)))));
        final bool hideUi = WordSelectionLayer.scrolling.value && _dragPointer == null;
        if (!hideUi) {
          final first = rects.first, last = rects.last;
          // FittedBox 축소 시에도 화면상 일정한 크기로 잡기 쉽게 보정 (TXT·PDF 공통)
          final double inv = (1.0 / _visualScale()).clamp(0.65, 2.8);
          final double hr = 11.0 * inv;
          final double pad = 18.0 * inv;

          Widget handle(Offset at, bool start) => Positioned(
                left: at.dx - (start ? hr * 2 : 0) - pad,
                top: at.dy - (10.0 * inv),
                child: Listener(
                  behavior: HitTestBehavior.opaque,
                  onPointerDown: (e) {
                    _dragPointer = e.pointer;
                    _dragStart = start;
                    _dragGlobal = e.position;
                    WordSelectionLayer.dragging.value = true;
                    WordSelectionLayer.scrolling.value = false;
                    if (_menu) setState(() => _menu = false);
                  },
                  onPointerMove: (e) {
                    if (_dragPointer != e.pointer) return;
                    _dragGlobal = e.position;
                    _updateDragAtGlobal(e.position);
                    _checkEdgeAutoScroll(e.position);
                  },
                  onPointerUp: (e) {
                    if (_dragPointer != e.pointer) return;
                    _stopAutoScroll();
                    _dragPointer = null;
                    _dragGlobal = null;
                    WordSelectionLayer.dragging.value = false;
                    if (mounted) setState(() => _menu = true);
                  },
                  onPointerCancel: (e) {
                    if (_dragPointer != e.pointer) return;
                    _stopAutoScroll();
                    _dragPointer = null;
                    _dragGlobal = null;
                    WordSelectionLayer.dragging.value = false;
                    if (mounted) setState(() => _menu = true);
                  },
                  child: Padding(
                    padding: EdgeInsets.all(pad),
                    child: CustomPaint(size: Size(hr * 2, hr * 2), painter: TextSelectHandlePainter(start)),
                  ),
                ),
              );

          children.add(handle(first.bottomLeft, true));
          children.add(handle(last.bottomRight, false));
          if (_menu && _dragPointer == null) {
            final top = rects.map((r) => r.top).reduce(math.min);
            final bottom = rects.map((r) => r.bottom).reduce(math.max);
            final double barOffset = 60.0 * inv;
            final double y = top - barOffset > 8 ? top - barOffset : bottom + 30.0 * inv;
            children.add(Positioned(
              left: 0,
              right: 0,
              top: y.clamp(0, (_size.height - 56 * inv).clamp(0, double.infinity)).toDouble(),
              child: Center(
                child: Transform.scale(
                  scale: inv,
                  child: _menuBar(),
                ),
              ),
            ));
          }
        }
      }
      return GestureDetector(
        behavior: HitTestBehavior.translucent,
        onLongPressStart: (d) {
          _start(d.localPosition);
        },
        onTap: _a == null ? null : _clear,
        child: Stack(clipBehavior: Clip.none, children: children),
      );
    });
  }

  Widget _menuBar() => SelectionActionBar(
        tr: widget.tr,
        onCopy: () {
          final text = _selectedText();
          _clear();
          copyText(context, text, widget.tr);
        },
        onSelectAll: () {
          final words = _words;
          if (words == null || words.isEmpty) return;
          setState(() {
            _a = 0;
            _b = words.length - 1;
          });
        },
        onShare: () {
          final text = _selectedText();
          _clear();
          shareText(text);
        },
      );
}

class _SelectionPainter extends CustomPainter {
  _SelectionPainter(this.rects, {this.color = const Color(0x4D1A73E8)}); // 한글·워드와 같은 파란 바탕 (kTextSelectColor 30%)
  final List<Rect> rects;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final p = Paint()..color = color;
    for (final r in rects) {
      canvas.drawRect(r, p);
    }
  }

  @override
  bool shouldRepaint(_SelectionPainter old) => old.rects.length != rects.length || (rects.isNotEmpty && old.rects.first != rects.first) || (rects.isNotEmpty && old.rects.last != rects.last);
}
