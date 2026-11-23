import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:path_provider/path_provider.dart';
import 'package:xml/xml.dart';

/// 편집 가능한 한글(HWPX/HWP) 문단 한 개
class HwpxParagraph {
  HwpxParagraph({
    required this.sectionIndex,
    required this.paragraphIndex,
    required this.inTable,
    required this.originalText,
    String? text,
    this.isNew = false,
  }) : text = text ?? originalText;

  final int sectionIndex;
  final int paragraphIndex;
  final bool inTable;
  final String originalText;
  String text;
  final bool isNew;

  bool get isModified => isNew ? text.trim().isNotEmpty : text != originalText;
}

/// 편집 화면에 불러온 한글 문서 상태
class HwpxEditDocument {
  HwpxEditDocument({
    required this.sourcePath,
    required this.isNativeHwpx,
    required this.sectionNames,
    required this.paragraphs,
  });

  final String sourcePath;

  /// true: 원본이 ZIP 기반 HWPX (서식·표·이미지 XML을 그대로 유지한 채 수정된 문단만 치환)
  /// false: 구형 바이너리 HWP (추출한 본문을 표준 KS X 6101 HWPX 사본으로 생성)
  final bool isNativeHwpx;
  final List<String> sectionNames;
  final List<HwpxParagraph> paragraphs;

  bool get hasChanges => paragraphs.any((p) => p.isModified);
}

/// 100% 자체 구현 + 상업적 이용 허용 라이선스(Dart archive BSD-3-Clause, xml MIT) 기반
/// 한글(HWPX / KS X 6101 OWPML) 편집 및 사본 저장 서비스.
/// 원본 파일은 절대 덮어쓰지 않고 앱 서재 폴더에 `_편집본.hwpx` 사본으로 저장한다.
class HwpxEditorService {
  /// 파일이 ZIP 기반 HWPX인지 확인하고, HWPX라면 원본 XML에서 문단 목록을 불러온다.
  /// 구형 바이너리 HWP 등 HWPX가 아니면 null을 반환한다.
  static Future<HwpxEditDocument?> loadNativeHwpx(String filePath) async {
    final file = File(filePath);
    if (!await file.exists()) return null;
    final bytes = await file.readAsBytes();
    // ZIP 시그니처(PK\x03\x04) 확인 — 확장자가 .hwp여도 실제 내용이 HWPX인 경우도 지원
    if (bytes.length < 4 || bytes[0] != 0x50 || bytes[1] != 0x4B) return null;

    Archive archive;
    try {
      archive = ZipDecoder().decodeBytes(bytes);
    } catch (_) {
      return null;
    }

    final sectionFiles = archive.files
        .where((f) => f.isFile && RegExp(r'^Contents/section\d+\.xml$', caseSensitive: false).hasMatch(f.name))
        .toList()
      ..sort((a, b) => _sectionNumber(a.name).compareTo(_sectionNumber(b.name)));
    if (sectionFiles.isEmpty) return null;

    final List<HwpxParagraph> paragraphs = [];
    final List<String> sectionNames = [];

    for (int sIdx = 0; sIdx < sectionFiles.length; sIdx++) {
      final sf = sectionFiles[sIdx];
      sectionNames.add(sf.name);
      final raw = utf8.decode(sf.content as List<int>, allowMalformed: true);
      final doc = XmlDocument.parse(raw);

      int pIdx = 0;
      for (final pEl in _collectParagraphs(doc.rootElement)) {
        final textNodes = _directTextElementsOfParagraph(pEl);
        final String joined = textNodes.map((t) => t.innerText).join();
        final bool inTable = _isInsideTableCell(pEl);
        paragraphs.add(
          HwpxParagraph(
            sectionIndex: sIdx,
            paragraphIndex: pIdx,
            inTable: inTable,
            originalText: joined,
          ),
        );
        pIdx++;
      }
    }

    return HwpxEditDocument(
      sourcePath: filePath,
      isNativeHwpx: true,
      sectionNames: sectionNames,
      paragraphs: paragraphs,
    );
  }

