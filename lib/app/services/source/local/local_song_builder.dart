import 'package:path/path.dart' as p;

import '../../../state/song_state.dart';
import 'local_audio_extensions.dart';
import 'local_scanner.dart';
import 'local_song_id.dart';
import 'local_tag_probe.dart';

/// 把「扫描结果 + 标签」组装成 [SongEntity]。
///
/// **刻意做成纯函数**（无 IO、无 DB、无单例）：回退链和增量合并是整个本地音源
/// 最容易出错、也最难在真机上复现的部分，必须能直接单测。
class LocalSongBuilder {
  const LocalSongBuilder._();

  static const String unknownTitle = '未知标题';
  static const String unknownArtist = '未知艺术家';
  static const String unknownAlbum = '未知专辑';

  /// 本地歌的歌手 guid 前缀。
  ///
  /// 本地文件没有服务端 guid，但 `SongEntity.artistGuids` 被聚合页和批量匹配
  /// 读取，留空会让「按歌手分组」全部塌成一堆 null。用**名字派生的确定性
  /// guid**：同名歌手稳定聚合，且前缀命名空间保证永不与飞牛 guid 撞车。
  static const String artistGuidPrefix = 'local-artist:';

  /// 本地歌的专辑 guid 前缀。
  static const String albumGuidPrefix = 'local-album:';

  /// 编码 artist 列。`SongEntity.artist` 的约定格式是
  /// `[{"guid":"...","name":"..."}]`（见 `song_state.dart:6`）。
  ///
  /// **不拆分多歌手**：本地标签里的分隔符没有统一约定（`/`、`,`、`;`、`&`、
  /// `feat.` 都有人用），任何按字符猜测的拆分都会误伤真实乐队名 ——
  /// 最典型的就是 `AC/DC` 被拆成 "AC" 和 "DC" 两个歌手。
  /// 整串作为一个歌手名存入：`artistDisplayName` 原样显示（用户在自己
  /// tagger 里看到什么就显示什么），代价是「周杰伦 / 费玉清」会被当成一个
  /// 歌手聚合，这比拆错乐队名轻得多。
  ///
  /// 飞牛侧没有这个问题，因为服务端直接返回歌手数组（`track_service.dart:65`）。
  static String encodeArtist(String rawName) {
    final name = rawName.trim();
    final effective = name.isEmpty ? unknownArtist : name;
    return '[{"guid":"${_jsonEscape('$artistGuidPrefix$effective')}",'
        '"name":"${_jsonEscape(effective)}"}]';
  }

  /// 编码 album 列。约定格式是 `{"guid":"...","name":"..."}`（单个对象，非数组）。
  static String? encodeAlbum(String? rawName) {
    final name = (rawName ?? '').trim();
    if (name.isEmpty) return null;
    return '{"guid":"${_jsonEscape('$albumGuidPrefix$name')}","name":"${_jsonEscape(name)}"}';
  }

  /// 是否需要重新读标签。
  ///
  /// 增量扫描的核心：文件大小与修改时间都没变，标签不可能变，直接复用库里
  /// 那一行（上游 `local_music_service.dart` 同样做法）。一次全库扫描从
  /// 「读几千个完整音频文件」降为「stat 几千个文件」，差两个数量级。
  ///
  /// 首次入库（[existing] 为 null）、或标签当初就没读出来（`tagsParsed`
  /// 为 false，可能是当时文件正被占用）时，都要重读。
  static bool shouldReprobe(SongEntity? existing, LocalScanEntry entry) {
    if (existing == null) return true;
    if (!existing.tagsParsed) return true;
    if (existing.fileModifiedMs != entry.fileModifiedMs) return true;
    // 文件被换成了同长度同 mtime 的另一个文件（极少见，但 rsync --size-only
    // 之类会造出来）：大小不同也重读。
    if (existing.fileSize != null && existing.fileSize != entry.fileSize) {
      return true;
    }
    return false;
  }

