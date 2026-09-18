import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';

import 'package:feiniu_music/app/state/song_state.dart';
import 'package:feiniu_music/app/services/source/local/local_scanner.dart';
import 'package:feiniu_music/app/services/source/local/local_song_builder.dart';
import 'package:feiniu_music/app/services/source/local/local_tag_probe.dart';

void main() {
  const entry = LocalScanEntry(
    path: '/music/周杰伦/范特西/01 爱在西元前.flac',
    fileSize: 40000000,
    fileModifiedMs: 1700000000000,
  );

  const fullTags = LocalTagProbeResult(
    title: '爱在西元前',
    artist: '周杰伦',
    album: '范特西',
    durationMs: 234000,
    bitrate: 900000,
    sampleRate: 44100,
    fileSize: 40000000,
    format: 'flac',
    trackNumber: 1,
    discNumber: 1,
    tagsParsed: true,
  );

  group('encodeArtist / encodeAlbum', () {
    test('产出合法 JSON，且能被 SongEntity 的解析器读回', () {
      final song = SongEntity(
        id: 'x',
        title: 't',
        artist: LocalSongBuilder.encodeArtist('周杰伦'),
        album: LocalSongBuilder.encodeAlbum('范特西'),
      );

      expect(song.artistDisplayName, '周杰伦');
      expect(song.albumDisplayName, '范特西');
      expect(song.firstArtistGuid, 'local-artist:周杰伦');
      expect(song.albumGuid, 'local-album:范特西');
    });

    test('多歌手整串保留，不拆分（读回来与写入一致）', () {
      final song = SongEntity(
        id: 'x',
        title: 't',
        artist: LocalSongBuilder.encodeArtist('周杰伦 / 费玉清'),
      );

      expect(song.artistDisplayName, '周杰伦 / 费玉清');
      expect(song.artistGuids, ['local-artist:周杰伦 / 费玉清']);
    });

    test('AC/DC 不被拆成两个歌手（回归：曾按 "/" 切分）', () {
      final song = SongEntity(
        id: 'x',
        title: 't',
        artist: LocalSongBuilder.encodeArtist('AC/DC'),
      );

      expect(song.artistDisplayName, 'AC/DC');
      expect(song.artistGuids, ['local-artist:AC/DC']);
      expect(song.artistGuids, hasLength(1));
    });

    test('确定性 guid：同名歌手跨扫描稳定聚合', () {
      expect(
        LocalSongBuilder.encodeArtist('周杰伦'),
        LocalSongBuilder.encodeArtist('周杰伦'),
      );
    });

    test('guid 带 local- 前缀，不会与飞牛 guid 撞车', () {
      final song = SongEntity(
        id: 'x',
        title: 't',
        artist: LocalSongBuilder.encodeArtist('A'),
      );
      expect(song.firstArtistGuid, startsWith('local-artist:'));
    });

    test('空歌手名落到「未知艺术家」而不是产出空数组', () {
      final song = SongEntity(
        id: 'x',
        title: 't',
        artist: LocalSongBuilder.encodeArtist('   '),
      );
      expect(song.artistDisplayName, LocalSongBuilder.unknownArtist);
      expect(song.artistGuids, hasLength(1));
    });

    test('空专辑名返回 null（不产出空对象）', () {
      expect(LocalSongBuilder.encodeAlbum(null), isNull);
      expect(LocalSongBuilder.encodeAlbum(''), isNull);
      expect(LocalSongBuilder.encodeAlbum('  '), isNull);
    });

    test('名字里的引号与反斜杠被转义，不破坏 JSON', () {
      final encoded = LocalSongBuilder.encodeArtist(r'AC"DC \ Live');
      expect(() => jsonDecode(encoded!), returnsNormally);

      final song = SongEntity(id: 'x', title: 't', artist: encoded);
      expect(song.artistDisplayName, r'AC"DC \ Live');
    });

    test('换行符被转义', () {
      final encoded = LocalSongBuilder.encodeAlbum('A\nB');
      expect(() => jsonDecode(encoded!), returnsNormally);
    });
  });

  group('标题回退链', () {
    test('标签 → 文件名 → 未知标题', () {
      expect(
        LocalSongBuilder.build(
          entry: entry,
          sourceId: 'local-1',
          tags: fullTags,
        ).title,
        '爱在西元前',
      );

      // 无标签：用文件名（去扩展名）
      final noTags = LocalSongBuilder.build(
        entry: entry,
        sourceId: 'local-1',
        tags: null,
      );
      expect(noTags.title, '01 爱在西元前');

      // 标签读出来了但标题为空：仍回退到文件名
      final emptyTitle = LocalSongBuilder.build(
        entry: entry,
        sourceId: 'local-1',
        tags: const LocalTagProbeResult(title: '   ', tagsParsed: true),
      );
      expect(emptyTitle.title, '01 爱在西元前');
    });

    test('文件名也拿不到时才用「未知标题」', () {
      final song = LocalSongBuilder.build(
        entry: const LocalScanEntry(path: '/', fileSize: 1),
        sourceId: 'local-1',
      );
      expect(song.title, LocalSongBuilder.unknownTitle);
    });

    test('艺术家缺失落到「未知艺术家」', () {
      final song = LocalSongBuilder.build(entry: entry, sourceId: 'local-1');
      expect(song.artistDisplayName, LocalSongBuilder.unknownArtist);
    });
  });

  group('build 的多音源字段', () {
    test('isLocal=true、sourceId、tagsParsed 都写对', () {
      final song = LocalSongBuilder.build(
        entry: entry,
        sourceId: 'local-1',
        tags: fullTags,
      );

      expect(song.isLocal, isTrue);
      expect(song.sourceId, 'local-1');
      expect(song.effectiveSourceId, 'local-1');
      expect(song.tagsParsed, isTrue);
      expect(song.isAudioFileDeleted, isFalse);
    });

    test('没读标签时 tagsParsed=false（下次扫描会重试）', () {
      final song = LocalSongBuilder.build(entry: entry, sourceId: 'local-1');
      expect(song.tagsParsed, isFalse);
    });

    test('uri 是可直接播放的文件路径', () {
      final song = LocalSongBuilder.build(entry: entry, sourceId: 'local-1');
      expect(song.uri, entry.path);
    });

    test('时长为 0 或 null 时不写入（避免进度条按 0 计算）', () {
      final zero = LocalSongBuilder.build(
        entry: entry,
        sourceId: 'local-1',
        tags: const LocalTagProbeResult(durationMs: 0, tagsParsed: true),
      );
      expect(zero.durationMs, isNull);
    });

    test('文件刚扫到就清掉失效标记', () {
      final existing = SongEntity(
        id: 'x',
        title: 'old',
        artist: '[]',
        isAudioFileDeleted: true,
      );
      final song = LocalSongBuilder.build(
        entry: entry,
        sourceId: 'local-1',
        existing: existing,
      );
      expect(song.isAudioFileDeleted, isFalse);
    });

    test('本次没读到封面时保留库里已有的封面路径', () {
      final existing = SongEntity(
        id: 'x',
        title: 'old',
        artist: '[]',
        localCoverPath: '/cache/covers_v2/abc.img',
      );
      final song = LocalSongBuilder.build(
        entry: entry,
        sourceId: 'local-1',
        existing: existing,
        coverPath: null,
      );
      expect(song.localCoverPath, '/cache/covers_v2/abc.img');
    });

    test('技术字段缺失时沿用旧行的值', () {
      final existing = SongEntity(
        id: 'x',
        title: 'old',
        artist: '[]',
        bitrate: 320000,
        sampleRate: 48000,
        trackNumber: 5,
        discNumber: 2,
      );
      final song = LocalSongBuilder.build(
        entry: entry,
        sourceId: 'local-1',
        existing: existing,
        tags: const LocalTagProbeResult(tagsParsed: true),
      );
      expect(song.bitrate, 320000);
      expect(song.sampleRate, 48000);
      expect(song.trackNumber, 5);
      expect(song.discNumber, 2);
    });
  });

  group('shouldReprobe（增量扫描）', () {
    SongEntity existingRow({
      int? fileModifiedMs = 1700000000000,
      int? fileSize = 40000000,
      bool tagsParsed = true,
      String? album = '[{"name":"专辑"}]',
    }) => SongEntity(
      id: 'x',
      title: 't',
      album: album,
      artist: '[]',
      fileModifiedMs: fileModifiedMs,
      fileSize: fileSize,
      tagsParsed: tagsParsed,
    );

    test('首次入库（无旧行）→ 要读标签', () {
      expect(LocalSongBuilder.shouldReprobe(null, entry), isTrue);
    });

    test('文件没动过 → 复用，不读标签', () {
      expect(LocalSongBuilder.shouldReprobe(existingRow(), entry), isFalse);
    });

    test('修改时间变了 → 重读', () {
      expect(
        LocalSongBuilder.shouldReprobe(
          existingRow(fileModifiedMs: 1600000000000),
          entry,
        ),
        isTrue,
      );
    });

    test('文件大小变了 → 重读', () {
      expect(
        LocalSongBuilder.shouldReprobe(existingRow(fileSize: 1), entry),
        isTrue,
      );
    });

    test('上次标签没读出来 → 重读（给一次重试机会）', () {
      expect(
        LocalSongBuilder.shouldReprobe(existingRow(tagsParsed: false), entry),
        isTrue,
      );
    });
  });

  group('reuse（增量命中时复用旧行）', () {
    test('保住所有没列出的列 —— 这正是逐字段重建会丢数据的那类 bug', () {
      final existing = SongEntity(
        id: '/music/a.flac',
        title: '原来的标题',
        artist: LocalSongBuilder.encodeArtist('原来的歌手'),
        album: LocalSongBuilder.encodeAlbum('原来的专辑'),
        uri: '/music/a.flac',
        isLocal: true,
        sourceId: 'local-1',
        codec: 'alac',
        coverId: 'cover-123',
        isCue: true,
        cueOffsetMs: 12345,
        durationMs: 200000,
        bitrate: 900000,
        tagsParsed: true,
        localCoverPath: '/cache/covers_v2/abc.img',
        updatedAt: 1600000000000,
      );

      final reused = LocalSongBuilder.reuse(
        existing,
        const LocalScanEntry(
          path: '/music/a.flac',
          fileSize: 40000000,
          fileModifiedMs: 1700000000000,
        ),
      );

      // 关键断言：这些列一个都不能丢
      expect(reused.title, '原来的标题');
      expect(reused.artistDisplayName, '原来的歌手');
      expect(reused.albumDisplayName, '原来的专辑');
      expect(reused.codec, 'alac');
      expect(reused.coverId, 'cover-123');
      expect(reused.isCue, isTrue);
      expect(reused.cueOffsetMs, 12345);
      expect(reused.durationMs, 200000);
      expect(reused.bitrate, 900000);
      expect(reused.tagsParsed, isTrue);
      expect(reused.localCoverPath, '/cache/covers_v2/abc.img');
      expect(reused.updatedAt, 1600000000000);
      expect(reused.isLocal, isTrue);
      expect(reused.sourceId, 'local-1');
    });

    test('跟上文件层面的变化（mtime / size）', () {
      final existing = SongEntity(
        id: '/music/a.flac',
        title: 't',
        artist: '[]',
        fileModifiedMs: 1,
        fileSize: 1,
      );

      final reused = LocalSongBuilder.reuse(
        existing,
        const LocalScanEntry(
          path: '/music/a.flac',
          fileSize: 999,
          fileModifiedMs: 888,
        ),
      );

      expect(reused.fileModifiedMs, 888);
      expect(reused.fileSize, 999);
    });

    test('清掉失效标记（文件回来了）', () {
      final existing = SongEntity(
        id: '/music/a.flac',
        title: 't',
        artist: '[]',
        isAudioFileDeleted: true,
      );

      final reused = LocalSongBuilder.reuse(
        existing,
        const LocalScanEntry(path: '/music/a.flac', fileSize: 1),
      );

      expect(reused.isAudioFileDeleted, isFalse);
    });
  });
}
