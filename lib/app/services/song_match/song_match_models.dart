import 'dart:convert';

import '../../state/settings_match.dart';

/// 搜索结果（映射 Lyrico SongSearchResult，见 PluginJsonParser.kt）。
class SongMatchResult {
  final String id;
  final String pluginId;
  final String pluginName;
  final String title;
  final String artist;
  final String album;
  final int duration;
  final String date;
  final String trackNumber;
  final String discNumber;
  final String picUrl;
  final Map<String, String> fields;
  final Map<String, String> internal;

  const SongMatchResult({
    required this.id,
    required this.pluginId,
    required this.pluginName,
    this.title = '',
    this.artist = '',
    this.album = '',
    this.duration = 0,
    this.date = '',
    this.trackNumber = '',
    this.discNumber = '',
    this.picUrl = '',
    this.fields = const {},
    this.internal = const {},
  });

  Map<String, String> get normalizedFields {
    final result = <String, String>{};
    result.addAll(fields);
    if (title.isNotEmpty) result.putIfAbsent('title', () => title);
    if (artist.isNotEmpty) result.putIfAbsent('artist', () => artist);
    if (album.isNotEmpty) result.putIfAbsent('album', () => album);
    if (date.isNotEmpty) result.putIfAbsent('date', () => date);
    if (trackNumber.isNotEmpty) {
      result.putIfAbsent('track_number', () => trackNumber);
    }
    if (discNumber.isNotEmpty) {
      result.putIfAbsent('disc_number', () => discNumber);
    }
    if (picUrl.isNotEmpty) result.putIfAbsent('cover_url', () => picUrl);
    return result;
  }

  @override
  String toString() =>
      'SongMatchResult($pluginName: $title / $artist / $album)';
}

/// 歌词候选（映射 Lyrico LyricsCandidateResult 的字段，见 PluginJsonParser.kt）。
class LyricMatchResult {
  final String pluginId;
  final String pluginName;
  final String type;
  final Map<String, String> tags;
  final String rawPlainLrc;
  final String rawVerbatimLrc;
  final String rawEnhancedLrc;
  final String rawTtml;
  final String rawMultiPersonEnhancedLrc;
  final List<LyricLine> original;
  final List<LyricLine> translated;
  final List<LyricLine> romanization;

  const LyricMatchResult({
    required this.pluginId,
    required this.pluginName,
    this.type = 'rawPlainLrc',
    this.tags = const {},
    this.rawPlainLrc = '',
    this.rawVerbatimLrc = '',
    this.rawEnhancedLrc = '',
    this.rawTtml = '',
    this.rawMultiPersonEnhancedLrc = '',
    this.original = const [],
    this.translated = const [],
    this.romanization = const [],
  });

  String get displayText {
    switch (type) {
      case 'structured':
        // 结构化歌词：把 original 行文本拼成 LRC（[mm:ss.xx]text）。
        return _linesToLrc(original);
      case 'rawPlainLrc':
        return rawPlainLrc;
      case 'rawVerbatimLrc':
        return rawVerbatimLrc;
      case 'rawEnhancedLrc':
        return rawEnhancedLrc;
      case 'rawTtml':
        return rawTtml;
      case 'rawMultiPersonEnhancedLrc':
        return rawMultiPersonEnhancedLrc;
      default:
        return rawPlainLrc;
    }
  }

  /// 逐字版本歌词（普通逐字 LRC，每字一个 `[mm:ss.xx]` 前缀）。
  ///
  /// structured 且带逐词时间戳时返回逐字格式；否则回退 [displayText]。
  String get verbatimLrc {
    if (type == 'structured') {
      final v = _linesToVerbatimLrc(original);
      if (v.trim().isNotEmpty) return v;
    }
    return displayText;
  }

  /// 增强逐字版本歌词（`[mm:ss.xxx]<ws,we>词`，带每字结束时间戳）。
  ///
  /// structured 且带逐词时间戳时返回增强逐字格式；否则回退 [displayText]。
  String get enhancedVerbatimLrc {
    if (type == 'structured') {
      final v = _linesToEnhancedLrc(original);
      if (v.trim().isNotEmpty) return v;
    }
    return displayText;
  }

