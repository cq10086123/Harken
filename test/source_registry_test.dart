import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:feiniu_music/app/services/source/local/local_source_repository.dart';
import 'package:feiniu_music/app/services/source/source_config.dart';
import 'package:feiniu_music/app/services/source/source_kind.dart';
import 'package:feiniu_music/app/services/source/source_registry.dart';
import 'package:feiniu_music/app/services/source/webdav/webdav_source_repository.dart';
import 'package:feiniu_music/app/state/song_state.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  tearDown(() async {
    await AudioSourceRegistry.instance.resetForTest();
  });

  group('PrefsSourceRepository', () {
    test('空存储返回空列表且不抛错', () async {
      final list = await LocalSourceRepository.instance.loadSources();
      expect(list, isEmpty);
    });

    test('upsert 新增后可按 ID 读回', () async {
      const src = LocalSourceConfig(id: 'local-1', name: '手机存储');
      await LocalSourceRepository.instance.upsert(src);

      final back = await LocalSourceRepository.instance.findById('local-1');
      expect(back, isNotNull);
      expect(back!.name, '手机存储');
      expect(await LocalSourceRepository.instance.loadSources(), hasLength(1));
    });

    test('upsert 同 ID 是整条替换而非追加', () async {
      const a = LocalSourceConfig(id: 'local-1', name: '旧名');
      const b = LocalSourceConfig(id: 'local-1', name: '新名');
      await LocalSourceRepository.instance.upsert(a);
      await LocalSourceRepository.instance.upsert(b);

      final list = await LocalSourceRepository.instance.loadSources();
      expect(list, hasLength(1));
      expect(list.single.name, '新名');
    });

    test('removeById 只删目标条', () async {
      const a = LocalSourceConfig(id: 'local-1', name: 'A');
      const b = LocalSourceConfig(id: 'local-2', name: 'B');
      await LocalSourceRepository.instance.upsert(a);
      await LocalSourceRepository.instance.upsert(b);
      await LocalSourceRepository.instance.removeById('local-1');

      final list = await LocalSourceRepository.instance.loadSources();
      expect(list, hasLength(1));
      expect(list.single.id, 'local-2');
    });

    test('newId 带音源前缀', () {
      expect(
        LocalSourceRepository.instance.newId(),
        startsWith('local-'),
      );
      expect(
        WebDavSourceRepository.instance.newId(),
        startsWith('webdav-'),
      );
    });

    test('持久化到 prefs 的是 JSON 数组', () async {
      const src = WebDavSourceConfig(
        id: 'webdav-1',
        name: 'NAS',
        endpoint: 'https://nas.lan/dav',
      );
      await WebDavSourceRepository.instance.upsert(src);

      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(WebDavSourceRepository.prefsKeyValue);
      expect(raw, isNotNull);
      final decoded = jsonDecode(raw!) as List;
      expect(decoded, hasLength(1));
      expect((decoded.single as Map)['kind'], 'webdav');
      expect((decoded.single as Map)['endpoint'], 'https://nas.lan/dav');
    });

    test('脏数据（缺 ID）被过滤，不影响同批好数据', () async {
      SharedPreferences.setMockInitialValues({
        LocalSourceRepository.prefsKeyValue: jsonEncode([
          {'kind': 'local', 'id': 'local-1', 'name': '好数据'},
          {'kind': 'local', 'name': '没有 id'},
          {'kind': 'local', 'id': '', 'name': '空 id'},
        ]),
      });
      LocalSourceRepository.instance.resetCacheForTest();

      final list = await LocalSourceRepository.instance.loadSources();
      expect(list, hasLength(1));
      expect(list.single.id, 'local-1');
    });

    test('整个列表损坏时降级为空列表而不是抛错', () async {
      SharedPreferences.setMockInitialValues({
        LocalSourceRepository.prefsKeyValue: '这不是 JSON',
      });
      LocalSourceRepository.instance.resetCacheForTest();

      final list = await LocalSourceRepository.instance.loadSources();
      expect(list, isEmpty);
    });

    test('非数组 JSON 降级为空列表', () async {
      SharedPreferences.setMockInitialValues({
        LocalSourceRepository.prefsKeyValue: '{"kind":"local"}',
      });
      LocalSourceRepository.instance.resetCacheForTest();

      expect(await LocalSourceRepository.instance.loadSources(), isEmpty);
    });
  });

  group('AudioSourceRegistry', () {
    test('初始即含隐式飞牛音源，ID 与存量数据归位值一致', () async {
      await AudioSourceRegistry.instance.ensureLoaded();

      final sources = AudioSourceRegistry.instance.sources.value;
      expect(sources, hasLength(1));
      expect(sources.single.id, SongEntity.defaultFeiniuSourceId);
      expect(sources.single.kind, AudioSourceKind.feiniu);
      expect(sources.single.enabled, isTrue);
    });

    test('添加本地与 WebDAV 后三种音源并存', () async {
      await AudioSourceRegistry.instance.ensureLoaded();
      await AudioSourceRegistry.instance.addLocal(
        const LocalSourceConfig(id: 'local-1', name: '手机存储'),
      );
      await AudioSourceRegistry.instance.addWebDav(
        const WebDavSourceConfig(
          id: 'webdav-1',
          name: '家里 NAS',
          endpoint: 'https://nas.lan/dav',
        ),
      );

      final kinds = AudioSourceRegistry.instance.sources.value
          .map((s) => s.kind)
          .toSet();
      expect(kinds, {
        AudioSourceKind.feiniu,
        AudioSourceKind.local,
        AudioSourceKind.webdav,
      });
      expect(AudioSourceRegistry.instance.sources.value, hasLength(3));
    });

    test('configFor 对未知 ID 归位到飞牛，播放分派不会拿到 null', () async {
      await AudioSourceRegistry.instance.ensureLoaded();

      final cfg = AudioSourceRegistry.instance.configFor('完全不存在的 id');
      expect(cfg.kind, AudioSourceKind.feiniu);
      expect(cfg.id, SongEntity.defaultFeiniuSourceId);
    });

    test('kindFor 按 sourceId 前缀正确分派', () async {
      await AudioSourceRegistry.instance.ensureLoaded();
      await AudioSourceRegistry.instance.addLocal(
        const LocalSourceConfig(id: 'local-1', name: 'L'),
      );
      await AudioSourceRegistry.instance.addWebDav(
        const WebDavSourceConfig(
          id: 'webdav-1',
          name: 'W',
          endpoint: 'https://a/dav',
        ),
      );

      final r = AudioSourceRegistry.instance;
      expect(r.kindFor('local-1'), AudioSourceKind.local);
      expect(r.kindFor('webdav-1'), AudioSourceKind.webdav);
      expect(r.kindFor(SongEntity.defaultFeiniuSourceId), AudioSourceKind.feiniu);
    });

    test('setEnabled 停用后从 enabledSources 消失，但配置保留', () async {
      await AudioSourceRegistry.instance.ensureLoaded();
      await AudioSourceRegistry.instance.addLocal(
        const LocalSourceConfig(id: 'local-1', name: 'L'),
      );

      await AudioSourceRegistry.instance.setEnabled('local-1', false);
      expect(
        AudioSourceRegistry.instance.enabledSources.map((s) => s.id),
        isNot(contains('local-1')),
      );
      // 配置仍在，重新启用即可恢复
      expect(
        AudioSourceRegistry.instance.sources.value.map((s) => s.id),
        contains('local-1'),
      );

      await AudioSourceRegistry.instance.setEnabled('local-1', true);
      expect(
        AudioSourceRegistry.instance.enabledSources.map((s) => s.id),
        contains('local-1'),
      );
    });

    test('飞牛隐式条目不可被停用或删除', () async {
      await AudioSourceRegistry.instance.ensureLoaded();

      await AudioSourceRegistry.instance.setEnabled(
        SongEntity.defaultFeiniuSourceId,
        false,
      );
      await AudioSourceRegistry.instance.remove(SongEntity.defaultFeiniuSourceId);

      final sources = AudioSourceRegistry.instance.sources.value;
      expect(sources, hasLength(1));
      expect(sources.single.enabled, isTrue);
    });

    test('remove 只删配置，不动已入库歌曲（删库交给专门的服务）', () async {
      await AudioSourceRegistry.instance.ensureLoaded();
      await AudioSourceRegistry.instance.addWebDav(
        const WebDavSourceConfig(
          id: 'webdav-1',
          name: 'W',
          endpoint: 'https://a/dav',
        ),
      );
      await AudioSourceRegistry.instance.remove('webdav-1');

      expect(
        AudioSourceRegistry.instance.sources.value.map((s) => s.id),
        isNot(contains('webdav-1')),
      );
      // 删除后该 ID 仍能拿到兜底配置，历史歌曲不会因此崩
      expect(
        AudioSourceRegistry.instance.configFor('webdav-1').kind,
        AudioSourceKind.feiniu,
      );
    });

    test('重启后（重新 ensureLoaded）配置从 prefs 恢复', () async {
      await AudioSourceRegistry.instance.ensureLoaded();
      await AudioSourceRegistry.instance.addLocal(
        const LocalSourceConfig(
          id: 'local-9',
          name: '外接盘',
          includePaths: ['/mnt/usb'],
        ),
      );

      await AudioSourceRegistry.instance.resetForTest();
      await AudioSourceRegistry.instance.ensureLoaded();

      final restored = AudioSourceRegistry.instance.configFor('local-9');
      expect(restored, isA<LocalSourceConfig>());
      expect((restored as LocalSourceConfig).includePaths, ['/mnt/usb']);
    });
  });
}
