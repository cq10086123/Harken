import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 歌词模式（Lyrico 歌词设置，见 Lyrico docs/guide/settings/lyrics.md）。
enum LyricMode {
  plain, // 逐行 LRC
  verbatim, // 逐字
  enhanced, // 增强逐字
  ttml, // TTML
}

/// 中文文本转换（Lyrico 元数据处理设置）。
enum ChineseTextConvert {
  none,
  simplifiedToTraditional,
  traditionalToSimplified,
}

/// 数据源匹配设置（移植 Lyrico 的歌词设置 + 元数据处理设置）。
///
/// - 歌词偏好：模式 / 罗马音 / 翻译 / 仅下载翻译；
/// - 元数据处理：简繁转换 / 移除空行 / 非歌词内容过滤规则 / 艺术家分隔符；
/// - 并发：批量匹配 / 插件搜索并发上限。
class MatchSettings {
  static const String _prefsLyricMode = 'match_lyric_mode';
  static const String _prefsRomanization = 'match_romanization';
  static const String _prefsTranslation = 'match_translation';
  static const String _prefsOnlyTranslation = 'match_only_translation';
  static const String _prefsChineseConvert = 'match_chinese_convert';
  static const String _prefsRemoveBlankLines = 'match_remove_blank_lines';
  static const String _prefsFilterRules = 'match_filter_rules';
  static const String _prefsArtistSeparator = 'match_artist_separator';
  static const String _prefsConcurrency = 'match_concurrency';
  static const String _prefsPreferFilename = 'match_prefer_filename';

  static final ValueNotifier<LyricMode> lyricMode =
      ValueNotifier(LyricMode.enhanced);
  static final ValueNotifier<bool> romanization = ValueNotifier(false);
  static final ValueNotifier<bool> translation = ValueNotifier(false);
  static final ValueNotifier<bool> onlyTranslation = ValueNotifier(false);
  static final ValueNotifier<ChineseTextConvert> chineseConvert =
      ValueNotifier(ChineseTextConvert.none);
  static final ValueNotifier<bool> removeBlankLines = ValueNotifier(false);

  /// 非歌词内容过滤规则（`作词 :`、`作曲 :`、`来源 QQ音乐` 等）。
  static final ValueNotifier<List<String>> filterRules = ValueNotifier(const []);

  /// 多歌手写入时的分隔符（默认 `/`）。
  static final ValueNotifier<String> artistSeparator = ValueNotifier('/');

  /// 并发上限（批量匹配 / 插件搜索并发）。
  static final ValueNotifier<int> concurrency = ValueNotifier(3);

  /// 优先使用文件名匹配：忽略内置标题/歌手标签，用文件名作为搜索关键词
  /// （适合标签混乱但文件名规范的音乐库）。默认关闭。
  static final ValueNotifier<bool> preferFilename = ValueNotifier(false);

  static bool _loaded = false;

  static bool get loaded => _loaded;

  static Future<void> ensureLoaded() async {
    if (_loaded) return;
    final prefs = await SharedPreferences.getInstance();
    lyricMode.value = _parseLyricMode(prefs.getString(_prefsLyricMode));
    romanization.value = prefs.getBool(_prefsRomanization) ?? false;
    translation.value = prefs.getBool(_prefsTranslation) ?? false;
    onlyTranslation.value = prefs.getBool(_prefsOnlyTranslation) ?? false;
    chineseConvert.value =
        _parseChineseConvert(prefs.getString(_prefsChineseConvert));
    removeBlankLines.value = prefs.getBool(_prefsRemoveBlankLines) ?? false;
    filterRules.value = prefs.getStringList(_prefsFilterRules) ?? const [];
    artistSeparator.value = prefs.getString(_prefsArtistSeparator) ?? '/';
    concurrency.value = (prefs.getInt(_prefsConcurrency) ?? 3).clamp(1, 8);
    preferFilename.value = prefs.getBool(_prefsPreferFilename) ?? false;
    _loaded = true;
  }

  static Future<void> setLyricMode(LyricMode mode) async {
    lyricMode.value = mode;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_prefsLyricMode, mode.name);
  }

  static Future<void> setRomanization(bool value) async {
    romanization.value = value;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_prefsRomanization, value);
  }

  static Future<void> setTranslation(bool value) async {
    translation.value = value;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_prefsTranslation, value);
  }

  static Future<void> setOnlyTranslation(bool value) async {
    onlyTranslation.value = value;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_prefsOnlyTranslation, value);
  }

  static Future<void> setChineseConvert(ChineseTextConvert value) async {
    chineseConvert.value = value;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_prefsChineseConvert, value.name);
  }

  static Future<void> setRemoveBlankLines(bool value) async {
    removeBlankLines.value = value;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_prefsRemoveBlankLines, value);
  }

  static Future<void> setFilterRules(List<String> rules) async {
    filterRules.value = rules;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList(_prefsFilterRules, rules);
  }

  static Future<void> setArtistSeparator(String value) async {
    final normalized = value.isEmpty ? '/' : value;
    artistSeparator.value = normalized;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_prefsArtistSeparator, normalized);
  }

  static Future<void> setConcurrency(int value) async {
    final clamped = value.clamp(1, 8);
    concurrency.value = clamped;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(_prefsConcurrency, clamped);
  }

  static Future<void> setPreferFilename(bool value) async {
    preferFilename.value = value;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_prefsPreferFilename, value);
  }

  static LyricMode _parseLyricMode(String? value) {
    for (final mode in LyricMode.values) {
      if (mode.name == value) return mode;
    }
    return LyricMode.verbatim;
  }

  static ChineseTextConvert _parseChineseConvert(String? value) {
    for (final mode in ChineseTextConvert.values) {
      if (mode.name == value) return mode;
    }
    return ChineseTextConvert.none;
  }
}
