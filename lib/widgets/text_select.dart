import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

// 길게 눌러 글 고르기: 고른 글 위에 뜨는 [복사 | 모두 선택 | 공유] 막대와,
// 글자 위치를 아는 쪽(PDF)에서 글을 고르는 층 (손잡이로 범위 조절)

const MethodChannel _channel = MethodChannel('ebook_reader/pdf_renderer');

/// 고른 글·손잡이 색 (쪽은 대부분 흰 종이라 잘 보이는 파란색)
const Color kTextSelectColor = Color(0xFF1A73E8);

/// 글을 다른 앱으로 보내기 (안드로이드 공유 창)
Future<void> shareText(String text) async {
  if (text.trim().isEmpty) return;
  try {
    await _channel.invokeMethod('shareText', {'text': text});
  } catch (_) {}
}

/// 글을 클립보드에 복사하고 짧게 알림
Future<void> copyText(BuildContext context, String text, String Function(String ko, String en, String zh, String ja) tr) async {
  if (text.isEmpty) return;
  await Clipboard.setData(ClipboardData(text: text));
  if (!context.mounted) return;
  ScaffoldMessenger.of(context)
    ..hideCurrentSnackBar()
    ..showSnackBar(SnackBar(content: Text(tr('복사했어요', 'Copied', '已复制', 'コピーしました')), duration: const Duration(milliseconds: 1400)));
}

/// 고른 글 위에 뜨는 어두운 막대: 복사 | 모두 선택 | 공유
class SelectionActionBar extends StatelessWidget {
  const SelectionActionBar({super.key, required this.tr, required this.onCopy, required this.onSelectAll, required this.onShare, this.onHighlight});

  final String Function(String ko, String en, String zh, String ja) tr;
  final VoidCallback onCopy;
  final VoidCallback? onSelectAll;
  final VoidCallback onShare;

  /// 형광펜 칠하기 (문서에서만)
  final VoidCallback? onHighlight;

  @override
  Widget build(BuildContext context) {
    Widget button(String label, VoidCallback onTap) => InkWell(
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 12),
            child: Text(label, style: const TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.w600)),
          ),
        );
    Widget divider() => Container(width: 1, height: 22, color: Colors.white.withValues(alpha: 0.28));
    return Material(
      color: const Color(0xFF303034),
      elevation: 3,
      shadowColor: Colors.black54,
      borderRadius: BorderRadius.circular(14),
      clipBehavior: Clip.antiAlias,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          button(tr('복사', 'Copy', '复制', 'コピー'), onCopy),
          if (onSelectAll != null) ...[divider(), button(tr('모두 선택', 'Select all', '全选', 'すべて選択'), onSelectAll!)],
          divider(),
          button(tr('공유', 'Share', '分享', '共有'), onShare),
          if (onHighlight != null) ...[divider(), button(tr('형광펜', 'Highlight', '荧光笔', 'マーカー'), onHighlight!)],
        ],
      ),
    );
  }
}

/// 화면 어디에나 띄우는 막대 (엑셀처럼 글 고르기를 문서 화면이 직접 하는 경우)
class FloatingSelectionBar {
  OverlayEntry? _entry;

  bool get shown => _entry != null;

  void show(BuildContext context, Offset globalAnchor, {
    required String Function(String ko, String en, String zh, String ja) tr,
    required VoidCallback onCopy,
    VoidCallback? onSelectAll,
    required VoidCallback onShare,
  }) {
    hide();
    final overlay = Overlay.of(context, rootOverlay: true);
    _entry = OverlayEntry(
      builder: (ctx) {
        final Size screen = MediaQuery.sizeOf(ctx);
        // 누른 곳 조금 위, 화면 밖으로 나가지 않게
        final double top = (globalAnchor.dy - 72).clamp(MediaQuery.paddingOf(ctx).top + 8, screen.height - 80).toDouble();
        return Positioned(
          top: top,
          left: 0,
          right: 0,
          child: Center(
            child: SelectionActionBar(tr: tr, onCopy: onCopy, onSelectAll: onSelectAll, onShare: onShare),
          ),
        );
      },
    );
    overlay.insert(_entry!);
  }

  void hide() {
    _entry?.remove();
    _entry = null;
  }
}

/// 쪽 위 한 줄의 글과 자리 (층 기준 좌표)
class SelLine {
  const SelLine(this.text, this.rect, {this.page = -1, this.norm});
  final String text;
  final Rect rect;

