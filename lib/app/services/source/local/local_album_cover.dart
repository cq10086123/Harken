import 'package:path/path.dart' as p;

/// 专辑封面解析：把「一个文件夹 = 一张专辑」这个使用习惯落到封面上。
///
/// 用户的实际导入方式是整目录导入，一个目录就是一张专辑。专辑里往往只有部分
/// 文件带内嵌封面（甚至一个都没有），但目录里通常躺着一张 `folder.jpg`。
/// 因此封面按两级回退：
///
/// 1. **目录旁挂图** —— `folder.jpg` / `cover.jpg` / …（见 [sidecarBaseNames]）；
/// 2. **同目录内任意歌曲的内嵌封面** —— 一张专辑的内嵌图通常每首都一样，
///    取第一张能读到的即可。
///
/// 歌曲自己有内嵌封面时优先用自己的（少数合辑里每首图不同）。
///
/// **上游 NagoMusic 没有旁挂图查找**（全仓库搜 `folder.jpg` 零命中），它在
/// Android 上看起来能识别，是因为走系统媒体库时 MediaStore 帮它索引了。
/// Windows 没有 MediaStore，必须自己找。
class LocalAlbumCover {
  const LocalAlbumCover._();

  /// 旁挂封面文件名候选，**按优先级**。全小写、不含扩展名。
  ///
  /// `folder` 排第一：这是 Windows / foobar2000 / EAC 的事实标准，
  /// 也是 MediaStore 优先采用的名字。
  static const List<String> sidecarBaseNames = [
    'folder',
    'cover',
    'front',
    'album',
    'art',
    'albumart',
    'coverart',
  ];

  /// 认可的旁挂图扩展名。
  static const Set<String> sidecarImageExtensions = {
    '.jpg',
    '.jpeg',
    '.png',
    '.webp',
  };

  /// 从一个目录的文件名列表里挑出专辑封面；没有返回 null。
  ///
  /// **纯函数**（只吃文件名字符串），因此挑选规则可以完全单测。
  ///
  /// 规则：先按 [sidecarBaseNames] 的顺序找同基名的图；都没有时，退而求其次
  /// 取字典序第一张图 —— 有图总比没图好，而字典序保证跨扫描稳定
  /// （不能依赖 `Directory.list` 的返回顺序，那在不同文件系统上不一致）。
  static String? pickSidecarCover(Iterable<String> fileNamesInDir) {
    final images = <String>[];
    for (final name in fileNamesInDir) {
      final ext = p.extension(name).toLowerCase();
      if (!sidecarImageExtensions.contains(ext)) continue;
      images.add(name);
    }
    if (images.isEmpty) return null;

    final byBase = <String, List<String>>{};
    for (final name in images) {
      final base = p.basenameWithoutExtension(name).toLowerCase();
      (byBase[base] ??= <String>[]).add(name);
    }

    for (final candidate in sidecarBaseNames) {
      final hits = byBase[candidate];
      if (hits == null || hits.isEmpty) continue;
      // 同基名有多个扩展名（folder.jpg 与 folder.png 并存）时取字典序第一，
      // 保证结果稳定。
      final sorted = [...hits]..sort();
      return sorted.first;
    }

    final sorted = [...images]..sort();
    return sorted.first;
  }

  /// 该文件名是否可能是专辑封面图（供扫描时收集用）。
  static bool isSidecarImageName(String fileName) {
    return sidecarImageExtensions.contains(p.extension(fileName).toLowerCase());
  }

  /// 取文件所在目录（规范化后）。同一目录的歌属于同一张专辑。
  static String directoryOf(String path) {
    final normalized = path.replaceAll('\\', '/');
    final idx = normalized.lastIndexOf('/');
    return idx <= 0 ? normalized : normalized.substring(0, idx);
  }

  /// 按目录分组。返回 `目录 → 该目录下的条目`。
  ///
  /// 保持插入顺序（`LinkedHashMap`），于是「同目录第一首」的定义是稳定的：
  /// 就是扫描顺序里的第一首，不会因为 Map 遍历顺序变化而在两次扫描间抖动。
  static Map<String, List<T>> groupByDirectory<T>(
    List<T> items,
    String Function(T item) pathOf,
  ) {
    final result = <String, List<T>>{};
    for (final item in items) {
      final dir = directoryOf(pathOf(item));
      (result[dir] ??= <T>[]).add(item);
    }
    return result;
  }
}
