#!/usr/bin/env python3
"""Claude usage tray / menu-bar widget for macOS and Linux.

Icon = 3 stacked bars: top 5-hour session, middle weekly (all models),
bottom weekly Fable. Click it for details and options (refresh interval,
start at login). Uses the sign-in saved by Claude Code: the macOS Keychain
item "Claude Code-credentials", or ~/.claude/.credentials.json on Linux.

Needs: Python 3.8+, `pip install pystray pillow`
Linux also needs a tray: python3-gi + gir1.2-ayatanaappindicator3-0.1
(GNOME: the "AppIndicator and KStatusNotifierItem Support" extension).
"""
import datetime as dt
import getpass
import json
import os
import platform
import re
import subprocess
import sys
import threading
import urllib.error
import urllib.request
import webbrowser
from pathlib import Path

SYSTEM = platform.system()  # 'Darwin', 'Linux', 'Windows'
CLIENT_ID = "9d1c250a-e61b-44d9-88ed-5944d1962f5e"
USAGE_URL = "https://api.anthropic.com/api/oauth/usage"
TOKEN_URLS = ["https://console.anthropic.com/v1/oauth/token", "https://platform.claude.com/v1/oauth/token"]
KEYCHAIN_SERVICE = "Claude Code-credentials"
CRED_FILE = Path(os.environ.get("CLAUDE_CONFIG_DIR") or Path.home() / ".claude") / ".credentials.json"
CONFIG_DIR = Path(os.environ.get("XDG_CONFIG_HOME") or Path.home() / ".config") / "claude-usage-tray"
SETTINGS_FILE = CONFIG_DIR / "settings.json"
INTERVALS = [1, 3, 5, 10, 15, 30, 60]  # minutes
USAGE_PAGE = "https://claude.ai/settings/usage"


# ---------- credentials ----------

def _keychain_read():
    r = subprocess.run(["security", "find-generic-password", "-s", KEYCHAIN_SERVICE, "-w"],
                       capture_output=True, text=True)
    if r.returncode != 0:
        return None
    raw = r.stdout.strip()
    if raw and not raw.startswith("{"):
        try:
            raw = bytes.fromhex(raw).decode("utf-8")
        except ValueError:
            pass
    return raw


def _keychain_account():
    r = subprocess.run(["security", "find-generic-password", "-s", KEYCHAIN_SERVICE],
                       capture_output=True, text=True)
    m = re.search(r'"acct"<blob>="([^"]*)"', r.stdout)
    return m.group(1) if m else getpass.getuser()


def load_creds():
    """Returns (creds_dict, source) where source is 'keychain' or 'file', or (None, None)."""
    if SYSTEM == "Darwin":
        raw = _keychain_read()
        if raw:
            try:
                return json.loads(raw), "keychain"
            except ValueError:
                pass
    if CRED_FILE.exists():
        try:
            return json.loads(CRED_FILE.read_text(encoding="utf-8")), "file"
        except ValueError:
            pass
    return None, None


def save_creds(creds, source):
    data = json.dumps(creds)
    if source == "keychain":
        subprocess.run(["security", "add-generic-password", "-U", "-a", _keychain_account(),
                        "-s", KEYCHAIN_SERVICE, "-w", data], check=True, capture_output=True)
    else:
        tmp = CRED_FILE.with_suffix(".tmp")
        tmp.write_text(data, encoding="utf-8")
        os.chmod(tmp, 0o600)
        os.replace(tmp, CRED_FILE)


# ---------- API ----------

def http_json(url, headers=None, body=None):
    data = json.dumps(body).encode() if body is not None else None
    req = urllib.request.Request(url, data=data, method="POST" if data else "GET",
                                 headers={"User-Agent": "claude-usage-tray/1.0", **(headers or {})})
    if data:
        req.add_header("Content-Type", "application/json")
    with urllib.request.urlopen(req, timeout=15) as r:
        return json.load(r)


