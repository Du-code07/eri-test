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

/// 한글·워드 파일처럼 글을 길게 눌러 고르기 (페이지 경계를 넘어 다음/이전 페이지까지 확장 지원):
/// 길게 누르면 그 낱말이 골라지며 양쪽 물방울 손잡이와 [복사 | 모두 선택 | 공유] 막대가 바로 표시됨.
/// 하이라이트가 있는 상태에서도 스크롤·줌이 자유롭게 되며, 화면이 움직이는 동안은 손잡이가 잠깐 숨겨졌다가 멈추면 다시 나타남.
class WordSelectionLayer extends StatefulWidget {
  const WordSelectionLayer({
    super.key,
    required this.loadWords,
    required this.tr,
    required this.child,
    this.pageIndex = 0,
    this.highlight = '',
    this.onEdgeAutoScroll,
  });

  /// 이 층이 속한 쪽 번호 (스크롤·두 쪽 보기에서 페이지 간 드래그 확장용)
  final int pageIndex;

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

  // ── 다중 페이지 선택 상태 공유 (PDF·TXT 스크롤/두 쪽 보기에서 페이지 넘어 드래그 지원) ──
  static final Map<int, _WordSelectionLayerState> _pages = {};
  static final Map<int, List<SelectableWord>> _wordCache = {};
  static int? _selAPage, _selAWord, _selBPage, _selBWord;
  static bool _selMenu = false;
  static int? _dragPointer;
  static bool _dragStart = false;
  static Offset? _dragGlobal;
  static Timer? _autoScrollTimer;
  static void Function(double dy)? _activeAutoScroll;

  static bool get _hasSelection => _selAPage != null && _selAWord != null && _selBPage != null && _selBWord != null;

  static (int, int, int, int) get _orderedRange {
    final ap = _selAPage!, aw = _selAWord!, bp = _selBPage!, bw = _selBWord!;
    final bool forward = ap < bp || (ap == bp && aw <= bw);
    return forward ? (ap, aw, bp, bw) : (bp, bw, ap, aw);
  }

  static void _notifyAllPages() {
    for (final st in List<_WordSelectionLayerState>.of(_pages.values)) {
      if (st.mounted) st._refresh();
    }
  }

  /// 이 화면 자리가 글을 골라 둔 쪽들 안인가 (밖을 누르면 고른 글을 지움)
  static bool containsGlobal(Offset global) {
    if (!_hasSelection) return false;
    final (loP, _, hiP, _) = _orderedRange;
    for (final entry in _pages.entries) {
      if (entry.key < loP || entry.key > hiP) continue;
      final box = entry.value.context.findRenderObject() as RenderBox?;
      if (box == null || !box.attached) continue;
      final local = box.globalToLocal(global);
      if ((Offset.zero & box.size).inflate(44).contains(local)) return true;
    }
    return false;
  }

  /// 골라 둔 글을 모두 지움
  static void clearAll() {
    _autoScrollTimer?.cancel();
    _autoScrollTimer = null;
    _dragPointer = null;
    _dragGlobal = null;
    _activeAutoScroll = null;
    final had = _hasSelection;
    _selAPage = _selAWord = _selBPage = _selBWord = null;
    _selMenu = false;
    active.value = false;
    dragging.value = false;
    scrolling.value = false;
    if (had) _notifyAllPages();
  }