  /// 구형 바이너리 HWP 파일용: 뷰어에서 추출한 페이지 텍스트로 편집 문서를 구성한다.
  /// 저장 시 표준 KS X 6101(.hwpx) 사본으로 내보낸다.
  static HwpxEditDocument fromPlainPages(String filePath, List<String> pages) {
    final List<HwpxParagraph> paragraphs = [];
    int pIdx = 0;
    for (final page in pages) {
      final lines = page.replaceAll('\r\n', '\n').split('\n');
      for (final line in lines) {
        final trimmed = line.trimRight();
        if (trimmed.isEmpty) continue;
        paragraphs.add(
          HwpxParagraph(
            sectionIndex: 0,
            paragraphIndex: pIdx++,
            inTable: false,
            originalText: trimmed,
          ),
        );
      }
    }
    if (paragraphs.isEmpty) {
      paragraphs.add(
        HwpxParagraph(
          sectionIndex: 0,
          paragraphIndex: 0,
          inTable: false,
          originalText: '',
        ),
      );
    }
    return HwpxEditDocument(
      sourcePath: filePath,
      isNativeHwpx: false,
      sectionNames: const ['Contents/section0.xml'],
      paragraphs: paragraphs,
    );
  }

  /// 편집한 내용을 원본을 건드리지 않고 앱 서재 폴더에 `<원본이름>_편집본.hwpx` 사본으로 저장한다.
  /// 저장된 사본의 절대 경로를 반환한다.
  static Future<String> saveCopy(HwpxEditDocument doc) async {
    final targetPath = await _nextCopyPath(doc.sourcePath);
    final List<int> outBytes = doc.isNativeHwpx
        ? await _buildModifiedHwpxBytes(doc)
        : _buildFreshHwpxBytes(doc.paragraphs);
    final outFile = File(targetPath);
    await outFile.writeAsBytes(outBytes, flush: true);
    return targetPath;
  }

  static Future<String> _nextCopyPath(String sourcePath) async {
    final appDir = await getApplicationDocumentsDirectory();
    final String rawName = sourcePath.split(Platform.pathSeparator).last;
    final String stem = rawName.replaceAll(RegExp(r'\.hwpx?$', caseSensitive: false), '');
    final String cleanStem = stem.replaceAll(RegExp(r'_편집본\d*$'), '');
    String candidate = '${appDir.path}${Platform.pathSeparator}${cleanStem}_편집본.hwpx';
    int n = 2;
    while (await File(candidate).exists()) {
      candidate = '${appDir.path}${Platform.pathSeparator}${cleanStem}_편집본$n.hwpx';
      n++;
    }
    return candidate;
  }

  static Future<List<int>> _buildModifiedHwpxBytes(HwpxEditDocument doc) async {
    final origBytes = await File(doc.sourcePath).readAsBytes();
    final origArchive = ZipDecoder().decodeBytes(origBytes);

    // 섹션별로 수정된 문단 및 새 문단을 정리
    final Map<int, Map<int, String>> editsBySection = {};
    final List<HwpxParagraph> addedParagraphs = [];
    for (final p in doc.paragraphs) {
      if (p.isNew) {
        if (p.text.trim().isNotEmpty) addedParagraphs.add(p);
      } else if (p.isModified) {
        editsBySection.putIfAbsent(p.sectionIndex, () => {})[p.paragraphIndex] = p.text;
      }
    }

    final int lastSectionIdx = doc.sectionNames.length - 1;
    final Map<String, List<int>> replacedContents = {};

    for (int sIdx = 0; sIdx < doc.sectionNames.length; sIdx++) {
      final sName = doc.sectionNames[sIdx];
      final edits = editsBySection[sIdx];
      final bool hasAdds = sIdx == lastSectionIdx && addedParagraphs.isNotEmpty;
      if ((edits == null || edits.isEmpty) && !hasAdds) continue;

      final sf = origArchive.files.firstWhere((f) => f.name == sName);
      final rawXml = utf8.decode(sf.content as List<int>, allowMalformed: true);
      final xmlDoc = XmlDocument.parse(rawXml);
      final pElements = _collectParagraphs(xmlDoc.rootElement);

      if (edits != null) {
        for (final entry in edits.entries) {
          final int idx = entry.key;
          if (idx < 0 || idx >= pElements.length) continue;
          _applyTextToParagraph(pElements[idx], entry.value);
        }
      }

      if (hasAdds) {
        final String hpPrefix = _detectHpPrefix(xmlDoc.rootElement);
        final String pTag = hpPrefix.isEmpty ? 'p' : '$hpPrefix:p';
        final String runTag = hpPrefix.isEmpty ? 'run' : '$hpPrefix:run';
        final String tTag = hpPrefix.isEmpty ? 't' : '$hpPrefix:t';
        for (final np in addedParagraphs) {
          final newP = XmlElement(
            XmlName.fromString(pTag),
            [
              XmlAttribute(XmlName('id'), '0'),
              XmlAttribute(XmlName('paraPrIDRef'), '0'),
              XmlAttribute(XmlName('styleIDRef'), '0'),
              XmlAttribute(XmlName('pageBreak'), '0'),
              XmlAttribute(XmlName('columnBreak'), '0'),
              XmlAttribute(XmlName('merged'), '0'),
            ],
            [
              XmlElement(
                XmlName.fromString(runTag),
                [XmlAttribute(XmlName('charPrIDRef'), '0')],
                [XmlElement(XmlName.fromString(tTag), [], [XmlText(np.text)])],
              ),
            ],
          );
          xmlDoc.rootElement.children.add(newP);
        }
      }

      replacedContents[sName] = utf8.encode(xmlDoc.toXmlString());
    }

    // OWPML/OCF 규격에 따라 mimetype을 맨 앞에 무압축(STORE)으로 기록
    final outArchive = Archive();
    final sortedFiles = List<ArchiveFile>.from(origArchive.files);
    sortedFiles.sort((a, b) {
      if (a.name == 'mimetype') return -1;
      if (b.name == 'mimetype') return 1;
      return 0;
    });

    for (final f in sortedFiles) {
      if (!f.isFile) continue;
      final List<int> data = replacedContents[f.name] ?? (f.content as List<int>);
      final af = ArchiveFile(f.name, data.length, data);
      if (f.name == 'mimetype') {
        af.compress = false;
      }
      outArchive.addFile(af);
    }

    return ZipEncoder().encode(outArchive)!;
  }