  /// 스크롤 보기: 이 글이 놓인 쪽 번호와 그 쪽 안 자리 (쪽 크기 대비 0~1).
  /// 스크롤·확대·축소로 쪽이 움직여도 이 자리로 화면 자리를 다시 셈
  final int page;
  final Rect? norm;

  SelLine moved(Rect r) => SelLine(text, r, page: page, norm: norm);
}

/// 글자 위치를 아는 쪽(PDF)에서 길게 눌러 글 고르기
class PageTextSelection extends ChangeNotifier {
  List<SelLine> lines = const [];

  /// 막대가 놓인 띠 (층이 그릴 때 정함) — 이 안이나 손잡이 근처를 누르면 고른 글을 지우지 않음
  Rect? barBand;

  bool hitsControls(Offset p) {
    if (!active) return false;
    if (barBand?.contains(p) ?? false) return true;
    if ((p - startHandle).distance < 36 || (p - endHandle).distance < 36) return true;
    return hitsSelection(p);
  }

  /// 고른 글(파란 바탕) 위를 눌렀는지
  bool hitsSelection(Offset p) => highlightRects.any((r) => r.inflate(10).contains(p));

  /// 낱말 상자들(읽는 순서)을 줄로 묶음: 같은 높이에서 오른쪽으로 이어지는 낱말은 한 줄 (쪽이 바뀌면 새 줄)
  static List<SelLine> linesFromWords(List<SelLine> words) {
    final out = <SelLine>[];
    String text = '';
    Rect? cur;
    int page = -1;
    Rect? norm;
    void flush() {
      final c = cur;
      if (c != null) out.add(SelLine(text, c, page: page, norm: norm));
    }
    for (final w in words) {
      if (w.text.trim().isEmpty || w.rect.isEmpty) continue;
      final c = cur;
      if (c != null && w.page == page) {
        final double h = math.max(1.0, c.height);
        final bool sameRow = (w.rect.center.dy - c.center.dy).abs() < h * 0.5;
        final double gap = w.rect.left - c.right;
        if (sameRow && gap > -h * 0.5 && gap < h * 3) {
          text += gap > h * 0.12 ? ' ${w.text}' : w.text;
          cur = c.expandToInclude(w.rect);
          final n = norm, wn = w.norm;
          norm = (n != null && wn != null) ? n.expandToInclude(wn) : null;
          continue;
        }
      }
      flush();
      text = w.text;
      cur = w.rect;
      page = w.page;
      norm = w.norm;
    }
    flush();
    return out;
  }

  /// 모든 줄이 쪽 자리를 알고 있는가 (스크롤 보기)
  bool get anchored => lines.isNotEmpty && lines.every((l) => l.norm != null && l.page >= 0);

  /// 쪽들의 지금 화면 자리([slots], 층 기준)로 줄 자리를 다시 셈 — 스크롤·확대·축소 중에도 글과 딱 맞게.
  /// 화면 밖이라 자리를 모르는 쪽은 가까운 쪽 크기로 위·아래에 이어 놓음 (화면 밖에 있게만)
  void reproject(Map<int, Rect> slots) {
    if (lines.isEmpty || slots.isEmpty || !anchored) return;
    final keys = slots.keys.toList()..sort();
    double gap = 6;
    for (int i = 0; i + 1 < keys.length; i++) {
      if (keys[i + 1] == keys[i] + 1) {
        gap = math.max(0, slots[keys[i + 1]]!.top - slots[keys[i]]!.bottom);
        break;
      }
    }
    Rect slotOf(int p) {
      final known = slots[p];
      if (known != null) return known;
      int? below, above;
      for (final k in keys) {
        if (k < p) below = k;
        if (k > p) {
          above = k;
          break;
        }
      }
      if (below != null) {
        final b = slots[below]!;
        return b.shift(Offset(0, (b.height + gap) * (p - below)));
      }
      final a = slots[above!]!;
      return a.shift(Offset(0, -(a.height + gap) * (above - p)));
    }
    lines = [
      for (final l in lines)
        () {
          final n = l.norm!;
          final s = slotOf(l.page);
          return l.moved(Rect.fromLTWH(s.left + n.left * s.width, s.top + n.top * s.height, n.width * s.width, n.height * s.height));
        }(),
    ];
    notifyListeners();
  }
  int _aLine = -1, _aChar = 0, _bLine = -1, _bChar = 0;

  bool get active => _aLine >= 0 && lines.isNotEmpty;

