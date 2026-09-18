import 'dart:convert';
import 'dart:io';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:image_cropper/image_cropper.dart';

import '../../app/utils/image_crop_helper.dart';
import '../../app/services/feiniu/api_client.dart';
import '../../app/services/feiniu/api_models.dart';
import '../../app/state/song_state.dart';
import '../../components/index.dart';

/// 歌曲信息编辑页。
///
/// 从歌曲详情页进入，展示歌曲完整信息（封面、音频规格、元数据），支持编辑
/// 封面 / 名称 / 专辑 / 歌手 / 年份 / 歌曲序号 / 光盘序号 / 风格。保存成功后
/// 返回更新后的 [SongEntity]，由调用方刷新列表与播放器。
class SongEditPage extends StatefulWidget {
  final SongEntity song;

  const SongEditPage({super.key, required this.song});

  @override
  State<SongEditPage> createState() => _SongEditPageState();
}

class _SongEditPageState extends State<SongEditPage> {
  final FeiNiuApiClient _api = FeiNiuApiClient.instance;
  final _formKey = GlobalKey<FormState>();

  bool _loading = true;
  bool _saving = false;

  // 服务端完整元数据（用于展示音频规格等只读信息）
  FeiNiuTrack? _track;
  FeiNiuAudioSpec? _audioSpec;

  // 表单状态
  late final TextEditingController _titleController;
  late final TextEditingController _albumController;
  late final TextEditingController _yearController;
  late final TextEditingController _trackNoController;
  late final TextEditingController _discNoController;

  /// 当前歌手（FeiNiuArtist，含 coverId 用于头像）
  List<FeiNiuArtist> _artists = [];

  /// 当前风格
  List<FeiNiuGenre> _genres = [];

  /// 换图后的本地裁剪文件路径；为 null 表示未换图（保留原封面）
  String? _pendingCoverPath;

  /// 缓存的本地封面 ImageProvider：跨 rebuild 复用同一实例（稳定图片缓存 key），
  /// 避免每次 build 重新创建 FileImage 导致重复解码（编辑页卡顿主因之一）。
  ImageProvider? _localCoverProvider;

  /// 重建 [_localCoverProvider]（路径变化时调用）。
  void _refreshLocalCoverProvider(String? path) {
    if (path == null || path.isEmpty) {
      _localCoverProvider = null;
      return;
    }
    _localCoverProvider = ResizeImage.resizeIfNeeded(
      _coverSize.toInt(),
      null,
      FileImage(File(path)),
    );
  }

  @override
  void initState() {
    super.initState();
    _titleController = TextEditingController(text: widget.song.title);
    _albumController = TextEditingController(
      text: widget.song.albumDisplayName == '未知专辑'
          ? ''
          : widget.song.albumDisplayName,
    );
    _yearController = TextEditingController();
    _trackNoController = TextEditingController(
      text: widget.song.trackNumber?.toString() ?? '',
    );
    _discNoController = TextEditingController(
      text: widget.song.discNumber?.toString() ?? '',
    );
    _load();
  }

  @override
  void dispose() {
    _titleController.dispose();
    _albumController.dispose();
    _yearController.dispose();
    _trackNoController.dispose();
    _discNoController.dispose();
    super.dispose();
  }

