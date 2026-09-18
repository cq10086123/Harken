import 'package:flutter_test/flutter_test.dart';

import 'package:feiniu_music/app/state/player_state.dart';

void main() {
  group('播放模式循环顺序', () {
    test('顺序 → 列表循环 → 单曲循环 → 随机 → 回到顺序', () {
      expect(nextPlaybackMode(PlaybackMode.sequential), PlaybackMode.loop);
      expect(nextPlaybackMode(PlaybackMode.loop), PlaybackMode.single);
      expect(nextPlaybackMode(PlaybackMode.single), PlaybackMode.shuffle);
      expect(nextPlaybackMode(PlaybackMode.shuffle), PlaybackMode.sequential);
    });

    test('四档能完整循环一圈且不重不漏', () {
      var mode = PlaybackMode.sequential;
      final seen = <PlaybackMode>{mode};
      for (var i = 0; i < 3; i++) {
        mode = nextPlaybackMode(mode);
        seen.add(mode);
      }
      expect(seen.length, 4, reason: '四档必须都能到达');
      expect(mode, PlaybackMode.shuffle);
      expect(nextPlaybackMode(mode), PlaybackMode.sequential, reason: '必须闭环');
    });
  });

  group('播放模式中文名', () {
    test('每个模式都有独立名称（UI 提示用）', () {
      final labels = PlaybackMode.values.map(playbackModeLabel).toList();
      expect(labels.toSet().length, PlaybackMode.values.length, reason: '不得重名');
      expect(playbackModeLabel(PlaybackMode.sequential), '顺序播放');
      expect(playbackModeLabel(PlaybackMode.loop), '列表循环');
      expect(playbackModeLabel(PlaybackMode.single), '单曲循环');
      expect(playbackModeLabel(PlaybackMode.shuffle), '随机播放');
    });
  });
}
