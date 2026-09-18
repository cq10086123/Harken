import 'package:flutter/material.dart';
import 'package:signals_flutter/signals_flutter.dart' hide computed;

import '../../app/state/settings_match.dart';
import '../../components/index.dart';

/// 数据匹配设置页（移植 Lyrico 歌词设置 + 元数据处理设置）。
///
/// - 歌词偏好：模式 / 罗马音 / 翻译 / 仅下载翻译；
/// - 元数据处理：简繁转换 / 移除空行 / 非歌词内容过滤规则 / 艺术家分隔符；
/// - 并发：批量匹配并发上限。
class MatchSettingsPage extends StatefulWidget {
  const MatchSettingsPage({super.key});

  @override
  State<MatchSettingsPage> createState() => _MatchSettingsPageState();
}

class _MatchSettingsPageState extends State<MatchSettingsPage>
    with SignalsMixin {
  late final _loading = createSignal(true);

  final TextEditingController _separatorController = TextEditingController();
  final TextEditingController _ruleController = TextEditingController();

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    await MatchSettings.ensureLoaded();
    _separatorController.text = MatchSettings.artistSeparator.value;
    _loading.value = false;
  }

  @override
  void dispose() {
    _separatorController.dispose();
    _ruleController.dispose();
    super.dispose();
  }

  Future<void> _applyConcurrency(int value) async {
    await MatchSettings.setConcurrency(value);
  }

  @override
  Widget build(BuildContext context) {
    return Watch.builder(
      builder: (context) {
        if (_loading.value) {
          return const Scaffold(
            body: Center(child: CircularProgressIndicator()),
          );
        }
        return AppPageScaffold(
          extendBodyBehindAppBar: true,
          appBar: const AppTopBar(
            title: '数据匹配设置',
            backgroundColor: Colors.transparent,
            elevation: 0,
          ),
          showMiniPlayer: false,
          body: ListView(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
            children: [
              AppSettingSection(
                title: '歌词偏好',
                children: [
                  ValueListenableBuilder<bool>(
                    valueListenable: MatchSettings.preferFilename,
                    builder: (context, v, _) => AppSettingSwitchTile(
                      title: '优先使用文件名匹配',
                      subtitle: '忽略内置标题/歌手标签，用文件名搜索'
                          '（适合标签混乱但文件名规范的音乐库）',
                      value: v,
                      onChanged: (value) =>
                          MatchSettings.setPreferFilename(value),
                    ),
                  ),
                  _buildLyricModeTile(context),
                  ValueListenableBuilder<bool>(
                    valueListenable: MatchSettings.romanization,
                    builder: (context, v, _) => AppSettingSwitchTile(
                      title: '罗马音',
                      subtitle: '搜索歌词时请求罗马音内容（适合日语歌曲）',
                      value: v,
                      onChanged: (value) => MatchSettings.setRomanization(value),
                    ),
                  ),
                  ValueListenableBuilder<bool>(
                    valueListenable: MatchSettings.translation,
                    builder: (context, v, _) => AppSettingSwitchTile(
                      title: '翻译',
                      subtitle: '搜索歌词时请求翻译内容',
                      value: v,
                      onChanged: (value) => MatchSettings.setTranslation(value),
                    ),
                  ),
                  ValueListenableBuilder<bool>(
                    valueListenable: MatchSettings.onlyTranslation,
                    builder: (context, v, _) => AppSettingSwitchTile(
                      title: '仅下载翻译歌词',
                      subtitle: '歌曲已有原文歌词时，只下载翻译部分',
                      value: v,
                      onChanged: (value) =>
                          MatchSettings.setOnlyTranslation(value),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 16),
              AppSettingSection(
                title: '元数据处理',
                children: [
                  _buildChineseConvertTile(context),
                  ValueListenableBuilder<bool>(
                    valueListenable: MatchSettings.removeBlankLines,
                    builder: (context, v, _) => AppSettingSwitchTile(
                      title: '移除空行',
                      subtitle: '保存歌词等多行文本时自动删除空行',
                      value: v,
                      onChanged: (value) =>
                          MatchSettings.setRemoveBlankLines(value),
                    ),
                  ),
                  _buildFilterRulesTile(context),
                  _buildArtistSeparatorTile(context),
                ],
              ),
              const SizedBox(height: 16),
              AppSettingSection(
                title: '并发',
                children: [
                  _buildConcurrencyTile(context),
                ],
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _buildLyricModeTile(BuildContext context) {
    final labels = {
      'plain': '逐行',
      'verbatim': '逐字',
      'enhanced': '增强逐字',
      'ttml': 'TTML',
    };
    return ValueListenableBuilder<LyricMode>(
      valueListenable: MatchSettings.lyricMode,
      builder: (context, mode, _) {
        return Padding(
          padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                '歌词模式',
                style: Theme.of(context).textTheme.titleSmall,
              ),
              const SizedBox(height: 10),
              SizedBox(
                width: double.infinity,
                child: SegmentedButton<LyricMode>(
                  segments: [
                    for (final m in LyricMode.values)
                      ButtonSegment(
                        value: m,
                        label: Text(labels[m.name] ?? m.name),
                      ),
                  ],
                  selected: {mode},
                  showSelectedIcon: false,
                  onSelectionChanged: (selection) {
                    MatchSettings.setLyricMode(selection.first);
                  },
                ),
              ),
              const SizedBox(height: 8),
              Text(
                '搜索歌词时优先获取的歌词格式',
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                    ),
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _buildChineseConvertTile(BuildContext context) {
    final labels = {
      'none': '不转换',
      'simplifiedToTraditional': '简转繁',
      'traditionalToSimplified': '繁转简',
    };
    return ValueListenableBuilder<ChineseTextConvert>(
      valueListenable: MatchSettings.chineseConvert,
      builder: (context, mode, _) {
        return Padding(
          padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                '中文文本转换',
                style: Theme.of(context).textTheme.titleSmall,
              ),
              const SizedBox(height: 10),
              SizedBox(
                width: double.infinity,
                child: SegmentedButton<ChineseTextConvert>(
                  segments: [
                    for (final m in ChineseTextConvert.values)
                      ButtonSegment(
                        value: m,
                        label: Text(labels[m.name] ?? m.name),
                      ),
                  ],
                  selected: {mode},
                  showSelectedIcon: false,
                  onSelectionChanged: (selection) {
                    MatchSettings.setChineseConvert(selection.first);
                  },
                ),
              ),
              const SizedBox(height: 8),
              Text(
                '应用于搜索到的文本元数据与歌词',
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                    ),
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _buildFilterRulesTile(BuildContext context) {
    return ValueListenableBuilder<List<String>>(
      valueListenable: MatchSettings.filterRules,
      builder: (context, rules, _) {
        return AppSettingTile(
          title: '非歌词内容过滤',
          subtitle: rules.isEmpty
              ? '添加过滤规则（如 作词 :、来源 QQ音乐）'
              : '${rules.length} 条规则',
          trailing: const Icon(Icons.chevron_right_rounded),
          onTap: () async {
            final result = await showModalBottomSheet<List<String>>(
              context: context,
              backgroundColor: Colors.transparent,
              isScrollControlled: true,
              builder: (_) => _FilterRulesSheet(rules: rules),
            );
            if (result != null) await MatchSettings.setFilterRules(result);
          },
        );
      },
    );
  }

  Widget _buildArtistSeparatorTile(BuildContext context) {
    return ValueListenableBuilder<String>(
      valueListenable: MatchSettings.artistSeparator,
      builder: (context, separator, _) {
        return AppSettingTile(
          title: '艺术家分隔符',
          subtitle: '多歌手写入时使用的分隔符：$separator',
          trailing: const Icon(Icons.chevron_right_rounded),
          onTap: () async {
            final controller = TextEditingController(text: separator);
            final result = await showDialog<String>(
              context: context,
              builder: (dialogContext) => AlertDialog(
                title: const Text('艺术家分隔符'),
                content: TextField(
                  controller: controller,
                  decoration: const InputDecoration(hintText: '/'),
                ),
                actions: [
                  TextButton(
                    onPressed: () => Navigator.of(dialogContext).pop(),
                    child: const Text('取消'),
                  ),
                  FilledButton(
                    // 用对话框自身 context pop（嵌套 Navigator 下外部 context
                    // pop 可能无效）。
                    onPressed: () {
                      final value = controller.text.trim();
                      if (value.isEmpty) return;
                      Navigator.of(dialogContext).pop(value);
                    },
                    child: const Text('确定'),
                  ),
                ],
              ),
            );
            if (result != null) {
              await MatchSettings.setArtistSeparator(result);
            }
          },
        );
      },
    );
  }

  Widget _buildConcurrencyTile(BuildContext context) {
    return ValueListenableBuilder<int>(
      valueListenable: MatchSettings.concurrency,
      builder: (context, concurrency, _) {
        return AppSettingSlider(
          title: '并发上限',
          value: concurrency.toDouble(),
          min: 1,
          max: 8,
          divisions: 7,
          valueText: '$concurrency',
          description: '批量匹配同时请求数',
          onChanged: (v) => _applyConcurrency(v.toInt()),
        );
      },
    );
  }
}

/// 非歌词内容过滤规则编辑弹层。
class _FilterRulesSheet extends StatefulWidget {
  final List<String> rules;

  const _FilterRulesSheet({required this.rules});

  @override
  State<_FilterRulesSheet> createState() => _FilterRulesSheetState();
}

class _FilterRulesSheetState extends State<_FilterRulesSheet> {
  late final List<String> _rules;
  late final TextEditingController _controller;

  @override
  void initState() {
    super.initState();
    _rules = List.of(widget.rules);
    _controller = TextEditingController();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return DraggableScrollableSheet(
      initialChildSize: 0.7,
      maxChildSize: 0.9,
      builder: (context, scrollController) {
        return AppSheetPanel(
          title: '非歌词内容过滤规则',
          expand: true,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 4, 16, 4),
                child: Row(
                  children: [
                    Expanded(
                      child: TextField(
                        controller: _controller,
                        decoration: const InputDecoration(
                          hintText: '如：作词 :、来源 QQ音乐',
                          isDense: true,
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    IconButton(
                      tooltip: '添加规则',
                      icon: const Icon(Icons.add_rounded),
                      onPressed: () {
                        final text = _controller.text.trim();
                        if (text.isEmpty) return;
                        setState(() {
                          _rules.add(text);
                          _controller.clear();
                        });
                      },
                    ),
                  ],
                ),
              ),
              const Divider(height: 1),
              Expanded(
                child: _rules.isEmpty
                    ? const Center(child: Text('暂无规则'))
                    : ListView.builder(
                        controller: scrollController,
                        itemCount: _rules.length,
                        itemBuilder: (context, index) {
                          final rule = _rules[index];
                          return ListTile(
                            title: Text(rule),
                            trailing: IconButton(
                              icon: const Icon(Icons.delete_outline_rounded),
                              onPressed: () {
                                setState(() => _rules.removeAt(index));
                              },
                            ),
                          );
                        },
                      ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
                child: SizedBox(
                  width: double.infinity,
                  height: 48,
                  child: FilledButton(
                    onPressed: () => Navigator.of(context).pop(_rules),
                    child: const Text('保存'),
                  ),
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}
