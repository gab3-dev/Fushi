import 'dart:async';

import 'package:material_ui/material_ui.dart';

import 'package:fushi/src/focus/fushi_focus_scroll.dart';
import 'package:fushi/src/media/detail/media_detail_kit.dart';
import 'package:fushi/src/utils/components/fushi_staggered_entrance.dart';
import 'package:fushi/src/utils/components/glass/fushi_icon.dart';
import 'package:fushi/src/utils/fushi_icons.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi/src/media/manga/library/online_manga_library_entry.dart';
import 'package:fushi/src/media/manga/library/online_manga_runtime_adapter.dart'
    show OnlineMangaSiblingSource, OnlineMangaSourceLanguageScope;
import 'package:fushi/src/media/online/online_source_error_text.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/utils/components/fushi_material_components.dart';
import 'package:fushi/src/utils/components/fushi_motion_tokens.dart';
import 'package:fushi/src/utils/components/batch_action_bar.dart';
import 'package:fushi/src/utils/components/fushi_icon_button.dart';
import 'package:fushi/src/utils/components/fushi_placeholder_message.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_buttons.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_chips.dart';

/// 一章在「先下载再读」语义下的状态（设计稿 2026-09-12 §5）。
enum _ChapterDownloadState {
  notDownloaded,
  queued,
  paused,
  downloading,
  downloaded,
  failed,
}

/// 章节下载失败文案：原因为空时只给「失败」，否则「失败 · 原因」。
///
/// 2026-10 体验优化：章节列表与下载页任务行原各拼一份，下载页那份在原因为
/// 空时留下尾冒号；收成一个函数两处共用。
///
/// [lastError] 是下载服务持久化的原始异常串（`SocketException: Failed host
/// lookup ...`），库里保留原样供诊断；这里经 [describeOnlineSourceErrorText]
/// 归一成给用户看的短句再拼。
String mangaChapterDownloadFailedLabel(String? lastError) {
  final String raw = lastError?.trim() ?? '';
  if (raw.isEmpty) return t.manga_chapter_download_status_failed;
  final String reason = describeOnlineSourceErrorText(raw);
  return '${t.manga_chapter_download_status_failed} · $reason';
}

/// 章节列表。
///
/// 作品页和阅读器里的「章节」弹层用**同一个** widget：两处对「已读怎么显示、
/// 当前章怎么高亮、排序默认哪个方向、下载状态怎么标」的答案必须一致，各写一份
/// 必然漂移。
///
/// 2026-10 M3E：行是作品详情骨架的分段列表行（[MediaDetailItemRow]）——话数
/// 序号胶囊、已读 = tertiary 对勾 + 标题降调、读了一半 = 行内进度条、当前章整行
/// primaryContainer、下载状态图标（排队 / 转圈 / 已下载 / 失败）；错峰进场。
class MangaChapterList extends StatefulWidget {
  const MangaChapterList({
    required this.entry,
    required this.states,
    required this.newestFirst,
    required this.unreadOnly,
    required this.onChapterTap,
    super.key,
    this.currentChapterKey,
    this.currentChapterAnchorKey,
    this.onSortToggled,
    this.onJumpToCurrent,
    this.onUnreadOnlyToggled,
    this.onToggleRead,
    this.onMarkUpToRead,
    this.showHeader = true,
    this.downloadedChapterKeys = const <String>{},
    this.jobsByChapterKey = const <String, MangaDownloadJobRow>{},
    this.onDownload,
    this.onDeleteDownload,
    this.onRevealDownload,
    this.onRetryDownload,
    this.onOcr,
    this.ocrRunningChapterKey,
    this.ocrProgress,
    this.ocrQueuedChapterKeys = const <String>{},
    this.languageScope,
    this.onSiblingSourceTap,
    this.onDownloadSelected,
    this.onMarkSelectedRead,
  });

  final OnlineMangaLibraryEntry? entry;
  final Map<String, MangaChapterStateRow> states;

