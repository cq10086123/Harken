import 'package:flutter/material.dart';

import '../../app/services/player_service.dart';
import '../../app/state/settings_playback_engine_state.dart';
import '../../app/state/settings_state.dart';
import '../../components/index.dart';

/// 解码引擎设置页：手动指定全局解码器（自动 / 系统解码 / FFmpeg 软解码）。
///
/// 切换后立即生效：重算队列引擎并保留进度重载当前曲，无需重启 App。
class PlaybackEngineSettingsPage extends StatefulWidget {
  const PlaybackEngineSettingsPage({super.key});

  @override
  State<PlaybackEngineSettingsPage> createState() =>
      _PlaybackEngineSettingsPageState();
}

class _PlaybackEngineSettingsPageState
    extends State<PlaybackEngineSettingsPage> {
  @override
  void initState() {
    super.initState();
    AppPlaybackEngineSettings.ensureLoaded();
  }

  Future<void> _select(PlaybackEngineMode option) async {
    if (option == AppPlaybackEngineSettings.mode.value) return;
    await AppPlaybackEngineSettings.setMode(option);
    // 立即生效：按新引擎重算队列并保留进度重载当前曲。
    await PlayerService.instance.refreshDecoderRouting();
    if (!mounted) return;
    AppToast.show(
      context,
      '已切换到「${AppPlaybackEngineSettings.labelOf(option)}」',
    );
  }

  @override
  Widget build(BuildContext context) {
    final bottomPadding = AppPageScaffold.scrollableBottomPadding(
      context,
      showMiniPlayer: false,
    );
    return AppPageScaffold(
      extendBodyBehindAppBar: true,
      appBar: const AppTopBar(
        title: '解码引擎',
        backgroundColor: Colors.transparent,
        elevation: 0,
      ),
      showMiniPlayer: false,
      body: ValueListenableBuilder<PlaybackEngineMode>(
        valueListenable: AppPlaybackEngineSettings.mode,
        builder: (context, current, _) {
          return ListView(
            padding: EdgeInsets.fromLTRB(16, 12, 16, bottomPadding),
            children: [
              AppSettingSection(
                title: '解码引擎',
                children: [
                  for (final option in PlaybackEngineMode.values)
                    AppSettingTile(
                      title: AppPlaybackEngineSettings.labelOf(option),
                      subtitle: AppPlaybackEngineSettings.descriptionOf(option),
                      trailing: Icon(
                        option == current
                            ? Icons.radio_button_checked_rounded
                            : Icons.radio_button_unchecked_rounded,
                        color: option == current
                            ? Theme.of(context).colorScheme.primary
                            : null,
                      ),
                      onTap: () => _select(option),
                    ),
                ],
              ),
              const SizedBox(height: 16),
              const AppSettingSection(
                title: '说明',
                children: [
                  AppSettingTile(
                    title: '单曲临时切换',
                    subtitle: '歌曲信息面板点「解码」标签可单独指定，仅该曲生效',
                  ),
                  AppSettingTile(
                    title: '解码失败时',
                    subtitle: '仍会自动兜底升级 FFmpeg 重试，不会卡死在坏源上',
                  ),
                  AppSettingTile(
                    title: '桌面端',
                    subtitle: 'Windows / macOS / Linux 恒用 FFmpeg（系统无对应解码实现）',
                  ),
                ],
              ),
            ],
          );
        },
      ),
    );
  }
}
