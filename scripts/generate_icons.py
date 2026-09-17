#!/usr/bin/env python3
"""Harken 应用图标生成器（单一矢量源 → 全平台资源）。

设计：**H + 声波弧**。
- H：品牌名首字母；
- 声波弧：Harken 本义「倾听 / 聆听」，同时表达音频与音乐。
纯色扁平、无渐变、无辉光、无投影 —— 只有 5 个形状（两竖 + 横梁 + 两道弧）。

深浅两套：
- 亮色：红底 #F02B3C + 白标
- 暗色：黑底 #101014 + 白标
跟随系统的平台（Android 资源限定符、浏览器 favicon 媒体查询）出两套；
Dock / 任务栏图标系统不支持切换的平台用亮色版。

用法：
    python3 scripts/generate_icons.py             # 生成全部平台资源
    python3 scripts/generate_icons.py --svg-only  # 只写矢量源

依赖：写 SVG / XML 无需依赖；位图渲染优先 resvg
（`npm i @resvg/resvg-js`，逐尺寸直出），否则回落 ImageMagick。
"""

from __future__ import annotations

import argparse
import json
import math
import os
import shutil
import subprocess
import sys
import tempfile

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

# --------------------------------------------------------------------------
# 设计参数：坐标为 0~1 画布比例，渲染时按目标尺寸缩放
# --------------------------------------------------------------------------

MARK = dict(
    # ---- H 字形 ----
    h_left=0.085,        # 左竖左边缘
    stem_w=0.140,        # 竖笔画宽
    h_gap=0.180,         # 两竖之间净空（H 的"口"）
    h_top=0.225,
    h_bottom=0.775,
    # ---- 声波弧 ----
    # 圆心地设在 H 右边缘，半径由「等间隙」反推：arc1 内缘 = H 右边缘 + wave_gap，
    # arc(n+1) 内缘 = arc(n) 外缘 + wave_gap。这样三道间隙在中轴上完全相等，
    # 才读得出「波」；若直接给半径，H→arc1 的间隙会比 arc1→arc2 大 3 倍。
    wave_gap=0.100,      # 弧与 H / 弧与弧之间的间隙
    wave_w=0.066,        # 弧线粗细
    wave_count=2,
    wave_span=46.0,      # 弧的张开半角（度）
    # ---- 光学取景 ----
    mark_w=0.60,         # 品牌标记占画布宽度比例
    mark_cy=0.5,
)

# 配色
LIGHT = dict(bg="#F02B3C", mark="#FFFFFF")
DARK = dict(bg="#101014", mark="#FFFFFF")

# 小尺寸简化：小于 48px 时去掉声波弧（间隙不足 2px 会糊成一片），只保留 H
SIMPLIFY_BELOW = 48


# --------------------------------------------------------------------------
# 基础几何
# --------------------------------------------------------------------------

def f(v: float) -> str:
    return f"{v:.3f}".rstrip("0").rstrip(".")


def _arc(cx, cy, r, a0, a1, n=20):
    return [(cx + r * math.cos(math.radians(a0 + (a1 - a0) * i / n)),
             cy + r * math.sin(math.radians(a0 + (a1 - a0) * i / n)))
            for i in range(n + 1)]


def rrect(x0, y0, x1, y1, r):
    """圆角矩形（顺时针）。"""
    r = min(r, (x1 - x0) / 2, (y1 - y0) / 2)
    return (_arc(x0 + r, y0 + r, r, 180, 270) +
            _arc(x1 - r, y0 + r, r, 270, 360) +
            _arc(x1 - r, y1 - r, r, 0, 90) +
            _arc(x0 + r, y1 - r, r, 90, 180))


def arc_band(cx, cy, r, w, a0, a1, n=48):
    """圆弧带：外弧去 + 内弧回，构成有粗细的弧线。"""
    ro, ri = r + w / 2, r - w / 2
    return (_arc(cx, cy, ro, a0, a1, n) + _arc(cx, cy, ri, a1, a0, n))


def _signed_area(poly) -> float:
    a = 0.0
    for i in range(len(poly)):
        x1, y1 = poly[i]
        x2, y2 = poly[(i + 1) % len(poly)]
        a += x1 * y2 - x2 * y1
    return a / 2


def ensure_cw(poly):
    """统一为顺时针，避免 nonzero 填充下子路径互相抵消出现空洞。"""
    return poly if _signed_area(poly) > 0 else poly[::-1]


