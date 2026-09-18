import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:signals/signals.dart';
import 'song_state.dart';
import '../services/player/player_engine.dart';

enum PlaybackMode {
  shuffle,
  loop,
  single,

  /// 顺序播放：播到队列末尾就停（不回卷、不补链）。
  ///
  /// 追加在枚举末尾而不是插到前面：枚举值可能被持久化，
  /// 插值会打乱已有取值的含义。
  sequential,
}

/// 播放模式循环顺序（点一下切到下一个）：
/// 顺序播放 → 列表循环 → 单曲循环 → 随机播放 → 回到顺序。
PlaybackMode nextPlaybackMode(PlaybackMode current) =>
    switch (current) {
      PlaybackMode.sequential => PlaybackMode.loop,
      PlaybackMode.loop => PlaybackMode.single,
      PlaybackMode.single => PlaybackMode.shuffle,
      PlaybackMode.shuffle => PlaybackMode.sequential,
    };

/// 播放模式中文名（UI 提示用）。
String playbackModeLabel(PlaybackMode mode) => switch (mode) {
      PlaybackMode.sequential => '顺序播放',
      PlaybackMode.loop => '列表循环',
      PlaybackMode.single => '单曲循环',
      PlaybackMode.shuffle => '随机播放',
    };

/// 随机播放的队列重排：**保留 [keepIndex] 及其之前的原顺序**（已经播过的
/// 部分、以及当前正在播的这首都不动），把之后的尾部随机打乱。
///
/// 为什么打乱「顺序」而不是「播完再随机挑一首」：播放引擎把整段同引擎歌曲
/// 作为一个播放列表原生连续播放，中间某首播完是引擎自己前进的，应用层拿不到
/// 插话机会（只有整段结尾才收到 completed 回调）。也就是说在「播完再挑」的
/// 模型下，随机永远只在整段末尾生效一次，听感就是顺序播放。把顺序本身打乱后，
/// 引擎怎么前进都是随机序，而且队列页显示的顺序与实际播放顺序始终一致。
///
/// 纯函数（无副作用、[random] 可注入）→ 见 `test/shuffle_order_test.dart`。
List<T> shuffledTailOrder<T>(List<T> items, int keepIndex, {Random? random}) {
  if (items.length <= 2) return List<T>.of(items);
  final idx = keepIndex < 0
      ? 0
      : (keepIndex >= items.length ? items.length - 1 : keepIndex);
  final head = items.sublist(0, idx + 1);
  final tail = items.sublist(idx + 1).toList()..shuffle(random ?? Random());
  return <T>[...head, ...tail];
}

class PlaybackSnapshot {
  final SongEntity? song;
  final List<SongEntity> queue;
  final int index;
  final bool isPlaying;
  final bool isLoading;
  final Duration position;
  final Duration? duration;
  final Duration bufferedPosition;

  const PlaybackSnapshot({
    required this.song,
    required this.queue,
    required this.index,
    required this.isPlaying,
    this.isLoading = false,
    required this.position,
    required this.duration,
    required this.bufferedPosition,
  });

  factory PlaybackSnapshot.initial() {
    return const PlaybackSnapshot(
      song: null,
      queue: [],
      index: -1,
      isPlaying: false,
      isLoading: false,
      position: Duration.zero,
      duration: null,
      bufferedPosition: Duration.zero,
    );
  }
}

class AppPlayerState {
  // Singleton pattern to be easily accessible, but also can be instantiated if needed
  static final AppPlayerState instance = AppPlayerState._internal();

  AppPlayerState._internal() {
    _initListeners();
  }

  // ValueNotifiers (for Flutter UI binding if needed directly)
  final ValueNotifier<Duration> position = ValueNotifier(Duration.zero);
  final ValueNotifier<Duration?> duration = ValueNotifier(null);
  final ValueNotifier<Duration> bufferedPosition = ValueNotifier(Duration.zero);
  final ValueNotifier<bool> isPlaying = ValueNotifier(false);
  final ValueNotifier<bool> isLoading = ValueNotifier(false);
  final ValueNotifier<List<SongEntity>> queue = ValueNotifier(const []);
  final ValueNotifier<int> currentIndex = ValueNotifier(-1);
  final ValueNotifier<SongEntity?> currentSong = ValueNotifier(null);
  final ValueNotifier<PlaybackSnapshot> snapshot =
      ValueNotifier(PlaybackSnapshot.initial());
  final ValueNotifier<PlaybackMode> playbackMode =
      ValueNotifier(PlaybackMode.loop);
  final ValueNotifier<String?> sleepTimerDisplayText = ValueNotifier(null);
  final ValueNotifier<bool> sleepUntilSongEnd = ValueNotifier(false);

  /// 当前歌曲使用的解码引擎（just_audio / media_kit）。
  /// UI 在"更多面板"展示当前解码方式。
  final ValueNotifier<EngineKind> decoderEngine =
      ValueNotifier(EngineKind.justAudio);

  /// 是否正在 DLNA 投屏（遥控模式）。投屏时播放页控件改为遥控投屏设备。
  final ValueNotifier<bool> isCasting = ValueNotifier(false);

  // Signals (for reactive state management)
  final positionSignal = signal(Duration.zero);
  final durationSignal = signal<Duration?>(null);
  final bufferedPositionSignal = signal(Duration.zero);
  final isPlayingSignal = signal(false);
  final isLoadingSignal = signal(false);
  final queueSignal = signal<List<SongEntity>>([]);
  final currentIndexSignal = signal(-1);
  final currentSongSignal = signal<SongEntity?>(null);
  final snapshotSignal = signal(PlaybackSnapshot.initial());
  final playbackModeSignal = signal(PlaybackMode.loop);
  final sleepTimerDisplayTextSignal = signal<String?>(null);
  final sleepUntilSongEndSignal = signal(false);
  final decoderEngineSignal = signal(EngineKind.justAudio);
  final isCastingSignal = signal(false);

  void _initListeners() {
    position.addListener(() => positionSignal.value = position.value);
    duration.addListener(() => durationSignal.value = duration.value);
    bufferedPosition.addListener(
      () => bufferedPositionSignal.value = bufferedPosition.value,
    );
    isPlaying.addListener(() => isPlayingSignal.value = isPlaying.value);
    isLoading.addListener(() => isLoadingSignal.value = isLoading.value);
    queue.addListener(() => queueSignal.value = queue.value);
    currentIndex.addListener(
        () => currentIndexSignal.value = currentIndex.value);
    currentSong.addListener(
        () => currentSongSignal.value = currentSong.value);
    snapshot.addListener(() => snapshotSignal.value = snapshot.value);
    playbackMode.addListener(
      () => playbackModeSignal.value = playbackMode.value,
    );
    sleepTimerDisplayText.addListener(
      () => sleepTimerDisplayTextSignal.value = sleepTimerDisplayText.value,
    );
    sleepUntilSongEnd.addListener(
      () => sleepUntilSongEndSignal.value = sleepUntilSongEnd.value,
    );
    decoderEngine.addListener(() {
      decoderEngineSignal.value = decoderEngine.value;
    });
    isCasting.addListener(() {
      isCastingSignal.value = isCasting.value;
    });
  }
  
  void dispose() {
    position.dispose();
    duration.dispose();
    bufferedPosition.dispose();
    isPlaying.dispose();
    isLoading.dispose();
    queue.dispose();
    currentIndex.dispose();
    currentSong.dispose();
    snapshot.dispose();
    playbackMode.dispose();
    sleepTimerDisplayText.dispose();
    sleepUntilSongEnd.dispose();
    decoderEngine.dispose();
    isCasting.dispose();
  }
}
