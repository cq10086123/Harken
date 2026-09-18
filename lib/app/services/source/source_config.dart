import 'source_kind.dart';
import 'webdav/webdav_scanner.dart';

/// 一个音源实例的持久化配置。
///
/// 三种音源各自携带不同参数，用 sealed 层次表达（与 `player_engine.dart` 的
/// `sealed class EngineItem` 同一风格），消费方可用穷尽 switch，漏分支编译期报错。
///
/// 所有子类都要能无损往返 JSON —— 存 `SharedPreferences` 的一个 JSON 数组里
/// （见 `PrefsSourceRepository`）。
sealed class AudioSourceConfig {
  /// 稳定 ID，形如 `<kind>-<时间戳>`。`SongEntity.sourceId` 指向它。
  final String id;

  /// 用户起的名字，如「客厅 NAS」。
  final String name;

  /// 是否启用。停用的音源不参与库查询与播放分派，但配置保留。
  final bool enabled;

  const AudioSourceConfig({
    required this.id,
    required this.name,
    this.enabled = true,
  });

  AudioSourceKind get kind;

  Map<String, dynamic> toJson();

  /// 从 JSON 还原；`kind` 未知或必填字段缺失时返回 null（静默丢弃该条）。
  static AudioSourceConfig? fromJson(Map<String, dynamic> json) {
    final kind = audioSourceKindFromName(json['kind'] as String?);
    if (kind == null) return null;
    return switch (kind) {
      AudioSourceKind.feiniu => FeiniuSourceConfig.fromJson(json),
      AudioSourceKind.local => LocalSourceConfig.fromJson(json),
      AudioSourceKind.webdav => WebDavSourceConfig.fromJson(json),
    };
  }
}

/// 飞牛音源配置。
///
/// 连接凭据（token / baseUrl / 安全码 / FNID）**不在这里** —— 它们已由
/// `FeiNiuApiClient` + `AppFnConnectionSettings` 管理，保持原样以免破坏
/// FNID 探测逻辑。
///
/// 本产品为**单账号模式**，因此飞牛音源恒为一条隐式条目
/// （ID = `SongEntity.defaultFeiniuSourceId`），不携带账号维度、不可增删。
/// 仓库里既有的 `AccountStore` 多账号机制属于历史遗留，与本模块无关，
/// 后续单独清理（见评估文档第十一节决策点 4）。
class FeiniuSourceConfig extends AudioSourceConfig {
  const FeiniuSourceConfig({
    required super.id,
    required super.name,
    super.enabled,
  });

  @override
  AudioSourceKind get kind => AudioSourceKind.feiniu;

  @override
  Map<String, dynamic> toJson() => {
    'kind': kind.name,
    'id': id,
    'name': name,
    'enabled': enabled,
  };

  static FeiniuSourceConfig? fromJson(Map<String, dynamic> json) {
    final id = json['id'] as String?;
    if (id == null || id.trim().isEmpty) return null;
    return FeiniuSourceConfig(
      id: id,
      name: (json['name'] as String?)?.trim().isNotEmpty == true
          ? json['name'] as String
          : AudioSourceKind.feiniu.title,
      enabled: json['enabled'] != false,
    );
  }

  FeiniuSourceConfig copyWith({
    String? id,
    String? name,
    bool? enabled,
  }) {
    return FeiniuSourceConfig(
      id: id ?? this.id,
      name: name ?? this.name,
      enabled: enabled ?? this.enabled,
    );
  }
}

/// 本地音源配置。
///
/// 两条互不排斥的取材路径（对齐上游 `LocalSourceSettings`）：
/// - [useSystemLibrary] + [includeAlbumIds]：走系统媒体库
///   （Android MediaStore / iOS 媒体库，`photo_manager` 实现，零额外权限）；
/// - [includePaths]：直接递归任意目录（`dart:io`，桌面端主力路径）。
///
/// ⚠️ `photo_manager` 不支持 Windows/Linux，因此桌面端必须
/// `useSystemLibrary = false` 且只依赖 [includePaths]。
class LocalSourceConfig extends AudioSourceConfig {
  /// 是否扫描系统媒体库。桌面端恒为 false。
  final bool useSystemLibrary;

  /// 只收录时长不小于该值的文件（毫秒），过滤提示音/铃声。0 表示不过滤。
  final int minDurationMs;

  /// 选中的媒体库专辑 ID（空 = 全部）。仅 [useSystemLibrary] 为 true 时有意义。
  final List<String> includeAlbumIds;

  /// 额外递归扫描的目录绝对路径。
  final List<String> includePaths;

  /// 扫描时把内嵌封面落盘到应用缓存（`localCoverPath`）。
  final bool cacheArtwork;

  /// 扫描时读取完整标签（较慢但元数据全）。关闭则只取文件名与时长。
  final bool readFullTagsOnScan;

  /// 上次扫描入库的歌曲数，供设置页展示。
  final int lastScanCount;

