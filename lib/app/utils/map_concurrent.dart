/// 限流并发 map（[limit] 个并发执行 [action]，收集结果）。
///
/// action 抛出的异常会向上传播（调用方自行捕获）；成功时收集返回结果。
Future<List<R>> mapConcurrent<T, R>(
  List<T> items,
  int limit,
  Future<R> Function(T item) action,
) async {
  final results = <R?>[];
  if (items.isEmpty) return results.whereType<R>().toList();
  final safeLimit = limit.clamp(1, items.length);
  var index = 0;

  Future<void> worker() async {
    while (true) {
      final next = index++;
      if (next >= items.length) break;
      results.add(await action(items[next]));
    }
  }

  await Future.wait(
    List.generate(safeLimit, (_) => worker()),
  );
  return results.whereType<R>().toList();
}

/// 限流并发执行（不收集结果，action 内部已隔离异常）。
Future<void> mapConcurrentEach<T>(
  List<T> items,
  int limit,
  Future<void> Function(T item) action,
) async {
  await mapConcurrent<T, void>(items, limit, action);
}