def path_of(poly, px) -> str:
    return "M " + " L ".join(f"{f(x * px)},{f(y * px)}" for x, y in poly) + " Z"


# --------------------------------------------------------------------------
# 标记几何
# --------------------------------------------------------------------------

def h_glyph(p, *, with_waves=True):
    """H（两竖 + 横梁）+ 可选声波弧。返回画布比例坐标下的多边形列表。"""
    sw, gap = p["stem_w"], p["h_gap"]
    left = p["h_left"]
    right = left + sw + gap
    top, bottom = p["h_top"], p["h_bottom"]
    mid = (top + bottom) / 2
    bar_h = sw * 1.04
    # 笔画终端圆角、横梁接头略小 —— 视觉上不至于在拐角处鼓包
    polys = [
        rrect(left, top, left + sw, bottom, sw * 0.5),
        rrect(right, top, right + sw, bottom, sw * 0.5),
        rrect(left + sw, mid - bar_h / 2, right, mid + bar_h / 2, sw * 0.30),
    ]
    if with_waves:
        cx = right + sw                      # 圆心落在 H 右边缘
        r = p["wave_gap"] + p["wave_w"] / 2  # arc1 半径：内缘距 H 右边缘 wave_gap
        for _ in range(p["wave_count"]):
            polys.append(arc_band(cx, mid, r, p["wave_w"],
                                  -p["wave_span"], p["wave_span"]))
            r += p["wave_gap"] + p["wave_w"]
    return polys


def framing(polys, mark_w, mark_cy):
    """按标记自身包围盒做等比缩放 + 居中，保证各尺寸留白一致。"""
    xs = [x for poly in polys for x, _ in poly]
    ys = [y for poly in polys for _, y in poly]
    bx0, bx1, by0, by1 = min(xs), max(xs), min(ys), max(ys)
    bw = bx1 - bx0
    s = mark_w / bw if bw else 1.0
    bcx, bcy = (bx0 + bx1) / 2, (by0 + by1) / 2
    tx = 0.5 - bcx * s
    ty = mark_cy - bcy * s
    return [[(x * s + tx, y * s + ty) for x, y in poly] for poly in polys]


def mark_polygons(params=None, mark_w=None, mark_cy=None, *, with_waves=True):
    p = dict(params or MARK)
    return framing(h_glyph(p, with_waves=with_waves),
                   p["mark_w"] if mark_w is None else mark_w,
                   p["mark_cy"] if mark_cy is None else mark_cy)


def max_radius(mark_w: float, *, with_waves=True) -> float:
    """标记在当前 mark_w 下的最大顶点半径（相对画布宽度），用于安全区反解。"""
    polys = mark_polygons(mark_w=mark_w, with_waves=with_waves)
    return max(math.hypot(x - 0.5, y - 0.5) for poly in polys for x, y in poly)


def fit_mark_w(safe_ratio: float, *, with_waves=True) -> float:
    """求满足给定安全半径（相对画布宽度）的最大 mark_w。"""
    return safe_ratio / max_radius(1.0, with_waves=with_waves)


# --------------------------------------------------------------------------
# SVG 输出
# --------------------------------------------------------------------------

def build_svg(width: int, *, bg=None, mark="#FFFFFF", mark_w=None,
              mark_cy=None, with_waves=True, radius=0.0) -> str:
    polys = mark_polygons(mark_w=mark_w, mark_cy=mark_cy, with_waves=with_waves)
    body = ""
    if bg:
        if radius:
            body += (f'<rect width="{width}" height="{width}" '
                     f'rx="{f(radius * width)}" ry="{f(radius * width)}" fill="{bg}"/>')
        else:
            body += f'<rect width="{width}" height="{width}" fill="{bg}"/>'
    body += "".join(f'<path d="{path_of(poly, width)}" fill="{mark}"/>' for poly in polys)
    return (f'<svg xmlns="http://www.w3.org/2000/svg" width="{width}" height="{width}" '
            f'viewBox="0 0 {width} {width}">\n{body}\n</svg>\n')


def build_mono_svg(size: int, *, with_waves=True, mark_w=None) -> str:
    """单色剪影（模板图标：读屏状态栏 / Android 主题化图标）。"""
    polys = mark_polygons(mark_w=mark_w, with_waves=with_waves)
    d = " ".join(path_of(ensure_cw(poly), size) for poly in polys)
    return (f'<svg xmlns="http://www.w3.org/2000/svg" width="{size}" height="{size}" '
            f'viewBox="0 0 {size} {size}">\n<path fill="#000000" '
            f'fill-rule="nonzero" d="{d}"/>\n</svg>\n')


