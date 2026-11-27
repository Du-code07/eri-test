import 'dart:async';
import '../services/pro.dart';
import 'pro_screen.dart';
import 'faq_screen.dart';
import 'contact_screen.dart';
import '../widgets/file_type_icon.dart';
import 'user_fonts_screen.dart';
import 'tap_zone_screen.dart';
import 'legal_screen.dart';
import 'licenses_screen.dart';
import 'scan_folders_screen.dart';
import '../services/scan_folders.dart';
import 'privacy_lock_screen.dart';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';
import '../widgets/pop_dialog.dart';
import '../widgets/push_aside_route.dart';
import '../widgets/app_colors.dart';

import '../services/storage_service.dart';
import '../widgets/choice_sheet.dart';
import '../widgets/sheet_pull_to_close.dart';
import 'language_select_screen.dart';

/// 앱 설정 화면: 항목을 누르면 아래에서 고르기 창이 올라온다.
class AppSettingsScreen extends StatefulWidget {
  const AppSettingsScreen({
    super.key,
    required this.appLang,
    required this.themeMode,
    required this.onChangeThemeMode,
    required this.viewMode,
    required this.hideExtension,
    this.hideGroupName = false,
    this.onChangeHideGroupName,
    this.hideThumbnails = false,
    this.onChangeHideThumbnails,
    this.hidePageCount = false,
    this.onChangeHidePageCount,
    required this.onChangeLanguage,
    required this.onChangeViewMode,
    required this.onChangeHideExtension,
    required this.onOpenGuide,
    this.scrollController,
    this.scrollPhysics,
    this.asSheet = false,
  });

  /// 지금 화면 문구에 쓰는 언어 (ko/en/zh/ja)
  final String appLang;
  final String themeMode; // 'system' | 'light' | 'dark'
  final Future<void> Function(String mode) onChangeThemeMode;
  final String viewMode; // 'grid' | 'list'
  final bool hideExtension;
  final bool hideGroupName;
  final Future<void> Function(bool hide)? onChangeHideGroupName;
  final bool hideThumbnails;
  final Future<void> Function(bool hide)? onChangeHideThumbnails;
  final bool hidePageCount;
  final Future<void> Function(bool hide)? onChangeHidePageCount;
  final ValueChanged<String> onChangeLanguage; // 'system' | ko/en/zh/ja
  final Future<void> Function(String mode) onChangeViewMode;
  final Future<void> Function(bool hide) onChangeHideExtension;
  final void Function(String lang) onOpenGuide;

  /// 아래에서 올라오는 창으로 띄울 때(위에서 아래로 끌어 닫기) 쓰는 스크롤 연결
  final ScrollController? scrollController;
  final ScrollPhysics? scrollPhysics;

  /// 창으로 띄웠는지: 맨 위 손잡이 줄과 '내리기' 버튼 표시
  final bool asSheet;

  @override
  State<AppSettingsScreen> createState() => _AppSettingsScreenState();
}

class _AppSettingsScreenState extends State<AppSettingsScreen> {
  late String _lang = widget.appLang;
  late String _langSetting = StorageService.appLangSetting ?? 'system';
  late String _themeMode = widget.themeMode;
  late String _viewMode = widget.viewMode;
  late bool _hideExt = widget.hideExtension;
  late bool _hideGroup = widget.hideGroupName;
  late bool _hideThumbs = widget.hideThumbnails;
  late bool _hidePages = widget.hidePageCount;
  bool _rememberPage = StorageService.rememberPage;


  @override
  void initState() {
    super.initState();
    _measureCache();
    _countScanFolders();
  }

  int _scanFolderCount = 0;
  Future<void> _countScanFolders() async {
    final n = (await ScanFolders.load()).length;
    if (mounted) setState(() => _scanFolderCount = n);
  }


  Future<void> _setRememberPage(bool v) async {
    setState(() => _rememberPage = v);
    await StorageService.setRememberPage(v);
  }

  String _t(String ko, String en, String zh, String ja) => AppI18n.t(_lang, ko: ko, en: en, zh: zh, ja: ja);

  String _viewModeLabel(String mode) => mode == 'grid'
      ? _t('표지형 (그리드)', 'Cover View (Grid)', '封面视图 (网格)', '表紙表示 (グリッド)')
      : _t('목록형 (리스트)', 'List View', '列表视图', 'リスト表示');

  String _themeLabel(String mode) => switch (mode) {
        'dark' => _t('다크 모드', 'Dark mode', '深色模式', 'ダークモード'),
        'comfort' => _t('편안한 모드', 'Comfort mode', '护眼模式', '目に優しいモード'),
        'light' => _t('라이트 모드', 'Light mode', '浅色模式', 'ライトモード'),
        _ => _t('기본 시스템', 'System default', '跟随系统', 'システムのデフォルト'),
      };

  /// 테마마다 아이콘 (설정 목록과 고르기 창이 같은 아이콘)
  IconData _themeIcon(String mode) => switch (mode) {
        'dark' => Icons.dark_mode_outlined,
        'comfort' => Icons.wb_incandescent_outlined,
        'light' => Icons.light_mode_outlined,
        _ => Icons.brightness_auto_outlined,
      };

  Future<void> _pickTheme() async {
    final cs = Theme.of(context).colorScheme;
    final v = await showChoiceSheet<String>(
      context: context,
      title: _t('테마', 'Theme', '主题', 'テーマ'),
      titleIcon: Icon(_themeIcon(_themeMode), size: 22, color: cs.onSurface),
      options: [
        ChoiceOption('system', _themeLabel('system'), icon: _themeIcon('system')),
        ChoiceOption('light', _themeLabel('light'), icon: _themeIcon('light')),
        ChoiceOption('dark', _themeLabel('dark'), icon: _themeIcon('dark')),
        ChoiceOption('comfort', _themeLabel('comfort'), icon: _themeIcon('comfort')),
      ],
      current: _themeMode,
      centered: true, // 컴팩트·와이드 모두 가운데 팝업 창
    );
    if (v == null || !mounted) return;
    setState(() => _themeMode = v);
    await widget.onChangeThemeMode(v);
  }

  String _styleLabel(String style) =>
      style == 'simple' ? _t('와이드', 'Wide', '宽屏', 'ワイド') : _t('컴팩트', 'Compact', '紧凑', 'コンパクト');

  Future<void> _pickStyle() async {
    final cs = Theme.of(context).colorScheme;
    final cur = StorageService.appStyle.value;
    final v = await showChoiceSheet<String>(
      context: context,
      title: _t('스타일', 'Style', '样式', 'スタイル'),
      titleIcon: _StyleCircleGridIcon(size: 22, color: cs.onSurface),
      options: [
        // 컴팩트: 세로 휴대폰 / 와이드: 옆으로 눕히고 화면을 키운 태블릿
        ChoiceOption('basic', _styleLabel('basic'), icon: Icons.smartphone_rounded,
            subtitle: _t('작은 화면에 적합해요', 'Suits small screens', '适合小屏幕', '小さい画面に向いています')),
        ChoiceOption('simple', _styleLabel('simple'),
            iconWidget: _WideTabletIcon(size: 22, color: cur == 'simple' ? cs.onSurface : cs.onSurfaceVariant),
            subtitle: _t('큰 화면에 적합해요', 'Suits large screens', '适合大屏幕', '大きい画面に向いています')),
      ],
      current: cur,
      centered: true, // 컴팩트·와이드 모두 가운데 팝업 창
    );
    if (v == null || !mounted) return;
    await StorageService.setAppStyle(v);
    if (mounted) setState(() {});
  }

