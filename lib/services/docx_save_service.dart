import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:xml/xml.dart';

/// DOCX 파일의 원본 ZIP 구조(이미지·표·머리말·스타일·관계 파일 등)를 그대로 보존하면서
/// 사용자가 수정한 문단만 `word/document.xml`의 `<w:p>` 노드에 반영해 안전하게 저장한다.
class DocxSaveService {
  static Future<bool> applyEditsToFile(String filePath, List<dynamic> edits) async {
    if (edits.isEmpty) return false;
    final File src = File(filePath);
    if (!await src.exists()) return false;

    final List<int> origBytes = await src.readAsBytes();
    final Archive archive = ZipDecoder().decodeBytes(origBytes);
    final ArchiveFile? docEntry = archive.findFile('word/document.xml');
    if (docEntry == null) return false;

    final String xmlText = utf8.decode(docEntry.content as List<int>, allowMalformed: true);
    final XmlDocument xmlDoc = XmlDocument.parse(xmlText);
    final List<XmlElement> allParas = xmlDoc.findAllElements('p', namespace: '*').where((e) => e.name.local == 'p').toList();

    bool changed = false;
    for (final dynamic raw in edits) {
      if (raw is! Map) continue;
      final int idx = (raw['index'] as num?)?.toInt() ?? -1;
      final String origText = _norm(raw['origText']?.toString() ?? '');
      final List<dynamic> runs = raw['runs'] is List ? raw['runs'] as List<dynamic> : const [];

      final XmlElement? target = _matchParagraph(allParas, idx, origText);
      if (target == null) continue;

      _replaceParagraphRuns(target, runs);
      changed = true;
    }

    if (!changed) return false;

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
    if (encoded == null || encoded.isEmpty) return false;

    final File tmp = File('$filePath.eri_tmp');
    await tmp.writeAsBytes(encoded, flush: true);
    await tmp.rename(filePath);
    return true;
  }

  static String _norm(String s) => s.replaceAll(RegExp(r'\s+'), ' ').trim();

  static String _paraText(XmlElement p) {
    final StringBuffer sb = StringBuffer();
    for (final XmlElement t in p.findAllElements('t', namespace: '*')) {
      if (t.name.local == 't') sb.write(t.innerText);
    }
    return _norm(sb.toString());
  }

  static XmlElement? _matchParagraph(List<XmlElement> allParas, int idx, String origText) {
    // 1) 인덱스 근처에서 원문 텍스트가 일치하는 문단을 우선 탐색
    if (origText.isNotEmpty) {
      if (idx >= 0 && idx < allParas.length && _paraText(allParas[idx]) == origText) {
        return allParas[idx];
      }
      int bestIdx = -1;
      int bestDist = 1 << 30;
      for (int i = 0; i < allParas.length; i++) {
        if (_paraText(allParas[i]) == origText) {
          final int d = idx >= 0 ? (i - idx).abs() : i;
          if (d < bestDist) {
            bestDist = d;
            bestIdx = i;
          }
        }
      }
      if (bestIdx >= 0) return allParas[bestIdx];
    }
    // 2) 빈 문단 등 텍스트 매칭이 안 되면 인덱스로 매칭
    if (idx >= 0 && idx < allParas.length) return allParas[idx];
    return null;
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
    final List<XmlNode> toRemove = para.children
        .where((n) => n is XmlElement && (n.name.local == 'r' || n.name.local == 'hyperlink'))
        .toList();
    for (final XmlNode n in toRemove) {
      para.children.remove(n);
    }

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

      final List<XmlNode> rChildren = [];
      if (rPrChildren.isNotEmpty) {
        rChildren.add(XmlElement(XmlName('rPr', 'w'), const [], rPrChildren));
      }

      final List<String> lines = text.split('\n');
      for (int i = 0; i < lines.length; i++) {
        if (i > 0) rChildren.add(XmlElement(XmlName('br', 'w')));
        if (lines[i].isNotEmpty) {
          rChildren.add(XmlElement(
            XmlName('t', 'w'),
            [XmlAttribute(XmlName('space', 'xml'), 'preserve')],
            [XmlText(lines[i])],
          ));
        }
      }

      para.children.add(XmlElement(XmlName('r', 'w'), const [], rChildren));
    }
  }
}
