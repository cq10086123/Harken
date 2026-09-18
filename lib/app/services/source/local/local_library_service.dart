import 'package:flutter/foundation.dart';

import '../../../state/song_state.dart';
import '../../db/dao/song_dao.dart';
import '../../db/db_constants.dart';
import '../../db/db_helper.dart';

/// 本地音源曲库的统一读取入口。
///
/// 为什么需要它：本地歌与在线歌是**两个数据源**——列表页原先只读服务器分页数据，
/// 于是「扫描成功、歌也入库了，但页面里看不到」。各页面统一经这里取本地数据，
/// 聚合规则（专辑名回退链、最近播放排序）**只此一处**实现，避免各页各写一套，
/// 再次出现「这个页面接了、那个页面没接」。
///
/// 硬性约定：**任何异常都必须留下日志**。历史教训是本地数据的读取写成
/// `catch (_) { return const []; }`，出问题时页面安安静静地空白，只能靠猜。
class LocalLibraryService {
  LocalLibraryService._();

  static final LocalLibraryService instance = LocalLibraryService._();

  /// 库内容版本号：WebDAV 扫描每批入库后自增。
  ///
  /// 列表页监听它做**节流刷新**（扫描中途也能看到歌陆续出现），
  /// 而不必等整次扫描结束。
  static final ValueNotifier<int> revision = ValueNotifier(0);

  /// 本地 + WebDAV 歌曲（未标记删除），按标题排序。
  ///
  /// 两者同住 songs 表、同走「DB 读取」链路，页面无需区分；
  /// WebDAV 歌的播放走各自的 Basic Auth 远端链路，与展示无关。
  Future<List<SongEntity>> songs() async {
    try {
      final local = await SongDao.instance.fetchLocalSongs();
      final webdav = await SongDao.instance.fetchWebDavSongs();
      debugPrint('[LocalLibrary] 本地歌曲 ${local.length} 首、'
          'WebDAV 歌曲 ${webdav.length} 首');
      return [...local, ...webdav];
    } catch (e, st) {
      debugPrint('[LocalLibrary] 读取本地歌曲失败: $e\n$st');
      return const [];
    }
  }

  /// 本地收藏的歌曲。
  Future<List<SongEntity>> favorites() async {
    try {
      final list = await SongDao.instance.fetchFavoriteLocalSongs();
      debugPrint('[LocalLibrary] 本地收藏 ${list.length} 首');
      return list;
    } catch (e, st) {
      debugPrint('[LocalLibrary] 读取本地收藏失败: $e\n$st');
      return const [];
    }
  }

  /// 本地歌曲按专辑聚合：`专辑名 → 歌曲列表`。
  ///
  /// 专辑名回退链：内嵌专辑标签（[SongEntity.albumName]）→ 所在文件夹名 →
  /// 「未知专辑」。扫描器已保证专辑字段至少有文件夹名，这里再兜一层。
  Future<Map<String, List<SongEntity>>> byAlbum() async {
    final list = await songs();
    final grouped = <String, List<SongEntity>>{};
    for (final song in list) {
      final name = albumNameOf(song);
      (grouped[name] ??= <SongEntity>[]).add(song);
    }
    debugPrint('[LocalLibrary] 本地专辑 ${grouped.length} 张 (${grouped.keys.join(", ")})');
    return grouped;
  }

  /// 本地最近播放（按最后播放时间倒序）。
  ///
  /// 直接查 `song_stats.lastPlayedMs`——本地播放同样会写统计表，所以这个列表
  /// 天然只包含真正播放过的本地歌，无需额外记录。
  Future<List<SongEntity>> recentlyPlayed({int limit = 100}) async {
    try {
      final db = await DbHelper.instance.database;
      final rows = await db.rawQuery(
        'SELECT s.* FROM ${DbConstants.tableSongStats} st '
        'JOIN ${DbConstants.tableSongs} s ON s.id = st.songId '
        "WHERE (s.isLocal = 1 OR s.sourceId LIKE 'webdav-%') "
        'AND COALESCE(s.isAudioFileDeleted, 0) = 0 '
        'ORDER BY st.lastPlayedMs DESC LIMIT ?',
        [limit],
      );
      final list = rows.map(SongEntity.fromMap).toList();
      debugPrint('[LocalLibrary] 本地最近播放 ${list.length} 首');
      return list;
    } catch (e, st) {
      debugPrint('[LocalLibrary] 读取本地最近播放失败: $e\n$st');
      return const [];
    }
  }

  /// 专辑名：内嵌标签 → 所在文件夹名 → 未知专辑。
  String albumNameOf(SongEntity song) {
    final tagged = song.albumName;
    if (tagged != null && tagged.trim().isNotEmpty) return tagged.trim();
    final folder = folderNameOf(song);
    if (folder != null && folder.isNotEmpty) return folder;
    return '未知专辑';
  }

  /// 歌曲所在文件夹名（路径最后一段）。路径为空时返回 null。
  String? folderNameOf(SongEntity song) {
    var path = (song.uri ?? '').trim();
    if (path.isEmpty) return null;
    path = path.replaceAll('\\', '/');
    while (path.endsWith('/')) {
      path = path.substring(0, path.length - 1);
    }
    final idx = path.lastIndexOf('/');
    final name = idx < 0 ? path : path.substring(idx + 1);
    return name.isEmpty ? null : name;
  }
}
