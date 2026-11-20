# /// script
# dependencies = ["pillow"]
# ///
"""Renders docs/demo.gif: a mockup of ProfileSlide with made-up profiles.

uv run scripts/make-demo-gif.py         README version
uv run scripts/make-demo-gif.py --cta   docs/demo-cta.gif: repo link and an end card, for sharing
(needs ffmpeg)
"""
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

from PIL import Image, ImageDraw, ImageFilter, ImageFont

S = 2  # supersampling
W, H = 880, 540
FPS = 20
CTA = "--cta" in sys.argv
OUT = Path(__file__).resolve().parent.parent / "docs" / ("demo-cta.gif" if CTA else "demo.gif")
REPO = "github.com/jmitchel3/profileslide"

SF = "/System/Library/Fonts/SFNS.ttf"
SFR = "/System/Library/Fonts/SFNSRounded.ttf"
EMOJI = "/System/Library/Fonts/Apple Color Emoji.ttc"


def font(size, weight=None, rounded=False):
    f = ImageFont.truetype(SFR if rounded else SF, int(size * S))
    values = []
    for axis in f.get_variation_axes():
        name = axis["name"]
        if name == b"Weight":
            values.append(weight or 400)
        elif name == b"Optical Size":
            values.append(max(axis["minimum"], min(axis["maximum"], size)))
        else:
            values.append(axis["default"])
    f.set_variation_by_axes(values)
    return f


_emoji_cache = {}


def emoji_img(ch, size, gray=False):
    key = (ch, size, gray)
    if key not in _emoji_cache:
        f = ImageFont.truetype(EMOJI, 160)
        im = Image.new("RGBA", (200, 200), (0, 0, 0, 0))
        ImageDraw.Draw(im).text((10, 10), ch, font=f, embedded_color=True)
        im = im.crop(im.getbbox())
        px = int(size * S)
        im = im.resize((px, px), Image.LANCZOS)
        if gray:
            a = im.getchannel("A")
            im = im.convert("L").convert("RGBA")
            im.putalpha(a)
        _emoji_cache[key] = im
    return _emoji_cache[key]


PROFILES = [
    dict(name="Work", emoji="💼", color=(52, 120, 246),
         tabs=["Inbox (12)", "Q4 roadmap", "Standup notes", "Design review"]),
    dict(name="Personal", emoji="🏠", color=(48, 176, 99),
         tabs=["Recipes", "Flights to Lisbon", "Photos", "Bank"]),
    dict(name="Side Project", emoji="🚀", color=(242, 140, 40),
         tabs=["Pull requests", "Landing page", "Analytics", "Docs"]),
    dict(name="Gaming", emoji="🎮", color=(150, 90, 220),
         tabs=["Patch notes", "Stream", "Build guide", "Forums"]),
]


def s(v):
    return int(round(v * S))


def mix(a, b, t):
    return tuple(int(a[i] + (b[i] - a[i]) * t) for i in range(3))


def rr(d, box, r, **kw):
    d.rounded_rectangle([s(box[0]), s(box[1]), s(box[2]), s(box[3])], radius=s(r), **kw)


def text_w(d, txt, f):
    return d.textlength(txt, font=f) / S


# Window geometry
WX, WY, WW, WH = 40, 56, 800, 440
SIDEBAR = 210
TITLE = 40


