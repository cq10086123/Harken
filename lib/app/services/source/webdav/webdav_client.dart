import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:dio/io.dart';
import 'package:flutter/foundation.dart';
import 'package:xml/xml.dart';

/// WebDAV 服务器上的一个资源（文件或目录）。
class WebDavResource {
  /// 服务器上的解码绝对路径，恒以 `/` 开头（目录以 `/` 结尾）。
  final String path;

  final bool isDirectory;

  /// 字节数；目录或服务器未返回时为 null。
  final int? size;

  /// 最后修改时间；服务器未返回或无法解析时为 null。
  final DateTime? modified;

  const WebDavResource({
    required this.path,
    required this.isDirectory,
    this.size,
    this.modified,
  });

  /// 文件名（路径最后一段；目录名不带尾斜杠）。
  String get name {
    var p = path;
    while (p.endsWith('/')) {
      p = p.substring(0, p.length - 1);
    }
    final idx = p.lastIndexOf('/');
    return idx < 0 ? p : p.substring(idx + 1);
  }
}

/// WebDAV 客户端：PROPFIND 列目录 + 拉流 URL 构造 + 连接测试。
///
/// 多地址容灾：[endpoints] 按「主地址 → 备用地址」排序，首个对根目录
/// PROPFIND 应答成功的被记住（`_activeEndpoint`），后续请求全部走它。
/// 连接在 App 运行期内通常稳定，不做逐请求轮换。
class WebDavClient {
  /// 规范化后的候选地址（`WebDavSourceConfig.allEndpoints`）。
  final List<String> endpoints;

  final String username;
  final String password;
  final bool ignoreSsl;

  Dio? _dio;
  String? _activeEndpoint;

  WebDavClient({
    required this.endpoints,
    required this.username,
    required this.password,
    this.ignoreSsl = false,
  });

  Map<String, String> get authHeaders => webdavAuthHeaders(username, password);

  Dio _client() {
    if (_dio != null) return _dio!;
    final dio = Dio(
      BaseOptions(
        connectTimeout: const Duration(seconds: 8),
        receiveTimeout: const Duration(seconds: 30),
        // PROPFIND 返回 207 Multi-Status：Dio 默认 validateStatus(<500) 已放行。
        responseType: ResponseType.plain,
        validateStatus: (code) => code != null && code < 500,
      ),
    );
    if (ignoreSsl) {
      // 自签证书的内网 NAS 常见配置。dio 5 的适配器回调：给每个底层
      // HttpClient 装上「信任一切」的回调。仅在本开关打开时生效。
      dio.httpClientAdapter = IOHttpClientAdapter(
        createHttpClient: () {
          final client = HttpClient();
          client.badCertificateCallback = (cert, host, port) => true;
          return client;
        },
      );
    }
    _dio = dio;
    return dio;
  }

  /// 逐个候选地址发 PROPFIND（Depth: 0）直到成功，记住可用地址。
  /// 全部失败时抛最后一个异常。
  Future<String> resolveActiveEndpoint() async {
    if (_activeEndpoint != null) return _activeEndpoint!;
    Object? lastError;
    for (final ep in endpoints) {
      try {
        final res = await propfindFollowed(ep, '/', depth: '0');
        if (res.statusCode == 207) {
          _activeEndpoint = ep;
          debugPrint('[WebDavClient] 活动地址: $ep');
          return ep;
        }
        lastError = StateError('HTTP ${res.statusCode}（不是 WebDAV 服务）');
        debugPrint('[WebDavClient] 地址不可用 $ep: HTTP ${res.statusCode}');
      } catch (e) {
        lastError = e;
        debugPrint('[WebDavClient] 地址不可用 $ep: $e');
      }
    }
    throw lastError ?? StateError('无可用 WebDAV 地址');
  }

  /// PROPFIND 并手动跟随 3xx 重定向（保留 PROPFIND 方法与 Depth 头）。
  ///
  /// Dart 的 HttpClient 只对 GET/HEAD 自动跟重定向；PROPFIND 遇 302 会被
  /// 原样返回。fnOS 等服务端在根路径做 302 跳转时，必须自己跟。
  Future<Response<dynamic>> propfindFollowed(
    String endpoint,
    String dirPath, {
    required String depth,
  }) async {
    var url = endpoint + encodedPath(dirPath);
    for (var hop = 0; hop < 5; hop++) {
      final res = await _client().fetch(
        RequestOptions(
          method: 'PROPFIND',
          path: url,
          headers: {...authHeaders, 'Depth': depth},
          responseType: ResponseType.plain,
          // 关掉 Dio 的自动跟随：我们自己跟（保留方法与头）。
          followRedirects: false,
          validateStatus: (code) => code != null && code < 500,
        ),
      );
      final status = res.statusCode ?? 0;
      if (status < 300 || status >= 400) return res;
      final location = res.headers.value('location');
      if (location == null || location.isEmpty) {
        throw StateError('重定向缺少 Location 头（HTTP $status）');
      }
      // Location 可能是相对路径或完整 URL，统一解析成下一个绝对 URL。
      final next = Uri.parse(url).resolve(location);
      url = next.toString();
      debugPrint('[WebDavClient] 跟随重定向 → $url');
    }
    throw StateError('重定向超过 5 层，已中止');
  }

