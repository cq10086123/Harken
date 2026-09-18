import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;

import '../../../state/song_state.dart';
import '../local/local_library_service.dart';
import '../source_config.dart';
import '../../db/dao/song_dao.dart';
import '../local/local_audio_extensions.dart';
import '../local/local_song_builder.dart';
import '../local/local_tag_probe.dart';
import 'webdav_client.dart';

/// WebDAV 扫描进度。
class WebDavScanProgress {
  final int filesProcessed;
  final int filesFound;

  const WebDavScanProgress({required this.filesProcessed, required this.filesFound});
}

/// WebDAV 扫描结果摘要。
class WebDavScanSummary {
  final int scanned;
  final int added;
  final int updated;
  final int reused;
  final int markedDeleted;

  const WebDavScanSummary({
    this.scanned = 0,
    this.added = 0,
    this.updated = 0,
    this.reused = 0,
    this.markedDeleted = 0,
  });
}

/// 扫描器对配置的最小依赖面（便于测试替身）。
abstract class WebDavSourceConfigLike {
  String get id;
  List<String> get allEndpoints;
  String get username;
  String get password;
  bool get ignoreSsl;
  String get path;
  List<String> get excludeFolders;
  bool get scrapeTagsOnScan;
}

/// WebDAV 音源扫描：递归 PROPFIND → 音频文件 → SongEntity 入库。
///
/// 元数据策略（对齐本地扫描的回退链）：
/// - `scrapeTagsOnScan = true`：把文件下载到临时目录后用 [probeLocalTags]
///   读完整标签（标题/歌手/专辑/轨道号/时长/码率/采样率），读完即删。
///   **慢**（每首下载一次），但元数据全；文件超过 [maxProbeBytes] 只走
///   文件名，避免 DSD 大文件把扫描拖到小时级。
/// - `false`：只用文件名与目录名（标题=文件名、专辑=所在文件夹名、
///   歌手=未知艺术家），秒扫。
///
/// 歌曲 ID = [webdavSongId]——**与 endpoint 无关**：换备用地址（内网 ↔
/// 隧道）不会让收藏/歌单/播放历史丢失。
class WebDavScanner {
  /// 标签探测的文件大小上限：超过则只走文件名。
  static const int maxProbeBytes = 80 * 1024 * 1024;