def refresh_token(creds, source):
    o = creds["claudeAiOauth"]
    if not o.get("refreshToken"):
        raise RuntimeError("Sign-in expired. Open Claude Code to sign in again.")
    body = {"grant_type": "refresh_token", "refresh_token": o["refreshToken"], "client_id": CLIENT_ID}
    r = None
    for url in TOKEN_URLS:
        try:
            r = http_json(url, body=body)
            break
        except Exception:
            continue
    if not r or not r.get("access_token"):
        raise RuntimeError("Sign-in expired. Open Claude Code to sign in again.")
    o["accessToken"] = r["access_token"]
    if r.get("refresh_token"):
        o["refreshToken"] = r["refresh_token"]
    if r.get("expires_in"):
        o["expiresAt"] = int((dt.datetime.now(dt.timezone.utc).timestamp() + float(r["expires_in"])) * 1000)
    save_creds(creds, source)


class RateLimited(Exception):
    """Claude answered 429 Too Many Requests."""


def get_usage(token):
    return http_json(USAGE_URL, headers={"Authorization": "Bearer " + token, "anthropic-beta": "oauth-2025-04-20"})


def fetch():
    """Returns (rows, bars, plan). rows: [(name, pct, reset_iso)]; bars: [session, weekly, fable] pct or None."""
    creds, source = load_creds()
    plan = None
    if creds and creds.get("claudeAiOauth"):
        o = creds["claudeAiOauth"]
        plan = o.get("subscriptionType")
        now_ms = dt.datetime.now(dt.timezone.utc).timestamp() * 1000
        if o.get("expiresAt") and now_ms > int(o["expiresAt"]) - 60000:
            refresh_token(creds, source)
        token = creds["claudeAiOauth"]["accessToken"]
    elif os.environ.get("CLAUDE_CODE_OAUTH_TOKEN"):
        token = os.environ["CLAUDE_CODE_OAUTH_TOKEN"]
    else:
        raise RuntimeError('Not signed in. Install Claude Code, run "claude" and sign in.')

    try:
        u = get_usage(token)
    except urllib.error.HTTPError as e:
        if e.code == 401 and creds:
            refresh_token(creds, source)
            u = get_usage(creds["claudeAiOauth"]["accessToken"])
        elif e.code == 401:
            raise RuntimeError("Token rejected. Sign in to Claude Code again.")
        elif e.code == 429:
            raise RateLimited()
        else:
            raise RuntimeError("Could not reach Claude (HTTP %d)" % e.code)
    except urllib.error.URLError as e:
        raise RuntimeError("Could not reach Claude (%s)" % e.reason)

    rows, bars = [], [None, None, None]
    for l in u.get("limits") or []:
        if not l or l.get("percent") is None:
            continue
        slot = -1
        kind = l.get("kind")
        if kind == "session":
            name, slot = "Session (5 hours)", 0
        elif kind == "weekly_all":
            name, slot = "Weekly, all models", 1
        else:
            label = (((l.get("scope") or {}).get("model") or {}).get("display_name")) or kind
            name = "Weekly, " + label
            if "fable" in label.lower():
                slot = 2
        pct = float(l["percent"])
        rows.append((name, pct, l.get("resets_at")))
        if slot >= 0 and bars[slot] is None:
            bars[slot] = pct
    if not rows:  # older response shape
        for key, name, slot in (("five_hour", "Session (5 hours)", 0), ("seven_day", "Weekly, all models", 1)):
            v = u.get(key)
            if v and v.get("utilization") is not None:
                rows.append((name, float(v["utilization"]), v.get("resets_at")))
                bars[slot] = float(v["utilization"])
    if not rows:
        raise RuntimeError("No usage data returned for this account.")
    return rows, bars, plan