  /// 源按新→旧返回，所以 `true` = 保持源顺序，`false` = 反转成第 1 话在前。
  final bool newestFirst;
  final bool unreadOnly;
  final String? currentChapterKey;

  /// 挂在当前章那一行上的 key：宿主拿它 `FushiFocusScroll.ensureVisible` 定位到当前章
  /// （阅读器章节抽屉打开即滚到当前章、作品页「跳到当前章节」）。当前章被筛掉
  /// （只看未读）时不挂，`currentContext` 为 null。
  final GlobalKey? currentChapterAnchorKey;

  final void Function(OnlineMangaChapter chapter) onChapterTap;
  final VoidCallback? onSortToggled;

  /// 区块标题里的「跳到当前章节」；null = 不出现（没有当前章 / 宿主不支持）。
  final VoidCallback? onJumpToCurrent;
  final VoidCallback? onUnreadOnlyToggled;
  final void Function(OnlineMangaChapter chapter)? onToggleRead;
  final void Function(OnlineMangaChapter chapter)? onMarkUpToRead;
  final bool showHeader;

  /// 下载状态位（设计稿 2026-09-12 §5）。两份输入合成一个状态：
  /// [downloadedChapterKeys] 是磁盘判据（`isChapterDownloaded`）的结果、
  /// [jobsByChapterKey] 是任务表里的行；下载中 / 排队 / 失败看任务行，已下载看
  /// 磁盘。默认都空 = 每章都显示成「未下载」（阅读器内的章节选择器只给磁盘那份）。
  final Set<String> downloadedChapterKeys;
  final Map<String, MangaDownloadJobRow> jobsByChapterKey;

  /// 溢出菜单里的下载动作；null = 不出现对应项。
  final void Function(OnlineMangaChapter chapter)? onDownload;
  final void Function(OnlineMangaChapter chapter)? onDeleteDownload;

  /// 「打开文件位置」（只对已下载的章出现）；null = 不出现（移动端没有文件管理器
  /// 契约，宿主据此不接）。
  final void Function(OnlineMangaChapter chapter)? onRevealDownload;
  final void Function(OnlineMangaChapter chapter)? onRetryDownload;

  /// 「识别本章」（只对已下载的章出现）；null = 不出现。
  final void Function(OnlineMangaChapter chapter)? onOcr;

  /// OCR 状态位（BUG-2481）：正在识别的那一章 + 页进度，以及排队中的章。
  final String? ocrRunningChapterKey;

  /// [uploading] = 远程引擎还在上传页图（计数是已上传页数，BUG-3605）。
  final ({int done, int total, bool uploading})? ocrProgress;
  final Set<String> ocrQueuedChapterKeys;

  /// 空章节列表的解释（BUG-2510）：该源只取哪种语言的章 + 同扩展其它语言的源。
  /// null = 不知道 / 不适用，空态沿用「还没有章节」。作品页只在「刷新已结束、
  /// 无错、0 话」时给，刷新途中或失败时都是 null——那两种情况各有自己的提示。
  final OnlineMangaSourceLanguageScope? languageScope;
  final void Function(OnlineMangaSiblingSource sibling)? onSiblingSourceTap;
  final Future<void> Function(List<OnlineMangaChapter> chapters)?
  onDownloadSelected;
  final Future<void> Function(List<OnlineMangaChapter> chapters)?
  onMarkSelectedRead;

  @override
  State<MangaChapterList> createState() => _MangaChapterListState();
}

class _MangaChapterListState extends State<MangaChapterList> {
  bool _selectionMode = false;
  final Set<String> _selectedKeys = <String>{};

  void _toggleSelection(String chapterKey) {
    setState(() {
      if (!_selectedKeys.add(chapterKey)) _selectedKeys.remove(chapterKey);
    });
  }

  void _clearSelection() {
    setState(() {
      _selectionMode = false;
      _selectedKeys.clear();
    });
  }