def window(p_idx, open_set):
    """The Chrome window of one profile, as an RGBA image of the window size."""
    p = PROFILES[p_idx]
    c = p["color"]
    im = Image.new("RGBA", (s(WW), s(WH)), (0, 0, 0, 0))
    d = ImageDraw.Draw(im)
    frame = mix(c, (255, 255, 255), 0.82)
    rr(d, (0, 0, WW, WH), 12, fill=frame)
    # traffic lights
    for i, col in enumerate([(255, 95, 87), (254, 188, 46), (40, 200, 64)]):
        cx, cy = 20 + i * 20, 20
        d.ellipse([s(cx - 6), s(cy - 6), s(cx + 6), s(cy + 6)], fill=col)
    # address bar
    rr(d, (SIDEBAR + 20, 9, WW - 20, 31), 11, fill=mix(c, (255, 255, 255), 0.93))
    d.text((s(SIDEBAR + 36), s(14)), p["tabs"][0].split(" (")[0].lower().replace(" ", "") + ".example.com",
           font=font(11), fill=(110, 110, 120))
    # sidebar tabs
    f = font(12.5)
    for i, t in enumerate(p["tabs"]):
        y = TITLE + 14 + i * 34
        if i == 0:
            rr(d, (10, y - 6, SIDEBAR - 10, y + 24), 8, fill=(255, 255, 255, 235))
        rr(d, (20, y + 2, 34, y + 16), 4, fill=mix(c, (255, 255, 255), 0.25 + i * 0.15))
        d.text((s(44), s(y + 1)), t, font=f, fill=(40, 40, 48))
    # new tab
    d.text((s(20), s(TITLE + 14 + 4 * 34)), "+  New Tab", font=f, fill=(120, 120, 130))
    # content
    rr(d, (SIDEBAR, TITLE, WW - 8, WH - 8), 10, fill=(255, 255, 255))
    cx0 = SIDEBAR + 34
    rr(d, (cx0, TITLE + 30, cx0 + 230, TITLE + 52), 6, fill=mix(c, (255, 255, 255), 0.15))
    for i in range(3):
        y = TITLE + 76 + i * 22
        rr(d, (cx0, y, WW - 60 - i * 70, y + 10), 5, fill=(232, 233, 238))
    for i in range(3):
        x = cx0 + i * 172
        rr(d, (x, TITLE + 160, x + 156, TITLE + 270), 10, fill=mix(c, (255, 255, 255), 0.85 - i * 0.05))
        rr(d, (x + 14, TITLE + 284, x + 140, TITLE + 294), 5, fill=(232, 233, 238))
        rr(d, (x + 14, TITLE + 302, x + 100, TITLE + 312), 5, fill=(240, 241, 245))
    # profile dots at the bottom of the sidebar
    spacing = 26
    total = len(PROFILES) * spacing
    x0 = (SIDEBAR - total) / 2 + spacing / 2
    yc = WH - 26
    for i, q in enumerate(PROFILES):
        active = i == p_idx
        is_open = i in open_set
        e = emoji_img(q["emoji"], 18 if active else 14, gray=not is_open and not active)
        if not active:
            a = e.getchannel("A").point(lambda v: int(v * (0.6 if is_open else 0.4)))
            e = e.copy()
            e.putalpha(a)
        im.alpha_composite(e, (s(x0 + i * spacing) - e.width // 2, s(yc) - e.height // 2))
    lf = font(11, 600)
    lw = text_w(d, p["name"], lf)
    d.text((s((SIDEBAR - lw) / 2), s(yc - 30)), p["name"], font=lf, fill=(100, 100, 110))
    # rounded mask
    mask = Image.new("L", im.size, 0)
    ImageDraw.Draw(mask).rounded_rectangle([0, 0, im.width - 1, im.height - 1], radius=s(12), fill=255)
    im.putalpha(Image.composite(im.getchannel("A"), mask, mask))
    return im


def background():
    bg = Image.new("RGB", (s(W), s(H)))
    d = ImageDraw.Draw(bg)
    top, bot = (34, 38, 64), (78, 60, 110)
    for y in range(s(H)):
        d.line([(0, y), (s(W), y)], fill=mix(top, bot, y / s(H)))
    return bg.convert("RGBA")


BG = background()
SHADOW = None


def shadow():
    global SHADOW
    if SHADOW is None:
        sh = Image.new("RGBA", (s(W), s(H)), (0, 0, 0, 0))
        ImageDraw.Draw(sh).rounded_rectangle([s(WX), s(WY + 8), s(WX + WW), s(WY + WH + 8)], radius=s(12),
                                             fill=(0, 0, 0, 120))
        SHADOW = sh.filter(ImageFilter.GaussianBlur(s(14)))
    return SHADOW


def caption(img, txt, alpha=1.0):
    if not txt or alpha <= 0:
        return
    layer = Image.new("RGBA", img.size, (0, 0, 0, 0))
    d = ImageDraw.Draw(layer)
    f = font(15, 600, rounded=True)
    tw = text_w(d, txt, f)
    x0 = (W - tw) / 2 - 16
    rr(d, (x0, 14, x0 + tw + 32, 42), 14, fill=(255, 255, 255, int(40 * alpha)))
    d.text((s(x0 + 16), s(19)), txt, font=f, fill=(255, 255, 255, int(255 * alpha)))
    img.alpha_composite(layer)


def keycap(img, txt, alpha=1.0, pressed=False):
    if alpha <= 0:
        return
    layer = Image.new("RGBA", img.size, (0, 0, 0, 0))
    d = ImageDraw.Draw(layer)
    f = font(26, 600, rounded=True)
    tw = text_w(d, txt, f)
    w, h = tw + 40, 54
    x0, y0 = (W - w) / 2, WY + WH - 100 + (3 if pressed else 0)
    rr(d, (x0, y0 + 4, x0 + w, y0 + h + 4), 12, fill=(0, 0, 0, int(70 * alpha)))
    rr(d, (x0, y0, x0 + w, y0 + h), 12, fill=(250, 250, 252, int(245 * alpha)),
       outline=(200, 200, 210, int(255 * alpha)), width=s(1))
    d.text((s(x0 + 20), s(y0 + 10)), txt, font=f, fill=(40, 40, 50, int(255 * alpha)))
    img.alpha_composite(layer)


def fingers(img, x, alpha):
    if alpha <= 0:
        return
    layer = Image.new("RGBA", img.size, (0, 0, 0, 0))
    d = ImageDraw.Draw(layer)
    y = WY + 250
    for dy in (-16, 16):
        cx, cy = x, y + dy
        d.ellipse([s(cx - 13), s(cy - 13), s(cx + 13), s(cy + 13)],
                  fill=(255, 255, 255, int(150 * alpha)), outline=(90, 90, 110, int(200 * alpha)), width=s(2))
    img.alpha_composite(layer)


def prompt(img, p_idx, alpha, open_pressed=False):
    if alpha <= 0:
        return
    p = PROFILES[p_idx]
    c = p["color"]
    layer = Image.new("RGBA", img.size, (0, 0, 0, 0))
    d = ImageDraw.Draw(layer)
    # dim the window
    rr(d, (WX, WY, WX + WW, WY + WH), 12, fill=(0, 0, 0, int(70 * alpha)))
    pw, ph = 300, 214
    x0, y0 = (W - pw) / 2, WY + (WH - ph) / 2 + (1 - alpha) * 10
    rr(d, (x0, y0 + 6, x0 + pw, y0 + ph + 6), 18, fill=(0, 0, 0, int(60 * alpha)))
    rr(d, (x0, y0, x0 + pw, y0 + ph), 18, fill=(248, 248, 250, int(250 * alpha)))
    cx, cy = W / 2, y0 + 50
    d.ellipse([s(cx - 32), s(cy - 32), s(cx + 32), s(cy + 32)], fill=c + (int(255 * alpha),))
    t1 = f"Open {p['name']}?"
    f1, f2 = font(17, 600, rounded=True), font(13, rounded=True)
    d.text((s(cx - text_w(d, t1, f1) / 2), s(y0 + 96)), t1, font=f1, fill=(30, 30, 36, int(255 * alpha)))
    t2 = "This space has no window yet."
    d.text((s(cx - text_w(d, t2, f2) / 2), s(y0 + 122)), t2, font=f2, fill=(120, 120, 130, int(255 * alpha)))
    fb = font(13, 600, rounded=True)
    by = y0 + 160
    rr(d, (x0 + 34, by, x0 + 142, by + 32), 16, fill=(228, 228, 234, int(255 * alpha)))
    d.text((s(x0 + 52), s(by + 8)), "Cancel  esc", font=fb, fill=(60, 60, 70, int(255 * alpha)))
    fill = mix(c, (0, 0, 0), 0.2) if open_pressed else c
    rr(d, (x0 + 152, by, x0 + 266, by + 32), 16, fill=fill + (int(255 * alpha),))
    d.text((s(x0 + 174), s(by + 8)), "Open  ⌃4", font=fb, fill=(255, 255, 255, int(255 * alpha)))
    img.alpha_composite(layer)
    e = emoji_img(p["emoji"], 32)
    if alpha < 1:
        e = e.copy()
        e.putalpha(e.getchannel("A").point(lambda v: int(v * alpha)))
    img.alpha_composite(e, (s(cx) - e.width // 2, s(cy) - e.height // 2))


def footer(img, alpha=1.0):
    layer = Image.new("RGBA", img.size, (0, 0, 0, 0))
    d = ImageDraw.Draw(layer)
    f = font(13, 600, rounded=True)
    tw = text_w(d, REPO, f)
    d.text((s((W - tw) / 2), s(H - 32)), REPO, font=f, fill=(255, 255, 255, int(200 * alpha)))
    img.alpha_composite(layer)


def end_card(alpha=1.0):
    img = BG.copy()
    layer = Image.new("RGBA", img.size, (0, 0, 0, 0))
    d = ImageDraw.Draw(layer)
    a = int(255 * alpha)
    spacing = 56
    x0 = W / 2 - spacing * (len(PROFILES) - 1) / 2
    for i, q in enumerate(PROFILES):
        cx, cy = x0 + i * spacing, 150
        d.ellipse([s(cx - 22), s(cy - 22), s(cx + 22), s(cy + 22)], fill=q["color"] + (a,))
    f1 = font(52, 700, rounded=True)
    t1 = "ProfileSlide"
    d.text((s((W - text_w(d, t1, f1)) / 2), s(200)), t1, font=f1, fill=(255, 255, 255, a))
    f2 = font(19, 500, rounded=True)
    for j, t in enumerate(["Arc is dead. Profile switching for Chrome:", "keyboard shortcuts and mouse slides."]):
        d.text((s((W - text_w(d, t, f2)) / 2), s(278 + j * 28)), t, font=f2, fill=(220, 220, 235, a))
    f3 = font(18, 600, rounded=True)
    tw = text_w(d, REPO, f3)
    bx = (W - tw) / 2 - 22
    rr(d, (bx, 372, bx + tw + 44, 414), 21, fill=(255, 255, 255, a))
    d.text((s(bx + 22), s(382)), REPO, font=f3, fill=(40, 30, 70, a))
    f4 = font(13, rounded=True)
    t4 = "Free and open source · macOS"
    d.text((s((W - text_w(d, t4, f4)) / 2), s(432)), t4, font=f4, fill=(200, 200, 215, a))
    img.alpha_composite(layer)
    for i, q in enumerate(PROFILES):
        e = emoji_img(q["emoji"], 24)
        if alpha < 1:
            e = e.copy()
            e.putalpha(e.getchannel("A").point(lambda v: int(v * alpha)))
        img.alpha_composite(e, (s(x0 + i * spacing) - e.width // 2, s(150) - e.height // 2))
    return img


def ease(t):
    t = max(0.0, min(1.0, t))
    return t * t * (3 - 2 * t)


def compose(win_a, win_b=None, slide=0.0, fade=0.0):
    img = BG.copy()
    img.alpha_composite(shadow())
    region = Image.new("RGBA", (s(WW), s(WH)), (0, 0, 0, 0))
    if win_b is None:
        region = win_a
    elif slide:
        off = int(s(WW + 30) * slide)
        region.alpha_composite(win_a, (-off, 0)) if off < s(WW) else None
        region.alpha_composite(win_b, (s(WW + 30) - off, 0)) if off > 30 else None
    else:
        region = Image.blend(win_a, win_b, fade)
    img.alpha_composite(region, (s(WX), s(WY)))
    return img


def main():
    if not shutil.which("ffmpeg"):
        sys.exit("ffmpeg not found")
    open1 = {0, 1, 2}
    open2 = {0, 1, 2, 3}
    wins = {i: window(i, open1) for i in range(3)}
    gaming = window(3, open2)
    work_after = window(0, open2)
    frames = []

    def hold(n, **kw):
        for _ in range(n):
            frames.append(render(**kw))

    def render(a, b=None, slide=0.0, fade=0.0, cap=None, cap_a=1.0, fx=None, fa=0.0,
               key=None, key_a=0.0, pressed=False, pr=None, pr_a=0.0, pr_press=False):
        img = compose(a, b, slide, fade)
        if fx is not None:
            fingers(img, fx, fa)
        if pr is not None:
            prompt(img, pr, pr_a, pr_press)
        if key:
            keycap(img, key, key_a, pressed)
        caption(img, cap, cap_a)
        if CTA:
            footer(img)
        return img

    cap1 = "Two-finger swipe on the tab sidebar"
    fx0, fx1 = WX + 170, WX + 50

    def swipe(a, b):
        for i in range(6):
            frames.append(render(a, cap=cap1, fx=fx0, fa=i / 5))
        for i in range(8):
            t = ease(i / 7)
            frames.append(render(a, cap=cap1, fx=fx0 + (fx1 - fx0) * t, fa=1))
        for i in range(9):
            t = ease(i / 8)
            frames.append(render(a, b, slide=t, cap=cap1, fx=fx1, fa=1 - t))
        hold(16, a=b, cap=cap1)

    hold(16, a=wins[0], cap=cap1)
    swipe(wins[0], wins[1])
    swipe(wins[1], wins[2])

    cap2 = "⌃1 – ⌃9 jump straight to a profile"
    for i in range(6):
        frames.append(render(wins[2], cap=cap2, cap_a=i / 5))
    for i in range(5):
        frames.append(render(wins[2], cap=cap2, key="⌃1", key_a=i / 4))
    hold(3, a=wins[2], cap=cap2, key="⌃1", key_a=1, pressed=True)
    for i in range(6):
        t = ease(i / 5)
        frames.append(render(wins[2], wins[0], fade=t, cap=cap2, key="⌃1", key_a=1 - t))
    hold(18, a=wins[0], cap=cap2)

    cap3 = "Closed profiles open with one more key"
    for i in range(6):
        frames.append(render(wins[0], cap=cap3, cap_a=i / 5))
    for i in range(5):
        frames.append(render(wins[0], cap=cap3, key="⌃4", key_a=i / 4))
    hold(3, a=wins[0], cap=cap3, key="⌃4", key_a=1, pressed=True)
    for i in range(6):
        t = ease(i / 5)
        frames.append(render(wins[0], cap=cap3, key="⌃4", key_a=1 - t, pr=3, pr_a=t))
    hold(24, a=wins[0], cap=cap3, pr=3, pr_a=1)
    hold(4, a=wins[0], cap=cap3, pr=3, pr_a=1, pr_press=True)
    for i in range(7):
        t = ease(i / 6)
        frames.append(render(wins[0], gaming, fade=t, cap=cap3, pr=3, pr_a=1 - t))
    hold(24, a=gaming, cap=cap3)
    if CTA:
        last = frames[-1]
        for i in range(8):
            frames.append(Image.blend(last, end_card(), ease(i / 7)))
        card = end_card()
        frames.extend([card] * 70)
        first = render(wins[0], cap=cap1)
        for i in range(8):
            frames.append(Image.blend(card, first, ease(i / 7)))
    for i in range(8 if not CTA else 0):
        t = ease(i / 7)
        frames.append(render(gaming, wins[0], fade=t, cap=cap3, cap_a=1 - t))

    with tempfile.TemporaryDirectory() as tmp:
        for i, f in enumerate(frames):
            f.convert("RGB").resize((W, H), Image.LANCZOS).save(f"{tmp}/f{i:04d}.png")
        OUT.parent.mkdir(exist_ok=True)
        pal = f"{tmp}/pal.png"
        subprocess.run(["ffmpeg", "-loglevel", "error", "-y", "-framerate", str(FPS), "-i", f"{tmp}/f%04d.png",
                        "-vf", "palettegen=stats_mode=diff", pal], check=True)
        subprocess.run(["ffmpeg", "-loglevel", "error", "-y", "-framerate", str(FPS), "-i", f"{tmp}/f%04d.png",
                        "-i", pal, "-lavfi", "paletteuse=dither=sierra2_4a:diff_mode=rectangle",
                        "-loop", "0", str(OUT)], check=True)
    print(f"{OUT} ({len(frames)} frames, {OUT.stat().st_size // 1024} KB)")


if __name__ == "__main__":
    main()
