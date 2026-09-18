import 'dart:math';

import 'package:flutter_test/flutter_test.dart';

import 'package:feiniu_music/app/services/player/shuffle_bag.dart';

/// 固定种子的 Random：让随机行为可复现（否则断言只能写成弱条件）。
Random seeded([int seed = 20260918]) => Random(seed);

void main() {
  group('ShuffleBag 洗牌袋', () {
    test('一轮内每首各轮到一次，不重复', () {
      final bag = ShuffleBag(random: seeded());
      final ids = List.generate(6, (i) => 's$i');
      String idAt(int i) => ids[i];

      final played = <int>[];
      var current = 0; // 当前在播 s0
      bag.reset(ids[current]);
      for (var n = 0; n < ids.length - 1; n++) {
        final next = bag.pick(ids.length, idAt, ids[current]);
        expect(next, isNotNull);
        expect(next, isNot(current), reason: '不能抽到当前正在播的这首');
        expect(played.contains(next), isFalse, reason: '本轮内不应重复');
        played.add(next!);
        current = next;
      }
      // 6 首一轮：除了起始的 s0，其余 5 首都应被走到
      expect(played.toSet().length, ids.length - 1);
      expect(played.contains(0), isFalse, reason: '起始曲本轮不再重复');
    });

    test('一轮放完后自动重开，能再次抽到已放过的歌', () {
      final bag = ShuffleBag(random: seeded(7));
      final ids = List.generate(3, (i) => 's$i');
      String idAt(int i) => ids[i];
      bag.reset(ids[0]);
      final first = <int>[];
      var current = 0;
      for (var n = 0; n < 2; n++) {
        final next = bag.pick(3, idAt, ids[current])!;
        first.add(next);
        current = next;
      }
      expect(first.toSet().length, 2);
      // 第 3 次：一轮已放完 → 重开一轮，应该还能抽到第一首
      final third = bag.pick(3, idAt, ids[current]);
      expect(third, isNotNull);
      expect(third, isNot(current));
    });

    test('队列只有一首时返回 null（无可随机）', () {
      final bag = ShuffleBag(random: seeded());
      expect(bag.pick(1, (i) => 'only', 'only'), isNull);
      expect(bag.pick(0, (i) => 'x', null), isNull);
    });

    test('队列增删后自动剔除失效记录（漫游追加 / 超长裁剪）', () {
      final bag = ShuffleBag(random: seeded(3));
      var ids = ['a', 'b', 'c'];
      String idAt(int i) => ids[i];
      bag.reset('a');
      final picked = bag.pick(ids.length, idAt, 'a')!;
      expect(['b', 'c'].contains(ids[picked]), isTrue);

      // 队列被替换成完全不同的歌：历史应被剔除，不会误判「已播」
      ids = ['x', 'y'];
      final next = bag.pick(ids.length, idAt, 'x');
      expect(next, isNotNull);
      expect(ids[next!], 'y');
      expect(bag.history, isNot(contains('a')), reason: '失效 id 应被剔除');
    });

    test('上一首回到本轮上一首听过的歌', () {
      final bag = ShuffleBag(random: seeded(11));
      final ids = List.generate(5, (i) => 's$i');
      String idAt(int i) => ids[i];
      bag.reset('s0');
      final a = bag.pick(5, idAt, 's0')!; // 现在在 a
      final b = bag.pick(5, idAt, ids[a])!; // 现在在 b
      expect(bag.backIndex(5, idAt), a, reason: '应回到 a');
      expect(bag.backIndex(5, idAt), 0, reason: '再往前是起始曲 s0');
      expect(bag.backIndex(5, idAt), isNull, reason: '历史到头，调用方回退顺序上一首');
      expect(ids[b], isNot(ids[a]));
    });

    test('上一首历史不足时不返回（调用方回退顺序上一首）', () {
      final bag = ShuffleBag(random: seeded());
      bag.reset('s0');
      expect(bag.backIndex(5, (i) => 's$i'), isNull);
    });
  });
}