  /// 列出一个目录（Depth: 1，含目录自身）。
  ///
  /// 返回值**不含** [dirPath] 自身。
  Future<List<WebDavResource>> list(String dirPath) async {
    final ep = await resolveActiveEndpoint();
    List<WebDavResource> all;
    try {
      final res = await propfindFollowed(ep, dirPath, depth: '1');
      if (res.statusCode != 207) {
        final status = res.statusCode;
        if (status == 401) {
          throw StateError('鉴权失败（401）——检查账号密码');
        }
        throw StateError('PROPFIND $dirPath 失败：HTTP $status');
      }
      all = _parseListResponse(res, dirPath);
    } on StateError {
      // 某些服务器对无尾斜杠的集合路径返回空 multistatus：补上斜杠重试
      // 一次；仍然空/解析失败则把错误抛给上层（扫描失败区可见）。
      if (dirPath.endsWith('/')) rethrow;
      final res2 = await propfindFollowed(ep, dirPath + '/', depth: '1');
      if (res2.statusCode != 207) {
        rethrow;
      }
      all = _parseListResponse(res2, dirPath);
    }
    final self = normalizeDirPath(dirPath);
    return all.where((r) => normalizeDirPath(r.path) != self).toList();
  }

  /// 解析 PROPFIND 响应体。**解析失败或空响应必须显式抛错**——曾经静默
  /// 返回空列表，扫描「完成 0 首」却没有任何线索（真机踩坑）。
  List<WebDavResource> _parseListResponse(
    Response<dynamic> res,
    String dirPath,
  ) {
    final status = res.statusCode;
    final data = res.data;
    String body;
    if (data is String) {
      body = data;
    } else if (data is List<int>) {
      body = utf8.decode(data, allowMalformed: true);
    } else {
      throw StateError(
          'PROPFIND $dirPath 响应类型异常：HTTP $status，data=${data.runtimeType}');
    }
    if (body.trim().isEmpty) {
      throw StateError(
          'PROPFIND $dirPath 返回空响应体（HTTP $status）');
    }
    List<WebDavResource> parsed;
    try {
      parsed = parsePropfind(body);
    } catch (e) {
      throw StateError(
          'PROPFIND $dirPath 响应解析失败：$e；body 开头: '
          '${body.substring(0, body.length > 150 ? 150 : body.length)}');
    }
    final self = normalizeDirPath(dirPath);
    final children =
        parsed.where((r) => normalizeDirPath(r.path) != self).toList();
    if (children.isEmpty) {
      // 只含自身 = 服务器按 Depth 0 处理了请求；绝不能静默当「空目录」。
      final preview = body.length > 200 ? body.substring(0, 200) : body;
      debugPrint('[WebDavClient] list($dirPath) 解析为 0 子项；'
          'body ${body.length} 字符，开头: $preview');
      throw StateError(
          'PROPFIND $dirPath 返回 0 子项（HTTP $status，'
          '${body.length} 字符）——服务器可能未按 Depth 1 处理');
    }
    return children;
  }

  /// 连接测试：返回 (服务器根目录下的条目数)。
  Future<int> testConnection() async {
    final items = await list('/');
    return items.length;
  }

  /// 文件/目录的完整拉流 URL。
  ///
  /// 路径逐段编码：文件名里的空格、中文、`#`、`?` 都必须转义，整段
  /// `Uri.parse` 会把 `#` 后面当 fragment 吃掉（真实曲库里 `C#` 专辑很常见）。
  String fileUrl(String path) {
    final ep = _activeEndpoint ?? endpoints.first;
    return ep + encodedPath(path);
  }

  /// 下载一个文件到本地（标签探测用）。
  Future<void> downloadTo(String serverPath, File target) async {
    final ep = await resolveActiveEndpoint();
    await _client().download(
      ep + encodedPath(serverPath),
      target.path,
      options: Options(headers: authHeaders),
    );
  }

  /// 关闭底层连接（扫描完成后调用；播放期间复用不关）。
  void close() {
    _dio?.close();
    _dio = null;
  }
}


/// 路径编码：逐段 `Uri.encodeComponent`，保留 `/` 分隔符。
String encodedPath(String path) {
  final segments = path.split('/');
  return segments
      .map((s) => s.isEmpty ? '' : Uri.encodeComponent(s))
      .join('/');
}

/// Basic Auth 请求头。匿名（账号密码都空）时不发 Authorization。
Map<String, String> webdavAuthHeaders(String username, String password) {
  if (username.trim().isEmpty && password.isEmpty) return const {};
  final raw = base64Encode(utf8.encode('$username:$password'));
  return {'Authorization': 'Basic $raw'};
}

