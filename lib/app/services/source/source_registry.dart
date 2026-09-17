import 'package:flutter/foundation.dart';

import '../../state/song_state.dart';
import 'local/local_source_repository.dart';
import 'source_config.dart';
import 'source_kind.dart';
import 'webdav/webdav_source_repository.dart';

/// 音源注册表 —— 外部访问音源配置的**唯一门面**。
///
/// 页面与 `PlayerService` 只依赖这里，不直接碰各音源的仓库。这样做有两个目的：
/// - 增删一种音源类型时，改动集中在本文件与各 provider，页面不动；
/// - 「飞牛默认音源」这种隐式条目只在这里合成一次，其余代码不必知道它的存在。
///
/// 飞牛音源比较特殊：它的凭据由 `AppFnConnectionSettings` 管理（FNID 探测），
/// 不在本注册表里存第二份。且本产品为**单账号模式**，飞牛恒为一条**隐式**
/// 配置（ID 固定为 [SongEntity.defaultFeiniuSourceId]），不可增删；
/// 其登录态由 `AuthService.isLoggedIn` 决定，注册表不重复持久化。
class AudioSourceRegistry {
  AudioSourceRegistry._();

  static final AudioSourceRegistry instance = AudioSourceRegistry._();

  /// 全部音源（含隐式飞牛条目），按 [AudioSourceConfig.enabled] 过滤前的完整列表。
  final ValueNotifier<List<AudioSourceConfig>> sources =
      ValueNotifier(const []);

  Future<void>? _loading;

  Future<void> ensureLoaded() => _loading ??= _doLoad();

  Future<void> _doLoad() async {
    await refresh();
  }

  /// 重新从持久化读取并刷新 [sources]。增删改后调用。
  Future<void> refresh() async {
    final local = await LocalSourceRepository.instance.loadSources();
    final webdav = await WebDavSourceRepository.instance.loadSources();
    sources.value = [
      _implicitFeiniuSource(),
      ...local,
      ...webdav,
    ];
  }

  /// 隐式飞牛音源条目。
  ///
  /// ID 固定为 `feiniu-default`，与存量数据的 `sourceId IS NULL` 归位值一致
  /// （见 `SongEntity.effectiveSourceId`），因此老库无需回填即可正确分派。
  ///
  /// 登录态由 `AuthService.isLoggedIn` 表达，这里恒 `enabled: true`——
  /// 未登录时该音源的 provider 自然取不到数据，不需要在配置层再表达一次。
  FeiniuSourceConfig _implicitFeiniuSource() {
    return const FeiniuSourceConfig(
      id: SongEntity.defaultFeiniuSourceId,
      name: '飞牛音乐',
    );
  }

  /// 当前启用的音源。
  List<AudioSourceConfig> get enabledSources =>
      sources.value.where((s) => s.enabled).toList();

  /// 按 ID 取配置；未知 ID 归位到飞牛默认音源。
  ///
  /// 归位而不是返回 null：存量数据 `sourceId` 为 NULL，`effectiveSourceId`
  /// 已经把它映射成 `feiniu-default`，这里再兜一层，保证任何历史 ID 都能
  /// 拿到一个可用配置，播放分派不会因为找不到配置而静默失败。
  AudioSourceConfig configFor(String sourceId) {
    for (final s in sources.value) {
      if (s.id == sourceId) return s;
    }
    return _implicitFeiniuSource();
  }

  /// 按 ID 取音源类型；未知 ID 视为飞牛。
  AudioSourceKind kindFor(String sourceId) => configFor(sourceId).kind;

  /// 某个 ID 是否属于当前启用的音源。
  bool isEnabled(String sourceId) => configFor(sourceId).enabled;

  // ---- 增删改（飞牛隐式条目不可增删） ----

  Future<void> addLocal(LocalSourceConfig config) async {
    await LocalSourceRepository.instance.upsert(config);
    await refresh();
  }

  Future<void> addWebDav(WebDavSourceConfig config) async {
    await WebDavSourceRepository.instance.upsert(config);
    await refresh();
  }

  Future<void> setEnabled(String id, bool enabled) async {
    if (id == SongEntity.defaultFeiniuSourceId) return;
    final local = await LocalSourceRepository.instance.findById(id);
    if (local != null) {
      await LocalSourceRepository.instance.upsert(
        local.copyWith(enabled: enabled),
      );
      await refresh();
      return;
    }
    final webdav = await WebDavSourceRepository.instance.findById(id);
    if (webdav != null) {
      await WebDavSourceRepository.instance.upsert(
        webdav.copyWith(enabled: enabled),
      );
      await refresh();
    }
  }

  /// 删除音源配置。
  ///
  /// ⚠️ 只删配置，**不删已入库的歌曲行** —— 删库是不可逆操作，交给
  /// `SourceDeletionService`（后续阶段）在用户明确确认后单独执行。
  Future<void> remove(String id) async {
    if (id == SongEntity.defaultFeiniuSourceId) return;
    await LocalSourceRepository.instance.removeById(id);
    await WebDavSourceRepository.instance.removeById(id);
    await refresh();
  }

  /// 丢弃缓存并重新加载。仅供测试使用（理由同 `PrefsSourceRepository.resetCacheForTest`）。
  Future<void> resetForTest() async {
    LocalSourceRepository.instance.resetCacheForTest();
    WebDavSourceRepository.instance.resetCacheForTest();
    _loading = null;
    sources.value = const [];
  }
}