  const LocalSourceConfig({
    required super.id,
    required super.name,
    super.enabled,
    this.useSystemLibrary = true,
    this.minDurationMs = 0,
    this.includeAlbumIds = const [],
    this.includePaths = const [],
    this.cacheArtwork = true,
    this.readFullTagsOnScan = true,
    this.lastScanCount = 0,
  });

  @override
  AudioSourceKind get kind => AudioSourceKind.local;

  @override
  Map<String, dynamic> toJson() => {
    'kind': kind.name,
    'id': id,
    'name': name,
    'enabled': enabled,
    'useSystemLibrary': useSystemLibrary,
    'minDurationMs': minDurationMs,
    'includeAlbumIds': includeAlbumIds,
    'includePaths': includePaths,
    'cacheArtwork': cacheArtwork,
    'readFullTagsOnScan': readFullTagsOnScan,
    'lastScanCount': lastScanCount,
  };

  static LocalSourceConfig? fromJson(Map<String, dynamic> json) {
    final id = json['id'] as String?;
    if (id == null || id.trim().isEmpty) return null;
    return LocalSourceConfig(
      id: id,
      name: (json['name'] as String?)?.trim().isNotEmpty == true
          ? json['name'] as String
          : AudioSourceKind.local.title,
      enabled: json['enabled'] != false,
      useSystemLibrary: json['useSystemLibrary'] != false,
      minDurationMs: (json['minDurationMs'] as num?)?.toInt() ?? 0,
      includeAlbumIds: _stringList(json['includeAlbumIds']),
      includePaths: _stringList(json['includePaths']),
      cacheArtwork: json['cacheArtwork'] != false,
      readFullTagsOnScan: json['readFullTagsOnScan'] != false,
      lastScanCount: (json['lastScanCount'] as num?)?.toInt() ?? 0,
    );
  }

  LocalSourceConfig copyWith({
    String? id,
    String? name,
    bool? enabled,
    bool? useSystemLibrary,
    int? minDurationMs,
    List<String>? includeAlbumIds,
    List<String>? includePaths,
    bool? cacheArtwork,
    bool? readFullTagsOnScan,
    int? lastScanCount,
  }) {
    return LocalSourceConfig(
      id: id ?? this.id,
      name: name ?? this.name,
      enabled: enabled ?? this.enabled,
      useSystemLibrary: useSystemLibrary ?? this.useSystemLibrary,
      minDurationMs: minDurationMs ?? this.minDurationMs,
      includeAlbumIds: includeAlbumIds ?? this.includeAlbumIds,
      includePaths: includePaths ?? this.includePaths,
      cacheArtwork: cacheArtwork ?? this.cacheArtwork,
      readFullTagsOnScan: readFullTagsOnScan ?? this.readFullTagsOnScan,
      lastScanCount: lastScanCount ?? this.lastScanCount,
    );
  }
}