  /// 구형 바이너리 HWP에서 편집한 텍스트를 표준 KS X 6101(OWPML) HWPX 파일로 생성한다.
  static List<int> _buildFreshHwpxBytes(List<HwpxParagraph> paragraphs) {
    final outArchive = Archive();
    void addText(String name, String content, {bool compress = true}) {
      final bytes = utf8.encode(content);
      final af = ArchiveFile(name, bytes.length, bytes)..compress = compress;
      outArchive.addFile(af);
    }

    addText('mimetype', 'application/hwp+zip', compress: false);

    addText(
      'META-INF/container.xml',
      '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
      '<ocf:container xmlns:ocf="urn:oasis:names:tc:opendocument:xmlns:container" xmlns:hpf="http://www.hancom.co.kr/schema/2011/hpf">'
      '<ocf:rootfiles>'
      '<ocf:rootfile full-path="Contents/content.hpf" media-type="application/hwpml-package+xml"/>'
      '</ocf:rootfiles>'
      '</ocf:container>',
    );

    addText(
      'Contents/content.hpf',
      '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
      '<opf:package xmlns:opf="http://www.idpf.org/2007/opf/" version="" unique-identifier="" id="">'
      '<opf:metadata><opf:title>ERI Edited Document</opf:title><opf:language>ko</opf:language></opf:metadata>'
      '<opf:manifest>'
      '<opf:item id="header" href="Contents/header.xml" media-type="application/xml"/>'
      '<opf:item id="section0" href="Contents/section0.xml" media-type="application/xml"/>'
      '</opf:manifest>'
      '<opf:spine>'
      '<opf:itemref idref="header" linear="yes"/>'
      '<opf:itemref idref="section0" linear="yes"/>'
      '</opf:spine>'
      '</opf:package>',
    );

    addText(
      'Contents/header.xml',
      '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
      '<hh:head xmlns:hh="http://www.hancom.co.kr/hwpml/2011/head" xmlns:hc="http://www.hancom.co.kr/hwpml/2011/core" version="1.4" secCnt="1">'
      '<hh:beginNum page="1" footnote="1" endnote="1" pic="1" tbl="1" equation="1"/>'
      '<hh:refList>'
      '<hh:fontfaces itemCnt="1">'
      '<hh:fontface lang="HANGUL" fontCnt="1"><hh:font id="0" face="함초롬바탕" type="TTF" isEmbedded="0"/></hh:fontface>'
      '</hh:fontfaces>'
      '<hh:charProperties itemCnt="1">'
      '<hh:charPr id="0" height="1000" textColor="#000000" shadeColor="none" useFontSpace="0" useKerning="0" symMark="NONE" borderFillIDRef="0">'
      '<hh:fontRef hangul="0" latin="0" hanja="0" japanese="0" other="0" symbol="0" user="0"/>'
      '</hh:charPr>'
      '</hh:charProperties>'
      '<hh:paraProperties itemCnt="1">'
      '<hh:paraPr id="0" tabPrIDRef="0" condense="0" fontLineHeight="0" snapToGrid="1" suppressLineNumbers="0" checked="0">'
      '<hh:align horizontal="JUSTIFY" vertical="BASELINE"/>'
      '<hh:lineSpacing type="PERCENT" value="160" unit="HWPUNIT"/>'
      '</hh:paraPr>'
      '</hh:paraProperties>'
      '<hh:styles itemCnt="1">'
      '<hh:style id="0" type="PARA" name="바탕글" engName="Normal" paraPrIDRef="0" charPrIDRef="0" nextStyleIDRef="0" langID="1042" lockForm="0"/>'
      '</hh:styles>'
      '</hh:refList>'
      '</hh:head>',
    );

    final buf = StringBuffer()
      ..write('<?xml version="1.0" encoding="UTF-8" standalone="yes"?>')
      ..write('<hs:sec xmlns:hs="http://www.hancom.co.kr/hwpml/2011/section" xmlns:hp="http://www.hancom.co.kr/hwpml/2011/paragraph">');
    for (int i = 0; i < paragraphs.length; i++) {
      final text = paragraphs[i].text;
      if (paragraphs[i].isNew && text.trim().isEmpty) continue;
      buf.write(
        '<hp:p id="$i" paraPrIDRef="0" styleIDRef="0" pageBreak="0" columnBreak="0" merged="0">'
        '<hp:run charPrIDRef="0"><hp:t>${_xmlEscape(text)}</hp:t></hp:run>'
        '</hp:p>',
      );
    }
    buf.write('</hs:sec>');
    addText('Contents/section0.xml', buf.toString());

    return ZipEncoder().encode(outArchive)!;
  }

