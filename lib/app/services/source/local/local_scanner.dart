import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';

import 'local_album_cover.dart';
import 'local_audio_extensions.dart';
import 'local_song_id.dart';

/// 扫描到的一个候选音频文件。
///
/// 只带**不读文件内容**就能拿到的信息；标签解析是后续独立一步
/// （见 `local_tag_probe.dart`），因为那一步要读整个文件、慢得多。
class LocalScanEntry {
  /// 规范化后的绝对路径，同时作为歌曲 ID（见 `localSongId`）。
  final String path;

  /// 系统媒体库资源 ID。自定义目录扫描为 null。
  final String? assetId;

  final int fileSize;

  /// 文件最后修改时间（毫秒）。用于增量扫描判断是否需要重读标签。
  final int? fileModifiedMs;

  const LocalScanEntry({
    required this.path,
    this.assetId,
    required this.fileSize,
    this.fileModifiedMs,
  });
}

/// 扫描进度。
class LocalScanProgress {
  /// 已访问的目录数。
  final int dirsVisited;

  /// 已收录的音频文件数。
  final int filesFound;

  const LocalScanProgress({
    required this.dirsVisited,
    required this.filesFound,
  });
}

/// 一次扫描的完整结果。
class LocalScanResult {
  /// 收录的音频文件。
  final List<LocalScanEntry> entries;

  /// 每个目录下的**图片文件**（`目录 → 文件名列表`）。
  ///
  /// 扫描时顺带收集，避免为了找 `folder.jpg` 再遍历一遍目录 ——
  /// 大曲库下这是几千次额外的 `Directory.list`。
  /// 存的是**纯文件名**（不是完整路径），拼回目录即可；这样
  /// `LocalAlbumCover.pickSidecarCover` 可以保持纯函数、直接单测。
  final Map<String, List<String>> imagesByDirectory;

  const LocalScanResult({
    required this.entries,
    required this.imagesByDirectory,
  });
}

/// 本地目录扫描器。
///
/// **纯 `dart:io`，不做任何平台分支** —— 这是三端（Android / iOS / Windows）
/// 共用本地音源的关键：`Directory.list` 在三端行为一致，而 `photo_manager`
/// 只支持 Android/iOS/macOS。因此：
/// - 桌面端（Windows/macOS/Linux）：只用本扫描器；
/// - Android/iOS：系统媒体库路径由 `photo_manager` 另行提供，本扫描器负责
///   用户额外指定的目录。
///
/// 自己递归而不用 `Directory.list(recursive: true)`：后者无法剪枝，
/// 遇到 `node_modules` / `.git` / 群晖 `@eaDir` 会把成千上万个无关文件
/// 全部 stat 一遍。这里逐层判断目录名，命中 [localScanSkippedDirNames]
/// 直接整棵跳过。
class LocalScanner {
  const LocalScanner();

  /// 递归扫描 [roots] 下的音频文件，只要音频列表时用这个。
  ///
  /// 内部走 [scanWithCovers]，丢弃顺带收集的图片信息。
  Future<List<LocalScanEntry>> scan(
    List<String> roots, {
    ValueGetter<bool>? isCancelled,
    void Function(LocalScanProgress progress)? onProgress,
  }) async {
    final result = await scanWithCovers(
      roots,
      isCancelled: isCancelled,
      onProgress: onProgress,
    );
    return result.entries;
  }