  // 앞·뒤 순서로 정리한 범위
  (int, int, int, int) get _range {
    final bool forward = _aLine < _bLine || (_aLine == _bLine && _aChar <= _bChar);
    return forward ? (_aLine, _aChar, _bLine, _bChar) : (_bLine, _bChar, _aLine, _aChar);
  }

  void clear() {
    if (_aLine < 0) return;
    _aLine = _bLine = -1;
    notifyListeners();
  }

  /// 스크롤 보기에서 문서가 움직일 때 하이라이트와 손잡이도 글과 함께 이동
  void shiftBy(Offset delta) {
    if (!active || delta == Offset.zero) return;
    lines = [for (final l in lines) l.moved(l.rect.shift(delta))];
    notifyListeners();
  }

  /// 자동 스크롤로 새로 화면에 들어온 줄들을 기존 선택 인덱스를 유지하며 앞·뒤에 병합
  void mergeVisibleLines(List<SelLine> fresh) {
    if (!active || fresh.isEmpty) return;
    // 쪽 자리를 아는 줄들은 (쪽, 쪽 안 높이) 순서로 비교 — 화면 자리는 아직 옛 자리일 수 있음
    if (anchored && fresh.every((l) => l.norm != null && l.page >= 0)) {
      double key(SelLine l) => l.page + l.norm!.center.dy;
      final double lastKey = key(lines.last) + lines.last.norm!.height * 0.5;
      final double firstKey = key(lines.first) - lines.first.norm!.height * 0.5;
      final below = [for (final nl in fresh) if (key(nl) > lastKey) nl];
      final above = [for (final nl in fresh) if (key(nl) < firstKey) nl];
      if (below.isEmpty && above.isEmpty) return;
      lines.addAll(below);
      if (above.isNotEmpty) {
        lines.insertAll(0, above);
        _aLine += above.length;
        _bLine += above.length;
      }
      notifyListeners();
      return;
    }
    bool changed = false;
    final double lastBottom = lines.last.rect.bottom;
    for (final nl in fresh) {
      if (nl.rect.center.dy > lastBottom + 2) {
        lines.add(nl);
        changed = true;
      }
    }
    final double firstTop = lines.first.rect.top;
    final above = <SelLine>[
      for (final nl in fresh)
        if (nl.rect.center.dy < firstTop - 2) nl,
    ];
    if (above.isNotEmpty) {
      lines.insertAll(0, above);
      _aLine += above.length;
      _bLine += above.length;
      changed = true;
    }
    if (changed) notifyListeners();
  }

  /// [p]에 가장 가까운 줄과 그 줄 안의 글자 자리
  (int, int)? hit(Offset p) {
    if (lines.isEmpty) return null;
    int best = -1;
    double bestD = double.infinity;
    for (int i = 0; i < lines.length; i++) {
      final r = lines[i].rect;
      final double dy = p.dy < r.top ? r.top - p.dy : (p.dy > r.bottom ? p.dy - r.bottom : 0);
      final double dx = p.dx < r.left ? r.left - p.dx : (p.dx > r.right ? p.dx - r.right : 0);
      final double d = dy * 3 + dx; // 위아래로 먼 줄보다 같은 높이의 줄을 먼저
      if (d < bestD) {
        bestD = d;
        best = i;
      }
    }
    if (best < 0) return null;
    final r = lines[best].rect;
    final int len = lines[best].text.length;
    final int c = r.width <= 0 ? 0 : ((p.dx - r.left) / r.width * len).round().clamp(0, len);
    return (best, c);
  }

  static bool _isWordChar(String ch) => !RegExp(r'[\s.,;:!?·、。，()\[\]{}<>"' "'" r'“”‘’]').hasMatch(ch);

  /// 누른 곳의 낱말을 고름. 글이 없는 곳이면 false
  bool selectWordAt(Offset p) {
    final h = hit(p);
    if (h == null) return false;
    final r = lines[h.$1].rect;
    // 글에서 너무 먼 곳은 고르지 않음
    if (!r.inflate(math.max(24.0, r.height)).contains(p)) return false;
    final String t = lines[h.$1].text;
    if (t.isEmpty) return false;
    int s = h.$2.clamp(0, t.length - 1), e = s;
    if (!_isWordChar(t[s]) && s > 0 && _isWordChar(t[s - 1])) s = e = s - 1;
    while (s > 0 && _isWordChar(t[s - 1])) {
      s--;
    }
    while (e < t.length && _isWordChar(t[e])) {
      e++;
    }
    if (e == s) e = math.min(t.length, s + 1);
    _aLine = _bLine = h.$1;
    _aChar = s;
    _bChar = e;
    notifyListeners();
    return true;
  }

