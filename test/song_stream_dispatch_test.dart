import 'package:flutter_test/flutter_test.dart';

import 'package:feiniu_music/app/services/source/song_stream_dispatch.dart';
import 'package:feiniu_music/app/state/song_state.dart';

/// 取源分派：决定一首歌的字节从哪来。
///
/// 回归重点是多音源改造前的那个互斥缺陷——旧逻辑用「飞牛是否已连接」这个
/// **全局**状态当开关，导致配了飞牛服务器之后本地文件根本播不了。分派改为
/// 按歌归属判断后，两者必须能并存。
void main() {
  group('streamKindFor', () {
    test('本地歌走文件，不看飞牛连接状态', () {
      const song = SongEntity(
        id: 'l1',
        title: '本地歌',
        artist: '[]',
        uri: '/sdcard/Music/a.flac',
        isLocal: true,
        sourceId: 'local-1',
      );
      expect(streamKindFor(song), SongStreamKind.localFile);
      expect(isFeiniuRemoteSong(song), isFalse);
    });

    test('飞牛歌走远端', () {
      const song = SongEntity(
        id: 'guid-1',
        title: '云端歌',
        artist: '[]',
        uri: 'https://nas/music/api/v1/track/stream?guid=guid-1',
        sourceId: 'feiniu-default',
      );
      expect(streamKindFor(song), SongStreamKind.feiniuRemote);
      expect(isFeiniuRemoteSong(song), isTrue);
    });

    test('存量数据（isLocal 缺省、sourceId 为 NULL）按飞牛处理', () {
      // 老库的行 isLocal=0、sourceId=NULL，必须继续走飞牛，行为不变。
      const legacy = SongEntity(id: 'old', title: 't', artist: 'a');
      expect(legacy.isLocal, isFalse);
      expect(legacy.sourceId, isNull);
      expect(streamKindFor(legacy), SongStreamKind.feiniuRemote);
      expect(legacy.effectiveSourceId, SongEntity.defaultFeiniuSourceId);
    });

    test('uri 是 http 但 isLocal=true 时仍以 isLocal 为准', () {
      // 判定依据是音源归属，不是 uri 长得像什么——避免将来某种本地音源
      // 把 uri 存成 file:// 或 http 形式时分派漂移。
      const song = SongEntity(
        id: 'l2',
        title: 't',
        artist: 'a',
        uri: 'https://example.com/a.flac',
        isLocal: true,
      );
      expect(streamKindFor(song), SongStreamKind.localFile);
    });

    test('isLocal 与 sourceId 独立：只置 sourceId 不置 isLocal 仍算远端', () {
      // sourceId 只表达「归属哪个音源」，是否本地文件由 isLocal 表达。
      // WebDAV 音源的歌会有 sourceId 但不是本地文件。
      const song = SongEntity(
        id: 'w1',
        title: 't',
        artist: 'a',
        uri: 'https://nas/dav/a.flac',
        sourceId: 'webdav-1',
      );
      expect(song.isLocal, isFalse);
      expect(streamKindFor(song), SongStreamKind.webdavRemote,
          reason: 'WebDAV 音源的歌走独立的 Basic Auth 远端链路');
    });

    test('分派是纯函数：同一首歌多次调用结果一致，不受外部状态影响', () {
      const song = SongEntity(
        id: 'l3',
        title: 't',
        artist: 'a',
        uri: '/a.mp3',
        isLocal: true,
      );
      expect(streamKindFor(song), streamKindFor(song));
      expect(isFeiniuRemoteSong(song), isFeiniuRemoteSong(song));
    });
  });
}