def build_mono_vector_drawable(size: int = 108, *, mark_w=None) -> str:
    """Android VectorDrawable 单色层（Android 13+ 主题图标）。"""
    polys = mark_polygons(mark_w=mark_w)
    d = " ".join(path_of(ensure_cw(poly), size) for poly in polys)
    return f'''<?xml version="1.0" encoding="utf-8"?>
<vector xmlns:android="http://schemas.android.com/apk/res/android"
    android:width="{size}dp"
    android:height="{size}dp"
    android:viewportWidth="{size}"
    android:viewportHeight="{size}">
    <path
        android:fillColor="#000000"
        android:pathData="{d}" />
</vector>
'''


# --------------------------------------------------------------------------
# 位图渲染
# --------------------------------------------------------------------------

class Raster:
    """位图渲染：优先 resvg（逐尺寸直出），否则回落 ImageMagick。"""

    def __init__(self) -> None:
        self.tmp = tempfile.mkdtemp(prefix="harken-icons-")
        self.resvg = None
        node = shutil.which("node")
        if node:
            for base in (os.path.join(ROOT, "node_modules"),
                         "/tmp/tools/node_modules",
                         os.path.join(self.tmp, "node_modules")):
                mod = os.path.join(base, "@resvg", "resvg-js")
                if os.path.isdir(mod):
                    self.resvg = (node, mod)
                    break
        self.magick = shutil.which("magick") or shutil.which("convert")

    def _resvg_png(self, svg_text, out, size, opaque=None) -> bool:
        node, mod = self.resvg
        js = os.path.join(self.tmp, "r.js")
        with open(js, "w") as fh:
            fh.write(
                "const {Resvg}=require(process.argv[2]);const fs=require('fs');"
                "const r=new Resvg(fs.readFileSync(process.argv[3],'utf8'),"
                "{fitTo:{mode:'width',value:+process.argv[5]},"
                "background:process.argv[6]});"
                "fs.writeFileSync(process.argv[4],r.render().asPng());")
        svg_file = os.path.join(self.tmp, "in.svg")
        with open(svg_file, "w") as fh:
            fh.write(svg_text)
        return subprocess.run(
            [node, js, mod, svg_file, out, str(size), opaque or "rgba(0,0,0,0)"],
            capture_output=True).returncode == 0

    def png(self, svg_text, out, size, *, opaque=None) -> None:
        os.makedirs(os.path.dirname(out), exist_ok=True)
        if self.resvg and self._resvg_png(svg_text, out, size, opaque):
            if opaque and self.magick:
                # iOS 图标不允许携带 alpha 通道（即使全不透明也会被审核拒绝）
                subprocess.run([self.magick, out, "-alpha", "off", "-strip", out],
                               check=False)
            return
        if not self.magick:
            sys.exit("缺少渲染工具：请安装 resvg（npm i @resvg/resvg-js）或 ImageMagick")
        master = os.path.join(self.tmp, "master.png")
        svg_file = os.path.join(self.tmp, "master.svg")
        with open(svg_file, "w") as fh:
            fh.write(svg_text)
        subprocess.run([self.magick, "-background", "none", svg_file,
                        "-resize", f"{size}x{size}", "-filter", "Lanczos",
                        "-strip", out], check=True)

    def ico(self, pngs, out) -> None:
        """把多个尺寸 PNG 合成多分辨率 .ico。"""
        if not self.magick:
            sys.exit("生成 .ico 需要 ImageMagick")
        os.makedirs(os.path.dirname(out), exist_ok=True)
        subprocess.run([self.magick] + list(pngs) + [out], check=True)


# --------------------------------------------------------------------------
# 各平台资源
# --------------------------------------------------------------------------

ANDROID_MIPMAPS = {"mdpi": 48, "hdpi": 72, "xhdpi": 96, "xxhdpi": 144, "xxxhdpi": 192}
ANDROID_ADAPTIVE = {"mdpi": 108, "hdpi": 162, "xhdpi": 216, "xxhdpi": 324, "xxxhdpi": 432}


def p(*parts) -> str:
    return os.path.join(ROOT, *parts)


def write(path: str, text: str) -> None:
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w") as fh:
        fh.write(text)
    print("  写入", os.path.relpath(path, ROOT))


