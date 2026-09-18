import 'dart:math';

/// 随机播放的「洗牌袋」。
///
/// 为什么不用纯随机：纯随机会反复抽到同一首，听感像「没生效」。这里做的是
/// 洗牌袋——一轮内每首歌各轮到一次，放完一整轮才重开；并且**不会抽到当前
/// 正在播的这首**（避免「下一首还是它」）。
///
/// 纯逻辑、无 IO、可单测：见 `test/shuffle_bag_test.dart`。
class ShuffleBag {
  ShuffleBag({Random? random}) : _random = random ?? Random();

  final Random _random;

  /// 本轮已播放的歌曲 id（按播放顺序），最后一项即当前这首。
  final List<String> _history = [];

  /// 本轮已播放的歌曲 id（只读快照）。
  List<String> get history => List.unmodifiable(_history);

  /// 开启随机播放时调用：清空本轮记录，并把当前这首记为「已播」。
  ///
  /// 不这么做的话，刚切到随机模式时可能又抽到正在播的这首。
  void reset(String? currentId) {
    _history.clear();
    if (currentId != null && currentId.isNotEmpty) {
      _history.add(currentId);
    }
  }

  /// 挑下一首，返回队列索引；队列不足两首或无可选时返回 null。
  ///
  /// - [length]：队列长度
  /// - [idAt]：按索引取歌曲 id
  /// - [currentId]：当前播放的歌曲 id（会被排除）
  ///
  /// 队列增删（漫游追加、超长裁剪）后，历史里已不存在的 id 会自动剔除；
  /// 历史长度追平队列长度说明一轮已放完，自动重开一轮。
  int? pick(int length, String Function(int index) idAt, String? currentId) {
    if (length <= 1) return null;
    final ids = <String>{for (var i = 0; i < length; i++) idAt(i)};
    _history.removeWhere((id) => !ids.contains(id));
    if (_history.length >= length) _history.clear();

    var candidates = _candidates(length, idAt, currentId, skipPlayed: true);
    if (candidates.isEmpty) {
      // 一轮放完了（或除当前这首以外都放过了）：重开一轮再挑。
      _history.clear();
      candidates = _candidates(length, idAt, currentId, skipPlayed: false);
      if (candidates.isEmpty) return null;
    }
    final picked = candidates[_random.nextInt(candidates.length)];
    _history.add(idAt(picked));
    return picked;
  }

  /// 随机模式下的「上一首」：返回本轮上一首播过的歌的索引（历史出栈）。
  ///
  /// 随机播放的「上一首」本来就该是刚听过的那首，而不是队列里排在前面的那首。
  /// 历史不足两条（刚开始随机、或队列已变）时返回 null，调用方回退到顺序上一首。
  int? backIndex(int length, String Function(int index) idAt) {
    if (_history.length < 2) return null;
    final backId = _history[_history.length - 2];
    for (var i = 0; i < length; i++) {
      if (idAt(i) == backId) {
        _history.removeLast();
        return i;
      }
    }
    return null;
  }

  List<int> _candidates(
    int length,
    String Function(int index) idAt,
    String? currentId, {
    required bool skipPlayed,
  }) {
    final out = <int>[];
    for (var i = 0; i < length; i++) {
      final id = idAt(i);
      if (currentId != null && id == currentId) continue;
      if (skipPlayed && _history.contains(id)) continue;
      out.add(i);
    }
    return out;
  }
}
