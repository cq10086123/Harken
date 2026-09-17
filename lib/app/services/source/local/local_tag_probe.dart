import 'dart:io';
import 'dart:typed_data';

import 'package:audio_metadata_reader/audio_metadata_reader.dart';
import 'package:flutter/foundation.dart';

import 'tag_text_encoding.dart';

/// 一次本地标签探测的结果。
///
/// 字段刻意与 `SongEntity` 对齐，映射时不需要二次转换。
class LocalTagProbeResult {
  final String? title;
  final String? artist;
  final String? album;
  final int? durationMs;
  final int? bitrate;
  final int? sampleRate;
  final int? fileSize;
  final String? format;
  final int? trackNumber;
  final int? discNumber;

  /// 内嵌封面原始字节（`includeArtwork` 为 false 时恒 null）。
  final Uint8List? artwork;

  /// 内嵌歌词（USLT / Vorbis LYRICS）。
  final String? lyrics;

  /// 标签是否解析成功。
  ///
  /// false 表示文件存在但读不出标签（损坏、或该容器 `audio_metadata_reader`
  /// 不支持）。此时调用方应回退到「文件名当标题」，而不是丢弃这首歌。
  final bool tagsParsed;

  const LocalTagProbeResult({
    this.title,
    this.artist,
    this.album,
    this.durationMs,
    this.bitrate,
    this.sampleRate,
    this.fileSize,
    this.format,
    this.trackNumber,
    this.discNumber,
    this.artwork,
    this.lyrics,
    this.tagsParsed = false,
  });
}

/// [compute] 的入参。只含可跨 isolate 传递的类型。
class LocalTagProbeInput {
  final String path;
  final bool includeArtwork;
  final bool includeLyrics;

  const LocalTagProbeInput({
    required this.path,
    required this.includeArtwork,
    this.includeLyrics = true,
  });
}

/// 在后台 isolate 上读一个音频文件的标签。
///
/// **必须走 isolate**：`readMetadata` 是同步的，而且要把整个音频文件读进来
/// 解析。带 1~3MB 内嵌大图的歌在 UI isolate 上做一次就是几十毫秒，一帧预算
/// 只有 16ms —— 扫几百首会直接把界面卡死。
///
/// 返回 null 表示文件不存在或完全无法读取（调用方应跳过该文件）。
Future<LocalTagProbeResult?> probeLocalTags(
  String path, {
  bool includeArtwork = true,
  bool includeLyrics = true,
}) {
  return compute(
    readLocalTagsInIsolate,
    LocalTagProbeInput(
      path: path,
      includeArtwork: includeArtwork,
      includeLyrics: includeLyrics,
    ),
  );
}

/// isolate 入口。必须是顶层函数才能被 [compute] 送到别的 isolate 上跑。
///
/// 不在这里做 OGG / WAV 的补充解析：上游 NagoMusic 为此额外实现了
/// `extractOggVorbisComments` / `extractWavId3Metadata`（在它的
/// `packages/media_cache` 里，本项目没有）。因此 **OGG/Opus 的封面与歌词、
/// WAV 的 ID3 标签在本地音源下可能读不到**，属已知限制；标签读不出时会
/// 回退到文件名，歌曲本身仍能正常播放。
@visibleForTesting
LocalTagProbeResult? readLocalTagsInIsolate(LocalTagProbeInput input) {
  final path = input.path;
  final file = File(path);

  int fileSize = 0;
  try {
    fileSize = file.statSync().size;
  } catch (_) {
    // 文件在扫描与探测之间被删掉了
    return null;
  }

  AudioMetadata? meta;
  try {
    meta = readMetadata(file, getImage: input.includeArtwork);
  } catch (e) {
    if (kDebugMode) {
      debugPrint('[LocalTagProbe] readMetadata 失败 path=$path: $e');
    }
    meta = null;
  }

  if (meta == null) {
    // 读不出标签也返回一个空结果（tagsParsed=false），让调用方回退到文件名，
    // 而不是丢掉这首歌。
    return LocalTagProbeResult(fileSize: fileSize, tagsParsed: false);
  }

  Uint8List? artwork;
  if (input.includeArtwork && meta.pictures.isNotEmpty) {
    final bytes = meta.pictures.first.bytes;
    if (bytes.isNotEmpty) artwork = bytes;
  }

  final lyrics = input.includeLyrics ? _nonEmpty(meta.lyrics) : null;

  return LocalTagProbeResult(
    // 中文标签的编码声明经常是错的（ID3v2 声明 Latin-1 实际塞 UTF-8），
    // 照声明解码会得到「爱情好无奈」→「ç±æå¥½æ å¥」。这里拿到的是已解码
    // 的 String，只能反向推：按 Latin-1 编回字节再严格 UTF-8 解码，
    // 不是这种乱码的话一定会失败并原样返回。
    title: repairMojibake(_nonEmpty(meta.title)),
    artist: repairMojibake(_nonEmpty(meta.artist)),
    album: repairMojibake(_nonEmpty(meta.album)),
    durationMs: meta.duration?.inMilliseconds,
    bitrate: meta.bitrate,
    sampleRate: meta.sampleRate,
    fileSize: fileSize,
    // format 取自扩展名而不是 AudioMetadata 的字段：上游同样这么做
    // （`tag_probe_service.dart` 里 `final format = ext.toUpperCase()`），
    // 因为容器自报的格式名在各家 tagger 下不一致，扩展名反而更稳定，
    // 且与 `playback_router.routeForFormat` 期望的小写扩展名口径一致。
    format: _extOf(path),
    trackNumber: meta.trackNumber,
    discNumber: meta.discNumber,
    artwork: artwork,
    lyrics: repairMojibake(lyrics),
    tagsParsed: true,
  );
}

String? _nonEmpty(String? v) {
  final t = (v ?? '').trim();
  return t.isEmpty ? null : t;
}

/// 小写扩展名（不含点）。无扩展名返回 null。
String? _extOf(String path) {
  final dot = path.lastIndexOf('.');
  if (dot < 0 || dot == path.length - 1) return null;
  final ext = path.substring(dot + 1).toLowerCase();
  return ext.isEmpty ? null : ext;
}
