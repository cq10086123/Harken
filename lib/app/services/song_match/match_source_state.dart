import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'backend_match_client.dart';

/// 搜索平台启用/排序状态（替代原插件系统的 PluginStore 职责）。
///
/// - [available]：后端可用的平台列表（拉取后缓存，离线可读）
/// - [order]：所有平台的显示/搜索排序（含未启用，拖动排序改这里）
/// - [enabled]：启用平台集合（是否参与搜索；搜索顺序由 [order] 决定）
///
/// 排序与启用解耦：禁用平台不丢排序位置，重新启用回到原位。
class MatchSourceState {
  MatchSourceState._internal();

  static final MatchSourceState instance = MatchSourceState._internal();

  static const String _prefsCache = 'match_sources_cache';
  static const String _prefsOrder = 'match_sources_order';
  static const String _prefsEnabled = 'match_sources_enabled';

  /// 后端可用平台列表（拉取后按原顺序）。离线时用缓存。
  final ValueNotifier<List<SearchSourceInfo>> available =
      ValueNotifier(const []);

  /// 所有平台的显示/搜索排序（含未启用平台）。
  final ValueNotifier<List<String>> order = ValueNotifier(const []);

  /// 启用平台集合（顺序无意义，搜索顺序由 [order] 决定）。
  final ValueNotifier<List<String>> enabled = ValueNotifier(const []);

  static bool _loaded = false;

  static bool get loaded => _loaded;

  Future<void> ensureLoaded() async {
    if (_loaded) return;
    final prefs = await SharedPreferences.getInstance();
    // 可用平台：优先本地缓存（离线可读），启动后 refresh 更新
    final cacheJson = prefs.getString(_prefsCache);
    if (cacheJson != null && cacheJson.isNotEmpty) {
      try {
        final list = (jsonDecode(cacheJson) as List)
            .whereType<Map>()
            .map((e) => SearchSourceInfo.fromJson(e.cast<String, dynamic>()))
            .toList();
        available.value = list;
      } catch (_) {
        // 损坏缓存忽略
      }
    }
    final savedOrder = prefs.getStringList(_prefsOrder);
    if (savedOrder != null && savedOrder.isNotEmpty) {
      order.value = List.of(savedOrder);
    }
    final savedEnabled = prefs.getStringList(_prefsEnabled);
    if (savedEnabled != null && savedEnabled.isNotEmpty) {
      enabled.value = List.of(savedEnabled);
    }
    _loaded = true;
  }

  /// 从后端拉取可用平台并更新缓存。失败抛异常（供 UI 提示）。
  Future<void> refresh() async {
    final sources = await BackendMatchClient.instance.fetchSources();
    if (sources.isEmpty) return;
    available.value = sources;
    // 持久化可用列表缓存
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      _prefsCache,
      jsonEncode(sources.map((s) => {
            'id': s.id,
            'name': s.name,
            'capabilities': s.capabilities,
            'searchTypes': s.searchTypes,
            'defaultSearchType': s.defaultSearchType,
            'config': s.config,
          }).toList()),
    );
    // 排序/启用与 available 对齐（加入新平台、剔除消失平台、首次全启用）
    _reconcile(sources);
  }

  /// 当前启用的平台 id，**按 [order] 排序**。
  ///
  /// 未初始化（未进数据源页 / 首次运行）时兜底：有 order 用 order 过滤 enabled；
  /// 仅 enabled 有值用 enabled；全空则默认全部可用平台。
  List<String> get enabledIdsInOrder {
    final all = available.value.map((s) => s.id).toList();
    final o = order.value.where(all.contains).toList();
    final e = enabled.value.where(all.contains).toList();
    final ordered = o.where(e.contains).toList();
    if (ordered.isNotEmpty) return ordered;
    if (e.isNotEmpty) return e;
    return all; // 全部未初始化 → 默认全启用
  }

  bool isEnabled(String id) => enabled.value.contains(id);

  /// 切换平台启用。
  Future<void> setEnabled(String id, bool on) async {
    final current = List.of(enabled.value);
    if (on) {
      if (!current.contains(id)) current.add(id);
    } else {
      current.remove(id);
    }
    await _saveEnabled(current);
  }

  /// 上移/下移排序（delta = -1 上移，+1 下移）。改 [order]（含未启用平台）。
  Future<void> move(String id, int delta) async {
    final current = List.of(order.value);
    final index = current.indexOf(id);
    if (index < 0) return;
    final target = index + delta;
    if (target < 0 || target >= current.length) return;
    current.removeAt(index);
    current.insert(target, id);
    await _saveOrder(current);
  }

  /// 设置整个排序（onReorder 后直接写入重排结果）。
  Future<void> setOrder(List<String> ids) async {
    await _saveOrder(List.of(ids));
  }

  /// 找到某平台在 [order] 中的位置（未在列表返回 null）。
  int? indexOf(String id) {
    final i = order.value.indexOf(id);
    return i < 0 ? null : i;
  }

  Future<void> _saveOrder(List<String> ids) async {
    order.value = List.of(ids);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList(_prefsOrder, ids);
  }

  Future<void> _saveEnabled(List<String> ids) async {
    enabled.value = List.of(ids);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList(_prefsEnabled, ids);
  }

  /// 排序/启用与 available 对齐：保留已有、剔除消失、追加新增；
  /// 首次（空）时全部启用 + 按 available 顺序。
  void _reconcile(List<SearchSourceInfo> sources) {
    final idList = sources.map((s) => s.id).toList();
    final idSet = idList.toSet();
    var curOrder = order.value.where(idSet.contains).toList();
    if (curOrder.isEmpty && idList.isNotEmpty) {
      curOrder.addAll(idList);
    } else {
      // 新出现的平台追加到末尾
      curOrder.addAll(idList.where((id) => !curOrder.contains(id)));
    }
    var curEnabled = enabled.value.where(idSet.contains).toList();
    if (curEnabled.isEmpty && idList.isNotEmpty) {
      // 无已启用记录 → 默认全部启用
      curEnabled.addAll(idList);
    }
    _saveOrder(curOrder);
    _saveEnabled(curEnabled);
  }
}
