import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:archive/archive.dart';
import 'package:xml/xml.dart';

/// DOCX 파일의 원본 ZIP 구조(이미지·표·머리말·스타일·관계 파일 등)를 그대로 보존하면서
/// 사용자가 바꾼 문단만 `word/document.xml`의 `<w:p>`에 반영해 안전하게 저장한다.
///
/// - 바뀌지 않은 문단은 손대지 않음 (목록 번호·수식·그림·링크 서식 유지)
/// - 글자만 바뀐 문단은 원래 글자 덩어리(<w:r>)의 서식을 그대로 둔 채 바뀐 부분만 고침
/// - 글자 서식을 바꾼 문단만 글자 덩어리를 새로 만듦
/// - 지운 문단은 문서에서도 뺌
class DocxSaveService {
  static const String _wNs = 'http://schemas.openxmlformats.org/wordprocessingml/2006/main';

  static Future<bool> applyEditsToFile(String filePath, List<dynamic> edits) async {
    if (edits.isEmpty) return false;
    final File src = File(filePath);
    if (!await src.exists()) return false;

    final List<int> origBytes = await src.readAsBytes();
    final List<int>? encoded = applyEditsToBytes(origBytes, edits);
    if (encoded == null) return false;

    final File tmp = File('$filePath.eri_tmp');
    await tmp.writeAsBytes(encoded, flush: true);
    await tmp.rename(filePath);
    return true;
  }

  /// 바꾼 내용을 반영한 새 DOCX 바이트 (바꿀 것이 없으면 null)
  static List<int>? applyEditsToBytes(List<int> origBytes, List<dynamic> edits) {
    final Archive archive = ZipDecoder().decodeBytes(origBytes);
    final ArchiveFile? docEntry = archive.findFile('word/document.xml');
    if (docEntry == null) return null;

    final String xmlText = utf8.decode(docEntry.content as List<int>, allowMalformed: true);
    final XmlDocument xmlDoc = XmlDocument.parse(xmlText);
    // 세로로 합친 표 칸의 이어지는 칸(vMerge continue)은 화면에 그려지지 않으므로 문단 번호에서 뺌
    final List<XmlElement> allParas = xmlDoc.findAllElements('p', namespace: _wNs).where((p) => !_inMergedCell(p)).toList();
    final List<String> keys = [for (final p in allParas) _key(_slotText(p, null))];

    // 고치기 전에 대상 문단부터 모두 찾아 둠 (지우거나 고치면 순서·글자가 바뀌므로)
    final Set<int> used = {};
    final List<(XmlElement, Map<dynamic, dynamic>)> jobs = [];
    for (final dynamic raw in edits) {
      if (raw is! Map) continue;
      final int idx = (raw['index'] as num?)?.toInt() ?? -1;
      final int found = _matchParagraph(keys, idx, _key(raw['origText']?.toString() ?? ''), used);
      if (found < 0) continue;
      used.add(found);
      jobs.add((allParas[found], raw));
    }

    bool changed = false;
    for (final (XmlElement para, Map<dynamic, dynamic> raw) in jobs) {
      if (raw['deleted'] == true) {
        _deleteParagraph(para);
        changed = true;
        continue;
      }
      final String origText = raw['origText']?.toString() ?? '';
      final String newText = raw['text']?.toString() ?? '';
      final bool fmt = raw['fmt'] == true;
      final List<dynamic> runs = raw['runs'] is List ? raw['runs'] as List<dynamic> : const [];
      if (_applyEdit(para, origText, newText, fmt, runs)) changed = true;
    }

    if (!changed) return null;

    final List<int> newDocBytes = utf8.encode(xmlDoc.toXmlString(pretty: false));
    final Archive outArchive = Archive();
    for (final ArchiveFile f in archive.files) {
      if (f.name == 'word/document.xml') {
        outArchive.addFile(ArchiveFile('word/document.xml', newDocBytes.length, newDocBytes));
      } else {
        outArchive.addFile(f);
      }
    }

    final List<int>? encoded = ZipEncoder().encode(outArchive);
    if (encoded == null || encoded.isEmpty) return null;
    return encoded;
  }

