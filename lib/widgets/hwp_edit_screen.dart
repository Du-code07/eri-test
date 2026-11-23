import 'dart:io';

import 'package:flutter/material.dart';

import '../services/file_share.dart';
import '../services/hwpx_editor_service.dart';
import '../services/storage_service.dart';
import 'app_colors.dart';

/// 도구 모음의 '한글 편집' 단추를 눌렀을 때 열리는 전용 편집 화면.
/// 원본은 건드리지 않고 사본(.hwpx)으로 저장한 뒤 바로 공유하거나 열어볼 수 있다.
class HwpEditScreen extends StatefulWidget {
  const HwpEditScreen({super.key, required this.document});

  final HwpxEditDocument document;

  @override
  State<HwpEditScreen> createState() => _HwpEditScreenState();
}

class _HwpEditScreenState extends State<HwpEditScreen> {
  final TextEditingController _searchCtrl = TextEditingController();
  final List<TextEditingController> _controllers = [];
  String _query = '';
  bool _saving = false;

  String _tr(String ko, String en, String zh, String ja) =>
      AppI18n.t(StorageService.appLangNotifier.value, ko: ko, en: en, zh: zh, ja: ja);

  @override
  void initState() {
    super.initState();
    for (final p in widget.document.paragraphs) {
      _controllers.add(TextEditingController(text: p.text));
    }
  }

  @override
  void dispose() {
    _searchCtrl.dispose();
    for (final c in _controllers) {
      c.dispose();
    }
    super.dispose();
  }

  void _addParagraph() {
    final int lastSec = widget.document.sectionNames.isEmpty ? 0 : widget.document.sectionNames.length - 1;
    final p = HwpxParagraph(
      sectionIndex: lastSec,
      paragraphIndex: widget.document.paragraphs.length,
      inTable: false,
      originalText: '',
      text: '',
      isNew: true,
    );
    setState(() {
      widget.document.paragraphs.add(p);
      _controllers.add(TextEditingController());
    });
  }

