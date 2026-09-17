import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:feiniu_music/app/services/source/local/local_song_id.dart';

void main() {
  group('normalizeLocalPath', () {
    test('Windows 反斜杠归一为正斜杠', () {
      expect(
        normalizeLocalPath(r'C:\Music\Album\a.flac'),
        'C:/Music/Album/a.flac',
      );
    });

    test('去掉尾部斜杠', () {
      expect(normalizeLocalPath('/music/'), '/music');
      expect(normalizeLocalPath('/music///'), '/music');
    });

    test('根路径保持为单斜杠，不被削成空串', () {
      expect(normalizeLocalPath('/'), '/');
    });

    test('折叠 . 与 ..', () {
      expect(normalizeLocalPath('/music/./a'), '/music/a');
      expect(normalizeLocalPath('/music/x/../a'), '/music/a');
    });

    test('空串返回空串', () {
      expect(normalizeLocalPath(''), '');
      expect(normalizeLocalPath('   '), '');
    });

    test('同一文件的两种写法归一为同一个字符串', () {
      expect(
        normalizeLocalPath(r'/music/album/a.flac'),
        normalizeLocalPath(r'\music\album\a.flac'),
      );
    });
  });

  group('localSongId', () {
    tearDown(() {
      debugDefaultTargetPlatformOverride = null;
    });

    test('Linux/Android 下保留大小写（文件系统敏感）', () {
      debugDefaultTargetPlatformOverride = TargetPlatform.linux;
      expect(localSongId('/Music/A.flac'), '/Music/A.flac');
      expect(localSongId('/Music/A.flac'), isNot(localSongId('/music/a.flac')));
    });

    test('Windows 下大小写归一（文件系统不敏感）', () {
      debugDefaultTargetPlatformOverride = TargetPlatform.windows;
      expect(
        localSongId(r'C:\Music\A.flac'),
        localSongId(r'c:\music\a.flac'),
      );
    });

    test('macOS 下大小写归一', () {
      debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
      expect(localSongId('/Music/A.flac'), localSongId('/music/a.flac'));
    });

    test('ID 跨调用稳定（重扫不能改变 ID，否则收藏/歌单会丢）', () {
      debugDefaultTargetPlatformOverride = TargetPlatform.linux;
      const path = '/sdcard/Music/周杰伦/范特西/01 爱在西元前.flac';
      expect(localSongId(path), localSongId(path));
    });

    test('含中文与空格的路径原样保留（不转义、不截断）', () {
      debugDefaultTargetPlatformOverride = TargetPlatform.linux;
      const path = '/music/我的 音乐/周杰伦 - 范特西.flac';
      expect(localSongId(path), path);
    });
  });

  group('isLocalFilePath', () {
    test('http(s) 不是本地文件', () {
      expect(isLocalFilePath('https://nas/music/a.flac'), isFalse);
      expect(isLocalFilePath('http://nas/music/a.flac'), isFalse);
    });

    test('绝对路径与相对路径都算本地', () {
      expect(isLocalFilePath('/music/a.flac'), isTrue);
      expect(isLocalFilePath(r'C:\music\a.flac'), isTrue);
      expect(isLocalFilePath('music/a.flac'), isTrue);
    });

    test('空串不算', () {
      expect(isLocalFilePath(''), isFalse);
      expect(isLocalFilePath('   '), isFalse);
    });
  });

  group('stripFileScheme', () {
    test('剥掉 file:// 前缀', () {
      expect(stripFileScheme('file:///music/a.flac'), '/music/a.flac');
    });

    test('Windows 的 file:///C:/... 去掉多余前导斜杠', () {
      expect(stripFileScheme('file:///C:/music/a.flac'), 'C:/music/a.flac');
    });

    test('URL 编码的空格与中文被解码', () {
      expect(stripFileScheme('file:///music/my%20song.flac'), '/music/my song.flac');
    });

    test('非 file URI 原样返回', () {
      expect(stripFileScheme('/music/a.flac'), '/music/a.flac');
      expect(
        stripFileScheme('https://nas/a.flac'),
        'https://nas/a.flac',
      );
    });

    test('含裸 % 的畸形路径不抛异常', () {
      expect(stripFileScheme('file:///music/100%.flac'), isNotNull);
    });
  });
}
