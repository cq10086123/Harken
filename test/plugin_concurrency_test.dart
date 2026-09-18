import 'dart:async';

import 'package:flutter_test/flutter_test.dart';

import 'package:feiniu_music/app/utils/map_concurrent.dart';

void main() {
  group('mapConcurrent', () {
    test('并发上限限制：同时执行数不超过 limit', () async {
      var concurrent = 0;
      var peakConcurrent = 0;
      final items = List.generate(10, (i) => i);

      final results = await mapConcurrent<int, int>(
        items,
        3,
        (item) async {
          concurrent++;
          if (concurrent > peakConcurrent) peakConcurrent = concurrent;
          await Future<void>.delayed(const Duration(milliseconds: 10));
          concurrent--;
          return item * 2;
        },
      );

      expect(results.toSet(), {0, 2, 4, 6, 8, 10, 12, 14, 16, 18},
          reason: '全部结果返回（并发完成顺序不确定，按集合断言）');
      expect(peakConcurrent, lessThanOrEqualTo(3),
          reason: '同时执行数不应超过并发上限');
    });

    test('空列表：立即返回空', () async {
      final results = await mapConcurrent<int, int>(
        const [],
        3,
        (item) async => item,
      );
      expect(results, isEmpty);
    });

    test('limit 大于列表长度：全部并行，全部完成', () async {
      var concurrent = 0;
      var peakConcurrent = 0;
      final results = await mapConcurrent<int, int>(
        List.generate(5, (i) => i),
        10, // limit 超过元素数
        (item) async {
          concurrent++;
          if (concurrent > peakConcurrent) peakConcurrent = concurrent;
          await Future<void>.delayed(const Duration(milliseconds: 5));
          concurrent--;
          return item;
        },
      );
      expect(results.length, 5);
      expect(peakConcurrent, 5, reason: 'limit 超过长度时全部并行');
    });

    test('action 抛异常：向上传播', () async {
      await expectLater(
        mapConcurrent<int, int>(
          [1, 2, 3],
          2,
          (item) async {
            if (item == 2) throw StateError('boom');
            return item;
          },
        ),
        throwsStateError,
      );
    });

    test('并发顺序不阻塞进度（结果数量完整）', () async {
      final items = List.generate(8, (i) => i);
      final results = await mapConcurrent<int, int>(
        items,
        4,
        (item) async {
          await Future<void>.delayed(Duration(milliseconds: 20 - item));
          return item;
        },
      );
      expect(results.toSet(), items.toSet(),
          reason: '全部结果返回（顺序可能与输入不同）');
    });
  });
}
