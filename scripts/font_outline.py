#!/usr/bin/env python3
"""把一段文字的字体轮廓导出成 SVG path —— 用来更新 generate_icons.py 里的 WORDMARK。

图标里的「Harken」字样是轮廓常量，不是 <text>：

* 生成图标时不需要加载字体，任何机器渲染结果完全一致；
* 字体缺失 / 渲染器不同（浏览器、Inkscape、resvg）不会导致字样变形。

换字体、换文案或想调字距时，跑这个脚本，把输出替换进 WORDMARK 即可：

    python3 scripts/font_outline.py "Harken" --font /usr/share/fonts/truetype/dejavu/DejaVuSans-Bold.ttf
    # → 打印 path 与推进宽度（em 单位，基线 y=0，y 轴向下）

现用字形来自 DejaVu Sans Bold（Bitstream Vera 许可，可自由使用与再分发）。
只支持简单字形（不含复合字形），拉丁字母足够。
"""

from __future__ import annotations

import argparse
import struct


def _tables(data: bytes) -> dict:
    n = struct.unpack(">H", data[4:6])[0]
    out = {}
    for i in range(n):
        off = 12 + 16 * i
        out[data[off:off + 4].decode("latin1")] = struct.unpack(">II", data[off + 8:off + 16])
    return out


def _cmap(data: bytes, t: dict) -> dict:
    o = t["cmap"][0]
    n = struct.unpack(">H", data[o + 2:o + 4])[0]
    best = None
    for i in range(n):
        pid, eid, off = struct.unpack(">HHI", data[o + 4 + 8 * i:o + 12 + 8 * i])
        if struct.unpack(">H", data[o + off:o + off + 2])[0] == 4 and \
                (pid, eid) in ((3, 1), (0, 3), (0, 4), (3, 10), (0, 0)):
            best = o + off
    if best is None:
        raise SystemExit("字体里没有可用的 format-4 cmap")
    seg = struct.unpack(">H", data[best + 6:best + 8])[0] // 2
    ends = struct.unpack(">%dH" % seg, data[best + 14:best + 14 + 2 * seg])
    starts = struct.unpack(">%dH" % seg, data[best + 16 + 2 * seg:best + 16 + 4 * seg])
    deltas = struct.unpack(">%dh" % seg, data[best + 16 + 4 * seg:best + 16 + 6 * seg])
    ro_base = best + 16 + 6 * seg
    ranges = struct.unpack(">%dH" % seg, data[ro_base:ro_base + 2 * seg])
    m = {}
    for i in range(seg):
        for c in range(starts[i], min(ends[i], 0xFFFE) + 1):
            if ranges[i] == 0:
                g = (c + deltas[i]) & 0xFFFF
            else:
                a = ro_base + 2 * i + ranges[i] + 2 * (c - starts[i])
                g = struct.unpack(">H", data[a:a + 2])[0]
                if g:
                    g = (g + deltas[i]) & 0xFFFF
            m[c] = g
    return m


def _glyph(data: bytes, t: dict, gid: int, locfmt: int):
    lo = t["loca"][0]
    if locfmt:
        s, e = struct.unpack(">II", data[lo + 4 * gid:lo + 4 * gid + 8])
    else:
        s, e = struct.unpack(">HH", data[lo + 2 * gid:lo + 2 * gid + 4])
        s, e = s * 2, e * 2
    if s == e:
        return []
    g = t["glyf"][0] + s
    nc = struct.unpack(">h", data[g:g + 2])[0]
    if nc < 0:
        raise SystemExit("遇到复合字形，脚本不支持——换用不含复合字形的文字")
    ends = struct.unpack(">%dH" % nc, data[g + 10:g + 10 + 2 * nc])
    p = g + 10 + 2 * nc
    ilen = struct.unpack(">H", data[p:p + 2])[0]
    p += 2 + ilen
    npts = ends[-1] + 1
    flags = []
    while len(flags) < npts:
        f = data[p]
        p += 1
        flags.append(f)
        if f & 8:
            r = data[p]
            p += 1
            flags.extend([f] * r)
    flags = flags[:npts]
    xs, v = [], 0
    for f in flags:
        if f & 2:
            dx = data[p]
            p += 1
            v += dx if f & 16 else -dx
        elif not f & 16:
            v += struct.unpack(">h", data[p:p + 2])[0]
            p += 2
        xs.append(v)
    ys, v = [], 0
    for f in flags:
        if f & 4:
            dy = data[p]
            p += 1
            v += dy if f & 32 else -dy
        elif not f & 32:
            v += struct.unpack(">h", data[p:p + 2])[0]
            p += 2
        ys.append(v)
    pts = list(zip(xs, ys, flags))
    out, st = [], 0
    for en in ends:
        out.append(pts[st:en + 1])
        st = en + 1
    return out