  /// 按歌词模式 + 翻译/罗马音偏好渲染歌词（对齐 Lyrico 管线）。
  ///
  /// - [mode] 逐字/增强逐字/逐行/TTML；
  /// - [includeTranslation] / [includeRomanization] 控制是否合并翻译/罗马音；
  /// - [onlyTranslation] 仅输出翻译（跳过原文）。
  String lyricsFor(
    LyricMode mode, {
    bool includeTranslation = true,
    bool includeRomanization = true,
    bool onlyTranslation = false,
  }) {
    switch (mode) {
      case LyricMode.verbatim:
        final v = _renderVerbatum(
          onlyTranslation: onlyTranslation,
          includeRomanization: includeRomanization,
          includeTranslation: includeTranslation,
        );
        if (v.trim().isNotEmpty) return v;
        return displayText;
      case LyricMode.enhanced:
        final v = _renderEnhanced(
          onlyTranslation: onlyTranslation,
          includeRomanization: includeRomanization,
          includeTranslation: includeTranslation,
        );
        if (v.trim().isNotEmpty) return v;
        return displayText;
      case LyricMode.plain:
        final v = _renderPlain(
          onlyTranslation: onlyTranslation,
          includeRomanization: includeRomanization,
          includeTranslation: includeTranslation,
        );
        if (v.trim().isNotEmpty) return v;
        return displayText;
      case LyricMode.ttml:
        final t = ttmlLrc;
        if (t.trim().isNotEmpty) return t;
        return displayText;
    }
  }

  /// 逐行 LRC + 翻译/罗马音合并。
  String _renderPlain({
    required bool onlyTranslation,
    required bool includeRomanization,
    required bool includeTranslation,
  }) {
    final buffer = StringBuffer();
    final transMap = _trackByStart(translated);
    final romaMap = _trackByStart(romanization);
    for (final line in original) {
      final ts = _formatTimestamp(line.startMs);
      if (onlyTranslation) {
        final tr = transMap[line.startMs];
        if (tr != null) buffer.writeln('[$ts]${tr.text}');
        continue;
      }
      buffer.writeln('[$ts]${line.text}');
      if (includeRomanization) {
        final ro = romaMap[line.startMs];
        if (ro != null && ro.text.isNotEmpty) buffer.writeln('[$ts]${ro.text}');
      }
      if (includeTranslation) {
        final tr = transMap[line.startMs];
        if (tr != null && tr.text.isNotEmpty) buffer.writeln('[$ts]${tr.text}');
      }
    }
    return buffer.toString();
  }

  /// 逐字 LRC + 翻译/罗马音合并。
  String _renderVerbatum({
    required bool onlyTranslation,
    required bool includeRomanization,
    required bool includeTranslation,
  }) {
    if (onlyTranslation) {
      return _renderPlain(
          onlyTranslation: true,
          includeRomanization: false,
          includeTranslation: true);
    }
    final base = _linesToVerbatimLrc(original);
    return _appendLinkedLines(
        base, includeRomanization, includeTranslation, verbatim: true);
  }

  /// 增强逐字 LRC + 翻译/罗马音合并。
  String _renderEnhanced({
    required bool onlyTranslation,
    required bool includeRomanization,
    required bool includeTranslation,
  }) {
    if (onlyTranslation) {
      return _renderPlain(
          onlyTranslation: true,
          includeRomanization: false,
          includeTranslation: true);
    }
    final base = _linesToEnhancedLrc(original);
    return _appendLinkedLines(
        base, includeRomanization, includeTranslation, verbatim: false);
  }

