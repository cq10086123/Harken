import 'package:flutter/material.dart';

import '../../app/router/app_page_route.dart';
import '../../app/services/backup/backup_service.dart';
import '../../components/index.dart';
import 'webdav_folder_picker_page.dart';

/// 数据备份 / 还原：备份本地账号 / 听歌统计 / 应用设置，支持导出到本地
/// JSON 文件或上传到 WebDAV（可选择性还原其中的某个分块）。
class BackupRestorePage extends StatefulWidget {
  const BackupRestorePage({super.key});

  @override
  State<BackupRestorePage> createState() => _BackupRestorePageState();
}

class _BackupRestorePageState extends State<BackupRestorePage> {
  final BackupService _backup = BackupService.instance;

  BackupSections _sections = const BackupSections();
  List<BackupTarget> _targets = const [];
  bool _autoEnabled = false;
  int _keepCount = BackupService.defaultKeepCount;
  bool _loading = true;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final s = await _backup.loadSections();
    final t = await _backup.loadTargets();
    final auto = await _backup.loadAutoEnabled();
    final keep = await _backup.loadKeepCount();
    if (!mounted) return;
    setState(() {
      _sections = s;
      _targets = t;
      _autoEnabled = auto;
      _keepCount = keep;
      _loading = false;
    });
  }

  Future<void> _update(BackupSections s) async {
    setState(() => _sections = s);
    await _backup.saveSections(s);
  }

  Future<void> _run(Future<void> Function() action) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      await action();
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  // ---- actions ----
  Future<void> _exportLocal() => _run(() async {
    if (!_sections.any) {
      AppToast.show(context, '请至少选择一项备份内容');
      return;
    }
    final path = await _backup.exportToFile(_sections);
    if (path == null) return; // 用户取消保存
    if (!mounted) return;
    AppToast.show(context, '备份已导出', type: ToastType.success);
  });

  Future<void> _importLocal() => _run(() async {
    final jsonStr = await _backup.pickBackupFile();
    if (jsonStr == null) return;
    if (!mounted) return;
    final confirmed = await _confirmImport();
    if (confirmed != true) return;
    try {
      final summary = await _backup.restoreFromJson(jsonStr);
      if (!mounted) return;
      _afterImport(summary);
    } catch (e) {
      if (!mounted) return;
      AppToast.show(context, '导入失败：$e', type: ToastType.error);
    }
  });

  Future<void> _exportWebDav() => _run(() async {
    if (!_sections.any) {
      AppToast.show(context, '请至少选择一项备份内容');
      return;
    }
    if (_targets.isEmpty) {
      AppToast.show(context, '请先在下方添加备份目标');
      return;
    }
    final results = await _backup.uploadToAllTargets(_targets, _sections);
    if (!mounted) return;
    final okCount = results.where((r) => r.ok).length;
    final failed = results.where((r) => !r.ok).toList();
    if (failed.isEmpty) {
      AppToast.show(context, '已备份到 $okCount 个目标', type: ToastType.success);
    } else {
      final detail = failed
          .map((r) => '${r.target.name.isNotEmpty ? '${r.target.name}：' : ''}${r.message ?? '失败'}')
          .join('；');
      AppToast.show(
        context,
        '成功 $okCount/${results.length}，失败：$detail',
        type: ToastType.error,
      );
    }
  });

  Future<void> _importWebDav() => _run(() async {
    final target = await _pickTarget('选择要恢复的来源');
    if (target == null) return;
    List<WebDavBackupEntry> entries;
    try {
      entries = await _backup.listWebDavBackups(target);
    } catch (e) {
      if (!mounted) return;
      AppToast.show(context, '读取备份列表失败：$e', type: ToastType.error);
      return;
    }
    if (!mounted) return;
    if (entries.isEmpty) {
      AppToast.show(context, '该目标没有找到备份');
      return;
    }
    final chosen = await _pickBackupEntry(entries);
    if (chosen == null) return;
    String jsonStr;
    try {
      jsonStr = await _backup.downloadFromWebDavPath(target, chosen.path);
    } catch (e) {
      if (!mounted) return;
      AppToast.show(context, '下载失败：$e', type: ToastType.error);
      return;
    }
    if (!mounted) return;
    final confirmed = await _confirmImport();
    if (confirmed != true) return;
    try {
      final summary = await _backup.restoreFromJson(jsonStr);
      if (!mounted) return;
      _afterImport(summary);
    } catch (e) {
      if (!mounted) return;
      AppToast.show(context, '导入失败：$e', type: ToastType.error);
    }
  });

  // ---- backup targets ----
  Future<void> _addTarget() async {
    final result = await Navigator.push<BackupTarget>(
      context,
      buildAppPageRoute<BackupTarget>(
        (_) => const BackupTargetEditPage(),
      ),
    );
    if (result == null || !mounted) return;
    final next = await _backup.addTarget(result);
    if (!mounted) return;
    setState(() => _targets = next);
    AppToast.show(context, '已添加备份目标');
  }

  Future<void> _editTarget(int index) async {
    final result = await Navigator.push<BackupTarget>(
      context,
      buildAppPageRoute<BackupTarget>(
        (_) => BackupTargetEditPage(target: _targets[index]),
      ),
    );
    if (result == null || !mounted) return;
    final next = await _backup.updateTargetAt(index, result);
    if (!mounted) return;
    setState(() => _targets = next);
  }

  Future<void> _removeTarget(int index) async {
    final next = await _backup.removeTargetAt(index);
    if (!mounted) return;
    setState(() => _targets = next);
  }

  Future<void> _toggleAuto(bool v) async {
    if (v && _targets.isEmpty) {
      AppToast.show(context, '请先在下方添加备份目标');
      return;
    }
    await _backup.setAutoEnabled(v);
    if (!mounted) return;
    setState(() => _autoEnabled = v);
  }

  Future<void> _changeKeepCount() async {
    final picked = await showModalBottomSheet<int>(
      context: context,
      backgroundColor: Theme.of(context).colorScheme.surface,
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Padding(
              padding: EdgeInsets.all(16),
              child: Text(
                '保留备份份数',
                style: TextStyle(fontWeight: FontWeight.w700, fontSize: 16),
              ),
            ),
            for (final n in BackupService.keepCountOptions)
              ListTile(
                title: Text('保留最近 $n 份'),
                trailing: _keepCount == n
                    ? const Icon(Icons.check_rounded)
                    : null,
                onTap: () => Navigator.pop(context, n),
              ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
    if (picked == null) return;
    await _backup.setKeepCount(picked);
    if (!mounted) return;
    setState(() => _keepCount = picked);
  }

  Future<BackupTarget?> _pickTarget(String title) async {
    if (_targets.isEmpty) {
      AppToast.show(context, '请先添加备份目标');
      return null;
    }
    if (_targets.length == 1) return _targets.first;
    return showModalBottomSheet<BackupTarget>(
      context: context,
      backgroundColor: Theme.of(context).colorScheme.surface,
      builder: (context) {
        return SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Padding(
                padding: const EdgeInsets.all(16),
                child: Text(
                  title,
                  style: const TextStyle(
                    fontWeight: FontWeight.w700,
                    fontSize: 16,
                  ),
                ),
              ),
              for (final t in _targets)
                ListTile(
                  leading: const Icon(Icons.cloud_outlined),
                  title: Text(t.name.isNotEmpty ? t.name : t.endpoint),
                  subtitle: Text(
                    t.path,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  onTap: () => Navigator.pop(context, t),
                ),
              const SizedBox(height: 8),
            ],
          ),
        );
      },
    );
  }

  Future<WebDavBackupEntry?> _pickBackupEntry(
    List<WebDavBackupEntry> entries,
  ) {
    String fmtTime(DateTime? t) {
      if (t == null) return '未知时间';
      String two(int v) => v.toString().padLeft(2, '0');
      return '${t.year}-${two(t.month)}-${two(t.day)} ${two(t.hour)}:${two(t.minute)}';
    }

    String fmtSize(int b) {
      if (b <= 0) return '';
      if (b < 1024) return ' · $b B';
      if (b < 1024 * 1024) return ' · ${(b / 1024).toStringAsFixed(0)} KB';
      return ' · ${(b / 1024 / 1024).toStringAsFixed(1)} MB';
    }

    return showModalBottomSheet<WebDavBackupEntry>(
      context: context,
      backgroundColor: Theme.of(context).colorScheme.surface,
      isScrollControlled: true,
      builder: (context) {
        return SafeArea(
          child: ConstrainedBox(
            constraints: BoxConstraints(
              maxHeight: MediaQuery.sizeOf(context).height * 0.6,
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Padding(
                  padding: EdgeInsets.all(16),
                  child: Text(
                    '选择要恢复的备份',
                    style: TextStyle(fontWeight: FontWeight.w700, fontSize: 16),
                  ),
                ),
                Flexible(
                  child: ListView.builder(
                    shrinkWrap: true,
                    itemCount: entries.length,
                    itemBuilder: (context, i) {
                      final e = entries[i];
                      return ListTile(
                        leading: Icon(
                          e.isCurrentDevice
                              ? Icons.smartphone_rounded
                              : Icons.devices_other_rounded,
                        ),
                        title: Text(fmtTime(e.modified)),
                        subtitle: Text(
                          '${e.isCurrentDevice ? '本机' : '设备 ${e.deviceId ?? '?'}'}${fmtSize(e.sizeBytes)}',
                        ),
                        onTap: () => Navigator.pop(context, e),
                      );
                    },
                  ),
                ),
                const SizedBox(height: 8),
              ],
            ),
          ),
        );
      },
    );
  }

  void _afterImport(String summary) {
    final needsRestart = _sections.settings;
    AppToast.show(
      context,
      needsRestart ? '$summary（部分设置需重启生效）' : summary,
      type: ToastType.success,
    );
  }

  Future<bool?> _confirmImport() {
    return showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('导入备份'),
        content: const Text('将以「智能合并」方式导入：账号按身份合并、听歌统计累加、设置按需覆盖。是否继续？'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('导入'),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final bottomPadding =
        AppPageScaffold.scrollableBottomPadding(context, showMiniPlayer: false);
    return AppPageScaffold(
      extendBodyBehindAppBar: true,
      appBar: const AppTopBar(
        title: '数据备份',
        backgroundColor: Colors.transparent,
        elevation: 0,
      ),
      showMiniPlayer: false,
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: EdgeInsets.fromLTRB(16, 12, 16, bottomPadding),
              children: [
                AppSettingSection(
                  title: '备份内容',
                  children: [
                    AppSettingSwitchTile(
                      title: '飞牛账号',
                      subtitle: '已保存的服务器账号（含 token，请妥善保管备份文件）',
                      value: _sections.accounts,
                      onChanged: (v) =>
                          _update(_sections.copyWith(accounts: v)),
                    ),
                    AppSettingSwitchTile(
                      title: '听歌统计',
                      subtitle: '播放时长/次数与听歌报告数据',
                      value: _sections.stats,
                      onChanged: (v) => _update(_sections.copyWith(stats: v)),
                    ),
                    AppSettingSwitchTile(
                      title: '应用设置',
                      subtitle: '主题、播放器、偏好设置等（导入后部分需重启生效）',
                      value: _sections.settings,
                      onChanged: (v) =>
                          _update(_sections.copyWith(settings: v)),
                    ),
                  ],
                ),
                const SizedBox(height: 16),
                AppSettingSection(
                  title: '本地',
                  children: [
                    AppSettingTile(
                      title: '导出到本地文件',
                      subtitle: '生成 JSON 备份文件',
                      leading: const Icon(Icons.save_alt_rounded),
                      trailing: _busy
                          ? _spinner()
                          : const Icon(Icons.chevron_right_rounded),
                      onTap: _busy ? null : _exportLocal,
                    ),
                    AppSettingTile(
                      title: '从本地文件导入',
                      subtitle: '选择一个备份 JSON 文件',
                      leading: const Icon(Icons.file_open_rounded),
                      trailing: const Icon(Icons.chevron_right_rounded),
                      onTap: _busy ? null : _importLocal,
                    ),
                  ],
                ),
                const SizedBox(height: 16),
                _buildTargetsSection(),
                const SizedBox(height: 16),
                AppSettingSection(
                  title: 'WebDAV 云端',
                  children: [
                    AppSettingTile(
                      title: '上传到 WebDAV',
                      subtitle: _targets.isEmpty
                          ? '请先在上方添加备份目标'
                          : '一键备份到 ${_targets.length} 个目标',
                      leading: const Icon(Icons.cloud_upload_rounded),
                      trailing: _busy
                          ? _spinner()
                          : const Icon(Icons.chevron_right_rounded),
                      onTap: _busy ? null : _exportWebDav,
                    ),
                    AppSettingTile(
                      title: '从 WebDAV 导入',
                      subtitle: '从某个目标的备份历史中选择一个恢复',
                      leading: const Icon(Icons.cloud_download_rounded),
                      trailing: const Icon(Icons.chevron_right_rounded),
                      onTap: _busy ? null : _importWebDav,
                    ),
                  ],
                ),
                const SizedBox(height: 16),
                AppSettingSection(
                  title: '自动备份',
                  children: [
                    AppSettingSwitchTile(
                      title: '每天打开 App 自动备份',
                      subtitle: '每天首次打开时自动上传到所有备份目标',
                      value: _autoEnabled,
                      onChanged: _toggleAuto,
                    ),
                    AppSettingTile(
                      title: '保留备份份数',
                      subtitle: '每设备最多保留最近 $_keepCount 份，超出自动清理',
                      leading: const Icon(Icons.timer_outlined),
                      trailing: const Icon(Icons.chevron_right_rounded),
                      onTap: _busy ? null : _changeKeepCount,
                    ),
                  ],
                ),
              ],
            ),
    );
  }

  Widget _buildTargetsSection() {
    return AppSettingSection(
      title: '备份目标',
      children: [
        for (var i = 0; i < _targets.length; i++)
          AppSettingTile(
            title: _targets[i].name.isNotEmpty
                ? _targets[i].name
                : _targets[i].endpoint,
            subtitle: _targets[i].path,
            leading: const Icon(Icons.cloud_done_outlined),
            trailing: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                IconButton(
                  icon: const Icon(Icons.edit_outlined),
                  tooltip: '编辑',
                  onPressed: _busy ? null : () => _editTarget(i),
                ),
                IconButton(
                  icon: const Icon(Icons.delete_outline),
                  tooltip: '移除',
                  onPressed: _busy ? null : () => _removeTarget(i),
                ),
              ],
            ),
            onTap: _busy ? null : () => _editTarget(i),
          ),
        AppSettingTile(
          title: '添加备份目标',
          subtitle: '填写 WebDAV 服务器地址、账号与备份目录',
          leading: const Icon(Icons.add_circle_outline),
          trailing: const Icon(Icons.chevron_right_rounded),
          onTap: _busy ? null : _addTarget,
        ),
      ],
    );
  }

  Widget _spinner() => const SizedBox(
    width: 20,
    height: 20,
    child: CircularProgressIndicator(strokeWidth: 2),
  );
}