  static bool _inMergedCell(XmlElement p) {
    for (XmlNode? a = p.parent; a != null; a = a.parent) {
      if (a is XmlElement && _isW(a, 'tc')) {
        final XmlElement? tcPr = a.childElements.where((e) => _isW(e, 'tcPr')).firstOrNull;
        final XmlElement? vm = tcPr?.childElements.where((e) => _isW(e, 'vMerge')).firstOrNull;
        if (vm != null) {
          final String val = vm.getAttribute('val', namespace: _wNs) ?? 'continue';
          if (val == 'continue') return true;
        }
      }
    }
    return false;
  }

  /// 문단 비교용 열쇠 (빈칸 차이는 무시)
  static String _key(String s) => s.replaceAll(RegExp(r'\s+'), '');

  static bool _isW(XmlElement e, String local) => e.name.local == local && e.name.namespaceUri == _wNs;

  /// 화면에 보이는 순서대로 문단 글자를 모음. slots를 주면 글자가 들어 있는 자리(<w:t>·<w:tab>·<w:br>)도 함께 모음.
  /// 수식(m:)·그림·지운 글자(w:del)·필드 명령은 화면 글자에 없으므로 뺌.
  static String _slotText(XmlElement p, List<_Slot>? slots) {
    final StringBuffer sb = StringBuffer();
    void add(XmlElement el, String text, bool isText) {
      slots?.add(_Slot(el, sb.length, text.length, isText));
      sb.write(text);
    }

    void walkRun(XmlElement r) {
      for (final XmlElement c in r.childElements) {
        if (c.name.namespaceUri != _wNs) continue;
        switch (c.name.local) {
          case 't':
            add(c, c.innerText, true);
          case 'tab':
            add(c, '\t', false);
          case 'br':
            final String type = c.getAttribute('type', namespace: _wNs) ?? '';
            if (type.isEmpty || type == 'textWrapping') add(c, '\n', false);
          case 'cr':
            add(c, '\n', false);
          case 'noBreakHyphen':
            add(c, '-', false);
          default:
            break;
        }
      }
    }

    void walk(XmlElement e) {
      for (final XmlElement c in e.childElements) {
        if (c.name.namespaceUri != _wNs) continue;
        switch (c.name.local) {
          case 'r':
            walkRun(c);
          case 'hyperlink':
          case 'ins':
          case 'moveTo':
          case 'smartTag':
          case 'fldSimple':
          case 'customXml':
          case 'sdt':
          case 'sdtContent':
            walk(c);
          default:
            break;
        }
      }
    }

    walk(p);
    return sb.toString();
  }

  static int _matchParagraph(List<String> keys, int idx, String key, Set<int> used) {
    // 1) 같은 번호의 문단 글자가 같으면 그대로
    if (idx >= 0 && idx < keys.length && !used.contains(idx) && keys[idx] == key) return idx;
    // 2) 번호가 어긋났으면 가장 가까운, 글자가 같은 문단 (빈 문단은 번호가 맞을 때만)
    if (key.isEmpty) return -1;
    int best = -1;
    int bestDist = 1 << 30;
    for (int i = 0; i < keys.length; i++) {
      if (used.contains(i) || keys[i] != key) continue;
      final int d = idx >= 0 ? (i - idx).abs() : i;
      if (d < bestDist) {
        bestDist = d;
        best = i;
      }
    }
    return best;
  }

  /// 글자 덩어리·책갈피 등 평범한 글만 든 문단인지 (그림·수식·링크·필드가 있으면 false)
  static bool _isPlain(XmlElement p) {
    const plainRunChildren = {'rPr', 't', 'tab', 'br', 'cr', 'lastRenderedPageBreak', 'noBreakHyphen', 'softHyphen'};
    const plainParaChildren = {'pPr', 'proofErr', 'bookmarkStart', 'bookmarkEnd', 'permStart', 'permEnd'};
    for (final XmlElement c in p.childElements) {
      if (c.name.namespaceUri != _wNs) return false;
      if (c.name.local == 'r') {
        for (final XmlElement rc in c.childElements) {
          if (rc.name.namespaceUri != _wNs || !plainRunChildren.contains(rc.name.local)) return false;
        }
        continue;
      }
      if (!plainParaChildren.contains(c.name.local)) return false;
    }
    return true;
  }

