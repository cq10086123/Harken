import 'package:flutter/foundation.dart';

import '../../state/song_state.dart';
import '../db/dao/song_dao.dart';
import '../feiniu/favorite_service.dart';
import 'song_stream_dispatch.dart';

/// 收藏双轨路由 —— 通用分流模式的第一条能力线。
///
/// 按 [streamKindFor] 的取源归属分派，调用方（歌曲详情、收藏页等）
/// 只认这个入口，**不写 `if (song.isLocal)`**：
///
/// - 飞牛歌 → 服务端收藏 API（按 guid）；
/// - 本地歌 → 本地 `songs.isFavorite` 列（建表即有，[SongEntity.isFavorite]）。
///
/// 后续歌单（serverPlaylists cap）、歌词、转码等能力照此模式各建一条
/// 路由线；WebDAV 等新音源落地时在对应路由里加分支，调用方无需改动。
class FavoriteRouter {
  const FavoriteRouter._();

  static const FavoriteRouter instance = FavoriteRouter._();

  /// 收藏变更广播：任何一次收藏写入成功后自增。
  ///
  /// 为什么会需要它：收藏状态散落在多个界面（播放页红心、歌曲信息面板、
  /// 通知栏图标……），而它们各自只在**打开或切歌时读一次**。在 A 处收藏后，
  /// B 处的红心不会知道，就一直停在灰色。所有关心收藏的界面监听这里，
  /// 收到变化后重读状态即可（见 [isFavorite]）。
  static final ValueNotifier<int> revision = ValueNotifier<int>(0);

  /// 查询收藏状态。
  ///
  /// 本地歌**以数据库为准**：入参 [song] 常常是列表/队列构建时的快照，
  /// 收藏后没人回写它，照着它渲染会让红心永远点不亮（历史 bug）。
  Future<bool> isFavorite(SongEntity song) async {
    if (isFeiniuRemoteSong(song)) {
      return FeiNiuFavoriteService.instance.isFavorite(song.id);
    }
    final fresh = await SongDao.instance.favoriteStateOf(song.id);
    return fresh ?? song.isFavorite;
  }

  /// 设置收藏状态。写入成功后广播一次（见 [revision]）。
  Future<void> setFavorite(SongEntity song, bool favorite) async {
    if (isFeiniuRemoteSong(song)) {
      if (favorite) {
        await FeiNiuFavoriteService.instance.favorite(song.id);
      } else {
        await FeiNiuFavoriteService.instance.unfavorite(song.id);
      }
      revision.value++;
      return;
    }
    await SongDao.instance.setFavorite(song.id, favorite);
    revision.value++;
  }

  /// 按 id 批量设置收藏（多选场景）。返回**失败条数**，0 表示全部成功。
  ///
  /// 调用方只拿到 id（拿不到 SongEntity），所以先在本地库按 id 反查：
  /// 命中的是本地歌 → 写数据库；其余视为飞牛歌 → 走服务端批量接口。
  /// 这样混选（本地 + 云端）也能各自落到正确的轨道上。
  Future<int> setFavoriteByIds(List<String> ids, bool favorite) async {
    if (ids.isEmpty) return 0;
    try {
      final local = await SongDao.instance.fetchByIds(ids);
      // WebDAV 歌的收藏也写本地列（服务端没有它们），所以这里按
      // 「非飞牛」分流，而不是按 isLocal。
      final localIds = local
          .where((s) => !isFeiniuRemoteSong(s))
          .map((s) => s.id)
          .toSet();
      for (final id in localIds) {
        await SongDao.instance.setFavorite(id, favorite);
      }
      final remoteIds =
          ids.where((id) => !localIds.contains(id)).toList();
      if (remoteIds.isEmpty) {
        revision.value++;
        return 0;
      }
      final failed = favorite
          ? await FeiNiuFavoriteService.instance.favoriteAll(remoteIds)
          : await FeiNiuFavoriteService.instance
                .unfavoriteAll(remoteIds);
      revision.value++;
      return failed;
    } catch (e) {
      debugPrint('[FavoriteRouter] 批量收藏失败: $e');
      return ids.length;
    }
  }
}