/// 备份目标编辑页：全页表单（比弹窗更适合 TV 遥控器聚焦与多字段录入）。
///
/// 保存时 `Navigator.pop(context, BackupTarget)` 返回结果；取消返回 null。
class BackupTargetEditPage extends StatefulWidget {
  /// 为 null 时是「添加」，否则为「编辑」。
  final BackupTarget? target;

  const BackupTargetEditPage({super.key, this.target});

  @override
  State<BackupTargetEditPage> createState() => _BackupTargetEditPageState();
}

class _BackupTargetEditPageState extends State<BackupTargetEditPage> {
  final _formKey = GlobalKey<FormState>();

  late final TextEditingController _nameCtrl;
  late final TextEditingController _endpointCtrl;
  late final TextEditingController _userCtrl;
  late final TextEditingController _passCtrl;
  late final TextEditingController _pathCtrl;

  bool _obscurePassword = true;

  @override
  void initState() {
    super.initState();
    final t = widget.target;
    _nameCtrl = TextEditingController(text: t?.name ?? '');
    _endpointCtrl = TextEditingController(text: t?.endpoint ?? '');
    _userCtrl = TextEditingController(text: t?.username ?? '');
    _passCtrl = TextEditingController(text: t?.password ?? '');
    _pathCtrl =
        TextEditingController(text: t?.path ?? BackupService.defaultBasePath);
  }