  Future<void> _pickLanguage() async {
    final v = await showChoiceSheet<String>(
      context: context,
      title: _t('언어', 'Language', '语言', '言語'),
      titleIcon: const LanguageGlyphIcon(size: 22),
      options: [for (final code in LanguageSelectScreen.options) ChoiceOption(code, languageOptionLabel(code))],
      current: _langSetting,
      centered: true, // 컴팩트·와이드 모두 가운데 팝업 창
    );
    if (v == null || !mounted) return;
    widget.onChangeLanguage(v);
    setState(() {
      _langSetting = v;
      _lang = StorageService.resolveAppLanguage(v);
    });
  }

  /// 파일 표시 방식(표지형/목록형) + 숨기기 옵션 — 누르면 바로 적용 (책갈피 터치 즐겨찾기는 페이지 기억하기 위로 이동)
  Future<void> _pickViewMode() async {
    final cs = Theme.of(context).colorScheme;
    await showChoiceSheetWithToggle<String>(
      context: context,
      title: _t('파일 표시 방식', 'Bookshelf View Mode', '文件显示样式', 'ファイル表示形式'),
      titleIcon: Icon(_viewMode == 'grid' ? Icons.grid_view_rounded : Icons.view_list_rounded, size: 22, color: cs.onSurface),
      resetLabel: _t('초기화', 'Reset', '重置', 'リセット'),
      resetTo: 'list',
      options: [
        ChoiceOption('list', _viewModeLabel('list'), icon: Icons.view_list_rounded),
        ChoiceOption('grid', _viewModeLabel('grid'), icon: Icons.grid_view_rounded),
      ],
      current: _viewMode,
      centered: true, // 컴팩트·와이드 모두 가운데 팝업 창
      onChanged: (r) async {
        final (mode, _) = r;
        if (!mounted) return;
        final bool modeChanged = mode != _viewMode;
        setState(() => _viewMode = mode);
        if (modeChanged) await widget.onChangeViewMode(mode);
      },
      moreToggles: [
        SheetToggle(
          icon: Icons.swipe_outlined,
          label: _t('밀어서 즐겨찾기·삭제 끄기', 'Turn off swipe actions', '关闭滑动收藏·删除', 'スワイプでお気に入り・削除をオフ'),
          subtitle: _t('파일을 옆으로 밀어도 즐겨찾기·휴지통 이동을 하지 않아요', 'Swiping a file no longer bookmarks or trashes it', '左右滑动文件不再收藏或移至回收站', 'ファイルを横にスワイプしてもお気に入り・ゴミ箱移動をしません'),
          value: StorageService.listSwipeOff.value,
          onlyFor: 'list',
          onChanged: (v) async {
            if (!mounted) return;
            setState(() {});
            await StorageService.setListSwipeOff(v);
          },
        ),
        SheetToggle(
          icon: Icons.hide_image_outlined,
          label: _t('표지 그림 끄기', 'Hide covers', '隐藏封面', '表紙を隠す'),
          subtitle: _t('표지 대신 파일 아이콘만', 'Show file icons only', '只显示文件图标', 'ファイルアイコンのみ'),
          value: _hideThumbs,
          onlyFor: 'grid',
          onChanged: (v) async {
            if (!mounted) return;
            setState(() => _hideThumbs = v);
            await widget.onChangeHideThumbnails?.call(v);
          },
        ),
        SheetToggle(
          icon: Icons.visibility_off_outlined,
          label: _t('파일 형식 숨기기', 'Hide file type', '隐藏文件类型', 'ファイル形式を隠す'),
          subtitle: _t('.docx, .pdf 등', '.docx, .pdf, etc', '.docx、.pdf 等', '.docx、.pdf など'),
          value: _hideExt,
          onChanged: (v) async {
            if (!mounted) return;
            setState(() => _hideExt = v);
            await widget.onChangeHideExtension(v);
          },
        ),
        SheetToggle(
          icon: Icons.label_off_outlined,
          label: _t('그룹 이름 숨기기', 'Hide group name', '隐藏分组名称', 'グループ名を隠す'),
          subtitle: _t('파일 아래 [그룹 이름]', '[Group] under each file', '文件下方的 [分组]', 'ファイルの下の [グループ]'),
          value: _hideGroup,
          onChanged: (v) async {
            if (!mounted) return;
            setState(() => _hideGroup = v);
            await widget.onChangeHideGroupName?.call(v);
          },
        ),
        SheetToggle(
          iconWidget: _SlashedPagesIcon(size: 19, color: cs.onSurfaceVariant),
          label: _t('페이지 수 숨기기', 'Hide page count', '隐藏页数', 'ページ数を隠す'),
          subtitle: _t('파일 아래 (페이지 수)', 'Under each file (page count)', '文件下方的页数', 'ファイルの下のページ数'),
          value: _hidePages,
          onChanged: (v) async {
            if (!mounted) return;
            setState(() => _hidePages = v);
            await widget.onChangeHidePageCount?.call(v);
          },
        ),
      ],
    );
  }

  String _refreshRateLabel(String mode) => switch (mode) {
        'auto' => _t('기본 시스템 (권장)', 'System Default (Recommended)', '默认系统（推荐）', 'システムデフォルト（推奨）'),
        '60' => _t('60Hz (절전)', '60Hz (Power Saving)', '60Hz（省电）', '60Hz（省電力）'),
        '90' => _t('90Hz (균형)', '90Hz (Balanced)', '90Hz（均衡）', '90Hz（バランス）'),
        _ => _t('120Hz (부드럽게)', '120Hz (Smooth)', '120Hz（流畅）', '120Hz（滑らか）'),
      };

  IconData _refreshRateIcon(String mode) => switch (mode) {
        'auto' => Icons.brightness_auto_outlined,
        '60' => Icons.eco_outlined,
        '90' => Icons.tune_outlined,
        _ => Icons.speed_outlined,
      };

  String _renderQualityLabel(String q) => switch (q) {
        'low' => _t('절전', 'Power Saving', '省电', '省電力'),
        'medium' => _t('표준', 'Standard', '标准', '標準'),
        _ => _t('고화질', 'High Quality', '高清', '高画質'),
      };

  IconData _renderQualityIcon(String q) => switch (q) {
        'low' => Icons.eco_outlined,
        'medium' => Icons.tune_outlined,
        _ => Icons.high_quality_outlined,
      };

  String _cacheDaysLabel(int days) => days <= 0
      ? _t('제한 없음', 'No limit', '无限制', '制限なし')
      : _t('$days일', '$days days', '$days 天', '$days日');

  String _cacheMbLabel(int mb) => mb <= 0
      ? _t('제한 없음', 'No limit', '无限制', '制限なし')
      : (mb >= 1024 ? '${(mb / 1024).toStringAsFixed(0)}GB' : '${mb}MB');

