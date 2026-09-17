import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../../state/song_state.dart';
import '../../db/dao/song_dao.dart';
import '../source_config.dart';
import 'local_album_cover.dart';
import 'local_cover_store.dart';
import 'local_scanner.dart';
import 'local_song_builder.dart';
import 'local_song_id.dart';
import 'local_tag_probe.dart';

/// 一次扫描的结果统计。
class LocalScanSummary {
  /// 扫描到的音频文件总数。
  final int scanned;

  /// 新入库的行数（由 `SongDao.upsertSongs` 返回，是权威计数）。
  final int added;

  /// 标签有变化，更新了。
  final int updated;

  /// 增量命中，复用库里原有行。
  final int reused;

  /// 被过滤掉（时长不足等）。
  final int skipped;

  /// 从库里标记为「文件已删除」。
  final int markedDeleted;

  /// 自己没封面、用了专辑封面（目录旁挂图或同目录其它歌的内嵌图）的歌数。
  final int albumCoverApplied;

  const LocalScanSummary({
    this.scanned = 0,
    this.added = 0,
    this.updated = 0,
    this.reused = 0,
    this.skipped = 0,
    this.markedDeleted = 0,
    this.albumCoverApplied = 0,
  });

  @override
  String toString() =>
      'LocalScanSummary(scanned=$scanned, added=$added, updated=$updated, '
      'reused=$reused, skipped=$skipped, markedDeleted=$markedDeleted, '
      'albumCoverApplied=$albumCoverApplied)';
}

/// 扫描过程中的可变计数器。
///
/// 抽成对象是因为按目录分组后，计数发生在被调用的方法里，用返回值传递
/// 七个数字既啰嗦又容易漏。
class _ScanCounters {
  int processed = 0;
  int updated = 0;
  int reused = 0;
  int skipped = 0;
  int albumCoverApplied = 0;
}

/// 本地音源提供者：目录扫描 → 标签解析 → 专辑封面 → 写入 `songs` 表。
///
/// 各块能力（`LocalScanner` / `probeLocalTags` / `LocalAlbumCover` /
/// `LocalSongBuilder`）都独立可测，本类只负责串起来并处理批处理与进度，
/// 自身不含判断逻辑。
///
/// **纯 `dart:io`，无平台分支** —— Android / iOS / Windows 走同一条路径。
/// 系统媒体库（`photo_manager`）是另一条独立入口，不进这里。
class LocalSourceProvider {
  LocalSourceProvider({SongDao? songDao, LocalScanner? scanner})
    : _songDao = songDao ?? SongDao.instance,
      _scanner = scanner ?? const LocalScanner();

  final SongDao _songDao;
  final LocalScanner _scanner;

  /// SQLite 的绑定变量上限。
  ///
  /// `SongDao.fetchByIds` 不做分批（它把所有 id 拼进一条 `IN (...)`），而本地
  /// 曲库动辄几千首，一次传入会撞上 SQLITE_MAX_VARIABLE_NUMBER。这里自己切。
  static const int _idBatchSize = 400;

  /// 攒够这么多首就写一次库，避免把整库歌曲都持有在内存里。
  static const int _upsertBatchSize = 100;

