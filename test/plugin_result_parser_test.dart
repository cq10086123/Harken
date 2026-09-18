import 'package:flutter_test/flutter_test.dart';

import 'package:feiniu_music/app/services/song_match/song_match_models.dart';
import 'package:feiniu_music/app/state/settings_match.dart';

void main() {
  group('parseSongResults', () {
    test('解析直接数组', () {
      final raw = '''
      [
        {"id":"1","title":"歌曲A","artist":"歌手A","album":"专辑A","duration":240000,"picUrl":"https://x/a.jpg"},
        {"id":"2","title":"歌曲B","artist":["歌手B","歌手C"],"album":"专辑B","date":"2024-01-01"}
      ]
      ''';
      final results = parseSongResults(raw, 'com.test', '测试');
      expect(results.length, 2);
      expect(results[0].title, '歌曲A');
      expect(results[0].artist, '歌手A');
      expect(results[0].album, '专辑A');
      expect(results[0].duration, 240000);
      expect(results[0].picUrl, 'https://x/a.jpg');
      expect(results[1].artist, '歌手B/歌手C');
      expect(results[1].date, '2024-01-01');
    });

    test('解析包装对象（items/results/songs/data）', () {
      final raw = '{"items":[{"id":"9","name":"歌曲","singer":"歌手"}]}';
      final results = parseSongResults(raw, 'com.test', '测试');
      expect(results.length, 1);
      expect(results[0].title, '歌曲');
      expect(results[0].artist, '歌手');
    });

    test('requireId=true 时缺 id 的行被过滤', () {
      final raw = '[{"title":"无ID"}]';
      final results = parseSongResults(raw, 'com.test', '测试', requireId: true);
      expect(results, isEmpty);
    });

    test('requireId=false 时缺 id 用 picUrl 兜底', () {
      final raw = '[{"title":"封面","picUrl":"https://x/cover.jpg"}]';
      final results =
          parseSongResults(raw, 'com.test', '测试', requireId: false);
      expect(results.length, 1);
      expect(results[0].id, 'https://x/cover.jpg');
    });

    test('fields 解析', () {
      final raw = '''
      [{"id":"1","title":"歌","fields":{"title":"歌","artist":"歌手","album":"专辑"}}]
      ''';
      final results = parseSongResults(raw, 'com.test', '测试');
      expect(results[0].fields['title'], '歌');
      expect(results[0].normalizedFields['album'], '专辑');
    });
  });

  group('parseLyricsCandidates', () {
    test('API 4：数组候选（rawPlainLrc）', () {
      final raw = '''
      [{"type":"rawPlainLrc","tags":{"ti":"歌曲","ar":"歌手"},"rawPlainLrc":"[00:00.00]第一句"}]
      ''';
      final candidates = parseLyricsCandidates(
        raw,
        'com.test',
        '测试',
        fallbackSong: const {},
      );
      expect(candidates.length, 1);
      expect(candidates[0].displayText, '[00:00.00]第一句');
      expect(candidates[0].title, '歌曲');
    });

    test('API 4：包装对象', () {
      final raw = '''
      {"candidates":[{"type":"rawPlainLrc","tags":{"ti":"歌"},"rawPlainLrc":"[00:00.00]x"}]}
      ''';
      final candidates = parseLyricsCandidates(
        raw,
        'com.test',
        '测试',
        fallbackSong: const {},
      );
      expect(candidates.length, 1);
      expect(candidates[0].displayText, '[00:00.00]x');
    });

    test('API 1-3：裸字符串 → 单候选', () {
      final raw = '"[00:00.00]第一句\\n[00:05.00]第二句"';
      final candidates = parseLyricsCandidates(
        raw,
        'com.test',
        '测试',
        fallbackSong: const {'title': '回退标题', 'artist': '回退歌手'},
      );
      expect(candidates.length, 1);
      expect(candidates[0].displayText, '[00:00.00]第一句\n[00:05.00]第二句');
      expect(candidates[0].title, '回退标题');
    });

    test('structured 格式解析 original 行', () {
      final raw = '''
      [{"type":"structured","tags":{"ti":"歌"},"original":[[0,2000,"第一句"],[2000,4000,"第二句"]],"translated":[[0,2000,"First"]]}]
      ''';
      final candidates = parseLyricsCandidates(
        raw,
        'com.test',
        '测试',
        fallbackSong: const {},
      );
      expect(candidates.length, 1);
      expect(candidates[0].type, 'structured');
      expect(candidates[0].original.length, 2);
      expect(candidates[0].original[0].text, '第一句');
      expect(candidates[0].original[0].startMs, 0);
      expect(candidates[0].translated.length, 1);
      // structured 的 displayText 应拼接成 LRC（3 位毫秒，尾部换行忽略）
      expect(candidates[0].displayText.trim(), '[00:00.000]第一句\n[00:02.000]第二句');
    });

    test('structured 逐字格式：词拼接为整行', () {
      // original 行 payload 是逐字数组 [[ws,we,"字"],...]
      final raw = '''
      [{"type":"structured","tags":{"ti":"歌"},"original":[[204,1145,[[204,356,"然"],[356,499,"后"],[499,644,"呢"],[644,788,","],[788,923,"最"],[923,1077,"后"],[1077,1145,"呢"]]]]}]
      ''';
      final candidates = parseLyricsCandidates(
        raw,
        'com.test',
        '测试',
        fallbackSong: const {},
      );
      expect(candidates.length, 1);
      expect(candidates[0].original.length, 1);
      expect(candidates[0].original[0].text, '然后呢,最后呢',
          reason: '逐字词应拼接为整行文本，不含时间戳');
      expect(candidates[0].displayText.trim(), '[00:00.204]然后呢,最后呢',
          reason: 'displayText 用行开始时间戳 + 整行文本');
      // 逐字：verbatimLrc 每字 [start]字 + 行尾 [end]
      expect(
        candidates[0].verbatimLrc.trim(),
        '[00:00.204]然[00:00.356]后[00:00.499]呢[00:00.644],[00:00.788]最[00:00.923]后[00:01.077]呢[00:01.145]',
        reason: 'verbatimLrc 每字 [start]字，行尾带 [end] 结束时间戳',
      );
      // 增强：enhancedVerbatimLrc [行start] + 每字 <start>字 + 行尾 <end>
      expect(
        candidates[0].enhancedVerbatimLrc.trim(),
        '[00:00.204] <00:00.204>然<00:00.356>后<00:00.499>呢<00:00.644>,<00:00.788>最<00:00.923>后<00:01.077>呢<00:01.145>',
        reason: 'enhancedVerbatimLrc 用 <start>字 + 行尾 <end> 输出增强逐字格式',
      );
      // TTML：ttmlLrc 从 structured 生成 TTML XML
      final ttml = candidates[0].ttmlLrc;
      expect(ttml, contains('<?xml version="1.0" encoding="utf-8"?>'));
      expect(ttml, contains('<tt xmlns="http://www.w3.org/ns/ttml"'));
      expect(ttml, contains('<p begin="00:00:00.204" end="00:00:01.145">'));
      expect(ttml, contains('<span begin="00:00:00.204" end="00:00:00.356">然</span>'));
      expect(ttml, contains('</tt>'));
    });

    test('structured 逐字格式：普通行也带行尾结束时长', () {
      // original 含普通行（词/曲/标题等）+ 逐字行；普通行 `[start]text[end]`
      final raw = '''
      [{"type":"structured","tags":{"ti":"歌"},"original":[
        [10,20,"我等你 - 刘若英"],
        [20,30,"词：瑞业"],
        [25301,31626,[[25301,25831,"不"],[25831,26116,"做"],[26116,26427,"考"],[26427,26831,"虑"],[26831,27161,"也"],[27161,27546,"没"],[27546,27946,"半"],[27946,28931,"点"],[28931,29306,"犹"],[29306,31626,"豫"]]]
      ]}]
      ''';
      final candidates = parseLyricsCandidates(
        raw,
        'com.test',
        '测试',
        fallbackSong: const {},
      );
      // 普通行：`[start]text[end]`（对齐 Lyrico 逐字歌词，每行都有结束时长）
      final verbatim = candidates[0].verbatimLrc.trim();
      expect(verbatim, contains('[00:00.010]我等你 - 刘若英[00:00.020]'));
      expect(verbatim, contains('[00:00.020]词：瑞业[00:00.030]'));
      // 逐字行不受影响：每字 [start]字 + 行尾 [end]
      expect(verbatim, contains('[00:25.301]不[00:25.831]做[00:26.116]考'
          '[00:26.427]虑[00:26.831]也[00:27.161]没[00:27.546]半[00:27.946]点'
          '[00:28.931]犹[00:29.306]豫[00:31.626]'));

      // 增强版：普通行 `[start] <start>text<end>`（对齐 Lyrico 增强逐字）
      final enhanced = candidates[0].enhancedVerbatimLrc.trim();
      expect(enhanced,
          contains('[00:00.010] <00:00.010>我等你 - 刘若英<00:00.020>'));
      expect(enhanced,
          contains('[00:00.020] <00:00.020>词：瑞业<00:00.030>'));
      // 逐字行：`[行start] ` + 每字 <start>字 + 行尾 <end>
      expect(enhanced, contains('[00:25.301] <00:25.301>不<00:25.831>做'
          '<00:26.116>考<00:26.427>虑<00:26.831>也<00:27.161>没<00:27.546>半'
          '<00:27.946>点<00:28.931>犹<00:29.306>豫<00:31.626>'));
    });

    test('structured 翻译/罗马音按行时间戳合并（逐行模式）', () {
      final raw = '''
      [{"type":"structured","tags":{"ti":"歌"},
        "original":[[0,2000,"第一句"],[2000,4000,"第二句"]],
        "translated":[[0,2000,"First"],[2000,4000,"Second"]],
        "romanization":[[0,2000,"Daiichi"],[2000,4000,"Daini"]]}]
      ''';
      final candidates = parseLyricsCandidates(
        raw,
        'com.test',
        '测试',
        fallbackSong: const {},
      );
      final c = candidates[0];
      // 默认包含翻译+罗马音：原文 → 罗马音 → 翻译
      expect(
        c.lyricsFor(LyricMode.plain).trim(),
        '[00:00.000]第一句\n[00:00.000]Daiichi\n[00:00.000]First\n'
        '[00:02.000]第二句\n[00:02.000]Daini\n[00:02.000]Second',
      );
      // 隐藏翻译：仅原文 + 罗马音
      expect(
        c.lyricsFor(LyricMode.plain, includeTranslation: false).trim(),
        '[00:00.000]第一句\n[00:00.000]Daiichi\n[00:02.000]第二句\n[00:02.000]Daini',
      );
      // 仅翻译：只输出翻译行
      expect(
        c.lyricsFor(LyricMode.plain, onlyTranslation: true).trim(),
        '[00:00.000]First\n[00:02.000]Second',
      );
    });
  });
}
