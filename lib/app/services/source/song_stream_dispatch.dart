import '../../state/song_state.dart';

/// 一首歌的取源路径。
///
/// 播放层（`PlayerService._sourceForSong`）据此决定走哪条链路：
/// - [feiniuRemote]：解析飞牛流地址（含 302 预解析、Cookie、缓存、服务端转码、
///   CUE 裁剪）；
/// - [localFile]：直接 `AudioSource.file(uri)`，不碰任何网络。
///
/// 与 `player/playback_router.dart`（决定用哪个**解码引擎**）正交：
/// 本文件决定**字节从哪来**，那边决定**谁来解码**。两者都只依赖 `SongEntity`
/// 的字段，不依赖全局连接状态。
enum SongStreamKind {
  feiniuRemote,
  localFile,
}

/// 判断一首歌的取源路径。
///
/// 纯函数，不读任何单例 —— 这样它可以脱离 Flutter binding 单测，也不会因为
/// 「飞牛当前是否已连接」而改变结论。历史上 `_sourceForSong` 用
/// `api.baseUrl.isNotEmpty` 这个**全局**条件当开关，导致本地文件只有在
/// 「完全没配飞牛服务器」时才能播；改为按歌归属判断后两者可以并存。
///
/// WebDAV 音源落地时在此新增分支（`webdavRemote`），调用方无需改动。
SongStreamKind streamKindFor(SongEntity song) {
  if (song.isLocal) return SongStreamKind.localFile;
  return SongStreamKind.feiniuRemote;
}

/// 是否走飞牛远端链路（缓存 / 转码 / CUE / Cookie 全部只对飞牛有意义）。
bool isFeiniuRemoteSong(SongEntity song) =>
    streamKindFor(song) == SongStreamKind.feiniuRemote;
