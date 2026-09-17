import 'source_kind.dart';

/// 一个音源实例**能做什么**。
///
/// 页面与设置项按能力显隐，而不是按 [AudioSourceKind] 硬判断——否则每加一种
/// 音源都要回去改所有 `if (kind == ...)`。能力由 provider 声明，UI 只消费。
///
/// 全部字段都是「有则 true」，默认 false，因此新增一种能力时既有 provider
/// 不会被误判为支持。
class AudioSourceCaps {
  /// 收藏状态写服务端（飞牛）；false 时写本地 `songs.isFavorite` 列。
  final bool serverFavorites;

  /// 歌单存服务端（飞牛）；false 时写本地 `playlists` / `playlist_songs` 表。
  final bool serverPlaylists;

  /// 服务端转码可用（飞牛）。false 时 DSF/APE 等格式只能 media_kit 软解。
  final bool serverTranscode;

  /// 服务端歌词可用（飞牛）。false 时只查同名 `.lrc` 旁挂与本地缓存。
  final bool serverLyrics;

  /// 支持目录浏览（本地自定义目录 / WebDAV）。
  final bool browseFolders;

  /// 支持随机漫游（飞牛 `getRoamStart` / `getRoamNext`）。
  final bool roaming;

  /// 支持元数据回写到源头（飞牛 `updateTrackMetadata`）。
  /// 本地文件理论上可写标签，但会改动用户文件，暂不开放。
  final bool metadataEdit;

  /// 取列表走服务端分页（飞牛 `getTrackList(page:, size:)`）。
  ///
  /// 本地与 WebDAV 是「扫描一次拿到整库」，没有分页概念——库页面对它们
  /// 一律走本地 DB 查询。
  final bool serverPagination;

  /// 支持多地址容灾（WebDAV：家里走内网、外出走隧道）。
  final bool multiEndpoint;

  const AudioSourceCaps({
    this.serverFavorites = false,
    this.serverPlaylists = false,
    this.serverTranscode = false,
    this.serverLyrics = false,
    this.browseFolders = false,
    this.roaming = false,
    this.metadataEdit = false,
    this.serverPagination = false,
    this.multiEndpoint = false,
  });

  /// 各类型音源的默认能力。
  ///
  /// provider 可以基于此再覆盖（例如某个只读 WebDAV 服务器禁掉收藏）。
  static AudioSourceCaps defaultsFor(AudioSourceKind kind) {
    return switch (kind) {
      AudioSourceKind.feiniu => const AudioSourceCaps(
        serverFavorites: true,
        serverPlaylists: true,
        serverTranscode: true,
        serverLyrics: true,
        browseFolders: true,
        roaming: true,
        metadataEdit: true,
        serverPagination: true,
      ),
      AudioSourceKind.local => const AudioSourceCaps(
        browseFolders: true,
      ),
      AudioSourceKind.webdav => const AudioSourceCaps(
        browseFolders: true,
        multiEndpoint: true,
      ),
    };
  }

  AudioSourceCaps copyWith({
    bool? serverFavorites,
    bool? serverPlaylists,
    bool? serverTranscode,
    bool? serverLyrics,
    bool? browseFolders,
    bool? roaming,
    bool? metadataEdit,
    bool? serverPagination,
    bool? multiEndpoint,
  }) {
    return AudioSourceCaps(
      serverFavorites: serverFavorites ?? this.serverFavorites,
      serverPlaylists: serverPlaylists ?? this.serverPlaylists,
      serverTranscode: serverTranscode ?? this.serverTranscode,
      serverLyrics: serverLyrics ?? this.serverLyrics,
      browseFolders: browseFolders ?? this.browseFolders,
      roaming: roaming ?? this.roaming,
      metadataEdit: metadataEdit ?? this.metadataEdit,
      serverPagination: serverPagination ?? this.serverPagination,
      multiEndpoint: multiEndpoint ?? this.multiEndpoint,
    );
  }
}