def gen_android(r: Raster) -> None:
    # 传统方形图标：亮/暗两套（mipmap-night-* 供深色模式）
    for dens, size in ANDROID_MIPMAPS.items():
        r.png(build_svg(size, bg=LIGHT["bg"], mark=LIGHT["mark"]),
              p(f"android/app/src/main/res/mipmap-{dens}/ic_launcher.png"), size)
        r.png(build_svg(size, bg=DARK["bg"], mark=DARK["mark"]),
              p(f"android/app/src/main/res/mipmap-night-{dens}/ic_launcher.png"), size)

    # 自适应图标前景：白色标记 + 透明底，底色由资源给出，故深浅通用
    adaptive_mw = round(fit_mark_w(33.0 / 108.0), 4)      # 中心 66dp 安全圆
    print(f"  自适应前景 mark_w={adaptive_mw}（安全圆 66/108dp）")
    for dens, size in ANDROID_ADAPTIVE.items():
        r.png(build_svg(size, bg=None, mark="#FFFFFF", mark_w=adaptive_mw),
              p(f"android/app/src/main/res/mipmap-{dens}/ic_launcher_foreground.png"),
              size)

    write(p("android/app/src/main/res/mipmap-anydpi-v26/ic_launcher.xml"),
          '''<?xml version="1.0" encoding="utf-8"?>
<!-- 自适应图标（Android 8+）：底色 + 前景标记 + 单色层（Android 13+ 主题图标）。
     底色按 uiMode 切换（values / values-night），故前景用白色标记，深浅通用。 -->
<adaptive-icon xmlns:android="http://schemas.android.com/apk/res/android">
    <background android:drawable="@color/ic_launcher_background" />
    <foreground android:drawable="@mipmap/ic_launcher_foreground" />
    <monochrome android:drawable="@drawable/ic_launcher_monochrome" />
</adaptive-icon>
''')
    write(p("android/app/src/main/res/values/ic_launcher_background.xml"),
          f'''<?xml version="1.0" encoding="utf-8"?>
<resources>
    <!-- 自适应图标底色（亮色模式） -->
    <color name="ic_launcher_background">{LIGHT["bg"]}</color>
</resources>
''')
    write(p("android/app/src/main/res/values-night/ic_launcher_background.xml"),
          f'''<?xml version="1.0" encoding="utf-8"?>
<resources>
    <!-- 自适应图标底色（深色模式）：跟随系统切为黑底 -->
    <color name="ic_launcher_background">{DARK["bg"]}</color>
</resources>
''')
    write(p("android/app/src/main/res/drawable/ic_launcher_monochrome.xml"),
          build_mono_vector_drawable(mark_w=0.60))

    # 开屏 Logo：红色标记在白色 / 黑色开屏背景上都可见，故单份即可
    r.png(build_svg(256, bg=None, mark=LIGHT["bg"], mark_w=0.72),
          p("android/app/src/main/res/drawable-nodpi/launch_logo.png"), 256)
    print("  Android 图标完成")


def gen_ios(r: Raster) -> None:
    base = p("ios/Runner/Assets.xcassets/AppIcon.appiconset")
    with open(os.path.join(base, "Contents.json")) as fh:
        spec = json.load(fh)
    for image in spec["images"]:
        name = image.get("filename")
        if not name:
            continue
        px = int(round(float(image["size"].split("x")[0]) * float(image["scale"].rstrip("x"))))
        # 小尺寸用简化标记；并去掉 alpha（App Store 审核要求）
        r.png(build_svg(px, bg=LIGHT["bg"], mark=LIGHT["mark"],
                        with_waves=px >= SIMPLIFY_BELOW),
              os.path.join(base, name), px, opaque=LIGHT["bg"])
    launch = p("ios/Runner/Assets.xcassets/LaunchImage.imageset")
    for name, scale in (("LaunchImage.png", 1), ("LaunchImage@2x.png", 2),
                        ("LaunchImage@3x.png", 3)):
        pw, ph = 168 * scale, 185 * scale
        side = min(pw, ph)
        svg = build_svg(side, bg=None, mark=LIGHT["bg"], mark_w=0.72)
        # 启动图画布为 2:3 左右，标记在其中的正方形区域内居中
        svg = svg.replace('<svg ', f'<svg ', 1).replace(
            f'viewBox="0 0 {side} {side}"',
            f'viewBox="{-round((pw - side) / 2)} {-round((ph - side) / 2)} {pw} {ph}"')
        svg = svg.replace(f'width="{side}" height="{side}"', f'width="{pw}" height="{ph}"')
        r.png(svg, os.path.join(launch, name), pw)
    print("  iOS 图标完成")


