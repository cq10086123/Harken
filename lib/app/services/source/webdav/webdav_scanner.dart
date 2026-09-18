import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;

import '../../../state/song_state.dart';
import '../../db/dao/song_dao.dart';
import '../local/local_audio_extensions.dart';
import '../local/local_library_service.dart';
import '../local/local_song_builder.dart';
import '../local/local_tag_probe.dart';
import '../source_config.dart';
import 'webdav_client.dart';

/// 扫描进度。
class WebDavScanProgress {
  /// 当前正在处理的目录（服务器路径）。
  final String currentDir;

  /// 已访问的目录数。
  final int dirsVisited;

  /// 累计发现的音频文件数。
  final int filesFound;

  /// 累计入库（写入 DB）的歌曲数——**边扫边入库**，列表页靠这个数字增长。
  final int filesImported;

  const WebDavScanProgress({
    required this.currentDir,
    required this.dirsVisited,
    required this.filesFound,
    required this.filesImported,
  });
}

/// 扫描结果摘要。
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

/// WebDAV 音源扫描：**边枚举边入库**。
///
/// 旧结构是「先递归枚举整棵树、再统一入库」——范围是 `/` 时枚举要几分钟，
/// 期间库里零数据、专辑页毫无动静，用户只能干等。现在**每处理完一个目录
/// 就把该目录的歌写入 DB 并广播库版本号**：第一本书扫完专辑页就有了。
///
/// 元数据策略（对齐本地扫描的回退链）：
/// - `scrapeTagsOnScan = true`：把文件下载到临时目录后用 [probeLocalTags]
///   读完整标签，读完即删。慢（每首下载一次）；文件超过 [maxProbeBytes]
///   只走文件名。
/// - `false`：只用文件名与目录名，秒扫。
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

    final songDao = SongDao.instance;
    final existingIds = await songDao.fetchIdsBySource(sourceId);
    final existingById = <String, SongEntity>{};
    if (existingIds.isNotEmpty) {
      for (final s in await songDao.fetchByIds(existingIds)) {
        existingById[s.id] = s;
      }
    }

    Directory? tempDir;
    if (config.scrapeTagsOnScan) {
      tempDir = await Directory.systemTemp.createTemp('webdav_tags');
    }

    var dirsVisited = 0;
    var filesFound = 0;
    var filesImported = 0;
    var added = 0, updated = 0, reused = 0;
    final pending = <SongEntity>[];
    final seenIds = <String>{};
    final seenAudioDirs = <String>{};

    void report(String dir) {
      onProgress?.call(WebDavScanProgress(
        currentDir: dir,
        dirsVisited: dirsVisited,
        filesFound: filesFound,
        filesImported: filesImported,
      ));
    }

    Future<void> flush() async {
      if (pending.isEmpty) return;
      final batch = List<SongEntity>.from(pending);
      pending.clear();
      await songDao.upsertSongs(batch);
      filesImported += batch.length;
      onBatchImported?.call();
    }

    Future<void> importFile(
      WebDavResource file,
      String serverPath,
      Directory? tempDir,
    ) async {
      final id = webdavSongId(sourceId, serverPath);
      if (!seenIds.add(id)) return; // 重复挂载/硬链接去重
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
        return;
      }

      LocalTagProbeResult? tags;
      if (tempDir != null &&
          (file.size ?? 0) > 0 &&
          file.size! <= maxProbeBytes) {
        try {
          final temp = File(p.join(tempDir.path,
              'probe_${serverPath.hashCode.abs()}_${filesFound}.bin'));
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
        durationMs: (tags?.durationMs ?? 0) > 0 ? tags!.durationMs : null,
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
    }

    /// 深度优先：处理完一个目录的歌**立刻入库**，再递归子目录。
    /// [isRoot] 为 true 时失败必须向上抛——顶层失败（鉴权/路径/解析）被
    /// 单目录兜底吞掉的话，用户只会看到「完成 0 首」而无任何线索。
    Future<void> walk(String dir, {bool isRoot = false}) async {
      if (isCancelled?.call() ?? false) return;
      dirsVisited++;
      report(dir);
      final List<WebDavResource> items;
      try {
        items = await client.list(dir);
      } catch (e) {
        debugPrint('[WebDavScanner] 列目录失败 $dir: $e');
        if (isRoot) rethrow;
        return;
      }
      final dirKey = normalizeDirPath(dir);
      if (seenAudioDirs.add(dirKey)) {
        // 只对本目录的音频文件做入库（子目录交给递归）。
        for (final item in items) {
          if (isCancelled?.call() ?? false) return;
          if (item.isDirectory) continue;
          final ext =
              p.extension(item.path).replaceAll('.', '').toLowerCase();
          if (!localAudioExtensions.contains(ext)) continue;
          filesFound++;
          await importFile(item, normalizeDirPath(item.path), tempDir);
          if (pending.length >= 8) await flush();
        }
        await flush(); // 目录边界：专辑颗粒度 immediate 可见
        report(dir);
      }
      for (final item in items) {
        if (isCancelled?.call() ?? false) return;
        if (!item.isDirectory) continue;
        final name = item.name;
        if (localScanSkippedDirNames.contains(name)) continue;
        if (config.excludeFolders.contains(name)) continue;
        await walk(normalizeDirPath(item.path));
      }
    }

    try {
      await walk(normalizeDirPath(config.path), isRoot: true);
      await flush();
    } finally {
      try {
        tempDir?.deleteSync(recursive: true);
      } catch (_) {}
    }

    // ── 上次扫到、这次没了 → 标记失效（不硬删除：歌单/收藏还有引用）─
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
      '[WebDavScanner] 完成：${seenIds.length} 首 '
      '(新增 $added · 更新 $updated · 复用 $reused · 失效 $markedDeleted)',
    );
    return WebDavScanSummary(
      scanned: seenIds.length,
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
/// 扫描状态不绑在音源管理页的 State 上：退出页面扫描照常进行（写库不
/// 中断），回到页面进度原样恢复，也不会因重复进入而并发开两个扫描。
/// 进度/错误/结果用 ValueNotifier 表达，页面直接监听。
class WebDavScanSession {
  WebDavScanSession._();

  static final WebDavScanSession instance = WebDavScanSession._();

  /// 正在扫描的音源 id；null = 空闲。
  final ValueNotifier<String?> runningSourceId = ValueNotifier(null);

  /// 正在扫描的音源名（进度区展示用）。
  final ValueNotifier<String> runningSourceName = ValueNotifier('');

  final ValueNotifier<WebDavScanProgress?> progress = ValueNotifier(null);

  final ValueNotifier<WebDavScanSummary?> lastSummary = ValueNotifier(null);

  /// 扫描失败原因；null = 无错误。**失败必须可见**——曾经静默吞掉，
  /// 用户点扫描后永远等不到任何反馈。
  final ValueNotifier<String?> lastError = ValueNotifier(null);

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
    lastError.value = null;
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
      LocalLibraryService.revision.value++;
    } catch (e, st) {
      debugPrint('[WebDavScanSession] 扫描失败: $e\n$st');
      lastError.value = e.toString();
    } finally {
      runningSourceId.value = null;
      runningSourceName.value = '';
      _running = null;
    }
  }
}
