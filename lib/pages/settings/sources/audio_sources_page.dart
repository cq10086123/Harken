import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:permission_handler/permission_handler.dart';

import '../../../app/services/source/local/local_scanner.dart';
import '../../../app/services/source/local/local_source_provider.dart';
import '../../../app/services/source/local/local_source_repository.dart';
import '../../../app/services/source/source_config.dart';
import '../../../app/services/source/source_kind.dart';
import '../../../app/services/source/source_registry.dart';
import '../../../app/services/source/webdav/webdav_client.dart';
import '../../../app/services/source/webdav/webdav_source_repository.dart';
import '../../../app/services/source/webdav/webdav_scanner.dart';
import 'webdav_source_editor.dart';
import '../../../app/state/song_state.dart';
import '../../../components/index.dart';

/// 音源管理页：列出全部音源，增删改本地音源并触发扫描。
///
/// **这是整条本地音源链路的唯一 UI 入口** —— 在此之前
/// `LocalSourceProvider.scanSource` 全仓库零调用，扫描跑不起来。
///
/// 飞牛条目是隐式的（由 `AudioSourceRegistry` 合成），不可删除、不可停用、
/// 不可编辑：它的服务器地址与凭证仍归「FN Connect」管，这里只做展示。
class AudioSourcesPage extends StatefulWidget {
  const AudioSourcesPage({super.key});

  @override
  State<AudioSourcesPage> createState() => _AudioSourcesPageState();
}

class _AudioSourcesPageState extends State<AudioSourcesPage> {
  bool _loading = true;

  /// 正在扫描的音源 ID；null 表示空闲。
  String? _scanningId;

  LocalScanProgress? _scanProgress;
  LocalScanSummary? _lastSummary;
  bool _cancelRequested = false;

  @override
  void initState() {
    super.initState();
    _init();
  }

  Future<void> _init() async {
    await AudioSourceRegistry.instance.ensureLoaded();
    if (!mounted) return;
    setState(() => _loading = false);
  }

  // ── 增删改 ────────────────────────────────────────────────────

  Future<void> _addSource() async {
    final path = await _pickDirectory();
    if (path == null || !mounted) return;

    final name = await _askName(_defaultNameFor(path));
    if (name == null || name.trim().isEmpty || !mounted) return;

    final repo = LocalSourceRepository.instance;
    final config = LocalSourceConfig(
      id: repo.newId(),
      name: name.trim(),
      // 自定义目录扫描走纯 dart:io，三端一致。系统媒体库（photo_manager）
      // 尚未实现，且它不支持 Windows，所以这里一律 false。
      useSystemLibrary: false,
      includePaths: [path],
    );

    await AudioSourceRegistry.instance.addLocal(config);
    if (!mounted) return;
    AppToast.show(context, '已添加「${config.name}」，点它开始扫描');
  }

  Future<void> _editSource(LocalSourceConfig config) async {
    final next = await showModalBottomSheet<LocalSourceConfig>(
      context: context,
      isScrollControlled: true,
      builder: (_) => _LocalSourceEditor(source: config),
    );
    if (next == null) return;

    final repo = LocalSourceRepository.instance;
    await repo.upsert(next);
    await AudioSourceRegistry.instance.refresh();
  }

  Future<void> _removeSource(LocalSourceConfig config) async {
    final ok = await AppDialog.showConfirm(
      context,
      title: '移除「${config.name}」',
      content: '只移除音源配置，已扫描入库的歌曲不会删除。',
      confirmText: '移除',
      isDestructive: true,
    );
    if (ok != true || !mounted) return;

    await AudioSourceRegistry.instance.remove(config.id);
    if (!mounted) return;
    AppToast.show(context, '已移除');
  }

  // ── 扫描 ──────────────────────────────────────────────────────