  /// 拉取歌曲完整元数据填充表单。
  Future<void> _load() async {
    try {
      final data = await _api.trackMetadata(widget.song.id);
      if (!mounted) return;
      if (data != null) {
        final track = FeiNiuTrack.fromJson(data['track'] as Map<String, dynamic>? ?? {});
        final audioSpec = data['audioSpec'] != null
            ? FeiNiuAudioSpec.fromJson(data['audioSpec'] as Map<String, dynamic>)
            : null;
        _track = track;
        _audioSpec = audioSpec;
        _artists = track.artists;
        _genres = track.genres;
        if (track.year != null) _yearController.text = track.year.toString();
        if (track.title.isNotEmpty) _titleController.text = track.title;
        final albumName = track.album.name;
        if (albumName.isNotEmpty && albumName != '未知专辑') {
          _albumController.text = albumName;
        }
        if (track.trackNo != null) _trackNoController.text = track.trackNo.toString();
        if (track.discNo != null) _discNoController.text = track.discNo.toString();
      }
    } catch (e) {
      debugPrint('[SongEditPage] load metadata error: $e');
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  /// 当前显示的封面 coverId（未换图时用服务端原值）。
  String? get _displayCoverId {
    if (_track?.coverId != null && _track!.coverId!.isNotEmpty) {
      return _track!.coverId;
    }
    if (widget.song.coverId != null && widget.song.coverId!.isNotEmpty) {
      return widget.song.coverId;
    }
    return null;
  }

  // ── 封面选择 / 上传 ──────────────────────────────────────────────

  /// 从相册选择图片 → 1:1 裁剪 → 上传到歌曲封面，得到新 coverId。
  Future<void> _pickCover() async {
    final result = await FilePicker.platform.pickFiles(
      type: FileType.image,
      allowMultiple: false,
    );
    final file = result?.files.first;
    if (file?.path == null || !mounted) return;

    final cropped = await cropCoverImage(
      sourcePath: file!.path!,
      ratioX: 1,
      ratioY: 1,
      uiSettings: [
        AndroidUiSettings(
          toolbarTitle: '裁剪封面',
          hideBottomControls: true,
          lockAspectRatio: true,
          toolbarColor: const Color(0xFF212121),
          statusBarLight: false,
          toolbarWidgetColor: Colors.white,
          activeControlsWidgetColor: Colors.white,
          backgroundColor: Colors.black,
        ),
        IOSUiSettings(
          title: '裁剪封面',
          aspectRatioLockEnabled: true,
          resetAspectRatioEnabled: false,
        ),
      ],
    );
    if (cropped == null || !mounted) return;

    setState(() {
      _pendingCoverPath = cropped.path; // 本地预览；保存时才上传
      _refreshLocalCoverProvider(cropped.path);
    });
  }

  // ── 歌手选择 ────────────────────────────────────────────────────

  Future<void> _showArtistPicker() async {
    final selected = await showModalBottomSheet<List<FeiNiuArtist>>(
      context: context,
      backgroundColor: Colors.transparent,
      isScrollControlled: true,
      builder: (_) => _ArtistPickerSheet(initial: _artists),
    );
    if (selected != null && mounted) {
      setState(() => _artists = selected);
    }
  }

  // ── 风格选择 ────────────────────────────────────────────────────

  Future<void> _showGenrePicker() async {
    final selected = await showModalBottomSheet<List<FeiNiuGenre>>(
      context: context,
      backgroundColor: Colors.transparent,
      isScrollControlled: true,
      builder: (_) => _GenrePickerSheet(initial: _genres),
    );
    if (selected != null && mounted) {
      setState(() => _genres = selected);
    }
  }


  // ── 保存 ────────────────────────────────────────────────────────

  Future<void> _save() async {
    if (_saving) return;
    if (!(_formKey.currentState?.validate() ?? false)) return;

    setState(() => _saving = true);
    try {
      // 换图了 → 先上传拿新 coverId；未换图 → 保留原 coverId
      String? newCoverId;
      if (_pendingCoverPath != null) {
        final bytes = await File(_pendingCoverPath!).readAsBytes();
        newCoverId = await _api.uploadTrackCover(bytes);
      }

      // 未换图时沿用原曲目 coverId（可能为 null，由服务端决定保留原封面）
      final coverId = newCoverId ?? _displayCoverId;

      // 专辑：改过专辑名时精确匹配已有专辑取 guid，避免服务端按字符串
      // 隐式新建出重复专辑；匹配不到则不传 albumGUID（由服务端自行处理）。
      String? albumGuid;
      final albumText = _albumController.text.trim();
      if (albumText.isNotEmpty && albumText != widget.song.albumDisplayName) {
        final albums = await _api.getAlbumListAll();
        albumGuid = albums.where((a) => a.name == albumText).firstOrNull?.guid;
      }

      final body = <String, dynamic>{
        'guid': widget.song.id,
        'title': _titleController.text.trim(),
        'album': albumText,
        if (albumGuid != null && albumGuid.isNotEmpty) 'albumGUID': albumGuid,
        'artistGUIDs': _artists.map((a) => a.guid).toList(),
        'genreGUIDs': _genres.map((g) => g.guid).toList(),
        'year': int.tryParse(_yearController.text.trim()),
        'trackNo': int.tryParse(_trackNoController.text.trim()),
        'discNo': int.tryParse(_discNoController.text.trim()),
        if (coverId != null && coverId.isNotEmpty)
          'coverId': coverId,
        if (coverId != null && coverId.isNotEmpty)
          'coverGUID': FeiNiuApiClient.deriveCoverGuid(coverId),
      };

      await _api.updateTrackMetadata(body);

      // 构造更新后的 SongEntity 返回
      final artistJson = jsonEncode(
        _artists
            .map((a) => {
                  'guid': a.guid,
                  'name': a.name,
                  if (a.coverId != null && a.coverId!.isNotEmpty)
                    'coverId': a.coverId,
                })
            .toList(),
      );
      final originalAlbumGuid = widget.song.albumGuid;
      final albumJson = jsonEncode({
        if (originalAlbumGuid != null && originalAlbumGuid.isNotEmpty)
          'guid': originalAlbumGuid,
        'name': _albumController.text.trim(),
      });
      final updated = widget.song.copyWith(
        title: _titleController.text.trim(),
        artist: artistJson,
        album: albumJson,
        coverId: coverId ?? widget.song.coverId,
        trackNumber: int.tryParse(_trackNoController.text.trim()),
        discNumber: int.tryParse(_discNoController.text.trim()),
        updatedAt: DateTime.now().millisecondsSinceEpoch,
      );

      if (!mounted) return;
      AppToast.show(context, '已保存');
      Navigator.of(context).pop(updated);
    } catch (e) {
      debugPrint('[SongEditPage] save error: $e');
      if (mounted) {
        AppToast.show(context, '保存失败：$e', type: ToastType.error);
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  // ── UI ──────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    return AppPageScaffold(
      extendBodyBehindAppBar: true,
      appBar: const AppTopBar(
        title: '编辑歌曲',
        backgroundColor: Colors.transparent,
        elevation: 0,
      ),
      showMiniPlayer: false,
      // 关掉键盘 inset 缩放：键盘弹出/收起时 Scaffold 不再逐帧重排整页
      // （页面有 4 张圆角卡片 + 6 个输入框，是全 App 唯一开此开关的页，
      //  是展开输入法卡顿的主因）。改用列表末尾的 _KeyboardInsetSpacer
      //  单独占位，只让那一个小组件随键盘逐帧重建。
      resizeToAvoidBottomInset: false,
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : Stack(
              children: [
                Form(
                  key: _formKey,
                  child: ListView(
                    padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
                    children: [
                      // 每张卡片独立 RepaintBoundary：键盘 insets 动画期间
                      // 卡片自身不重排，图层只做合成平移，避免整页重新栅格化。
                      RepaintBoundary(child: _buildHeaderCard(context)),
                      const SizedBox(height: 16),
                      if (_audioSpec != null) ...[
                        RepaintBoundary(child: _buildAudioSpecCard(context)),
                        const SizedBox(height: 16),
                      ],
                      RepaintBoundary(child: _buildEditCard(context)),
                      const SizedBox(height: 24),
                      SizedBox(
                        height: 48,
                        child: FilledButton.icon(
                          onPressed: _saving ? null : _save,
                          icon: _saving
                              ? const SizedBox(
                                  width: 18,
                                  height: 18,
                                  child: CircularProgressIndicator(strokeWidth: 2),
                                )
                              : const Icon(Icons.check_rounded),
                          label: Text(_saving ? '保存中…' : '保存'),
                          style: FilledButton.styleFrom(
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(14),
                            ),
                          ),
                        ),
                      ),
                      // 键盘 insets 占位：resizeToAvoidBottomInset 已关闭，
                      // 这里单独读 viewInsets，让保存按钮仍能滚到键盘上方。
                      // 只让这个小组件随键盘逐帧重建，不波及整页。
                      const _KeyboardInsetSpacer(),
                    ],
                  ),
                ),
              ],
            ),
    );
  }

  /// 头部：居中的封面大图（点击换图）。歌名/歌手在下方表单已有，这里不重复。
  Widget _buildHeaderCard(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 20),
      decoration: BoxDecoration(
        color: theme.cardColor,
        borderRadius: BorderRadius.circular(20),
      ),
      child: Center(
        child: _buildCover(theme),
      ),
    );
  }

