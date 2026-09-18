import 'package:flutter_test/flutter_test.dart';
import 'package:feiniu_music/app/services/source/webdav/webdav_client.dart';
import 'package:feiniu_music/app/services/source/webdav/webdav_scanner.dart';

void main() {
  group('parsePropfind', () {
    test('标准 D: 前缀（多集合）', () {
      const body = '''
<?xml version="1.0" encoding="utf-8"?>
<D:multistatus xmlns:D="DAV:">
  <D:response>
    <D:href>/dav/Music/</D:href>
    <D:propstat><D:prop><D:resourcetype><D:collection/></D:resourcetype></D:prop></D:propstat>
  </D:response>
  <D:response>
    <D:href>/dav/Music/%E5%91%A8%E5%90%8C%20-%20%E5%A4%A7%E9%B1%BC.mp3</D:href>
    <D:propstat><D:prop>
      <D:resourcetype/>
      <D:getcontentlength>4021003</D:getcontentlength>
      <D:getlastmodified>Wed, 01 Jul 2026 08:00:00 GMT</D:getlastmodified>
    </D:prop></D:propstat>
  </D:response>
</D:multistatus>
''';
      final items = parsePropfind(body);
      expect(items.length, 2);

      final dir = items[0];
      expect(dir.isDirectory, isTrue);
      expect(dir.path, '/dav/Music/');

      final file = items[1];
      expect(file.isDirectory, isFalse);
      // href 是 URL 编码的 → 解码回「周同 - 大鱼.mp3」
      expect(file.path, '/dav/Music/周同 - 大鱼.mp3');
      expect(file.size, 4021003);
      expect(file.modified, isNotNull);
      expect(file.modified!.year, 2026);
      expect(file.name, '周同 - 大鱼.mp3');
    });

    test('无前缀默认命名空间 + 完整 URL href', () {
      const body = '''
<?xml version="1.0" encoding="utf-8"?>
<multistatus xmlns="DAV:">
  <response>
    <href>https://nas.lan:5006/dav/a.flac</href>
    <propstat><prop><resourcetype/></prop></propstat>
  </response>
</multistatus>
''';
      final items = parsePropfind(body);
      expect(items.length, 1);
      expect(items.first.isDirectory, isFalse);
      expect(items.first.path, '/dav/a.flac');
    });

    test('非法 XML 返回空列表（不抛异常）', () {
      expect(parsePropfind('not xml <'), isEmpty);
    });

    test('文件名含 # 不被当 fragment 吃掉（路径已编码）', () {
      const body = '''
<D:multistatus xmlns:D="DAV:">
  <D:response>
    <D:href>/dav/C%23%20Greatest/01%20C%23.mp3</D:href>
    <D:propstat><D:prop><D:resourcetype/></D:prop></D:propstat>
  </D:response>
</D:multistatus>
''';
      final items = parsePropfind(body);
      expect(items.single.path, '/dav/C# Greatest/01 C#.mp3');
    });
  });

  group('normalizeDirPath / encodedPath', () {
    test('目录路径归一', () {
      expect(normalizeDirPath(''), '');
      expect(normalizeDirPath('/'), '');
      expect(normalizeDirPath('/Music/'), '/Music');
      expect(normalizeDirPath('Music'), '/Music');
    });

    test('路径编码保留分隔符', () {
      expect(encodedPath('/a b/中文名.mp3'), '/a%20b/%E4%B8%AD%E6%96%87%E5%90%8D.mp3');
    });
  });

  group('webdavAuthHeaders', () {
    test('匿名不发 Authorization', () {
      expect(webdavAuthHeaders('', ''), isEmpty);
    });

    test('有账号密码发 Basic', () {
      final h = webdavAuthHeaders('user', 'pass');
      expect(h['Authorization'], 'Basic dXNlcjpwYXNz');
    });
  });

  group('webdavSongId', () {
    test('与 endpoint 无关、与 sourceId 绑定、大小写归一', () {
      expect(
        webdavSongId('webdav-1', '/Music/A/01.mp3'),
        webdavSongId('webdav-1', 'Music/a/01.mp3'),
        reason: '路径大小写归一（服务器路径等价性按不敏感处理）',
      );
      expect(
        webdavSongId('webdav-1', '/Music/a.mp3'),
        isNot(webdavSongId('webdav-2', '/Music/a.mp3')),
        reason: '不同音源同路径不撞车',
      );
    });
  });
}