  /// 把翻译/罗马音按行时间戳追加到逐字/增强输出后（Lyrico 按原文行合并）。
  String _appendLinkedLines(
    String base,
    bool includeRomanization,
    bool includeTranslation, {
    required bool verbatim,
  }) {
    final buffer = StringBuffer(base);
    final transMap = _trackByStart(translated);
    final romaMap = _trackByStart(romanization);
    for (final line in original) {
      final ts = _formatTimestamp(line.startMs);
      if (includeRomanization) {
        final ro = romaMap[line.startMs];
        if (ro != null && ro.text.isNotEmpty) buffer.writeln('[$ts]${ro.text}');
      }
      if (includeTranslation) {
        final tr = transMap[line.startMs];
        if (tr != null && tr.text.isNotEmpty) buffer.writeln('[$ts]${tr.text}');
      }
    }
    return buffer.toString();
  }

  /// 按行开始时间戳索引翻译/罗马音轨道。
  static Map<int, LyricLine> _trackByStart(List<LyricLine> track) {
    final map = <int, LyricLine>{};
    for (final line in track) {
      map[line.startMs] = line;
    }
    return map;
  }

  /// 从 structured 生成 TTML 歌词（对齐 Lyrico TTML 输出）。
  ///
  /// 仅当 [type] 为 structured 且有词时间戳时生成；否则回退 [displayText]。
  String get ttmlLrc {
    if (type == 'structured') {
      final t = _linesToTtml(original);
      if (t.trim().isNotEmpty) return t;
    }
    return displayText;
  }

  /// 把 structured 行列表转成 LRC 文本（供编辑/写入）。
  static String _linesToLrc(List<LyricLine> lines) {
    final buffer = StringBuffer();
    for (final line in lines) {
      final ts = _formatTimestamp(line.startMs);
      buffer.writeln('[$ts]${line.text}');
    }
    return buffer.toString();
  }

  /// 把 structured 行列表转成**普通逐字 LRC**（对齐 Lyrico 逐字歌词格式）。
  ///
  /// 仅**多词行**（真正的逐字，≥2 个词）输出逐字标签；单词/整行/元数据行
  /// （词/曲/编曲等）保持 `[mm:ss.xxx]文本` + **行尾 `[end]`**（与逐字行
  /// 一致的结束时长）。
  ///
  /// 逐字行：每字 `[start]字` + **行尾 `[end]`**（结束时间戳带 `[]`）：
  /// `[00:25.301]不[00:25.831]做…豫[00:31.626]`。
  ///
  /// 普通行：`[start]文本[end]`（如 `[00:00.010]我等你 - 刘若英[00:00.020]`）。
  static String _linesToVerbatimLrc(List<LyricLine> lines) {
    final buffer = StringBuffer();
    for (final line in lines) {
      if (line.words.length >= 2) {
        for (final w in line.words) {
          buffer.write('[${_formatTimestamp(w.startMs)}]${w.text}');
        }
        // 行尾结束时间戳：最后字 endMs（或行 endMs）
        final endMs = line.words.last.endMs > 0 ? line.words.last.endMs : line.endMs;
        if (endMs > 0) buffer.write('[${_formatTimestamp(endMs)}]');
        buffer.writeln();
      } else {
        // 普通行：也带行尾结束时长（逐字歌词每行都有结束时间戳）
        buffer.write('[${_formatTimestamp(line.startMs)}]${line.text}');
        final endMs = line.endMs > 0 ? line.endMs : line.startMs;
        if (endMs > line.startMs) {
          buffer.write('[${_formatTimestamp(endMs)}]');
        }
        buffer.writeln();
      }
    }
    return buffer.toString();
  }

