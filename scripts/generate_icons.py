#!/usr/bin/env python3
"""Harken 应用图标生成器（单一矢量源 → 全平台资源）。

设计：**黑胶唱片**。
- 深色圆角底 + 暖色光晕；
- 居中一张黑胶：同心纹路、边缘金色高光、中心橙金渐变标签，标签压白色
  「Harken」字样；
- 四周点缀金色音符与星芒。

三个关键处理：

1. **按尺寸分级** —— 插画细节缩小时会糊成噪点，不是「变小」而是「变脏」。
   因此按输出尺寸决定画哪些元素：≥128px 才画「Harken」字样（再小就低于可辨认
   极限，会变成一道白杠），≥96px 保留音符，≥256px 才画星芒。
2. **图形与底分离** —— 唱片本体是独立一层。Android 自适应图标把「底」放背景层、
   把唱片缩到 80% 放前景层，圆角/圆形蒙版不会切到内容。
3. **文字用轮廓** —— 「Harken」由 DejaVu Sans Bold 转为路径常量（见 WORDMARK），
   生成时不加载字体，任何机器结果一致。换字体或改文案见 scripts/font_outline.py。

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
# 品牌色
# --------------------------------------------------------------------------

BG = "#131316"          # 底色
DISC_HI = "#3C3C42"     # 唱片高光（左上打光）
DISC_MID = "#17171B"
DISC_LOW = "#08080A"
LABEL_TOP = "#FFC85A"   # 标签渐变：上暖黄
LABEL_BOTTOM = "#E24A22"  # 下橙红
GOLD_TOP = "#FFDD8A"    # 音符 / 星芒
GOLD_BOTTOM = "#DFA028"
GLOW = "#FFB454"        # 背后暖光
MARK = "#FFFFFF"

SQUIRCLE_R = 0.225      # 圆角（应用内展示 / 托盘 / 开屏）
SAFE_MARK_SCALE = 0.80  # 自适应 / maskable 图标里唱片的缩放（留安全区）

# --------------------------------------------------------------------------
# 「Harken」字形轮廓
#   DejaVu Sans Bold，-0.02em 字距，坐标以 em 为单位（y 向上翻转，基线 y=0）
#   生成方式见 scripts/font_outline.py（Bitstream Vera 许可，可自由使用）
# --------------------------------------------------------------------------

WORDMARK = (
    "M 0.0918 -0.7290 L 0.2798 -0.7290 L 0.2798 -0.4512 L 0.5571 -0.4512 L 0.5571"
    " -0.7290 L 0.7451 -0.7290 L 0.7451 0.0000 L 0.5571 0.0000 L 0.5571 -0.3091 L"
    " 0.2798 -0.3091 L 0.2798 0.0000 L 0.0918 0.0000 Z M 1.1460 -0.2461 Q 1.0913 "
    "-0.2461 1.0637 -0.2275 Q 1.0362 -0.2090 1.0362 -0.1729 Q 1.0362 -0.1396 1.05"
    "84 -0.1208 Q 1.0806 -0.1021 1.1201 -0.1021 Q 1.1695 -0.1021 1.2031 -0.1375 Q"
    " 1.2368 -0.1729 1.2368 -0.2261 L 1.2368 -0.2461 Z M 1.4131 -0.3120 L 1.4131 "
    "0.0000 L 1.2368 0.0000 L 1.2368 -0.0811 Q 1.2017 -0.0312 1.1577 -0.0085 Q 1."
    "1138 0.0142 1.0508 0.0142 Q 0.9658 0.0142 0.9129 -0.0354 Q 0.8599 -0.0850 0."
    "8599 -0.1641 Q 0.8599 -0.2603 0.9260 -0.3052 Q 0.9922 -0.3501 1.1338 -0.3501"
    " L 1.2368 -0.3501 L 1.2368 -0.3638 Q 1.2368 -0.4053 1.2041 -0.4246 Q 1.1714 "
    "-0.4438 1.1021 -0.4438 Q 1.0459 -0.4438 0.9976 -0.4326 Q 0.9492 -0.4214 0.90"
    "77 -0.3989 L 0.9077 -0.5322 Q 0.9639 -0.5459 1.0205 -0.5530 Q 1.0772 -0.5601"
    " 1.1338 -0.5601 Q 1.2818 -0.5601 1.3474 -0.5017 Q 1.4131 -0.4434 1.4131 -0.3"
    "777 Z M 1.9620 -0.3979 Q 1.9390 -0.4087 1.9163 -0.4138 Q 1.8936 -0.4189 1.87"
    "06 -0.4189 Q 1.8033 -0.4189 1.7669 -0.3757 Q 1.7305 -0.3325 1.7305 -0.2520 L"
    " 1.7305 0.0000 L 1.5557 0.0000 L 1.5557 -0.5469 L 1.7305 -0.5469 L 1.7305 -0"
    ".4570 Q 1.7642 -0.5107 1.8079 -0.5354 Q 1.8516 -0.5601 1.9126 -0.5601 Q 1.92"
    "14 -0.5601 1.9317 -0.5593 Q 1.9419 -0.5586 1.9615 -0.5562 Z M 2.0289 -0.7598"
    " L 2.2037 -0.7598 L 2.2037 -0.3462 L 2.4048 -0.5469 L 2.6080 -0.5469 L 2.340"
    "9 -0.2959 L 2.6290 0.0000 L 2.4171 0.0000 L 2.2037 -0.2280 L 2.2037 0.0000 L"
    " 2.0289 0.0000 Z M 3.2198 -0.2749 L 3.2198 -0.2251 L 2.8111 -0.2251 Q 2.8175"
    " -0.1636 2.8555 -0.1328 Q 2.8936 -0.1021 2.9620 -0.1021 Q 3.0172 -0.1021 3.0"
    "750 -0.1184 Q 3.1329 -0.1348 3.1939 -0.1680 L 3.1939 -0.0332 Q 3.1319 -0.009"
    "8 3.0699 0.0022 Q 3.0079 0.0142 2.9459 0.0142 Q 2.7974 0.0142 2.7152 -0.0613"
    " Q 2.6329 -0.1367 2.6329 -0.2729 Q 2.6329 -0.4067 2.7137 -0.4834 Q 2.7945 -0"
    ".5601 2.9361 -0.5601 Q 3.0650 -0.5601 3.1424 -0.4824 Q 3.2198 -0.4048 3.2198"
    " -0.3398 Z M 3.0401 -0.3330 Q 3.0401 -0.3828 3.0111 -0.4133 Q 2.9820 -0.4438"
    " 2.9351 -0.4438 Q 2.8844 -0.4438 2.8526 -0.4153 Q 2.8209 -0.3867 2.8131 -0.3"
    "330 Z M 3.8819 -0.3330 L 3.8819 0.0000 L 3.7062 0.0000 L 3.7062 -0.0542 L 3."
    "7062 -0.2549 Q 3.7062 -0.3257 3.7030 -0.3525 Q 3.6998 -0.3794 3.6920 -0.3921"
    " Q 3.6817 -0.4092 3.6642 -0.4187 Q 3.6466 -0.4282 3.6241 -0.4282 Q 3.5694 -0"
    ".4282 3.5382 -0.3860 Q 3.5069 -0.3438 3.5069 -0.2690 L 3.5069 0.0000 L 3.332"
    "1 0.0000 L 3.3321 -0.5469 L 3.5069 -0.5469 L 3.5069 -0.4668 Q 3.5465 -0.5146"
    " 3.5909 -0.5374 Q 3.6354 -0.5601 3.6891 -0.5601 Q 3.7838 -0.5601 3.8329 -0.5"
    "020 Q 3.8819 -0.4438 3.8819 -0.3884 Z"
)
WORDMARK_ADVANCE = 3.9601   # 含字距的推进宽度（em）
WORDMARK_CAP = 0.7290       # 大写高度（em）
WORDMARK_SQUEEZE = 0.66     # 横向压缩：参考图里是偏窄的重字重

# --------------------------------------------------------------------------
# 几何
# --------------------------------------------------------------------------

DISC_R = 0.380          # 唱片半径（画布比例）
LABEL_R = 0.148         # 中心标签半径
LABEL_TEXT_W = 0.72     # 字样宽度 / 标签直径

# 按尺寸分级：尺寸越小，越要丢掉细节，只留下「一张黑胶」这个信息
TIERS = (
    (256, dict(grooves=16, notes=3, stars=6, text=True, sheen=True)),
    (128, dict(grooves=12, notes=3, stars=3, text=True, sheen=True)),
    (96,  dict(grooves=9,  notes=2, stars=0, text=False, sheen=True)),
    (64,  dict(grooves=6,  notes=0, stars=0, text=False, sheen=True)),
    (32,  dict(grooves=5,  notes=0, stars=0, text=False, sheen=False, boost=True)),
    (0,   dict(grooves=3,  notes=0, stars=0, text=False, sheen=False, boost=True)),
)


def tier_for(size: int, over: dict | None = None) -> dict:
    out = dict(next(t for lo, t in TIERS if size >= lo))
    if over:
        out.update(over)
    return out


def f(v: float) -> str:
    s = f"{v:.4f}".rstrip("0").rstrip(".")
    return s if s not in ("", "-") else "0"


# ---------------------------------------------------------------- 装饰件

def sparkle(cx, cy, r, op=0.9):
    """四角星芒（参考图里的高光点）。"""
    k = r * 0.16
    d = (f"M {f(cx)} {f(cy - r)} L {f(cx + k)} {f(cy - k)} L {f(cx + r)} {f(cy)} "
         f"L {f(cx + k)} {f(cy + k)} L {f(cx)} {f(cy + r)} L {f(cx - k)} {f(cy + k)} "
         f"L {f(cx - r)} {f(cy)} L {f(cx - k)} {f(cy - k)} Z")
    return (f'<path d="{d}" fill="#FFEFC8" fill-opacity="{op}"/>'
            f'<path d="{d}" fill="none" stroke="#FFC85A" '
            f'stroke-opacity="{op * 0.5:.2f}" stroke-width="{f(r * 0.30)}"/>')


def note(cx, cy, s, rot=0):
    """八分音符：斜椭圆符头 + 符干 + 符尾。s = 符干高度。"""
    hrx, hry = s * 0.270, s * 0.200
    sw, sh = s * 0.058, s * 1.00
    sx = hrx * 0.80
    fx, fy = sx + sw / 2, -sh
    return (f'<g transform="translate({f(cx)} {f(cy)}) rotate({rot})">'
            f'<ellipse cx="0" cy="0" rx="{f(hrx)}" ry="{f(hry)}" fill="url(#gold)" '
            f'transform="rotate(-20)"/>'
            f'<rect x="{f(sx - sw / 2)}" y="{f(-sh)}" width="{f(sw)}" '
            f'height="{f(sh + hry * 0.5)}" rx="{f(sw * 0.4)}" fill="url(#gold)"/>'
            f'<path d="M {f(fx)} {f(fy)} '
            f'C {f(fx + s * 0.46)} {f(fy + s * 0.18)} {f(fx + s * 0.48)} {f(fy + s * 0.44)} '
            f'{f(fx + s * 0.20)} {f(fy + s * 0.60)} '
            f'C {f(fx + s * 0.30)} {f(fy + s * 0.40)} {f(fx + s * 0.22)} {f(fy + s * 0.20)} '
            f'{f(fx - sw)} {f(fy + s * 0.13)} Z" fill="url(#gold)"/>'
            f'</g>')


def beamed_pair(cx, cy, s, rot=0):
    """符杠连接的两个八分音符。s = 符干高度。"""
    hrx, hry = s * 0.265, s * 0.195
    sw, sh = s * 0.056, s * 1.00
    gap, beam, tilt = s * 0.86, s * 0.125, s * 0.075
    body = []
    for i in (0, 1):
        hx = i * gap
        body.append(f'<ellipse cx="{f(hx)}" cy="0" rx="{f(hrx)}" ry="{f(hry)}" '
                    f'fill="url(#gold)" transform="rotate(-20 {f(hx)} 0)"/>')
        body.append(f'<rect x="{f(hx + hrx * 0.80 - sw / 2)}" y="{f(-sh)}" '
                    f'width="{f(sw)}" height="{f(sh + hry * 0.5)}" rx="{f(sw * 0.4)}" '
                    f'fill="url(#gold)"/>')
    x0 = hrx * 0.80 - sw / 2
    x1 = gap + hrx * 0.80 + sw / 2
    body.append(f'<path d="M {f(x0)} {f(-sh)} L {f(x1)} {f(-sh - tilt)} '
                f'L {f(x1)} {f(-sh - tilt + beam)} L {f(x0)} {f(-sh + beam)} Z" '
                f'fill="url(#gold)"/>')
    return (f'<g transform="translate({f(cx)} {f(cy)}) rotate({rot})">'
            + "".join(body) + '</g>')


def decorations(size, n_notes, n_stars):
    """音符 + 星芒。位置是照着参考图挑的固定坐标，不用随机数。"""
    S = size
    out = []
    if n_notes:
        parts = [note(0.205 * S, 0.245 * S, 0.125 * S, rot=-8)]
        if n_notes >= 2:
            parts.append(beamed_pair(0.665 * S, 0.245 * S, 0.125 * S, rot=-6))
        if n_notes >= 3:
            parts.append(note(0.735 * S, 0.760 * S, 0.082 * S, rot=6))
        # 暗描边把金色从浅色边缘上拉开（参考图里音符是有描边的）
        out.append(f'<g stroke="#7C520B" stroke-width="{f(0.006 * S)}" '
                   f'stroke-linejoin="round">' + "".join(parts) + '</g>')
    if n_stars:
        pts = [(0.170, 0.190, 0.034, 1.0), (0.850, 0.330, 0.024, 0.9),
               (0.790, 0.760, 0.021, 0.85), (0.115, 0.585, 0.016, 0.7),
               (0.630, 0.135, 0.014, 0.65), (0.300, 0.845, 0.012, 0.6)]
        dots = [(0.245, 0.315, 0.009, 0.55), (0.885, 0.545, 0.007, 0.45),
                (0.505, 0.075, 0.006, 0.40), (0.075, 0.415, 0.008, 0.50),
                (0.695, 0.905, 0.007, 0.42), (0.415, 0.925, 0.006, 0.38),
                (0.925, 0.155, 0.008, 0.50), (0.055, 0.735, 0.006, 0.35)]
        out.append("".join(sparkle(*p) for p in pts[:n_stars]))
        out.append("".join(
            f'<circle cx="{f(x)}" cy="{f(y)}" r="{f(r)}" fill="{GOLD_TOP}" '
            f'fill-opacity="{op}"/>' for x, y, r, op in dots[:n_stars + 2]))
    return "".join(out)


# ---------------------------------------------------------------- 唱片本体

def vinyl(size, *, notes=None, stars=None, text=None, grooves=None, sheen=None,
          disc_r=DISC_R, label_r=LABEL_R, contrast=None) -> str:
    """唱片本体（纹路 + 标签 + 字样 + 装饰），不含底色。

    notes / stars / text 传 None 表示「按尺寸分级自动决定」；传 False 则强制关闭。
    """
    S = size
    t = tier_for(S)
    if grooves is None:
        grooves = t["grooves"]
    if sheen is None:
        sheen = t["sheen"]
    if text is None:
        text = t["text"]
    if notes is True or notes is None:
        notes = t["notes"]
    if stars is True or stars is None:
        stars = t["stars"]
    if contrast is None:
        contrast = t.get("boost", False)
    c = 0.5 * S
    o = [f'<circle cx="{f(c)}" cy="{f(c)}" r="{f(disc_r * S)}" fill="url(#disc)"/>']
    # 同心纹路：用不透明度细微起伏模拟唱片的沟槽反光
    for i in range(grooves):
        t_ = i / (grooves - 1) if grooves > 1 else 0
        r = label_r * S * 1.16 + (disc_r * S * 0.985 - label_r * S * 1.16) * t_
        op = 0.030 + 0.055 * (0.5 + 0.5 * math.sin(i * 2.1))
        o.append(f'<circle cx="{f(c)}" cy="{f(c)}" r="{f(r)}" fill="none" '
                 f'stroke="#FFFFFF" stroke-opacity="{op:.3f}" '
                 f'stroke-width="{f(0.0016 * S)}"/>')
    if sheen:
        o.append(f'<g clip-path="url(#discClip)">'
                 f'<ellipse cx="{f(0.34 * S)}" cy="{f(0.26 * S)}" rx="{f(0.30 * S)}" '
                 f'ry="{f(0.20 * S)}" fill="url(#sheen)" '
                 f'transform="rotate(-28 {f(0.34 * S)} {f(0.26 * S)})"/></g>')
    # 边缘：上缘金边高光 + 内侧一圈冷白
    o.append(f'<circle cx="{f(c)}" cy="{f(c)}" r="{f(disc_r * S)}" fill="none" '
             f'stroke="url(#rim)" stroke-width="{f((0.009 if contrast else 0.006) * S)}"/>')
    o.append(f'<circle cx="{f(c)}" cy="{f(c)}" r="{f(disc_r * S - 0.004 * S)}" fill="none" '
             f'stroke="#FFFFFF" stroke-opacity="0.10" stroke-width="{f(0.0015 * S)}"/>')
    # 中心标签
    o.append(f'<circle cx="{f(c)}" cy="{f(c)}" r="{f(label_r * S)}" fill="url(#label)"/>')
    o.append(f'<circle cx="{f(c)}" cy="{f(c)}" r="{f(label_r * S * 0.94)}" fill="none" '
             f'stroke="#FFFFFF" stroke-opacity="0.30" stroke-width="{f(0.0035 * S)}"/>')
    if text:
        tw = 2 * label_r * S * LABEL_TEXT_W
        sx = WORDMARK_SQUEEZE
        em = tw / (WORDMARK_ADVANCE * sx)      # 压缩后仍要达到 tw
        ty = c + WORDMARK_CAP * em / 2         # 基线：让大写字母视觉居中
        o.append(f'<g transform="translate({f(c)} {f(ty)}) '
                 f'scale({f(sx * em)} {f(em)}) translate({f(-WORDMARK_ADVANCE / 2)} 0)">'
                 f'<path d="{WORDMARK}" fill="{MARK}" fill-rule="nonzero"/></g>')
    o.append(decorations(S, int(notes or 0), int(stars or 0)))
    return "".join(o)


def defs(size, *, contrast=False) -> str:
    """contrast=True：小尺寸下把「黑胶 vs 底色」的对比拉开。

    32px 以下光是缩小，唱片的黑和背景的黑会糊成一块，只剩一个橙点；
    所以小尺寸改用更亮的盘面 + 更亮的金边，让轮廓线读得出来。
    """
    S = size
    hi = "#454550" if contrast else DISC_HI
    mid = "#202027" if contrast else DISC_MID
    low = "#121216" if contrast else DISC_LOW
    glow_a = "0.18" if contrast else "0.26"
    return f'''<defs>
<radialGradient id="glow" cx="0.5" cy="0.5" r="0.62">
  <stop offset="0" stop-color="{GLOW}" stop-opacity="{glow_a}"/>
  <stop offset="0.52" stop-color="#FF9A3C" stop-opacity="0.09"/>
  <stop offset="1" stop-color="#FF9A3C" stop-opacity="0"/>
</radialGradient>
<radialGradient id="disc" cx="0.36" cy="0.28" r="0.92">
  <stop offset="0" stop-color="{hi}"/>
  <stop offset="0.42" stop-color="{mid}"/>
  <stop offset="1" stop-color="{low}"/>
</radialGradient>
<linearGradient id="label" x1="0" y1="0" x2="0" y2="1">
  <stop offset="0" stop-color="{LABEL_TOP}"/><stop offset="1" stop-color="{LABEL_BOTTOM}"/>
</linearGradient>
<linearGradient id="gold" x1="0" y1="0" x2="0" y2="1">
  <stop offset="0" stop-color="{GOLD_TOP}"/><stop offset="1" stop-color="{GOLD_BOTTOM}"/>
</linearGradient>
<linearGradient id="rim" x1="0.2" y1="1" x2="0.35" y2="0">
  <stop offset="0" stop-color="#C08A2E" stop-opacity="0"/>
  <stop offset="0.42" stop-color="#D9A03C" stop-opacity="0"/>
  <stop offset="0.72" stop-color="#FFD98A" stop-opacity="0.60"/>
  <stop offset="1" stop-color="#FFEBB6" stop-opacity="0.95"/>
</linearGradient>
<radialGradient id="sheen" cx="0.5" cy="0.5" r="0.5">
  <stop offset="0" stop-color="#FFFFFF" stop-opacity="0.13"/>
  <stop offset="1" stop-color="#FFFFFF" stop-opacity="0"/>
</radialGradient>
<clipPath id="discClip"><circle cx="{f(0.5 * S)}" cy="{f(0.5 * S)}" r="{f(DISC_R * S)}"/></clipPath>
</defs>'''


# ---------------------------------------------------------------- 输出组装

def _svg(size, body, defs_text) -> str:
    return (f'<svg xmlns="http://www.w3.org/2000/svg" width="{size}" height="{size}" '
            f'viewBox="0 0 {size} {size}">\n{defs_text}\n{body}\n</svg>\n')


def build_svg(size: int, *, radius=SQUIRCLE_R, mark_scale=1.0,
              notes=None, stars=None, text=None, contrast=None) -> str:
    """完整图标：底色 + 暖光 + 唱片（可选缩放，用于安全区）。"""
    S = size
    rx = f' rx="{f(radius * S)}"' if radius else ""
    body = (f'<rect width="{S}" height="{S}"{rx} fill="{BG}"/>'
            f'<rect width="{S}" height="{S}"{rx} fill="url(#glow)"/>')
    inner = vinyl(S, notes=notes, stars=stars, text=text, contrast=contrast)
    if mark_scale != 1.0:
        inner = (f'<g transform="translate({f(S / 2)} {f(S / 2)}) '
                 f'scale({f(mark_scale)}) translate({f(-S / 2)} {f(-S / 2)})">'
                 f'{inner}</g>')
    return _svg(S, body + inner, defs(S, contrast=bool(contrast if contrast is not None
                                                       else tier_for(S).get("boost"))))


def build_bg_svg(size: int) -> str:
    """自适应图标的背景层：底色 + 暖光（系统负责蒙版，故不带圆角）。"""
    S = size
    return _svg(S, f'<rect width="{S}" height="{S}" fill="{BG}"/>'
                    f'<rect width="{S}" height="{S}" fill="url(#glow)"/>', defs(S))


def build_fg_svg(size: int, *, mark_scale=SAFE_MARK_SCALE) -> str:
    """自适应图标的前景层：透明底 + 缩到安全区的唱片（不含音符/星芒，避免被裁）。"""
    S = size
    inner = vinyl(S, notes=False, stars=False)
    inner = (f'<g transform="translate({f(S / 2)} {f(S / 2)}) scale({f(mark_scale)}) '
             f'translate({f(-S / 2)} {f(-S / 2)})">{inner}</g>')
    return _svg(S, inner, defs(S))


def mono_path(size: int, *, disc_r=0.420, ring_r=0.240, dot_r=0.190) -> str:
    """单色剪影路径：实心盘 - 细环 + 实心标签（evenOdd 一次成型）。

    三个同心圆用 evenOdd 叠加即可得到「黑胶」：盘面实心、标签外一圈镂空、
    标签与中心孔实心。环宽 = ring_r - dot_r，太小在 16px 会消失，
    太大就变成靶心，0.05 画布宽是两者的折中。
    """
    S = size
    c = 0.5 * S

    def circle(r):
        return (f"M {f(c + r)} {f(c)} A {f(r)} {f(r)} 0 1 0 {f(c - r)} {f(c)} "
                f"A {f(r)} {f(r)} 0 1 0 {f(c + r)} {f(c)} Z")

    return (circle(disc_r * S) + " " + circle(ring_r * S) + " "
            + circle(max(dot_r, 0.02) * S))


def build_mono_svg(size: int) -> str:
    """单色剪影（模板图标：macOS 菜单栏按 alpha 反色，颜色本身不参与）。"""
    return _svg(size, f'<path d="{mono_path(size)}" fill="#000000" '
                      f'fill-rule="evenodd"/>', "")


def build_mono_vector_drawable(size: int = 108) -> str:
    """Android 13+ 主题图标层。"""
    return f'''<?xml version="1.0" encoding="utf-8"?>
<vector xmlns:android="http://schemas.android.com/apk/res/android"
    android:width="{size}dp"
    android:height="{size}dp"
    android:viewportWidth="{size}"
    android:viewportHeight="{size}">
    <path
        android:fillColor="#000000"
        android:fillType="evenOdd"
        android:pathData="{mono_path(size)}" />
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
                         "/tmp/gen/node_modules",
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
        r.png(build_svg(size, radius=0.0),
              p(f"android/app/src/main/res/mipmap-{dens}/ic_launcher.png"), size)

    # 自适应图标：底色 + 暖光作背景层，唱片缩到安全区作前景层
    for dens, size in ANDROID_ADAPTIVE.items():
        r.png(build_bg_svg(size),
              p(f"android/app/src/main/res/mipmap-{dens}/ic_launcher_background.png"), size)
        r.png(build_fg_svg(size),
              p(f"android/app/src/main/res/mipmap-{dens}/ic_launcher_foreground.png"), size)

    write(p("android/app/src/main/res/mipmap-anydpi-v26/ic_launcher.xml"),
          '''<?xml version="1.0" encoding="utf-8"?>
<!-- 自适应图标（Android 8+）：背景层是深色底 + 暖光，前景层是缩到中心安全区
     的唱片，另有单色层供 Android 13+ 主题图标。前景只放唱片本体，不含音符与
     星芒 —— 它们超出安全区，会被圆形蒙版切掉。 -->
<adaptive-icon xmlns:android="http://schemas.android.com/apk/res/android">
    <background android:drawable="@mipmap/ic_launcher_background" />
    <foreground android:drawable="@mipmap/ic_launcher_foreground" />
    <monochrome android:drawable="@drawable/ic_launcher_monochrome" />
</adaptive-icon>
''')
    write(p("android/app/src/main/res/drawable/ic_launcher_monochrome.xml"),
          build_mono_vector_drawable())

    # 开屏 Logo：整枚图标（圆角），明暗开屏背景上都成立
    r.png(build_svg(256),
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
        r.png(build_svg(px, radius=0.0), os.path.join(base, name), px, opaque=BG)
    launch = p("ios/Runner/Assets.xcassets/LaunchImage.imageset")
    for name, scale in (("LaunchImage.png", 1), ("LaunchImage@2x.png", 2),
                        ("LaunchImage@3x.png", 3)):
        px = round(min(168 * scale, 185 * scale) * 0.72)
        r.png(build_svg(px), os.path.join(launch, name), px)
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
          build_mono_svg(18))
    print("  macOS 图标完成")


def gen_windows(r: Raster) -> None:
    tmp = []
    for size in (16, 24, 32, 48, 64, 128, 256):
        out = os.path.join(r.tmp, f"win_{size}.png")
        r.png(build_svg(size, radius=0.0), out, size)
        tmp.append(out)
    r.ico(tmp, p("windows/runner/resources/app_icon.ico"))
    print("  Windows 图标完成")


def gen_tray(r: Raster) -> None:
    """托盘图标：整枚图标（圆角）。透明底的白字在浅色任务栏上不可见，
    故托盘统一用完整图标，深浅任务栏都清晰。"""
    tmp = []
    for size in (16, 20, 24, 32, 48, 64, 128, 256):
        out = os.path.join(r.tmp, f"tray_{size}.png")
        r.png(build_svg(size), out, size)
        tmp.append(out)
    r.ico(tmp, p("assets/icon/app_icon.ico"))
    print("  托盘图标完成")


def gen_web(r: Raster) -> None:
    # 应用内展示位图带圆角，视觉上与图标一致
    r.png(build_svg(512), p("assets/icon/app_icon.png"), 512)
    # PWA 图标不带圆角（由系统 / 浏览器蒙版处理）；maskable 版留安全区
    r.png(build_svg(512, radius=0.0), p("web/icons/Icon-512.png"), 512)
    r.png(build_svg(192, radius=0.0), p("web/icons/Icon-192.png"), 192)
    for size in (192, 512):
        r.png(build_svg(size, radius=0.0, mark_scale=SAFE_MARK_SCALE,
                        notes=False, stars=False),
              p(f"web/icons/Icon-maskable-{size}.png"), size)
    r.png(build_svg(32, radius=0.0), p("web/favicon.png"), 32)
    print("  Web / 应用内图标完成")


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--svg-only", action="store_true", help="只写矢量源，不渲染位图")
    args = ap.parse_args()

    write(p("assets/icon/app_icon.svg"), build_svg(1024))
    write(p("assets/icon/app_icon_mono.svg"), build_mono_svg(512))
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