  /// 扫描前的音频权限保障（普通系统弹窗，无需跳系统设置）。
  ///
  /// Android 13+ 请求 READ_MEDIA_AUDIO，12 及以下请求存储权限。
  /// 拿到后：无「所有文件访问」时扫描自动走 MediaStore 路线（见
  /// MediaStoreScanner）；已授予所有文件访问则走 dart:io 遍历。
  Future<bool> _ensureScanPermission() async {
    if (!Platform.isAndroid) return true;
    final audio = await Permission.audio.request();
    if (audio.isGranted) return true;
    // Android 12 及以下回退到传统存储权限
    final storage = await Permission.storage.request();
    if (storage.isGranted) return true;
    if (mounted) {
      AppToast.show(
        context,
        '需要音频权限才能扫描本地音乐，请允许后重试',
        type: ToastType.error,
      );
    }
    return false;
  }

  Future<void> _scan(LocalSourceConfig config) async {
    if (_scanningId != null) return;

    if (!await _ensureScanPermission()) return;

    if (config.includePaths.isEmpty) {
      AppToast.show(context, '还没选目录', type: ToastType.info);
      return;
    }

    setState(() {
      _scanningId = config.id;
      _scanProgress = null;
      _lastSummary = null;
      _cancelRequested = false;
    });

    try {
      final summary = await LocalSourceProvider().scanSource(
        config,
        isCancelled: () => _cancelRequested,
        onProgress: (p) {
          if (!mounted) return;
          setState(() => _scanProgress = p);
        },
      );
      if (!mounted) return;
      setState(() => _lastSummary = summary);

      // 把本次扫描到的数量记回配置，列表上能直接看到。
      await LocalSourceRepository.instance.upsert(
        config.copyWith(lastScanCount: summary.scanned),
      );
      await AudioSourceRegistry.instance.refresh();
      if (!mounted) return;

      AppToast.show(
        context,
        '扫描完成：共 ${summary.scanned} 首，新增 ${summary.added}',
      );
    } catch (e) {
      if (!mounted) return;
      AppToast.show(context, '扫描失败：$e', type: ToastType.error);
    } finally {
      if (mounted) setState(() => _scanningId = null);
    }
  }

  // ── WebDAV ───────────────────────────────────────────────────

  Future<void> _editWebDav(WebDavSourceConfig? config) async {
    final source = config ??
        WebDavSourceConfig(
          id: WebDavSourceRepository.instance.newId(),
          name: '',
          endpoint: '',
        );
    final next = await showWebDavSourceEditor(context, source);
    if (next == null) return;
    await WebDavSourceRepository.instance.upsert(next);
    await AudioSourceRegistry.instance.refresh();
    if (!mounted) return;
    AppToast.show(context, '已保存「' + next.name + '」，点刷新图标扫描');
  }

  Future<void> _removeWebDav(WebDavSourceConfig config) async {
    final ok = await AppDialog.showConfirm(
      context,
      title: '移除「' + config.name + '」',
      content: '只移除音源配置；已扫描入库的歌曲保留在曲库里，'
          '但将因无法取流而不可播放。重新添加同名源并扫描即可恢复。',
      confirmText: '移除',
      isDestructive: true,
    );
    if (ok != true || !mounted) return;
    await AudioSourceRegistry.instance.remove(config.id);
    if (!mounted) return;
    AppToast.show(context, '已移除');
  }

  /// WebDAV 扫描走**全局会话**：退出页面扫描继续，回到页面进度恢复。
  Future<void> _scanWebDav(WebDavSourceConfig config) async {
    if (WebDavScanSession.instance.isRunning) {
      AppToast.show(context, '已有扫描在跑', type: ToastType.info);
      return;
    }
    if (config.endpoint.trim().isEmpty) {
      AppToast.show(context, '还没填地址', type: ToastType.info);
      return;
    }
    AppToast.show(context, '扫描在后台进行，可以边扫边听');
    await WebDavScanSession.instance.start(config);
  }

