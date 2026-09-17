import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;

/// 本地音源的歌曲 ID = **规范化后的绝对路径**。
///
/// 与上游 NagoMusic 一致（`local_music_service.dart:455` `id: candidate.path`）。
/// 选路径而不是内容哈希，理由：
/// - **跨扫描稳定** —— 重扫不改变 ID，收藏 / 歌单 / 播放历史全部存活；
/// - **可调试** —— 出问题时 ID 直接就是文件位置，不用反查；
/// - 内容哈希在「同一个文件被拷了两份」时会撞车，路径不会。
///
/// 代价：文件被移动或重命名后 ID 变化，该歌的收藏会「丢」。由
/// `isAudioFileDeleted` 失效标记 + 重扫兜底，不做自动追踪。
///
/// 三端路径差异必须在这里一次性抹平，否则同一个文件在 Windows 和 macOS 上
/// 会得到不同 ID。
String localSongId(String rawPath) {
  final normalized = normalizeLocalPath(rawPath);
  return caseInsensitiveFileSystem ? normalized.toLowerCase() : normalized;
}

/// 当前平台的文件系统是否大小写不敏感。
///
/// Windows 恒不敏感；macOS 默认不敏感（APFS 默认选项）；Linux 与
/// Android/iOS 敏感。大小写不敏感时 ID 需做小写归一，否则
/// `Music/A.flac` 与 `music/a.flac` 会被当成两首歌。
///
/// 用 [defaultTargetPlatform] 而非 `Platform.isWindows`：单测里
/// `defaultTargetPlatform` 可被 `debugDefaultTargetPlatformOverride` 覆盖，
/// 于是两个分支都能测到（同 `player/playback_router.dart` 的做法）。
bool get caseInsensitiveFileSystem {
  if (kIsWeb) return false;
  final platform = defaultTargetPlatform;
  return platform == TargetPlatform.windows || platform == TargetPlatform.macOS;
}

/// 把任意形态的路径规范化成 ID / 比较用的形式：分隔符归一 + 去尾部斜杠。
///
/// 不做小写转换（展示要用原样），大小写归一只在 [localSongId] 里做。
String normalizeLocalPath(String rawPath) {
  var t = rawPath.trim();
  if (t.isEmpty) return '';
  // Windows 反斜杠 → 正斜杠。p.normalize 在非 Windows 平台不转换分隔符，
  // 这里显式替换，保证同一份数据在不同平台产出同一个 ID。
  t = t.replaceAll('\\', '/');
  t = p.normalize(t);
  t = t.replaceAll('\\', '/');
  while (t.length > 1 && t.endsWith('/')) {
    t = t.substring(0, t.length - 1);
  }
  return t;
}

/// 判断一个 uri 是否本地文件路径（而不是 http(s) 流地址）。
bool isLocalFilePath(String uri) {
  final t = uri.trim();
  if (t.isEmpty) return false;
  if (t.startsWith('http://') || t.startsWith('https://')) return false;
  return true;
}

/// 剥掉 `file://` 前缀，返回纯文件系统路径。非 file URI 原样返回。
///
/// `just_audio` 的 `AudioSource.file` 需要纯路径，不接受 `file://` URI。
String stripFileScheme(String uri) {
  var t = uri.trim();
  if (!t.startsWith('file://')) return t;
  t = t.substring('file://'.length);
  // Windows 的 file:///C:/... 剥完会剩一个前导斜杠，去掉才是合法路径。
  if (RegExp(r'^/[A-Za-z]:/').hasMatch(t)) {
    t = t.substring(1);
  }
  try {
    return Uri.decodeComponent(t);
  } catch (_) {
    // 含裸 % 的畸形路径：解码失败就用原串，不要让整次扫描挂掉。
    return t;
  }
}
