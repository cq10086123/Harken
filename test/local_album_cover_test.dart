import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import 'package:feiniu_music/app/services/source/local/local_album_cover.dart';
import 'package:feiniu_music/app/services/source/local/local_scanner.dart';

void main() {
  group('pickSidecarCover', () {
    test('folder.jpg 优先于 cover.jpg（Windows/foobar2000 事实标准）', () {
      expect(
        LocalAlbumCover.pickSidecarCover(['cover.jpg', 'folder.jpg']),
        'folder.jpg',
      );
    });

    test('候选按 sidecarBaseNames 顺序，不依赖传入顺序', () {
      expect(
        LocalAlbumCover.pickSidecarCover([
          'art.jpg',
          'album.jpg',
          'front.jpg',
          'cover.jpg',
        ]),
        'cover.jpg',
        reason: 'cover 在候选表里排在 front/album/art 前面',
      );
    });

    test('文件名大小写不敏感（FOLDER.JPG 也算）', () {
      expect(
        LocalAlbumCover.pickSidecarCover(['FOLDER.JPG', 'zzz.png']),
        'FOLDER.JPG',
      );
    });

    test('同基名多扩展名时取字典序第一，保证跨扫描稳定', () {
      expect(
        LocalAlbumCover.pickSidecarCover(['folder.png', 'folder.jpg']),
        'folder.jpg',
      );
    });

    test('没有命名规范的图时退而取字典序第一（有图总比没图好）', () {
      expect(
        LocalAlbumCover.pickSidecarCover(['zebra.png', 'apple.jpg', 'mid.jpg']),
        'apple.jpg',
      );
    });

    test('挑选不依赖传入顺序（Directory.list 顺序在各文件系统上不一致）', () {
      const files = ['x3.jpg', 'x1.jpg', 'x2.jpg'];
      expect(
        LocalAlbumCover.pickSidecarCover(files),
        LocalAlbumCover.pickSidecarCover(files.reversed),
      );
    });

    test('没有图片时返回 null', () {
      expect(LocalAlbumCover.pickSidecarCover(['a.mp3', 'b.flac']), isNull);
      expect(LocalAlbumCover.pickSidecarCover(const []), isNull);
    });

    test('非图片扩展名不被当成封面', () {
      expect(
        LocalAlbumCover.pickSidecarCover(['folder.gif', 'cover.bmp', 'a.jpg']),
        'a.jpg',
      );
    });
  });

  group('isSidecarImageName', () {
    test('jpg/jpeg/png/webp 认，其余不认', () {
      for (final n in ['a.jpg', 'a.JPEG', 'a.png', 'a.webp']) {
        expect(LocalAlbumCover.isSidecarImageName(n), isTrue, reason: n);
      }
      for (final n in ['a.gif', 'a.bmp', 'a.mp3', 'a.lrc', 'noext']) {
        expect(LocalAlbumCover.isSidecarImageName(n), isFalse, reason: n);
      }
    });
  });

  group('directoryOf', () {
    test('取父目录', () {
      expect(
        LocalAlbumCover.directoryOf('/music/周杰伦/范特西/01.flac'),
        '/music/周杰伦/范特西',
      );
    });

    test('Windows 反斜杠也能取对（否则同一专辑会被拆成多组）', () {
      expect(
        LocalAlbumCover.directoryOf(r'C:\Music\Album\01.flac'),
        'C:/Music/Album',
      );
    });

    test('同一目录的两种路径写法归到同一组', () {
      expect(
        LocalAlbumCover.directoryOf('/music/a/1.flac'),
        LocalAlbumCover.directoryOf(r'\music\a\2.flac'),
      );
    });
  });

  group('groupByDirectory', () {
    test('按目录分组，组内保持原顺序', () {
      final groups = LocalAlbumCover.groupByDirectory<String>(
        ['/m/a/1.flac', '/m/b/2.flac', '/m/a/3.flac'],
        (e) => e,
      );

      expect(groups.keys, ['/m/a', '/m/b']);
      expect(groups['/m/a'], ['/m/a/1.flac', '/m/a/3.flac']);
      expect(groups['/m/b'], ['/m/b/2.flac']);
    });

    test('空列表返回空 Map', () {
      expect(
        LocalAlbumCover.groupByDirectory<String>(const [], (e) => e),
        isEmpty,
      );
    });
  });

  group('LocalScanner 顺带收集目录图片', () {
    TestWidgetsFlutterBinding.ensureInitialized();

    late Directory tempDir;

    setUp(() {
      tempDir = Directory.systemTemp.createTempSync('album_cover_test');
    });

    tearDown(() {
      try {
        tempDir.deleteSync(recursive: true);
      } catch (_) {}
    });

    void make(String rel) {
      final f = File(p.join(tempDir.path, rel));
      f.parent.createSync(recursive: true);
      f.writeAsStringSync('x');
    }

    test('同一次遍历就收集到目录里的图片（不做第二遍遍历）', () async {
      make('周杰伦 - 范特西/01.flac');
      make('周杰伦 - 范特西/02.flac');
      make('周杰伦 - 范特西/folder.jpg');

      final result = await const LocalScanner().scanWithCovers([tempDir.path]);

      expect(result.entries, hasLength(2));
      final dir = LocalAlbumCover.directoryOf(result.entries.first.path);
      expect(result.imagesByDirectory[dir], ['folder.jpg']);
    });

    test('图片不会被当成歌曲收录', () async {
      make('a.mp3');
      make('folder.jpg');
      make('back.png');

      final result = await const LocalScanner().scanWithCovers([tempDir.path]);

      expect(result.entries, hasLength(1));
      expect(result.entries.single.path, endsWith('a.mp3'));
    });

    test('多个专辑目录各自收集自己的图', () async {
      make('专辑A/01.flac');
      make('专辑A/cover.jpg');
      make('专辑B/01.flac');
      make('专辑B/folder.png');

      final result = await const LocalScanner().scanWithCovers([tempDir.path]);

      expect(result.imagesByDirectory, hasLength(2));
      final dirs = result.imagesByDirectory.keys.toList();
      expect(dirs.any((d) => d.endsWith('专辑A')), isTrue);
      expect(dirs.any((d) => d.endsWith('专辑B')), isTrue);
      for (final d in dirs) {
        expect(result.imagesByDirectory[d], hasLength(1));
      }
    });

    test('没有图的目录不出现在 imagesByDirectory 里', () async {
      make('无图专辑/01.flac');

      final result = await const LocalScanner().scanWithCovers([tempDir.path]);

      expect(result.entries, hasLength(1));
      expect(result.imagesByDirectory, isEmpty);
    });
  });
}