  /// 把 structured 行列表转成**增强逐字 LRC**（对齐 Lyrico 增强型逐字歌词）。
  ///
  /// 仅多词行输出增强逐字标签；单词/整行/元数据行也带 `<start>text<end>`。
  ///
  /// 增强行：`[行start] ` + 每字 `<start>字` + **行尾 `<end>`**：
  /// `[00:25.301] <00:25.301>不<00:25.831>做…豫<00:31.626>`。
  ///
  /// 普通行：`[start] <start>text<end>`（如
  /// `[00:00.010] <00:00.010>我等你 - 刘若英<00:00.020>`）。
  static String _linesToEnhancedLrc(List<LyricLine> lines) {
    final buffer = StringBuffer();
    for (final line in lines) {
      if (line.words.length >= 2) {
        buffer.write('[${_formatTimestamp(line.startMs)}] ');
        for (final w in line.words) {
          buffer.write('<${_formatTimestamp(w.startMs)}>${w.text}');
        }
        final endMs = line.words.last.endMs > 0 ? line.words.last.endMs : line.endMs;
        if (endMs > 0) buffer.write('<${_formatTimestamp(endMs)}>');
        buffer.writeln();
      } else {
        // 普通行：`[start] <start>text<end>`（增强格式，也带结束时长）
        buffer.write('[${_formatTimestamp(line.startMs)}] ');
        buffer.write('<${_formatTimestamp(line.startMs)}>${line.text}');
        final endMs = line.endMs > 0 ? line.endMs : line.startMs;
        if (endMs > line.startMs) {
          buffer.write('<${_formatTimestamp(endMs)}>');
        }
        buffer.writeln();
      }
    }
    return buffer.toString();
  }

  /// 把 structured 行列表转成 **TTML XML**（对齐 Lyrico/Apple TTML 输出）。
  ///
  /// 每行一个 `<p begin end>`，带词时间戳时含 `<span begin end>`。
  static String _linesToTtml(List<LyricLine> lines) {
    if (lines.isEmpty) return '';
    final buffer = StringBuffer();
    buffer.writeln('<?xml version="1.0" encoding="utf-8"?>');
    buffer.writeln('<tt xmlns="http://www.w3.org/ns/ttml" '
        'xmlns:ttm="http://www.w3.org/ns/ttml#metadata" '
        'xmlns:itunes="http://music.apple.com/itunes/ttml">');
    buffer.writeln('  <body>');
    buffer.writeln('    <div>');
    for (final line in lines) {
      final begin = _formatTtmlTime(line.startMs);
      final end = _formatTtmlTime(line.endMs > 0 ? line.endMs : line.startMs + 1000);
      if (line.words.length >= 2) {
        buffer.write('      <p begin="$begin" end="$end">');
        for (final w in line.words) {
          final wb = _formatTtmlTime(w.startMs);
          final we = _formatTtmlTime(w.endMs > 0 ? w.endMs : w.startMs + 1);
          buffer.write('<span begin="$wb" end="$we">${_xmlEscape(w.text)}</span>');
        }
        buffer.writeln('</p>');
      } else {
        buffer.writeln('      <p begin="$begin" end="$end">'
            '<span begin="$begin" end="$end">${_xmlEscape(line.text)}</span></p>');
      }
    }
    buffer.writeln('    </div>');
    buffer.writeln('  </body>');
    buffer.writeln('</tt>');
    return buffer.toString();
  }

  /// TTML 时间格式：`HH:MM:SS.mmm`。
  static String _formatTtmlTime(int ms) {
    final h = (ms ~/ 3600000).toString().padLeft(2, '0');
    final m = ((ms % 3600000) ~/ 60000).toString().padLeft(2, '0');
    final s = ((ms % 60000) ~/ 1000).toString().padLeft(2, '0');
    final milli = (ms % 1000).toString().padLeft(3, '0');
    return '$h:$m:$s.$milli';
  }

  static String _xmlEscape(String text) {
    return text
        .replaceAll('&', '&amp;')
        .replaceAll('<', '&lt;')
        .replaceAll('>', '&gt;')
        .replaceAll('"', '&quot;');
  }

  static String _formatTimestamp(int ms) {
    final m = (ms ~/ 60000).toString().padLeft(2, '0');
    final s = ((ms % 60000) ~/ 1000).toString().padLeft(2, '0');
    final h = (ms % 1000).toString().padLeft(3, '0');
    return '$m:$s.$h';
  }

  String get title => tags['ti'] ?? '';
  String get artist => tags['ar'] ?? '';
  String get album => tags['al'] ?? '';
}

/// 逐词歌词的一个词（普通逐字 LRC 用）。
class LyricWord {
  final int startMs;
  final int endMs;
  final String text;

