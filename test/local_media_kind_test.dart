import 'package:flutter_test/flutter_test.dart';

import 'package:feiniu_music/app/services/source/local/local_media_kind.dart';
import 'package:feiniu_music/app/state/song_state.dart';

SongEntity _song(
  String id,
  String title, {
  int? durationMs,
  String artist = '[{"name":"未知艺术家"}]',
  int? trackNumber,
}) {
  return SongEntity(
    id: id,
    title: title,
    artist: artist,
    durationMs: durationMs,
    trackNumber: trackNumber,
  );
}

List<SongEntity> _audiobookAlbum() => [
      for (var i = 1; i <= 12; i++)
        _song('a$i', '第$i集 山河故人', durationMs: 15 * 60 * 1000),
    ];

List<SongEntity> _musicAlbum() => [
      _song('m1', '人间烟火', durationMs: 4 * 60 * 1000),
      _song('m2', '其实都没有', durationMs: 4 * 60 * 1000),
      _song('m3', '一梦洒脱', durationMs: 5 * 60 * 1000),
      _song('m4', '2026年的第一场雪', durationMs: 4 * 60 * 1000),
    ];

void main() {
  group('isEpisodeStyleTitle（严格集数命名）', () {
    test('中文集数写法', () {
      expect(isEpisodeStyleTitle('第1集 开端'), isTrue);
      expect(isEpisodeStyleTitle('第001集'), isTrue);
      expect(isEpisodeStyleTitle('第十二回'), isTrue);
      expect(isEpisodeStyleTitle('第3章'), isTrue);
    });

    test('英文前缀与行首编号', () {
      expect(isEpisodeStyleTitle('EP01 序章'), isTrue);
      expect(isEpisodeStyleTitle('Track 4'), isTrue);
      expect(isEpisodeStyleTitle('001、开端'), isTrue);
      expect(isEpisodeStyleTitle('001 开端'), isTrue);
    });

    test('普通歌名即使含数字也不算集数（关键：音乐专辑不能被误判）', () {
      expect(isEpisodeStyleTitle('2026年的第一场雪'), isFalse);
      expect(isEpisodeStyleTitle('Love 2000'), isFalse);
      expect(isEpisodeStyleTitle('99 Problems'), isFalse);
      expect(isEpisodeStyleTitle('人间烟火'), isFalse);
    });
  });

  group('detectLocalMediaKind（内容类型识别）', () {
    test('有声书：集数命名 + 单集长 → audiobook', () {
      expect(detectLocalMediaKind(_audiobookAlbum()), LocalMediaKind.audiobook);
    });

    test('音乐：普通歌名 + 短时长 + 无歌手标签（用户实测样本）→ music', () {
      expect(detectLocalMediaKind(_musicAlbum()), LocalMediaKind.music);
    });

    test('音乐：带真实歌手标签与轨道号 → music（扣分项生效）', () {
      final songs = [
        for (var i = 1; i <= 8; i++)
          _song(
            'x$i',
            '歌曲$i',
            durationMs: 4 * 60 * 1000,
            artist: '[{"name":"周杰伦"}]',
            trackNumber: i,
          ),
      ];
      expect(detectLocalMediaKind(songs), LocalMediaKind.music);
    });

    test('集数命名但单集很短（如短篇播客）仍判有声书', () {
      final songs = [
        for (var i = 1; i <= 10; i++)
          _song('p$i', '第$i集', durationMs: 3 * 60 * 1000),
      ];
      expect(detectLocalMediaKind(songs), LocalMediaKind.audiobook);
    });

    test('空列表 → music（安全默认）', () {
      expect(detectLocalMediaKind(const []), LocalMediaKind.music);
    });
  });
}