/// WebDAV 音源配置。
///
/// [endpoint] 是主地址，[altEndpoints] 是同一台服务器的备用地址（家里内网 /
/// 外出隧道）。扫描与播放先试主地址，再按序试备用，命中的会被缓存
/// （见后续的 `WebDavEndpointResolver`）。
class WebDavSourceConfig extends AudioSourceConfig
    implements WebDavSourceConfigLike {
  final String endpoint;
  final List<String> altEndpoints;
  final String username;
  final String password;

  /// 音乐根目录（服务器上的绝对路径）。
  final String path;

  /// 只扫描这些子目录（空 = 全部）。
  final List<String> includeFolders;

  /// 跳过这些子目录。
  final List<String> excludeFolders;

  /// 扫描时读取完整标签。关闭则只用文件名与 PROPFIND 返回的元信息。
  final bool scrapeTagsOnScan;

  /// 忽略 TLS 证书校验（自签证书的内网 NAS 常用）。
  final bool ignoreSsl;

  const WebDavSourceConfig({
    required super.id,
    required super.name,
    super.enabled,
    required this.endpoint,
    this.altEndpoints = const [],
    this.username = '',
    this.password = '',
    this.path = '/',
    this.includeFolders = const [],
    this.excludeFolders = const [],
    this.scrapeTagsOnScan = true,
    this.ignoreSsl = false,
  });

  @override
  AudioSourceKind get kind => AudioSourceKind.webdav;

  /// 主地址 + 备用地址，规范化并去重后的列表。
  ///
  /// 在这里规范化而不是在每个调用点做，是为了让漏写 scheme 的手输地址
  /// （`nas.lan/dav`）也能得到 Dio 打得开的 URL，同时让这些字符串可以安全
  /// 用作 map 键（连接测试结果正是以它们为键）。
  List<String> get allEndpoints {
    final seen = <String>{};
    final result = <String>[];
    for (final raw in [endpoint, ...altEndpoints]) {
      final trimmed = raw.trim();
      // 用户没写 scheme 时，除默认 https 外再补一个 http 候选：
      // 内网 NAS 的 WebDAV（如 fnOS :5005）大多是明文 http，裸 IP
      // 会先试 https（握手失败）再试 http，无需用户回头改地址。
      if (!trimmed.startsWith('http://') && !trimmed.startsWith('https://') && trimmed.isNotEmpty) {
        final http = normalizeWebDavEndpoint('http://$trimmed');
        final https = normalizeWebDavEndpoint(trimmed);
        if (https.isNotEmpty && seen.add(https)) result.add(https);
        if (http.isNotEmpty && seen.add(http)) result.add(http);
        continue;
      }
      final t = normalizeWebDavEndpoint(trimmed);
      if (t.isEmpty) continue;
      if (seen.add(t)) result.add(t);
    }
    return result;
  }

  @override
  Map<String, dynamic> toJson() => {
    'kind': kind.name,
    'id': id,
    'name': name,
    'enabled': enabled,
    'endpoint': endpoint,
    'altEndpoints': altEndpoints,
    'username': username,
    'password': password,
    'path': path,
    'includeFolders': includeFolders,
    'excludeFolders': excludeFolders,
    'scrapeTagsOnScan': scrapeTagsOnScan,
    'ignoreSsl': ignoreSsl,
  };

  static WebDavSourceConfig? fromJson(Map<String, dynamic> json) {
    final id = json['id'] as String?;
    final endpoint = json['endpoint'] as String?;
    if (id == null || id.trim().isEmpty) return null;
    if (endpoint == null || endpoint.trim().isEmpty) return null;
    return WebDavSourceConfig(
      id: id,
      name: (json['name'] as String?)?.trim().isNotEmpty == true
          ? json['name'] as String
          : AudioSourceKind.webdav.title,
      enabled: json['enabled'] != false,
      endpoint: endpoint,
      altEndpoints: _stringList(json['altEndpoints']),
      username: json['username'] as String? ?? '',
      password: json['password'] as String? ?? '',
      path: (json['path'] as String?)?.trim().isNotEmpty == true
          ? json['path'] as String
          : '/',
      includeFolders: _stringList(json['includeFolders']),
      excludeFolders: _stringList(json['excludeFolders']),
      scrapeTagsOnScan: json['scrapeTagsOnScan'] != false,
      ignoreSsl: json['ignoreSsl'] == true,
    );
  }

  WebDavSourceConfig copyWith({
    String? id,
    String? name,
    bool? enabled,
    String? endpoint,
    List<String>? altEndpoints,
    String? username,
    String? password,
    String? path,
    List<String>? includeFolders,
    List<String>? excludeFolders,
    bool? scrapeTagsOnScan,
    bool? ignoreSsl,
  }) {
    return WebDavSourceConfig(
      id: id ?? this.id,
      name: name ?? this.name,
      enabled: enabled ?? this.enabled,
      endpoint: endpoint ?? this.endpoint,
      altEndpoints: altEndpoints ?? this.altEndpoints,
      username: username ?? this.username,
      password: password ?? this.password,
      path: path ?? this.path,
      includeFolders: includeFolders ?? this.includeFolders,
      excludeFolders: excludeFolders ?? this.excludeFolders,
      scrapeTagsOnScan: scrapeTagsOnScan ?? this.scrapeTagsOnScan,
      ignoreSsl: ignoreSsl ?? this.ignoreSsl,
    );
  }
}

/// 把用户输入的地址规范化为 `scheme://host[:port][/path]`（无结尾斜杠）。
///
/// - 缺 scheme 时补 `https`（WebDAV over TLS 是默认预期）；
/// - 去掉结尾斜杠，使 `https://a/dav` 与 `https://a/dav/` 归一为同一个键；
/// - 无法解析时返回去空白后的原串，交由调用方在连接测试时报错。
String normalizeWebDavEndpoint(String raw) {
  var t = raw.trim();
  if (t.isEmpty) return '';
  if (!t.startsWith('http://') && !t.startsWith('https://')) {
    t = 'https://$t';
  }
  final uri = Uri.tryParse(t);
  if (uri == null || uri.host.isEmpty) return t;
  var path = uri.path;
  // 根路径（'/'）也要剥：'https://nas.lan/' 应归一为 'https://nas.lan'。
  while (path.isNotEmpty && path.endsWith('/')) {
    path = path.substring(0, path.length - 1);
  }
  // Dart 的 Uri 没有 isDefaultPort，手写默认端口判断（http:80 / https:443）
  final isDefaultPort = uri.port == 0 ||
      (uri.scheme == 'https' && uri.port == 443) ||
      (uri.scheme == 'http' && uri.port == 80);
  final port = uri.hasPort && !isDefaultPort ? ':${uri.port}' : '';
  return '${uri.scheme}://${uri.host}$port$path';
}

List<String> _stringList(dynamic raw) {
  if (raw is! List) return const [];
  return raw
      .map((e) => e?.toString() ?? '')
      .where((e) => e.trim().isNotEmpty)
      .toList();
}
