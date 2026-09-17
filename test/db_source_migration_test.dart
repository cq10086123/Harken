import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:feiniu_music/app/services/db/db_constants.dart';
import 'package:feiniu_music/app/services/db/db_helper.dart';
import 'package:feiniu_music/app/state/song_state.dart';

/// v18 迁移：多音源改造给 `songs` 加 sourceId / fileModifiedMs /
/// localCoverPath / localAssetId / tagsParsed。
///
/// 必须同时满足（历史同类故障见 db_helper 注释：v12 缺 updatedAt、
/// v13 漏加 isCue、v14 重复加 isCue 导致 open 失败）：
/// 1. v17 旧库升级后能查/写这些列；
/// 2. **全新安装（onCreate）也直接含这些列** —— localCoverPath / tagsParsed
///    此前只在 `oldVersion < 2` 分支里加，onCreate 建表一直没有它们，
///    导致全新安装的库反而缺列；
/// 3. v1 老库（已从 `oldVersion < 2` 分支拿到 localCoverPath / tagsParsed）
///    升级到 v18 不抛 duplicate column；
/// 4. 迁移幂等：重开同版本库不抛错；
/// 5. 写入带 sourceId 的 SongEntity 事务不回滚。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tempDir;

  /// v18 新增的列。
  const newColumns = {
    'sourceId',
    'fileModifiedMs',
    'localCoverPath',
    'localAssetId',
    'tagsParsed',
  };

  setUp(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    tempDir = Directory.systemTemp.createTempSync('db_source_test');
  });

  tearDown(() {
    DbHelper.instance.resetForTest();
    try {
      tempDir.deleteSync(recursive: true);
    } catch (_) {}
  });

  Future<Set<String>> songColumns(Database db) async {
    final cols = await db.rawQuery(
      'PRAGMA table_info(${DbConstants.tableSongs})',
    );
    return cols.map((r) => r['name'] as String).toSet();
  }

  Future<Set<String>> indexNames(Database db) async {
    final rows = await db.rawQuery(
      "SELECT name FROM sqlite_master WHERE type='index' "
      "AND tbl_name='${DbConstants.tableSongs}'",
    );
    return rows.map((r) => r['name'] as String).toSet();
  }

  /// v17 历史 schema：含 isAudioFileDeleted，但没有任何 v18 新列。
  Future<void> createLegacyV17Db(String path) async {
    final legacy = await databaseFactory.openDatabase(
      path,
      options: OpenDatabaseOptions(
        version: 17,
        onCreate: (db, version) async {
          await db.execute('''
CREATE TABLE ${DbConstants.tableSongs} (
  id TEXT PRIMARY KEY,
  title TEXT NOT NULL,
  artist TEXT NOT NULL,
  album TEXT,
  uri TEXT,
  isLocal INTEGER NOT NULL DEFAULT 0,
  headersJson TEXT,
  durationMs INTEGER,
  bitrate INTEGER,
  sampleRate INTEGER,
  fileSize INTEGER,
  format TEXT,
  codec TEXT,
  isFavorite INTEGER NOT NULL DEFAULT 0,
  coverId TEXT,
  audioSpec TEXT,
  trackNumber INTEGER,
  discNumber INTEGER,
  updatedAt INTEGER,
  isCue INTEGER NOT NULL DEFAULT 0,
  cueOffsetMs INTEGER,
  isAudioFileDeleted INTEGER NOT NULL DEFAULT 0
)
''');
        },
      ),
    );
    await legacy.close();
  }

  /// v1 老库：`oldVersion < 2` 分支会加 localCoverPath / tagsParsed，
  /// 用来验证「列已存在时 v18 再 ADD COLUMN」不炸（幂等）。
  Future<void> createLegacyV1Db(String path) async {
    final legacy = await databaseFactory.openDatabase(
      path,
      options: OpenDatabaseOptions(
        version: 1,
        onCreate: (db, version) async {
          await db.execute('''
CREATE TABLE ${DbConstants.tableSongs} (
  id TEXT PRIMARY KEY,
  title TEXT NOT NULL,
  artist TEXT NOT NULL,
  album TEXT,
  uri TEXT,
  isLocal INTEGER NOT NULL DEFAULT 0
)
''');
        },
      ),
    );
    await legacy.close();
  }

  test('dbVersion 已升到 18', () {
    expect(DbConstants.dbVersion, 18);
  });

  test('全新安装（onCreate）直接含全部 v18 新列', () async {
    final dbPath = p.join(tempDir.path, 'fresh.db');
    DbHelper.instance.resetForTest(overridePath: dbPath);
    final db = await DbHelper.instance.database;

    final names = await songColumns(db);
    for (final col in newColumns) {
      expect(names, contains(col), reason: 'onCreate 应包含 $col');
    }
  });

  test('全新安装含按音源查询的两个索引', () async {
    final dbPath = p.join(tempDir.path, 'fresh-idx.db');
    DbHelper.instance.resetForTest(overridePath: dbPath);
    final db = await DbHelper.instance.database;

    final idx = await indexNames(db);
    expect(idx, contains('idx_songs_source'));
    expect(idx, contains('idx_songs_source_title'));
  });

  test('v17 旧库升级到 v18：新列全部添加', () async {
    final dbPath = p.join(tempDir.path, 'legacy-v17.db');
    await createLegacyV17Db(dbPath);

    DbHelper.instance.resetForTest(overridePath: dbPath);
    final db = await DbHelper.instance.database;

    final names = await songColumns(db);
    for (final col in newColumns) {
      expect(names, contains(col), reason: 'v18 迁移后应有 $col');
    }
  });

  test('v17 旧库升级后写入带 sourceId 的 SongEntity 不回滚', () async {
    final dbPath = p.join(tempDir.path, 'legacy-v17-write.db');
    await createLegacyV17Db(dbPath);

    DbHelper.instance.resetForTest(overridePath: dbPath);
    final db = await DbHelper.instance.database;

    const song = SongEntity(
      id: 'local-1-a',
      title: '本地歌',
      artist: '[{"name":"某人"}]',
      uri: '/music/a.flac',
      isLocal: true,
      sourceId: 'local-1',
      fileModifiedMs: 1700000000000,
      localCoverPath: '/cache/a.jpg',
      tagsParsed: true,
    );
    await db.transaction((txn) async {
      final batch = txn.batch();
      batch.insert(
        DbConstants.tableSongs,
        song.toMap(),
        conflictAlgorithm: ConflictAlgorithm.replace,
      );
      await batch.commit(noResult: true);
    });

    final rows = await db.query(
      DbConstants.tableSongs,
      where: 'id = ?',
      whereArgs: ['local-1-a'],
    );
    expect(rows, hasLength(1));
    final back = SongEntity.fromMap(rows.single);
    expect(back.sourceId, 'local-1');
    expect(back.isLocal, isTrue);
    expect(back.fileModifiedMs, 1700000000000);
    expect(back.localCoverPath, '/cache/a.jpg');
    expect(back.tagsParsed, isTrue);
  });

  test('v1 老库（已有 localCoverPath/tagsParsed）升级到 v18 不抛 duplicate column', () async {
    final dbPath = p.join(tempDir.path, 'legacy-v1.db');
    await createLegacyV1Db(dbPath);

    DbHelper.instance.resetForTest(overridePath: dbPath);
    // 若 v18 迁移用的是裸 ALTER TABLE，这里会抛 duplicate column name
    // 并让整个 openDatabase 事务回滚。
    final db = await DbHelper.instance.database;

    final names = await songColumns(db);
    for (final col in newColumns) {
      expect(names, contains(col), reason: 'v1→v18 后应有 $col');
    }
  });

  test('迁移幂等：v18 库重开不重复加列、不抛错', () async {
    final dbPath = p.join(tempDir.path, 'current.db');
    DbHelper.instance.resetForTest(overridePath: dbPath);
    await DbHelper.instance.database;

    DbHelper.instance.resetForTest(overridePath: dbPath);
    final db = await DbHelper.instance.database;

    final names = await songColumns(db);
    for (final col in newColumns) {
      expect(names, contains(col));
    }
  });

  test('存量行 sourceId 为 NULL，由 effectiveSourceId 归位到飞牛', () async {
    final dbPath = p.join(tempDir.path, 'legacy-null-source.db');
    await createLegacyV17Db(dbPath);

    DbHelper.instance.resetForTest(overridePath: dbPath);
    final db = await DbHelper.instance.database;

    // 模拟存量飞牛数据：不带 sourceId 写入
    await db.insert(
      DbConstants.tableSongs,
      {
        'id': 'feiniu-legacy',
        'title': '老数据',
        'artist': '[{"name":"某人"}]',
        'isLocal': 0,
        'isFavorite': 0,
        'isCue': 0,
        'isAudioFileDeleted': 0,
        'tagsParsed': 0,
      },
      conflictAlgorithm: ConflictAlgorithm.replace,
    );

    final rows = await db.query(
      DbConstants.tableSongs,
      where: 'id = ?',
      whereArgs: ['feiniu-legacy'],
    );
    final back = SongEntity.fromMap(rows.single);
    expect(back.sourceId, isNull);
    expect(back.effectiveSourceId, SongEntity.defaultFeiniuSourceId);
    expect(back.isLocal, isFalse);
  });

  test('按 sourceId 过滤是可用查询形态（并存的库页面依赖它）', () async {
    final dbPath = p.join(tempDir.path, 'filter.db');
    DbHelper.instance.resetForTest(overridePath: dbPath);
    final db = await DbHelper.instance.database;

    for (final e in [
      ('a', 'local-1'),
      ('b', 'local-1'),
      ('c', 'webdav-1'),
    ]) {
      await db.insert(
        DbConstants.tableSongs,
        SongEntity(
          id: e.$1,
          title: e.$1,
          artist: '[]',
          sourceId: e.$2,
        ).toMap(),
        conflictAlgorithm: ConflictAlgorithm.replace,
      );
    }

    final local = await db.query(
      DbConstants.tableSongs,
      where: 'sourceId = ?',
      whereArgs: ['local-1'],
    );
    expect(local, hasLength(2));

    final dav = await db.query(
      DbConstants.tableSongs,
      where: 'sourceId = ?',
      whereArgs: ['webdav-1'],
    );
    expect(dav, hasLength(1));
  });
}
