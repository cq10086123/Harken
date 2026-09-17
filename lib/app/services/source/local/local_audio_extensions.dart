import 'package:path/path.dart' as p;

/// 本地扫描收录的音频扩展名（**含点、全小写**）。
///
/// 取「上游 NagoMusic 的列表」∪「本项目 `FeiNiuTranscodeService.unsupportedFormats`
/// 里 media_kit 能软解的格式」的并集：
/// - 上游列表覆盖常规格式（mp3/flac/wav/m4a/aac/ogg/opus/alac/wma）；
/// - 本项目桌面端与 Android 兜底都走 media_kit（FFmpeg），DSF/APE/DTS 等
///   无损/冷门格式本地能直接软解，没有理由在扫描阶段就把它们排除掉
///   （远端场景它们才需要服务端转码）。
const Set<String> localAudioExtensions = {
  // 常规
  '.mp3',
  '.flac',
  '.wav',
  '.m4a',
  '.m4b',
  '.aac',
  '.ogg',
  '.oga',
  '.opus',
  '.alac',
  '.wma',
  '.mp4',
  '.aif',
  '.aiff',
  // media_kit / FFmpeg 可软解的无损与冷门格式
  '.dsf',
  '.dff',
  '.dsd',
  '.ape',
  '.dts',
  '.tta',
  '.ra',
  '.au',
  '.dvf',
  '.dss',
  '.mmf',
};

/// 扫描时跳过的目录名。
///
/// 这些目录里的音频几乎总是缓存/临时产物，收录进来只会污染曲库。
const Set<String> localScanSkippedDirNames = {
  '.git',
  '.svn',
  '.hg',
  '.idea',
  '.vscode',
  '.dart_tool',
  'node_modules',
  '.Trashes',
  '.Spotlight-V100',
  '.fseventsd',
  '\$RECYCLE.BIN',
  'System Volume Information',
  'Android', // Android/data、Android/obb 等应用私有目录
  '@eaDir', // 群晖缩略图目录
  '#recycle', // 群晖回收站
};

/// 该路径的扩展名是否属于收录范围。
///
/// 大小写不敏感（`.FLAC` 与 `.flac` 同等对待）。
bool isLocalAudioFile(String path) {
  return localAudioExtensions.contains(p.extension(path).toLowerCase());
}

/// 该目录名是否应在扫描时整棵跳过。
bool isSkippedDirName(String dirName) {
  return localScanSkippedDirNames.contains(dirName);
}

/// 从路径取小写扩展名（不含点）。用于填 `SongEntity.format`。
///
/// 返回空串表示没有扩展名。
String localFormatOf(String path) {
  return p.extension(path).replaceAll('.', '').toLowerCase();
}
