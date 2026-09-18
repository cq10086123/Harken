import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:feiniu_music/app/services/song_match/backend_match_client.dart';
import 'package:feiniu_music/app/services/song_match/match_source_state.dart';

SearchSourceInfo _src(String id) =>
    SearchSourceInfo(id: id, name: id);

void main() {
  setUp(() {
    TestWidgetsFlutterBinding.ensureInitialized();
    SharedPreferences.setMockInitialValues({});
    final s = MatchSourceState.instance;
    s.available.value = const [];
    s.order.value = const [];
    s.enabled.value = const [];
  });

  test('未初始化时 enabledIdsInOrder 兜底为全部可用平台', () {
    final s = MatchSourceState.instance;
    s.available.value = ['netease', 'qq', 'kugou'].map(_src).toList();
    expect(s.enabledIdsInOrder, ['netease', 'qq', 'kugou'],
        reason: 'order/enabled 未初始化 → 默认全启用');
  });

  test('有 order 但 enabled 部分启用：按 order 过滤', () {
    final s = MatchSourceState.instance;
    s.available.value = ['netease', 'qq', 'kugou', 'soda', 'apple'].map(_src).toList();
    s.order.value = ['qq', 'netease', 'kugou', 'soda', 'apple'];
    s.enabled.value = ['qq', 'kugou'];
    expect(s.enabledIdsInOrder, ['qq', 'kugou'],
        reason: '搜索顺序 = order 过滤 enabled');
  });

  test('move 排序含未启用平台，禁用不丢位置', () async {
    final s = MatchSourceState.instance;
    s.available.value = ['netease', 'qq', 'kugou', 'soda', 'apple'].map(_src).toList();
    s.order.value = ['netease', 'qq', 'kugou', 'soda', 'apple'];
    s.enabled.value = ['netease', 'qq', 'kugou'];

    // 禁用 netease（从 enabled 移除，但 order 位置保留）
    await s.setEnabled('netease', false);
    expect(s.isEnabled('netease'), isFalse);
    expect(s.order.value, ['netease', 'qq', 'kugou', 'soda', 'apple'],
        reason: '禁用不改 order，排序位置保留');

    // 重新启用 → 回到原位（order 位置），而非末尾
    await s.setEnabled('netease', true);
    expect(s.enabled.value, contains('netease'));
    expect(s.order.value.indexOf('netease'), 0,
        reason: '重新启用回到原排序位');

    // 拖动排序：kugou 上移 1 位
    await s.move('kugou', -1);
    expect(s.order.value, ['netease', 'kugou', 'qq', 'soda', 'apple'],
        reason: 'move 改 order（含未启用平台）');
  });

  test('indexOf 基于 order', () {
    final s = MatchSourceState.instance;
    s.available.value = ['netease', 'qq', 'kugou'].map(_src).toList();
    s.order.value = ['qq', 'netease', 'kugou'];
    expect(s.indexOf('qq'), 0);
    expect(s.indexOf('kugou'), 2);
  });

  test('ensureLoaded 从持久化恢复 order/enabled', () async {
    SharedPreferences.setMockInitialValues({
      'match_sources_order': ['qq', 'netease', 'kugou'],
      'match_sources_enabled': ['qq', 'kugou'],
    });
    final s = MatchSourceState.instance;
    await s.ensureLoaded();
    expect(s.order.value, ['qq', 'netease', 'kugou']);
    expect(s.enabled.value, ['qq', 'kugou']);
  });
}
