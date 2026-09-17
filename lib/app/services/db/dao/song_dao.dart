import 'package:sqflite/sqflite.dart';

import '../db_constants.dart';
import '../db_helper.dart';
import '../../../state/song_state.dart';
import '../../../utils/cache_version_store.dart';

class SongDao {
  static final SongDao instance = SongDao._();
  SongDao._();

  static const String cacheVersionScope = 'song_library';
  /// API 缓存的永久 TTL 哨兵值：ttl_ms 存 -1 表示永久（不清空、不按时间淘汰），
  /// 语义对齐「数据永久缓存，除非清空缓存或下次刷新」。
  static const int kCacheTtlPermanent = -1;
  static const int _maxIdsPerQuery = 500;
  static List<SongEntity>? _cachedAll;
  static Future<List<SongEntity>>? _cachedAllFuture;

  Future<int> upsertSongs(List<SongEntity> songs) async {
    if (songs.isEmpty) return 0;
    final db = await DbHelper.instance.database;
    final uniqueIds = songs.map((song) => song.id).toSet().toList();
    final added = await db.transaction<int>((txn) async {
      final existingIds = <String>{};
      for (
        var offset = 0;
        offset < uniqueIds.length;
        offset += _maxIdsPerQuery
      ) {
        final end = (offset + _maxIdsPerQuery).clamp(0, uniqueIds.length);
        final ids = uniqueIds.sublist(offset, end);
        final placeholders = List.filled(ids.length, '?').join(',');
        final rows = await txn.query(
          DbConstants.tableSongs,
          columns: ['id'],
          where: 'id IN ($placeholders)',
          whereArgs: ids,
        );
        existingIds.addAll(rows.map((row) => row['id']).whereType<String>());
      }

      final batch = txn.batch();
      for (final song in songs) {
        batch.insert(
          DbConstants.tableSongs,
          song.toMap(),
          conflictAlgorithm: ConflictAlgorithm.replace,
        );
      }
      await batch.commit(noResult: true);
      return uniqueIds.length - existingIds.length;
    });
    _cachedAll = null;
    CacheVersionStore.instance.bump(cacheVersionScope);
    return added;
  }

  Future<int> countAll() async {
    final db = await DbHelper.instance.database;
    final result = await db.rawQuery(
      'SELECT COUNT(*) as total FROM ${DbConstants.tableSongs}',
    );
    if (result.isEmpty) return 0;
    final value = result.first['total'];
    if (value is int) return value;
    return int.tryParse(value?.toString() ?? '') ?? 0;
  }

  Future<List<SongEntity>> fetchAll() async {
    final db = await DbHelper.instance.database;
    final rows = await db.query(
      DbConstants.tableSongs,
      orderBy: 'title COLLATE NOCASE',
    );
    return rows.map(SongEntity.fromMap).toList();
  }

  Future<List<SongEntity>> fetchAllCached() async {
    final cached = _cachedAll;
    if (cached != null) return cached;
    final inflight = _cachedAllFuture;
    if (inflight != null) return inflight;
    final future = fetchAll();
    _cachedAllFuture = future;
    final list = await future;
    _cachedAll = list;
    _cachedAllFuture = null;
    return list;
  }

  /// 本地音源歌曲（isLocal = 1，未标记删除）。本地库量级有限，直接全量取。
  Future<List<SongEntity>> fetchLocalSongs() async {
    final db = await DbHelper.instance.database;
    final rows = await db.query(
      DbConstants.tableSongs,
      where: 'isLocal = 1 AND COALESCE(isAudioFileDeleted, 0) = 0',
      orderBy: 'title COLLATE NOCASE',
    );
    return rows.map(SongEntity.fromMap).toList();
  }

  Future<List<SongEntity>> fetchByIds(List<String> ids) async {
    if (ids.isEmpty) return const [];
    final db = await DbHelper.instance.database;
    final placeholders = List.filled(ids.length, '?').join(',');
    final rows = await db.query(
      DbConstants.tableSongs,
      where: 'id IN ($placeholders)',
      whereArgs: ids,
    );
    final map = <String, SongEntity>{};
    for (final row in rows) {
      final song = SongEntity.fromMap(row);
      map[song.id] = song;
    }
    return ids.map((id) => map[id]).whereType<SongEntity>().toList();
  }

