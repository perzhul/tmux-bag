#!/usr/bin/env python3
"""Records demo/demo.gif.

Drives a private tmux server through a nested client, injecting mouse events
the way a terminal sends them, and renders every screen with a drawn pointer.

Needs tmux >= 3.4 and `pip install pyte pillow`.
Usage: demo/make-demo.py [--font-dir DIR] [--out PATH]
"""
import argparse
import os
import pathlib
import subprocess
import tempfile
import time

import pyte
from PIL import Image, ImageDraw, ImageFont

COLS, ROWS = 100, 22
REPO = pathlib.Path(__file__).resolve().parent.parent
INNER, OUTER = "tmux-bag-demo-inner", "tmux-bag-demo-outer"

CONF = """
set -s escape-time 0
set -g base-index 1
set -g renumber-windows on
set -g mouse on
set -g automatic-rename off
set -g allow-rename off
set -g display-time 2500
set -g status-justify centre
set -g status-style "bg=colour235 fg=colour245"
set -g status-left "#[fg=colour39,bold] #S "
set -g status-right "#[fg=colour245]%H:%M"
setw -g window-status-format " #I #W "
setw -g window-status-current-format "#[fg=colour255,bg=colour238,bold] #I #W "
set -g message-style "bg=colour238 fg=colour255"
set -g mode-style "bg=colour238 fg=colour255"
set -g status-interval 1
# Short enough that the demo shows the idle marker; the default is 30 seconds.
set -g @bag-silence 2
"""

G, R, D, B, X = "\033[32m", "\033[31m", "\033[2m", "\033[1m", "\033[0m"
# window name: (working directory, screen)
WINDOWS = {
    "api": ("api", f"$ go test ./...\n{G}ok{X}   api/handlers   0.84s\n{G}ok{X}   api/store      1.12s\n{G}ok{X}   api/auth       0.31s\n"),
    "auth-fix": ("auth", "$ git diff --stat\n internal/auth/session.go | 14 ++++++++------\n internal/auth/token.go   |  6 +++---\n 2 files changed, 11 insertions(+), 9 deletions(-)\n"),
    "docs": ("handbook", f"$ mdbook serve\n{D}[INFO] Book building has started{X}\n{D}[INFO] Running the html backend{X}\nServing on http://localhost:3000\n"),
    "flaky-test": ("queue", f"$ go test -run TestRetry -count 50 ./queue\n{R}--- FAIL: TestRetry (0.02s){X}\n    retry_test.go:41: got 2 attempts, want 3\n{R}FAIL{X}\n"),
    "billing": ("billing", f"$ make migrate\napplying 0042_add_invoice_due_date.sql ... {G}done{X}\napplying 0043_backfill_due_dates.sql ...\n"),
    "review": ("invoices", f"$ git log --oneline -3\n{B}a41c9e2{X} add cursor pagination to /invoices\n{B}77d03b1{X} reject forged cursors\n{B}0f2e8aa{X} test: pagination edge cases\n"),
}

PALETTE = {
    "black": (40, 42, 46), "red": (224, 108, 117), "green": (152, 195, 121), "brown": (229, 192, 123),
    "yellow": (229, 192, 123), "blue": (97, 175, 239), "magenta": (198, 120, 221), "cyan": (86, 182, 194),
    "white": (220, 223, 228),
}
BG, FG = (30, 31, 34), (204, 206, 210)
CAPTION_BAR = 40


def tmux(server, *args):
    return subprocess.run(["tmux", "-L", server, *args], check=True, capture_output=True, text=True).stdout


class DimScreen(pyte.Screen):
    """pyte drops SGR 2 (dim); keep it in the unused italics flag."""

    def select_graphic_rendition(self, *attrs, **kwargs):
        super().select_graphic_rendition(*attrs, **kwargs)
        if 2 in attrs:
            self.cursor.attrs = self.cursor.attrs._replace(italics=True)
        if 22 in attrs or 0 in attrs or not attrs:
            self.cursor.attrs = self.cursor.attrs._replace(italics=False)


def color(value, default):
    if value == "default":
        return default
    name = value.removeprefix("bright")
    if name in PALETTE:
        return PALETTE[name]
    return tuple(int(value[i:i + 2], 16) for i in (0, 2, 4))