  Future<WebDavScanSummary> scanSource(
    WebDavSourceConfigLike config, {
    bool Function()? isCancelled,
    void Function(WebDavScanProgress progress)? onProgress,
    void Function()? onBatchImported,
  }) async {
    final sourceId = config.id;
    final client = WebDavClient(
      endpoints: config.allEndpoints,
      username: config.username,
      password: config.password,
      ignoreSsl: config.ignoreSsl,
    );

    // ── 1. 递归枚举音频文件 ─────────────────────────────────────
    final files = <WebDavResource>[];
    final root = normalizeDirPath(config.path);
    var dirsVisited = 0;

    void reportDirs() {
      onProgress?.call(
        WebDavScanProgress(
          filesProcessed: dirsVisited,
          filesFound: files.length,
        ),
      );
    }

    Future<void> walk(String dir) async {
      if (isCancelled?.call() ?? false) return;
      dirsVisited++;
      reportDirs();
      final List<WebDavResource> items;
      try {
        items = await client.list(dir);
      } catch (e) {
        debugPrint('[WebDavScanner] 列目录失败 $dir: $e');
        return; // 单个目录失败不拖垮整个扫描
      }
      for (final item in items) {
        if (isCancelled?.call() ?? false) return;
        if (item.isDirectory) {
          final name = item.name;
          if (localScanSkippedDirNames.contains(name)) continue;
          if (config.excludeFolders.contains(name)) continue;
          await walk(normalizeDirPath(item.path));
        } else {
          final ext = p.extension(item.path).replaceAll('.', '').toLowerCase();
          if (!localAudioExtensions.contains(ext)) continue;
          files.add(item);
          reportDirs();
        }
      }
    }

    await walk(root);
    debugPrint(
      '[WebDavScanner] 枚举完成：${files.length} 个音频文件（$dirsVisited 个目录）',
    );

    if (isCancelled?.call() ?? false) return const WebDavScanSummary();

    // ── 2. 旧行（增量判断 + 复用）───────────────────────────────
    final songDao = SongDao.instance;
    final existingIds = await songDao.fetchIdsBySource(sourceId);
    final existingById = <String, SongEntity>{};
    if (existingIds.isNotEmpty) {
      for (final s in await songDao.fetchByIds(existingIds)) {
        existingById[s.id] = s;
      }
    }

    // ── 3. 逐首构建实体 ─────────────────────────────────────────
    Directory? tempDir;
    if (config.scrapeTagsOnScan && files.isNotEmpty) {
      tempDir = await Directory.systemTemp.createTemp('webdav_tags');
    }

    var added = 0, updated = 0, reused = 0;
    final pending = <SongEntity>[];
    final seenIds = <String>{};
    final clock = Stopwatch()..start();
    var lastReportMs = -1000;

    Future<void> flush() async {
      if (pending.isEmpty) return;
      final batch = List<SongEntity>.from(pending);
      pending.clear();
      await songDao.upsertSongs(batch);
    }

    void reportFile(int processed) {
      if (onProgress == null) return;
      final elapsed = clock.elapsedMilliseconds;
      if (elapsed - lastReportMs < 200 && processed != files.length) return;
      lastReportMs = elapsed;
      onProgress(
        WebDavScanProgress(filesProcessed: processed, filesFound: files.length),
      );
    }

    try {
      for (var i = 0; i < files.length; i++) {
        if (isCancelled?.call() ?? false) break;
        final file = files[i];
        final serverPath = normalizeDirPath(file.path);
        final id = webdavSongId(sourceId, serverPath);
        if (!seenIds.add(id)) continue; // 重复挂载/硬链接去重
        final existing = existingById[id];
        final url = client.fileUrl(file.path);

        // 增量命中：文件没变、标签已解析过、且本次不强制重读 → 复用旧行。
        final unchanged = existing != null &&
            existing.tagsParsed == true &&
            existing.fileSize != null &&
            existing.fileSize == file.size &&
            !config.scrapeTagsOnScan;
        if (unchanged) {
          reused++;
          if (existing.uri != url) {
            pending.add(existing.copyWith(uri: url));
          }
          reportFile(i + 1);
          continue;
        }

        LocalTagProbeResult? tags;
        if (tempDir != null &&
            (file.size ?? 0) > 0 &&
            file.size! <= maxProbeBytes) {
          try {
            final temp = File(p.join(tempDir.path, 'probe_$i.bin'));
            await client.downloadTo(file.path, temp);
            tags = await probeLocalTags(
              temp.path,
              includeArtwork: false,
              includeLyrics: false,
            );
            if (temp.existsSync()) temp.deleteSync();
          } catch (e) {
            debugPrint('[WebDavScanner] 标签读取失败 ${file.name}: $e');
          }
        }

        final fileName = p.basenameWithoutExtension(file.path);
        final entity = SongEntity(
          id: id,
          title: _firstNonEmpty(tags?.title, fileName),
          artist: LocalSongBuilder.encodeArtist(
            _firstNonEmpty(tags?.artist, '未知艺术家'),
          ),
          album: LocalSongBuilder.encodeAlbum(
            _firstNonEmpty(tags?.album, _folderNameOf(serverPath) ?? '未知专辑'),
          ),
          uri: url,
          isLocal: false,
          sourceId: sourceId,
          tagsParsed: tags?.tagsParsed ?? false,
          durationMs:
              (tags?.durationMs ?? 0) > 0 ? tags!.durationMs : null,
          bitrate: tags?.bitrate,
          sampleRate: tags?.sampleRate,
          fileSize: file.size,
          fileModifiedMs: file.modified?.millisecondsSinceEpoch,
          format: _firstNonEmpty(
            tags?.format,
            p.extension(file.path).replaceAll('.', '').toLowerCase(),
          ),
          trackNumber: tags?.trackNumber,
          discNumber: tags?.discNumber,
          updatedAt: DateTime.now().millisecondsSinceEpoch,
          isAudioFileDeleted: false,
        );
        if (existing == null) {
          added++;
        } else {
          updated++;
        }
        pending.add(entity);
        if (pending.length >= 8) {
          await flush();
          onBatchImported?.call();
        }
        reportFile(i + 1);
      }
      await flush();
      onBatchImported?.call();
    } finally {
      try {
        tempDir?.deleteSync(recursive: true);
      } catch (_) {}
    }

    // ── 4. 上次扫到、这次没了 → 标记失效（不硬删除：歌单/收藏还有引用）─
    final missing = existingIds.where((id) => !seenIds.contains(id)).toList();
    var markedDeleted = 0;
    if (missing.isNotEmpty) {
      final rows = await songDao.fetchByIds(missing);
      final toMark = rows
          .where((s) => !s.isAudioFileDeleted)
          .map((s) => s.copyWith(isAudioFileDeleted: true))
          .toList();
      if (toMark.isNotEmpty) {
        await songDao.upsertSongs(toMark);
        markedDeleted = toMark.length;
      }
    }

    debugPrint(
      '[WebDavScanner] 完成：${files.length} 首 '
      '(新增 $added · 更新 $updated · 复用 $reused · 失效 $markedDeleted)',
    );
    return WebDavScanSummary(
      scanned: files.length,
      added: added,
      updated: updated,
      reused: reused,
      markedDeleted: markedDeleted,
    );
  }
}

