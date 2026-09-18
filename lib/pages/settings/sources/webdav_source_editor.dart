import 'package:flutter/material.dart';

import '../../../app/services/source/source_config.dart';
import '../../../app/services/source/webdav/webdav_client.dart';
import '../../../app/services/source/webdav/webdav_scanner.dart';
import '../../../components/index.dart';

/// WebDAV 音源编辑面板：**先连接，后选目录**。
///
/// 第一步：填地址与凭据 → 「测试连接」（逐个候选地址试活，含跟随重定向）。
/// 第二步：连接成功后出现目录浏览器，逐层点进 NAS 的目录树，选一层作为
/// 音乐根目录（扫描会递归它的全部子目录）。
class WebDavSourceEditor extends StatefulWidget {
  final WebDavSourceConfig source;

  const WebDavSourceEditor({super.key, required this.source});

  @override
  State<WebDavSourceEditor> createState() => _WebDavSourceEditorState();
}

class _WebDavSourceEditorState extends State<WebDavSourceEditor> {
  late final TextEditingController _name;
  late final TextEditingController _endpoint;
  late final TextEditingController _altEndpoints;
  late final TextEditingController _username;
  late final TextEditingController _password;
  late bool _ignoreSsl;
  late bool _scrapeTags;
  late String _selectedPath;

  WebDavClient? _client;
  bool _testing = false;
  String? _testError;

  // 目录浏览器状态
  bool _browsing = false;
  bool _loadingDir = false;
  String _currentDir = '/';
  List<WebDavResource> _currentChildren = const [];

  bool get _connected => _browsing;

  @override
  void initState() {
    super.initState();
    _name = TextEditingController(text: widget.source.name);
    _endpoint = TextEditingController(text: widget.source.endpoint);
    _altEndpoints =
        TextEditingController(text: widget.source.altEndpoints.join('\n'));
    _username = TextEditingController(text: widget.source.username);
    _password = TextEditingController(text: widget.source.password);
    _ignoreSsl = widget.source.ignoreSsl;
    _scrapeTags = widget.source.scrapeTagsOnScan;
    _selectedPath = widget.source.path;
    // 连接态必须由「测试连接」建立——缓存的活动地址只在 client 实例内，
    // 不能凭已有配置假定连通。
    _browsing = false;
  }

  @override
  void dispose() {
    _client?.close();
    _name.dispose();
    _endpoint.dispose();
    _altEndpoints.dispose();
    _username.dispose();
    _password.dispose();
    super.dispose();
  }

  WebDavSourceConfig? _buildConfig() {
    final endpoint = _endpoint.text.trim();
    if (endpoint.isEmpty) return null;
    final alt = _altEndpoints.text
        .split(RegExp(r'[\n,]'))
        .map((e) => e.trim())
        .where((e) => e.isNotEmpty)
        .toList();
    return widget.source.copyWith(
      name: _name.text.trim().isEmpty ? 'WebDAV 音源' : _name.text.trim(),
      endpoint: endpoint,
      altEndpoints: alt,
      username: _username.text.trim(),
      password: _password.text,
      path: _selectedPath,
      ignoreSsl: _ignoreSsl,
      scrapeTagsOnScan: _scrapeTags,
    );
  }

  WebDavClient _makeClient() {
    _client?.close();
    _client = WebDavClient(
      endpoints: _candidates(),
      username: _username.text.trim(),
      password: _password.text,
      ignoreSsl: _ignoreSsl,
    );
    return _client!;
  }

  /// 候选地址：与 `WebDavSourceConfig.allEndpoints` 同规则（无 scheme 时
  /// https 与 http 都试）。
  List<String> _candidates() {
    final c = _buildConfig();
    return c?.allEndpoints ?? const [];
  }