  @override
  void dispose() {
    _nameCtrl.dispose();
    _endpointCtrl.dispose();
    _userCtrl.dispose();
    _passCtrl.dispose();
    _pathCtrl.dispose();
    super.dispose();
  }

  void _save() {
    if (!_formKey.currentState!.validate()) return;
    final endpoint = _endpointCtrl.text.trim();
    Navigator.pop(
      context,
      BackupTarget(
        id: widget.target?.id ?? '',
        name: _nameCtrl.text.trim(),
        endpoint: endpoint,
        username: _userCtrl.text.trim(),
        password: _passCtrl.text,
        path: _pathCtrl.text.trim().isEmpty
            ? BackupService.defaultBasePath
            : _pathCtrl.text.trim(),
      ),
    );
  }

  Widget _field({
    required TextEditingController controller,
    required String label,
    String? hint,
    IconData? icon,
    bool autofocus = false,
    bool isPassword = false,
    Widget? suffix,
    TextInputType? keyboardType,
    String? Function(String?)? validator,
  }) {
    return TextFormField(
      controller: controller,
      autofocus: autofocus,
      obscureText: isPassword && _obscurePassword,
      keyboardType: keyboardType,
      decoration: InputDecoration(
        labelText: label,
        hintText: hint,
        prefixIcon: icon == null ? null : Icon(icon),
        suffixIcon: isPassword
            ? IconButton(
                icon: Icon(
                  _obscurePassword
                      ? Icons.visibility_off_outlined
                      : Icons.visibility_outlined,
                ),
                onPressed: () =>
                    setState(() => _obscurePassword = !_obscurePassword),
              )
            : suffix,
        border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
      ),
      validator: validator,
      onFieldSubmitted: (_) => _save(),
    );
  }

