import 'package:flutter_test/flutter_test.dart';

import 'package:feiniu_music/app/state/song_state.dart';

void main() {
  group('SongEntity codec 字段', () {
    test('fromMap/toMap 往返保留 codec', () {
      final song = SongEntity.fromMap({
        'id': 's1',
        'title': '我等你',
        'artist': '[{"name":"刘若英"}]',
        'format': 'm4a',
        'codec': 'eac3',
      });
      expect(song.format, 'm4a');
      expect(song.codec, 'eac3');
      expect(song.toMap()['codec'], 'eac3');
    });

    test('codec 缺失时 fromMap 为 null', () {
      final song = SongEntity.fromMap({
        'id': 's2',
        'title': 't',
        'artist': 'a',
        'format': 'mp3',
      });
      expect(song.codec, isNull);
    });

    test('copyWith 保留 codec', () {
      final song = SongEntity(
        id: 's3',
        title: 't',
        artist: 'a',
        format: 'm4a',
        codec: 'alac',
      );
      final copied = song.copyWith(title: '新标题');
      expect(copied.codec, 'alac');
    });

    test('copyWith 可更新 codec', () {
      final song = SongEntity(
        id: 's4',
        title: 't',
        artist: 'a',
        format: 'm4a',
      );
      final updated = song.copyWith(codec: 'eac3');
      expect(updated.codec, 'eac3');
    });
  });

  group('SongEntity album 字段', () {
    test('albumCoverId 解析 album JSON 中的 coverId', () {
      final song = SongEntity.fromMap({
        'id': 's5',
        'title': 't',
        'artist': 'a',
        'album': '{"guid":"abc","name":"专辑","coverId":"album_def"}',
      });
      expect(song.albumCoverId, 'album_def');
    });

    test('albumCoverId 缺 coverId / 非 JSON 时返回 null', () {
      final noCover = SongEntity.fromMap({
        'id': 's6',
        'title': 't',
        'artist': 'a',
        'album': '{"guid":"abc","name":"专辑"}',
      });
      expect(noCover.albumCoverId, isNull);

      final plain = SongEntity.fromMap({
        'id': 's7',
        'title': 't',
        'artist': 'a',
        'album': '纯文本专辑',
      });
      expect(plain.albumCoverId, isNull);
      expect(plain.albumGuid, isNull);
    });
  });

  group('SongEntity 多音源字段', () {
    test('默认值保持既有行为：非本地、无音源、标签未解析', () {
      const song = SongEntity(id: 's1', title: 't', artist: 'a');
      expect(song.isLocal, isFalse);
      expect(song.sourceId, isNull);
      expect(song.tagsParsed, isFalse);
      expect(song.fileModifiedMs, isNull);
      expect(song.localCoverPath, isNull);
      expect(song.localAssetId, isNull);
      // 存量数据 toMap 仍写 isLocal=0，与改造前完全一致
      expect(song.toMap()['isLocal'], 0);
    });

    test('effectiveSourceId 把 NULL 归位到飞牛默认音源', () {
      const legacy = SongEntity(id: 's2', title: 't', artist: 'a');
      expect(legacy.effectiveSourceId, SongEntity.defaultFeiniuSourceId);

      const local = SongEntity(
        id: 's3',
        title: 't',
        artist: 'a',
        sourceId: 'local-1',
      );
      expect(local.effectiveSourceId, 'local-1');
    });

    test('fromMap/toMap 往返保留全部音源字段', () {
      const song = SongEntity(
        id: 's4',
        title: '本地歌',
        artist: '[{"name":"某人"}]',
        uri: '/music/a.flac',
        isLocal: true,
        sourceId: 'local-1700000000000',
        fileModifiedMs: 1700000000000,
        localCoverPath: '/cache/cover/a.jpg',
        localAssetId: 'asset-9',
        tagsParsed: true,
      );
      final round = SongEntity.fromMap(song.toMap());
      expect(round.isLocal, isTrue);
      expect(round.sourceId, 'local-1700000000000');
      expect(round.fileModifiedMs, 1700000000000);
      expect(round.localCoverPath, '/cache/cover/a.jpg');
      expect(round.localAssetId, 'asset-9');
      expect(round.tagsParsed, isTrue);
    });

    test('isLocal / tagsParsed 以 0/1 与 bool 两种形态入库都能读回', () {
      // sqflite 读回的是 int；某些内存构造路径可能给 bool，两种都要认
      expect(
        SongEntity.fromMap({
          'id': 's5',
          'title': 't',
          'artist': 'a',
          'isLocal': 1,
          'tagsParsed': 1,
        }).isLocal,
        isTrue,
      );
      expect(
        SongEntity.fromMap({
          'id': 's6',
          'title': 't',
          'artist': 'a',
          'isLocal': true,
          'tagsParsed': true,
        }).tagsParsed,
        isTrue,
      );
      expect(
        SongEntity.fromMap({
          'id': 's7',
          'title': 't',
          'artist': 'a',
          'isLocal': 0,
        }).isLocal,
        isFalse,
      );
    });

    test('copyWith 保留未指定的音源字段，可单独更新', () {
      const song = SongEntity(
        id: 's8',
        title: 't',
        artist: 'a',
        isLocal: true,
        sourceId: 'webdav-1',
        localCoverPath: '/c.jpg',
        tagsParsed: true,
      );
      final renamed = song.copyWith(title: '新标题');
      expect(renamed.isLocal, isTrue);
      expect(renamed.sourceId, 'webdav-1');
      expect(renamed.localCoverPath, '/c.jpg');
      expect(renamed.tagsParsed, isTrue);

      final rescanned = song.copyWith(tagsParsed: false, fileModifiedMs: 42);
      expect(rescanned.tagsParsed, isFalse);
      expect(rescanned.fileModifiedMs, 42);
      expect(rescanned.sourceId, 'webdav-1');
    });

    test('fileModifiedMs 支持字符串数字（sqflite 某些驱动返回 TEXT）', () {
      final song = SongEntity.fromMap({
        'id': 's9',
        'title': 't',
        'artist': 'a',
        'fileModifiedMs': '1700000000000',
      });
      expect(song.fileModifiedMs, 1700000000000);
    });
  });
}