  /// 某个音源下所有歌曲的 ID。
  ///
  /// 只取 `id` 一列：本地音源重扫时要用它比对「上次扫到、这次没了」的文件，
  /// 曲库几千首时把整行读出来纯属浪费。走 `idx_songs_source` 索引。
  ///
  /// [sourceId] 传 `SongEntity.defaultFeiniuSourceId` 时同时匹配 NULL ——
  /// 历史飞牛数据的 `sourceId` 是 NULL，语义上归属默认飞牛音源
  /// （与 `SongEntity.effectiveSourceId` 的口径保持一致）。
  Future<List<String>> fetchIdsBySource(String sourceId) async {
    final db = await DbHelper.instance.database;
    final where = sourceId == SongEntity.defaultFeiniuSourceId
        ? '(sourceId = ? OR sourceId IS NULL)'
        : 'sourceId = ?';
    final rows = await db.query(
      DbConstants.tableSongs,
      columns: ['id'],
      where: where,
      whereArgs: [sourceId],
    );
    return rows.map((row) => row['id']).whereType<String>().toList();
  }

  Future<int> deleteByIds(List<String> ids) async {
    if (ids.isEmpty) return 0;
    final db = await DbHelper.instance.database;
    final placeholders = List.filled(ids.length, '?').join(',');
    final result = await db.delete(
      DbConstants.tableSongs,
      where: 'id IN ($placeholders)',
      whereArgs: ids,
    );
    _cachedAll = null;
    CacheVersionStore.instance.bump(cacheVersionScope);
    return result;
  }

  // region API 缓存

  Future<void> cacheApiResponse(
    String key,
    String json, {
    int? ttlMs,
  }) async {
    final db = await DbHelper.instance.database;
    final now = DateTime.now().millisecondsSinceEpoch;
    await db.insert(DbConstants.tableApiCache, {
      'cache_key': key,
      'json_data': json,
      'cached_at_ms': now,
      // null → 永久（ttl_ms 存 -1）；显式传值则存实际 TTL
      'ttl_ms': ttlMs ?? kCacheTtlPermanent,
    }, conflictAlgorithm: ConflictAlgorithm.replace);
  }

  Future<String?> getCachedApiResponse(
    String key, {
    bool ignoreTtl = false,
  }) async {
    final db = await DbHelper.instance.database;
    if (ignoreTtl) {
      final rows = await db.query(
        DbConstants.tableApiCache,
        where: 'cache_key = ?',
        whereArgs: [key],
        limit: 1,
      );
      if (rows.isEmpty) return null;
      return rows.first['json_data'] as String?;
    }
    final now = DateTime.now().millisecondsSinceEpoch;
    final rows = await db.query(
      DbConstants.tableApiCache,
      // 永久项（ttl_ms = -1）不按时间过期
      where: 'cache_key = ? AND (ttl_ms < 0 OR (cached_at_ms + ttl_ms) > ?)',
      whereArgs: [key, now],
      limit: 1,
    );
    if (rows.isEmpty) return null;
    return rows.first['json_data'] as String?;
  }

  Future<void> clearExpiredCache() async {
    final db = await DbHelper.instance.database;
    final now = DateTime.now().millisecondsSinceEpoch;
    await db.delete(
      DbConstants.tableApiCache,
      // 永久项（ttl_ms = -1）保留，只清有 TTL 且已过期的
      where: 'ttl_ms >= 0 AND (cached_at_ms + ttl_ms) < ?',
      whereArgs: [now],
    );
  }

  /// 清空全部 API 响应缓存（设置页「清理缓存」入口）
  Future<void> clearApiCache() async {
    final db = await DbHelper.instance.database;
    await db.delete(DbConstants.tableApiCache);
  }

  /// API 缓存条目数（设置页展示占用）
  Future<int> apiCacheCount() async {
    final db = await DbHelper.instance.database;
    final rows = await db.rawQuery(
      'SELECT COUNT(*) AS c FROM ${DbConstants.tableApiCache}',
    );
    return rows.isEmpty ? 0 : (rows.first['c'] as int?) ?? 0;
  }

  // endregion
}