  Future<bool> _confirmLeaveIfDirty() async {
    if (!widget.document.hasChanges) return true;
    final ok = await showCenterDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(_tr('편집을 취소할까요?', 'Discard edits?', '放弃编辑吗？', '編集を破棄しますか？')),
        content: Text(_tr('저장하지 않은 수정 내용은 사라져요', 'Unsaved changes will be lost', '未保存的修改将会丢失', '保存していない変更は失われます')),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: Text(_tr('계속 편집', 'Keep editing', '继续编辑', '編集を続ける'))),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(_tr('나가기', 'Discard', '退出', '破棄')),
          ),
        ],
      ),
    );
    return ok == true;
  }

  Future<void> _saveCopy() async {
    if (_saving) return;
    setState(() => _saving = true);
    try {
      final String savedPath = await HwpxEditorService.saveCopy(widget.document);
      if (!mounted) return;
      final String savedName = savedPath.split(Platform.pathSeparator).last;
      final String? action = await showCenterDialog<String>(
        context: context,
        builder: (ctx) {
          final cs = Theme.of(ctx).colorScheme;
          return AlertDialog(
            title: Text(_tr('사본으로 저장했어요', 'Saved as a copy', '已保存为副本', 'コピーとして保存しました')),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(savedName, style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 15)),
                const SizedBox(height: 8),
                Text(
                  _tr(
                    '원본은 그대로 두고 내 서재에 사본을 저장했어요. 바로 공유해 내보내거나 사본을 열어볼 수 있어요',
                    'The original file is untouched and the copy was saved to your library. You can share or open it now',
                    '原文件保持不变，副本已保存到书架。您可以立即分享导出或打开副本',
                    '元のファイルはそのままに、本棚へコピーを保存しました。すぐ共有したり開いたりできます',
                  ),
                  style: TextStyle(fontSize: 13.5, color: cs.onSurfaceVariant, height: 1.45),
                ),
              ],
            ),
            actions: [
              TextButton(onPressed: () => Navigator.pop(ctx, 'close'), child: Text(_tr('닫기', 'Close', '关闭', '閉じる'))),
              TextButton(onPressed: () => Navigator.pop(ctx, 'open'), child: Text(_tr('사본 열기', 'Open copy', '打开副本', 'コピーを開く'))),
              FilledButton.icon(
                onPressed: () => Navigator.pop(ctx, 'share'),
                icon: const Icon(Icons.share_outlined, size: 18),
                label: Text(_tr('공유하기', 'Share', '分享', '共有')),
              ),
            ],
          );
        },
      );
      if (!mounted) return;
      if (action == 'share') {
        await shareFile(context, savedPath, title: savedName);
        if (mounted) Navigator.pop(context, null);
      } else if (action == 'open') {
        Navigator.pop(context, savedPath);
      } else {
        Navigator.pop(context, null);
      }
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(_tr('사본 저장에 실패했어요: $e', 'Failed to save copy: $e', '保存副本失败：$e', 'コピーの保存に失敗しました：$e'))),
      );
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final Color sig = AppColors.of(context);
    final String fileName = widget.document.sourcePath.split(Platform.pathSeparator).last;
    final String q = _query.trim().toLowerCase();
    final List<int> visibleIndices = [
      for (int i = 0; i < widget.document.paragraphs.length; i++)
        if (q.isEmpty || widget.document.paragraphs[i].text.toLowerCase().contains(q)) i,
    ];
    final int changedCount = widget.document.paragraphs.where((p) => p.isModified).length;

    return PopScope(
      canPop: !widget.document.hasChanges,
      onPopInvokedWithResult: (didPop, _) async {
        if (didPop) return;
        if (await _confirmLeaveIfDirty() && mounted) Navigator.pop(context);
      },
      child: Scaffold(
        appBar: AppBar(
          leading: IconButton(
            icon: const Icon(Icons.close),
            onPressed: () async {
              if (await _confirmLeaveIfDirty() && mounted) Navigator.pop(context);
            },
          ),
          titleSpacing: 0,
          title: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(_tr('한글 편집', 'Edit HWP', '编辑 HWP', 'HWP編集'), style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w800)),
              Text(fileName, maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant)),
            ],
          ),
          actions: [
            Padding(
              padding: const EdgeInsets.only(right: 12),
              child: FilledButton(
                onPressed: (_saving || !widget.document.hasChanges) ? null : _saveCopy,
                style: FilledButton.styleFrom(
                  padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                  visualDensity: VisualDensity.compact,
                ),
                child: _saving
                    ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                    : Text(
                        changedCount > 0
                            ? _tr('사본 저장 ($changedCount)', 'Save copy ($changedCount)', '保存副本 ($changedCount)', 'コピー保存 ($changedCount)')
                            : _tr('사본 저장', 'Save copy', '保存副本', 'コピー保存'),
                      ),
              ),
            ),
          ],
        ),
        body: Column(
          children: [
            Container(
              width: double.infinity,
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
              color: sig.withValues(alpha: 0.14),
              child: Row(
                children: [
                  Icon(Icons.info_outline_rounded, size: 17, color: cs.onSurfaceVariant),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      widget.document.isNativeHwpx
                          ? _tr(
                              '원본 서식·표·이미지를 유지한 채 수정한 내용만 사본(.hwpx)으로 저장해요',
                              'Original layout, tables, and images stay intact in the saved .hwpx copy',
                              '保留原格式、表格与图片，仅将修改内容保存为 .hwpx 副本',
                              '元の書式・表・画像を保ったまま変更内容のみコピー(.hwpx)として保存します',
                            )
                          : _tr(
                              '구형 HWP 파일은 수정한 내용을 표준 HWPX 사본으로 저장해요',
                              'Legacy HWP edits are saved as a standard .hwpx copy',
                              '旧版 HWP 文件的修改将保存为标准 .hwpx 副本',
                              '旧形式HWPの編集内容は標準HWPXコピーとして保存されます',
                            ),
                      style: TextStyle(fontSize: 12.5, color: cs.onSurfaceVariant, height: 1.35),
                    ),
                  ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 10, 16, 6),
              child: TextField(
                controller: _searchCtrl,
                onChanged: (v) => setState(() => _query = v),
                decoration: InputDecoration(
                  isDense: true,
                  prefixIcon: const Icon(Icons.search, size: 20),
                  suffixIcon: _query.isNotEmpty
                      ? IconButton(
                          icon: const Icon(Icons.clear, size: 18),
                          onPressed: () {
                            _searchCtrl.clear();
                            setState(() => _query = '');
                          },
                        )
                      : null,
                  hintText: _tr('수정할 문장 검색', 'Search text to edit', '搜索要修改的内容', '編集する文を検索'),
                  border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
                  contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                ),
              ),
            ),
            Expanded(
              child: ListView.builder(
                padding: const EdgeInsets.fromLTRB(16, 6, 16, 28),
                itemCount: visibleIndices.length + 1,
                itemBuilder: (context, idx) {
                  if (idx == visibleIndices.length) {
                    return Padding(
                      padding: const EdgeInsets.only(top: 8),
                      child: OutlinedButton.icon(
                        onPressed: _addParagraph,
                        icon: const Icon(Icons.add_rounded, size: 18),
                        label: Text(_tr('문단 추가', 'Add paragraph', '添加段落', '段落を追加')),
                      ),
                    );
                  }
                  final int pIndex = visibleIndices[idx];
                  final HwpxParagraph p = widget.document.paragraphs[pIndex];
                  final bool edited = p.isModified;
                  return Container(
                    margin: const EdgeInsets.only(bottom: 10),
                    padding: const EdgeInsets.fromLTRB(12, 8, 12, 10),
                    decoration: BoxDecoration(
                      color: cs.surfaceContainerLowest,
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(
                        color: edited ? sig : cs.outlineVariant.withValues(alpha: 0.65),
                        width: edited ? 1.6 : 1,
                      ),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            Text(
                              p.isNew
                                  ? _tr('새 문단', 'New paragraph', '新段落', '新しい段落')
                                  : _tr('문단 ${pIndex + 1}', 'Paragraph ${pIndex + 1}', '段落 ${pIndex + 1}', '段落 ${pIndex + 1}'),
                              style: TextStyle(fontSize: 11.5, fontWeight: FontWeight.w700, color: cs.onSurfaceVariant),
                            ),
                            if (p.inTable) ...[
                              const SizedBox(width: 6),
                              Container(
                                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1.5),
                                decoration: BoxDecoration(
                                  color: cs.surfaceContainerHighest,
                                  borderRadius: BorderRadius.circular(6),
                                ),
                                child: Text(_tr('표', 'Table', '表格', '表'), style: TextStyle(fontSize: 10.5, fontWeight: FontWeight.w700, color: cs.onSurfaceVariant)),
                              ),
                            ],
                            const Spacer(),
                            if (edited)
                              Container(
                                padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
                                decoration: BoxDecoration(color: sig, borderRadius: BorderRadius.circular(8)),
                                child: Text(
                                  _tr('수정됨', 'Edited', '已修改', '編集済み'),
                                  style: const TextStyle(fontSize: 10.5, fontWeight: FontWeight.w700, color: Colors.white, shadows: AppColors.whiteTextShadows),
                                ),
                              ),
                          ],
                        ),
                        const SizedBox(height: 6),
                        TextField(
                          controller: _controllers[pIndex],
                          maxLines: null,
                          style: const TextStyle(fontSize: 15, height: 1.45),
                          decoration: const InputDecoration(
                            isDense: true,
                            border: InputBorder.none,
                            contentPadding: EdgeInsets.zero,
                          ),
                          onChanged: (v) => setState(() => p.text = v),
                        ),
                      ],
                    ),
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }
}
