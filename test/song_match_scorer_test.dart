import 'package:flutter_test/flutter_test.dart';

import 'package:feiniu_music/app/services/song_match/song_match_models.dart';
import 'package:feiniu_music/app/services/song_match/song_match_scorer.dart';

SongMatchResult _r({
  required String id,
  required String pluginId,
  required String title,
  String artist = '',
  String album = '',
}) {
  return SongMatchResult(id: id, pluginId: pluginId, pluginName: pluginId, title: title, artist: artist, album: album);
}

void main() {
  group('SongMatchScorer.mergeRanked', () {
    test('按插件源顺序分组，同源内保持返回顺序', () {
      final groups = [
        [
          _r(id: 'qq-1', pluginId: 'qq', title: '完全无关的歌'),
          _r(id: 'qq-2', pluginId: 'qq', title: '我等你 (Live)'),
        ],
        [
          _r(id: 'netease-1', pluginId: 'netease', title: '我等你'),
        ],
      ];
      // qq 在 netease 前 → qq 整组在前，同源内保持 qq-1, qq-2 原始顺序
      final merged = SongMatchScorer.mergeRanked(
        groups,
        sourceOrder: ['qq', 'netease'],
      );
      expect(merged.map((e) => e.id).toList(), ['qq-1', 'qq-2', 'netease-1']);
    });

    test('源顺序反转则整组反转，同源内保持返回顺序', () {
      final groups = [
        [
          _r(id: 'qq-1', pluginId: 'qq', title: '我等你'),
          _r(id: 'qq-2', pluginId: 'qq', title: '我等你 (Live)'),
        ],
        [
          _r(id: 'netease-1', pluginId: 'netease', title: '我等你'),
        ],
      ];
      final merged = SongMatchScorer.mergeRanked(
        groups,
        sourceOrder: ['netease', 'qq'],
      );
      expect(merged.map((e) => e.id).toList(), ['netease-1', 'qq-1', 'qq-2']);
    });

    test('未知源排在最后，按出现顺序保持', () {
      final groups = [
        [
          _r(id: 'qq-1', pluginId: 'qq', title: '我等你'),
        ],
        [
          _r(id: 'unknown-1', pluginId: 'unknown', title: '我等你'),
        ],
      ];
      final merged = SongMatchScorer.mergeRanked(
        groups,
        sourceOrder: ['qq'],
      );
      expect(merged.map((e) => e.id).toList(), ['qq-1', 'unknown-1']);
    });

    test('不传 sourceOrder 时保持原分组顺序', () {
      final groups = [
        [
          _r(id: 'a-1', pluginId: 'a', title: '歌'),
          _r(id: 'a-2', pluginId: 'a', title: '歌2'),
        ],
        [
          _r(id: 'b-1', pluginId: 'b', title: '歌3'),
        ],
      ];
      final merged = SongMatchScorer.mergeRanked(groups);
      expect(merged.map((e) => e.id).toList(), ['a-1', 'a-2', 'b-1']);
    });

    test('有关键词时优先按歌曲名+歌手相似度降序', () {
      final groups = [
        [
          _r(id: 'q-cover', pluginId: 'qq', title: '晴天(深情版)', artist: 'Lucky小爱'),
          _r(id: 'q-exact', pluginId: 'qq', title: '晴天', artist: '周杰伦'),
        ],
        [
          _r(id: 'n-live', pluginId: 'netease', title: '晴天 (原唱 周杰伦)', artist: 'RyaVocal'),
        ],
      ];
      final merged = SongMatchScorer.mergeRanked(
        groups,
        sourceOrder: ['qq', 'netease'],
        keyword: '晴天 周杰伦',
      );
      // 晴天/周杰伦 完全匹配排最前；其余按相似度降序
      expect(merged.first.id, 'q-exact', reason: '标题+歌手完全匹配排第一');
    });

    test('相似度相同按数据源顺序稳定排序', () {
      final groups = [
        [
          _r(id: 'q-exact', pluginId: 'qq', title: '晴天', artist: '周杰伦'),
        ],
        [
          _r(id: 'n-exact', pluginId: 'netease', title: '晴天', artist: '周杰伦'),
        ],
      ];
      final merged = SongMatchScorer.mergeRanked(
        groups,
        sourceOrder: ['qq', 'netease'],
        keyword: '晴天 周杰伦',
      );
      // 两者相似度相同（都完全匹配）→ 按源顺序 qq 在前
      expect(merged.map((e) => e.id).toList(), ['q-exact', 'n-exact']);
    });

    test('无关键词时保持平台顺序（原逻辑）', () {
      final groups = [
        [
          _r(id: 'qq-1', pluginId: 'qq', title: '完全无关的歌'),
        ],
        [
          _r(id: 'netease-1', pluginId: 'netease', title: '晴天'),
        ],
      ];
      final merged = SongMatchScorer.mergeRanked(
        groups,
        sourceOrder: ['qq', 'netease'],
      );
      expect(merged.map((e) => e.id).toList(), ['qq-1', 'netease-1']);
    });
  });
}