  void selectAll() {
    if (lines.isEmpty) return;
    _aLine = 0;
    _aChar = 0;
    _bLine = lines.length - 1;
    _bChar = lines.last.text.length;
    notifyListeners();
  }

  /// 손잡이 끌기: [start]면 앞 손잡이, 아니면 뒤 손잡이를 [p]로
  void moveHandle(bool start, Offset p) {
    if (!active) return;
    final h = hit(p);
    if (h == null) return;
    final (sl, sc, el, ec) = _range;
    if (start) {
      _aLine = h.$1;
      _aChar = h.$2;
      _bLine = el;
      _bChar = ec;
    } else {
      _aLine = sl;
      _aChar = sc;
      _bLine = h.$1;
      _bChar = h.$2;
    }
    notifyListeners();
  }

  /// 길게 누른 채로 끌기: 처음 고른 낱말의 앞을 고정하고 끝을 옮김
  void extendTo(Offset p) {
    if (!active) return;
    final h = hit(p);
    if (h == null) return;
    _bLine = h.$1;
    _bChar = h.$2;
    notifyListeners();
  }

  String get selectedText {
    if (!active) return '';
    final (sl, sc, el, ec) = _range;
    final out = StringBuffer();
    for (int i = sl; i <= el; i++) {
      final t = lines[i].text;
      final int a = i == sl ? sc.clamp(0, t.length) : 0;
      final int b = i == el ? ec.clamp(0, t.length) : t.length;
      if (b > a) out.write(t.substring(a, b));
      if (i != el) out.write('\n');
    }
    return out.toString();
  }

  double _xAt(int line, int c) {
    final l = lines[line];
    final int len = math.max(1, l.text.length);
    return l.rect.left + l.rect.width * (c.clamp(0, len) / len);
  }

  /// 고른 부분의 네모들 (줄마다 하나)
  List<Rect> get highlightRects {
    if (!active) return const [];
    final (sl, sc, el, ec) = _range;
    final out = <Rect>[];
    for (int i = sl; i <= el; i++) {
      final r = lines[i].rect;
      final double l = i == sl ? _xAt(i, sc) : r.left;
      final double rr = i == el ? _xAt(i, ec) : r.right;
      if (rr > l) out.add(Rect.fromLTRB(l, r.top, rr, r.bottom));
    }
    return out;
  }

  /// 고른 부분의 네모들을 쪽 안 자리로 ([쪽, 왼쪽, 위, 너비, 높이] — 쪽 크기 대비 0~1). 쪽 자리를 모르는 줄은 뺌
  List<List<num>> get highlightNorm {
    if (!active) return const [];
    final (sl, sc, el, ec) = _range;
    final out = <List<num>>[];
    for (int i = sl; i <= el; i++) {
      final line = lines[i];
      final n = line.norm;
      if (n == null || line.page < 0) continue;
      final int len = math.max(1, line.text.length);
      final double a = i == sl ? sc.clamp(0, len) / len : 0;
      final double b = i == el ? ec.clamp(0, len) / len : 1;
      if (b > a) out.add([line.page, n.left + n.width * a, n.top, n.width * (b - a), n.height]);
    }
    return out;
  }

  /// 앞 손잡이 자리 (글 아래 왼쪽) / 뒤 손잡이 자리 (글 아래 오른쪽)
  Offset get startHandle {
    final (sl, sc, _, _) = _range;
    return Offset(_xAt(sl, sc), lines[sl].rect.bottom);
  }

  Offset get endHandle {
    final (_, _, el, ec) = _range;
    return Offset(_xAt(el, ec), lines[el].rect.bottom);
  }
}

/// [PageTextSelection]을 그리는 층: 고른 글 바탕, 손잡이 두 개, 막대
class PageTextSelectLayer extends StatelessWidget {
  const PageTextSelectLayer({
    super.key,
    required this.sel,
    required this.tr,
    this.onDone,
    this.onHighlight,
    this.onHandleDragStart,
    this.onHandleDragUpdate,
    this.onHandleDragEnd,
    this.hideHandles = false,
    this.paintRects,
  });

  /// 고른 글 바탕을 이 층에서 그리는가 (없으면 그림). 스크롤 보기 문서는 문서 화면 안에 그려서 글과 함께 움직이게 함
  final bool Function()? paintRects;

  /// 형광펜 칠하기: 고른 부분의 네모들(이 층 기준)을 받음. 없으면 단추를 숨김
  final void Function(List<Rect> rects)? onHighlight;