def gen_macos(r: Raster) -> None:
    base = p("macos/Runner/Assets.xcassets/AppIcon.appiconset")
    with open(os.path.join(base, "Contents.json")) as fh:
        spec = json.load(fh)
    for image in spec["images"]:
        name = image.get("filename")
        if not name:
            continue
        px = int(round(float(image["size"].split("x")[0]) * float(image["scale"].rstrip("x"))))
        r.png(build_svg(px, bg=LIGHT["bg"], mark=LIGHT["mark"],
                        with_waves=px >= SIMPLIFY_BELOW),
              os.path.join(base, name), px)
    # 菜单栏模板图标：单色剪影（系统按明暗自动反色）；18pt 用简化标记保证可读
    write(p("macos/Runner/Assets.xcassets/StatusBarIcon.imageset/status_bar_icon.svg"),
          build_mono_svg(18, with_waves=False, mark_w=0.86))
    print("  macOS 图标完成")


def gen_windows(r: Raster) -> None:
    sizes = (16, 24, 32, 48, 64, 128, 256)
    tmp = []
    for s in sizes:
        out = os.path.join(r.tmp, f"win_{s}.png")
        r.png(build_svg(s, bg=LIGHT["bg"], mark=LIGHT["mark"],
                        with_waves=s >= SIMPLIFY_BELOW), out, s)
        tmp.append(out)
    r.ico(tmp, p("windows/runner/resources/app_icon.ico"))
    print("  Windows 图标完成")


def gen_tray(r: Raster) -> None:
    """托盘图标：透明底标记，深浅任务栏都可见；小尺寸用简化标记。"""
    sizes = (16, 20, 24, 32, 48, 64, 128, 256)
    tmp = []
    for s in sizes:
        out = os.path.join(r.tmp, f"tray_{s}.png")
        r.png(build_svg(s, bg=None, mark=LIGHT["bg"], mark_w=0.88,
                        with_waves=s >= SIMPLIFY_BELOW), out, s)
        tmp.append(out)
    r.ico(tmp, p("assets/icon/app_icon.ico"))
    print("  托盘图标完成")


def gen_web(r: Raster) -> None:
    # 应用内 Logo / PWA 图标：亮色版
    r.png(build_svg(512, bg=LIGHT["bg"], mark=LIGHT["mark"]), p("assets/icon/app_icon.png"), 512)
    r.png(build_svg(512, bg=LIGHT["bg"], mark=LIGHT["mark"]), p("web/icons/Icon-512.png"), 512)
    r.png(build_svg(192, bg=LIGHT["bg"], mark=LIGHT["mark"]), p("web/icons/Icon-192.png"), 192)
    maskable_mw = round(fit_mark_w(0.40), 4)      # maskable 安全区半径 40%
    print(f"  maskable 图标 mark_w={maskable_mw}（安全区半径 40%）")
    for s in (192, 512):
        r.png(build_svg(s, bg=LIGHT["bg"], mark=LIGHT["mark"], mark_w=maskable_mw),
              p(f"web/icons/Icon-maskable-{s}.png"), s)
    # 浏览器 favicon：亮/暗两套，由 index.html 的媒体查询切换
    r.png(build_svg(32, bg=LIGHT["bg"], mark=LIGHT["mark"], with_waves=False),
          p("web/favicon.png"), 32)
    r.png(build_svg(32, bg=DARK["bg"], mark=DARK["mark"], with_waves=False),
          p("web/favicon-dark.png"), 32)
    print("  Web / 应用内图标完成")


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--svg-only", action="store_true", help="只写矢量源，不渲染位图")
    args = ap.parse_args()

    write(p("assets/icon/app_icon.svg"),
          build_svg(1024, bg=LIGHT["bg"], mark=LIGHT["mark"]))
    write(p("assets/icon/app_icon_dark.svg"),
          build_svg(1024, bg=DARK["bg"], mark=DARK["mark"]))
    write(p("assets/icon/app_icon_mono.svg"),
          build_mono_svg(512, mark_w=0.60))
    if args.svg_only:
        return

    r = Raster()
    print("· 渲染器：", "resvg" if r.resvg else f"ImageMagick ({r.magick})")
    gen_android(r)
    gen_ios(r)
    gen_macos(r)
    gen_windows(r)
    gen_tray(r)
    gen_web(r)
    print("\n完成。已更新全部平台图标资源。")


if __name__ == "__main__":
    main()