  Future<void> _pickRefreshRate(VoidCallback refreshSheet) async {
    final cs = Theme.of(context).colorScheme;
    final v = await showChoiceSheet<String>(
      context: context,
      title: _t('주사율 조절', 'Refresh Rate', '刷新率调节', 'リフレッシュレート'),
      titleIcon: Icon(_refreshRateIcon(StorageService.refreshRateMode.value), size: 22, color: cs.onSurface),
      options: [
        ChoiceOption('auto', _refreshRateLabel('auto'), icon: _refreshRateIcon('auto')),
        ChoiceOption('60', _refreshRateLabel('60'), icon: _refreshRateIcon('60')),
        ChoiceOption('90', _refreshRateLabel('90'), icon: _refreshRateIcon('90')),
        ChoiceOption('120', _refreshRateLabel('120'), icon: _refreshRateIcon('120')),
      ],
      current: StorageService.refreshRateMode.value,
      centered: true,
    );
    if (v == null || !mounted) return;
    await StorageService.setRefreshRateMode(v);
    if (mounted) {
      setState(() {});
      refreshSheet();
    }
  }

  Future<void> _pickRenderQuality(VoidCallback refreshSheet) async {
    final cs = Theme.of(context).colorScheme;
    final v = await showChoiceSheet<String>(
      context: context,
      title: _t('문서 렌더링 화질', 'Document Render Quality', '文档渲染画质', '文書レンダリング画質'),
      titleIcon: Icon(_renderQualityIcon(StorageService.renderQuality.value), size: 22, color: cs.onSurface),
      options: [
        ChoiceOption('low', _renderQualityLabel('low'), icon: _renderQualityIcon('low')),
        ChoiceOption('medium', _renderQualityLabel('medium'), icon: _renderQualityIcon('medium')),
        ChoiceOption('high', _renderQualityLabel('high'), icon: _renderQualityIcon('high')),
      ],
      current: StorageService.renderQuality.value,
      centered: true,
    );
    if (v == null || !mounted) return;
    await StorageService.setRenderQuality(v);
    if (mounted) {
      setState(() {});
      refreshSheet();
    }
  }

