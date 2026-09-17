import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:feiniu_music/app/services/cover_image_provider.dart';
import 'package:feiniu_music/app/state/song_state.dart';

/// 封面取图源分派。
///
/// 只测不碰 `FeiNiuApiClient` 单例的分支（本地文件 / 无封面）；
/// 网络分支要构造单例与 baseUrl，留给真机验证。
void main() {
  group('本地封面', () {
    test('localCoverPath 非空 → FileImage', () {
      const song = SongEntity(
        id: '/music/a.flac',
        title: 't',
        artist: '[]',
        isLocal: true,
        sourceId: 'local-1',
        localCoverPath: '/cache/covers_v2/abc.img',
      );

      final provider = coverImageProviderFor(song);

      expect(provider, isA<FileImage>());
      expect((provider! as FileImage).file.path, '/cache/covers_v2/abc.img');
    });

    test('coverId 为空串时也走本地分支（不被当成有网络封面）', () {
      const song = SongEntity(
        id: '/music/a.flac',
        title: 't',
        artist: '[]',
        coverId: '',
        localCoverPath: '/cache/covers_v2/abc.img',
      );

      expect(coverImageProviderFor(song), isA<FileImage>());
    });
  });

  group('无封面', () {
    test('coverId 与 localCoverPath 都没有 → null（调用方跳过预热）', () {
      const song = SongEntity(id: 'x', title: 't', artist: '[]');

      expect(coverImageProviderFor(song), isNull);
    });

    test('两者都是空串 → null', () {
      const song = SongEntity(
        id: 'x',
        title: 't',
        artist: '[]',
        coverId: '',
        localCoverPath: '   ',
      );

      expect(coverImageProviderFor(song), isNull);
    });

    test('本地歌未落盘封面时返回 null 而不是抛异常', () {
      // 这是扫描时 readFullTagsOnScan=false 或标签里没有内嵌图的常见情形。
      const song = SongEntity(
        id: '/music/a.flac',
        title: 't',
        artist: '[]',
        isLocal: true,
        sourceId: 'local-1',
      );

      expect(() => coverImageProviderFor(song), returnsNormally);
      expect(coverImageProviderFor(song), isNull);
    });
  });
}