  static int _sectionNumber(String name) {
    final m = RegExp(r'section(\d+)\.xml$', caseSensitive: false).firstMatch(name);
    return m == null ? 0 : (int.tryParse(m.group(1)!) ?? 0);
  }

  /// 문서 순서대로 모든 문단(<hp:p>) 수집 (표 셀 내부 문단 포함)
  static List<XmlElement> _collectParagraphs(XmlElement root) {
    final List<XmlElement> out = [];
    void walk(XmlElement el) {
      if (el.name.local == 'p') {
        out.add(el);
      }
      for (final child in el.childElements) {
        walk(child);
      }
    }
    walk(root);
    return out;
  }

  /// 해당 문단(<hp:p>)에 직접 속한 <hp:run> 내부의 <hp:t> 요소만 추출 (하위 표 셀 <hp:tbl> 내부는 제외)
  static List<XmlElement> _directTextElementsOfParagraph(XmlElement pEl) {
    final List<XmlElement> out = [];
    for (final child in pEl.childElements) {
      if (child.name.local == 'run') {
        for (final sub in child.childElements) {
          if (sub.name.local == 't') out.add(sub);
        }
      } else if (child.name.local == 't') {
        out.add(child);
      }
    }
    return out;
  }

  static bool _isInsideTableCell(XmlElement pEl) {
    XmlNode? cur = pEl.parent;
    while (cur is XmlElement) {
      if (cur.name.local == 'tc') return true;
      cur = cur.parent;
    }
    return false;
  }

  static String _detectHpPrefix(XmlElement root) {
    for (final p in _collectParagraphs(root)) {
      if (p.name.prefix != null && p.name.prefix!.isNotEmpty) return p.name.prefix!;
    }
    return 'hp';
  }

  static void _applyTextToParagraph(XmlElement pEl, String newText) {
    final textNodes = _directTextElementsOfParagraph(pEl);
    if (textNodes.isNotEmpty) {
      textNodes.first.children
        ..clear()
        ..add(XmlText(newText));
      for (int i = 1; i < textNodes.length; i++) {
        textNodes[i].children.clear();
      }
      return;
    }
    final String prefix = pEl.name.prefix ?? 'hp';
    final String runTag = prefix.isEmpty ? 'run' : '$prefix:run';
    final String tTag = prefix.isEmpty ? 't' : '$prefix:t';
    final runs = pEl.childElements.where((e) => e.name.local == 'run');
    final existingRun = runs.isEmpty ? null : runs.first;
    final tEl = XmlElement(XmlName.fromString(tTag), [], [XmlText(newText)]);
    if (existingRun != null) {
      existingRun.children.add(tEl);
    } else {
      pEl.children.add(XmlElement(XmlName.fromString(runTag), [XmlAttribute(XmlName('charPrIDRef'), '0')], [tEl]));
    }
  }

  static String _xmlEscape(String s) => s
      .replaceAll('&', '&amp;')
      .replaceAll('<', '&lt;')
      .replaceAll('>', '&gt;')
      .replaceAll('"', '&quot;')
      .replaceAll("'", '&apos;');
}
