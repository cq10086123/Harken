import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import 'package:feiniu_music/app/services/source/local/local_audio_extensions.dart';
import 'package:feiniu_music/app/services/source/local/local_scanner.dart';
import 'package:feiniu_music/app/services/source/local/local_song_id.dart';

/// 本地目录扫描。用真实临时目录，跑的是 `LocalScanner` 的真实 `dart:io` 路径。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tempDir;

  setUp(() {
    tempDir = Directory.systemTemp.createTempSync('local_scanner_test');
  });

  tearDown(() {
    try {
      tempDir.deleteSync(recursive: true);
    } catch (_) {}
  });

  File make(String relativePath, {String content = 'x'}) {
    final f = File(p.join(tempDir.path, relativePath));
    f.parent.createSync(recursive: true);
    f.writeAsStringSync(content);
    return f;
  }

  List<String> names(List<LocalScanEntry> entries) =>
      entries.map((e) => p.basename(e.path)).toList()..sort();

  group('isLocalAudioFile / localFormatOf', () {
    test('常规与无损格式都收录', () {
      for (final ext in ['.mp3', '.flac', '.wav', '.m4a', '.dsf', '.ape', '.opus']) {
        expect(isLocalAudioFile('/a/x$ext'), isTrue, reason: ext);
      }
    });

    test('扩展名大小写不敏感', () {
      expect(isLocalAudioFile('/a/x.FLAC'), isTrue);
      expect(isLocalAudioFile('/a/x.Flac'), isTrue);
    });

    test('非音频不收录', () {
      for (final ext in ['.jpg', '.txt', '.cue', '.lrc', '.nfo', '.pdf']) {
        expect(isLocalAudioFile('/a/x$ext'), isFalse, reason: ext);
      }
    });

    test('无扩展名不收录', () {
      expect(isLocalAudioFile('/a/README'), isFalse);
    });

    test('localFormatOf 返回小写、不含点', () {
      expect(localFormatOf('/a/x.FLAC'), 'flac');
      expect(localFormatOf('/a/x.mp3'), 'mp3');
      expect(localFormatOf('/a/README'), '');
    });

    test('isSkippedDirName 命中缓存/系统目录', () {
      for (final n in ['.git', 'node_modules', '@eaDir', '#recycle', 'Android']) {
        expect(isSkippedDirName(n), isTrue, reason: n);
      }
      expect(isSkippedDirName('Music'), isFalse);
    });
  });

  group('LocalScanner.scan', () {
    test('递归收录多层目录里的音频文件', () async {
      make('a.mp3');
      make('sub/b.flac');
      make('sub/deep/c.wav');

      final entries = await const LocalScanner().scan([tempDir.path]);

      expect(names(entries), ['a.mp3', 'b.flac', 'c.wav']);
    });

    test('过滤非音频文件', () async {
      make('a.mp3');
      make('cover.jpg');
      make('notes.txt');
      make('album.lrc');
      make('disc.cue');

      final entries = await const LocalScanner().scan([tempDir.path]);

      expect(names(entries), ['a.mp3']);
    });

    test('整棵跳过 node_modules / .git 等目录', () async {
      make('a.mp3');
      make('node_modules/pkg/song.mp3');
      make('.git/objects/x.mp3');
      make('@eaDir/thumb.mp3');

      final entries = await const LocalScanner().scan([tempDir.path]);

      expect(names(entries), ['a.mp3']);
    });

    test('普通音乐目录不被误跳', () async {
      make('Music/周杰伦/a.flac');
      make('Music/Album Art/b.mp3');

      final entries = await const LocalScanner().scan([tempDir.path]);

      expect(names(entries), ['a.flac', 'b.mp3']);
    });

    test('多个 root 之间的重复文件只收一次', () async {
      make('shared/a.mp3');

      final entries = await const LocalScanner().scan([
        tempDir.path,
        p.join(tempDir.path, 'shared'),
      ]);

      expect(names(entries), ['a.mp3']);
    });

    test('root 本身是单个音频文件时直接收录', () async {
      final f = make('single.mp3');

      final entries = await const LocalScanner().scan([f.path]);

      expect(names(entries), ['single.mp3']);
    });

    test('不存在的 root 被跳过而不是抛异常', () async {
      make('a.mp3');

      final entries = await const LocalScanner().scan([
        p.join(tempDir.path, 'no_such_dir'),
        tempDir.path,
      ]);

      expect(names(entries), ['a.mp3']);
    });

    test('空目录返回空列表', () async {
      final entries = await const LocalScanner().scan([tempDir.path]);
      expect(entries, isEmpty);
    });

    test('携带文件大小与修改时间（增量扫描依赖）', () async {
      make('a.mp3', content: 'abcdefghij');

      final entries = await const LocalScanner().scan([tempDir.path]);

      expect(entries.single.fileSize, 10);
      expect(entries.single.fileModifiedMs, isNotNull);
      expect(entries.single.fileModifiedMs, greaterThan(0));
    });

    test('自定义目录扫描的 assetId 为 null（只有媒体库扫描才有）', () async {
      make('a.mp3');

      final entries = await const LocalScanner().scan([tempDir.path]);

      expect(entries.single.assetId, isNull);
    });

    test('isCancelled 恒 true 时一个文件都不收', () async {
      make('d1/a.mp3');
      make('d2/b.mp3');

      final entries = await const LocalScanner().scan(
        [tempDir.path],
        isCancelled: () => true,
      );

      expect(entries, isEmpty);
    });

    test('isCancelled 中途生效后收不满全部文件', () async {
      make('d1/a.mp3');
      make('d2/b.mp3');
      make('d3/c.mp3');
      make('d4/d.mp3');

      var calls = 0;
      final entries = await const LocalScanner().scan(
        [tempDir.path],
        // 前几次放行，之后取消
        isCancelled: () => ++calls > 2,
      );

      expect(entries.length, lessThan(4), reason: '取消后不应收满 4 个');
    });

    test('onProgress 逐目录回调且计数递增', () async {
      make('a.mp3');
      make('s1/b.mp3');
      make('s2/c.mp3');

      final progress = <LocalScanProgress>[];
      await const LocalScanner().scan(
        [tempDir.path],
        onProgress: progress.add,
      );

      // 至少根目录 + 两个子目录
      expect(progress.length, greaterThanOrEqualTo(3));
      expect(progress.first.dirsVisited, 1);
      expect(progress.last.dirsVisited, progress.length);
      // 回调在「进入目录」时触发：最后一个回调时该目录自己的歌还没收进来
      // （根 + s1 的 2 首已计入），所以 filesFound 是 2 而不是 3。
      expect(progress.last.filesFound, 2);
    });

    test('中文与空格路径正常工作', () async {
      make('我的 音乐/周杰伦 - 范特西/01 爱在西元前.flac');

      final entries = await const LocalScanner().scan([tempDir.path]);

      expect(entries, hasLength(1));
      expect(p.basename(entries.single.path), '01 爱在西元前.flac');
    });

    test('entry.path 已规范化，可直接当 localSongId 用', () async {
      make('a.mp3');

      final entries = await const LocalScanner().scan([tempDir.path]);

      expect(entries.single.path, normalizeLocalPath(entries.single.path));
      expect(localSongId(entries.single.path), isNotEmpty);
    });
  });
}