def format_reset(iso):
    if not iso:
        return ""
    t = dt.datetime.fromisoformat(iso.replace("Z", "+00:00")).astimezone()
    d = t - dt.datetime.now().astimezone()
    mins = d.total_seconds() / 60
    if mins < 1:
        return "resets now"
    if mins < 24 * 60:
        return "resets in %dh %02dm" % (mins // 60, mins % 60)
    return "resets " + t.strftime("%a %H:%M")


# ---------- settings / autostart ----------

def load_settings():
    try:
        return json.loads(SETTINGS_FILE.read_text(encoding="utf-8"))
    except (OSError, ValueError):
        return {}


def save_settings(s):
    CONFIG_DIR.mkdir(parents=True, exist_ok=True)
    SETTINGS_FILE.write_text(json.dumps(s), encoding="utf-8")


def autostart_path():
    if SYSTEM == "Darwin":
        return Path.home() / "Library/LaunchAgents/com.claude-usage-tray.plist"
    if SYSTEM == "Linux":
        return Path(os.environ.get("XDG_CONFIG_HOME") or Path.home() / ".config") / "autostart/claude-usage-tray.desktop"
    return None


def set_autostart(on):
    p = autostart_path()
    if not on:
        if p.exists():
            p.unlink()
        return
    p.parent.mkdir(parents=True, exist_ok=True)
    py, script = sys.executable, str(Path(__file__).resolve())
    if SYSTEM == "Darwin":
        p.write_text(
            '<?xml version="1.0" encoding="UTF-8"?>\n'
            '<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">\n'
            '<plist version="1.0"><dict>\n'
            '  <key>Label</key><string>com.claude-usage-tray</string>\n'
            '  <key>ProgramArguments</key><array><string>%s</string><string>%s</string></array>\n'
            '  <key>RunAtLoad</key><true/>\n'
            '</dict></plist>\n' % (py, script), encoding="utf-8")
    else:
        p.write_text(
            "[Desktop Entry]\nType=Application\nName=Claude Usage Tray\n"
            'Exec="%s" "%s"\nX-GNOME-Autostart-enabled=true\n' % (py, script), encoding="utf-8")


# ---------- icon ----------

STYLE_CHOICES = [("bars", "Bars"), ("rounded", "Rounded bars"), ("thin", "Thin bars"),
                 ("columns", "Columns"), ("number", "Number (5-hour %)")]
COLOR_CHOICES = [("orange", "Claude orange"), ("traffic", "Traffic light (green / amber / red)"),
                 ("blue", "Blue"), ("perbar", "One color per bar"), ("white", "White"), ("black", "Black")]
INTERVAL_CHOICES = [(m, "1 minute" if m == 1 else "1 hour" if m == 60 else "%d minutes" % m) for m in INTERVALS]
DEFAULT_SETTINGS = {"refreshMinutes": 5, "style": "bars", "color": "orange", "warn": True}
COLORS = {"orange": (217, 119, 87), "traffic": (76, 175, 80), "blue": (66, 133, 244),
          "white": (240, 240, 240), "black": (25, 25, 25)}
PER_BAR = [(217, 119, 87), (66, 133, 244), (156, 110, 230)]  # session, weekly, Fable


def bar_color(slot, p, st):
    c = st["color"]
    if st["warn"] or c == "traffic":
        if p >= 90:
            return (220, 60, 50, 255)
        if p >= 70:
            return (230, 150, 30, 255)
    if c == "perbar":
        rgb = PER_BAR[slot] if 0 <= slot < 3 else PER_BAR[0]
    else:
        rgb = COLORS.get(c, COLORS["orange"])
    return rgb + (255,)


def track_color(st):
    return {"white": (255, 255, 255, 80), "black": (0, 0, 0, 70)}.get(st["color"], (128, 128, 128, 150))


def _font(px):
    from PIL import ImageFont
    for name in ("/System/Library/Fonts/Supplemental/Arial Bold.ttf", "/Library/Fonts/Arial Bold.ttf",
                 "/System/Library/Fonts/Helvetica.ttc", "DejaVuSans-Bold.ttf",
                 "/usr/share/fonts/truetype/dejavu/DejaVuSans-Bold.ttf", "LiberationSans-Bold.ttf", "arialbd.ttf"):
        try:
            return ImageFont.truetype(name, px)
        except OSError:
            continue
    try:
        return ImageFont.load_default(size=px)
    except TypeError:
        return ImageFont.load_default()


def render_icon(pcts, st, error=False, size=64):
    """Draws at 4x and scales down: smooth curves, while square edges (on whole
    pixels of the final size) stay sharp."""
    from PIL import Image, ImageDraw
    S = 4
    W = size * S
    img = Image.new("RGBA", (W, W), (0, 0, 0, 0))
    d = ImageDraw.Draw(img)
    style = st["style"]
    track = track_color(st)

    def box(x, y, w, h):
        return [x * S, y * S, (x + w) * S - 1, (y + h) * S - 1]

    if style == "number" and not error:
        p = pcts[0] or 0.0
        bg = bar_color(0, p, st)
        d.ellipse([0, 0, W - 1, W - 1], fill=bg)
        text = str(int(round(p)))
        em = 0.66 if len(text) == 1 else 0.54 if len(text) == 2 else 0.40
        font = _font(int(W * em))
        l, t, r, b = d.textbbox((0, 0), text, font=font)
        fg = (0, 0, 0, 255) if (0.299 * bg[0] + 0.587 * bg[1] + 0.114 * bg[2]) / 255 > 0.75 else (255, 255, 255, 255)
        d.text(((W - (r - l)) / 2 - l, (W - (b - t)) / 2 - t), text, font=font, fill=fg)
        return img.resize((size, size), getattr(Image, "Resampling", Image).LANCZOS)

    if style == "columns" and not error:
        gap = max(1, round(size * 0.09))
        cw = (size - 2 * gap) // 3
        left = (size - (3 * cw + 2 * gap)) // 2
        y0, ch = 1, size - 2
        for i in range(3):
            x = left + i * (cw + gap)
            d.rectangle(box(x, y0, cw, ch), fill=track)
            p = pcts[i]
            if p:
                fh = max(1, round(min(100.0, p) / 100 * ch))
                d.rectangle(box(x, y0 + ch - fh, cw, fh), fill=bar_color(i, p, st))
        return img.resize((size, size), getattr(Image, "Resampling", Image).LANCZOS)

    if style == "thin":
        bh = max(2, round(size * 0.16))
        gap = (size - 3 * bh) // 4
    else:
        gap = max(1, round(size * 0.09))
        bh = (size - 2 * gap) // 3
    top = (size - (3 * bh + 2 * gap)) // 2
    x0, bw = 1, size - 2
    for i in range(3):
        y = top + i * (bh + gap)
        bx = box(x0, y, bw, bh)
        if error:  # hollow bars = no data
            d.rectangle(bx, outline=(140, 140, 140, 255), width=max(S, size * S // 32))
            continue
        p = pcts[i]
        fw = max(1, round(min(100.0, p) / 100 * bw)) if p else 0
        if style == "rounded":
            r = bh * S // 2
            d.rounded_rectangle(bx, radius=r, fill=track)
            if fw:
                mask = Image.new("L", img.size, 0)
                md = ImageDraw.Draw(mask)
                md.rounded_rectangle(bx, radius=r, fill=255)
                md.rectangle([(x0 + fw) * S, 0, W, W], fill=0)  # clip to the filled part
                img.paste(bar_color(i, p, st), (0, 0, W, W), mask)
        else:
            d.rectangle(bx, fill=track)
            if fw:
                d.rectangle(box(x0, y, fw, bh), fill=bar_color(i, p, st))
    return img.resize((size, size), getattr(Image, "Resampling", Image).LANCZOS)


# ---------- app ----------

def _noop(icon, item):
    pass


class App:
    def __init__(self):
        import pystray
        self.pystray = pystray
        self.rows, self.bars, self.plan = [], [None, None, None], None
        self.error, self.updated = "Loading...", None
        self.notice, self.retry_min = None, 0  # retry_min > 0 while backing off after a 429
        self.settings = dict(DEFAULT_SETTINGS)
        self.settings.update({k: v for k, v in load_settings().items() if k in DEFAULT_SETTINGS})
        for key, choices in (("refreshMinutes", INTERVAL_CHOICES), ("style", STYLE_CHOICES), ("color", COLOR_CHOICES)):
            if self.settings[key] not in [c[0] for c in choices]:
                self.settings[key] = DEFAULT_SETTINGS[key]
        self.wake = threading.Event()
        self.running = True
        self.icon = pystray.Icon("claude-usage-tray", render_icon(None, self.settings, error=True),
                                 "Claude usage", menu=self.build_menu())

    def build_menu(self):
        Item, Menu = self.pystray.MenuItem, self.pystray.Menu

        def row(i):
            return Item(lambda item: self.row_text(i), _noop, enabled=False,
                        visible=lambda item: i < len(self.rows))

        def choices(key, options, extra=()):
            def pick(value):
                def action(icon, item):
                    self.settings[key] = value
                    save_settings(self.settings)
                    if key == "refreshMinutes":
                        self.wake.set()  # restarts the countdown (and refreshes now)
                    else:
                        self.redraw()
                return action
            return Menu(*[Item(label, pick(v), checked=lambda item, v=v: self.settings[key] == v, radio=True)
                          for v, label in options], *extra)

        def toggle_warn(icon, item):
            self.settings["warn"] = not self.settings["warn"]
            save_settings(self.settings)
            self.redraw()

        items = [
            Item(lambda item: "Claude usage" + ("  |  " + self.plan if self.plan else ""), _noop, enabled=False),
            Item(lambda item: self.error or "", _noop, enabled=False, visible=lambda item: bool(self.error)),
            Item(lambda item: self.notice or "", _noop, enabled=False, visible=lambda item: bool(self.notice)),
        ]
        items += [row(i) for i in range(6)]
        items += [
            Item(lambda item: "Updated " + self.updated.strftime("%H:%M") if self.updated else "", _noop,
                 enabled=False, visible=lambda item: self.updated is not None),
            Menu.SEPARATOR,
            Item("Refresh now", lambda icon, item: self.wake.set()),
            Item("Refresh every", choices("refreshMinutes", INTERVAL_CHOICES)),
            Item("Style", choices("style", STYLE_CHOICES)),
            Item("Color", choices("color", COLOR_CHOICES, (
                Menu.SEPARATOR,
                Item("Turn amber / red at 70% / 90%", toggle_warn, checked=lambda item: self.settings["warn"])))),
            Item("Open usage on claude.ai", lambda icon, item: webbrowser.open(USAGE_PAGE)),
        ]
        if autostart_path():
            items.append(Item("Start at login", lambda icon, item: set_autostart(not autostart_path().exists()),
                              checked=lambda item: autostart_path().exists()))
        items += [Menu.SEPARATOR, Item("Quit", self.quit)]
        return Menu(*items)

    def row_text(self, i):
        if i >= len(self.rows):
            return ""
        name, pct, reset = self.rows[i]
        r = format_reset(reset)
        return "%s: %d%%%s" % (name, round(pct), ("  (" + r + ")") if r else "")

    def redraw(self):
        if self.error:
            self.icon.icon = render_icon(None, self.settings, error=True)
            self.icon.title = "Claude: " + self.error
        else:
            self.icon.icon = render_icon(self.bars, self.settings)
            names = ("5 hours", "Weekly", "Fable")
            self.icon.title = ("Claude (retrying later)\n" if self.notice else "Claude usage\n") + "\n".join(
                "%s: %s" % (n, "-" if b is None else "%d%%" % round(b)) for n, b in zip(names, self.bars))
        self.icon.update_menu()

    def update(self):
        try:
            self.rows, self.bars, self.plan = fetch()
            self.error, self.updated = None, dt.datetime.now()
            self.notice, self.retry_min = None, 0
        except RateLimited:
            # Too many requests: back off (doubling, up to 30 min) and keep showing the last numbers
            self.retry_min = min(30, max(2, max(self.retry_min, self.settings["refreshMinutes"]) * 2))
            msg = "Claude is limiting requests. Retrying in %d min." % self.retry_min
            if self.rows:
                self.notice, self.error = msg + " Showing the last numbers.", None
            else:
                self.error = msg
        except Exception as e:
            self.error = str(e)
        self.redraw()

    def loop(self, icon):
        icon.visible = True
        while self.running:
            self.update()
            self.wake.wait((self.retry_min or self.settings["refreshMinutes"]) * 60)
            self.wake.clear()

    def quit(self, icon, item):
        self.running = False
        self.wake.set()
        icon.stop()

    def run(self):
        if SYSTEM == "Darwin":
            try:  # menu-bar only, no Dock icon
                from AppKit import NSApplication
                NSApplication.sharedApplication().setActivationPolicy_(1)  # Accessory
            except Exception:
                pass
        self.icon.run(setup=self.loop)


def single_instance():
    if SYSTEM == "Windows":
        return True
    import fcntl
    CONFIG_DIR.mkdir(parents=True, exist_ok=True)
    global _lock_file
    _lock_file = open(CONFIG_DIR / "lock", "w")
    try:
        fcntl.flock(_lock_file, fcntl.LOCK_EX | fcntl.LOCK_NB)
        return True
    except OSError:
        return False


if __name__ == "__main__":
    if not single_instance():
        sys.exit(0)
    App().run()
