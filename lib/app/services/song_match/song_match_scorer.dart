import 'song_match_models.dart';

/// 搜索结果合并排序工具（多源「综合」展示用）。
///
/// 综合 tab 把多源结果合并，**优先按歌曲名+歌手相似度降序**（与搜索关键词
/// 越接近排越前），同分按数据源顺序（客户端启用的平台排序）。

class SongMatchScorer {
  /// 把多源结果合并为「综合」列表。
  ///
  /// [keyword] 为搜索关键词：非空时优先按 title/artist 相似度降序，
  /// 同分按 [sourceOrder]（客户端平台排序）稳定排序；空时纯按源顺序。
  static List<SongMatchResult> mergeRanked(
    List<List<SongMatchResult>> groups, {
    List<String> sourceOrder = const [],
    String keyword = '',
  }) {
    final sourceIndex = <String, int>{
      for (var i = 0; i < sourceOrder.length; i++) sourceOrder[i]: i,
    };
    final flat = groups.expand((g) => g).toList();
    final kw = keyword.trim().toLowerCase();

    int sourceRank(SongMatchResult r) =>
        sourceIndex[r.pluginId] ?? 0x7fffffff;

    flat.sort((a, b) {
      if (kw.isNotEmpty) {
        final sa = _similarity(a, kw);
        final sb = _similarity(b, kw);
        if (sa != sb) return sb.compareTo(sa); // 相似度降序
      }
      // 同分：按数据源顺序（稳定）
      final ia = sourceRank(a);
      final ib = sourceRank(b);
      if (ia != ib) return ia.compareTo(ib);
      return 0;
    });
    return flat;
  }

  /// 结果与搜索关键词的相似度：title 权重 0.65 + artist 权重 0.35。
  static double _similarity(SongMatchResult r, String keyword) {
    final title = r.title.toLowerCase().trim();
    final artist = r.artist.toLowerCase().trim();
    final titleSim = _textSimilarity(title, keyword);
    final artistSim = _textSimilarity(artist, keyword);
    return titleSim * 0.65 + artistSim * 0.35;
  }

  /// 字段与关键词的相似度（0~1）：
  /// - 关键词完全包含该字段 / 该字段包含关键词 → 1.0；
  /// - 否则按字符重叠率。
  static double _textSimilarity(String text, String keyword) {
    if (text.isEmpty) return 0;
    if (keyword.contains(text)) return 1.0;
    if (text.contains(keyword)) return 1.0;
    final tChars = text.runes.toSet();
    final kChars = keyword.runes.toSet();
    final common = tChars.where(kChars.contains).length;
    return common / text.runes.length;
  }
}