  static void _deleteParagraph(XmlElement p) {
    final XmlNode? parent = p.parent;
    bool keepShell = parent == null;
    // 구역 설정이 든 문단은 쪽 설정이 사라지지 않게 글자만 비움
    final XmlElement? pPr = p.childElements.where((e) => _isW(e, 'pPr')).firstOrNull;
    if (pPr != null && pPr.childElements.any((e) => _isW(e, 'sectPr'))) keepShell = true;
    // 표 칸에는 문단이 하나는 있어야 함
    if (parent is XmlElement && _isW(parent, 'tc') && parent.childElements.where((e) => _isW(e, 'p')).length <= 1) {
      keepShell = true;
    }
    if (keepShell) {
      p.children.removeWhere((n) => !(n is XmlElement && _isW(n, 'pPr')));
    } else {
      parent!.children.remove(p);
    }
  }

  static bool _applyEdit(XmlElement p, String origText, String newText, bool fmt, List<dynamic> runs) {
    final bool plain = _isPlain(p);
    if (fmt && plain && runs.isNotEmpty) {
      _replaceParagraphRuns(p, runs);
      return true;
    }
    final List<_Slot> slots = [];
    final String xmlText = _slotText(p, slots);
    if (xmlText == origText) {
      _patchText(p, slots, origText, newText);
      return true;
    }
    if (plain) {
      if (runs.isNotEmpty) {
        _replaceParagraphRuns(p, runs);
      } else {
        _replaceWithText(p, newText);
      }
      return true;
    }
    return false; // 그림·수식이 든 문단인데 글자 자리를 맞출 수 없으면 원본을 망가뜨리지 않게 그대로 둠
  }

  static XmlElement _newT(String text) => XmlElement(
        XmlName('t', 'w'),
        [XmlAttribute(XmlName('space', 'xml'), 'preserve')],
        [XmlText(text)],
      );

  static void _setT(XmlElement t, String text) {
    t.children.clear();
    if (text.isNotEmpty) t.children.add(XmlText(text));
    t.setAttribute('xml:space', 'preserve');
  }

  static void _insertAfter(XmlNode anchor, XmlNode node) {
    final XmlNode parent = anchor.parent!;
    parent.children.insert(parent.children.indexOf(anchor) + 1, node);
  }

  static void _insertBefore(XmlNode anchor, XmlNode node) {
    final XmlNode parent = anchor.parent!;
    parent.children.insert(parent.children.indexOf(anchor), node);
  }

  /// <w:t>의 off 자리에 글자를 끼움 (줄바꿈은 같은 덩어리 안의 <w:br/>로)
  static void _insertInto(XmlElement t, int off, String text) {
    final String cur = t.innerText;
    final int at = off.clamp(0, cur.length);
    final String left = cur.substring(0, at);
    final String right = cur.substring(at);
    final List<String> parts = text.split('\n');
    if (parts.length == 1) {
      _setT(t, left + text + right);
      return;
    }
    _setT(t, left + parts.first);
    XmlNode cursor = t;
    for (int i = 1; i < parts.length; i++) {
      final XmlElement br = XmlElement(XmlName('br', 'w'));
      _insertAfter(cursor, br);
      final XmlElement nt = _newT(parts[i] + (i == parts.length - 1 ? right : ''));
      _insertAfter(br, nt);
      cursor = nt;
    }
  }