  final PageTextSelection sel;
  final String Function(String ko, String en, String zh, String ja) tr;

  /// 복사·공유를 누른 뒤
  final VoidCallback? onDone;
  final VoidCallback? onHandleDragStart;
  final void Function(bool start, Offset globalPosition)? onHandleDragUpdate;
  final VoidCallback? onHandleDragEnd;
  final bool hideHandles;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: sel,
      builder: (context, _) {
        if (!sel.active) return const SizedBox.shrink();
        final rects = sel.highlightRects;
        if (rects.isEmpty) return const SizedBox.shrink();
        final Rect bounds = rects.reduce((a, b) => a.expandToInclude(b));
        final Offset s = sel.startHandle, e = sel.endHandle;
        const double hr = 11; // 손잡이 반지름

        Widget handle(bool start, Offset at) => Positioned(
              left: at.dx - (start ? hr * 2 : 0) - 14,
              top: at.dy - 10,
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onPanStart: (_) => onHandleDragStart?.call(),
                onPanUpdate: (d) {
                  final box = context.findRenderObject() as RenderBox?;
                  if (box == null) return;
                  // 손가락이 손잡이를 가리지 않게 조금 위의 글자를 기준으로
                  sel.moveHandle(start, box.globalToLocal(d.globalPosition) - const Offset(0, 28));
                  onHandleDragUpdate?.call(start, d.globalPosition);
                },
                onPanEnd: (_) => onHandleDragEnd?.call(),
                onPanCancel: () => onHandleDragEnd?.call(),
                child: Padding(
                  padding: const EdgeInsets.all(14),
                  child: CustomPaint(size: const Size(hr * 2, hr * 2), painter: TextSelectHandlePainter(start)),
                ),
              ),
            );

        return LayoutBuilder(builder: (context, c) {
          // 막대: 고른 글 위 (자리가 없으면 아래)
          final double barTop = bounds.top - 60 > 8 ? bounds.top - 60 : math.min(c.maxHeight - 56, bounds.bottom + 30);
          sel.barBand = Rect.fromLTWH(0, barTop - 6, c.maxWidth, 60);
          return Stack(
            clipBehavior: Clip.none,
            children: [
              if (paintRects?.call() ?? true) IgnorePointer(child: CustomPaint(size: Size.infinite, painter: _HighlightPainter(rects))),

              if (!hideHandles) handle(true, s),
              if (!hideHandles) handle(false, e),
              if (!hideHandles)
              Positioned(
                top: barTop,
                left: 0,
                right: 0,
                child: Center(
                  child: SelectionActionBar(
                    tr: tr,
                    onCopy: () async {
                      final t = sel.selectedText;
                      sel.clear();
                      await copyText(context, t, tr);
                      onDone?.call();
                    },
                    onSelectAll: sel.selectAll,
                    onShare: () {
                      final t = sel.selectedText;
                      sel.clear();
                      shareText(t);
                      onDone?.call();
                    },
                    onHighlight: onHighlight == null
                        ? null
                        : () {
                            final r = sel.highlightRects;
                            sel.clear();
                            onHighlight!(r);
                            onDone?.call();
                          },
                  ),
                ),
              ),
            ],
          );
        });
      },
    );
  }
}

class _HighlightPainter extends CustomPainter {
  _HighlightPainter(this.rects);
  final List<Rect> rects;

  @override
  void paint(Canvas canvas, Size size) {
    final p = Paint()..color = kTextSelectColor.withValues(alpha: 0.30);
    for (final r in rects) {
      canvas.drawRect(r, p);
    }
  }

  @override
  bool shouldRepaint(covariant _HighlightPainter old) => old.rects != rects;
}

/// 물방울 모양 손잡이: 앞 손잡이는 오른쪽 위 모서리, 뒤 손잡이는 왼쪽 위 모서리가 뾰족함
class TextSelectHandlePainter extends CustomPainter {
  TextSelectHandlePainter(this.start);
  final bool start;

  @override
  void paint(Canvas canvas, Size size) {
    final double r = size.width / 2;
    final p = Paint()..color = kTextSelectColor;
    canvas.drawCircle(Offset(r, r), r, p);
    canvas.drawRect(start ? Rect.fromLTWH(r, 0, r, r) : Rect.fromLTWH(0, 0, r, r), p);
  }

  @override
  bool shouldRepaint(covariant TextSelectHandlePainter old) => old.start != start;
}
