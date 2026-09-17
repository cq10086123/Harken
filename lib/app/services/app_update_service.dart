import 'package:dio/dio.dart';
import 'package:package_info_plus/package_info_plus.dart';

class AppUpdateInfo {
  final String latestVersion;
  final String? releaseName;
  final String? releaseUrl;
  final String? releaseNotes;
  final bool hasUpdate;

  const AppUpdateInfo({
    required this.latestVersion,
    required this.hasUpdate,
    this.releaseName,
    this.releaseUrl,
    this.releaseNotes,
  });
}

class AppUpdateService {
  AppUpdateService._();

  static final AppUpdateService instance = AppUpdateService._();

  static const String releasePageUrl =
      'https://github.com/cq10086123/Harken/releases/latest';
  static const String latestReleaseApiUrl =
      'https://api.github.com/repos/cq10086123/Harken/releases/latest';

  final Dio _dio = Dio(
    BaseOptions(
      connectTimeout: const Duration(seconds: 8),
      receiveTimeout: const Duration(seconds: 8),
    ),
  );

  String? _cachedVersion;

  /// The running app's clean release version (e.g. "1.3.1"), read from the
  /// platform. The build number is intentionally omitted — it's only a
  /// maintenance counter and shouldn't appear in the displayed version or
  /// affect update comparison.
  Future<String> currentVersion() async {
    final cached = _cachedVersion;
    if (cached != null) return cached;
    try {
      final info = await PackageInfo.fromPlatform();
      final v = info.version.trim();
      _cachedVersion = v.isEmpty ? '0.0.0' : v;
      return _cachedVersion!;
    } catch (_) {
      return _cachedVersion ?? '0.0.0';
    }
  }

  Future<AppUpdateInfo> checkLatest(String currentVersion) async {
    try {
      final response = await _dio.get(
        latestReleaseApiUrl,
        options: Options(
          headers: {
            'Accept': 'application/vnd.github.v3+json',
            'User-Agent': 'Harken',
          },
        ),
      );
      final data = response.data as Map<String, dynamic>?;
      if (data == null) {
        return AppUpdateInfo(latestVersion: currentVersion, hasUpdate: false);
      }

      final tagName = (data['tag_name'] as String? ?? '').trim();
      final latestName = tagName.startsWith('v') || tagName.startsWith('V')
          ? tagName.substring(1)
          : tagName;
      final releaseName = data['name'] as String?;
      final body = data['body'] as String?;
      final htmlUrl = data['html_url'] as String?;

      final hasUpdate = _compareVersions(latestName, currentVersion) > 0;
      return AppUpdateInfo(
        latestVersion: latestName,
        hasUpdate: hasUpdate,
        releaseName: releaseName,
        releaseUrl: htmlUrl ?? releasePageUrl,
        releaseNotes: body,
      );
    } catch (e) {
      return AppUpdateInfo(latestVersion: currentVersion, hasUpdate: false);
    }
  }

  String _normalizeVersion(String version) {
    final value = version.trim();
    if (value.startsWith('v') || value.startsWith('V')) {
      return value.substring(1);
    }
    return value;
  }

  int _compareVersions(String a, String b) {
    // Compare only the release part (major.minor.patch); ignore any build or
    // prerelease suffix so maintenance builds (e.g. 1.3.1-2 vs 1.3.1) don't
    // register as a new version.
    List<int> release(String v) {
      var s = _normalizeVersion(v);
      final cut = s.indexOf(RegExp(r'[+\-]'));
      if (cut >= 0) s = s.substring(0, cut);
      return s.split('.').map((e) => int.tryParse(e.trim()) ?? 0).toList();
    }

    final left = release(a);
    final right = release(b);
    final length = left.length > right.length ? left.length : right.length;
    for (var i = 0; i < length; i++) {
      final l = i < left.length ? left[i] : 0;
      final r = i < right.length ? right[i] : 0;
      if (l != r) return l.compareTo(r);
    }
    return 0;
  }
}
