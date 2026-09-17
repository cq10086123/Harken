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

  /// 查询收藏状态。
  Future<bool> isFavorite(SongEntity song) {
    if (isFeiniuRemoteSong(song)) {
      return FeiNiuFavoriteService.instance.isFavorite(song.id);
    }
    return Future.value(song.isFavorite);
  }

  /// 设置收藏状态。
  Future<void> setFavorite(SongEntity song, bool favorite) async {
    if (isFeiniuRemoteSong(song)) {
      if (favorite) {
        await FeiNiuFavoriteService.instance.favorite(song.id);
      } else {
        await FeiNiuFavoriteService.instance.unfavorite(song.id);
      }
      return;
    }
    await SongDao.instance.setFavorite(song.id, favorite);
  }
}