  static String _selectedTextAll() {
    if (!_hasSelection) return '';
    final (loP, loW, hiP, hiW) = _orderedRange;
    final buf = StringBuffer();
    for (int p = loP; p <= hiP; p++) {
      final words = _wordCache[p];
      if (words == null || words.isEmpty) continue;
      final int s = (p == loP ? loW : 0).clamp(0, words.length - 1);
      final int e = (p == hiP ? hiW : words.length - 1).clamp(0, words.length - 1);
      if (p > loP && buf.isNotEmpty) buf.write('\n');
      for (int i = s; i <= e; i++) {
        final w = words[i];
        if (i > s) {
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
    }
    return buf.toString();
  }

  /// 화면 좌표 [global]이 가리키는 페이지와 낱말을 찾아 선택 끝점을 이동 (다른 페이지로 자연스럽게 넘어감)
  static void _updateDragAcrossPages(Offset global) {
    if (!_hasSelection || _pages.isEmpty) return;
    _WordSelectionLayerState? target;
    double bestPageDist = double.infinity;
    final sortedKeys = _pages.keys.toList()..sort();
    for (final k in sortedKeys) {
      final st = _pages[k]!;
      if (!st.mounted) continue;
      final box = st.context.findRenderObject() as RenderBox?;
      if (box == null || !box.attached || !box.hasSize) continue;
      final tl = box.localToGlobal(Offset.zero);
      final br = box.localToGlobal(Offset(box.size.width, box.size.height));
      final top = math.min(tl.dy, br.dy);
      final bottom = math.max(tl.dy, br.dy);
      final left = math.min(tl.dx, br.dx);
      final right = math.max(tl.dx, br.dx);
      // 손가락이 손잡이를 가리지 않게 24px 위 기준
      final double py = global.dy - 24.0;
      final double dy = py < top ? top - py : (py > bottom ? py - bottom : 0.0);
      final double dx = global.dx < left ? left - global.dx : (global.dx > right ? global.dx - right : 0.0);
      final double dist = dy * 4.0 + dx;
      if (dist < bestPageDist) {
        bestPageDist = dist;
        target = st;
      }
    }
    if (target == null) return;
    final int targetPage = target.widget.pageIndex;
    final words = target._words;
    if (words == null) {
      // 아직 단어가 로드되지 않은 다음 페이지면 비동기로 로드 후 즉시 반영
      target._ensureWords().then((loaded) {
        if (loaded.isNotEmpty && _dragPointer != null && _dragGlobal != null) {
          _updateDragAcrossPages(_dragGlobal!);
        }
      });
      return;
    }
    if (words.isEmpty) return;
    final box = target.context.findRenderObject() as RenderBox?;
    if (box == null || !box.hasSize) return;
    final double inv = 1.0 / target._visualScale();
    final Offset local = box.globalToLocal(global) - Offset(0, 24.0 * inv);
    final int? wi = target._wordAt(local);
    if (wi == null) return;

    final (loP, loW, hiP, hiW) = _orderedRange;
    if (_dragStart) {
      if (_selAPage == hiP && _selAWord == hiW && _selBPage == targetPage && _selBWord == wi) return;
      _selAPage = hiP;
      _selAWord = hiW;
      _selBPage = targetPage;
      _selBWord = wi;
    } else {
      if (_selAPage == loP && _selAWord == loW && _selBPage == targetPage && _selBWord == wi) return;
      _selAPage = loP;
      _selAWord = loW;
      _selBPage = targetPage;
      _selBWord = wi;
    }
    // 중간 페이지 단어들도 캐시해 두어 복사 시 누락 방지
    final (nLoP, _, nHiP, _) = _orderedRange;
    for (int p = nLoP; p <= nHiP; p++) {
      final pst = _pages[p];
      if (pst != null && pst._words == null) {
        unawaited(pst._ensureWords().then((_) => _notifyAllPages()));
      }
    }
    _notifyAllPages();
  }

  static void _checkEdgeAutoScroll(BuildContext ctx, Offset global) {
    final cb = _activeAutoScroll;
    if (cb == null) return;
    final double screenH = MediaQuery.sizeOf(ctx).height;
    const double edge = 76.0;
    double step = 0;
    if (global.dy > screenH - edge) {
      step = ((global.dy - (screenH - edge)) / edge).clamp(0.2, 1.0) * 14.0;
    } else if (global.dy < edge) {
      step = -((edge - global.dy) / edge).clamp(0.2, 1.0) * 14.0;
    }
    if (step == 0) {
      _autoScrollTimer?.cancel();
      _autoScrollTimer = null;
      return;
    }
    _autoScrollTimer ??= Timer.periodic(const Duration(milliseconds: 24), (_) {
      if (_dragPointer == null || _dragGlobal == null || _activeAutoScroll == null) {
        _autoScrollTimer?.cancel();
        _autoScrollTimer = null;
        return;
      }
      final g = _dragGlobal!;
      double dy = 0;
      if (g.dy > screenH - edge) {
        dy = ((g.dy - (screenH - edge)) / edge).clamp(0.2, 1.0) * 14.0;
      } else if (g.dy < edge) {
        dy = -((edge - g.dy) / edge).clamp(0.2, 1.0) * 14.0;
      }
      if (dy == 0) {
        _autoScrollTimer?.cancel();
        _autoScrollTimer = null;
        return;
      }
      _activeAutoScroll!(dy);
      _updateDragAcrossPages(g);
    });
  }

  @override
  State<WordSelectionLayer> createState() => _WordSelectionLayerState();
}

class _WordSelectionLayerState extends State<WordSelectionLayer> {
  List<SelectableWord>? _words;
  Size _size = Size.zero;

  void _refresh() {
    if (mounted) setState(() {});
  }

  @override
  void initState() {
    super.initState();
    WordSelectionLayer._pages[widget.pageIndex] = this;
    WordSelectionLayer.scrolling.addListener(_onScrollState);
    if (WordSelectionLayer._wordCache.containsKey(widget.pageIndex)) {
      _words = WordSelectionLayer._wordCache[widget.pageIndex];
    }
    _loadForHighlight();
    // 이미 다른 페이지에서 확장돼 이 페이지가 선택 범위에 포함돼 있으면 즉시 단어 로드
    if (WordSelectionLayer._hasSelection && _words == null) {
      final (loP, _, hiP, _) = WordSelectionLayer._orderedRange;
      if (widget.pageIndex >= loP && widget.pageIndex <= hiP) {
        unawaited(_ensureWords().then((_) => _refresh()));
      }
    }
  }

  void _onScrollState() {
    if (mounted && WordSelectionLayer._hasSelection) setState(() {});
  }

  @override
  void didUpdateWidget(covariant WordSelectionLayer oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.pageIndex != widget.pageIndex) {
      if (WordSelectionLayer._pages[oldWidget.pageIndex] == this) {
        WordSelectionLayer._pages.remove(oldWidget.pageIndex);
      }
      WordSelectionLayer._pages[widget.pageIndex] = this;
      _words = WordSelectionLayer._wordCache[widget.pageIndex];
      _hlFor = null;
    }
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
    WordSelectionLayer.scrolling.removeListener(_onScrollState);
    if (WordSelectionLayer._pages[widget.pageIndex] == this) {
      WordSelectionLayer._pages.remove(widget.pageIndex);
    }
    super.dispose();
  }

  Future<List<SelectableWord>> _ensureWords() async {
    final w = _words;
    if (w != null) return w;
    try {
      _words = await widget.loadWords();
      WordSelectionLayer._wordCache[widget.pageIndex] = _words!;
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

  Future<void> _start(Offset local) async {
    WordSelectionLayer.clearAll();
    await _ensureWords();
    final i = _wordAt(local);
    if (i == null || !mounted) return;
    HapticFeedback.selectionClick();
    WordSelectionLayer._selAPage = widget.pageIndex;
    WordSelectionLayer._selAWord = i;
    WordSelectionLayer._selBPage = widget.pageIndex;
    WordSelectionLayer._selBWord = i;
    WordSelectionLayer._selMenu = true;
    WordSelectionLayer.active.value = true;
    WordSelectionLayer.scrolling.value = false;
    WordSelectionLayer._notifyAllPages();
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
      if (WordSelectionLayer._hasSelection && words != null && words.isNotEmpty) {
        final (loP, loW, hiP, hiW) = WordSelectionLayer._orderedRange;
        final int p = widget.pageIndex;
        if (p >= loP && p <= hiP) {
          final int sIdx = (p == loP ? loW : 0).clamp(0, words.length - 1);
          final int eIdx = (p == hiP ? hiW : words.length - 1).clamp(0, words.length - 1);
          final rects = [for (int i = sIdx; i <= eIdx; i++) _px(words[i].rect)];
          children.add(Positioned.fill(child: IgnorePointer(child: CustomPaint(painter: _SelectionPainter(rects)))));
          final bool hideUi = WordSelectionLayer.scrolling.value && WordSelectionLayer._dragPointer == null;
          if (!hideUi) {
            final double inv = (1.0 / _visualScale()).clamp(0.65, 2.8);
            final double hr = 11.0 * inv;
            final double pad = 18.0 * inv;

            Widget handle(Offset at, bool start) => Positioned(
                  left: at.dx - (start ? hr * 2 : 0) - pad,
                  top: at.dy - (10.0 * inv),
                  child: Listener(
                    behavior: HitTestBehavior.opaque,
                    onPointerDown: (e) {
                      WordSelectionLayer._dragPointer = e.pointer;
                      WordSelectionLayer._dragStart = start;
                      WordSelectionLayer._dragGlobal = e.position;
                      WordSelectionLayer._activeAutoScroll = widget.onEdgeAutoScroll;
                      WordSelectionLayer.dragging.value = true;
                      WordSelectionLayer.scrolling.value = false;
                      WordSelectionLayer._selMenu = false;
                      WordSelectionLayer._notifyAllPages();
                    },
                    onPointerMove: (e) {
                      if (WordSelectionLayer._dragPointer != e.pointer) return;
                      WordSelectionLayer._dragGlobal = e.position;
                      WordSelectionLayer._updateDragAcrossPages(e.position);
                      WordSelectionLayer._checkEdgeAutoScroll(context, e.position);
                    },
                    onPointerUp: (e) {
                      if (WordSelectionLayer._dragPointer != e.pointer) return;
                      WordSelectionLayer._autoScrollTimer?.cancel();
                      WordSelectionLayer._autoScrollTimer = null;
                      WordSelectionLayer._dragPointer = null;
                      WordSelectionLayer._dragGlobal = null;
                      WordSelectionLayer._activeAutoScroll = null;
                      WordSelectionLayer.dragging.value = false;
                      WordSelectionLayer._selMenu = true;
                      WordSelectionLayer._notifyAllPages();
                    },
                    onPointerCancel: (e) {
                      if (WordSelectionLayer._dragPointer != e.pointer) return;
                      WordSelectionLayer._autoScrollTimer?.cancel();
                      WordSelectionLayer._autoScrollTimer = null;
                      WordSelectionLayer._dragPointer = null;
                      WordSelectionLayer._dragGlobal = null;
                      WordSelectionLayer._activeAutoScroll = null;
                      WordSelectionLayer.dragging.value = false;
                      WordSelectionLayer._selMenu = true;
                      WordSelectionLayer._notifyAllPages();
                    },
                    child: Padding(
                      padding: EdgeInsets.all(pad),
                      child: CustomPaint(size: Size(hr * 2, hr * 2), painter: TextSelectHandlePainter(start)),
                    ),
                  ),
                );

            if (p == loP) children.add(handle(rects.first.bottomLeft, true));
            if (p == hiP) children.add(handle(rects.last.bottomRight, false));
            if (p == loP && WordSelectionLayer._selMenu && WordSelectionLayer._dragPointer == null) {
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
      }
      return GestureDetector(
        behavior: HitTestBehavior.translucent,
        onLongPressStart: (d) {
          _start(d.localPosition);
        },
        onTap: WordSelectionLayer._hasSelection ? WordSelectionLayer.clearAll : null,
        child: Stack(clipBehavior: Clip.none, children: children),
      );
    });
  }

  Widget _menuBar() => SelectionActionBar(
        tr: widget.tr,
        onCopy: () {
          final text = WordSelectionLayer._selectedTextAll();
          WordSelectionLayer.clearAll();
          copyText(context, text, widget.tr);
        },
        onSelectAll: () {
          final words = _words;
          if (words == null || words.isEmpty) return;
          WordSelectionLayer._selAPage = widget.pageIndex;
          WordSelectionLayer._selAWord = 0;
          WordSelectionLayer._selBPage = widget.pageIndex;
          WordSelectionLayer._selBWord = words.length - 1;
          WordSelectionLayer._notifyAllPages();
        },
        onShare: () {
          final text = WordSelectionLayer._selectedTextAll();
          WordSelectionLayer.clearAll();
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