  Future<void> _test() async {
    if (_endpoint.text.trim().isEmpty) {
      setState(() => _testError = '请先填写主地址');
      return;
    }
    setState(() {
      _testing = true;
      _testError = null;
      _browsing = false;
      _currentChildren = const [];
    });
    try {
      final client = _makeClient();
      await client.resolveActiveEndpoint();
      final root = await client.list('/');
      if (!mounted) return;
      setState(() {
        _browsing = true;
        _currentDir = '/';
        _selectedPath = '/';
        _currentChildren = root;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _testError = '连接失败：$e');
    } finally {
      if (mounted) setState(() => _testing = false);
    }
  }

  Future<void> _enterDir(WebDavResource dir) async {
    final client = _client;
    if (client == null) return;
    final target = normalizeDirPath(dir.path);
    setState(() => _loadingDir = true);
    try {
      final children = await client.list(target);
      if (!mounted) return;
      setState(() {
        _currentDir = target;
        _selectedPath = target;
        _currentChildren = children;
        _loadingDir = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _loadingDir = false);
      AppToast.show(context, '进入目录失败：$e', type: ToastType.error);
    }
  }

  Future<void> _goUp() async {
    if (_currentDir == '/') return;
    final parent = _currentDir.contains('/')
        ? _currentDir.substring(0, _currentDir.lastIndexOf('/'))
        : '';
    final client = _client;
    if (client == null) return;
    final target = parent.isEmpty ? '/' : parent;
    setState(() => _loadingDir = true);
    try {
      final children = await client.list(target);
      if (!mounted) return;
      setState(() {
        _currentDir = target;
        _selectedPath = target;
        _currentChildren = children;
        _loadingDir = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _loadingDir = false);
      AppToast.show(context, '返回上级失败：$e', type: ToastType.error);
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
                'WebDAV 音源',
                style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600),
              ),
              const SizedBox(height: 16),
              TextField(
                controller: _name,
                decoration: const InputDecoration(labelText: '名称'),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _endpoint,
                keyboardType: TextInputType.url,
                decoration: const InputDecoration(
                  labelText: '主地址（含端口）',
                  hintText: 'http://192.168.100.105:5005',
                ),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _altEndpoints,
                keyboardType: TextInputType.multiline,
                maxLines: 2,
                decoration: const InputDecoration(
                  labelText: '备用地址（每行一个，可选）',
                  hintText: '家里内网 / 外出隧道各一条',
                ),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _username,
                decoration: const InputDecoration(labelText: '账号（匿名留空）'),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _password,
                obscureText: true,
                decoration: const InputDecoration(labelText: '密码'),
              ),
              SwitchListTile(
                dense: true,
                contentPadding: EdgeInsets.zero,
                title: const Text('忽略 TLS 证书校验'),
                subtitle: const Text('自签证书的内网 NAS 勾选'),
                value: _ignoreSsl,
                onChanged: (v) => setState(() => _ignoreSsl = v),
              ),
              if (_testError != null)
                Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: Text(
                    _testError!,
                    style: const TextStyle(color: Colors.red),
                  ),
                ),
              OutlinedButton.icon(
                onPressed: _testing ? null : _test,
                icon: _testing
                    ? const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : Icon(_connected ? Icons.check_circle : Icons.wifi_tethering,
                        size: 18,
                        color: _connected ? Colors.green : null),
                label: Text(_connected
                    ? '已连接（重新测试）'
                    : _testing
                        ? '正在连接…'
                        : '测试连接'),
              ),
              if (_connected) ...[
                const SizedBox(height: 12),
                _buildBrowser(),
                SwitchListTile(
                  dense: true,
                  contentPadding: EdgeInsets.zero,
                  title: const Text('扫描时读取完整标签'),
                  subtitle: const Text('标题/歌手/专辑/时长更准，但每首要下载一次，较慢'),
                  value: _scrapeTags,
                  onChanged: (v) => setState(() => _scrapeTags = v),
                ),
                FilledButton(
                  onPressed: () {
                    final config = _buildConfig();
                    if (config == null) {
                      AppToast.show(context, '请先填写主地址',
                          type: ToastType.error);
                      return;
                    }
                    Navigator.of(context).pop(config);
                  },
                  child: Text(_selectedPath == '/'
                      ? '保存（扫描整台服务器）'
                      : '保存（只扫 $_selectedPath）'),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  /// 第二步：目录浏览器。选一层作为音乐根目录。
  Widget _buildBrowser() {
    final dirs = _currentChildren.where((r) => r.isDirectory).toList()
      ..sort((a, b) => a.name.compareTo(b.name));
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          '将扫描：${_currentDir == '/' ? '/（整台服务器）' : _currentDir}',
          style: const TextStyle(fontWeight: FontWeight.w600),
        ),
        const Text(
          '浏览到哪一层就扫哪一层（含全部子目录）。点进目标书籍/歌手'
          '文件夹后直接保存即可。',
          style: TextStyle(color: Colors.grey, fontSize: 12),
        ),
        const SizedBox(height: 4),
        Row(
          children: [
            TextButton.icon(
              onPressed: _loadingDir || _currentDir == '/' ? null : _goUp,
              icon: const Icon(Icons.arrow_upward, size: 18),
              label: const Text('上一级'),
            ),
          ],
        ),
        Container(
          constraints: const BoxConstraints(maxHeight: 260),
          decoration: BoxDecoration(
            border: Border.all(color: Colors.grey.withValues(alpha: 0.3)),
            borderRadius: BorderRadius.circular(8),
          ),
          child: _loadingDir
              ? const Center(
                  child: Padding(
                    padding: EdgeInsets.all(16),
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                )
              : dirs.isEmpty
                  ? const Padding(
                      padding: EdgeInsets.all(16),
                      child: Text('这层没有子目录了',
                          style: TextStyle(color: Colors.grey)),
                    )
                  : ListView(
                      shrinkWrap: true,
                      children: [
                        for (final d in dirs)
                          ListTile(
                            dense: true,
                            leading: const Icon(Icons.folder, size: 20),
                            title: Text(d.name),
                            trailing:
                                const Icon(Icons.chevron_right, size: 18),
                            onTap: () => _enterDir(d),
                          ),
                      ],
                    ),
        ),
        if (_selectedPath.isNotEmpty && _selectedPath != '/')
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Text(
              '已选音乐根目录：$_selectedPath',
              style: const TextStyle(color: Colors.green, fontSize: 12),
            ),
          ),
      ],
    );
  }
}

/// 供音源管理页打开编辑器。
Future<WebDavSourceConfig?> showWebDavSourceEditor(
  BuildContext context,
  WebDavSourceConfig source,
) {
  return showModalBottomSheet<WebDavSourceConfig>(
    context: context,
    isScrollControlled: true,
    builder: (_) => WebDavSourceEditor(source: source),
  );
}