  /// 원래 글자와 새 글자를 견주어 바뀐 부분만 고침 → 나머지 글자 덩어리 서식은 그대로
  static void _patchText(XmlElement p, List<_Slot> slots, String orig, String now) {
    final int maxA = math.min(orig.length, now.length);
    int a = 0;
    while (a < maxA && orig.codeUnitAt(a) == now.codeUnitAt(a)) {
      a++;
    }
    int b = 0;
    while (b < orig.length - a && b < now.length - a && orig.codeUnitAt(orig.length - 1 - b) == now.codeUnitAt(now.length - 1 - b)) {
      b++;
    }
    final int ds = a;
    final int de = orig.length - b;
    final String ins = now.substring(a, now.length - b);
    if (ds == de && ins.isEmpty) return;

    // 1) 끼울 자리를 먼저 정함 (지울 자리는 a부터라 그 앞 글자 위치는 변하지 않음)
    final _Slot? prev = slots.where((s) => s.start < a && a <= s.start + s.len).firstOrNull;
    final _Slot? at = slots.where((s) => s.start == a && s.len > 0).firstOrNull;

    // 2) 지우기: 글자는 잘라 내고, 칸 띄움·줄바꿈 자리는 나중에 뺌
    final List<XmlElement> removeLater = [];
    if (de > ds) {
      for (final _Slot s in slots) {
        final int from = math.max(ds - s.start, 0);
        final int to = math.min(de - s.start, s.len);
        if (to <= from) continue;
        if (s.isText) {
          final String t = s.el.innerText;
          _setT(s.el, t.substring(0, from) + t.substring(to));
        } else {
          removeLater.add(s.el);
        }
      }
    }

    // 3) 끼우기
    if (ins.isNotEmpty) {
      if (prev != null && prev.isText) {
        _insertInto(prev.el, a - prev.start, ins);
      } else if (at != null && at.isText) {
        _insertInto(at.el, 0, ins);
      } else if (at != null) {
        final XmlElement nt = _newT('');
        _insertBefore(at.el, nt);
        _insertInto(nt, 0, ins);
      } else if (prev != null) {
        final XmlElement nt = _newT('');
        _insertAfter(prev.el, nt);
        _insertInto(nt, 0, ins);
      } else {
        // 글자가 하나도 없던 문단: 문단 기본 글자 서식으로 새 덩어리
        final XmlElement nt = _newT('');
        final List<XmlNode> rChildren = [];
        final XmlElement? pRPr = p.childElements
            .where((e) => _isW(e, 'pPr'))
            .expand((e) => e.childElements)
            .where((e) => _isW(e, 'rPr'))
            .firstOrNull;
        if (pRPr != null) {
          final XmlElement rPr = XmlElement(XmlName('rPr', 'w'));
          for (final XmlElement c in pRPr.childElements) {
            if (c.name.local == 'ins' || c.name.local == 'del' || c.name.local == 'rPrChange') continue;
            rPr.children.add(c.copy());
          }
          if (rPr.children.isNotEmpty) rChildren.add(rPr);
        }
        rChildren.add(nt);
        final XmlElement run = XmlElement(XmlName('r', 'w'), const [], rChildren);
        final int insertAt = p.children.indexWhere((n) => n is XmlElement && _isW(n, 'pPr')) + 1;
        p.children.insert(insertAt, run);
        _insertInto(nt, 0, ins);
      }
    }
    for (final XmlElement el in removeLater) {
      el.parent?.children.remove(el);
    }
  }

  /// 평범한 문단 글자를 통째로 바꿈 (첫 글자 덩어리 서식을 그대로 씀)
  static void _replaceWithText(XmlElement para, String text) {
    final XmlElement? firstRun = para.childElements.where((e) => _isW(e, 'r')).firstOrNull;
    final XmlElement? rPr = firstRun?.childElements.where((e) => _isW(e, 'rPr')).firstOrNull;
    para.children.removeWhere((n) => n is XmlElement && _isW(n, 'r'));
    if (text.isEmpty) return;
    final XmlElement nt = _newT('');
    final XmlElement run = XmlElement(XmlName('r', 'w'), const [], [if (rPr != null) rPr.copy(), nt]);
    para.children.add(run);
    _insertInto(nt, 0, text);
  }