  /// 임시 캐시 자동 정리 기한 & 용량 한도 설정 창 (가운데 팝업)
  Future<void> _openCachePolicySheet(VoidCallback refreshParent) async {
    await _measureCache();
    if (!mounted) return;
    await showPopDialog<void>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDlgState) {
          final cs = Theme.of(ctx).colorScheme;
          void refreshAll() {
            if (ctx.mounted) setDlgState(() {});
            refreshParent();
          }

          final int days = StorageService.cacheMaxDays.value;
          final int mb = StorageService.cacheMaxMb.value;

          return Dialog(
            insetPadding: const EdgeInsets.symmetric(horizontal: 24, vertical: 32),
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
            clipBehavior: Clip.antiAlias,
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 440),
              child: Padding(
                padding: const EdgeInsets.fromLTRB(0, 20, 0, 14),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Padding(
                      padding: const EdgeInsets.fromLTRB(22, 0, 12, 6),
                      child: Row(
                        children: [
                          Icon(Icons.cleaning_services_outlined, size: 22, color: cs.onSurface),
                          const SizedBox(width: 12),
                          Expanded(
                            child: Text(
                              _t('임시 캐시 설정', 'Temporary Cache Settings', '临时缓存设置', '一時キャッシュ設定'),
                              style: const TextStyle(fontSize: 19, fontWeight: FontWeight.w800),
                            ),
                          ),
                          IconButton(
                            onPressed: () => Navigator.of(ctx).pop(),
                            icon: const Icon(Icons.close_rounded, size: 20),
                          ),
                        ],
                      ),
                    ),
                    Padding(
                      padding: const EdgeInsets.fromLTRB(22, 0, 22, 10),
                      child: Text(
                        _t('기한이 지나면 자동으로 삭제되고, 한도를 넘으면 가장 오래된 캐시부터 삭제돼요',
                            'Expired cache is deleted automatically; oldest files are removed first when over the limit',
                            '超过期限将自动删除，超出上限时从最早的缓存开始删除',
                            '期限が過ぎると自動削除され、上限を超えると最も古いキャッシュから削除されます'),
                        style: TextStyle(fontSize: 13, height: 1.4, color: cs.onSurfaceVariant),
                      ),
                    ),
                    ListTile(
                      contentPadding: const EdgeInsets.symmetric(horizontal: 22),
                      leading: Icon(Icons.schedule_outlined, size: 21, color: cs.onSurface),
                      title: Text(_t('보관 기한', 'Retention Period', '保留期限', '保存期間'), style: const TextStyle(fontSize: 15.5, fontWeight: FontWeight.w700)),
                      subtitle: Text(_cacheDaysLabel(days), style: TextStyle(fontSize: 13.5, color: cs.onSurfaceVariant)),
                      trailing: Icon(Icons.chevron_right, color: cs.onSurfaceVariant),
                      onTap: () async {
                        final v = await showChoiceSheet<int>(
                          context: ctx,
                          title: _t('보관 기한', 'Retention Period', '保留期限', '保存期間'),
                          titleIcon: Icon(Icons.schedule_outlined, size: 21, color: cs.onSurface),
                          options: [
                            ChoiceOption(7, _cacheDaysLabel(7)),
                            ChoiceOption(14, _cacheDaysLabel(14)),
                            ChoiceOption(30, _cacheDaysLabel(30)),
                            ChoiceOption(90, _cacheDaysLabel(90)),
                            ChoiceOption(0, _cacheDaysLabel(0)),
                          ],
                          current: days,
                          centered: true,
                        );
                        if (v == null) return;
                        await StorageService.setCacheMaxDays(v);
                        await _measureCache();
                        refreshAll();
                      },
                    ),
                    ListTile(
                      contentPadding: const EdgeInsets.symmetric(horizontal: 22),
                      leading: Icon(Icons.storage_outlined, size: 21, color: cs.onSurface),
                      title: Text(_t('최대 용량 한도', 'Maximum Size Limit', '最大容量上限', '最大容量上限'), style: const TextStyle(fontSize: 15.5, fontWeight: FontWeight.w700)),
                      subtitle: Text(_cacheMbLabel(mb), style: TextStyle(fontSize: 13.5, color: cs.onSurfaceVariant)),
                      trailing: Icon(Icons.chevron_right, color: cs.onSurfaceVariant),
                      onTap: () async {
                        final v = await showChoiceSheet<int>(
                          context: ctx,
                          title: _t('최대 용량 한도', 'Maximum Size Limit', '最大容量上限', '最大容量上限'),
                          titleIcon: Icon(Icons.storage_outlined, size: 21, color: cs.onSurface),
                          options: [
                            ChoiceOption(100, _cacheMbLabel(100)),
                            ChoiceOption(300, _cacheMbLabel(300)),
                            ChoiceOption(500, _cacheMbLabel(500)),
                            ChoiceOption(1024, _cacheMbLabel(1024)),
                            ChoiceOption(0, _cacheMbLabel(0)),
                          ],
                          current: mb,
                          centered: true,
                        );
                        if (v == null) return;
                        await StorageService.setCacheMaxMb(v);
                        await _measureCache();
                        refreshAll();
                      },
                    ),
                    const Divider(height: 16, indent: 22, endIndent: 22),
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 22, vertical: 2),
                      child: Row(
                        children: [
                          Expanded(
                            child: Text(
                              _cacheBytes == null
                                  ? _t('임시 파일 계산 중…', 'Calculating…', '计算中…', '計算中…')
                                  : _t('현재 임시 파일 ${_fmtBytes(_cacheBytes!)}', 'Current cache ${_fmtBytes(_cacheBytes!)}', '当前缓存 ${_fmtBytes(_cacheBytes!)}', '現在のキャッシュ ${_fmtBytes(_cacheBytes!)}'),
                              style: TextStyle(fontSize: 13.5, color: cs.onSurfaceVariant, fontWeight: FontWeight.w600),
                            ),
                          ),
                          TextButton(
                            onPressed: () async {
                              await _clearCache();
                              refreshAll();
                            },
                            child: Text(_t('지금 비우기', 'Clear Now', '立即清除', '今すぐ削除'), style: const TextStyle(fontWeight: FontWeight.w700)),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
          );
        },
      ),
    );
  }

  /// 성능 및 배터리 설정 창 (컴팩트·와이드 모두 가운데 팝업 창)
  Future<void> _openPerformanceSheet() async {
    await _measureCache();
    if (!mounted) return;
    await showPopDialog<void>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setSheetState) {
          final cs = Theme.of(ctx).colorScheme;
          void refresh() {
            if (ctx.mounted) setSheetState(() {});
            if (mounted) setState(() {});
          }

          Widget row({
            IconData? icon,
            Widget? leading,
            required String title,
            required String subtitle,
            VoidCallback? onTap,
            Widget? trailing,
            Color? titleColor,
          }) {
            return ListTile(
              contentPadding: const EdgeInsets.symmetric(horizontal: 20, vertical: 2),
              leading: leading ?? Icon(icon, size: 22, color: titleColor ?? cs.onSurface),
              title: Text(title, style: TextStyle(fontSize: 15.5, fontWeight: FontWeight.w700, color: titleColor)),
              subtitle: Text(subtitle, style: TextStyle(fontSize: 13, color: cs.onSurfaceVariant)),
              trailing: trailing ?? Icon(Icons.chevron_right, color: cs.onSurfaceVariant),
              onTap: onTap,
            );
          }

          final rr = StorageService.refreshRateMode.value;
          final rq = StorageService.renderQuality.value;
          final snapOff = StorageService.pageSnapshotOff.value;
          final oled = StorageService.pureBlackDark.value;
          final animOff = Anim.off.value;

          return Dialog(
            insetPadding: const EdgeInsets.symmetric(horizontal: 24, vertical: 32),
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
            clipBehavior: Clip.antiAlias,
            child: ConstrainedBox(
              constraints: BoxConstraints(maxWidth: 460, maxHeight: MediaQuery.sizeOf(ctx).height * 0.82),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  SizedBox(
                    height: 64,
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(22, 12, 12, 0),
                      child: Row(
                        children: [
                          BatteryLeafIcon(size: 23, color: cs.onSurface),
                          const SizedBox(width: 14),
                          Expanded(
                            child: Text(
                              _t('관리', 'Manage', '管理', '管理'),
                              style: (Theme.of(ctx).textTheme.titleLarge ?? const TextStyle()).copyWith(fontWeight: FontWeight.w800),
                            ),
                          ),
                          IconButton(
                            onPressed: () => Navigator.of(ctx).pop(),
                            icon: const Icon(Icons.close_rounded, size: 20),
                          ),
                        ],
                      ),
                    ),
                  ),
                  Flexible(
                    child: ListView(
                      shrinkWrap: true,
                      padding: const EdgeInsets.only(bottom: 16),
                      children: [
                        // 주사율 조절: 설정 변경 시 아이콘만 바뀌고 문구 앞 이름 생략
                        row(
                          icon: _refreshRateIcon(rr),
                          title: _t('주사율 조절', 'Refresh Rate', '刷新率调节', 'リフレッシュレート'),
                          subtitle: _t('주사율이 낮을수록 배터리 소모량이 줄어요', 'Lower refresh rate reduces battery usage', '刷新率越低，耗电量越少', 'リフレッシュレートが低いほど電池消費が減ります'),
                          onTap: () => _pickRefreshRate(refresh),
                        ),
                        // 문서 렌더링 화질: 설정 변경 시 아이콘만 바뀌고 문구 앞 이름 생략
                        row(
                          icon: _renderQualityIcon(rq),
                          title: _t('문서 렌더링 화질', 'Document Render Quality', '文档渲染画质', '文書レンダリング画質'),
                          subtitle: _t('화질을 낮추면 배터리와 메모리 사용이 줄어요', 'Lower quality uses less battery and memory', '降低画质可减少耗电和内存占用', '画質を下げると電池とメモリ消費を抑えます'),
                          onTap: () => _pickRenderQuality(refresh),
                        ),
                        row(
                          icon: Icons.photo_camera_back_outlined,
                          title: _t('페이지 전환 스냅샷 끄기', 'Turn Off Page Turn Snapshots', '关闭翻页快照', 'ページ切替スナップショットをオフ'),
                          subtitle: _t('페이지 미리 찍기를 꺼서 배터리와 CPU 부하가 줄어요', 'Skips page pre-capture to reduce battery and CPU load', '关闭页面预截图以降低耗电和 CPU 负载', 'ページの事前キャプチャをオフにして電池とCPU負荷を抑えます'),
                          onTap: () async {
                            await StorageService.setPageSnapshotOff(!snapOff);
                            refresh();
                          },
                          trailing: Switch(
                            value: snapOff,
                            onChanged: (v) async {
                              await StorageService.setPageSnapshotOff(v);
                              refresh();
                            },
                          ),
                        ),
                        row(
                          icon: Icons.contrast_outlined,
                          title: _t('순수 검정 다크 모드', 'Pure Black Dark Mode', '纯黑深色模式', 'ピュアブラックダークモード'),
                          subtitle: _t('다크 모드 배경을 완전한 검정색으로 바꿔 배터리 소모량이 줄어요', 'Uses pure black backgrounds in dark mode to reduce battery usage', '将深色模式背景改为纯黑以减少耗电量', 'ダークモードの背景を完全な黒にして電池消費を抑えます'),
                          onTap: () async {
                            await StorageService.setPureBlackDark(!oled);
                            refresh();
                          },
                          trailing: Switch(
                            value: oled,
                            onChanged: (v) async {
                              await StorageService.setPureBlackDark(v);
                              refresh();
                            },
                          ),
                        ),
                        row(
                          icon: Icons.motion_photos_off_outlined,
                          title: _t('애니메이션 끄기', 'Turn Off Animations', '关闭动画', 'アニメーションをオフ'),
                          subtitle: _t('애니메이션을 끄면 화면 버벅임과 빠른 반응 속도에 도움이 돼요', 'Reduces stutter and improves responsiveness', '关闭动画可减少卡顿并提升响应速度', 'アニメーションをオフにするとカクつきが減り反応が速くなります'),
                          onTap: () async {
                            await StorageService.setAnimOff(!animOff);
                            refresh();
                          },
                          trailing: Switch(
                            value: animOff,
                            onChanged: (v) async {
                              await StorageService.setAnimOff(v);
                              refresh();
                            },
                          ),
                        ),
                        const Divider(height: 16, indent: 20, endIndent: 20),
                        row(
                          icon: Icons.cleaning_services_outlined,
                          title: _t('임시 캐시 설정', 'Temporary Cache', '临时缓存设置', '一時キャッシュ設定'),
                          subtitle: _t(
                            '보관 ${_cacheDaysLabel(StorageService.cacheMaxDays.value)} · 한도 ${_cacheMbLabel(StorageService.cacheMaxMb.value)}${_cacheBytes == null ? '' : ' (${_fmtBytes(_cacheBytes!)})'}',
                            'Keep ${_cacheDaysLabel(StorageService.cacheMaxDays.value)} · Limit ${_cacheMbLabel(StorageService.cacheMaxMb.value)}${_cacheBytes == null ? '' : ' (${_fmtBytes(_cacheBytes!)})'}',
                            '保留 ${_cacheDaysLabel(StorageService.cacheMaxDays.value)} · 上限 ${_cacheMbLabel(StorageService.cacheMaxMb.value)}${_cacheBytes == null ? '' : ' (${_fmtBytes(_cacheBytes!)})'}',
                            '保存 ${_cacheDaysLabel(StorageService.cacheMaxDays.value)} · 上限 ${_cacheMbLabel(StorageService.cacheMaxMb.value)}${_cacheBytes == null ? '' : ' (${_fmtBytes(_cacheBytes!)})'}',
                          ),
                          onTap: () => _openCachePolicySheet(refresh),
                        ),
                        row(
                          icon: Icons.delete_forever_outlined,
                          title: _t('데이터 지우기', 'Clear Data', '清除数据', 'データを削除'),
                          subtitle: _t('앱 안의 파일·메모·설정을 지우고 처음 상태로 되돌려요', 'Resets the app to how it was when first installed', '删除应用内文件·笔记·设置并恢复初始状态', 'アプリ内のデータを消して初期状態に戻します'),
                          titleColor: Colors.redAccent,
                          onTap: _clearData,
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }

  // ── 데이터 ──
  int? _cacheBytes;

  /// 지울 수 있는 임시 파일 폴더 (지워도 필요할 때 다시 만들어짐)
  Future<List<Directory>> _cacheDirs() async => [
        await getTemporaryDirectory(),
        Directory('${(await getApplicationSupportDirectory()).path}/outline_cache'),
      ];

  Future<void> _measureCache() async {
    int total = 0;
    try {
      for (final d in await _cacheDirs()) {
        if (!await d.exists()) continue;
        await for (final e in d.list(recursive: true, followLinks: false)) {
          if (e is File) {
            try {
              total += await e.length();
            } catch (_) {}
          }
        }
      }
    } catch (_) {}
    if (mounted) setState(() => _cacheBytes = total);
  }

  String _fmtBytes(int b) {
    if (b < 1024) return '${b}B';
    if (b < 1024 * 1024) return '${(b / 1024).toStringAsFixed(0)}KB';
    if (b < 1024 * 1024 * 1024) return '${(b / 1024 / 1024).toStringAsFixed(1)}MB';
    return '${(b / 1024 / 1024 / 1024).toStringAsFixed(2)}GB';
  }

  Future<void> _clearCache() async {
    final ok = await showPopDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(_t('캐시 지우기', 'Clear Cache', '清除缓存', 'キャッシュを削除')),
        content: Text(_t('다시 만들 수 있는 임시 파일만 지워요\n지우면 파일을 열 때 조금 느려져요',
            'Delete temporary files such as pre-rendered pages and contents?\nYour files, notes and settings stay',
            '要删除预先渲染的页面、目录等临时文件吗？\n文件、笔记和设置不受影响',
            '事前に描いたページ・目次などの一時ファイルを削除しますか？\nファイル・メモ・設定はそのままです')),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: Text(_t('취소', 'Cancel', '取消', 'キャンセル'))),
          ElevatedButton(onPressed: () => Navigator.pop(ctx, true), child: Text(_t('지우기', 'Clear', '清除', '削除'))),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    for (final d in await _cacheDirs()) {
      try {
        if (!await d.exists()) continue;
        await for (final e in d.list(followLinks: false)) {
          try {
            await e.delete(recursive: true);
          } catch (_) {}
        }
      } catch (_) {}
    }
    PaintingBinding.instance.imageCache.clear();
    await _measureCache();
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(_t('캐시를 지웠어요', 'Cache cleared', '缓存已清除', 'キャッシュを削除しました'))));
  }

  Future<void> _clearData() async {
    final ok = await showPopDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(_t('데이터 지우기', 'Clear Data', '清除数据', 'データを削除')),
        content: Text(_t('앱 안의 파일·메모·설정이 모두 지워지고 되돌릴 수 없어요\n원래 폴더에 있는 원본 파일은 그대로 남아요\n지운 뒤 앱이 닫혀요',
            'All files, notes and settings in the app will be deleted and cannot be restored\nOriginal files in their folders stay as they are\nThe app will close afterwards',
            '应用内的文件·笔记·设置将全部删除且无法恢复\n原文件夹中的原文件会保留\n删除后应用将关闭',
            'アプリ内のファイル・メモ・設定がすべて削除され、元に戻せません\n元のフォルダにある元のファイルはそのまま残ります\n削除後アプリが閉じます')),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: Text(_t('취소', 'Cancel', '取消', 'キャンセル'))),
          ElevatedButton(
            style: ElevatedButton.styleFrom(backgroundColor: Colors.redAccent, foregroundColor: Colors.white),
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(_t('모두 지우기', 'Delete All', '全部删除', 'すべて削除')),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    const ch = MethodChannel('ebook_reader/pdf_renderer');
    final done = await ch.invokeMethod<bool>('clearAppData').catchError((_) => false) ?? false;
    if (!done && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(_t('데이터를 지우지 못했어요', 'Could not clear data', '无法清除数据', 'データを削除できませんでした'))));
    }
  }

  Widget _section(String text) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 20, 24, 6),
      child: Text(
        text,
        style: TextStyle(fontSize: 13.5, fontWeight: FontWeight.w800, color: Theme.of(context).colorScheme.onSurfaceVariant),
      ),
    );
  }

  Widget _item({
    required IconData icon,
    required String title,
    String? subtitle,
    VoidCallback? onTap,
    Widget? trailing,
    Widget? leading,
  }) {
    final cs = Theme.of(context).colorScheme;
    return ListTile(
      contentPadding: const EdgeInsets.symmetric(horizontal: 24, vertical: 4),
      leading: leading ?? Icon(icon, size: 23, color: cs.onSurface),
      title: Text(title, style: const TextStyle(fontSize: 16.5, fontWeight: FontWeight.w700)),
      subtitle: subtitle == null ? null : Text(subtitle, style: TextStyle(fontSize: 14, color: cs.onSurfaceVariant)),
      trailing: trailing ?? Icon(Icons.chevron_right, color: cs.onSurfaceVariant),
      onTap: onTap,
    );
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: widget.asSheet
          // 창으로 띄울 때: 맨 위 회색 막대 + 제목까지 간격 (밑에서 올라오는 모든 창과 같게), 그 아래 [설정 아이콘 앱 설정]
          ? PreferredSize(
              preferredSize: const Size.fromHeight(10 + 4 + 22 + 48),
              child: Material(
                color: Theme.of(context).appBarTheme.backgroundColor ?? cs.surface,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const SheetGrip(below: 22),
                    SizedBox(
                      height: 48,
                      // 설정 아이콘 + 앱 설정 (창은 끌어 내리거나 뒤로 가기로 닫음). 아이콘·제목은 아래 줄들과 같은 자리
                      child: Row(children: [
                        const SizedBox(width: 24),
                        Icon(Icons.settings_outlined, size: 23, color: cs.onSurface),
                        const SizedBox(width: 17),
                        Text(_t('설정', 'Settings', '设置', '設定'),
                            style: (Theme.of(context).textTheme.titleLarge ?? const TextStyle()).copyWith(fontWeight: FontWeight.w800)),
                      ]),
                    ),
                  ],
                ),
              ),
            )
          : AppBar(title: Text(_t('설정', 'Settings', '设置', '設定'), style: const TextStyle(fontWeight: FontWeight.w800))),
      body: SafeArea(
        top: !widget.asSheet,
        child: ListView(
          controller: widget.scrollController,
          physics: widget.scrollPhysics,
          padding: const EdgeInsets.only(bottom: 16),
          children: [
            _section(_t('일반', 'General', '通用', '一般')),
            // 스타일: 컴팩트(휴대폰) / 와이드(태블릿)
            _item(
              icon: Icons.dashboard_customize_outlined,
              leading: _StyleCircleGridIcon(size: 23, color: cs.onSurface),
              title: _t('스타일', 'Style', '样式', 'スタイル'),
              subtitle: _styleLabel(StorageService.appStyle.value),
              onTap: _pickStyle,
            ),
            _item(
              icon: _themeIcon(_themeMode),
              title: _t('테마', 'Theme', '主题', 'テーマ'),
              subtitle: _themeLabel(_themeMode),
              onTap: _pickTheme,
            ),
            _item(
              icon: Icons.language,
              leading: const LanguageGlyphIcon(size: 23),
              title: _t('언어', 'Language', '语言', '言語'),
              subtitle: languageOptionLabel(_langSetting),
              onTap: _pickLanguage,
            ),
            // 잠금: 기존 자물쇠에서 안쪽 동그라미만 뺀 아이콘
            _item(
              icon: Icons.lock_outline,
              leading: CleanLockIcon(size: 23, color: cs.onSurface),
              title: _t('잠금', 'Lock', '锁定', 'ロック'),
              subtitle: _t('앱·파일을 잠글 수 있어요', 'Lock your app and files', '可以锁定应用和文件', 'アプリ・ファイルをロックできます'),
              onTap: () async {
                await Navigator.of(context).push(PushAsideRoute(builder: (_) => PrivacyLockScreen(t: _t)));
                if (mounted) setState(() {});
              },
            ),
            // 관리: 배터리 안 절전 나뭇잎 아이콘
            _item(
              icon: Icons.battery_saver_outlined,
              leading: BatteryLeafIcon(size: 23, color: cs.onSurface),
              title: _t('관리', 'Manage', '管理', '管理'),
              subtitle: _t('주사율·화질·절전·애니메이션·캐시 관리', 'Refresh rate, quality, power saving, animations & cache', '刷新率·画质·省电·动画·缓存管理', 'リフレッシュレート・画質・省電力・アニメ・キャッシュ'),
              onTap: _openPerformanceSheet,
            ),
            // 파일: 파일 목록·여는 방식에 관한 설정
            _section(_t('파일', 'Files', '文件', 'ファイル')),
            _item(
              icon: _viewMode == 'grid' ? Icons.grid_view_rounded : Icons.view_list_rounded,
              title: _t('파일 표시 방식', 'Bookshelf View Mode', '文件显示样式', 'ファイル表示形式'),
              // 지금 방식 + 형식 숨김 여부
              subtitle: [
                _viewModeLabel(_viewMode),
                if (_hideExt) _t('형식 숨김', 'extensions hidden', '隐藏扩展名', '形式を隠す'),
                if (_hideGroup) _t('그룹 숨김', 'groups hidden', '隐藏分组', 'グループを隠す'),
              ].join(' · '),
              onTap: _pickViewMode,
            ),

            _item(
              icon: Icons.bookmark_added_outlined,
              title: _t('페이지 기억하기', 'Remember Last Page', '记住页面', 'ページを記憶'),
              subtitle: _t('마지막으로 읽던 쪽으로 열어요', 'Opens at the page you last read', '打开到上次阅读的页面', '最後に読んだページで開きます'),
              onTap: () => _setRememberPage(!_rememberPage),
              trailing: Switch(value: _rememberPage, onChanged: _setRememberPage),
            ),
            _item(
              icon: Icons.grid_view_outlined,
              title: _t('탭 영역', 'Tap Zones', '点击区域', 'タップ領域'),
              subtitle: _t('영역별로 눌렀을 때의 동작을 정해요', 'Set what tapping each area does', '设置点击各区域时的操作', 'エリアごとのタップ時の動作を決めます'),
              onTap: () => Navigator.of(context).push(PushAsideRoute(builder: (_) => TapZoneScreen(t: _t))),
            ),
            // 파일 탐색·글꼴 찾기가 찾아볼 폴더 (사용자가 고른 폴더만 읽음)
            _item(
              icon: Icons.folder_open_outlined,
              title: _t('탐색할 폴더', 'Folders to Search', '要查找的文件夹', '探すフォルダ'),
              subtitle: _scanFolderCount == 0
                  ? _t('파일 탐색·글꼴 찾기가 찾을 폴더', 'Where Find Files and Find Fonts search', '查找文件·查找字体的位置', 'ファイル検索・フォント検索が探すフォルダ')
                  : _t('폴더 $_scanFolderCount개', '$_scanFolderCount folder(s)', '$_scanFolderCount 个文件夹', 'フォルダ $_scanFolderCount 個'),
              onTap: () async {
                await Navigator.of(context).push(PushAsideRoute(builder: (_) => ScanFoldersScreen(appLang: _lang)));
                _countScanFolders();
              },
            ),
            // (스크롤 보기는 이제 문서 화면 안에서 바로 보여 주므로 미리 준비·준비 완료 알림 설정이 필요 없음)
            _section(_t('글꼴', 'Fonts', '字体', 'フォント')),
            _item(
              icon: Icons.description_outlined,
              leading: const DocPairIcon(size: 25),
              title: _t('한글·워드 글꼴', 'HWP·Word Fonts', 'HWP·Word 字体', 'HWP・Wordフォント'),
              subtitle: _t('문서 글꼴', 'Document fonts', '文档字体', '文書フォント'),
              onTap: () => Navigator.of(context).push(PushAsideRoute(builder: (_) => UserFontsScreen(t: _t, category: 'doc'))),
            ),
            _item(
              icon: Icons.font_download_outlined,
              title: _t('앱 글꼴', 'App Font', '应用字体', 'アプリのフォント'),
              subtitle: _t('메뉴·목록·설정 화면 글꼴', 'Font for menus, lists and settings', '菜单、列表、设置的字体', 'メニュー・一覧・設定のフォント'),
              onTap: () => Navigator.of(context).push(PushAsideRoute(builder: (_) => UserFontsScreen(t: _t, category: 'app'))),
            ),
            _item(
              icon: Icons.menu_book_outlined,
              leading: FileTypeIcon(ext: 'epub', size: 24, color: Theme.of(context).colorScheme.onSurface),
              title: _t('EPUB 글꼴', 'EPUB Font', 'EPUB字体', 'EPUBフォント'),
              subtitle: _t('EPUB 책 본문 글꼴', 'Font for EPUB book text', 'EPUB正文字体', 'EPUB本文のフォント'),
              onTap: () => Navigator.of(context).push(PushAsideRoute(builder: (_) => UserFontsScreen(t: _t, category: 'epub'))),
            ),
            // 데이터: 캐시 지우기 · 데이터 지우기
            // 프로: 이리ERI 프로 안내와 유료 기능 숨기기
            _section(_t('프로', 'Pro', '专业版', 'プロ')),
            // 이리ERI 프로: 유료 기능과 무료 제공 기간 안내
            _item(
              icon: Icons.workspace_premium_outlined,
              leading: SimpleCrownIcon(size: 23, color: cs.onSurface),
              title: _t('이리ERI 프로', '이리ERI Pro', '이리ERI 专业版', '이리ERI プロ'),
              subtitle: Pro.freePeriod
                  ? _t('2027년 유료 출시 전까지 무료로 쓸 수 있어요', 'Free to use until the paid launch in 2027', '在2027年付费版推出前可免费使用', '2027年の有料リリース前まで無料で使えます')
                  : _t('업데이트하면 구매할 수 있어요', 'Update the app to buy it', '更新应用后即可购买', 'アップデートすると購入できます'),
              onTap: () async {
                await Navigator.of(context).push(PushAsideRoute(builder: (_) => ProScreen(lang: _lang)));
                if (mounted) setState(() {});
              },
            ),
            // 유료 기능 숨기기: 파일 추가 메뉴에서 스캔·합치기를 감춤 (무료 제공 기간에는 쓸 수 없음 — 유료 기능이 항상 보임)
            ValueListenableBuilder<bool>(
              valueListenable: Pro.hidePaid,
              builder: (context, _, _) {
                final bool locked = !Pro.canHidePaid;
                final bool hide = Pro.hidesPaid;
                return _item(
                  icon: Icons.visibility_off_outlined,
                  title: _t('유료 기능 숨기기', 'Hide Paid Features', '隐藏付费功能', '有料機能を隠す'),
                  subtitle: locked
                      ? _t('무료 제공 기간에는 유료 기능이 모두 보여요', 'All paid features are shown during the free period', '免费提供期间付费功能全部显示', '無料提供期間中は有料機能がすべて表示されます')
                      : _t('파일 추가 메뉴에서 스캔·PDF 합치기·이미지 합치기를 숨겨요', 'Hides Scan, Merge PDFs and Merge Images in the Add Files menu',
                          '在添加文件菜单中隐藏扫描、合并 PDF 和合并图片', 'ファイル追加メニューでスキャン・PDF結合・画像結合を隠します'),
                  onTap: locked ? null : () => Pro.setHidePaid(!hide),
                  trailing: Switch(value: hide, onChanged: locked ? null : Pro.setHidePaid),
                );
              },
            ),

            _section(_t('도움말', 'Help', '帮助', 'ヘルプ')),
            _item(
              icon: Icons.lightbulb_outline,
              title: _t('가이드', 'Guide', '指南', 'ガイド'),
              subtitle: _t('예시 화면에서 단추를 하나씩 알려 줘요', 'Explains each button on a sample screen', '在示例画面上逐个介绍按钮', '見本の画面でボタンを一つずつ説明します'),
              onTap: () => widget.onOpenGuide(_lang),
            ),
            _item(
              icon: Icons.help_outline,
              title: _t('자주 묻는 질문', 'FAQ', '常见问题', 'よくある質問'),
              subtitle: _t('지원 형식, 요금, 파일 추가 방식 등', 'Supported formats, pricing, how files are added and more', '支持的格式、费用、文件添加方式等', '対応形式、料金、ファイルの追加方法など'),
              onTap: () => Navigator.of(context).push(PushAsideRoute(builder: (_) => FaqScreen(lang: _lang))),
            ),
            _item(
              icon: Icons.mail_outline,
              title: _t('문의하기', 'Contact Us', '联系我们', 'お問い合わせ'),
              subtitle: ContactScreen.supportEmail,
              onTap: () => Navigator.of(context).push(PushAsideRoute(builder: (_) => ContactScreen(lang: _lang))),
            ),
            _item(
              icon: Icons.rate_review_outlined,
              title: _t('리뷰 남기기', 'Write a Review', '撰写评价', 'レビューを書く'),
              subtitle: _t('Google Play 스토어에 리뷰를 남겨요', 'Leave a review on the Google Play Store', '在 Google Play 商店留下评价', 'Google Play ストアにレビューを書きます'),
              // 보류: 스토어에 앱이 올라가면 이리ERI의 Google Play 페이지를 열도록 연결
              onTap: () {},
            ),
            _item(
              icon: Icons.gavel_outlined,
              title: _t('이용 약관', 'Terms of Service', '使用条款', '利用規約'),
              onTap: () => Navigator.of(context).push(PushAsideRoute(builder: (_) => LegalScreen(doc: LegalDoc.terms, lang: _lang))),
            ),
            _item(
              icon: Icons.privacy_tip_outlined,
              title: _t('개인정보 처리방침', 'Privacy Policy', '隐私政策', 'プライバシーポリシー'),
              onTap: () => Navigator.of(context).push(PushAsideRoute(builder: (_) => LegalScreen(doc: LegalDoc.privacy, lang: _lang))),
            ),
            _item(
              icon: Icons.article_outlined,
              title: _t('오픈소스 라이선스', 'Open Source Licenses', '开源许可', 'オープンソースライセンス'),
              onTap: () => Navigator.of(context).push(PushAsideRoute(builder: (_) => LicensesScreen(appLang: _lang))),
            ),
          ],
        ),
      ),
    );
  }
}