  /// 扫描一个本地音源。
  ///
  /// 读标签 / 落封面 / 最短时长三项默认取 [source] 上的配置（用户在设置页
  /// 调的就是那几项），仅在测试或一次性覆盖时才显式传参。
  ///
  /// **按目录（= 专辑）成组处理**，因为封面要在目录内共享：
  /// 歌曲自己有内嵌封面就用自己的，没有就退到该目录的专辑封面
  /// （`folder.jpg` 之类旁挂图，或同目录其它歌的内嵌图）。
  ///
  /// - [isCancelled] 返回 true 时尽早停止，已扫到的部分仍会入库；
  /// - [onProgress] 已按「≥200ms 或 ≥20 首」节流（沿用上游做法）；
  /// - 单个文件读标签失败不影响其余文件。
  Future<LocalScanSummary> scanSource(
    LocalSourceConfig source, {
    ValueGetter<bool>? isCancelled,
    void Function(LocalScanProgress progress)? onProgress,
    bool? readTags,
    bool? cacheArtwork,
    int? minDurationMs,
  }) async {
    final sourceId = source.id;
    final doReadTags = readTags ?? source.readFullTagsOnScan;
    final doCacheArtwork = cacheArtwork ?? source.cacheArtwork;
    final durationFloor = minDurationMs ?? source.minDurationMs;

    // ── 1. 枚举文件（不读内容，很快）；顺带收集目录里的图片名 ──────
    final scanResult = await _scanner.scanWithCovers(
      source.includePaths,
      isCancelled: isCancelled,
    );
    final entries = scanResult.entries;
    if (isCancelled?.call() ?? false) return const LocalScanSummary();

    final total = entries.length;

    // ── 2. 取这些路径在库里的旧行（增量判断要用）──────────────────
    final existingById = await _fetchExistingById(entries);

    // ── 3. 按目录成组处理 ────────────────────────────────────────
    final counters = _ScanCounters();
    final pending = <SongEntity>[];
    var added = 0;

    final clock = Stopwatch()..start();
    var lastReportMs = -1000;
    var lastReportProcessed = -1;

    void reportProgress({bool force = false}) {
      if (onProgress == null) return;
      final elapsed = clock.elapsedMilliseconds;
      // 双条件节流：只按时间会在超大曲库上刷屏，只按数量会在慢盘上长时间无反馈。
      final enoughTime = elapsed - lastReportMs >= 200;
      final enoughCount = counters.processed - lastReportProcessed >= 20;
      if (!force && !enoughTime && !enoughCount) return;
      lastReportMs = elapsed;
      lastReportProcessed = counters.processed;
      onProgress(
        LocalScanProgress(dirsVisited: counters.processed, filesFound: total),
      );
    }

    Future<void> flush() async {
      if (pending.isEmpty) return;
      final batch = List<SongEntity>.from(pending);
      pending.clear();
      added += await _songDao.upsertSongs(batch);
    }

    final byDirectory = LocalAlbumCover.groupByDirectory(
      entries,
      (e) => e.path,
    );

    for (final dirEntry in byDirectory.entries) {
      if (isCancelled?.call() ?? false) break;

      await _scanOneDirectory(
        dirPath: dirEntry.key,
        dirEntries: dirEntry.value,
        imageNames:
            scanResult.imagesByDirectory[dirEntry.key] ?? const <String>[],
        existingById: existingById,
        sourceId: sourceId,
        doReadTags: doReadTags,
        doCacheArtwork: doCacheArtwork,
        durationFloor: durationFloor,
        counters: counters,
        pending: pending,
        flush: flush,
        isCancelled: isCancelled,
        reportProgress: reportProgress,
      );
    }

    await flush();
    reportProgress(force: true);

    // ── 4. 上次扫到、这次没了的文件 → 标记失效 ────────────────────
    final markedDeleted = await _markMissingDeleted(
      sourceId: sourceId,
      seenIds: {for (final e in entries) localSongId(e.path)},
      isCancelled: isCancelled,
    );

    return LocalScanSummary(
      scanned: total,
      added: added,
      updated: counters.updated,
      reused: counters.reused,
      skipped: counters.skipped,
      markedDeleted: markedDeleted,
      albumCoverApplied: counters.albumCoverApplied,
    );
  }