/// 歌曲 ID：`<sourceId>|<小写服务器路径>`。
///
/// 与 endpoint 无关（换备用地址不换 ID），与 sourceId 绑定（两台 NAS 上
/// 同路径不会撞车）。小写归一让 `Music/a.flac` 与 `music/A.flac` 视为同一路径。
String webdavSongId(String sourceId, String serverPath) {
  final normalized = normalizeDirPath(serverPath);
  return '$sourceId|${normalized.toLowerCase()}';
}

String _firstNonEmpty(String? a, String b) {
  if (a != null && a.trim().isNotEmpty) return a.trim();
  return b;
}

String? _folderNameOf(String serverPath) {
  final normalized = normalizeDirPath(serverPath);
  if (normalized.isEmpty) return null;
  final idx = normalized.lastIndexOf('/');
  final name = idx < 0 ? normalized : normalized.substring(idx + 1);
  return name.isEmpty ? null : name;
}

/// WebDAV 扫描的**全局会话**。
///
/// 扫描状态不再绑在音源管理页的 State 上：退出页面扫描照常进行
/// （写库不中断），回到页面进度原样恢复，也不会因重复进入而并发开两个
/// 扫描。进度/结果用 ValueNotifier 表达，页面直接监听。
class WebDavScanSession {
  WebDavScanSession._();

  static final WebDavScanSession instance = WebDavScanSession._();

  /// 正在扫描的音源 id；null = 空闲。
  final ValueNotifier<String?> runningSourceId = ValueNotifier(null);

  /// 正在扫描的音源名（进度区展示用）。
  final ValueNotifier<String> runningSourceName = ValueNotifier('');

  final ValueNotifier<WebDavScanProgress?> progress =
      ValueNotifier(null);

  final ValueNotifier<WebDavScanSummary?> lastSummary =
      ValueNotifier(null);

  bool _cancelRequested = false;
  Future<void>? _running;

  bool get isRunning => runningSourceId.value != null;

  void cancel() => _cancelRequested = true;

  /// 启动扫描。已有扫描在跑时直接忽略（不并发）。
  Future<void> start(WebDavSourceConfig config) async {
    if (isRunning) {
      debugPrint('[WebDavScanSession] 已有扫描在跑，忽略本次请求');
      return;
    }
    _cancelRequested = false;
    runningSourceId.value = config.id;
    runningSourceName.value = config.name;
    progress.value = null;
    lastSummary.value = null;
    _running = _run(config);
  }

  Future<void> _run(WebDavSourceConfig config) async {
    try {
      final summary = await WebDavScanner().scanSource(
        config,
        isCancelled: () => _cancelRequested,
        onProgress: (p) => progress.value = p,
        onBatchImported: () => LocalLibraryService.revision.value++,
      );
      lastSummary.value = summary;
      // 完成后最后一批可能仍在上面的回调里刷过一次；再兜底广播一次。
      LocalLibraryService.revision.value++;
    } catch (e, st) {
      debugPrint('[WebDavScanSession] 扫描失败: $e\n$st');
      lastSummary.value = const WebDavScanSummary();
    } finally {
      runningSourceId.value = null;
      runningSourceName.value = '';
      _running = null;
    }
  }
}