/// 归一目录路径：恒以 `/` 开头、不以 `/` 结尾（根目录为空串）。
String normalizeDirPath(String raw) {
  var p = raw.trim();
  if (p.isEmpty) return '';
  if (!p.startsWith('/')) p = '/$p';
  while (p.length > 1 && p.endsWith('/')) {
    p = p.substring(0, p.length - 1);
  }
  return p == '/' ? '' : p;
}

/// 解析 PROPFIND multistatus XML。
///
/// **纯函数、不碰网络**——WebDAV 服务器的命名空间前缀五花八门（`D:`、`d:`、
/// 无前缀默认命名空间），因此按 localName 匹配而不是全名。
List<WebDavResource> parsePropfind(String body) {
  final results = <WebDavResource>[];
  final doc = XmlDocument.parse(body);
  // 找出所有 localName == 'response' 的元素（multistatus 的直接/间接子级）。
  final responses = doc.descendantElements
      .where((e) => e.name.local == 'response')
      .toList();
  for (final r in responses) {
    final hrefEl = _childByLocalName(r, 'href');
    if (hrefEl == null) continue;
    final href = hrefEl.innerText.trim();
    if (href.isEmpty) continue;

    var path = _hrefToPath(href);
    if (path.isEmpty) continue;

    final prop = _descendantByLocalName(r, 'prop');
    final isDir = prop != null &&
        _descendantByLocalName(prop, 'collection') != null;

    int? size;
    if (!isDir && prop != null) {
      final sizeEl = _descendantByLocalName(prop, 'getcontentlength');
      size = int.tryParse(sizeEl?.innerText.trim() ?? '');
    }
    DateTime? modified;
    if (prop != null) {
      modified = _parseHttpDate(
        _descendantByLocalName(prop, 'getlastmodified')?.innerText.trim(),
      );
    }

    // 统一目录以 '/' 结尾、文件不以 '/' 结尾。
    if (isDir && !path.endsWith('/')) path = '$path/';
    if (!isDir && path.endsWith('/')) path = path.substring(0, path.length - 1);

    results.add(WebDavResource(
      path: path,
      isDirectory: isDir,
      size: size,
      modified: modified,
    ));
  }
  return results;
}

/// href → 解码后的服务器路径（恒以 `/` 开头）。
/// 服务器可能返回完整 URL（`https://host/dav/a.mp3`）或纯路径（`/dav/a.mp3`）。
String _hrefToPath(String href) {
  var raw = href.trim();
  if (raw.startsWith('http://') || raw.startsWith('https://')) {
    final uri = Uri.tryParse(raw);
    if (uri == null) return '';
    raw = uri.path;
  }
  if (raw.isEmpty) return '';
  final decoded = Uri.tryParse(raw)?.toString() ?? raw;
  // href 里的路径段是 URL 编码过的（%20 等），逐段解码。
  final segments = decoded
      .split('/')
      .map(Uri.decodeComponent)
      .toList();
  var path = segments.join('/');
  if (!path.startsWith('/')) path = '/$path';
  return path;
}

XmlElement? _childByLocalName(XmlElement parent, String local) {
  for (final child in parent.childElements) {
    if (child.name.local == local) return child;
  }
  return null;
}

XmlElement? _descendantByLocalName(XmlElement parent, String local) {
  for (final e in parent.descendantElements) {
    if (e.name.local == local) return e;
  }
  return null;
}

DateTime? _parseHttpDate(String? raw) {
  if (raw == null || raw.isEmpty) return null;
  try {
    // RFC 1123：'Tue, 01 Jul 2026 08:00:00 GMT'
    final format = DateFormatRfc1123();
    return format.parse(raw);
  } catch (_) {
    return null;
  }
}

/// 极简 RFC 1123 日期解析（避免引入 intl）。
class DateFormatRfc1123 {
  static const _months = {
    'Jan': 1, 'Feb': 2, 'Mar': 3, 'Apr': 4, 'May': 5, 'Jun': 6,
    'Jul': 7, 'Aug': 8, 'Sep': 9, 'Oct': 10, 'Nov': 11, 'Dec': 12,
  };

  DateTime? parse(String raw) {
    // 'Tue, 01 Jul 2026 08:00:00 GMT' → 按空格/冒号拆
    final m = RegExp(
      r'(\d{1,2}) (\w{3}) (\d{4}) (\d{2}):(\d{2}):(\d{2})',
    ).firstMatch(raw);
    if (m == null) return null;
    final month = _months[m.group(2)];
    if (month == null) return null;
    // 分组：1=日 2=月名 3=年 4=时 5=分 6=秒
    return DateTime.utc(
      int.parse(m.group(3)!),
      month,
      int.parse(m.group(1)!),
      int.parse(m.group(4)!),
      int.parse(m.group(5)!),
      int.parse(m.group(6)!),
    );
  }
}
