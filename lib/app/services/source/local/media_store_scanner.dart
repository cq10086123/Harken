import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:photo_manager/photo_manager.dart';

import 'local_audio_extensions.dart';
import 'local_scanner.dart';
import 'local_song_id.dart';

/// Android MediaStore 扫描器（分区存储兼容路线）。
///
/// Android 11+ 分区存储下，dart:io 无法枚举共享存储（/storage/emulated/0/...），
/// 除非持有「所有文件访问」。本扫描器改走 MediaStore（经 photo_manager）：
///
/// - 授权：只需 READ_MEDIA_AUDIO（系统普通弹窗），不用跳系统设置；
/// - 枚举：MediaStore.Audio 收录的音频（新拷贝的文件通常几秒内被系统
///   媒体扫描器自动收录）；
/// - 读取：Android 11+ 允许持有音频权限的应用**用文件路径直接打开**
///   媒体库登记的音频，因此标签解析 / 封面落盘等下游逻辑照常工作；
/// - 目录过滤：把用户选的根路径映射为 MediaStore 的 relativePath 前缀
///   （如 /storage/emulated/0/taizifei → `taizifei/`），前缀匹配含子目录。
///
/// 局限：只扫得到媒体库里登记的文件；无法映射到主存储 relativePath 的
/// 根路径（如外置 SD 卡）在这里扫不到，这类用户需授予「所有文件访问」
/// 走 [LocalScanner] 的 dart:io 路线。
class MediaStoreScanner {
  const MediaStoreScanner();

  /// 与 [LocalScanner.scanWithCovers] 同构：返回音频条目 + 目录侧车图片名。
  Future<LocalScanResult> scanWithCovers(
    List<String> roots, {
    ValueGetter<bool>? isCancelled,
  }) async {
    try {
      final permission = await PhotoManager.requestPermissionExtend();
      if (!permission.hasAccess) {
        return const LocalScanResult(entries: [], imagesByDirectory: {});
      }
    } catch (e) {
      debugPrint('[MediaStoreScanner] 权限请求失败: $e');
      return const LocalScanResult(entries: [], imagesByDirectory: {});
    }

    // 根路径 → relativePath 前缀。全部无法映射时 MediaStore 无法按目录
    // 过滤（会误收全库），宁可返回空让上层走 dart:io 路线报 0。
    final prefixes = <String>{};
    for (final root in roots) {
      final prefix = _relativePrefixOf(root);
      if (prefix != null) prefixes.add(prefix);
    }
    if (prefixes.isEmpty) {
      debugPrint('[MediaStoreScanner] 根路径均无法映射到主存储，放弃 MediaStore 路线');
      return const LocalScanResult(entries: [], imagesByDirectory: {});
    }

    final entries = <LocalScanEntry>[];
    final seen = <String>{};
    final images = <String, List<String>>{};

    await _collect(
      RequestType.audio,
      prefixes,
      isCancelled,
      onAsset: (file) {
        if (!isLocalAudioFile(file.path)) return null;
        final stat = file.statSync();
        return LocalScanEntry(
          path: normalizeLocalPath(file.path),
          fileSize: stat.size,
          fileModifiedMs: stat.modified.millisecondsSinceEpoch,
        );
      },
      onImage: (file) {
        final dir = normalizeLocalPath(file.parent.path);
        (images[dir] ??= <String>[]).add(_basename(file.path));
      },
      seen: seen,
      results: entries,
    );

    // 顺带收集目录里的图片（旁挂封面 folder.jpg 等），与 LocalScanner 行为一致。
    // 缺了这一步，MediaStore 路线下 pickSidecarCover 永远拿不到图片名，
    // 文件夹里的封面图会被无视。
    await _collect(
      RequestType.image,
      prefixes,
      isCancelled,
      onAsset: (_) => null,
      onImage: (file) {
        final dir = normalizeLocalPath(file.parent.path);
        (images[dir] ??= <String>[]).add(_basename(file.path));
      },
      seen: seen,
      results: entries,
    );

    return LocalScanResult(entries: entries, imagesByDirectory: images);
  }

  /// 遍历 [type] 对应的媒体库目录，对每个资源取文件并分派给音频/图片回调。
  Future<void> _collect(
    RequestType type,
    Set<String> prefixes,
    ValueGetter<bool>? isCancelled, {
    required LocalScanEntry? Function(File file) onAsset,
    required void Function(File file) onImage,
    required Set<String> seen,
    required List<LocalScanEntry> results,
  }) async {
    List<AssetPathEntity> folders;
    try {
      folders = await PhotoManager.getAssetPathList(type: type, onlyAll: false);
    } catch (e) {
      debugPrint('[MediaStoreScanner] 目录列表查询失败: $e');
      return;
    }
    for (final folder in folders) {
      if (isCancelled?.call() ?? false) return;
      List<AssetEntity> assets;
      try {
        assets = await folder.getAssetListRange(start: 0, end: 1048576);
      } catch (e) {
        debugPrint('[MediaStoreScanner] 目录 ${folder.name} 查询失败: $e');
        continue;
      }
      for (final asset in assets) {
        if (isCancelled?.call() ?? false) return;
        // relativePath 形如 `taizifei/`（Android 独有）；无该字段时无法过滤，
        // 只在未指定过滤时收录。
        final rel = asset.relativePath;
        if (prefixes.isNotEmpty &&
            !prefixes.any((p) => rel != null && rel.startsWith(p))) {
          continue;
        }
        final File? file;
        try {
          file = await asset.originFile;
        } catch (_) {
          continue;
        }
        if (file == null) continue;
        if (type == RequestType.image) {
          onImage(file);
          continue;
        }
        final entry = onAsset(file);
        if (entry == null) continue;
        if (!seen.add(localSongId(entry.path))) continue;
        results.add(entry);
      }
    }
  }

  /// 根路径 → relativePath 前缀（带尾斜杠）。无法映射到主存储时返回 null。
  String? _relativePrefixOf(String root) {
    var path = root.replaceAll('\\', '/');
    const primaryBases = ['/storage/emulated/0/', '/sdcard/'];
    for (final base in primaryBases) {
      if (path.startsWith(base)) {
        path = path.substring(base.length);
        break;
      }
    }
    if (path == '/storage/emulated/0' || path == '/sdcard') path = '';
    while (path.startsWith('/')) {
      path = path.substring(1);
    }
    while (path.contains('//')) {
      path = path.replaceAll('//', '/');
    }
    if (path.endsWith('/')) path = path.substring(0, path.length - 1);
    if (path.isEmpty) return '';
    // 外置卡 / SAF content 路径残留等无法映射到主存储 relativePath
    if (path.startsWith('content:') || path.contains(':')) return null;
    return '$path/';
  }

  String _basename(String path) {
    final sep = path.lastIndexOf('/');
    return sep < 0 ? path : path.substring(sep + 1);
  }
}
