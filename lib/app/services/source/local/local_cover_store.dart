import 'dart:io' as io;
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

import 'local_song_id.dart';

/// 本地内嵌封面落盘。
///
/// **刻意复用 `CoverLocalCache` 的目录与命名约定**
/// （`getTemporaryDirectory()/covers_v2/<sha1>.img`）：那个类的
/// `contentUriForPath` 用 `^[0-9a-f]{40}\.img$` 白名单校验文件名，只暴露它自己
/// 产出的文件。本地封面按同一规则命名后，Android Auto / 车机媒体卡片无需任何
/// 改动就能读到本地图 —— 换一套命名就得同步改原生 Provider。
class LocalCoverStore {
  LocalCoverStore._();

  static const String kDirName = 'covers_v2';

  static String? _dirPath;

  /// 封面缓存目录（不存在则创建）。
  static Future<String> coverDirPath() async {
    final cached = _dirPath;
    if (cached != null) return cached;
    final dir = await getTemporaryDirectory();
    final path = '${dir.path}/$kDirName';
    await io.Directory(path).create(recursive: true);
    _dirPath = path;
    return path;
  }

  /// 测试注入点：绕过 `path_provider`，让落盘逻辑能在 `flutter test` 里跑真实 IO。
  @visibleForTesting
  static void debugOverrideDirPath(String? path) {
    _dirPath = path;
  }

  /// 把内嵌封面字节写进缓存目录，返回绝对路径；失败返回 null。
  ///
  /// **文件名按内容哈希**，不是按 songId：一张专辑十几首歌的内嵌封面通常是
  /// 同一张图，按内容哈希后整张专辑共用一个文件（12 轨 × 1MB 从 12MB 降到
  /// 1MB）。这也与飞牛侧一致 —— 那边整张专辑共享同一个 `coverId`。
  ///
  /// 副作用是幂等：同一张图重复写入直接命中已存在的文件，不重写。
  static Future<String?> save({
    required String songId,
    required Uint8List bytes,
    int? fileModifiedMs,
  }) async {
    if (bytes.isEmpty) return null;
    try {
      final dir = await coverDirPath();
      final name = '${sha1.convert(bytes)}.img';
      final target = io.File('$dir/$name');
      if (await target.exists()) return target.path;
      await target.writeAsBytes(bytes, flush: true);
      return target.path;
    } catch (e) {
      if (kDebugMode) {
        debugPrint('[LocalCoverStore] 封面落盘失败 songId=$songId: $e');
      }
      return null;
    }
  }

  /// 删除一个封面缓存文件。
  ///
  /// **只删本类管理的目录内的文件** —— 见 [isManagedPath]。
  static Future<bool> delete(String? path) async {
    if (!await isManagedPath(path)) return false;
    try {
      final f = io.File(path!.trim());
      if (await f.exists()) await f.delete();
      return true;
    } catch (_) {
      // 缓存删不掉不影响功能，忽略。
      return false;
    }
  }

  /// 该路径是否落在本类管理的目录内。
  ///
  /// 清理时的保护闸：`localCoverPath` 是数据库里的字符串，可能被改过或来自
  /// 旧版本；绝不能因为「它看起来像封面」就把用户的音频文件删了。
  static Future<bool> isManagedPath(String? path) async {
    final t = normalizeLocalPath((path ?? '').trim());
    if (t.isEmpty) return false;
    final dir = normalizeLocalPath(await coverDirPath());
    return t.startsWith('$dir/');
  }
}
