/// 音频来源的类型。
///
/// 一个 [AudioSourceKind] 对应一种「音频从哪来」的实现：飞牛 NAS 音乐服务、
/// 本机文件系统、WebDAV 服务器。三种可以同时启用并存（见 `AudioSourceRegistry`），
/// 每首歌通过 `SongEntity.sourceId` 归属到具体某一个音源实例。
library;

enum AudioSourceKind {
  /// 飞牛私有云（fnOS）音乐服务。唯一具备服务端分页 / 服务端收藏 /
  /// 服务端歌单 / 服务端转码 / 随机漫游能力的音源。
  feiniu,

  /// 本机文件系统。Android 走 MediaStore（`photo_manager`）或自定义目录递归，
  /// iOS 走媒体库或文件 App 授权目录，桌面端直接递归任意目录。
  local,

  /// WebDAV 服务器。浏览用 PROPFIND，播放直接 HTTP GET + Basic Auth
  /// （不需要 WebDAV 协议本身）。
  webdav,
}

extension AudioSourceKindX on AudioSourceKind {
  /// 展示名。
  String get title => switch (this) {
    AudioSourceKind.feiniu => '飞牛音乐',
    AudioSourceKind.local => '本地音乐',
    AudioSourceKind.webdav => 'WebDAV',
  };

  /// 添加音源时的副标题说明。
  String get subtitle => switch (this) {
    AudioSourceKind.feiniu => '连接飞牛 NAS 的音乐服务',
    AudioSourceKind.local => '扫描本机设备上的音频文件',
    AudioSourceKind.webdav => '连接 WebDAV 服务器上的音频文件',
  };

  /// `sourceId` 前缀。
  ///
  /// 音源 ID 形如 `<prefix>-<时间戳>`（见 `PrefsSourceRepository.newId`）。
  /// 前缀让「这首歌属于哪一类音源」可以从 ID 直接判断，无需查配置表——
  /// 播放建队列时每首歌都要问一次，查表会把开销摊到「点一下要等多久」上。
  String get idPrefix => switch (this) {
    AudioSourceKind.feiniu => 'feiniu',
    AudioSourceKind.local => 'local',
    AudioSourceKind.webdav => 'webdav',
  };

  /// 该音源的歌曲是否为本地文件（决定 `SongEntity.isLocal`）。
  bool get isLocalFile => this == AudioSourceKind.local;
}

/// 从持久化字符串解析音源类型；未知值返回 null。
AudioSourceKind? audioSourceKindFromName(String? name) {
  if (name == null) return null;
  for (final kind in AudioSourceKind.values) {
    if (kind.name == name) return kind;
  }
  return null;
}