  /// 一章的下载状态：磁盘判据优先（真正决定能不能读），其次看任务行。
  _ChapterDownloadState _downloadStateOf(OnlineMangaChapter chapter) {
    if (widget.downloadedChapterKeys.contains(chapter.key)) {
      return _ChapterDownloadState.downloaded;
    }
    final MangaDownloadJobRow? job = widget.jobsByChapterKey[chapter.key];
    switch (job?.status) {
      case MangaDownloadJobStatus.queued:
        return _ChapterDownloadState.queued;
      case MangaDownloadJobStatus.paused:
        return _ChapterDownloadState.paused;
      case MangaDownloadJobStatus.running:
        return _ChapterDownloadState.downloading;
      case MangaDownloadJobStatus.failed:
        return _ChapterDownloadState.failed;
      default:
        return _ChapterDownloadState.notDownloaded;
    }
  }

  @override
  Widget build(BuildContext context) {
    final OnlineMangaLibraryEntry? entry = widget.entry;
    final List<OnlineMangaChapter> chapters =
        entry?.chapters ?? const <OnlineMangaChapter>[];
    final List<OnlineMangaChapter> visible = _visibleChapters(chapters);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        if (widget.showHeader) _buildHeader(context, chapters.length),
        if (chapters.isEmpty)
          _buildEmptyChapters(context)
        else if (visible.isEmpty)
          _buildEmpty(
            context,
            t.manga_series_all_read,
            icon: FushiIcons.success,
          )
        else
          for (int i = 0; i < visible.length; i++)
            _buildRow(context, visible[i], i, visible.length),
        if (_selectionMode)
          BatchActionBar(
            selectedCount: _selectedKeys
                .intersection(
                  visible
                      .map((OnlineMangaChapter chapter) => chapter.key)
                      .toSet(),
                )
                .length,
            onSelectAll: () => setState(
              () => _selectedKeys.addAll(
                visible.map((OnlineMangaChapter chapter) => chapter.key),
              ),
            ),
            onInvertSelection: () => setState(() {
              final Set<String> visibleKeys = visible
                  .map((OnlineMangaChapter chapter) => chapter.key)
                  .toSet();
              final Set<String> next = <String>{
                for (final String key in visibleKeys)
                  if (!_selectedKeys.contains(key)) key,
              };
              _selectedKeys
                ..removeAll(visibleKeys)
                ..addAll(next);
            }),
            actions: <Widget>[
              FushiIconButton(
                key: const ValueKey<String>('manga-chapter-batch-download'),
                tooltip: t.manga_chapter_download_action,
                icon: FushiIcons.download,
                enabled:
                    widget.onDownloadSelected != null &&
                    _selectedKeys
                        .intersection(
                          visible.map((OnlineMangaChapter c) => c.key).toSet(),
                        )
                        .isNotEmpty,
                onTap: () async {
                  final List<OnlineMangaChapter> selected = visible
                      .where(
                        (OnlineMangaChapter chapter) =>
                            _selectedKeys.contains(chapter.key),
                      )
                      .toList();
                  await widget.onDownloadSelected?.call(selected);
                  if (mounted) _clearSelection();
                },
              ),
              FushiIconButton(
                key: const ValueKey<String>('manga-chapter-batch-mark-read'),
                tooltip: t.manga_series_mark_read,
                icon: FushiIcons.success,
                enabled:
                    widget.onMarkSelectedRead != null &&
                    _selectedKeys
                        .intersection(
                          visible.map((OnlineMangaChapter c) => c.key).toSet(),
                        )
                        .isNotEmpty,
                onTap: () async {
                  final List<OnlineMangaChapter> selected = visible
                      .where(
                        (OnlineMangaChapter chapter) =>
                            _selectedKeys.contains(chapter.key),
                      )
                      .toList();
                  await widget.onMarkSelectedRead?.call(selected);
                  if (mounted) _clearSelection();
                },
              ),
            ],
          ),
      ],
    );
  }

  List<OnlineMangaChapter> _visibleChapters(List<OnlineMangaChapter> chapters) {
    final Iterable<OnlineMangaChapter> filtered = widget.unreadOnly
        ? chapters.where(
            (OnlineMangaChapter chapter) =>
                widget.states[chapter.key]?.readAt == null,
          )
        : chapters;
    final List<OnlineMangaChapter> ordered = filtered.toList(growable: false);
    if (widget.newestFirst) return ordered;
    return ordered.reversed.toList(growable: false);
  }

  /// 区块标题：「章节」+ 计数胶囊，行尾排序与只看未读。
  Widget _buildHeader(BuildContext context, int total) {
    return MediaDetailSectionHeader(
      t.mihon_chapters_title,
      count: total,
      padding: const EdgeInsets.fromLTRB(0, 16, 0, 8),
      trailing: Wrap(
        alignment: WrapAlignment.end,
        crossAxisAlignment: WrapCrossAlignment.center,
        spacing: 4,
        runSpacing: 4,
        children: <Widget>[
          if (widget.onDownloadSelected != null ||
              widget.onMarkSelectedRead != null)
            FushiIconButton(
              key: const ValueKey<String>('manga-chapter-select-mode'),
              tooltip: _selectionMode ? t.dialog_cancel : t.batch_select,
              icon: _selectionMode ? FushiIcons.close : FushiIcons.checklist,
              onTap: () => setState(() {
                _selectionMode = !_selectionMode;
                _selectedKeys.clear();
              }),
            ),
          // 纯图标省出标题位：几百话的作品标题行本来就挤（计数胶囊 + 只看未读），
          // 当前方向进 tooltip / 无障碍名称，列表本身的话数顺序一眼可见。
          if (widget.onSortToggled != null)
            Semantics(
              label: widget.newestFirst
                  ? t.manga_series_sort_newest
                  : t.manga_series_sort_oldest,
              child: FushiIconButtonControl(
                key: const ValueKey<String>('manga_chapter_sort'),
                tooltip: widget.newestFirst
                    ? t.manga_series_sort_newest
                    : t.manga_series_sort_oldest,
                onPressed: widget.onSortToggled,
                icon: const FushiIcon(FushiIcons.swapVert),
              ),
            ),
          if (widget.onJumpToCurrent != null)
            FushiIconButtonControl(
              key: const ValueKey<String>('manga_chapter_jump_current'),
              tooltip: t.manga_chapter_list_jump_current,
              onPressed: widget.onJumpToCurrent,
              icon: const FushiIcon(FushiIcons.myLocation),
            ),
          if (widget.onUnreadOnlyToggled != null) ...<Widget>[
            const SizedBox(width: 4),
            FushiSelectableChip(
              key: const ValueKey<String>('manga_chapter_unread_only'),
              label: t.manga_series_unread_only,
              selected: widget.unreadOnly,
              onSelected: (_) => widget.onUnreadOnlyToggled!(),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildEmptyChapters(BuildContext context) {
    final OnlineMangaSourceLanguageScope? scope = widget.languageScope;
    if (scope == null) return _buildEmpty(context, t.manga_series_no_chapters);
    final ThemeData theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 24),
      child: Column(
        children: <Widget>[
          Text(t.manga_series_no_chapters, style: theme.textTheme.bodyMedium),
          const SizedBox(height: 4),
          Text(
            t.manga_series_no_chapters_in_language(
              language: scope.language.toUpperCase(),
            ),
            key: const ValueKey<String>('manga_series_language_scope'),
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
            textAlign: TextAlign.center,
          ),
          if (scope.siblings.isNotEmpty) ...<Widget>[
            const SizedBox(height: 12),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              alignment: WrapAlignment.center,
              children: <Widget>[
                for (final OnlineMangaSiblingSource sibling in scope.siblings)
                  FushiActionChipControl(
                    key: ValueKey<String>(
                      'manga_series_sibling_${sibling.sourceId}',
                    ),
                    label: Text(
                      t.manga_series_try_sibling_language(
                        language: sibling.language.toUpperCase(),
                      ),
                    ),
                    onPressed: widget.onSiblingSourceTap == null
                        ? null
                        : () => widget.onSiblingSourceTap!(sibling),
                  ),
              ],
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildEmpty(
    BuildContext context,
    String message, {
    IconData icon = FushiIcons.manga,
  }) => FushiPlaceholderMessage(icon: icon, message: message);

  Widget _buildRow(
    BuildContext context,
    OnlineMangaChapter chapter,
    int index,
    int count,
  ) {
    final MangaChapterStateRow? state = widget.states[chapter.key];
    final bool read = state?.readAt != null;
    final bool current = chapter.key == widget.currentChapterKey;
    // 「读了一半」= 有状态行、没读完、且真的翻过页。开了一下就退出（lastPage 0）
    // 不算进度，显示成「读到 1/24 页」只会误导。
    final int lastPage = state?.lastPage ?? 0;
    final bool partial = !read && state != null && lastPage > 0;
    final int? pageCount = state?.pageCount;
    final _ChapterDownloadState download = _downloadStateOf(chapter);
    final MangaDownloadJobRow? job = widget.jobsByChapterKey[chapter.key];
    final int pagesTotal = job?.pagesTotal ?? 0;
    // 相邻章节常有相同下载状态，列表身份必须取章节 key；状态探针放在每章内部，
    // 避免重复 sibling key，且排序 / 下载状态变化时保留该章的进场状态。
    final GlobalKey? anchor = current ? widget.currentChapterAnchorKey : null;
    return FushiStaggeredEntrance(
      key: ValueKey<String>('manga_chapter_${chapter.key}'),
      index: index,
      child: KeyedSubtree(
        key: ValueKey<String>('manga_chapter_download_${download.name}'),
        child: _anchored(
          anchor,
          MediaDetailItemRow(
            index: index,
            count: count,
            title: chapter.name,
            number: _numberLabel(chapter),
            subtitle: _buildSubtitle(chapter, state, partial),
            // 几百话的表里一个行尾小图标扫不到，整行底色才是能一眼定位的信号。
            current: current,
            completed: read,
            progress: partial && pageCount != null && pageCount > 0
                ? (lastPage + 1) / pageCount
                : null,
            downloadState: switch (download) {
              _ChapterDownloadState.notDownloaded =>
                MediaDetailDownloadState.none,
              _ChapterDownloadState.queued => MediaDetailDownloadState.queued,
              _ChapterDownloadState.paused => MediaDetailDownloadState.queued,
              _ChapterDownloadState.downloading =>
                MediaDetailDownloadState.downloading,
              _ChapterDownloadState.downloaded =>
                MediaDetailDownloadState.downloaded,
              _ChapterDownloadState.failed => MediaDetailDownloadState.failed,
            },
            downloadProgress:
                download == _ChapterDownloadState.downloading && pagesTotal > 0
                ? ((job?.pagesDone ?? 0) / pagesTotal).clamp(0.0, 1.0)
                : null,
            trailing: _selectionMode ? null : _buildMenu(chapter, download),
            selected: _selectionMode
                ? _selectedKeys.contains(chapter.key)
                : null,
            onTap: () => _selectionMode
                ? _toggleSelection(chapter.key)
                : widget.onChapterTap(chapter),
          ),
        ),
      ),
    );
  }

  static Widget _anchored(GlobalKey? anchor, Widget child) =>
      anchor == null ? child : KeyedSubtree(key: anchor, child: child);

  /// 序号胶囊里的话数：整数话不带小数点；源没给（Mihon 用 -1 表示未知）就不画。
  static String? _numberLabel(OnlineMangaChapter chapter) {
    final double? number = chapter.number;
    if (number == null || number < 0) return null;
    if (number == number.truncateToDouble()) return '${number.toInt()}';
    return '$number';
  }

  String? _buildSubtitle(
    OnlineMangaChapter chapter,
    MangaChapterStateRow? state,
    bool partial,
  ) {
    final MangaDownloadJobRow? job = widget.jobsByChapterKey[chapter.key];
    final _ChapterDownloadState download = _downloadStateOf(chapter);
    final List<String> parts = <String>[
      if (chapter.scanlator?.isNotEmpty == true) chapter.scanlator!,
      if (chapter.uploadedAt != null) _formatDate(chapter.uploadedAt!),
      switch (download) {
        _ChapterDownloadState.queued => t.manga_chapter_download_status_queued,
        _ChapterDownloadState.paused => t.download_task_status_paused,
        _ChapterDownloadState.downloading =>
          t.manga_chapter_download_status_downloading(
            done: '${job?.pagesDone ?? 0}',
            total: '${job?.pagesTotal ?? 0}',
          ),
        _ChapterDownloadState.downloaded =>
          t.manga_chapter_download_status_downloaded,
        // 失败原因原样露出来：扩展抛的 `Log in via WebView ...` 之类正是用户要
        // 知道的下一步；只写「下载失败」等于把答案藏起来（BUG-2479）。
        _ChapterDownloadState.failed => mangaChapterDownloadFailedLabel(
          job?.lastError,
        ),
        _ChapterDownloadState.notDownloaded => t.manga_chapter_not_downloaded,
      },
      if (chapter.key == widget.ocrRunningChapterKey &&
          (widget.ocrProgress?.uploading ?? false))
        t.manga_remote_ocr_uploading(
          done: widget.ocrProgress?.done ?? 0,
          total: widget.ocrProgress?.total ?? 0,
        )
      else if (chapter.key == widget.ocrRunningChapterKey)
        t.manga_chapter_ocr_status_running(
          done: '${widget.ocrProgress?.done ?? 0}',
          total: '${widget.ocrProgress?.total ?? 0}',
        )
      else if (widget.ocrQueuedChapterKeys.contains(chapter.key))
        t.manga_chapter_ocr_status_queued,
      if (partial)
        state!.pageCount != null
            ? t.manga_series_read_progress(
                page: '${state.lastPage + 1}',
                total: '${state.pageCount}',
              )
            : t.manga_series_read_progress_partial(
                page: '${state.lastPage + 1}',
              ),
    ];
    if (parts.isEmpty) return null;
    return parts.join(' · ');
  }

  /// 行尾溢出菜单（已读 / 下载 / 识别）；一个动作都没接（阅读器章节弹层）时不画。
  Widget? _buildMenu(
    OnlineMangaChapter chapter,
    _ChapterDownloadState download,
  ) {
    final bool hasMenu =
        widget.onToggleRead != null ||
        widget.onMarkUpToRead != null ||
        widget.onDownload != null ||
        widget.onDeleteDownload != null ||
        widget.onRevealDownload != null ||
        widget.onRetryDownload != null ||
        widget.onOcr != null;
    if (!hasMenu) return null;
    return FushiOverflowMenu<String>(
      items: <PopupMenuEntry<String>>[
        if (widget.onToggleRead != null)
          FushiPopupMenuItem<String>(
            value: 'toggle-read',
            label: widget.states[chapter.key]?.readAt != null
                ? t.manga_series_mark_unread
                : t.manga_series_mark_read,
          ),
        if (widget.onMarkUpToRead != null)
          FushiPopupMenuItem<String>(
            value: 'mark-up-to',
            label: t.manga_series_mark_previous_read,
          ),
        if (widget.onDownload != null &&
            download == _ChapterDownloadState.notDownloaded)
          FushiPopupMenuItem<String>(
            value: 'download',
            label: t.manga_chapter_download_action,
          ),
        if (widget.onRetryDownload != null &&
            download == _ChapterDownloadState.failed)
          FushiPopupMenuItem<String>(
            value: 'retry-download',
            label: t.manga_chapter_download_retry_action,
          ),
        if (widget.onOcr != null &&
            download == _ChapterDownloadState.downloaded &&
            chapter.key != widget.ocrRunningChapterKey &&
            !widget.ocrQueuedChapterKeys.contains(chapter.key))
          FushiPopupMenuItem<String>(
            key: const ValueKey<String>('manga_chapter_ocr'),
            value: 'ocr',
            label: t.manga_chapter_ocr_action,
          ),
        if (widget.onRevealDownload != null &&
            download == _ChapterDownloadState.downloaded)
          FushiPopupMenuItem<String>(
            key: const ValueKey<String>('manga_chapter_reveal'),
            value: 'reveal-download',
            label: t.media_file_location_open,
          ),
        if (widget.onDeleteDownload != null &&
            download == _ChapterDownloadState.downloaded)
          FushiPopupMenuItem<String>(
            value: 'delete-download',
            label: t.manga_chapter_download_delete_action,
          ),
      ],
      onSelected: (String value) {
        switch (value) {
          case 'toggle-read':
            widget.onToggleRead?.call(chapter);
          case 'mark-up-to':
            widget.onMarkUpToRead?.call(chapter);
          case 'download':
            widget.onDownload?.call(chapter);
          case 'retry-download':
            widget.onRetryDownload?.call(chapter);
          case 'reveal-download':
            widget.onRevealDownload?.call(chapter);
          case 'delete-download':
            widget.onDeleteDownload?.call(chapter);
          case 'ocr':
            widget.onOcr?.call(chapter);
        }
      },
    );
  }

  static String _formatDate(int millis) {
    final DateTime date = DateTime.fromMillisecondsSinceEpoch(millis);
    final String month = date.month.toString().padLeft(2, '0');
    final String day = date.day.toString().padLeft(2, '0');
    return '${date.year}-$month-$day';
  }
}

/// 把挂了 [anchor]（[MangaChapterList.currentChapterAnchorKey]）的当前章行滚进
/// 视口，停在视口偏上（30%）处，上下文各留几话。返回是否找到当前章行（被「只看
/// 未读」筛掉 / 没有当前章时为 false，什么都不滚）。
///
/// 阅读器章节抽屉与作品页「跳到当前章节」共用；[duration] 为零时直接跳。
bool scrollToMangaChapterAnchor(
  GlobalKey anchor, {
  Duration duration = Duration.zero,
}) {
  final BuildContext? target = anchor.currentContext;
  if (target == null) return false;
  unawaited(
    FushiFocusScroll.ensureVisible(
      target,
      alignment: 0.3,
      duration: duration,
      curve: FushiMotion.standard,
    ),
  );
  return true;
}

/// 长章节表的快速滚动条：一条可拖动的滚动条，几百话直接拖到想去的位置。
///
/// 只在移动端加：桌面端 [ScrollBehavior] 已经给竖向滚动视图套了可拖动的滚动条，
/// 再套一层会画两条。[notificationPredicate] 用来在多个滚动视图并存（作品页宽屏
/// 两栏）时只跟正文那一个。
class MangaChapterFastScrollbar extends StatelessWidget {
  const MangaChapterFastScrollbar({
    required this.controller,
    required this.child,
    super.key,
    this.thumbVisibility = false,
    this.notificationPredicate,
  });

  final ScrollController controller;
  final Widget child;
  final bool thumbVisibility;
  final ScrollNotificationPredicate? notificationPredicate;

  /// 当前平台是否需要补这条滚动条（桌面端已自带）。
  static bool neededOn(TargetPlatform platform) => switch (platform) {
    TargetPlatform.android ||
    TargetPlatform.iOS ||
    TargetPlatform.fuchsia => true,
    TargetPlatform.linux ||
    TargetPlatform.macOS ||
    TargetPlatform.windows => false,
  };

  @override
  Widget build(BuildContext context) {
    if (!neededOn(Theme.of(context).platform)) return child;
    return Scrollbar(
      key: const ValueKey<String>('manga_chapter_fast_scrollbar'),
      controller: controller,
      thumbVisibility: thumbVisibility,
      interactive: true,
      notificationPredicate:
          notificationPredicate ?? defaultScrollNotificationPredicate,
      child: child,
    );
  }
}
