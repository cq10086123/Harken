import '../db/dao/playlist_dao.dart';
import '../db/dao/song_dao.dart';
import '../feiniu/playlist_service.dart';

/// 通用分流的歌单引用（不区分服务端/本地）。
class PlaylistRef {
  final String id;
  final String name;

  /// 本地歌单（PlaylistDao 管理）；false = 飞牛服务端歌单。
  final bool isLocal;

  const PlaylistRef({
    required this.id,
    required this.name,
    this.isLocal = false,
  });
}

/// 歌单双轨路由 —— 通用分流模式的第二条能力线（第一条见 FavoriteRouter）。
///
/// 按**歌单归属**分派：
/// - 飞牛歌单 → 服务端 API（只能收飞牛歌，本地歌会被跳过）；
/// - 本地歌单 → `playlists` / `playlist_songs` 表（本地歌和飞牛歌都能收，
///   飞牛歌一并 upsert 进 songs 表保证可播）。
///
/// 入参统一用歌曲 id 列表：路由内部经 SongDao 解析实体判断归属，
/// 调用方不需要 SongEntity。WebDAV 等新音源落地时在此加分支。
class PlaylistRouter {
  const PlaylistRouter._();

  static const PlaylistRouter instance = PlaylistRouter._();

  /// 选择歌单时的完整列表：本地歌单在前（离线也可见），飞牛歌单在后
  /// （未连接/失败时静默为空，不阻塞弹层）。
  Future<List<PlaylistRef>> playlistsForPick() async {
    final result = <PlaylistRef>[];
    try {
      final locals = await PlaylistDao.instance.listLocalPlaylists();
      for (final row in locals) {
        result.add(PlaylistRef(
          id: row['id'] as String,
          name: row['name'] as String,
          isLocal: true,
        ));
      }
    } catch (_) {}
    try {
      final server = await FeiNiuPlaylistService.instance
          .getPlaylistList(page: 1, size: 500);
      for (final p in server) {
        result.add(PlaylistRef(id: p.guid, name: p.name));
      }
    } catch (_) {}
    return result;
  }

  /// 添加歌曲到已有歌单。飞牛歌单收不了本地歌（本地歌自动跳过）；
  /// 本地歌单照单全收。返回 false 表示一首都加不进去（全是本地歌 +
  /// 选了飞牛歌单），调用方据此提示。
  Future<bool> addIds(PlaylistRef playlist, List<String> ids) async {
    if (playlist.isLocal) {
      final entities = await SongDao.instance.fetchByIds(ids);
      await PlaylistDao.instance.addSongsToLocal(playlist.id, entities);
      return entities.isNotEmpty;
    }
    final entityById = await _entityById(ids);
    final remoteIds =
        ids.where((id) => !(entityById[id]?.isLocal ?? false)).toList();
    if (remoteIds.isEmpty) return false;
    await FeiNiuPlaylistService.instance.addTracks(playlist.id, remoteIds);
    return true;
  }

  /// 创建歌单并添加。选中歌里**含本地歌**时建本地歌单（服务端歌单收不了），
  /// 纯飞牛歌时保持原有服务端歌单行为。
  Future<PlaylistRef> createAndAdd(String name, List<String> ids) async {
    final entityById = await _entityById(ids);
    final hasLocal = ids.any((id) => entityById[id]?.isLocal ?? false);
    if (hasLocal) {
      final id = await PlaylistDao.instance.createLocalPlaylist(name);
      final entities = await SongDao.instance.fetchByIds(ids);
      await PlaylistDao.instance.addSongsToLocal(id, entities);
      return PlaylistRef(id: id, name: name, isLocal: true);
    }
    final created = await FeiNiuPlaylistService.instance.createPlaylist(name);
    await FeiNiuPlaylistService.instance.addTracks(created.guid, ids);
    return PlaylistRef(id: created.guid, name: created.name);
  }

  Future<Map<String, dynamic>> _entityById(List<String> ids) async {
    final entities = await SongDao.instance.fetchByIds(ids);
    return {for (final s in entities) s.id: s};
  }
}
