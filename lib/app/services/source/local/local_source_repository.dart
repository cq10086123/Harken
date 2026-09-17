import '../prefs_source_repository.dart';
import '../source_config.dart';
import '../source_kind.dart';

/// 本地音源列表仓库。
///
/// 可以有多条（例如「手机内置存储」+「外接 U 盘目录」各一条），彼此独立扫描、
/// 独立启停。
class LocalSourceRepository extends PrefsSourceRepository<LocalSourceConfig> {
  LocalSourceRepository._();

  static final LocalSourceRepository instance = LocalSourceRepository._();

  static const String prefsKeyValue = 'audio_source_local_list';

  @override
  String get prefsKey => prefsKeyValue;

  @override
  String get idPrefix => AudioSourceKind.local.idPrefix;

  @override
  LocalSourceConfig fromJson(Map<String, dynamic> json) {
    // fromJson 返回可空（ID 缺失时丢弃该条），基类要求非空返回，
    // 这里给一个空 ID 占位——基类的 idOf(...).trim().isNotEmpty 过滤会剔掉它。
    return LocalSourceConfig.fromJson(json) ??
        const LocalSourceConfig(id: '', name: '');
  }

  @override
  Map<String, dynamic> toJson(LocalSourceConfig source) => source.toJson();

  @override
  String idOf(LocalSourceConfig source) => source.id;
}
