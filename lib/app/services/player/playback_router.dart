import 'package:flutter/foundation.dart';

import '../feiniu/transcode_service.dart';
import '../../state/settings_playback_engine_state.dart';
import '../../state/song_state.dart';
import 'player_engine.dart';

/// 播放引擎路由：决定每首歌由哪个引擎解码。
///
/// 原则：**能系统解码的就用系统解码（just_audio），只有系统解码不了的才用
/// media_kit（FFmpeg 软解）**。
///
/// - **just_audio**（默认）：普通 FLAC、mp3/aac/m4a/ogg/wav/opus、未知/空格式
///   ——直连流 + 缓存，ExoPlayer 系统解码器处理。
/// - **media_kit**：
///   - 黑名单格式（dsf/dff/dsd/wma/ape/dts/aiff…）：ExoPlayer 原生无法解码，
///     media_kit 直连原始流，FFmpeg 软解。
///   - codec 未知 + 可疑容器（m4a/aac/mp4/mkv…）的**在线**歌曲：首发即
///     media_kit，杜绝「先跑系统解码、再中途升级引擎」造成的中断与进度
///     回退。**本地歌曲不适用此规则**（容器格式由扩展名确定，系统解码
///     器处理本地 m4a/aac 是标准能力），仍走 just_audio 硬件解码。
///   - 黑名单 codec（eac3/ac3/alac/dts/truehd/mlp…）：M4A/MP4 容器内常见的
///     环绕声/无损编码，ExoPlayer 设备解码器支持因设备而异（解码器不可用或
///     静默失败时进度条走但无声音），media_kit（FFmpeg）必定出声。
///   - **运行时升级**的歌曲（见 PlayerService `_mediaKitEscalateSongIds`）：
///     普通 FLAC 若 ExoPlayer 解码触发 32KB 帧缓冲超限（`Buffer too small`），
///     当场升级到 media_kit 无损解码。**只有这类 FLAC 才走 media_kit**。
///
/// 未知/空格式走 just_audio 直连（与现状一致）：格式探测延后，播放出错由
/// 引擎错误处理兜底。
///
/// **用户手动模式优先**：设置 → 解码引擎 选定后，上方全部规则让位——
/// [PlaybackEngineMode.system] 一律 just_audio，[PlaybackEngineMode.ffmpeg]
/// 一律 media_kit（桌面端除外，桌面端恒 media_kit）。
EngineKind routeForFormat(
  String? format, {
  String? codec,
  bool isLocal = false,
}) {
  // 桌面端（Windows/macOS/Linux）全量走 media_kit（libmpv + FFmpeg）：
  // - Windows：just_audio（ExoPlayer）无原生实现；
  // - macOS：流需携带认证头，AVPlayer 不可靠；
  // 任意格式都能软解，且显式带 httpHeaders。
  // 用 defaultTargetPlatform 而非 Platform.isWindows：单测默认 TargetPlatform.android。
  if (!kIsWeb &&
      (defaultTargetPlatform == TargetPlatform.windows ||
          defaultTargetPlatform == TargetPlatform.macOS ||
          defaultTargetPlatform == TargetPlatform.linux)) {
    return EngineKind.mediaKit;
  }
  // 用户手动指定的全局解码引擎：显式选择优先于下方全部自动规则。
  // - system → 全部系统解码（ExoPlayer，硬件解码省电）
  // - ffmpeg → 全部 media_kit（FFmpeg 软解，兼容性最好）
  final manualMode = AppPlaybackEngineSettings.mode.value;
  if (manualMode == PlaybackEngineMode.system) return EngineKind.justAudio;
  if (manualMode == PlaybackEngineMode.ffmpeg) return EngineKind.mediaKit;

  // codec 判断优先：eac3/ac3/alac 等 ExoPlayer 设备解码不可靠的编码直接
  // 走 media_kit（FFmpeg），即使容器是 m4a（format 不在黑名单）。
  if (FeiNiuTranscodeService.isMediaKitCodec(codec)) {
    return EngineKind.mediaKit;
  }
  // codec 未知 + 可疑容器（m4a/m4b/mp4/aac/mkv…）：ExoPlayer 设备解码器
  // 可能静默失败。旧策略是「先在系统解码器上跑，约 3 秒后再升级
  // media_kit」——设备解码正常时纯属误伤，且切换瞬间的 seek 失败会让
  // 整首歌从头重播。改为**路由层首发 media_kit**：没有中途切换就没有
  // 中断，任何设备都必定出声。
  // 仅对**在线**歌曲生效：本规则的出发点是远程流的 codec 标记常缺失、
  // 设备解码器可能静默失败；本地文件的容器格式由扩展名确定，套用此规则
  // 只会让本地 m4a/aac 白白走 FFmpeg 软解（多耗 CPU/电量）。
  if (!isLocal &&
      codec == null &&
      FeiNiuTranscodeService.isRiskySilenceContainer(format)) {
    return EngineKind.mediaKit;
  }
  if (format == null || format.isEmpty) return EngineKind.justAudio;
  final f = format.trim().toLowerCase();
  // 普通 FLAC 走系统解码（just_audio），不强制 media_kit。
  return FeiNiuTranscodeService.isMediaKitFormat(f)
      ? EngineKind.mediaKit
      : EngineKind.justAudio;
}

/// 解析歌曲格式与编码后返回引擎类型。格式/编码解析走 `resolvedFormatFor` /
/// `resolvedCodecFor`（会话内缓存），对列表接口已带 `audioSpec.format` /
/// `audioSpec.codec` 的曲目零网络开销。
Future<EngineKind> routeForSong(SongEntity song) async {
  final format = await FeiNiuTranscodeService.instance.resolvedFormatFor(song);
  final codec = await FeiNiuTranscodeService.instance.resolvedCodecFor(song);
  return routeForFormat(format, codec: codec, isLocal: song.isLocal);
}