  Widget _buildWebDavTile(WebDavSourceConfig source) {
    final isScanning = _scanningId == source.id;
    return AppSettingTile(
      title: source.name,
      subtitle: source.endpoint,
      leading: const Icon(Icons.dns_outlined),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (isScanning)
            const SizedBox(
              width: 18,
              height: 18,
              child: CircularProgressIndicator(strokeWidth: 2),
            )
          else
            IconButton(
              tooltip: '扫描',
              icon: const Icon(Icons.refresh),
              onPressed:
                  _scanningId != null ? null : () => _scanWebDav(source),
            ),
          IconButton(
            tooltip: '编辑',
            icon: const Icon(Icons.edit_outlined),
            onPressed: _scanningId != null ? null : () => _editWebDav(source),
          ),
          IconButton(
            tooltip: '移除',
            icon: const Icon(Icons.delete_outline),
            onPressed:
                _scanningId != null ? null : () => _removeWebDav(source),
          ),
        ],
      ),
      onTap: _scanningId != null ? null : () => _editWebDav(source),
    );
  }

  // ── 辅助 ──────────────────────────────────────────────────────

  Future<String?> _pickDirectory() async {
    try {
      // getDirectoryPath 三端都支持：Android/iOS 走系统目录选择器，
      // Windows/macOS/Linux 走原生文件夹对话框。
      return await FilePicker.platform.getDirectoryPath(
        dialogTitle: '选择音乐文件夹',
      );
    } catch (e) {
      if (mounted) {
        AppToast.show(context, '打开目录选择器失败：$e', type: ToastType.error);
      }
      return null;
    }
  }

  Future<String?> _askName(String initial) {
    final controller = TextEditingController(text: initial);
    return showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('音源名称'),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: const InputDecoration(hintText: '例如：手机音乐'),
          onSubmitted: (v) => Navigator.pop(context, v),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, controller.text),
            child: const Text('确定'),
          ),
        ],
      ),
    );
  }

  /// 用目录名当默认名（`/sdcard/Music/周杰伦` → `周杰伦`）。
  String _defaultNameFor(String path) {
    final t = path.replaceAll('\\', '/');
    final parts = t.split('/').where((e) => e.isNotEmpty).toList();
    if (parts.isEmpty) return '本地音乐';
    final last = parts.last;
    // Windows 盘符（`C:`）不适合当名字。
    if (last.endsWith(':')) return '本地音乐';
    return last;
  }

  // ── UI ────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final bottomPadding = AppPageScaffold.scrollableBottomPadding(
      context,
      showMiniPlayer: false,
    );

    return AppPageScaffold(
      extendBodyBehindAppBar: true,
      appBar: AppTopBar(
        title: '音源管理',
        backgroundColor: Colors.transparent,
        elevation: 0,
        actions: [
          IconButton(
            tooltip: '添加本地音源',
            icon: const Icon(Icons.add),
            onPressed: _scanningId != null ? null : _addSource,
          ),
        ],
      ),
      showMiniPlayer: false,
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : ValueListenableBuilder<List<AudioSourceConfig>>(
              valueListenable: AudioSourceRegistry.instance.sources,
              builder: (context, sources, _) {
                final feiniu = sources
                    .where((s) => s.id == SongEntity.defaultFeiniuSourceId)
                    .toList();
                final local = sources
                    .where((s) => s.kind == AudioSourceKind.local)
                    .cast<LocalSourceConfig>()
                    .toList();
                final webdav = sources
                    .where((s) => s.kind == AudioSourceKind.webdav)
                    .cast<WebDavSourceConfig>()
                    .toList();

                return ListView(
                  padding: EdgeInsets.fromLTRB(16, 12, 16, bottomPadding),
                  children: [
                    AppSettingSection(title: '云端', children: [
                      ...feiniu.map(_buildFeiniuTile),
                    ]),
                    const SizedBox(height: 16),
                    AppSettingSection(
                      title: '本地',
                      children: local.isEmpty
                          ? [
                              const AppSettingTile(
                                title: '还没有本地音源',
                                subtitle: '点右上角 + 选择一个音乐文件夹',
                                leading: Icon(Icons.folder_open_outlined),
                              ),
                            ]
                          : [for (final s in local) _buildLocalTile(s)],
                    ),
                    const SizedBox(height: 16),
                    AppSettingSection(
                      title: 'WebDAV',
                      children: [
                        ...[for (final s in webdav) _buildWebDavTile(s)],
                        AppSettingTile(
                          title: '添加 WebDAV 音源',
                          subtitle: 'NAS / 网盘的 WebDAV 地址，流式播放',
                          leading: const Icon(Icons.dns_outlined),
                          trailing: const Icon(Icons.add),
                          onTap: _scanningId != null
                              ? null
                              : () => _editWebDav(null),
                        ),
                      ],
                    ),
                    ValueListenableBuilder<String?>(
                      valueListenable:
                          WebDavScanSession.instance.runningSourceId,
                      builder: (context, running, _) {
                        if (running == null) return const SizedBox.shrink();
                        return Padding(
                          padding: const EdgeInsets.only(top: 16),
                          child: _buildScanProgress(),
                        );
                      },
                    ),
                    if (_lastSummary != null && _scanningId == null) ...[
                      const SizedBox(height: 16),
                      _buildSummary(),
                    ],
                  ],
                );
              },
            ),
    );
  }

  Widget _buildFeiniuTile(AudioSourceConfig source) {
    return AppSettingTile(
      title: source.name,
      subtitle: '服务器地址与账号在「FN Connect」里配置',
      leading: const Icon(Icons.cloud_outlined),
      trailing: const Icon(Icons.lock_outline, size: 18),
    );
  }

  Widget _buildLocalTile(LocalSourceConfig source) {
    final isScanning = _scanningId == source.id;
    final paths = source.includePaths;
    final subtitle = paths.isEmpty
        ? '未选择目录'
        : paths.length == 1
        ? paths.first
        : '${paths.length} 个目录';

    return AppSettingTile(
      title: source.name,
      subtitle: subtitle,
      leading: const Icon(Icons.folder_outlined),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (isScanning)
            const SizedBox(
              width: 18,
              height: 18,
              child: CircularProgressIndicator(strokeWidth: 2),
            )
          else
            IconButton(
              tooltip: '扫描',
              icon: const Icon(Icons.refresh),
              onPressed: _scanningId != null ? null : () => _scan(source),
            ),
          IconButton(
            tooltip: '编辑',
            icon: const Icon(Icons.edit_outlined),
            onPressed: _scanningId != null ? null : () => _editSource(source),
          ),
          IconButton(
            tooltip: '移除',
            icon: const Icon(Icons.delete_outline),
            onPressed: _scanningId != null ? null : () => _removeSource(source),
          ),
        ],
      ),
      onTap: _scanningId != null ? null : () => _editSource(source),
    );
  }

  Widget _buildScanProgress() {
    return ValueListenableBuilder<String>(
      valueListenable: WebDavScanSession.instance.runningSourceName,
      builder: (context, name, _) {
        return ValueListenableBuilder<WebDavScanProgress?>(
          valueListenable: WebDavScanSession.instance.progress,
          builder: (context, p, __) {
            return AppSettingSection(
              title: '正在扫描「$name」',
              children: [
                AppSettingTile(
                  title: p == null
                      ? '准备中…'
                      : '已处理 ${p.filesProcessed} / ${p.filesFound}',
                  subtitle: '扫描在后台进行，退出本页不会中断',
                  leading: const Icon(Icons.hourglass_top_outlined),
                  trailing: TextButton(
                    onPressed: () => WebDavScanSession.instance.cancel(),
                    child: const Text('取消'),
                  ),
                ),
              ],
            );
          },
        );
      },
    );
  }

  Widget _buildSummary() {
    final s = _lastSummary!;
    return AppSettingSection(
      title: '上次扫描结果',
      children: [
        AppSettingTile(
          title: '共 ${s.scanned} 首',
          subtitle:
              '新增 ${s.added} · 更新 ${s.updated} · 复用 ${s.reused}\n'
              '跳过 ${s.skipped} · 失效 ${s.markedDeleted} · '
              '套用专辑封面 ${s.albumCoverApplied}',
          leading: const Icon(Icons.check_circle_outline),
        ),
      ],
    );
  }
}

