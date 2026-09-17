import 'dart:io';

import 'package:flutter/material.dart';

import '../../app/services/db/dao/playlist_dao.dart';
import '../../app/services/player_service.dart';
import '../../app/state/song_state.dart';

/// 本地歌单详情：列出成员歌曲，点击任意一首即以该歌单为队列播放。
///
/// 本地歌单（id 带 `local-pl-` 前缀）由 [PlaylistDao] 管理，可同时收录
/// 本地歌与飞牛歌。编辑（改名/删歌）能力后续批次补齐。
class LocalPlaylistDetailPage extends StatefulWidget {
  const LocalPlaylistDetailPage({
    super.key,
    required this.playlistId,
    required this.playlistName,
  });

  final String playlistId;
  final String playlistName;

  @override
  State<LocalPlaylistDetailPage> createState() =>
      _LocalPlaylistDetailPageState();
}

class _LocalPlaylistDetailPageState extends State<LocalPlaylistDetailPage> {
  bool _loading = true;
  List<SongEntity> _songs = [];

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final songs =
        await PlaylistDao.instance.localPlaylistSongs(widget.playlistId);
    if (!mounted) return;
    setState(() {
      _songs = songs;
      _loading = false;
    });
  }

  Future<void> _playAt(int index) async {
    if (_songs.isEmpty) return;
    await PlayerService.instance
        .playQueue(List<SongEntity>.from(_songs), index);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(title: Text(widget.playlistName)),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _songs.isEmpty
              ? const Center(child: Text('歌单还没有歌曲'))
              : Column(
                  children: [
                    Padding(
                      padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
                      child: Row(
                        children: [
                          Text('${_songs.length} 首',
                              style: theme.textTheme.bodySmall),
                          const Spacer(),
                          TextButton.icon(
                            onPressed: () => _playAt(0),
                            icon: const Icon(
                                Icons.play_circle_fill_rounded),
                            label: const Text('播放全部'),
                          ),
                        ],
                      ),
                    ),
                    Expanded(
                      child: RefreshIndicator(
                        onRefresh: _load,
                        child: ListView.builder(
                          itemCount: _songs.length,
                          itemBuilder: (context, index) {
                            final s = _songs[index];
                            final hasCover = s.localCoverPath != null &&
                                s.localCoverPath!.isNotEmpty;
                            return ListTile(
                              leading: hasCover
                                  ? ClipRRect(
                                      borderRadius:
                                          BorderRadius.circular(6),
                                      child: Image.file(
                                        File(s.localCoverPath!),
                                        width: 44,
                                        height: 44,
                                        fit: BoxFit.cover,
                                        errorBuilder: (_, _, _) =>
                                            Text('${index + 1}'),
                                      ),
                                    )
                                  : SizedBox(
                                      width: 44,
                                      child: Text('${index + 1}'),
                                    ),
                              title: Text(s.title,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis),
                              subtitle: Text(s.artistDisplayName,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis),
                              onTap: () => _playAt(index),
                            );
                          },
                        ),
                      ),
                    ),
                  ],
                ),
    );
  }
}
