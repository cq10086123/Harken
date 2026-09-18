import 'package:flutter/foundation.dart';

import '../../../state/song_state.dart';

/// 本地导入内容的媒体类型。
///
/// 为什么要识别：本地曲库既可能是**音乐专辑**（该按轨道号/歌名排）也可能是
/// **有声书**（该按集数排），两者的正确默认行为完全不同。此前代码直接把
/// 「本地专辑」等同于「有声书」（默认集数排序），音乐专辑会被按集数乱排。
///
/// 识别必须自动完成——用户导入的是文件夹，不会去手动标注类型。
enum LocalMediaKind {
  audiobook('有声书'),
  music('音乐');

  const LocalMediaKind(this.label);

  /// 展示名（专辑详情页标出来，方便用户确认识别是否正确）。
  final String label;
}

/// **严格**集数命名模式：只有这些才算「有声书式命名」。
///
/// 注意与排序用的 `episodeNumberOf` 区分：排序可以宽松（识别不出就退化为
/// 取标题里第一串数字），但**类型识别必须严格**——否则像
/// 「2026年的第一场雪」「Love 2000」这类带数字的歌名会被当成集数，
/// 把整张音乐专辑误判成有声书。
final List<RegExp> strictEpisodePatterns = [
  // 第1集 / 第十二回 / 第003章 / 第5话
  RegExp(r'第\s*[0-9一二三四五六七八九十百千零两]{1,6}\s*[集话回章部节期卷]'),
  // EP01 / Track 4 / Vol.3
  RegExp(r'(?:\bEP|\bep|\bEp|\bTrack|\btrack|\bVOL|\bVol|\bvol)'
      r'\s*[._-]?\s*\d{1,4}\b'),
  // 001、标题 / 12-标题 / 07.标题（行首编号 + 标点分隔）
  RegExp(r'^\s*\d{1,4}\s*[、.．:：\-_]'),
  // 001 标题（零填充编号 + 空格，常见于导出音频）
  RegExp(r'^\s*0\d{1,3}\s+\S'),
];

/// 标题是否属于「有声书式」的集数命名。
bool isEpisodeStyleTitle(String title) =>
    strictEpisodePatterns.any((p) => p.hasMatch(title));

/// 识别一组本地歌曲属于有声书还是音乐。
///
/// 判据（本地文件常常没有完整标签，所以只用**在无标签文件上依然可靠**的信号）：
/// - 标题命中严格集数写法的比例（最强信号）；
/// - 单集平均时长（有声书单集通常 ≥ 8 分钟，歌曲 3–6 分钟）；
/// - 是否带真实歌手标签、是否有轨道号（两者都指向「音乐专辑」）。
///
/// `artist` / `trackNumber` 在本地扫描结果里经常为空（实测样本 167 首全空），
/// 所以它们只做扣分项，不足以单独判定。得分 ≥ 4 判为有声书，否则音乐。
LocalMediaKind detectLocalMediaKind(List<SongEntity> songs) {
  if (songs.isEmpty) return LocalMediaKind.music;

  final episodeHits = songs.where((s) => isEpisodeStyleTitle(s.title)).length;
  final episodeRatio = episodeHits / songs.length;

  final durations = songs
      .map((s) => s.durationMs)
      .whereType<int>()
      .where((d) => d > 0)
      .toList(growable: false);
  final avgMinutes = durations.isEmpty
      ? null
      : durations.reduce((a, b) => a + b) / durations.length / 60000.0;

  final artistRatio =
      songs.where((s) => _hasRealArtist(s)).length / songs.length;
  final trackRatio =
      songs.where((s) => (s.trackNumber ?? 0) > 0).length / songs.length;

  var score = 0;
  // 标题是最强信号：整册都是「第N集」写法时，即使单集只有几分钟
  // （短篇有声书/播客很常见）也应判为有声书。
  if (episodeRatio >= 0.6) {
    score += 5;
  } else if (episodeRatio >= 0.3) {
    score += 2;
  }
  if (avgMinutes != null) {
    if (avgMinutes >= 8) {
      score += 3;
    } else if (avgMinutes >= 5) {
      score += 1;
    } else if (avgMinutes <= 6 && episodeRatio < 0.3) {
      // 短时长只在「标题不像集数」时才是音乐的证据。
      score -= 1;
    }
  }
  if (artistRatio >= 0.5) score -= 3;
  if (trackRatio >= 0.5) score -= 2;

  final kind = score >= 4 ? LocalMediaKind.audiobook : LocalMediaKind.music;
  debugPrint(
    '[LocalMediaKind] ${songs.length} 首 → ${kind.label} '
    '(集数比例 ${episodeRatio.toStringAsFixed(2)}, '
    '平均时长 ${avgMinutes?.toStringAsFixed(1) ?? "?"} 分钟, '
    '歌手标签 ${artistRatio.toStringAsFixed(2)}, '
    '轨道号 ${trackRatio.toStringAsFixed(2)}, 得分 $score)',
  );
  return kind;
}

bool _hasRealArtist(SongEntity song) {
  final name = song.artistDisplayName.trim();
  if (name.isEmpty) return false;
  return name != '未知艺术家' && name != '未知歌手';
}