  const LyricWord({
    required this.startMs,
    required this.endMs,
    required this.text,
  });
}

/// 逐词/逐行歌词（structured 格式的一行）。
///
/// 行可能带逐词时间戳（[words]），供「逐字歌词优先」时输出普通逐字 LRC。
class LyricLine {
  final int startMs;
  final int endMs;
  final String text;

  /// 逐词时间戳（可选）；为空表示整行无逐字信息。
  final List<LyricWord> words;

  const LyricLine({
    required this.startMs,
    required this.endMs,
    required this.text,
    this.words = const [],
  });
}

/// 解析搜索结果的原始 JSON（Lyrico PluginJsonParser 语义）。
List<SongMatchResult> parseSongResults(
  String rawJson,
  String pluginId,
  String pluginName, {
  bool requireId = true,
}) {
  if (rawJson.isEmpty) return [];
  final root = jsonDecode(rawJson);
  final items = switch (root) {
    List list => list,
    Map map => _firstList(
        map.cast<String, dynamic>(), ['items', 'results', 'songs', 'data']),
    _ => <dynamic>[],
  };
  if (items == null) return [];

  final results = <SongMatchResult>[];
  var index = 0;
  for (final element in items) {
    if (element is! Map) continue;
    final obj = element.cast<String, dynamic>();
    final coverUrl =
        _firstString(obj, ['picUrl', 'coverUrl', 'cover_url', 'artworkUrl']);
    final id = _firstString(obj, ['id', 'songId', 'trackId']);
    if (id.isEmpty && requireId) {
      continue;
    }
    final resolvedId = id.isNotEmpty
        ? id
        : coverUrl.isNotEmpty
            ? coverUrl
            : '$pluginId:cover:$index';
    final title = _firstString(obj, ['title', 'name', 'songName']);
    final artist = _firstString(obj, ['artist', 'artists', 'singer']);
    final album = _firstString(obj, ['album', 'albumName']);
    final date = _firstString(obj, ['year', 'date', 'releaseDate', 'release_date']);
    final duration = _firstInt(obj, ['duration', 'durationMs', 'duration_ms']);
    final trackNumber =
        _firstString(obj, ['trackNumber', 'trackerNumber', 'track_number']);
    final discNumber = _firstString(obj, ['discNumber', 'disc_number', 'disc']);
    final fields = _stringMap(obj['fields'] ?? obj['metadata']);
    final internal = _stringMap(obj['internal']);

    results.add(SongMatchResult(
      id: resolvedId,
      pluginId: pluginId,
      pluginName: pluginName,
      title: title,
      artist: artist,
      album: album,
      duration: duration,
      date: date,
      trackNumber: trackNumber,
      discNumber: discNumber,
      picUrl: coverUrl,
      fields: fields,
      internal: internal,
    ));
    index++;
  }
  return results;
}

/// 解析 structured 行列表（Lyrico PluginJsonParser 语义）。
///
/// 每行格式：`[startMs, endMs, "文本"]` 或
/// `[startMs, endMs, [[ws, we, "字"], ...]]`（逐词）。
List<LyricLine> parseStructuredLines(dynamic raw) {
  if (raw is! List) return [];
  final lines = <LyricLine>[];
  for (final line in raw) {
    if (line is! List || line.length < 3) continue;
    final startMs = (line[0] as num).toInt();
    final endMs = (line[1] as num).toInt();
    final payload = line[2];
    String text;
    List<LyricWord> words = const [];
    if (payload is List) {
      // 逐字格式：[start, end, [[ws, we, "字"], ...]] → 保留词时间戳，拼接为整行
      final parsed = <LyricWord>[];
      for (final word in payload) {
        if (word is! List || word.length < 3) continue;
        final ws = (word[0] as num).toInt();
        final we = (word[1] as num).toInt();
        final wText = word[2].toString();
        parsed.add(LyricWord(startMs: ws, endMs: we, text: wText));
      }
      if (parsed.isNotEmpty) {
        words = parsed;
        text = parsed.map((w) => w.text).join();
      } else {
        text = '';
      }
    } else {
      // 整行格式：[start, end, "文本"]
      text = payload.toString();
    }
    lines.add(LyricLine(
      startMs: startMs,
      endMs: endMs,
      text: text,
      words: words,
    ));
  }
  return lines;
}

