import 'dart:math';

import 'package:flutter_test/flutter_test.dart';

import 'package:feiniu_music/app/state/player_state.dart';

/// 固定种子：让随机顺序可复现（否则只能写弱断言）。
Random seeded([int seed = 20260918]) => Random(seed);

void main() {
  group('随机播放的队列重排 shuffledTailOrder', () {
    test('当前曲及其之前的部分保持原顺序，只打乱尾部', () {
      final items = List.generate(8, (i) => 's$i');
      const keep = 3;
      final out = shuffledTailOrder(items, keep, random: seeded());

      expect(out.length, items.length);
      expect(out.sublist(0, keep + 1), items.sublist(0, keep + 1),
          reason: '已播部分与当前曲不该被移动');
      expect(out[keep], 's$keep', reason: '当前正在播的这首必须停在原位');
    });

    test('尾部是同一批元素的一个排列（不丢不重）', () {
      final items = List.generate(12, (i) => 's$i');
      const keep = 2;
      final out = shuffledTailOrder(items, keep, random: seeded(42));

      expect(out.toSet().length, items.length, reason: '不能出现重复元素');
      expect(out.toSet(), items.toSet(), reason: '不能丢失元素');
    });

    test('确实会打乱（多次抽样里至少出现一种与原始不同的顺序）', () {
      final items = List.generate(10, (i) => 's$i');
      var shuffled = 0;
      for (var seed = 0; seed < 20; seed++) {
        final out = shuffledTailOrder(items, 0, random: seeded(seed));
        if (out.toString() != items.toString()) shuffled++;
      }
      expect(shuffled, greaterThan(15), reason: '20 次抽样应几乎都改变了尾部顺序');
    });

    test('队列过短时不重排（原样返回副本）', () {
      expect(shuffledTailOrder(<String>['a'], 0, random: seeded()), ['a']);
      expect(shuffledTailOrder(<String>['a', 'b'], 0, random: seeded()), ['a', 'b']);
      expect(shuffledTailOrder(<String>[], -1, random: seeded()), isEmpty);
    });

    test('keepIndex 越界时钳制到合法范围', () {
      final items = List.generate(5, (i) => 's$i');
      // -1 → 0：只保留第一首，其余打乱
      final neg = shuffledTailOrder(items, -1, random: seeded());
      expect(neg.first, 's0');
      expect(neg.toSet(), items.toSet());
      // 越界到末尾 → 全部保持原样（没有尾部可打乱）
      final over = shuffledTailOrder(items, 99, random: seeded());
      expect(over, items);
    });

    test('新一轮重排：当前曲置于队首，其余重新随机', () {
      final items = List.generate(6, (i) => 's$i');
      // 模拟 _startNewShuffleRound：当前曲 s4 放到队首后再打乱尾部（keepIndex=0）
      final current = items[4];
      final rest = items.where((s) => s != current).toList();
      final out = shuffledTailOrder(<String>[current, ...rest], 0,
          random: seeded(5));
      expect(out.first, current, reason: '新一轮里当前曲仍在队首');
      expect(out.length, items.length);
      expect(out.toSet(), items.toSet());
    });

    test('不修改传入的列表', () {
      final items = List.generate(6, (i) => 's$i');
      final snapshot = List<String>.of(items);
      shuffledTailOrder(items, 1, random: seeded());
      expect(items, snapshot, reason: '纯函数不应改动入参');
    });
  });
}
