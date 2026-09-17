import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 以 JSON 数组形式存放在 `SharedPreferences` 里的音源列表仓库基类。
///
/// 子类只需给出 prefs 键、ID 前缀以及 JSON 编解码方式。三种音源各一个子类，
/// 于是「增删改查一份音源列表」的逻辑只写一遍。
///
/// 移植自上游 NagoMusic 的 `PrefsSourceRepository`，差异：
/// - 去掉 `AppLog`（Harken 没有该设施），按仓库既有约定用 `kDebugMode` + `debugPrint`；
/// - 去掉 `SourceVisibilityRepository` 联动（Harken 的启用态直接放在
///   `AudioSourceConfig.enabled` 上，不需要独立的可见性仓库）。
abstract class PrefsSourceRepository<T> {
  /// 存放该列表的 `SharedPreferences` 键。
  String get prefsKey;

  /// [newId] 生成 ID 的前缀（见 `AudioSourceKindX.idPrefix`）。
  String get idPrefix;

  T fromJson(Map<String, dynamic> json);

  Map<String, dynamic> toJson(T source);

  String idOf(T source);

  /// 上一次 [loadSources] 的结果；任何写操作都会让它失效。
  ///
  /// 播放建队列时每首歌都要问一次「这个 sourceId 属于哪个音源」，恢复上次
  /// 播放留下的大队列一次就是几千次调用。没有这层缓存的话每次都要重新
  /// `jsonDecode` 整份列表——音源数量本身不多，但乘上几千首歌，解码开销
  /// 直接摊到「点一下要等多久」上。
  List<T>? _cache;

  Future<List<T>> loadSources() async {
    final cached = _cache;
    if (cached != null) return cached;

    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(prefsKey);
    if (raw == null || raw.trim().isEmpty) {
      _cache = const [];
      return const [];
    }
    try {
      final decoded = jsonDecode(raw);
      if (decoded is List) {
        final list = decoded
            .whereType<Map>()
            .map((e) => fromJson(e.cast<String, dynamic>()))
            .where((e) => idOf(e).trim().isNotEmpty)
            .toList();
        _cache = list;
        return list;
      }
    } catch (e, s) {
      if (kDebugMode) {
        debugPrint('[PrefsSourceRepository] 解析音源列表失败 key=$prefsKey: $e\n$s');
      }
    }
    _cache = const [];
    return const [];
  }

  Future<void> saveSources(List<T> sources) async {
    final prefs = await SharedPreferences.getInstance();
    final data = jsonEncode(sources.map(toJson).toList());
    await prefs.setString(prefsKey, data);
    _cache = List<T>.from(sources);
  }

  /// 按 ID 插入或整条替换。
  Future<void> upsert(T source) async {
    final list = await loadSources();
    final idx = list.indexWhere((e) => idOf(e) == idOf(source));
    final next = [...list];
    if (idx >= 0) {
      next[idx] = source;
    } else {
      next.add(source);
    }
    await saveSources(next);
  }

  Future<void> removeById(String id) async {
    final list = await loadSources();
    await saveSources(list.where((e) => idOf(e) != id).toList());
  }

  /// 按 ID 取单条；不存在返回 null。
  Future<T?> findById(String id) async {
    final list = await loadSources();
    for (final s in list) {
      if (idOf(s) == id) return s;
    }
    return null;
  }

  String newId() => '$idPrefix-${DateTime.now().millisecondsSinceEpoch}';

  /// 丢弃内存缓存，使下次 [loadSources] 重新从 prefs 读取。
  ///
  /// 仅供测试使用：子类实例是进程级单例，活过整个测试文件；`setUp` 里
  /// `setMockInitialValues` 换掉的是 SharedPreferences 的后备存储，换不掉
  /// 这层缓存，不重置的话下一个测试读到的还是上一个测试留下的旧数据。
  void resetCacheForTest() {
    _cache = null;
  }
}
