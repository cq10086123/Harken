#!/usr/bin/env python3
"""Harken 应用图标生成器（单一矢量源 → 全平台资源）。

设计：**流线声波**。
- 深海军蓝→青绿的对角渐变底（#1E2966 → #22B9DA）；
- 一条由多条白色细线扭成的声波带横贯画面，两端收束成一个尖点。

关键处理：
1. **包络收束** —— 每条线的振幅由 sin(pi t)^p 包络调制，两端归零，
   因此所有线在左右两端汇聚；各条线相位错开，中部自然展开成扭带。
2. **按尺寸分级** —— 尺寸越小线越少、线越粗、振荡次数越少。若始终用 26 条细线，
   48px 以下会相位混叠，看起来「峰数都变了」。
3. **安全区适配** —— 自适应图标 / maskable 图标必须留出中心安全区，
   故这两类把声波缩到画布 62% 居中，其余平台保持满幅。

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
# 设计参数
# --------------------------------------------------------------------------

WAVE = dict(
    amp=0.215,          # 振幅（画布比例）
    freq=3.0,           # 振荡次数（中部 3 个波峰）
    phase=-0.30,        # 起始相位
    spread=0.44,        # 各条线之间的相位错开量 —— 决定扭带的「展开宽度」
    envp=0.62,          # 包络幂次：越小越平坦、越大越集中在中间
    samples=460,        # 每条线的采样点数
)

# 按尺寸分级：(线数, 线宽占画布比例, 振荡次数, 相位错开量)
WAVE_TIERS = (
    (256, dict(n=26, stroke=0.0018, freq=3.0, spread=0.44)),
    (128, dict(n=26, stroke=0.0018, freq=3.0, spread=0.44)),
    (64,  dict(n=17, stroke=0.0027, freq=3.0, spread=0.42)),
    (32,  dict(n=11, stroke=0.0042, freq=2.0, spread=0.40)),
    (0,   dict(n=6,  stroke=0.0085, freq=1.5, spread=0.38)),
)

# 单色剪影用的是多条线的上下包络，线一少就出现内部白缝；
# 因此小尺寸把相位错开量加大，让剪影在小图标上依然是一整条实心扭带。
MONO_SPREAD_TIERS = ((128, 0.44), (0, 1.2))

BG_TOP = "#1E2966"          # 左上：深海军蓝
BG_BOTTOM = "#22B9DA"       # 右下：青绿
MARK = "#FFFFFF"

SQUIRCLE_R = 0.225          # 独立图标资源的圆角（应用内展示 / 托盘 / 开屏）
SAFE_MARK_W = 0.62          # 自适应 / maskable 图标的安全区缩放


def tier_for(size: int, over: dict | None = None) -> dict:
    p = next(t for lo, t in WAVE_TIERS if size >= lo)
    out = dict(p)
    if over:
        out.update(over)
    return out


def mono_tier_for(size: int) -> dict:
    return dict(spread=next(v for lo, v in MONO_SPREAD_TIERS if size >= lo))


# --------------------------------------------------------------------------
# 几何
# --------------------------------------------------------------------------

def f(v: float) -> str:
    return f"{v:.3f}".rstrip("0").rstrip(".")


def _envelope(t, p=0.62):
    """两端归零的包络 → 所有线在左右两端汇聚成一个尖点。"""
    return math.sin(math.pi * t) ** p


def wave_lines(n, amp, freq, phase, spread, envp, samples):
    """返回 n 条折线，每条为 [(t, y)]，t∈[0,1]，y 相对中线。"""
    lines = []
    for i in range(n):
        u = (i / (n - 1)) * 2 - 1 if n > 1 else 0.0     # -1..1
        ph = phase + u * spread
        line = []
        for k in range(samples + 1):
            t = k / samples
            y = -amp * _envelope(t, envp) * math.sin(2 * math.pi * freq * t + ph)
            line.append((t, y))
        lines.append(line)
    return lines


def wave_polys(size: int, *, mark_w=1.0, params=None) -> list[list[tuple[float, float]]]:
    """声波带的多条折线，已按 mark_w 缩放并居中。"""
    p = dict(params or WAVE)
    p.update(tier_for(size, params))
    sx = mark_w
    polys = []
    for line in wave_lines(p["n"], p["amp"], p["freq"], p["phase"],
                           p["spread"], p["envp"], p["samples"]):
        polys.append([(0.5 + (t - 0.5) * sx, 0.5 + y * sx) for t, y in line])
    return polys


def wave_svg_paths(size: int, *, mark_w=1.0, params=None):
    """返回 (path_d, stroke_width_px) 列表。"""
    p = dict(params or WAVE)
    p.update(tier_for(size, params))
    w = p["stroke"] * size
    out = []
    for poly in wave_polys(size, mark_w=mark_w, params=params):
        d = "M " + " L ".join(f"{f(x * size)},{f(y * size)}" for x, y in poly)
        out.append((d, w))
    return out


def band_closed_poly(mark_w=1.0, params=None, size=256):
    """把整条声波带取成**一条闭合多边形**（用于单色剪影 / 主题图标）。

    取所有线的上下包络：每列取最大与最小 y，构成带的轮廓。
    """
    p = dict(params or WAVE)
    p.update(tier_for(size, params))
    p.update(mono_tier_for(size))
    lines = wave_lines(p["n"], p["amp"], p["freq"], p["phase"],
                       p["spread"], p["envp"], p["samples"])
    m = len(lines[0])
    up, dn = [], []
    for k in range(m):
        t = lines[0][k][0]
        ys = [ln[k][1] for ln in lines]
        up.append((0.5 + (t - 0.5) * mark_w, 0.5 + min(ys) * mark_w))
        dn.append((0.5 + (t - 0.5) * mark_w, 0.5 + max(ys) * mark_w))
    return up + dn[::-1]


# --------------------------------------------------------------------------
# 通用绘图
# --------------------------------------------------------------------------

def ensure_cw(poly):
    """统一为顺时针，避免 nonzero 填充规则下子路径互相抵消出现空洞。"""
    a = 0.0
    for i in range(len(poly)):
        x1, y1 = poly[i]
        x2, y2 = poly[(i + 1) % len(poly)]
        a += x1 * y2 - x2 * y1
    return poly if a > 0 else poly[::-1]


def path_of(poly, px) -> str:
    return "M " + " L ".join(f"{f(x * px)},{f(y * px)}" for x, y in poly) + " Z"


def build_svg(size: int, *, radius=0.0, mark_w=1.0, mono=False,
              stroke_color=MARK) -> str:
    """完整图标：渐变底（可选圆角）+ 白色声波带。"""
    rx = f' rx="{f(radius * size)}" ry="{f(radius * size)}"' if radius else ""
    defs = (f'<defs><linearGradient id="brandBg" x1="0" y1="0" x2="1" y2="0.85">'
            f'<stop offset="0" stop-color="{BG_TOP}"/>'
            f'<stop offset="1" stop-color="{BG_BOTTOM}"/>'
            f'</linearGradient></defs>')
    body = defs + f'<rect width="{size}" height="{size}"{rx} fill="url(#brandBg)"/>'
    for d, w in wave_svg_paths(size, mark_w=mark_w):
        body += (f'<path d="{d}" fill="none" stroke="{stroke_color}" '
                 f'stroke-width="{f(w)}" stroke-linecap="round"/>')
    return (f'<svg xmlns="http://www.w3.org/2000/svg" width="{size}" height="{size}" '
            f'viewBox="0 0 {size} {size}">\n{body}\n</svg>\n')


def build_mono_svg(size: int, *, mark_w=1.0) -> str:
    """单色剪影（模板图标：读屏状态栏 / Android 主题化图标）。"""
    poly = ensure_cw(band_closed_poly(mark_w=mark_w, size=size))
    return (f'<svg xmlns="http://www.w3.org/2000/svg" width="{size}" height="{size}" '
            f'viewBox="0 0 {size} {size}">\n'
            f'<path fill="#000000" fill-rule="nonzero" d="{path_of(poly, size)}"/>\n'
            f'</svg>\n')


def build_mono_vector_drawable(size: int = 108, *, mark_w=SAFE_MARK_W) -> str:
    """Android VectorDrawable 单色层（Android 13+ 主题图标）。"""
    poly = ensure_cw(band_closed_poly(mark_w=mark_w, size=size))
    return f'''<?xml version="1.0" encoding="utf-8"?>
<vector xmlns:android="http://schemas.android.com/apk/res/android"
    android:width="{size}dp"
    android:height="{size}dp"
    android:viewportWidth="{size}"
    android:viewportHeight="{size}">
    <path
        android:fillColor="#000000"
        android:pathData="{path_of(poly, size)}" />
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
        svg_file = os.path.join(self.tmp, "master.svg")
        with open(svg_file, "w") as fh:
            fh.write(svg_text)
        subprocess.run([self.magick, "-background", "none", svg_file,
                        "-resize", f"{size}x{size}", "-filter", "Lanczos",
                        "-strip", out], check=True)

    def ico(self, pngs, out) -> None:
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
    # 传统方形图标：满幅（系统自行套蒙版）
    for dens, size in ANDROID_MIPMAPS.items():
        r.png(build_svg(size),
              p(f"android/app/src/main/res/mipmap-{dens}/ic_launcher.png"), size)

    # 自适应图标前景：透明底 + 缩到安全区的白色声波带，渐变底由 drawable 给出
    for dens, size in ANDROID_ADAPTIVE.items():
        r.png(build_svg(size, mark_w=SAFE_MARK_W),
              p(f"android/app/src/main/res/mipmap-{dens}/ic_launcher_foreground.png"),
              size)

    write(p("android/app/src/main/res/mipmap-anydpi-v26/ic_launcher.xml"),
          '''<?xml version="1.0" encoding="utf-8"?>
<!-- 自适应图标（Android 8+）：渐变底 + 前景标记 + 单色层（Android 13+ 主题图标）。
     前景已缩到中心安全区内，圆形 / 圆角蒙版不会裁掉声波两端。 -->
<adaptive-icon xmlns:android="http://schemas.android.com/apk/res/android">
    <background android:drawable="@drawable/ic_launcher_background" />
    <foreground android:drawable="@mipmap/ic_launcher_foreground" />
    <monochrome android:drawable="@drawable/ic_launcher_monochrome" />
</adaptive-icon>
''')
    write(p("android/app/src/main/res/drawable/ic_launcher_background.xml"),
          f'''<?xml version="1.0" encoding="utf-8"?>
<!-- 自适应图标底色：与位图图标同源的渐变（左上深海军蓝 → 右下青绿）。
     angle=315 表示渐变方向指向左上，与 SVG 的 0,0 → 1,0.85 走向一致。 -->
<shape xmlns:android="http://schemas.android.com/apk/res/android"
    android:shape="rectangle">
    <gradient
        android:startColor="{BG_BOTTOM}"
        android:endColor="{BG_TOP}"
        android:angle="315" />
</shape>
''')
    write(p("android/app/src/main/res/drawable/ic_launcher_monochrome.xml"),
          build_mono_vector_drawable())

    # 开屏 Logo：整枚图标（渐变底 + 圆角），明暗开屏背景上都成立
    r.png(build_svg(256, radius=SQUIRCLE_R),
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
        # 满幅 + 去 alpha（App Store 审核要求；圆角由 iOS 自行套用）
        r.png(build_svg(px), os.path.join(base, name), px, opaque=BG_BOTTOM)
    # 启动图：整枚图标居中
    launch = p("ios/Runner/Assets.xcassets/LaunchImage.imageset")
    for name, scale in (("LaunchImage.png", 1), ("LaunchImage@2x.png", 2),
                        ("LaunchImage@3x.png", 3)):
        px = round(min(168 * scale, 185 * scale) * 0.72)
        r.png(build_svg(px, radius=SQUIRCLE_R),
              os.path.join(launch, name), px)
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
          build_mono_svg(18, mark_w=0.94))
    print("  macOS 图标完成")


def gen_windows(r: Raster) -> None:
    tmp = []
    for size in (16, 24, 32, 48, 64, 128, 256):
        out = os.path.join(r.tmp, f"win_{size}.png")
        r.png(build_svg(size), out, size)
        tmp.append(out)
    r.ico(tmp, p("windows/runner/resources/app_icon.ico"))
    print("  Windows 图标完成")


def gen_tray(r: Raster) -> None:
    """托盘图标：整枚图标（渐变底）。透明底白线在浅色任务栏上不可见，
    故托盘统一用完整图标 + 圆角，深浅任务栏都清晰。"""
    tmp = []
    for size in (16, 20, 24, 32, 48, 64, 128, 256):
        out = os.path.join(r.tmp, f"tray_{size}.png")
        r.png(build_svg(size, radius=SQUIRCLE_R if size >= 24 else 0.0), out, size)
        tmp.append(out)
    r.ico(tmp, p("assets/icon/app_icon.ico"))
    print("  托盘图标完成")


def gen_web(r: Raster) -> None:
    # 应用内展示位图带圆角，视觉上与图标一致
    r.png(build_svg(512, radius=SQUIRCLE_R), p("assets/icon/app_icon.png"), 512)
    # PWA 图标不带圆角（由系统 / 浏览器蒙版处理）
    r.png(build_svg(512), p("web/icons/Icon-512.png"), 512)
    r.png(build_svg(192), p("web/icons/Icon-192.png"), 192)
    for size in (192, 512):
        r.png(build_svg(size, mark_w=SAFE_MARK_W),
              p(f"web/icons/Icon-maskable-{size}.png"), size)
    r.png(build_svg(32), p("web/favicon.png"), 32)
    print("  Web / 应用内图标完成")


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--svg-only", action="store_true", help="只写矢量源，不渲染位图")
    args = ap.parse_args()

    write(p("assets/icon/app_icon.svg"), build_svg(1024))
    write(p("assets/icon/app_icon_mono.svg"), build_mono_svg(512, mark_w=0.94))
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
