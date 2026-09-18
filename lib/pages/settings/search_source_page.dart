import 'package:flutter/material.dart';
import 'package:signals_flutter/signals_flutter.dart' hide computed;

import '../../app/router/app_router.dart';
import '../../app/services/song_match/backend_match_client.dart';
import '../../app/services/song_match/match_source_state.dart';
import '../../components/index.dart';

/// 搜索源管理页：选择后端可用平台并排序（替换原「数据源插件管理」）。
///
/// - 从服务端增强（FnMusicEnhance）拉取可用平台列表；
/// - **客户端决定启用哪些平台**（开关）；
/// - 拖动排序（顺序即搜索结果的平台分组顺序，后端不自行定序）。
class SearchSourcePage extends StatefulWidget {
  const SearchSourcePage({super.key});

  @override
  State<SearchSourcePage> createState() => _SearchSourcePageState();
}

class _SearchSourcePageState extends State<SearchSourcePage>
    with SignalsMixin {
  late final _loading = createSignal(true);
  late final _error = createSignal<String?>(null);

  @override
  void initState() {
    super.initState();
    _refresh();
  }

  Future<void> _refresh() async {
    _loading.value = true;
    _error.value = null;
    try {
      await MatchSourceState.instance.ensureLoaded();
      await MatchSourceState.instance.refresh();
    } catch (e) {
      _error.value = '$e';
    } finally {
      _loading.value = false;
    }
  }

  void _openCompanionSettings() {
    Navigator.pushNamed(context, AppRoutes.metadataMatchSettings);
  }

  String _capabilitiesText(SearchSourceInfo info) {
    final labels = <String>[];
    if (info.hasCapability('searchSongs')) labels.add('歌曲搜索');
    if (info.hasCapability('searchCovers')) labels.add('封面');
    if (info.hasCapability('getLyrics')) labels.add('歌词');
    return labels.isEmpty ? '无能力' : labels.join(' / ');
  }

  @override
  Widget build(BuildContext context) {
    return AppPageScaffold(
      extendBodyBehindAppBar: true,
      appBar: AppTopBar(
        title: '搜索源管理',
        backgroundColor: Colors.transparent,
        elevation: 0,
        actions: [
          IconButton(
            tooltip: '刷新平台列表',
            icon: const Icon(Icons.refresh_rounded),
            onPressed: _loading.value ? null : _refresh,
          ),
        ],
      ),
      showMiniPlayer: false,
      body: Watch.builder(
        builder: (context) {
          if (_loading.value) {
            return const Center(child: CircularProgressIndicator());
          }
          final err = _error.value;
          if (err != null) {
            return _buildError(context, err);
          }
          return _buildList(context);
        },
      ),
    );
  }

  Widget _buildError(BuildContext context, String err) {
    final colorScheme = Theme.of(context).colorScheme;
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        const SizedBox(height: 32),
        Icon(Icons.cloud_off_rounded,
            size: 48, color: colorScheme.outline),
        const SizedBox(height: 12),
        Center(
          child: Text('无法获取搜索平台列表',
              style: Theme.of(context).textTheme.titleMedium),
        ),
        const SizedBox(height: 8),
        Center(
          child: Text(
            err,
            textAlign: TextAlign.center,
            style: Theme.of(context)
                .textTheme
                .bodySmall
                ?.copyWith(color: colorScheme.onSurfaceVariant),
          ),
        ),
        const SizedBox(height: 16),
        Center(
          child: FilledButton(
            onPressed: _refresh,
            child: const Text('重试'),
          ),
        ),
        const SizedBox(height: 4),
        Center(
          child: TextButton(
            onPressed: _openCompanionSettings,
            child: const Text('前往服务端增强设置'),
          ),
        ),
      ],
    );
  }

  Widget _buildList(BuildContext context) {
    final state = MatchSourceState.instance;
    // order/enabled/available 是 ValueNotifier，用 ListenableBuilder 监听
    // 实现排序/禁用后的实时刷新（Watch.builder 只跟踪 Signal，不跟踪 ValueNotifier）。
    return ListenableBuilder(
      listenable: Listenable.merge(
          [state.available, state.order, state.enabled]),
      builder: (context, _) {
        if (state.available.value.isEmpty) {
          return const Center(child: Text('暂无可用搜索平台'));
        }
        // 显示顺序 = order（含未启用平台，用户拖动排序）；order 未初始化时用 available。
        final byId = {
          for (final s in state.available.value) s.id: s,
        };
        final displayIds = state.order.value.isNotEmpty
            ? state.order.value
            : state.available.value.map((s) => s.id).toList();
        final sources = displayIds
            .map((id) => byId[id])
            .whereType<SearchSourceInfo>()
            .toList();
        final enabled = state.enabled.value;
        return Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
              child: Text(
                '启用平台并拖动排序（顺序即搜索结果分组顺序）',
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                    ),
              ),
            ),
            Expanded(
              child: ReorderableListView.builder(
                padding: const EdgeInsets.fromLTRB(12, 4, 12, 24),
                itemCount: sources.length,
                onReorder: (oldIndex, newIndex) {
                  if (newIndex > oldIndex) newIndex--;
                  if (oldIndex < 0 ||
                      oldIndex >= displayIds.length ||
                      newIndex < 0 ||
                      newIndex >= displayIds.length) {
                    return;
                  }
                  // 直接写入重排结果（绝对位置，避免相对移动错乱）
                  final reordered = List.of(displayIds);
                  final id = reordered.removeAt(oldIndex);
                  reordered.insert(newIndex, id);
                  state.setOrder(reordered);
                },
                itemBuilder: (context, index) {
                  final source = sources[index];
                  final isEnabled = enabled.contains(source.id);
                  return ListTile(
                    key: ValueKey(source.id),
                    leading: Icon(
                      isEnabled
                          ? Icons.check_circle_rounded
                          : Icons.radio_button_unchecked_rounded,
                      color: isEnabled
                          ? Theme.of(context).colorScheme.primary
                          : null,
                    ),
                    title: Text(source.name),
                    subtitle: Text(
                      '${source.id} · ${_capabilitiesText(source)}',
                    ),
                    trailing: ReorderableDragStartListener(
                      index: index,
                      child: const Padding(
                        padding: EdgeInsets.symmetric(horizontal: 8),
                        child: Icon(Icons.drag_indicator_rounded),
                      ),
                    ),
                    onTap: () => state.setEnabled(
                      source.id,
                      !isEnabled,
                    ),
                  );
                },
              ),
            ),
          ],
        );
      },
    );
  }
}