  static void _replaceParagraphRuns(XmlElement para, List<dynamic> runs) {
    // 기존 문단의 첫 번째 <w:rPr>에서 글꼴(rFonts) 등 기본 속성을 참고해 보존
    XmlElement? templateRPr;
    for (final XmlNode child in para.children) {
      if (child is XmlElement && child.name.local == 'r') {
        final rPr = child.childElements.where((e) => e.name.local == 'rPr').firstOrNull;
        if (rPr != null) {
          templateRPr = rPr;
          break;
        }
      }
    }

    // 글자 크기가 커졌을 때 고정(exact) 줄 간격으로 글자가 겹치지 않도록 auto 줄 간격으로 완화
    final bool hasCustomSize = runs.any((r) => r is Map && (r['fontSizePt'] as num?) != null && (r['fontSizePt'] as num) > 12);
    if (hasCustomSize) {
      for (final XmlElement pPr in para.childElements.where((e) => e.name.local == 'pPr')) {
        for (final XmlElement sp in pPr.childElements.where((e) => e.name.local == 'spacing')) {
          final ruleAttr = sp.attributes.where((a) => a.name.local == 'lineRule').firstOrNull;
          if (ruleAttr != null && ruleAttr.value == 'exact') {
            sp.setAttribute('w:lineRule', 'auto');
          }
        }
      }
    }

    // <w:pPr>(정렬·줄간격·들여쓰기 등)는 유지하고 기존 <w:r>만 교체
    para.children.removeWhere((n) => n is XmlElement && _isW(n, 'r'));

    for (final dynamic rawRun in runs) {
      if (rawRun is! Map) continue;
      final String text = rawRun['text']?.toString() ?? '';
      if (text.isEmpty) continue;

      final List<XmlNode> rPrChildren = [];
      if (templateRPr != null) {
        for (final XmlElement el in templateRPr.childElements) {
          if (el.name.local == 'rFonts' || el.name.local == 'lang') {
            rPrChildren.add(el.copy());
          }
        }
      }

      if (rawRun['bold'] == true) {
        rPrChildren.add(XmlElement(XmlName('b', 'w')));
      }
      if (rawRun['italic'] == true) {
        rPrChildren.add(XmlElement(XmlName('i', 'w')));
      }
      if (rawRun['underline'] == true) {
        rPrChildren.add(XmlElement(
          XmlName('u', 'w'),
          [XmlAttribute(XmlName('val', 'w'), 'single')],
        ));
      }
      final num? fsPt = rawRun['fontSizePt'] as num?;
      if (fsPt != null && fsPt > 0) {
        final String halfPts = (fsPt * 2).round().toString();
        rPrChildren.add(XmlElement(
          XmlName('sz', 'w'),
          [XmlAttribute(XmlName('val', 'w'), halfPts)],
        ));
        rPrChildren.add(XmlElement(
          XmlName('szCs', 'w'),
          [XmlAttribute(XmlName('val', 'w'), halfPts)],
        ));
      }
      final String? colorHex = rawRun['colorHex']?.toString();
      if (colorHex != null && colorHex.isNotEmpty) {
        final String hex = colorHex.replaceFirst('#', '').toUpperCase();
        if (RegExp(r'^[0-9A-F]{6}$').hasMatch(hex)) {
          rPrChildren.add(XmlElement(
            XmlName('color', 'w'),
            [XmlAttribute(XmlName('val', 'w'), hex)],
          ));
        }
      }

      final XmlElement nt = _newT('');
      final XmlElement run = XmlElement(XmlName('r', 'w'), const [], [
        if (rPrChildren.isNotEmpty) XmlElement(XmlName('rPr', 'w'), const [], rPrChildren),
        nt,
      ]);
      para.children.add(run);
      _insertInto(nt, 0, text);
    }
  }
}

class _Slot {
  final XmlElement el;
  final int start;
  final int len;
  final bool isText;
  const _Slot(this.el, this.start, this.len, this.isText);
}