  /// 封面大图：右下角相机角标点击从相册选择封面。换图后本地预览，否则网络图。
  static const double _coverSize = 160;

  Widget _buildCover(ThemeData theme) {
    final Widget image;
    if (_pendingCoverPath != null) {
      // 本地相册选择的封面。复用缓存的 provider（稳定缓存 key），避免每次
      // build 重新解码大图。
      if (_localCoverProvider == null) {
        _refreshLocalCoverProvider(_pendingCoverPath);
      }
      image = Image(
        image: _localCoverProvider!,
        width: _coverSize,
        height: _coverSize,
        fit: BoxFit.cover,
      );
    } else if (_displayCoverId != null) {
      image = CachedNetworkImage(
        imageUrl: _api.coverUrl(
          _displayCoverId!,
          size: FeiNiuApiClient.coverRequestSize,
          updatedAt: widget.song.updatedAt,
        ),
        httpHeaders: FeiNiuApiClient.imageAuthHeaders(),
        width: _coverSize,
        height: _coverSize,
        fit: BoxFit.cover,
        placeholder: (_, _) => _coverPlaceholder(theme),
        errorWidget: (_, _, _) => _coverPlaceholder(theme),
      );
    } else {
      image = _coverPlaceholder(theme);
    }

    return InkWell(
      onTap: _pickCover,
      borderRadius: BorderRadius.circular(20),
      child: Stack(
        children: [
          // RepaintBoundary：键盘弹入/表单重建时封面图层独立重绘，
          // 避免每次 rebuild 都触发封面 image 重新 decode（编辑页卡顿主因）。
          RepaintBoundary(
            child: ClipRRect(
              borderRadius: BorderRadius.circular(20),
              child: image,
            ),
          ),
          Positioned(
            right: 5,
            bottom: 5,
            child: Container(
              width: 34,
              height: 34,
              decoration: BoxDecoration(
                color: Colors.black.withValues(alpha: 0.55),
                shape: BoxShape.circle,
              ),
              child: const Icon(
                Icons.photo_camera_rounded,
                size: 18,
                color: Colors.white,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _coverPlaceholder(ThemeData theme) {
    final letter = widget.song.title.trim().isEmpty
        ? '?'
        : widget.song.title.trim().substring(0, 1);
    return Container(
      width: _coverSize,
      height: _coverSize,
      decoration: BoxDecoration(
        color: theme.cardColor,
        borderRadius: BorderRadius.circular(20),
      ),
      alignment: Alignment.center,
      child: Text(
        letter.toUpperCase(),
        style: TextStyle(
          fontSize: 48,
          color: theme.colorScheme.primary,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }

  /// 音频规格只读卡片。
  Widget _buildAudioSpecCard(BuildContext context) {
    final spec = _audioSpec!;
    final theme = Theme.of(context);
    final items = <(String, String)>[
      (
        '码率',
        spec.bitrate != null && spec.bitrate! > 0
            ? '${(spec.bitrate! / 1000).toStringAsFixed(0)}kbps'
            : '-',
      ),
      (
        '采样率',
        spec.sampleRate != null && spec.sampleRate! > 0
            ? '${(spec.sampleRate! / 1000).toStringAsFixed(1)}kHz'
            : '-',
      ),
      ('声道数', spec.channel?.toString() ?? '-'),
      (
        '文件大小',
        spec.size != null && spec.size! > 0
            ? '${(spec.size! / (1024 * 1024)).toStringAsFixed(1)}MB'
            : '-',
      ),
    ];

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: theme.cardColor,
        borderRadius: BorderRadius.circular(20),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '音频信息',
            style: theme.textTheme.titleSmall?.copyWith(
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: 12),
          // 两行两列：每项用同一 _buildSpecItem（内边距 vertical:6），
          // 行距 4，全部项目的上下边距统一收紧。
          _buildSpecRow(theme, items[0], items[1]),
          const SizedBox(height: 4),
          _buildSpecRow(theme, items[2], items[3]),
          if (_track?.createdAt != null && _track!.createdAt > 0) ...[
            const SizedBox(height: 4),
            _buildSpecItem(theme, '添加时间', _formatDate(_track!.createdAt)),
          ],
          if (spec.path != null && spec.path!.isNotEmpty) ...[
            const SizedBox(height: 4),
            _buildSpecItem(theme, '文件位置', spec.path!),
          ],
        ],
      ),
    );
  }

  Widget _buildSpecItem(ThemeData theme, String label, String value) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerLow,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            label,
            style: TextStyle(
              fontSize: 11,
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: 2),
          Text(
            value,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w600,
              color: theme.colorScheme.onSurface,
            ),
          ),
        ],
      ),
    );
  }

  /// 一行两个规格项（左右各一个 Expanded，中间间距 8）。
  Widget _buildSpecRow(
    ThemeData theme,
    (String, String) left,
    (String, String) right,
  ) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(child: _buildSpecItem(theme, left.$1, left.$2)),
        const SizedBox(width: 8),
        Expanded(child: _buildSpecItem(theme, right.$1, right.$2)),
      ],
    );
  }

  /// 编辑表单卡片。
  Widget _buildEditCard(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Theme.of(context).cardColor,
        borderRadius: BorderRadius.circular(20),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '编辑信息',
            style: Theme.of(context).textTheme.titleSmall?.copyWith(
                  fontWeight: FontWeight.w700,
                ),
          ),
          const SizedBox(height: 12),
          _buildTextField(
            controller: _titleController,
            label: '名称',
            icon: Icons.music_note_outlined,
            validator: (v) {
              if (v == null || v.trim().isEmpty) return '请输入歌曲名称';
              return null;
            },
          ),
          const SizedBox(height: 14),
          _buildTextField(
            controller: _albumController,
            label: '专辑',
            icon: Icons.album_outlined,
          ),
          const SizedBox(height: 14),
          _buildArtistField(context),
          const SizedBox(height: 14),
          _buildChipField(
            context,
            label: '风格',
            icon: Icons.category_outlined,
            chips: _genres.map((g) => g.name).toList(),
            onAdd: _showGenrePicker,
            onRemove:
                _genres.isEmpty ? null : () => setState(() => _genres = []),
          ),
          const SizedBox(height: 14),
          _buildTextField(
            controller: _yearController,
            label: '年份',
            icon: Icons.calendar_today_outlined,
            keyboardType: TextInputType.number,
          ),
          const SizedBox(height: 14),
          _buildTextField(
            controller: _trackNoController,
            label: '歌曲序号',
            icon: Icons.format_list_numbered_rounded,
            keyboardType: TextInputType.number,
          ),
          const SizedBox(height: 14),
          _buildTextField(
            controller: _discNoController,
            label: '光盘序号',
            icon: Icons.album_outlined,
            keyboardType: TextInputType.number,
          ),
        ],
      ),
    );
  }

  /// 歌词编辑卡片（始终显示；未开启歌词修改时给提示入口）。
  Widget _buildTextField({
    required TextEditingController controller,
    required String label,
    required IconData icon,
    TextInputType? keyboardType,
    String? Function(String?)? validator,
  }) {
    return TextFormField(
      controller: controller,
      keyboardType: keyboardType,
      validator: validator,
      decoration: InputDecoration(
        labelText: label,
        prefixIcon: Icon(icon),
        border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
        isDense: true,
      ),
    );
  }

  /// 歌手字段：大号头像 + 名字（无 chip 背景包裹），横向可换行排列。
  /// 每个歌手显示头像（有 coverId 用图片，否则首字母圆形占位）与名字，
  /// 右上角删除按钮移除。点击「添加」打开歌手选择器。
  Widget _buildArtistField(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Icon(Icons.person_outline, size: 20, color: theme.colorScheme.primary),
            const SizedBox(width: 8),
            Text(
              '歌手',
              style: TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w600,
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
        const SizedBox(height: 10),
        Wrap(
          spacing: 14,
          runSpacing: 14,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            for (final artist in _artists)
              _buildArtistItem(theme, artist),
            InkWell(
              onTap: _showArtistPicker,
              borderRadius: BorderRadius.circular(12),
              child: Container(
                width: 64,
                height: 64,
                decoration: BoxDecoration(
                  color: theme.colorScheme.primary.withValues(alpha: 0.08),
                  borderRadius: BorderRadius.circular(16),
                  border: Border.all(
                    color: theme.colorScheme.primary.withValues(alpha: 0.3),
                  ),
                ),
                child: Icon(
                  Icons.add_rounded,
                  color: theme.colorScheme.primary,
                  size: 28,
                ),
              ),
            ),
          ],
        ),
      ],
    );
  }

  Widget _buildArtistItem(ThemeData theme, FeiNiuArtist artist) {
    return Stack(
      clipBehavior: Clip.none,
      children: [
        Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            _ArtistAvatarWidget(
              coverId: artist.coverId,
              name: artist.name,
              size: 56,
            ),
            const SizedBox(height: 6),
            SizedBox(
              width: 60,
              child: Text(
                artist.name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: 12,
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ),
          ],
        ),
        Positioned(
          top: -3,
          right: -3,
          child: GestureDetector(
            onTap: () {
              setState(() {
                _artists = _artists
                    .where((a) => a.guid != artist.guid)
                    .toList();
              });
            },
            child: Container(
              width: 18,
              height: 18,
              decoration: BoxDecoration(
                color: theme.colorScheme.surfaceContainerHighest,
                shape: BoxShape.circle,
                border: Border.all(
                  color: theme.colorScheme.onSurfaceVariant
                      .withValues(alpha: 0.4),
                ),
              ),
              child: Icon(
                Icons.close_rounded,
                size: 12,
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ),
        ),
      ],
    );
  }

  /// 可添加/清空的 chip 字段（风格）。
  Widget _buildChipField(
    BuildContext context, {
    required String label,
    required IconData icon,
    required List<String> chips,
    required VoidCallback onAdd,
    required VoidCallback? onRemove,
  }) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Icon(icon, size: 20, color: theme.colorScheme.primary),
            const SizedBox(width: 8),
            Text(
              label,
              style: TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w600,
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
        const SizedBox(height: 8),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            if (chips.isEmpty)
              const SizedBox.shrink()
            else
              for (final chip in chips)
                InputChip(
                  label: Text(chip),
                  onDeleted: onRemove == null ? null : () => onRemove(),
                  deleteIconColor: theme.colorScheme.onSurfaceVariant,
                  visualDensity: VisualDensity.compact,
                ),
            ActionChip(
              avatar: Icon(
                Icons.add_rounded,
                size: 18,
                color: theme.colorScheme.primary,
              ),
              label: const Text('添加'),
              onPressed: onAdd,
              visualDensity: VisualDensity.compact,
            ),
          ],
        ),
      ],
    );
  }

  String _formatDate(int timestampMs) {
    // timestamp 单位为秒（服务端 createdAt）
    final dt = DateTime.fromMillisecondsSinceEpoch(timestampMs * 1000);
    final y = dt.year.toString().padLeft(4, '0');
    final m = dt.month.toString().padLeft(2, '0');
    final d = dt.day.toString().padLeft(2, '0');
    final hh = dt.hour.toString().padLeft(2, '0');
    final mm = dt.minute.toString().padLeft(2, '0');
    return '$y-$m-$d $hh:$mm';
  }
}