/// 스타일 아이콘: 첫 번째(좌상단) 칸을 동그라미로 그린 2x2 커스텀 레이아웃 아이콘
class _StyleCircleGridIcon extends StatelessWidget {
  const _StyleCircleGridIcon({required this.size, required this.color});
  final double size;
  final Color color;

  @override
  Widget build(BuildContext context) => SizedBox(
        width: size,
        height: size,
        child: CustomPaint(painter: _StyleCircleGridPainter(color)),
      );
}

class _StyleCircleGridPainter extends CustomPainter {
  _StyleCircleGridPainter(this.color);
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final s = size.width / 24.0;
    final p = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.8 * s
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;
    canvas.drawCircle(Offset(7.0 * s, 7.0 * s), 3.4 * s, p);
    canvas.drawRRect(RRect.fromRectAndRadius(Rect.fromLTWH(13.6 * s, 3.6 * s, 6.8 * s, 6.8 * s), Radius.circular(1.6 * s)), p);
    canvas.drawRRect(RRect.fromRectAndRadius(Rect.fromLTWH(3.6 * s, 13.6 * s, 6.8 * s, 6.8 * s), Radius.circular(1.6 * s)), p);
    canvas.drawLine(Offset(17.0 * s, 14.0 * s), Offset(17.0 * s, 20.0 * s), p);
    canvas.drawLine(Offset(14.0 * s, 17.0 * s), Offset(20.0 * s, 17.0 * s), p);
  }

  @override
  bool shouldRepaint(_StyleCircleGridPainter old) => old.color != color;
}

