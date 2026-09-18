import 'package:flutter_test/flutter_test.dart';

import 'package:feiniu_music/app/services/source/source_caps.dart';
import 'package:feiniu_music/app/services/source/source_config.dart';
import 'package:feiniu_music/app/services/source/source_kind.dart';

void main() {
  group('normalizeWebDavEndpoint', () {
    test('缺 scheme 时补 https', () {
      expect(normalizeWebDavEndpoint('nas.lan/dav'), 'https://nas.lan/dav');
    });

    test('去掉结尾斜杠，使两种写法归一为同一个键', () {
      expect(
        normalizeWebDavEndpoint('https://nas.lan/dav/'),
        normalizeWebDavEndpoint('https://nas.lan/dav'),
      );
      expect(normalizeWebDavEndpoint('https://nas.lan/dav/'), 'https://nas.lan/dav');
    });

    test('根路径不产生裸斜杠', () {
      expect(normalizeWebDavEndpoint('https://nas.lan/'), 'https://nas.lan');
    });

    test('保留显式非默认端口', () {
      expect(
        normalizeWebDavEndpoint('https://nas.lan:5006/dav'),
        'https://nas.lan:5006/dav',
      );
    });

    test('http 保留（内网明文 WebDAV 常见）', () {
      expect(normalizeWebDavEndpoint('http://192.168.1.5/dav'), 'http://192.168.1.5/dav');
    });

    test('默认端口不写进结果', () {
      expect(normalizeWebDavEndpoint('https://nas.lan:443/dav'), 'https://nas.lan/dav');
      expect(normalizeWebDavEndpoint('http://nas.lan:80/dav'), 'http://nas.lan/dav');
    });

    test('空串返回空串', () {
      expect(normalizeWebDavEndpoint(''), '');
      expect(normalizeWebDavEndpoint('   '), '');
    });
  });

  group('AudioSourceKind', () {
    test('idPrefix 与音源类型对应，可用于 sourceId 前缀判断', () {
      expect(AudioSourceKind.feiniu.idPrefix, 'feiniu');
      expect(AudioSourceKind.local.idPrefix, 'local');
      expect(AudioSourceKind.webdav.idPrefix, 'webdav');
    });

    test('只有 local 是本地文件', () {
      expect(AudioSourceKind.local.isLocalFile, isTrue);
      expect(AudioSourceKind.feiniu.isLocalFile, isFalse);
      expect(AudioSourceKind.webdav.isLocalFile, isFalse);
    });

    test('audioSourceKindFromName 未知值返回 null', () {
      expect(audioSourceKindFromName('webdav'), AudioSourceKind.webdav);
      expect(audioSourceKindFromName('smb'), isNull);
      expect(audioSourceKindFromName(null), isNull);
    });
  });

  group('AudioSourceConfig JSON 往返', () {
    test('WebDAV 配置无损往返', () {
      const src = WebDavSourceConfig(
        id: 'webdav-1',
        name: '家里 NAS',
        endpoint: 'https://nas.lan/dav',
        altEndpoints: ['https://nas.example.com/dav'],
        username: 'user',
        password: 'pw',
        path: '/music',
        includeFolders: ['/music/flac'],
        excludeFolders: ['/music/tmp'],
        scrapeTagsOnScan: false,
        ignoreSsl: true,
      );
      final back = AudioSourceConfig.fromJson(src.toJson());
      expect(back, isA<WebDavSourceConfig>());
      final w = back! as WebDavSourceConfig;
      expect(w.id, 'webdav-1');
      expect(w.name, '家里 NAS');
      expect(w.endpoint, 'https://nas.lan/dav');
      expect(w.altEndpoints, ['https://nas.example.com/dav']);
      expect(w.username, 'user');
      expect(w.password, 'pw');
      expect(w.path, '/music');
      expect(w.includeFolders, ['/music/flac']);
      expect(w.excludeFolders, ['/music/tmp']);
      expect(w.scrapeTagsOnScan, isFalse);
      expect(w.ignoreSsl, isTrue);
      expect(w.kind, AudioSourceKind.webdav);
    });

    test('本地配置无损往返', () {
      const src = LocalSourceConfig(
        id: 'local-1',
        name: '手机存储',
        useSystemLibrary: false,
        minDurationMs: 30000,
        includePaths: ['/sdcard/Music', '/mnt/usb'],
        cacheArtwork: false,
        readFullTagsOnScan: false,
        lastScanCount: 128,
      );
      final back = AudioSourceConfig.fromJson(src.toJson())! as LocalSourceConfig;
      expect(back.useSystemLibrary, isFalse);
      expect(back.minDurationMs, 30000);
      expect(back.includePaths, ['/sdcard/Music', '/mnt/usb']);
      expect(back.cacheArtwork, isFalse);
      expect(back.readFullTagsOnScan, isFalse);
      expect(back.lastScanCount, 128);
      expect(back.kind, AudioSourceKind.local);
    });

    test('飞牛配置无损往返', () {
      const src = FeiniuSourceConfig(
        id: 'feiniu-default',
        name: '飞牛音乐',
      );
      final back = AudioSourceConfig.fromJson(src.toJson())! as FeiniuSourceConfig;
      expect(back.id, 'feiniu-default');
      expect(back.name, '飞牛音乐');
      expect(back.enabled, isTrue);
      expect(back.kind, AudioSourceKind.feiniu);
    });

    test('飞牛为单账号模式：配置不携带账号维度', () {
      // 单账号决策下，飞牛音源恒为一条隐式条目，不该有 accountId 这类字段。
      // 这条断言防止将来又把账号维度接回音源模型。
      const src = FeiniuSourceConfig(id: 'feiniu-default', name: '飞牛音乐');
      expect(src.toJson().keys, isNot(contains('accountId')));
    });

    test('未知 kind / 缺 ID / 缺 endpoint 的脏数据被丢弃而不是抛错', () {
      expect(AudioSourceConfig.fromJson({'kind': 'smb', 'id': 'x'}), isNull);
      expect(AudioSourceConfig.fromJson({'kind': 'webdav', 'id': ''}), isNull);
      expect(
        AudioSourceConfig.fromJson({'kind': 'webdav', 'id': 'w1'}),
        isNull,
        reason: 'WebDAV 缺 endpoint 必须丢弃',
      );
      expect(AudioSourceConfig.fromJson({}), isNull);
    });

    test('缺 name 时回落到类型默认名', () {
      final w = AudioSourceConfig.fromJson({
        'kind': 'webdav',
        'id': 'w1',
        'endpoint': 'https://nas.lan/dav',
      })! as WebDavSourceConfig;
      expect(w.name, AudioSourceKind.webdav.title);

      final l = AudioSourceConfig.fromJson({
        'kind': 'local',
        'id': 'l1',
      })! as LocalSourceConfig;
      expect(l.name, AudioSourceKind.local.title);
    });

    test('enabled 缺省为 true，显式 false 才停用', () {
      final on = AudioSourceConfig.fromJson({
        'kind': 'local',
        'id': 'l1',
      })!;
      expect(on.enabled, isTrue);

      final off = AudioSourceConfig.fromJson({
        'kind': 'local',
        'id': 'l2',
        'enabled': false,
      })!;
      expect(off.enabled, isFalse);
    });

    test('列表字段里的空串与非字符串被清掉', () {
      final l = AudioSourceConfig.fromJson({
        'kind': 'local',
        'id': 'l1',
        'includePaths': ['/a', '', '   ', 42],
      })! as LocalSourceConfig;
      expect(l.includePaths, ['/a', '42']);
    });

    test('allEndpoints 规范化并去重，主地址排首位', () {
      const src = WebDavSourceConfig(
        id: 'w1',
        name: 'n',
        endpoint: 'nas.lan/dav/',
        altEndpoints: ['https://nas.lan/dav', 'https://tunnel.example/dav'],
      );
      expect(src.allEndpoints, [
        'https://nas.lan/dav',
        'https://tunnel.example/dav',
      ]);
    });

    test('copyWith 只改指定字段', () {
      const src = WebDavSourceConfig(
        id: 'w1',
        name: 'n',
        endpoint: 'https://nas.lan/dav',
        username: 'u',
        password: 'p',
        path: '/music',
      );
      final renamed = src.copyWith(name: '公司 NAS', enabled: false);
      expect(renamed.name, '公司 NAS');
      expect(renamed.enabled, isFalse);
      expect(renamed.endpoint, 'https://nas.lan/dav');
      expect(renamed.username, 'u');
      expect(renamed.path, '/music');
    });
  });

  group('AudioSourceCaps', () {
    test('飞牛具备全部服务端能力', () {
      final caps = AudioSourceCaps.defaultsFor(AudioSourceKind.feiniu);
      expect(caps.serverFavorites, isTrue);
      expect(caps.serverPlaylists, isTrue);
      expect(caps.serverTranscode, isTrue);
      expect(caps.serverLyrics, isTrue);
      expect(caps.roaming, isTrue);
      expect(caps.metadataEdit, isTrue);
      expect(caps.serverPagination, isTrue);
    });

    test('本地与 WebDAV 无服务端能力、无服务端分页', () {
      for (final kind in [AudioSourceKind.local, AudioSourceKind.webdav]) {
        final caps = AudioSourceCaps.defaultsFor(kind);
        expect(caps.serverFavorites, isFalse, reason: '$kind');
        expect(caps.serverPlaylists, isFalse, reason: '$kind');
        expect(caps.serverTranscode, isFalse, reason: '$kind');
        expect(caps.serverLyrics, isFalse, reason: '$kind');
        expect(caps.roaming, isFalse, reason: '$kind');
        expect(caps.serverPagination, isFalse, reason: '$kind');
        expect(caps.browseFolders, isTrue, reason: '$kind');
      }
    });

    test('只有 WebDAV 支持多地址容灾', () {
      expect(
        AudioSourceCaps.defaultsFor(AudioSourceKind.webdav).multiEndpoint,
        isTrue,
      );
      expect(
        AudioSourceCaps.defaultsFor(AudioSourceKind.local).multiEndpoint,
        isFalse,
      );
      expect(
        AudioSourceCaps.defaultsFor(AudioSourceKind.feiniu).multiEndpoint,
        isFalse,
      );
    });

    test('copyWith 覆盖单项能力（只读服务器禁收藏）', () {
      final caps = AudioSourceCaps.defaultsFor(
        AudioSourceKind.webdav,
      ).copyWith(serverFavorites: true);
      expect(caps.serverFavorites, isTrue);
      expect(caps.browseFolders, isTrue);
    });
  });
}