/// 本地音源编辑面板：改名、增删目录、调扫描选项。
class _LocalSourceEditor extends StatefulWidget {
  final LocalSourceConfig source;

  const _LocalSourceEditor({required this.source});

  @override
  State<_LocalSourceEditor> createState() => _LocalSourceEditorState();
}

class _LocalSourceEditorState extends State<_LocalSourceEditor> {
  late String _name = widget.source.name;
  late List<String> _paths = [...widget.source.includePaths];
  late bool _readTags = widget.source.readFullTagsOnScan;
  late bool _cacheArtwork = widget.source.cacheArtwork;
  late int _minDurationSec = widget.source.minDurationMs ~/ 1000;

  Future<void> _addPath() async {
    try {
      final path = await FilePicker.platform.getDirectoryPath(
        dialogTitle: '选择音乐文件夹',
      );
      if (path == null || !mounted) return;
      if (_paths.contains(path)) {
        AppToast.show(context, '这个目录已经加过了', type: ToastType.info);
        return;
      }
      setState(() => _paths = [..._paths, path]);
    } catch (e) {
      if (mounted) {
        AppToast.show(context, '打开目录选择器失败：$e', type: ToastType.error);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      // 键盘弹起时把内容顶上去，否则底部按钮被挡住。
      padding: EdgeInsets.only(
        bottom: MediaQuery.of(context).viewInsets.bottom,
      ),
      child: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(20, 16, 20, 20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const Text(
                '编辑本地音源',
                style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600),
              ),
              const SizedBox(height: 16),
              TextField(
                controller: TextEditingController(text: _name)
                  ..selection = TextSelection.collapsed(offset: _name.length),
                decoration: const InputDecoration(labelText: '名称'),
                onChanged: (v) => _name = v,
              ),
              const SizedBox(height: 20),
              Row(
                children: [
                  const Text('目录', style: TextStyle(fontWeight: FontWeight.w600)),
                  const Spacer(),
                  TextButton.icon(
                    onPressed: _addPath,
                    icon: const Icon(Icons.add, size: 18),
                    label: const Text('添加'),
                  ),
                ],
              ),
              if (_paths.isEmpty)
                const Padding(
                  padding: EdgeInsets.symmetric(vertical: 8),
                  child: Text('还没选目录', style: TextStyle(color: Colors.grey)),
                )
              else
                for (final path in _paths)
                  ListTile(
                    dense: true,
                    contentPadding: EdgeInsets.zero,
                    leading: const Icon(Icons.folder_outlined, size: 20),
                    title: Text(
                      path,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    trailing: IconButton(
                      icon: const Icon(Icons.close, size: 18),
                      onPressed: () => setState(
                        () => _paths = _paths.where((e) => e != path).toList(),
                      ),
                    ),
                  ),
              const SizedBox(height: 8),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('读取完整标签'),
                subtitle: const Text('关掉只读时长，扫描快很多但无歌手/专辑/封面'),
                value: _readTags,
                onChanged: (v) => setState(() => _readTags = v),
              ),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('提取内嵌封面'),
                subtitle: const Text('关掉后只靠目录里的 folder.jpg'),
                value: _cacheArtwork,
                onChanged: (v) => setState(() => _cacheArtwork = v),
              ),
              const SizedBox(height: 8),
              Text(
                '最短时长：$_minDurationSec 秒（0 = 不过滤）',
                style: const TextStyle(fontWeight: FontWeight.w600),
              ),
              Slider(
                value: _minDurationSec.toDouble(),
                min: 0,
                max: 120,
                divisions: 24,
                label: '$_minDurationSec 秒',
                onChanged: (v) => setState(() => _minDurationSec = v.round()),
              ),
              const SizedBox(height: 12),
              FilledButton(
                onPressed: () => Navigator.pop(
                  context,
                  widget.source.copyWith(
                    name: _name.trim().isEmpty
                        ? widget.source.name
                        : _name.trim(),
                    includePaths: _paths,
                    readFullTagsOnScan: _readTags,
                    cacheArtwork: _cacheArtwork,
                    minDurationMs: _minDurationSec * 1000,
                  ),
                ),
                child: const Text('保存'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