/// 와이드 아이콘: 컴팩트(스마트폰) 아이콘을 옆으로 눕히고 화면을 넓힌 태블릿 (버튼 없이 테두리 채움)
class _WideTabletIcon extends StatelessWidget {
  const _WideTabletIcon({required this.size, required this.color});
  final double size;
  final Color color;

  @override
  Widget build(BuildContext context) => SizedBox(
        width: size,
        height: size,
        child: CustomPaint(painter: _WideTabletPainter(color)),
      );
}

class _WideTabletPainter extends CustomPainter {
  _WideTabletPainter(this.color);
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final s = size.width / 24.0;
    // smartphone_rounded와 동일한 채워진 베젤 스타일: 바깥 둥근 사각형에서 안쪽 넓은 화면을 비움
    final path = Path()
      ..fillType = PathFillType.evenOdd
      ..addRRect(RRect.fromRectAndRadius(Rect.fromLTWH(1.5 * s, 3.8 * s, 21.0 * s, 16.4 * s), Radius.circular(2.6 * s)))
      ..addRRect(RRect.fromRectAndRadius(Rect.fromLTWH(4.3 * s, 5.8 * s, 15.4 * s, 12.4 * s), Radius.circular(0.8 * s)));
    canvas.drawPath(path, Paint()..color = color..style = PaintingStyle.fill);
  }

  @override
  bool shouldRepaint(_WideTabletPainter old) => old.color != color;
}