class Demo:
    def __init__(self, font_dir):
        self.font = ImageFont.truetype(str(font_dir / "JetBrainsMono-Regular.ttf"), 16)
        self.bold = ImageFont.truetype(str(font_dir / "JetBrainsMono-Bold.ttf"), 16)
        self.caption_font = ImageFont.truetype(str(font_dir / "JetBrainsMono-Bold.ttf"), 15)
        ascent, descent = self.font.getmetrics()
        self.cw, self.ch = self.font.getlength("M"), ascent + descent
        self.frames, self.pointer, self.pressed, self.caption = [], (COLS // 2, ROWS // 2), False, ""

    # Screen state.
    def screen(self):
        screen = DimScreen(COLS, ROWS)
        pyte.Stream(screen).feed("\r\n".join(tmux(OUTER, "capture-pane", "-e", "-p", "-t", "o").split("\n")[:ROWS]))
        return screen

    def find(self, text, row=None):
        # A message covers the status line until display-time runs out.
        if row is not None:
            self.wait_for(lambda: text in self.screen().display[row])
        lines = self.screen().display
        for y in ([row] if row is not None else range(ROWS)):
            x = lines[y].find(text)
            if x >= 0:
                return x + len(text) // 2, y
        raise RuntimeError(f"{text!r} not on screen:\n" + "\n".join(lines))

    def wait_for(self, check, timeout=3):
        end = time.time() + timeout
        while time.time() < end:
            if check():
                return
            time.sleep(0.05)
        raise RuntimeError("timed out")

    # Input.
    def mouse(self, kind, x, y):
        button = {"press": "0", "move": "32", "release": "0"}[kind]
        seq = f"\033[<{button};{x + 1};{y + 1}{'m' if kind == 'release' else 'M'}"
        tmux(OUTER, "send-keys", "-t", "o", "-H", *(f"{b:02x}" for b in seq.encode()))

    def key(self, *keys):
        tmux(OUTER, "send-keys", "-t", "o", *keys)

    # Recording.
    def shot(self, ms):
        self.frames.append((self.render(self.screen()), ms))

    def hold(self, ms):
        self.shot(ms)

    def move(self, x, y, steps=14, ms=35):
        x0, y0 = self.pointer
        for i in range(1, steps + 1):
            t = i / steps
            t = t * t * (3 - 2 * t)
            self.pointer = (round(x0 + (x - x0) * t), round(y0 + (y - y0) * t))
            if self.pressed:
                self.mouse("move", *self.pointer)
            time.sleep(0.03)
            self.shot(ms)

    def press(self):
        self.pressed = True
        self.mouse("press", *self.pointer)
        time.sleep(0.15)
        self.shot(120)

    def release(self):
        self.pressed = False
        self.mouse("release", *self.pointer)
        time.sleep(0.5)

    def click(self):
        self.press()
        self.release()

    # Rendering.
    def render(self, screen):
        width, height = round(self.cw * COLS) + 24, round(self.ch * ROWS) + CAPTION_BAR + 12
        img = Image.new("RGB", (width, height), BG)
        draw = ImageDraw.Draw(img)
        draw.rectangle([0, 0, width, CAPTION_BAR], fill=(22, 23, 25))
        for i, dot in enumerate([(255, 95, 87), (254, 188, 46), (40, 200, 64)]):
            draw.ellipse([14 + i * 20, 14, 26 + i * 20, 26], fill=dot)
        if self.caption:
            draw.text((width / 2, CAPTION_BAR / 2), self.caption, font=self.caption_font, fill=(235, 236, 238), anchor="mm")
        ox, oy = 12, CAPTION_BAR + 6
        for y in range(ROWS):
            line = screen.buffer[y]
            for x in range(COLS):
                char = line[x]
                fg, bg = color(char.fg, FG), color(char.bg, BG)
                if char.reverse:
                    fg, bg = bg, fg
                if char.italics:  # dim
                    fg = tuple((f + b) // 2 for f, b in zip(fg, bg))
                left, top = ox + x * self.cw, oy + y * self.ch
                if bg != BG:
                    draw.rectangle([left, top, left + self.cw, top + self.ch], fill=bg)
                if char.data.strip():
                    draw.text((left, top), char.data, font=self.bold if char.bold else self.font, fill=fg)
        px, py = ox + (self.pointer[0] + 0.4) * self.cw, oy + (self.pointer[1] + 0.5) * self.ch
        if self.pressed:
            draw.ellipse([px - 11, py - 11, px + 11, py + 11], outline=(255, 214, 102), width=2)
        arrow = [(0, 0), (0, 17), (4.5, 13), (7.5, 19.5), (10, 18.5), (7, 12), (12.5, 12)]
        draw.polygon([(px + ax, py + ay) for ax, ay in arrow], fill=(255, 255, 255), outline=(0, 0, 0))
        return img

    def save(self, out):
        sample = Image.new("RGB", (self.frames[0][0].width, self.frames[0][0].height * 4))
        for i, idx in enumerate(range(0, len(self.frames), max(1, len(self.frames) // 4))):
            if i < 4:
                sample.paste(self.frames[idx][0], (0, i * self.frames[0][0].height))
        palette = sample.quantize(colors=128, method=Image.Quantize.MEDIANCUT)
        images = [img.quantize(palette=palette, dither=Image.Dither.NONE) for img, _ in self.frames]
        images[0].save(out, save_all=True, append_images=images[1:], duration=[ms for _, ms in self.frames], loop=0, optimize=True)


def setup(tmp):
    conf = tmp / "tmux.conf"
    conf.write_text(CONF)
    for server in (INNER, OUTER):
        subprocess.run(["tmux", "-L", server, "kill-server"], capture_output=True)
    first = True
    for name, (directory, text) in WINDOWS.items():
        cwd = tmp / "work" / directory
        cwd.mkdir(parents=True)
        (cwd / ".screen").write_text(f"{B}~/work/{directory}{X}\n{text}")
        cmd = "cat .screen; PS1='$ ' exec sh"
        if first:
            tmux(INNER, "-f", str(conf), "new-session", "-d", "-s", "work", "-n", name, "-c", str(cwd), "-x", str(COLS), "-y", str(ROWS), cmd)
            first = False
        else:
            tmux(INNER, "new-window", "-d", "-t", "work:", "-n", name, "-c", str(cwd), cmd)
    socket = tmux(INNER, "display-message", "-p", "#{socket_path}").strip()
    subprocess.run(["bash", str(REPO / "tmux-bag.tmux")], check=True, env={**os.environ, "TMUX": f"{socket},0,0"})
    tmux(INNER, "select-window", "-t", "work:2")
    tmux(OUTER, "-f", "/dev/null", "new-session", "-d", "-s", "o", "-x", str(COLS), "-y", str(ROWS),
         f"TERM=tmux-256color tmux -L {INNER} attach -t work")
    tmux(OUTER, "set", "-t", "o", "status", "off")
    time.sleep(1)


def bag(demo, name):
    demo.move(*demo.find(name, ROWS - 1))
    demo.press()
    demo.move(demo.pointer[0] + 2, ROWS - 1, steps=3)
    demo.wait_for(lambda: "drop!" in "".join(demo.screen().display))
    demo.move(*demo.find("drop!"), steps=18)
    demo.hold(350)
    demo.release()
    demo.hold(1800)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--font-dir", type=pathlib.Path, default=pathlib.Path.home() / "Library/Fonts")
    parser.add_argument("--out", type=pathlib.Path, default=REPO / "demo/demo.gif")
    args = parser.parse_args()
    with tempfile.TemporaryDirectory() as tmp:
        setup(pathlib.Path(tmp))
        demo = Demo(args.font_dir)
        try:
            demo.caption = "Too many windows? Drag one onto the bag."
            demo.hold(1400)
            bag(demo, "flaky-test")
            demo.caption = "It keeps running, out of the way."
            bag(demo, "docs")
            demo.caption = "Click the bag to see what's inside."
            demo.move(*demo.find("bag 2", ROWS - 1))
            demo.click()
            demo.wait_for(lambda: "flaky-test" in demo.screen().display[1])
            demo.hold(1800)
            demo.caption = "Pick one to bring it back."
            demo.key("Down")
            time.sleep(0.2)
            demo.hold(1200)
            demo.key("Enter")
            time.sleep(0.5)
            demo.hold(1800)
            demo.caption = "Back where you left it."
            demo.find("bag 1", ROWS - 1)
            demo.move(COLS * 2 // 3, ROWS // 2, steps=10)
            demo.hold(2500)
        finally:
            for server in (INNER, OUTER):
                subprocess.run(["tmux", "-L", server, "kill-server"], capture_output=True)
    demo.save(args.out)
    print(f"{args.out}: {len(demo.frames)} frames, {os.path.getsize(args.out) // 1024} KiB")


if __name__ == "__main__":
    main()
