import 'dart:io';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/widgets.dart';

import '../state/song_state.dart';
import 'feiniu/api_client.dart';

/// 按歌曲归属返回它封面的 [ImageProvider]；没有封面返回 null。
///
/// 存在的理由：`player_service.dart` 里有三处几乎逐字相同的「预热当前/下一首
/// 封面」代码，各自手写 `coverUrl(...)` + `imageAuthHeaders()`。加本地音源时
/// 若照抄，同样的分派逻辑就要写第四、第五遍，而漏掉任何一处都会表现为
/// 「本地歌切歌时封面闪一下」。收在这里，三处共用一个判断。
///
/// 分派口径与 `ArtworkWidget` 保持一致：
/// - `coverId` 非空 → 飞牛网络封面（`CachedNetworkImageProvider`，带鉴权头）；
/// - 否则 `localCoverPath` 非空 → 本地落盘的封面文件（`FileImage`）；
/// - 都没有 → null，调用方跳过预热即可。
///
/// 网络封面统一用 canonical 尺寸（`FeiNiuApiClient.coverRequestSize`）请求：
/// 全 App 同一 coverId 永远构造同一个 URL，共享同一份磁盘缓存与解码缓存。
ImageProvider? coverImageProviderFor(SongEntity song) {
  // 一律 trim 后再判空：数据库里的 TEXT 列可能存着空白串，
  // `'   '.isNotEmpty` 为 true 会产出一个路径无效的 FileImage，
  // 表现为封面位置一直转圈而不是退回占位图。
  final coverId = (song.coverId ?? '').trim();
  if (coverId.isNotEmpty) {
    return CachedNetworkImageProvider(
      FeiNiuApiClient.instance.coverUrl(
        coverId,
        size: FeiNiuApiClient.coverRequestSize,
        updatedAt: song.updatedAt,
      ),
      headers: FeiNiuApiClient.imageAuthHeaders(),
    );
  }

  final localPath = (song.localCoverPath ?? '').trim();
  if (localPath.isNotEmpty) {
    return FileImage(File(localPath));
  }

  return null;
}