/// 잠금 아이콘: 기존 Material Icons.lock_outline 비율 그대로 안쪽 열쇠구멍 동그라미만 제거
class CleanLockIcon extends StatelessWidget {
  const CleanLockIcon({super.key, required this.size, required this.color});
  final double size;
  final Color color;

  @override
  Widget build(BuildContext context) => SizedBox(
        width: size,
        height: size,
        child: CustomPaint(painter: _CleanLockPainter(color)),
      );
}

class _CleanLockPainter extends CustomPainter {
  _CleanLockPainter(this.color);
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final s = size.width / 24.0;
    final p = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2.0 * s
      ..strokeCap = StrokeCap.butt
      ..strokeJoin = StrokeJoin.miter;
    // Material lock_outline 비율: 각진 직사각형 몸체 + 반원 고리 (안쪽 동그라미 없음)
    final shackle = Path()
      ..moveTo(8.0 * s, 9.0 * s)
      ..lineTo(8.0 * s, 6.2 * s)
      ..arcToPoint(Offset(16.0 * s, 6.2 * s), radius: Radius.circular(4.0 * s), clockwise: true)
      ..lineTo(16.0 * s, 9.0 * s);
    canvas.drawPath(shackle, p);
    canvas.drawRRect(
      RRect.fromRectAndRadius(Rect.fromLTWH(5.0 * s, 9.0 * s, 14.0 * s, 11.5 * s), Radius.circular(1.8 * s)),
      p,
    );
  }

  @override
  bool shouldRepaint(_CleanLockPainter old) => old.color != color;
}

