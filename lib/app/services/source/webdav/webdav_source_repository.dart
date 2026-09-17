import '../prefs_source_repository.dart';
import '../source_config.dart';
import '../source_kind.dart';

/// WebDAV 音源列表仓库。
///
/// 可以有多条（家里 NAS + 公司 NAS 各一条）。凭据当前与备份目标
/// （`BackupTarget`）一致明文存放，后续应迁移到系统安全存储
/// （见《音源多源化重构可行性评估》第十一节决策点 6）。
class WebDavSourceRepository extends PrefsSourceRepository<WebDavSourceConfig> {
  WebDavSourceRepository._();

  static final WebDavSourceRepository instance = WebDavSourceRepository._();

  static const String prefsKeyValue = 'audio_source_webdav_list';

  @override
  String get prefsKey => prefsKeyValue;

  @override
  String get idPrefix => AudioSourceKind.webdav.idPrefix;

  @override
  WebDavSourceConfig fromJson(Map<String, dynamic> json) {
    // 同 LocalSourceRepository：ID/endpoint 缺失时返回空 ID 占位，
    // 由基类的 idOf(...).trim().isNotEmpty 过滤剔除。
    return WebDavSourceConfig.fromJson(json) ??
        const WebDavSourceConfig(id: '', name: '', endpoint: '');
  }

  @override
  Map<String, dynamic> toJson(WebDavSourceConfig source) => source.toJson();

  @override
  String idOf(WebDavSourceConfig source) => source.id;
}
