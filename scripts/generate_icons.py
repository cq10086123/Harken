#!/usr/bin/env python3
"""Harken 应用图标生成器（单一矢量源 → 全平台资源）。

设计：**声波 H**。
- 白色粗体字母 H（品牌首字母）；
- H 的横杠化作一条流动的正弦声波 —— 一个笔画同时是「字母」与「音频」；
- 深海军蓝渐变底（#1E3A6B → #0B1830）+ 纯白主体。

比例依据（对标 Spotify / Apple Music 一类一线 App 图标）：
- 竖笔粗细 ≈ 画布 13%，波形横杠略细（≈10.8%）
- 标记占画布宽度 62%，视觉重心居中
- 只有 3 个形状（两竖 + 波形横杠），无渐变于标记上、无辉光、无投影

底色本身是深色，明暗模式下观感一致，因此不再区分亮/暗两套资源。
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
    stem_w=0.132,        # 竖笔宽 = 画布 13.2%
    h_gap=0.206,         # 两竖之间净空
    h_top=0.200,
    h_bottom=0.800,
    # ---- 横杠：化作正弦声波 ----
    wave_amp=0.056,      # 振幅（画布比例）
    wave_periods=1.0,    # 一个完整周期
    wave_t=0.108,        # 波形横杠的厚度
    wave_taper=0.16,     # 波峰处略微加粗，避免视觉上比竖笔细
    wave_ends=0.55,      # 波形端点伸入竖笔内部的比例（按竖笔宽归一），保证无缝
    # ---- 光学取景 ----
    mark_w=0.62,
    mark_cy=0.5,
)

# 品牌配色：深海军蓝渐变 + 纯白标记
BRAND_BG_TOP = "#1E3A6B"
BRAND_BG_BOTTOM = "#0B1830"
BRAND_MARK = "#FFFFFF"

# 配色
LIGHT = dict(bg="#F02B3C", mark="#FFFFFF")
DARK = dict(bg="#101014", mark="#FFFFFF")

# 八分音符在所有尺寸下都清晰（16px 实测可读），无需按尺寸简化标记。

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

def mark_polygons(params=None, mark_w=None, mark_cy=None):
    p = dict(params or MARK)
    return framing(h_wave_polygons(p),
                   p["mark_w"] if mark_w is None else mark_w,
                   p["mark_cy"] if mark_cy is None else mark_cy)


def h_wave_polygons(p, *, detail=1.0):
    """声波 H：左竖 + 右竖 + 一条正弦波形横杠。

    波形端点伸入竖笔内部（wave_ends），因此横杠与竖笔之间不会出现接缝或缺口。
    波形两端相位归零，端点正好落在中线上，被竖笔遮住。
    """
    sw, gap = p["stem_w"], p["h_gap"]
    top, bottom = p["h_top"], p["h_bottom"]
    total = sw * 2 + gap
    lx = 0.5 - total / 2
    rx = lx + sw + gap
    mid = (top + bottom) / 2

    polys = [rrect(lx, top, lx + sw, bottom, sw * 0.40),
             rrect(rx, top, rx + sw, bottom, sw * 0.40)]

    x0 = lx + sw * p["wave_ends"]
    x1 = rx + sw * (1 - p["wave_ends"])
    n = max(40, int(260 * detail))
    up, dn = [], []
    for i in range(n + 1):
        t = i / n
        x = x0 + (x1 - x0) * t
        # 两端相位归零：端点落在中线上，被竖笔完全遮住
        y = mid + p["wave_amp"] * math.sin(2 * math.pi * p["wave_periods"] * t)
        w = p["wave_t"] * (1.0 + p["wave_taper"] * math.sin(math.pi * t))
        up.append((x, y - w / 2))
        dn.append((x, y + w / 2))
    polys.append(up + dn[::-1])
    return polys


def circle_pts(cx, cy, r, n=200):
    return [(cx + r * math.cos(2 * math.pi * i / n),
             cy + r * math.sin(2 * math.pi * i / n)) for i in range(n)]


def bez(p0, c1, c2, p3, n=120):
    out = []
    for i in range(n + 1):
        t = i / n
        u = 1 - t
        out.append((
            u ** 3 * p0[0] + 3 * u * u * t * c1[0] + 3 * u * t * t * c2[0] + t ** 3 * p3[0],
            u ** 3 * p0[1] + 3 * u * u * t * c1[1] + 3 * u * t * t * c2[1] + t ** 3 * p3[1],
        ))
    return out


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


def max_radius(mark_w: float) -> float:
    """标记在当前 mark_w 下的最大顶点半径（相对画布宽度），用于安全区反解。"""
    polys = mark_polygons(mark_w=mark_w)
    return max(math.hypot(x - 0.5, y - 0.5) for poly in polys for x, y in poly)


def fit_mark_w(safe_ratio: float) -> float:
    """求满足给定安全半径（相对画布宽度）的最大 mark_w。"""
    return safe_ratio / max_radius(1.0)


# --------------------------------------------------------------------------
# SVG 输出
# --------------------------------------------------------------------------

def build_svg(width: int, *, gradient=True, bg=None, mark=BRAND_MARK, mark_w=None,
              mark_cy=None, radius=0.0) -> str:
    """渲染标记。

    gradient=True 时底色为品牌渐变（左上深→右下更深）；否则用 bg 指定纯色，
    bg=None 表示透明底（用于开屏 / 主题图标等需要叠在别处的情形）。
    """
    polys = mark_polygons(mark_w=mark_w, mark_cy=mark_cy)
    rx = f' rx="{f(radius * width)}" ry="{f(radius * width)}"' if radius else ""
    defs = ""
    if gradient:
        defs = ('<defs><linearGradient id="brandBg" x1="0" y1="0" x2="1" y2="1">'
                f'<stop offset="0" stop-color="{BRAND_BG_TOP}"/>'
                f'<stop offset="1" stop-color="{BRAND_BG_BOTTOM}"/>'
                '</linearGradient></defs>')
        bg = "url(#brandBg)"
    body = defs
    if bg:
        body += f'<rect width="{width}" height="{width}"{rx} fill="{bg}"/>'
    body += "".join(f'<path d="{path_of(poly, width)}" fill="{mark}"/>' for poly in polys)
    return (f'<svg xmlns="http://www.w3.org/2000/svg" width="{width}" height="{width}" '
            f'viewBox="0 0 {width} {width}">\n{body}\n</svg>\n')


def build_mono_svg(size: int, *, mark_w=None) -> str:
    """单色剪影（模板图标：读屏状态栏 / Android 主题化图标）。"""
    polys = mark_polygons(mark_w=mark_w)
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
    # 传统方形图标：底色本身是深海军蓝，明暗模式观感一致，故只有一套
    for dens, size in ANDROID_MIPMAPS.items():
        r.png(build_svg(size),
              p(f"android/app/src/main/res/mipmap-{dens}/ic_launcher.png"), size)

    # 自适应图标前景：白色标记 + 透明底，底色由 drawable 渐变给出
    adaptive_mw = round(fit_mark_w(33.0 / 108.0), 4)      # 中心 66dp 安全圆
    print(f"  自适应前景 mark_w={adaptive_mw}（安全圆 66/108dp）")
    for dens, size in ANDROID_ADAPTIVE.items():
        r.png(build_svg(size, gradient=False, bg=None, mark_w=adaptive_mw),
              p(f"android/app/src/main/res/mipmap-{dens}/ic_launcher_foreground.png"),
              size)

    write(p("android/app/src/main/res/mipmap-anydpi-v26/ic_launcher.xml"),
          '''<?xml version="1.0" encoding="utf-8"?>
<!-- 自适应图标（Android 8+）：渐变底 + 前景标记 + 单色层（Android 13+ 主题图标）。 -->
<adaptive-icon xmlns:android="http://schemas.android.com/apk/res/android">
    <background android:drawable="@drawable/ic_launcher_background" />
    <foreground android:drawable="@mipmap/ic_launcher_foreground" />
    <monochrome android:drawable="@drawable/ic_launcher_monochrome" />
</adaptive-icon>
''')
    write(p("android/app/src/main/res/drawable/ic_launcher_background.xml"),
          f'''<?xml version="1.0" encoding="utf-8"?>
<!-- 自适应图标底色：与位图图标同源的深海军蓝渐变（左上浅 → 右下深）。
     angle=315 表示渐变方向指向左上，与 SVG 的 1,1 → 0,0 走向一致。 -->
<shape xmlns:android="http://schemas.android.com/apk/res/android"
    android:shape="rectangle">
    <gradient
        android:startColor="{BRAND_BG_BOTTOM}"
        android:endColor="{BRAND_BG_TOP}"
        android:angle="315" />
</shape>
''')
    write(p("android/app/src/main/res/drawable/ic_launcher_monochrome.xml"),
          build_mono_vector_drawable(mark_w=0.62))

    # 开屏 Logo：整枚图标（渐变底 + 白标），在明暗两种开屏背景上都成立
    r.png(build_svg(256, mark_w=0.62),
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
        # 去掉 alpha（App Store 审核要求）
        r.png(build_svg(px), os.path.join(base, name), px, opaque=BRAND_BG_BOTTOM)
    # 启动图：整枚图标居中（渐变底自身可见，无需依赖启动背景色）
    launch = p("ios/Runner/Assets.xcassets/LaunchImage.imageset")
    for name, scale in (("LaunchImage.png", 1), ("LaunchImage@2x.png", 2),
                        ("LaunchImage@3x.png", 3)):
        pw, ph = 168 * scale, 185 * scale
        icon = round(min(pw, ph) * 0.72)
        svg = build_svg(icon, radius=0.22)
        r.png(svg, os.path.join(launch, name), icon)
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
        r.png(build_svg(px), os.path.join(base, name), px)
    # 菜单栏模板图标：单色剪影（系统按明暗自动反色）
    write(p("macos/Runner/Assets.xcassets/StatusBarIcon.imageset/status_bar_icon.svg"),
          build_mono_svg(18, mark_w=0.86))
    print("  macOS 图标完成")


def gen_windows(r: Raster) -> None:
    sizes = (16, 24, 32, 48, 64, 128, 256)
    tmp = []
    for size in sizes:
        out = os.path.join(r.tmp, f"win_{size}.png")
        r.png(build_svg(size), out, size)
        tmp.append(out)
    r.ico(tmp, p("windows/runner/resources/app_icon.ico"))
    print("  Windows 图标完成")


def gen_tray(r: Raster) -> None:
    """托盘图标：整枚图标（含渐变底）。透明底白标在浅色任务栏上不可见，
    故托盘统一用完整图标，深浅任务栏都能看清。"""
    sizes = (16, 20, 24, 32, 48, 64, 128, 256)
    tmp = []
    for size in sizes:
        out = os.path.join(r.tmp, f"tray_{size}.png")
        r.png(build_svg(size, radius=0.20 if size >= 32 else 0.0), out, size)
        tmp.append(out)
    r.ico(tmp, p("assets/icon/app_icon.ico"))
    print("  托盘图标完成")


def gen_web(r: Raster) -> None:
    r.png(build_svg(512), p("assets/icon/app_icon.png"), 512)
    r.png(build_svg(512), p("web/icons/Icon-512.png"), 512)
    r.png(build_svg(192), p("web/icons/Icon-192.png"), 192)
    maskable_mw = round(fit_mark_w(0.40), 4)      # maskable 安全区半径 40%
    print(f"  maskable 图标 mark_w={maskable_mw}（安全区半径 40%）")
    for size in (192, 512):
        r.png(build_svg(size, mark_w=maskable_mw),
              p(f"web/icons/Icon-maskable-{size}.png"), size)
    r.png(build_svg(32), p("web/favicon.png"), 32)
    print("  Web / 应用内图标完成")


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--svg-only", action="store_true", help="只写矢量源，不渲染位图")
    args = ap.parse_args()

    write(p("assets/icon/app_icon.svg"), build_svg(1024))
    write(p("assets/icon/app_icon_mono.svg"), build_mono_svg(512, mark_w=0.62))
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