/// 관리(성능 및 배터리) 아이콘: 배터리 윤곽 안에 주사율 절전(eco_outlined) 나뭇잎을 그린 아이콘
class BatteryLeafIcon extends StatelessWidget {
  const BatteryLeafIcon({super.key, required this.size, required this.color});
  final double size;
  final Color color;

  @override
  Widget build(BuildContext context) => SizedBox(
        width: size,
        height: size,
        child: CustomPaint(painter: _BatteryLeafPainter(color)),
      );
}

class _BatteryLeafPainter extends CustomPainter {
  _BatteryLeafPainter(this.color);
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final s = size.width / 24.0;
    final p = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.75 * s
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;
    // 배터리 단자
    canvas.drawRRect(RRect.fromRectAndRadius(Rect.fromLTWH(9.5 * s, 2.0 * s, 5.0 * s, 2.2 * s), Radius.circular(0.8 * s)), p);
    // 배터리 몸체
    canvas.drawRRect(RRect.fromRectAndRadius(Rect.fromLTWH(5.8 * s, 4.2 * s, 12.4 * s, 17.6 * s), Radius.circular(2.0 * s)), p);
    // 배터리 안쪽 절전 나뭇잎 (eco_outlined와 동일한 윤곽 + 잎맥)
    final leafStroke = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.45 * s
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;
    final leaf = Path()
      ..moveTo(9.0 * s, 16.5 * s)
      ..cubicTo(8.5 * s, 12.2 * s, 10.8 * s, 9.6 * s, 15.0 * s, 9.4 * s)
      ..cubicTo(15.2 * s, 13.6 * s, 12.8 * s, 16.4 * s, 9.0 * s, 16.5 * s)
      ..close();
    canvas.drawPath(leaf, leafStroke);
    // 나뭇잎 줄기·잎맥
    canvas.drawLine(Offset(8.6 * s, 17.4 * s), Offset(12.6 * s, 12.6 * s), leafStroke..strokeWidth = 1.25 * s);
  }

  @override
  bool shouldRepaint(_BatteryLeafPainter old) => old.color != color;
}

/// 페이지 수 숨기기 아이콘: 겹쳐진 페이지 위에 대각선 취소선 (대각선 위로는 선이 닿지 않게 끊김 처리)
class _SlashedPagesIcon extends StatelessWidget {
  const _SlashedPagesIcon({required this.size, required this.color});
  final double size;
  final Color color;

  @override
  Widget build(BuildContext context) => SizedBox(
        width: size,
        height: size,
        child: CustomPaint(painter: _SlashedPagesPainter(color)),
      );
}

class _SlashedPagesPainter extends CustomPainter {
  _SlashedPagesPainter(this.color);
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final s = size.width / 24.0;
    final p = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.8 * s
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;
    canvas.saveLayer(Offset.zero & size, Paint());
    // 앞쪽 페이지
    canvas.drawRRect(RRect.fromRectAndRadius(Rect.fromLTWH(6.8 * s, 3.6 * s, 13.4 * s, 13.4 * s), Radius.circular(1.8 * s)), p);
    // 뒤쪽 페이지
    final back = Path()
      ..moveTo(4.0 * s, 7.6 * s)
      ..lineTo(4.0 * s, 18.6 * s)
      ..quadraticBezierTo(4.0 * s, 20.2 * s, 5.6 * s, 20.2 * s)
      ..lineTo(16.6 * s, 20.2 * s);
    canvas.drawPath(back, p);
    // 그룹 이름 숨기기(label_off_outlined)처럼 대각선 주변을 투명하게 비워 선이 닿지 않게 처리
    final erase = Paint()
      ..blendMode = BlendMode.clear
      ..style = PaintingStyle.stroke
      ..strokeWidth = 4.2 * s
      ..strokeCap = StrokeCap.round;
    canvas.drawLine(Offset(2.6 * s, 2.6 * s), Offset(21.4 * s, 21.4 * s), erase);
    // 대각선 취소선
    canvas.drawLine(Offset(3.0 * s, 3.0 * s), Offset(21.0 * s, 21.0 * s), p..strokeWidth = 1.85 * s);
    canvas.restore();
  }

  @override
  bool shouldRepaint(_SlashedPagesPainter old) => old.color != color;
}

/// 이리ERI 프로 아이콘: 심플한 3봉우리 왕관
class SimpleCrownIcon extends StatelessWidget {
  const SimpleCrownIcon({super.key, required this.size, required this.color});
  final double size;
  final Color color;

  @override
  Widget build(BuildContext context) => SizedBox(
        width: size,
        height: size,
        child: CustomPaint(painter: _SimpleCrownPainter(color)),
      );
}

class _SimpleCrownPainter extends CustomPainter {
  _SimpleCrownPainter(this.color);
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final s = size.width / 24.0;
    final p = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.85 * s
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;
    final crown = Path()
      ..moveTo(3.5 * s, 17.5 * s)
      ..lineTo(4.5 * s, 8.0 * s)
      ..lineTo(8.8 * s, 12.2 * s)
      ..lineTo(12.0 * s, 6.2 * s)
      ..lineTo(15.2 * s, 12.2 * s)
      ..lineTo(19.5 * s, 8.0 * s)
      ..lineTo(20.5 * s, 17.5 * s)
      ..close();
    canvas.drawPath(crown, p);
  }

  @override
  bool shouldRepaint(_SimpleCrownPainter old) => old.color != color;
}