  /// 递归扫描 [roots]，同时收集每个目录下的图片文件名（供专辑封面回退用）。
  ///
  /// - 按 [localSongId] 去重（同一路径被多个 root 覆盖时只收一次）；
  /// - [isCancelled] 返回 true 时立即停止并返回已收集的部分；
  /// - [onProgress] 节流由调用方负责，这里每访问一个目录就回调一次；
  /// - 单个目录读失败（权限不足 / 符号链接成环 / 扫描中途被删）只跳过该目录，
  ///   不让整次扫描失败。
  Future<LocalScanResult> scanWithCovers(
    List<String> roots, {
    ValueGetter<bool>? isCancelled,
    void Function(LocalScanProgress progress)? onProgress,
  }) async {
    final results = <LocalScanEntry>[];
    final seen = <String>{};
    final images = <String, List<String>>{};
    var dirsVisited = 0;

    for (final root in roots) {
      if (isCancelled?.call() ?? false) break;
      final normalizedRoot = normalizeLocalPath(root);
      if (normalizedRoot.isEmpty) continue;

      final rootType = FileSystemEntity.typeSync(normalizedRoot);
      if (rootType == FileSystemEntityType.notFound) {
        if (kDebugMode) {
          debugPrint('[LocalScanner] 根路径不存在，跳过: $normalizedRoot');
        }
        continue;
      }

      // root 本身就是一个音频文件时直接收（用户可能拖了单个文件进来）。
      if (rootType == FileSystemEntityType.file) {
        if (isLocalAudioFile(normalizedRoot)) {
          final entry = _entryFor(normalizedRoot);
          if (entry != null && seen.add(localSongId(entry.path))) {
            results.add(entry);
          }
        }
        continue;
      }

      await _walk(
        normalizedRoot,
        results: results,
        seen: seen,
        imagesByDirectory: images,
        isCancelled: isCancelled,
        onDirVisited: () {
          dirsVisited++;
          onProgress?.call(
            LocalScanProgress(
              dirsVisited: dirsVisited,
              filesFound: results.length,
            ),
          );
        },
      );
    }

    return LocalScanResult(entries: results, imagesByDirectory: images);
  }

  Future<void> _walk(
    String dir, {
    required List<LocalScanEntry> results,
    required Set<String> seen,
    required Map<String, List<String>> imagesByDirectory,
    required ValueGetter<bool>? isCancelled,
    required void Function() onDirVisited,
  }) async {
    onDirVisited();

    List<FileSystemEntity> children;
    try {
      children = await Directory(dir).list(followLinks: false).toList();
    } catch (e) {
      // 权限不足 / 扫描中途目录被删 / 符号链接成环。跳过这棵子树即可。
      if (kDebugMode) {
        debugPrint('[LocalScanner] 目录不可读，跳过: $dir ($e)');
      }
      return;
    }

    for (final entity in children) {
      if (isCancelled?.call() ?? false) return;

      if (entity is Directory) {
        final name = _basename(entity.path);
        if (isSkippedDirName(name)) continue;
        await _walk(
          normalizeLocalPath(entity.path),
          results: results,
          seen: seen,
          imagesByDirectory: imagesByDirectory,
          isCancelled: isCancelled,
          onDirVisited: onDirVisited,
        );
        continue;
      }

      if (entity is! File) continue;
      final path = normalizeLocalPath(entity.path);

      // 顺带记下目录里的图片文件名，供专辑封面回退（folder.jpg 等）。
      // 只记文件名不记完整路径，好让挑选逻辑保持纯函数。
      final fileName = _basename(path);
      if (LocalAlbumCover.isSidecarImageName(fileName)) {
        (imagesByDirectory[dir] ??= <String>[]).add(fileName);
        continue;
      }

      if (!isLocalAudioFile(path)) continue;

      final entry = _entryFor(path);
      if (entry == null) continue;
      if (!seen.add(localSongId(path))) continue;
      results.add(entry);
    }
  }

  LocalScanEntry? _entryFor(String path) {
    try {
      final stat = File(path).statSync();
      return LocalScanEntry(
        path: path,
        fileSize: stat.size,
        fileModifiedMs: stat.modified.millisecondsSinceEpoch,
      );
    } catch (_) {
      // 文件在遍历与 stat 之间被删掉，或无读取权限。
      return null;
    }
  }

  String _basename(String path) {
    final sep = path.lastIndexOf('/');
    return sep < 0 ? path : path.substring(sep + 1);
  }
}