/// 键盘 insets 占位：编辑页关闭了 resizeToAvoidBottomInset 以避免键盘动画
/// 逐帧重排整页，这里单独读取 viewInsets 撑出底部空间，让保存按钮仍能滚到
/// 键盘上方。独立小部件，随键盘逐帧重建的只有它自己。
class _KeyboardInsetSpacer extends StatelessWidget {
  const _KeyboardInsetSpacer();

  @override
  Widget build(BuildContext context) {
    final bottomInset = MediaQuery.viewInsetsOf(context).bottom;
    return SizedBox(height: bottomInset + 12);
  }
}

/// 歌手选择弹层：可搜索、显示头像+名字、多选。
class _ArtistPickerSheet extends StatefulWidget {
  final List<FeiNiuArtist> initial;

  const _ArtistPickerSheet({required this.initial});

  @override
  State<_ArtistPickerSheet> createState() => _ArtistPickerSheetState();
}

class _ArtistPickerSheetState extends State<_ArtistPickerSheet> {
  final FeiNiuApiClient _api = FeiNiuApiClient.instance;
  List<FeiNiuArtist> _all = [];
  final Set<String> _selected = {};
  bool _loading = true;
  bool _creating = false;
  String _query = '';

  @override
  void initState() {
    super.initState();
    _selected.addAll(widget.initial.map((a) => a.guid));
    _load();
  }