class Font:
    def __init__(self, path: str) -> None:
        self.data = open(path, "rb").read()
        self.t = _tables(self.data)
        head = self.t["head"][0]
        self.upem = struct.unpack(">H", self.data[head + 18:head + 20])[0]
        self.locfmt = struct.unpack(">h", self.data[head + 50:head + 52])[0]
        self.cmap = _cmap(self.data, self.t)
        hh = self.t["hhea"][0]
        self.n_adv = struct.unpack(">H", self.data[hh + 34:hh + 36])[0]
        self.hmtx = self.t["hmtx"][0]

    def advance(self, ch: str) -> float:
        gid = self.cmap[ord(ch)]
        if gid < self.n_adv:
            a = struct.unpack(">H", self.data[self.hmtx + 4 * gid:self.hmtx + 4 * gid + 2])[0]
        else:
            o = self.hmtx + 4 * (self.n_adv - 1)
            a = struct.unpack(">H", self.data[o:o + 2])[0]
        return a / self.upem

    def contours(self, ch: str):
        return _glyph(self.data, self.t, self.cmap[ord(ch)], self.locfmt)


def _to_path(contours, upem: float, ox: float, scale: float) -> str:
    """TrueType 二次曲线轮廓 → SVG path（y 轴翻转，em 单位）。"""
    def pt(x, y):
        return (ox + x / upem) * scale, (-y / upem) * scale

    segs = []
    for c in contours:
        start = next((i for i, q in enumerate(c) if q[2] & 1), None)
        if start is None:
            x0 = (c[0][0] + c[-1][0]) / 2
            y0 = (c[0][1] + c[-1][1]) / 2
            pts = [(x0, y0, 1)] + list(c)
        else:
            pts = list(c[start:]) + list(c[:start])
        d = ["M {:.4f} {:.4f}".format(*pt(pts[0][0], pts[0][1]))]
        i = 1
        while i < len(pts):
            x, y, fl = pts[i]
            if fl & 1:
                d.append("L {:.4f} {:.4f}".format(*pt(x, y)))
                i += 1
            else:
                if i + 1 < len(pts) and pts[i + 1][2] & 1:
                    ex, ey = pts[i + 1][0], pts[i + 1][1]
                    i += 2
                else:
                    nx = pts[(i + 1) % len(pts)]
                    ex, ey = (x + nx[0]) / 2, (y + nx[1]) / 2
                    i += 1
                d.append("Q {:.4f} {:.4f} {:.4f} {:.4f}".format(*pt(x, y), *pt(ex, ey)))
        d.append("Z")
        segs.append(" ".join(d))
    return " ".join(segs)


def outline(text: str, font: str, tracking: float = 0.0):
    """返回 (path, 推进宽度) —— 宽度以 em 计，基线 y=0，y 轴向下。"""
    f = Font(font)
    parts, x = [], 0.0
    for ch in text:
        parts.append(_to_path(f.contours(ch), f.upem, x, 1.0))
        x += f.advance(ch) + tracking
    return " ".join(parts), x - (tracking if text else 0.0)


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("text")
    ap.add_argument("--font", default="/usr/share/fonts/truetype/dejavu/DejaVuSans-Bold.ttf")
    ap.add_argument("--tracking", type=float, default=-0.02, help="字距（em），默认 -0.02")
    a = ap.parse_args()
    d, w = outline(a.text, a.font, a.tracking)
    print(f"# 推进宽度 WORDMARK_ADVANCE = {w:.4f}   （{len(d)} 字符）")
    print(d)


if __name__ == "__main__":
    main()
