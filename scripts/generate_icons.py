#!/usr/bin/env python3
"""App 图标生成器（单一矢量源 → 全平台资源）。

设计：Harken「牛角音符」—— 深空黑底 + 红色牛角/音符，呼应 fnOS 品牌调性。
所有平台图标都由本脚本从同一份几何定义生成，改一处即可全局重出。

用法：
    python3 scripts/generate_icons.py            # 生成全部平台资源
    python3 scripts/generate_icons.py --svg-only  # 只写矢量源（不渲染位图）

依赖：
    - 写 SVG / XML 无需依赖；
    - 渲染位图优先用 resvg（`npm i @resvg/resvg-js`，质量最好，逐尺寸直出），
      否则回落到 ImageMagick 的 `convert`（从 1024 母版降采样）。
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
# 几何：坐标为 0~1 的画布比例，渲染时按目标尺寸缩放
# --------------------------------------------------------------------------

MARK = dict(
    # 牛角中线（从音符头两侧向上外扩，末端向内勾出尖端）
    h_base_x=0.478, h_base_y=0.610,
    h_c1_x=0.300, h_c1_y=0.715,
    h_c2_x=0.135, h_c2_y=0.545,
    h_tip_x=0.150, h_tip_y=0.235,
    h_w_base=0.100, h_w_tip=0.0018, h_taper=0.88, h_steps=72,
    # 音符头（实心圆，压在牛角根部之上，读作牛鼻/牛脸）
    head_x=0.5, head_y=0.700, head_r=0.133,
    # 符干
    stem_x=0.461, stem_top=0.190, stem_bottom=0.700, stem_w=0.078,
    # 符尾（八分音符小旗）
    flag_x0=0.539, flag_y0=0.193, flag_w=0.200, flag_h=0.222,
    flag_w_base=0.052, flag_w_tip=0.004, flag_taper=1.0, flag_steps=36,
    # 背景辉光
    glow_cy=0.55, glow_rx=0.46, glow_ry=0.41, glow_a=0.25,
    # 光学取景：品牌标记占画布宽度比例 / 垂直中心
    mark_w=0.76, mark_cy=0.495,
)

BRAND = dict(
    bg_top="#1A1A21",
    bg_mid="#0C0C11",
    bg_bottom="#07070A",
    red_hi="#FF6E7B",
    red="#ED2C40",
    red_deep="#C01125",
    red_dark="#870916",
    head_mid="#E01B2E",
    head_dark="#8A0A17",
    glow="#FF3B4E",
    glow_deep="#B3121F",
)


# --------------------------------------------------------------------------
# 基础几何工具
# --------------------------------------------------------------------------

def f(v: float) -> str:
    return f"{v:.3f}".rstrip("0").rstrip(".")


def bez(p0, c1, c2, p3, n):
    out = []
    for i in range(n + 1):
        t = i / n
        u = 1 - t
        out.append((
            u ** 3 * p0[0] + 3 * u * u * t * c1[0] + 3 * u * t * t * c2[0] + t ** 3 * p3[0],
            u ** 3 * p0[1] + 3 * u * u * t * c1[1] + 3 * u * t * t * c2[1] + t ** 3 * p3[1],
        ))
    return out


def ribbon(center, w_start, w_end, taper=0.9):
    """沿中线生成两端收细的带状多边形（牛角 / 符尾）。"""
    n = len(center) - 1
    left, right = [], []
    for i, (x, y) in enumerate(center):
        if i == 0:
            tx, ty = center[1][0] - x, center[1][1] - y
        elif i == n:
            tx, ty = x - center[i - 1][0], y - center[i - 1][1]
        else:
            tx = center[i + 1][0] - center[i - 1][0]
            ty = center[i + 1][1] - center[i - 1][1]
        ln = math.hypot(tx, ty) or 1.0
        nx, ny = -ty / ln, tx / ln
        t = i / n
        w = w_end + (w_start - w_end) * (1 - t) ** taper
        left.append((x + nx * w, y + ny * w))
        right.append((x - nx * w, y - ny * w))
    return left + right[::-1]


def circle(cx, cy, r, n=128):
    return [(cx + r * math.cos(2 * math.pi * i / n),
             cy + r * math.sin(2 * math.pi * i / n)) for i in range(n)]


def arc(cx, cy, r, a0, a1, n=24):
    return [(cx + r * math.cos(math.radians(a0 + (a1 - a0) * i / n)),
             cy + r * math.sin(math.radians(a0 + (a1 - a0) * i / n)))
            for i in range(n + 1)]


def rounded_bar(x, y0, y1, w, r):
    cx = x + w / 2
    return [(x, y1), (x, y0 + r)] + arc(cx, y0 + r, r, 180, 360, 16) + [(x + w, y1)]


def mirror(poly, axis=0.5):
    return [(2 * axis - x, y) for x, y in poly]


def _signed_area(poly) -> float:
    a = 0.0
    n = len(poly)
    for i in range(n):
        x1, y1 = poly[i]
        x2, y2 = poly[(i + 1) % n]
        a += x1 * y2 - x2 * y1
    return a / 2.0


def ensure_cw(poly):
    """统一为顺时针，避免 nonzero 填充规则下多个子路径互相抵消出现空洞。"""
    return poly if _signed_area(poly) > 0 else poly[::-1]


def path_of(poly, px) -> str:
    return "M " + " L ".join(f"{f(x * px)},{f(y * px)}" for x, y in poly) + " Z"


# --------------------------------------------------------------------------
# 标记几何（返回 0~1 坐标下的多边形列表，按绘制顺序）
# --------------------------------------------------------------------------

def mark_polygons(p, detail: float = 1.0):
    horn = ribbon(
        bez((p["h_base_x"], p["h_base_y"]),
            (p["h_c1_x"], p["h_c1_y"]),
            (p["h_c2_x"], p["h_c2_y"]),
            (p["h_tip_x"], p["h_tip_y"]),
            max(8, int(p["h_steps"] * detail))),
        p["h_w_base"], p["h_w_tip"], taper=p["h_taper"],
    )
    polys = [horn, mirror(horn)]

    polys.append(rounded_bar(p["stem_x"], p["stem_top"], p["stem_bottom"],
                             p["stem_w"], p["stem_w"] * 0.5))

    if p["flag_w"] > 0:
        spines = bez((p["flag_x0"], p["flag_y0"]),
                     (p["flag_x0"] + p["flag_w"] * 0.62, p["flag_y0"] + p["flag_h"] * 0.04),
                     (p["flag_x0"] + p["flag_w"] * 0.98, p["flag_y0"] + p["flag_h"] * 0.44),
                     (p["flag_x0"] + p["flag_w"], p["flag_y0"] + p["flag_h"]),
                     max(8, int(p["flag_steps"] * detail)))
        polys.append(ribbon(spines, p["flag_w_base"], p["flag_w_tip"],
                            taper=p["flag_taper"]))

    # 音符头最后画：盖住牛角根部，读作牛脸
    polys.append(circle(p["head_x"], p["head_y"], p["head_r"],
                        max(20, int(128 * detail))))
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


# --------------------------------------------------------------------------
# SVG 渲染
# --------------------------------------------------------------------------

def build_svg(width: int, *, with_bg: bool = True, mark_w=None, mark_cy=None,
              detail: float = 1.0, params=None) -> str:
    p = dict(params or MARK)
    polys = framing(mark_polygons(p, detail),
                    p["mark_w"] if mark_w is None else mark_w,
                    p["mark_cy"] if mark_cy is None else mark_cy)
    glass = [(polys[0], "url(#horn)"), (polys[1], "url(#hornM)")]
    stem_flag = [(poly, "url(#horn)") for poly in polys[2:-1]]
    head = [(polys[-1], "url(#head)")]

    def group(items):
        return "".join(f'<path d="{path_of(poly, width)}" fill="{fill}"/>'
                       for poly, fill in items)

    body = group(glass) + group(stem_flag) + group(head)

    bg = ""
    if with_bg:
        bg = (f'<rect width="{width}" height="{width}" fill="url(#bg)"/>'
              f'<ellipse cx="{f(width * 0.5)}" cy="{f(width * p["glow_cy"])}" '
              f'rx="{f(width * p["glow_rx"])}" ry="{f(width * p["glow_ry"])}" '
              f'fill="url(#glow)"/>')

    defs = f'''<defs>
<linearGradient id="bg" x1="0" y1="0" x2="0.28" y2="1">
<stop offset="0" stop-color="{BRAND["bg_top"]}"/>
<stop offset="0.52" stop-color="{BRAND["bg_mid"]}"/>
<stop offset="1" stop-color="{BRAND["bg_bottom"]}"/>
</linearGradient>
<radialGradient id="glow" cx="0.5" cy="0.5" r="0.5">
<stop offset="0" stop-color="{BRAND["glow"]}" stop-opacity="{f(p["glow_a"])}"/>
<stop offset="0.62" stop-color="{BRAND["glow_deep"]}" stop-opacity="{f(p["glow_a"] * 0.38)}"/>
<stop offset="1" stop-color="{BRAND["glow_deep"]}" stop-opacity="0"/>
</radialGradient>
<linearGradient id="horn" x1="0.05" y1="0" x2="0.95" y2="1">
<stop offset="0" stop-color="{BRAND["red_hi"]}"/>
<stop offset="0.32" stop-color="{BRAND["red"]}"/>
<stop offset="0.70" stop-color="{BRAND["red_deep"]}"/>
<stop offset="1" stop-color="{BRAND["red_dark"]}"/>
</linearGradient>
<linearGradient id="hornM" x1="0.95" y1="0" x2="0.05" y2="1">
<stop offset="0" stop-color="{BRAND["red_hi"]}"/>
<stop offset="0.32" stop-color="{BRAND["red"]}"/>
<stop offset="0.70" stop-color="{BRAND["red_deep"]}"/>
<stop offset="1" stop-color="{BRAND["red_dark"]}"/>
</linearGradient>
<radialGradient id="head" cx="0.36" cy="0.26" r="0.9">
<stop offset="0" stop-color="#FF8590"/>
<stop offset="0.34" stop-color="{BRAND["head_mid"]}"/>
<stop offset="1" stop-color="{BRAND["head_dark"]}"/>
</radialGradient>
</defs>'''

    return (f'<svg xmlns="http://www.w3.org/2000/svg" width="{width}" height="{width}" '
            f'viewBox="0 0 {width} {width}">\n{defs}\n{bg}\n{body}\n</svg>\n')


def build_launch_svg(w: int, h: int, *, mark_w=0.80) -> str:
    """启动图：宽高比为 168:185 的画布，标记在其中的正方形区域内居中。"""
    side = min(w, h)
    polys = framing(mark_polygons(dict(MARK), 1.0), mark_w, 0.5)
    ox, oy = (w - side) / 2.0, (h - side) / 2.0
    body = "".join(
        f'<path d="{path_of([(x * side + ox, y * side + oy) for x, y in poly], 1)}" '
        f'fill="url(#horn)"/>' for poly in polys)
    return (f'<svg xmlns="http://www.w3.org/2000/svg" width="{w}" height="{h}" '
            f'viewBox="0 0 {w} {h}">\n'
            f'<defs><linearGradient id="horn" x1="0.05" y1="0" x2="0.95" y2="1">'
            f'<stop offset="0" stop-color="{BRAND["red_hi"]}"/>'
            f'<stop offset="0.32" stop-color="{BRAND["red"]}"/>'
            f'<stop offset="0.70" stop-color="{BRAND["red_deep"]}"/>'
            f'<stop offset="1" stop-color="{BRAND["red_dark"]}"/></linearGradient></defs>\n'
            f'{body}\n</svg>\n')


def build_mono_svg(size: int, *, detail: float = 0.22, mark_w=0.88) -> str:
    """单色剪影（模板图标：读屏状态栏 / Android 主题化图标）。"""
    polys = framing(mark_polygons(dict(MARK), detail), mark_w, 0.5)
    d = " ".join(path_of(ensure_cw(poly), size) for poly in polys)
    return (f'<svg xmlns="http://www.w3.org/2000/svg" width="{size}" height="{size}" '
            f'viewBox="0 0 {size} {size}">\n<path fill="#000000" '
            f'fill-rule="nonzero" d="{d}"/>\n</svg>\n')


def build_mono_vector_drawable(size: int = 108, *, mark_w=0.60) -> str:
    """Android VectorDrawable 单色层（Android 13+ 主题图标）。"""
    polys = framing(mark_polygons(dict(MARK), 0.22), mark_w, 0.5)
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
    """位图渲染器：优先 resvg（逐尺寸直出），否则回落到 ImageMagick。"""

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

    def _resvg_png(self, svg_text: str, out: str, size: int,
                   opaque: str | None = None) -> bool:
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

    def png(self, svg_text: str, out: str, size: int, *,
            opaque: str | None = None) -> None:
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
        if not os.path.exists(master):
            svg_file = os.path.join(self.tmp, "master.svg")
            with open(svg_file, "w") as fh:
                fh.write(build_svg(2048))
            subprocess.run([self.magick, "-background", "none", svg_file, master],
                           check=True)
        subprocess.run([self.magick, master, "-resize", f"{size}x{size}",
                        "-filter", "Lanczos", "-strip", out], check=True)

    def ico(self, pngs, out: str) -> None:
        """把多个尺寸 PNG 合成多分辨率 .ico。"""
        if not self.magick:
            sys.exit("生成 .ico 需要 ImageMagick")
        os.makedirs(os.path.dirname(out), exist_ok=True)
        subprocess.run([self.magick] + list(pngs) + [out], check=True)


# --------------------------------------------------------------------------
# 各平台资源生成
# --------------------------------------------------------------------------

def write(path: str, text: str) -> None:
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w") as fh:
        fh.write(text)
    print("  写入", os.path.relpath(path, ROOT))


def p(*parts) -> str:
    return os.path.join(ROOT, *parts)


ANDROID_MIPMAPS = {"mdpi": 48, "hdpi": 72, "xhdpi": 96, "xxhdpi": 144, "xxxhdpi": 192}
# 自适应图标前景：108dp 画布，标记必须落在中心 66dp 安全圆内（半径 33dp），
# 否则圆形/圆角蒙版会把牛角尖端裁掉。
ANDROID_ADAPTIVE = {"mdpi": 108, "hdpi": 162, "xhdpi": 216, "xxhdpi": 324, "xxxhdpi": 432}


def max_radius(mark_w: float, detail: float = 0.6) -> float:
    """标记在 mark_w 缩放下的最大顶点半径（相对画布宽度的比例）。"""
    polys = framing(mark_polygons(dict(MARK), detail), mark_w, 0.5)
    return max(math.hypot(x - 0.5, y - 0.5) for poly in polys for x, y in poly)


def fit_mark_w(safe_ratio: float, detail: float = 0.6) -> float:
    """求满足给定安全半径（相对画布宽度的比例）的最大 mark_w。"""
    return safe_ratio / max_radius(1.0, detail)


def gen_android(r: Raster) -> None:
    for dens, size in ANDROID_MIPMAPS.items():
        r.png(build_svg(size), p("android/app/src/main/res", f"mipmap-{dens}",
                                 "ic_launcher.png"), size)
    adaptive_mw = round(fit_mark_w(33.0 / 108.0), 3)   # 中心 66dp 安全圆
    print(f"  自适应前景 mark_w={adaptive_mw}（安全圆 66/108dp）")
    for dens, size in ANDROID_ADAPTIVE.items():
        r.png(build_svg(size, with_bg=False, mark_w=adaptive_mw, mark_cy=0.50),
              p("android/app/src/main/res", f"mipmap-{dens}",
                "ic_launcher_foreground.png"), size)
    write(p("android/app/src/main/res/mipmap-anydpi-v26/ic_launcher.xml"), '''<?xml version="1.0" encoding="utf-8"?>
<!-- 自适应图标（Android 8+）：底色 + 前景标记 + 单色层（Android 13+ 主题图标）。 -->
<adaptive-icon xmlns:android="http://schemas.android.com/apk/res/android">
    <background android:drawable="@color/ic_launcher_background" />
    <foreground android:drawable="@mipmap/ic_launcher_foreground" />
    <monochrome android:drawable="@drawable/ic_launcher_monochrome" />
</adaptive-icon>
''')
    write(p("android/app/src/main/res/values/ic_launcher_background.xml"), f'''<?xml version="1.0" encoding="utf-8"?>
<resources>
    <!-- 自适应图标底色：与图标画布同源的深空黑 -->
    <color name="ic_launcher_background">{BRAND["bg_mid"]}</color>
</resources>
''')
    write(p("android/app/src/main/res/drawable/ic_launcher_monochrome.xml"),
          build_mono_vector_drawable())
    # 开屏 Logo：透明底标记，白/黑开屏背景上均可见
    r.png(build_svg(256, with_bg=False, mark_w=0.96),
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
        size = float(image["size"].split("x")[0]) * float(image["scale"].rstrip("x"))
        px = int(round(size))
        r.png(build_svg(px), os.path.join(base, name), px, opaque=BRAND["bg_mid"])
    # 启动图：168x185pt 画布，标记在其中的正方形区域居中
    launch = p("ios/Runner/Assets.xcassets/LaunchImage.imageset")
    for name, scale in (("LaunchImage.png", 1), ("LaunchImage@2x.png", 2),
                        ("LaunchImage@3x.png", 3)):
        r.png(build_launch_svg(168 * scale, 185 * scale),
              os.path.join(launch, name), 168 * scale)
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
          build_mono_svg(18, detail=0.30, mark_w=0.92))
    print("  macOS 图标完成")


def gen_windows(r: Raster) -> None:
    sizes = (16, 24, 32, 48, 64, 128, 256)
    tmp = []
    for s in sizes:
        out = os.path.join(r.tmp, f"win_{s}.png")
        r.png(build_svg(s), out, s)
        tmp.append(out)
    r.ico(tmp, p("windows/runner/resources/app_icon.ico"))
    print("  Windows 图标完成")


def gen_tray(r: Raster) -> None:
    """托盘图标：透明底标记（深浅任务栏都可见），多分辨率。"""
    sizes = (16, 20, 24, 32, 48, 64, 128, 256)
    tmp = []
    for s in sizes:
        out = os.path.join(r.tmp, f"tray_{s}.png")
        r.png(build_svg(s, with_bg=False, mark_w=0.94), out, s)
        tmp.append(out)
    r.ico(tmp, p("assets/icon/app_icon.ico"))
    print("  托盘图标完成")


def gen_web(r: Raster) -> None:
    r.png(build_svg(512), p("assets/icon/app_icon.png"), 512)
    r.png(build_svg(512), p("web/icons/Icon-512.png"), 512)
    r.png(build_svg(192), p("web/icons/Icon-192.png"), 192)
    maskable_mw = round(fit_mark_w(0.40), 3)          # maskable 安全区半径 40%
    print(f"  maskable 图标 mark_w={maskable_mw}（安全区半径 40%）")
    for s in (192, 512):
        r.png(build_svg(s, mark_w=maskable_mw), p("web/icons", f"Icon-maskable-{s}.png"), s)
    r.png(build_svg(32), p("web/favicon.png"), 32)
    print("  Web / 应用内图标完成")


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--svg-only", action="store_true", help="只写矢量源，不渲染位图")
    args = ap.parse_args()

    write(p("assets/icon/app_icon.svg"), build_svg(1024))
    write(p("assets/icon/app_icon_mono.svg"), build_mono_svg(512, detail=1.0, mark_w=0.76))
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