  /// 组装一首本地歌。
  ///
  /// 标题回退链：**内嵌标签 → 文件名（去扩展名）→ 「未知标题」**。
  /// 文件名这一级很重要：没打标签的本地文件很常见，直接显示「未知标题」会让
  /// 曲库不可用；文件名至少是人能认出来的。
  static SongEntity build({
    required LocalScanEntry entry,
    required String sourceId,
    LocalTagProbeResult? tags,
    SongEntity? existing,
    String? coverPath,
  }) {
    final fileName = p.basenameWithoutExtension(entry.path);

    final title = _firstNonEmpty(tags?.title, fileName, unknownTitle)!;
    final artistName = _firstNonEmpty(tags?.artist, unknownArtist)!;
    final albumName = _firstNonEmpty(tags?.album, null);

    final durationMs = tags?.durationMs;

    return SongEntity(
      id: localSongId(entry.path),
      title: title,
      artist: encodeArtist(artistName),
      album: encodeAlbum(albumName),
      uri: entry.path,
      isLocal: true,
      sourceId: sourceId,
      fileModifiedMs: entry.fileModifiedMs,
      localAssetId: entry.assetId,
      tagsParsed: tags?.tagsParsed ?? false,
      // 封面：本次读到了就用新的；没读到时保留库里已有的（不能把上次落盘的
      // 封面路径抹掉，否则重扫一次全库封面就全没了）。
      localCoverPath: _firstNonEmpty(coverPath, existing?.localCoverPath),
      durationMs: (durationMs != null && durationMs > 0) ? durationMs : null,
      bitrate: tags?.bitrate ?? existing?.bitrate,
      sampleRate: tags?.sampleRate ?? existing?.sampleRate,
      fileSize: entry.fileSize > 0 ? entry.fileSize : existing?.fileSize,
      format: _firstNonEmpty(tags?.format, localFormatOf(entry.path)),
      trackNumber: tags?.trackNumber ?? existing?.trackNumber,
      discNumber: tags?.discNumber ?? existing?.discNumber,
      updatedAt: DateTime.now().millisecondsSinceEpoch,
      // 文件刚扫到，必然是存在的：清掉上一次扫描可能留下的失效标记，
      // 否则一个曾经「文件被删」的歌在文件回来后仍显示为失效。
      isAudioFileDeleted: false,
    );
  }

  /// 增量命中时复用库里那一行，只更新「文件层面」的变化。
  ///
  /// 用 `copyWith` 而不是重新 `build`：`build` 需要标签，而增量命中恰恰是
  /// 为了**不读标签**。同时 `copyWith` 保住了所有没列出的列 ——
  /// 这正是 `player_service.dart` 里那个逐字段重建 bug 的教训。
  static SongEntity reuse(SongEntity existing, LocalScanEntry entry) {
    return existing.copyWith(
      // 路径大小写或分隔符可能变了（Windows 上尤其常见），ID 与 uri 都要跟上。
      uri: entry.path,
      fileModifiedMs: entry.fileModifiedMs ?? existing.fileModifiedMs,
      fileSize: entry.fileSize > 0 ? entry.fileSize : existing.fileSize,
      isAudioFileDeleted: false,
    );
  }

  static String? _firstNonEmpty(String? a, String? b, [String? c]) {
    for (final v in [a, b, c]) {
      final t = (v ?? '').trim();
      if (t.isNotEmpty) return t;
    }
    return null;
  }

  /// 最小 JSON 字符串转义。
  ///
  /// 不用 `jsonEncode` 拼整个对象是为了保持输出与飞牛写入的格式逐字节一致
  /// （键顺序、无空格），避免同一歌手在两个音源下产生两种字符串形态。
  static String _jsonEscape(String v) {
    return v
        .replaceAll(r'\', r'\\')
        .replaceAll('"', r'\"')
        .replaceAll('\n', r'\n')
        .replaceAll('\r', r'\r')
        .replaceAll('\t', r'\t');
  }
}
