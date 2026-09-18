import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 全局解码引擎模式（用户可在「设置 → 解码引擎」手动指定）。
///
/// 为什么需要手动开关：自动路由只能按「格式 + 编码」猜，而同一格式在不同
/// SoC 上的系统解码器支持差异极大——是否真的出声只有本机知道。与其让 App
/// 猜（历史方案是播 3 秒后盲切引擎，反而打断正常播放），不如把选择权给用户。
enum PlaybackEngineMode {
  /// 自动（默认）：按格式/编码智能路由——普通格式走系统解码；无损与黑名单
  /// 编码、「codec 未知 + 可疑容器」首发 FFmpeg。
  auto,

  /// 系统解码优先：全部交系统解码器（ExoPlayer），硬件解码、省电。
  /// 设备对目标格式支持不佳时可能无声；解码失败仍会兜底升级 FFmpeg
  /// （避免卡死在坏源上）。
  system,

  /// FFmpeg 软解码：全部交 media_kit（libmpv + FFmpeg）。兼容性最好、必定
  /// 出声；代价是软件解码稍耗 CPU/电量，且不再走服务器转码。
  ffmpeg,
}

/// 解码引擎设置（全局，跨会话持久化）。
///
/// 引擎路由优先级（由高到低）：
/// 1. 单曲手动指定：歌曲信息面板点「解码」标签，会话级、优先于一切；
/// 2. 本设置：全局手动模式；
/// 3. 自动路由：`playback_router.routeForFormat`；
/// 4. 解码失败兜底：播放出错时升级 FFmpeg 重试（仅在真的失败时触发，
///    不做预防性切换）。
class AppPlaybackEngineSettings {
  static const String _prefsMode = 'playback_engine_mode_v1';

  static final ValueNotifier<PlaybackEngineMode> mode =
      ValueNotifier(PlaybackEngineMode.auto);

  static Future<void>? _loading;

  static Future<void> ensureLoaded() => _loading ??= _doLoad();

  static Future<void> _doLoad() async {
    final prefs = await SharedPreferences.getInstance();
    final saved = prefs.getString(_prefsMode);
    mode.value = PlaybackEngineMode.values.firstWhere(
      (m) => m.name == saved,
      orElse: () => PlaybackEngineMode.auto,
    );
  }

  static Future<void> setMode(PlaybackEngineMode value) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_prefsMode, value.name);
    mode.value = value;
  }

  /// 设置页展示名。
  static String labelOf(PlaybackEngineMode value) {
    switch (value) {
      case PlaybackEngineMode.auto:
        return '自动';
      case PlaybackEngineMode.system:
        return '系统解码（硬件解码）';
      case PlaybackEngineMode.ffmpeg:
        return 'FFmpeg 软解码';
    }
  }

  /// 设置页副标题。
  static String descriptionOf(PlaybackEngineMode value) {
    switch (value) {
      case PlaybackEngineMode.auto:
        return '按格式与编码智能选择，风险格式首发 FFmpeg';
      case PlaybackEngineMode.system:
        return '全部走系统解码器，省电；设备不支持时可能无声';
      case PlaybackEngineMode.ffmpeg:
        return '全部走 FFmpeg 软解，必定出声；稍耗电、跳过服务器转码';
    }
  }
}
