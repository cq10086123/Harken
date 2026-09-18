import 'package:flutter_test/flutter_test.dart';

import 'package:feiniu_music/app/state/song_state.dart';
import 'package:feiniu_music/pages/library/library_detail_pages.dart';

/// 构造带标题的歌曲（title 是集数排序的唯一输入）。
SongEntity _song(String id, String title, {int? trackNumber}) {
  return SongEntity(
    id: id,
    title: title,
    artist: '[{"name":"a"}]',
    trackNumber: trackNumber,
  );
}

void main() {
  group('episodeNumberOf（集数提取）', () {
    test('中文格式：第N集/话/回/章/部/期，前导零等价', () {
      expect(episodeNumberOf('第1集 开端'), 1);
      expect(episodeNumberOf('第01集'), 1);
      expect(episodeNumberOf('第001集'), 1);
      expect(episodeNumberOf('第12话'), 12);
      expect(episodeNumberOf('第100回'), 100);
      expect(episodeNumberOf('第3章'), 3);
    });

    test('英文前缀：EP / Track', () {
      expect(episodeNumberOf('EP01 序章'), 1);
      expect(episodeNumberOf('ep3'), 3);
      expect(episodeNumberOf('Track 4'), 4);
    });

    test('含数字但非集数格式 → 取首个数字（此处曾抛 RangeError）', () {
      expect(episodeNumberOf('2026年的第一场雪'), 2026);
      expect(episodeNumberOf('Love 2000'), 2000);
    });

    test('没有数字 → null（排序时沉底）', () {
      expect(episodeNumberOf('人间烟火'), isNull);
      expect(episodeNumberOf('《其实都没有》杨宗纬'), isNull);
      expect(episodeNumberOf(''), isNull);
    });
  });

  group('sortAlbumDetailSongs（episode 排序）', () {
    test('数字标题混入不再抛异常，且按集数数值排序、无集数沉底', () {
      final songs = [
        _song('a', '第10集'),
        _song('b', '第2集'),
        _song('c', '2026年的第一场雪'),
        _song('d', '没有数字的标题'),
      ];
      final sorted = sortAlbumDetailSongs(
        songs,
        sortKey: 'episode',
        ascending: true,
      );
      expect(
        sorted.map((s) => s.title).toList(),
        ['第2集', '第10集', '2026年的第一场雪', '没有数字的标题'],
      );
    });

    test('本地音乐专辑场景（全部是普通歌名）不抛异常', () {
      final songs = [
        _song('1', '人间烟火'),
        _song('2', '其实都没有'),
        _song('3', '一梦洒脱'),
      ];
      final sorted = sortAlbumDetailSongs(
        songs,
        sortKey: 'episode',
        ascending: true,
      );
      expect(sorted.length, 3);
    });
  });
}