  Future<void> _load() async {
    try {
      final artists = await _api.getArtistListAll();
      if (!mounted) return;
      setState(() {
        _all = artists;
        _loading = false;
      });
    } catch (e) {
      debugPrint('[ArtistPickerSheet] load error: $e');
      if (mounted) setState(() => _loading = false);
    }
  }

  /// 手动新增歌手：弹输入框 → 调 `/artist/create` → 追加到列表并选中。
  Future<void> _showCreateDialog() async {
    final controller = TextEditingController();
    final created = await showDialog<String>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('新增歌手'),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: const InputDecoration(
            hintText: '输入歌手名称',
            border: OutlineInputBorder(),
          ),
          onSubmitted: (v) {
            final name = v.trim();
            if (name.isNotEmpty) Navigator.of(dialogContext).pop(name);
          },
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () {
              final name = controller.text.trim();
              if (name.isEmpty) return;
              Navigator.of(dialogContext).pop(name);
            },
            child: const Text('创建'),
          ),
        ],
      ),
    );
    final name = created?.trim();
    if (name == null || name.isEmpty || !mounted) return;

    setState(() => _creating = true);
    try {
      final artist = await _api.createArtist(name);
      if (!mounted) return;
      setState(() {
        _creating = false;
        if (!_all.any((a) => a.guid == artist.guid)) _all.add(artist);
        _selected.add(artist.guid);
        _query = ''; // 清空搜索，确保新歌手可见
      });
      if (mounted) {
        AppToast.show(context, '已创建歌手「$name」');
      }
    } catch (e) {
      debugPrint('[ArtistPickerSheet] create artist error: $e');
      if (mounted) {
        setState(() => _creating = false);
        AppToast.show(context, '创建失败：$e', type: ToastType.error);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final filtered = _query.isEmpty
        ? _all
        : _all
              .where(
                (a) => a.name.toLowerCase().contains(_query.toLowerCase()),
              )
              .toList();

    return Container(
      height: MediaQuery.of(context).size.height * 0.7,
      decoration: BoxDecoration(
        color: theme.scaffoldBackgroundColor,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
      ),
      child: Column(
        children: [
          Center(
            child: Container(
              margin: const EdgeInsets.symmetric(vertical: 12),
              width: 32,
              height: 4,
              decoration: BoxDecoration(
                color: theme.brightness == Brightness.dark
                    ? Colors.grey[800]
                    : Colors.grey[300],
                borderRadius: BorderRadius.circular(2),
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
            child: Row(
              children: [
                Text(
                  '选择歌手',
                  style: TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.w600,
                    color: theme.colorScheme.onSurface,
                  ),
                ),
                const Spacer(),
                Text(
                  '已选 ${_selected.length}',
                  style: TextStyle(
                    fontSize: 12,
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
                const SizedBox(width: 8),
                TextButton.icon(
                  onPressed: _creating ? null : _showCreateDialog,
                  icon: _creating
                      ? const SizedBox(
                          width: 14,
                          height: 14,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.person_add_alt_1_rounded, size: 18),
                  label: const Text('新增'),
                ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: TextField(
              onChanged: (v) => setState(() => _query = v),
              decoration: InputDecoration(
                hintText: '搜索歌手',
                prefixIcon: const Icon(Icons.search_rounded),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                ),
                isDense: true,
              ),
            ),
          ),
          const SizedBox(height: 8),
          Expanded(
            child: _loading
                ? const Center(child: CircularProgressIndicator())
                : ListView.builder(
                    itemCount: filtered.length,
                    itemBuilder: (context, index) {
                      final artist = filtered[index];
                      final selected = _selected.contains(artist.guid);
                      return ListTile(
                        leading: _ArtistAvatarWidget(
                          coverId: artist.coverId,
                          name: artist.name,
                          size: 40,
                        ),
                        title: Text(artist.name),
                        trailing: selected
                            ? Icon(
                                Icons.check_circle,
                                color: theme.colorScheme.primary,
                              )
                            : Icon(
                                Icons.circle_outlined,
                                color: theme.colorScheme.onSurfaceVariant
                                    .withValues(alpha: 0.4),
                              ),
                        onTap: () {
                          setState(() {
                            if (selected) {
                              _selected.remove(artist.guid);
                            } else {
                              _selected.add(artist.guid);
                            }
                          });
                        },
                      );
                    },
                  ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
            child: SizedBox(
              height: 48,
              width: double.infinity,
              child: FilledButton(
                onPressed: () {
                  final chosen = _all
                      .where((a) => _selected.contains(a.guid))
                      .toList();
                  Navigator.of(context).pop(chosen);
                },
                child: const Text('确定'),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// 歌手头像：有 coverId 显示图片，否则首字母圆形占位。
class _ArtistAvatarWidget extends StatelessWidget {
  final String? coverId;
  final String name;
  final double size;

  const _ArtistAvatarWidget({
    required this.coverId,
    required this.name,
    required this.size,
  });

  @override
  Widget build(BuildContext context) {
    final radius = size / 2;
    final initial = name.isNotEmpty ? name.characters.first : '?';
    if (coverId != null && coverId!.isNotEmpty) {
      final coverUrl = FeiNiuApiClient.instance.coverUrl(coverId!, size: FeiNiuApiClient.coverRequestSize);
      // 有封面时不叠加名字首字，仅显示头像图片。
      return CircleAvatar(
        radius: radius,
        backgroundImage: CachedNetworkImageProvider(
          coverUrl,
          headers: FeiNiuApiClient.imageAuthHeaders(),
        ),
        onBackgroundImageError: (_, _) {},
      );
    }
    return CircleAvatar(radius: radius, child: Text(initial));
  }
}

/// 风格选择弹层：搜索 + 多选（风格无封面，仅名字）。
class _GenrePickerSheet extends StatefulWidget {
  final List<FeiNiuGenre> initial;

  const _GenrePickerSheet({required this.initial});

  @override
  State<_GenrePickerSheet> createState() => _GenrePickerSheetState();
}

class _GenrePickerSheetState extends State<_GenrePickerSheet> {
  final FeiNiuApiClient _api = FeiNiuApiClient.instance;
  List<FeiNiuGenre> _all = [];
  final Set<String> _selected = {};
  bool _loading = true;
  String _query = '';

  @override
  void initState() {
    super.initState();
    _selected.addAll(widget.initial.map((g) => g.guid));
    _load();
  }

  Future<void> _load() async {
    try {
      final page = await _api.getGenreList(page: 1, size: 200);
      if (!mounted) return;
      setState(() {
        _all = page.list;
        _loading = false;
      });
    } catch (e) {
      debugPrint('[GenrePickerSheet] load error: $e');
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final filtered = _query.isEmpty
        ? _all
        : _all
              .where(
                (g) => g.name.toLowerCase().contains(_query.toLowerCase()),
              )
              .toList();

    return Container(
      height: MediaQuery.of(context).size.height * 0.6,
      decoration: BoxDecoration(
        color: theme.scaffoldBackgroundColor,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
      ),
      child: Column(
        children: [
          Center(
            child: Container(
              margin: const EdgeInsets.symmetric(vertical: 12),
              width: 32,
              height: 4,
              decoration: BoxDecoration(
                color: theme.brightness == Brightness.dark
                    ? Colors.grey[800]
                    : Colors.grey[300],
                borderRadius: BorderRadius.circular(2),
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
            child: Row(
              children: [
                Text(
                  '选择风格',
                  style: TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.w600,
                    color: theme.colorScheme.onSurface,
                  ),
                ),
                const Spacer(),
                Text(
                  '已选 ${_selected.length}',
                  style: TextStyle(
                    fontSize: 12,
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: TextField(
              onChanged: (v) => setState(() => _query = v),
              decoration: InputDecoration(
                hintText: '搜索风格',
                prefixIcon: const Icon(Icons.search_rounded),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                ),
                isDense: true,
              ),
            ),
          ),
          const SizedBox(height: 8),
          Expanded(
            child: _loading
                ? const Center(child: CircularProgressIndicator())
                : ListView.builder(
                    itemCount: filtered.length,
                    itemBuilder: (context, index) {
                      final genre = filtered[index];
                      final selected = _selected.contains(genre.guid);
                      return ListTile(
                        leading: Icon(
                          Icons.category_outlined,
                          color: selected
                              ? theme.colorScheme.primary
                              : theme.colorScheme.onSurfaceVariant,
                        ),
                        title: Text(genre.name),
                        trailing: selected
                            ? Icon(
                                Icons.check_circle,
                                color: theme.colorScheme.primary,
                              )
                            : Icon(
                                Icons.circle_outlined,
                                color: theme.colorScheme.onSurfaceVariant
                                    .withValues(alpha: 0.4),
                              ),
                        onTap: () {
                          setState(() {
                            if (selected) {
                              _selected.remove(genre.guid);
                            } else {
                              _selected.add(genre.guid);
                            }
                          });
                        },
                      );
                    },
                  ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
            child: SizedBox(
              height: 48,
              width: double.infinity,
              child: FilledButton(
                onPressed: () {
                  final chosen = _all
                      .where((g) => _selected.contains(g.guid))
                      .toList();
                  Navigator.of(context).pop(chosen);
                },
                child: const Text('确定'),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
