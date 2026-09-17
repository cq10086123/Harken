import 'package:sqflite/sqflite.dart';

import '../../../state/song_state.dart';
import '../db_constants.dart';
import '../db_helper.dart';
import 'song_dao.dart';

/// 本地歌单（`playlists` / `playlist_songs` 表）。
///
/// 与飞牛服务端歌单**并存**：本地歌单 id 一律带 [localIdPrefix] 前缀，
/// UI / 路由据此区分归属。歌单成员存 `SongEntity.id`——本地歌必在库，
/// 飞牛歌（加歌单时手里有实体）一并 upsert 进 songs 表，因此**本地歌单
/// 两种歌都能收**。
///
/// 这两张表建库起就存在但一直无人写入（预埋）；本地歌单是第一个用户。
class PlaylistDao {
  PlaylistDao._();

  static final PlaylistDao instance = PlaylistDao._();

  /// 本地歌单 id 前缀（区分飞牛服务端 guid）。
  static const String localIdPrefix = 'local-pl-';

  Future<Database> get _db async => DbHelper.instance.database;

  /// 本地歌单列表（按创建时间倒序）。
  Future<List<Map<String, Object?>>> listLocalPlaylists() async {
    final db = await _db;
    return db.query(
      DbConstants.tablePlaylists,
      where: 'id LIKE ?',
      whereArgs: ['$localIdPrefix%'],
      orderBy: 'createdAtMs DESC',
    );
  }

  /// 本地歌单曲目（join songs 表拿实体，按加入顺序）。
  Future<List<SongEntity>> localPlaylistSongs(String playlistId) async {
    final db = await _db;
    final rows = await db.rawQuery(
      'SELECT s.* FROM ${DbConstants.tablePlaylistSongs} ps '
      'JOIN ${DbConstants.tableSongs} s ON s.id = ps.songId '
      'WHERE ps.playlistId = ? ORDER BY ps.sortOrder ASC',
      [playlistId],
    );
    return rows.map(SongEntity.fromMap).toList();
  }

  /// 本地歌单曲目数。
  Future<int> localPlaylistSongCount(String playlistId) async {
    final db = await _db;
    final rows = await db.rawQuery(
      'SELECT COUNT(*) AS c FROM ${DbConstants.tablePlaylistSongs} '
      'WHERE playlistId = ?',
      [playlistId],
    );
    return (rows.first['c'] as int?) ?? 0;
  }

  /// 创建本地歌单，返回 id。
  Future<String> createLocalPlaylist(String name) async {
    final now = DateTime.now().millisecondsSinceEpoch;
    final id = '$localIdPrefix$now';
    final db = await _db;
    await db.insert(DbConstants.tablePlaylists, {
      'id': id,
      'name': name,
      'createdAtMs': now,
      'isFavorite': 0,
      'sortOrder': 0,
    });
    return id;
  }

  /// 添加歌曲到本地歌单。飞牛歌一并 upsert 进 songs 表（保证后续按
  /// id 能查到实体）。重复添加（主键冲突）静默忽略。
  Future<void> addSongsToLocal(
    String playlistId,
    List<SongEntity> songs,
  ) async {
    if (songs.isEmpty) return;
    await SongDao.instance.upsertSongs(songs);
    final db = await _db;
    final baseOrder = DateTime.now().millisecondsSinceEpoch;
    final batch = db.batch();
    for (var i = 0; i < songs.length; i++) {
      batch.insert(
        DbConstants.tablePlaylistSongs,
        {
          'playlistId': playlistId,
          'songId': songs[i].id,
          'sortOrder': baseOrder + i,
        },
        conflictAlgorithm: ConflictAlgorithm.ignore,
      );
    }
    await batch.commit(noResult: true);
  }

  /// 从本地歌单移除一首。
  Future<void> removeSongFromLocal(String playlistId, String songId) async {
    final db = await _db;
    await db.delete(
      DbConstants.tablePlaylistSongs,
      where: 'playlistId = ? AND songId = ?',
      whereArgs: [playlistId, songId],
    );
  }

  /// 删除本地歌单（连同成员行）。
  Future<void> deleteLocalPlaylist(String playlistId) async {
    final db = await _db;
    await db.delete(
      DbConstants.tablePlaylistSongs,
      where: 'playlistId = ?',
      whereArgs: [playlistId],
    );
    await db.delete(
      DbConstants.tablePlaylists,
      where: 'id = ?',
      whereArgs: [playlistId],
    );
  }

  /// 本地歌单改名。
  Future<void> renameLocalPlaylist(String playlistId, String name) async {
    final db = await _db;
    await db.update(
      DbConstants.tablePlaylists,
      {'name': name},
      where: 'id = ?',
      whereArgs: [playlistId],
    );
  }
}