/// 解析歌词候选原始 JSON（Lyrico PluginJsonParser 语义，API 4 数组 / 1-3 单对象/字符串）。
///
/// 由后端歌词接口或插件返回；结构化歌词行经 [parseStructuredLines] 解析。
List<LyricMatchResult> parseLyricsCandidates(
  String rawJson,
  String pluginId,
  String pluginName, {
  required Map<String, String> fallbackSong,
}) {
  if (rawJson.isEmpty) return [];
  final root = jsonDecode(rawJson);

  // API 4：直接数组或 items/results/candidates 包装；
  // API 1-3：裸字符串（整段 LRC）作为单候选。
  final items = switch (root) {
    List list => list,
    Map map =>
      _firstList(map.cast<String, dynamic>(), ['items', 'results', 'candidates']) ??
          [map],
    String s when s.isNotEmpty => [s],
    _ => <dynamic>[],
  };

  final results = <LyricMatchResult>[];
  for (final element in items) {
    if (element is! Map) {
      // 裸字符串（整段 LRC）→ 单候选
      if (element is String && element.isNotEmpty) {
        results.add(LyricMatchResult(
          pluginId: pluginId,
          pluginName: pluginName,
          type: 'rawPlainLrc',
          tags: {
            'ti': fallbackSong['title'] ?? '',
            'ar': fallbackSong['artist'] ?? '',
          },
          rawPlainLrc: element,
        ));
      }
      continue;
    }
    final obj = element.cast<String, dynamic>();
    final type = obj['type']?.toString() ?? 'structured';
    final tags = _stringMap(obj['tags']);

    if (type == 'structured') {
      results.add(LyricMatchResult(
        pluginId: pluginId,
        pluginName: pluginName,
        type: 'structured',
        tags: tags,
        original: parseStructuredLines(obj['original']),
        translated: parseStructuredLines(obj['translated']),
        romanization: parseStructuredLines(obj['romanization']),
      ));
    } else {
      results.add(LyricMatchResult(
        pluginId: pluginId,
        pluginName: pluginName,
        type: type,
        tags: tags,
        rawPlainLrc: obj['rawPlainLrc']?.toString() ?? '',
        rawVerbatimLrc: obj['rawVerbatimLrc']?.toString() ?? '',
        rawEnhancedLrc: obj['rawEnhancedLrc']?.toString() ?? '',
        rawTtml: obj['rawTtml']?.toString() ?? '',
        rawMultiPersonEnhancedLrc: obj['rawMultiPersonEnhancedLrc']?.toString() ?? '',
      ));
    }
  }
  return results;
}

String _firstString(Map<String, dynamic> obj, List<String> keys) {
  for (final key in keys) {
    final value = obj[key];
    if (value == null) continue;
    if (value is List) {
      final joined = value
          .where((e) => e != null && e.toString().isNotEmpty)
          .map((e) => e.toString())
          .join('/');
      if (joined.isNotEmpty) return joined;
    } else {
      final s = value.toString();
      if (s.isNotEmpty) return s;
    }
  }
  return '';
}

int _firstInt(Map<String, dynamic> obj, List<String> keys) {
  for (final key in keys) {
    final value = obj[key];
    if (value is num) return value.toInt();
    if (value is String) {
      final parsed = int.tryParse(value);
      if (parsed != null) return parsed;
    }
  }
  return 0;
}

List<dynamic>? _firstList(Map<String, dynamic> obj, List<String> keys) {
  for (final key in keys) {
    final value = obj[key];
    if (value is List) return value;
  }
  return null;
}

Map<String, String> _stringMap(dynamic value) {
  if (value is! Map) return {};
  final result = <String, String>{};
  value.forEach((k, v) {
    if (v != null) result[k.toString()] = v.toString();
  });
  return result;
}