  /// 处理一个目录（= 一张专辑）。
  ///
  /// 两遍走：先把每首歌的标签和它自己的封面读出来落盘，**再**决定专辑封面
  /// 并回填给没封面的歌。必须先走完第一遍才知道这张专辑有没有内嵌图 ——
  /// 带图的那首可能排在没图的那首后面。
  ///
  /// 内存是平的：内嵌图读到就立刻落盘换成路径，不在内存里攒字节。
  Future<void> _scanOneDirectory({
    required String dirPath,
    required List<LocalScanEntry> dirEntries,
    required List<String> imageNames,
    required Map<String, SongEntity> existingById,
    required String sourceId,
    required bool doReadTags,
    required bool doCacheArtwork,
    required int durationFloor,
    required _ScanCounters counters,
    required List<SongEntity> pending,
    required Future<void> Function() flush,
    required ValueGetter<bool>? isCancelled,
    required void Function({bool force}) reportProgress,
  }) async {
    // 旁挂图直接用**原文件路径**，不拷进缓存：那是用户自己的文件，
    // 拷一份纯属浪费空间，而且 LocalCoverStore 的清理逻辑绝不能碰它
    // （isManagedPath 会正确地返回 false）。
    final sidecarName = LocalAlbumCover.pickSidecarCover(imageNames);
    final sidecarPath = sidecarName == null
        ? null
        : '$dirPath/$sidecarName';

    /// 每首歌的第一遍结果。
    final probed = <_ProbedSong>[];
    String? firstEmbeddedCover;

    for (final entry in dirEntries) {
      if (isCancelled?.call() ?? false) break;

      final songId = localSongId(entry.path);
      final existing = existingById[songId];

      // 文件没动过：复用原行，不读标签。这是增量扫描省下两个数量级 IO 的地方。
      if (!LocalSongBuilder.shouldReprobe(existing, entry)) {
        pending.add(LocalSongBuilder.reuse(existing!, entry));
        counters.reused++;
        counters.processed++;
        reportProgress();
        if (pending.length >= _upsertBatchSize) await flush();
        continue;
      }

      LocalTagProbeResult? tags;
      if (doReadTags) {
        try {
          tags = await probeLocalTags(
            entry.path,
            includeArtwork: doCacheArtwork,
          );
        } catch (e) {
          if (kDebugMode) {
            debugPrint('[LocalSource] 标签读取异常 ${entry.path}: $e');
          }
          tags = null;
        }
      }

      final durationMs = tags?.durationMs;
      if (durationFloor > 0 && durationMs != null && durationMs < durationFloor) {
        counters.skipped++;
        counters.processed++;
        reportProgress();
        continue;
      }

      String? ownCover;
      final artwork = tags?.artwork;
      if (doCacheArtwork && artwork != null && artwork.isNotEmpty) {
        ownCover = await LocalCoverStore.save(
          songId: songId,
          bytes: artwork,
          fileModifiedMs: entry.fileModifiedMs,
        );
        // 记住这张专辑第一张能读到的内嵌图，作为没有旁挂图时的专辑封面。
        firstEmbeddedCover ??= ownCover;
      }

      probed.add(
        _ProbedSong(entry: entry, tags: tags, existing: existing, ownCover: ownCover),
      );
      counters.processed++;
      reportProgress();
    }

    // 专辑封面：旁挂图优先，其次同目录第一张内嵌图。
    final albumCover = sidecarPath ?? firstEmbeddedCover;

    for (final item in probed) {
      final coverPath = item.ownCover ?? albumCover;
      if (item.ownCover == null && albumCover != null) {
        counters.albumCoverApplied++;
      }

      pending.add(
        LocalSongBuilder.build(
          entry: item.entry,
          sourceId: sourceId,
          tags: item.tags,
          existing: item.existing,
          coverPath: coverPath,
        ),
      );
      // 「新增」计数以 upsertSongs 的返回值为准（只有它知道行原本是否存在），
      // 这里只统计「已有行被更新」。
      if (item.existing != null) counters.updated++;

      if (pending.length >= _upsertBatchSize) await flush();
    }
  }

  Future<Map<String, SongEntity>> _fetchExistingById(
    List<LocalScanEntry> entries,
  ) async {
    final ids = entries.map((e) => localSongId(e.path)).toList();
    final result = <String, SongEntity>{};
    for (var i = 0; i < ids.length; i += _idBatchSize) {
      final end = (i + _idBatchSize).clamp(0, ids.length);
      final rows = await _songDao.fetchByIds(ids.sublist(i, end));
      for (final row in rows) {
        result[row.id] = row;
      }
    }
    return result;
  }

  /// 把「上次属于这个音源、这次没扫到」的歌标记为文件已删除。
  ///
  /// 不直接删行：用户可能在它上面有歌单/播放历史引用，删行会留下悬空引用。
  /// 标记失效由列表页灰显，用户可手动清理。
  Future<int> _markMissingDeleted({
    required String sourceId,
    required Set<String> seenIds,
    ValueGetter<bool>? isCancelled,
  }) async {
    final knownIds = await _songDao.fetchIdsBySource(sourceId);
    if (knownIds.isEmpty) return 0;

    final missing = knownIds.where((id) => !seenIds.contains(id)).toList();
    if (missing.isEmpty) return 0;

    var marked = 0;
    for (var i = 0; i < missing.length; i += _idBatchSize) {
      if (isCancelled?.call() ?? false) break;
      final end = (i + _idBatchSize).clamp(0, missing.length);
      final batch = missing.sublist(i, end);
      final rows = await _songDao.fetchByIds(batch);
      final toUpdate = rows
          .where((s) => !s.isAudioFileDeleted)
          .map((s) => s.copyWith(isAudioFileDeleted: true))
          .toList();
      if (toUpdate.isNotEmpty) {
        await _songDao.upsertSongs(toUpdate);
        marked += toUpdate.length;
      }
    }
    return marked;
  }
}

/// 第一遍扫描的中间结果。
class _ProbedSong {
  final LocalScanEntry entry;
  final LocalTagProbeResult? tags;
  final SongEntity? existing;

  /// 这首歌自己的内嵌封面落盘路径；没有内嵌图时为 null。
  final String? ownCover;

  const _ProbedSong({
    required this.entry,
    required this.tags,
    required this.existing,
    required this.ownCover,
  });
}
