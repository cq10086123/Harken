import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 播放无歌词音乐时自动搜索歌词设置。
///
/// 开启后，播放无歌词（`hasLyric == false` / 歌词接口返回空）的音乐时，
/// 自动通过已启用的数据源插件搜索歌词。命中后写入本地缓存；[writeBack]
/// 开启且服务端增强（FnMusicEnhance）可用时，再同步写入 NAS。
class LyricAutoSearchSettings {
  static const String _prefsEnabled = 'lyric_auto_search_enabled';
  static const String _prefsWriteBack = 'lyric_auto_search_write_back';

  /// 自动搜索歌词开关。
  static final ValueNotifier<bool> enabled = ValueNotifier(false);

  /// 搜索到歌词后自动回写到 NAS（服务端增强）。默认关闭。
  static final ValueNotifier<bool> writeBack = ValueNotifier(false);

  static bool _loaded = false;

  static bool get loaded => _loaded;

  static Future<void> ensureLoaded() async {
    if (_loaded) return;
    final prefs = await SharedPreferences.getInstance();
    enabled.value = prefs.getBool(_prefsEnabled) ?? false;
    writeBack.value = prefs.getBool(_prefsWriteBack) ?? false;
    _loaded = true;
  }

  static Future<void> setEnabled(bool value) async {
    enabled.value = value;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_prefsEnabled, value);
  }

  static Future<void> setWriteBack(bool value) async {
    writeBack.value = value;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_prefsWriteBack, value);
  }
}