  /// 打开 WebDAV 文件夹选择器，用当前填写的服务器信息连接并浏览目录。
  /// 选中后回填到「备份目录」输入框。
  Future<void> _browsePath() async {
    final endpoint = _endpointCtrl.text.trim();
    if (endpoint.isEmpty) {
      AppToast.show(context, '请先填写 WebDAV 地址');
      return;
    }
    final target = BackupTarget(
      id: widget.target?.id ?? '',
      name: _nameCtrl.text.trim(),
      endpoint: endpoint,
      username: _userCtrl.text.trim(),
      password: _passCtrl.text,
      path: _pathCtrl.text.trim().isEmpty
          ? BackupService.defaultBasePath
          : _pathCtrl.text.trim(),
    );
    final result = await Navigator.push<String>(
      context,
      buildAppPageRoute<String>(
        (_) => WebDavFolderPickerPage(
          target: target,
          initialPath: _pathCtrl.text.trim().isEmpty
              ? BackupService.defaultBasePath
              : _pathCtrl.text.trim(),
        ),
      ),
    );
    if (result == null || !mounted) return;
    setState(() => _pathCtrl.text = result);
  }

  @override
  Widget build(BuildContext context) {
    final bottomPadding =
        AppPageScaffold.scrollableBottomPadding(context, showMiniPlayer: false);
    return AppPageScaffold(
      extendBodyBehindAppBar: true,
      appBar: AppTopBar(
        title: widget.target == null ? '添加备份目标' : '编辑备份目标',
        backgroundColor: Colors.transparent,
        elevation: 0,
      ),
      showMiniPlayer: false,
      body: Form(
        key: _formKey,
        child: ListView(
          padding: EdgeInsets.fromLTRB(16, 12, 16, bottomPadding),
          children: [
            _field(
              controller: _nameCtrl,
              label: '名称（可选）',
              hint: '例如：我的 NAS',
              icon: Icons.badge_outlined,
            ),
            const SizedBox(height: 16),
            _field(
              controller: _endpointCtrl,
              label: 'WebDAV 地址',
              hint: 'https://example.com/dav',
              icon: Icons.link_outlined,
              autofocus: true,
              keyboardType: TextInputType.url,
              validator: (v) => (v == null || v.trim().isEmpty)
                  ? '请输入 WebDAV 地址'
                  : null,
            ),
            const SizedBox(height: 16),
            _field(
              controller: _userCtrl,
              label: '用户名',
              icon: Icons.person_outline,
            ),
            const SizedBox(height: 16),
            _field(
              controller: _passCtrl,
              label: '密码',
              icon: Icons.lock_outline,
              isPassword: true,
            ),
            const SizedBox(height: 16),
            _field(
              controller: _pathCtrl,
              label: '备份目录',
              hint: '/（留空则备份到根目录）',
              icon: Icons.folder_outlined,
              suffix: IconButton(
                icon: const Icon(Icons.folder_open_outlined),
                tooltip: '浏览服务器目录',
                onPressed: _browsePath,
              ),
            ),
            const SizedBox(height: 8),
            // 说明：实际备份会自动拼接到所选目录下的 HarkenBackup 子目录
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 4),
              child: Text(
                '备份文件会自动保存到所选目录下的 ${BackupService.webDavFolder} 文件夹',
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                    ),
              ),
            ),
            const SizedBox(height: 24),
            FilledButton.icon(
              onPressed: _save,
              icon: const Icon(Icons.check_rounded),
              label: const Text('保存'),
              style: FilledButton.styleFrom(
                padding: const EdgeInsets.symmetric(vertical: 14),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
