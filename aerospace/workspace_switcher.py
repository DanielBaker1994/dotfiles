#!/opt/homebrew/bin/python3
import os
import plistlib
import re
import subprocess
import sys
import tkinter as tk
from collections import OrderedDict

from PIL import Image, ImageDraw, ImageFont, ImageTk

# AppKit is loaded once here; fail fast if it's unavailable.
try:
    import ctypes
    OBJC = ctypes.cdll.LoadLibrary("/usr/lib/libobjc.A.dylib")
    ctypes.cdll.LoadLibrary("/System/Library/Frameworks/AppKit.framework/AppKit")
    OBJC.objc_getClass.restype = ctypes.c_void_p
    OBJC.objc_getClass.argtypes = [ctypes.c_char_p]
    OBJC.sel_registerName.restype = ctypes.c_void_p
    OBJC.sel_registerName.argtypes = [ctypes.c_char_p]
    _MSG = OBJC.objc_msgSend
    _SEL = OBJC.sel_registerName
except Exception as e:
    raise SystemExit("workspace-switcher: AppKit/objc failed to load: %r" % (e,))


def objc_call(recv, sel, *args, restype=None, argtypes=None):
    """Send an ObjC message. restype/argtypes default to a pointer-returning
    message with just (self, selector); pass overrides for messages that take
    arguments or return non-pointers (e.g. ctypes.c_ulong / ctypes.c_uint64)."""
    _MSG.restype = restype if restype is not None else ctypes.c_void_p
    _MSG.argtypes = argtypes if argtypes is not None \
        else [ctypes.c_void_p, ctypes.c_void_p]
    return _MSG(recv, _SEL(sel), *args)


AA = 4  # supersampling factor for smooth (anti-aliased) rounded corners

# --- layout constants ---
ROW_H = 30
PAD = 8
WIDTH = 250
PILL_W = 240    # selected-row highlight width (centered)
PILL_H = ROW_H - 6
PILL_RADIUS = 6
PILL_BORDER = 2
RADIUS = 9
ICON_SIZE = 22
ICON_STRIDE = 26
TEXT_X = PAD + 10
ICON_X0 = PAD + 36
ROW_TOP = PAD + 28
FONT = ("SF Pro", 9)

# --- fonts: loaded once at startup, cached on success, never re-attempted ---
GLYPH_RADIUS = 5
GLYPH_FONT_SIZE = 14
FRAME_FONT_SIZE = 11
SFNS_FONT_PATH = "/System/Library/Fonts/SFNS.ttf"
NERD_FONT_PATH = os.path.expanduser("~/Library/Fonts/HackNerdFont-Regular.ttf")


def _load_font(path, size):
    try:
        return ImageFont.truetype(path, size)
    except Exception as e:
        print("workspace-switcher: font load failed (%s): %r; using default"
              % (path, e), file=sys.stderr)
        return ImageFont.load_default()


FRAME_FONT = _load_font(SFNS_FONT_PATH, FRAME_FONT_SIZE * AA)
GLYPH_FONT = _load_font(NERD_FONT_PATH, GLYPH_FONT_SIZE)


def rounded_rect(w, h, r, fill, outline=None, width=0):
    """Anti-aliased rounded rectangle via supersampling."""
    img = Image.new("RGBA", (w * AA, h * AA), (0, 0, 0, 0))
    d = ImageDraw.Draw(img)
    d.rounded_rectangle([0, 0, w * AA - 1, h * AA - 1],
                        radius=r * AA, fill=fill, outline=outline, width=width * AA)
    return img.resize((w, h), Image.LANCZOS)


def rounded_rect_hi(w, h, r, fill, outline=None, width=0):
    """Supersampled (4x) rounded rectangle, NOT downscaled. Used as the base
    for the baked frame so anti-aliasing becomes colour rather than alpha,
    which avoids macOS compositor ghosting."""
    img = Image.new("RGBA", (w * AA, h * AA), (0, 0, 0, 0))
    d = ImageDraw.Draw(img)
    d.rounded_rectangle([0, 0, w * AA - 1, h * AA - 1],
                        radius=r * AA, fill=fill, outline=outline, width=width * AA)
    return img


DOTFILES = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
CACHE = os.path.expanduser("~/.cache/workspace-switcher")
TOGGLE_FLAG = "/tmp/workspace-switcher-toggle"
FOCUS_FILE = "/tmp/workspace-switcher-focus"
# BAR_COLOR lives in colors.sh; the workspace palette in aerospacer.sh
COLOR_SOURCES = [
    os.path.join(DOTFILES, "sketchybar", "colors.sh"),
    os.path.join(DOTFILES, "sketchybar", "plugins", "aerospacer.sh"),
]
MAX_ICONS = 3

APP_DIRS = [
    "/Applications",
    "/Applications/Utilities",
    "/System/Applications",
    "/System/Applications/Utilities",
    "/System/Library/CoreServices",
    os.path.expanduser("~/Applications"),
]


def load_colors_sh():
    out = {}
    for path in COLOR_SOURCES:
        with open(path) as fh:
            for line in fh:
                m = re.match(r"^([A-Z_]+)=0x([0-9a-fA-F]{8})", line.strip())
                if m:
                    out[m.group(1)] = "#" + m.group(2)[2:]
    return out


C = load_colors_sh()
BAR = C["BAR_COLOR"]
GROUP_BG = C["GROUP_BG_COLOR"]
TEXT = C["WHITE"]
DIM = C["GREY"]
BORDER = C["SPACE_BORDER_COLOR"]


# The launcher runs us with a minimal PATH, so resolve aerospace to an
# absolute path at startup instead of relying on PATH.
def _find_aerospace():
    from shutil import which
    for cand in (which("aerospace"),
                 "/opt/homebrew/bin/aerospace",
                 "/usr/local/bin/aerospace"):
        if cand and os.path.isfile(cand):
            return cand
    return "aerospace"


AEROSPACE = _find_aerospace()


def aerospace(*args):
    return subprocess.run([AEROSPACE] + list(args),
                          capture_output=True, text=True).stdout


def find_bundle(app, bundle_id=None):
    for base in APP_DIRS:
        bundle = os.path.join(base, app + ".app")
        if os.path.isdir(bundle):
            return bundle
    # Fallback: resolve via Spotlight using the bundle identifier.
    if bundle_id:
        out = subprocess.run(["mdfind",
                              f"kMDItemCFBundleIdentifier == '{bundle_id}'"],
                             capture_output=True, text=True).stdout.strip()
        if out and os.path.isdir(out):
            return out
    return None


def icon_path(bundle):
    icns = None
    try:
        with open(os.path.join(bundle, "Contents", "Info.plist"), "rb") as fh:
            info = plistlib.load(fh)
        name = info.get("CFBundleIconFile") or info.get("CFBundleIconName") or ""
        cand = os.path.join(bundle, "Contents", "Resources", name + ".icns")
        if os.path.isfile(cand):
            icns = cand
    except Exception:
        pass
    if icns is None:
        res = os.path.join(bundle, "Contents", "Resources")
        if os.path.isdir(res):
            for f in sorted(os.listdir(res)):
                if f.endswith(".icns") and not f.startswith(("document", "fileicon")):
                    return os.path.join(res, f)
    return icns


def app_icon_png(app, bundle_id=None):
    os.makedirs(os.path.join(CACHE, "icons"), exist_ok=True)
    slug = re.sub(r"[^a-z0-9]+", "_", app.lower()).strip("_")
    path = os.path.join(CACHE, "icons", slug + ".png")
    if os.path.isfile(path):
        return path
    bundle = find_bundle(app, bundle_id)
    icns = icon_path(bundle) if bundle else None
    if not icns:
        return None
    try:
        im = Image.open(icns).convert("RGBA").resize(
            (ICON_SIZE, ICON_SIZE), Image.LANCZOS)
        im.save(path)
    except Exception:
        return None
    return path


def missing_glyph():
    """Placeholder tile with a '?' for apps that have no discoverable
    icon (e.g. Webex), so the row still shows something instead of a gap."""
    img = Image.new("RGBA", (ICON_SIZE, ICON_SIZE), (0, 0, 0, 0))
    d = ImageDraw.Draw(img)
    d.rounded_rectangle([0, 0, ICON_SIZE - 1, ICON_SIZE - 1],
                        radius=GLYPH_RADIUS, fill=GROUP_BG, outline=BORDER,
                        width=1)
    bbox = d.textbbox((0, 0), "?", font=GLYPH_FONT)
    d.text(((ICON_SIZE - (bbox[2] - bbox[0])) / 2 - bbox[0],
            (ICON_SIZE - (bbox[3] - bbox[1])) / 2 - bbox[1]),
           "?", font=GLYPH_FONT, fill=TEXT)
    return img


# The placeholder is static, so render it once and reuse it everywhere.
MISSING_GLYPH = missing_glyph()


def center_on_pointer(w, h, px, py):
    """Return "+x+y" placing a w x h window centered on the display under
    (px, py). Falls back to the main display if anything goes wrong."""
    try:
        class _NSRect(ctypes.Structure):
            _fields_ = [("x", ctypes.c_double), ("y", ctypes.c_double),
                        ("w", ctypes.c_double), ("h", ctypes.c_double)]

        def nsstring(s):
            return objc_call(OBJC.objc_getClass(b"NSString"),
                             b"stringWithUTF8String:", s,
                             argtypes=[ctypes.c_void_p, ctypes.c_void_p,
                                       ctypes.c_char_p])

        def frame(screen, key):
            val = objc_call(screen, b"valueForKey:", nsstring(key),
                            argtypes=[ctypes.c_void_p, ctypes.c_void_p,
                                      ctypes.c_void_p])
            r = _NSRect()
            objc_call(val, b"getValue:", ctypes.byref(r), restype=None,
                      argtypes=[ctypes.c_void_p, ctypes.c_void_p,
                                ctypes.c_void_p])
            return r

        cls = OBJC.objc_getClass(b"NSScreen")
        screens = objc_call(cls, b"screens")
        main = objc_call(cls, b"mainScreen")
        n = objc_call(screens, b"count", restype=ctypes.c_ulong)
        mf = frame(main, b"frame")
        # NSScreen coords use a bottom-left origin; Tk uses the primary
        # display's top-left as (0,0), so translate before comparing.
        def to_tk(f):
            return f.x - mf.x, (mf.y + mf.h) - (f.y + f.h)

        for i in range(n):
            scr = objc_call(screens, b"objectAtIndex:", i,
                            argtypes=[ctypes.c_void_p, ctypes.c_void_p,
                                      ctypes.c_ulong])
            vf = frame(scr, b"visibleFrame")
            left, top = to_tk(vf)
            if left <= px < left + vf.w and top <= py < top + vf.h:
                return f"+{int(left + (vf.w - w) / 2)}" \
                       f"+{int(top + (vf.h - h) / 2)}"
        vf = frame(main, b"visibleFrame")
        left, top = to_tk(vf)
        return f"+{int(left + (vf.w - w) / 2)}" \
               f"+{int(top + (vf.h - h) / 2)}"
    except Exception:
        return None


def gather():
    order = aerospace("list-workspaces", "--all").split()
    focused = aerospace("list-workspaces", "--focused").strip()
    apps = OrderedDict((sid, OrderedDict()) for sid in order)
    for line in aerospace("list-windows", "--all",
                          "--format", "%{app-name}|%{app-bundle-id}|%{workspace}").splitlines():
        name, _, rest = line.partition("|")
        bid, _, sid = rest.partition("|")
        if name and sid in apps:
            apps[sid][name] = bid or None
    return order, focused, apps


class Switcher:
    def __init__(self, order, focused, apps):
        self.order = order
        self.focused = focused
        self.apps = apps
        self.visible = list(order)
        self.sel = 0
        self.last_q = ""
        self.rows = []
        self._shown = True
        self._saved_wid = None
        self._saved_app_pid = None

        self.root = tk.Tk()
        self.root.title("workspace-switcher")
        self.root.overrideredirect(True)
        self.root.attributes("-topmost", True)
        try:
            self.root.attributes("-transparent", True)
            self.root.configure(bg="systemTransparent")
        except tk.TclError:
            self.root.configure(bg=BAR)

        height = PAD * 2 + 30 + len(order) * ROW_H
        px, py = self.root.winfo_pointerxy()
        place = center_on_pointer(WIDTH, height, px, py)
        if place is None:
            sw, sh = self.root.winfo_screenwidth(), self.root.winfo_screenheight()
            place = f"+{(sw - WIDTH) // 2}+{(sh - height) // 2}"
        # macOS ignores the first geometry request on overrideredirect windows,
        # so keep it around and re-assert once the window is mapped.
        self.geom = f"{WIDTH}x{height}{place}"
        self.root.geometry(self.geom)

        # Opaque 4x background base (anti-aliasing baked as colour at render time so
        # the transparent window's compositor doesn't ghost moving highlights).
        self.bg4 = rounded_rect_hi(WIDTH, height, RADIUS, fill=BAR,
                                   outline=BORDER, width=1)
        self.canvas = tk.Canvas(self.root, width=WIDTH, height=height,
                                highlightthickness=0, bd=0)
        try:
            self.canvas.configure(bg="systemTransparent")
        except tk.TclError:
            self.canvas.configure(bg=BAR)
        self.canvas.pack()
        self.bg_id = None

        # highlight tile geometry for the cursor-selected row, outlined like the
        # bar's active workspace pill; drawn at 4x into the baked frame.
        self.pill_w = PILL_W
        self.pill_h = PILL_H
        # frame font is cached at module load
        self._pil_font = FRAME_FONT
        # per-app icon PIL cache (avoid re-reading PNGs from disk on every
        # rebuild while typing)
        self._icon_cache = {}

        self.entry = tk.Entry(self.root, font=FONT, bg=BAR, fg=TEXT,
                              insertbackground=BORDER, highlightthickness=0,
                              relief="flat")
        self.canvas.create_window(WIDTH // 2, PAD + 12, window=self.entry,
                                  width=WIDTH - 2 * PAD - 4)
        self.entry.bind("<KeyRelease>", self.on_type)
        for seq in ("<Up>", "<Down>", "<Return>", "<Escape>",
                    "<Control-n>", "<Control-p>", "<Control-j>",
                    "<Tab>", "<Shift-Tab>"):
            self.entry.bind(seq, self.on_key)
            self.root.bind(seq, self.on_key)
        # escape must work even if focus briefly lands elsewhere
        self.root.bind_all("<Escape>", self.on_key)
        self.interacted = False
        self.rebuild()
        # map the window and re-assert the position now, so it first appears
        # centered instead of flashing top-left and jumping
        self.root.update_idletasks()
        try:
            self.root.geometry(self.geom)
        except tk.TclError:
            pass
        self.root.update()
        self.focus_tries = 0
        self._make_borderless()
        self._set_accessory_policy()
        self.root.after(100, self.take_focus)

    def _set_accessory_policy(self):
        """Make this app an 'agent' — no Dock icon, no menu bar, no focus
        stealing on launch or while polling.  We still activate explicitly
        when showing the popup."""
        try:
            nsapp = objc_call(OBJC.objc_getClass(b"NSApplication"),
                              b"sharedApplication")
            objc_call(nsapp, b"setActivationPolicy:", 1, restype=None,
                      argtypes=[ctypes.c_void_p, ctypes.c_void_p,
                                ctypes.c_int])
        except Exception:
            pass

    def _deactivate(self):
        """Deactivate our app so macOS hands focus to the previously active
        one.  Setting alpha=0 alone keeps us as the foreground app, which
        silently steals keystrokes from whatever window the user is typing in."""
        try:
            nsapp = objc_call(OBJC.objc_getClass(b"NSApplication"),
                              b"sharedApplication")
            objc_call(nsapp, b"hide:", None, restype=None,
                      argtypes=[ctypes.c_void_p, ctypes.c_void_p,
                                ctypes.c_void_p])
        except Exception:
            pass

    def _make_borderless(self):
        """Hide the window's title bar / chrome via AppKit. This Tk build
        leaves a title bar even with overrideredirect, so strip it explicitly."""
        try:
            nsapp = objc_call(OBJC.objc_getClass(b"NSApplication"),
                              b"sharedApplication")
            win = objc_call(nsapp, b"keyWindow")
            if win:
                objc_call(win, b"setStyleMask:", 0, restype=None,
                          argtypes=[ctypes.c_void_p, ctypes.c_void_p,
                                    ctypes.c_uint64])
                objc_call(win, b"setTitleVisibility:", 1, restype=None,
                          argtypes=[ctypes.c_void_p, ctypes.c_void_p,
                                    ctypes.c_long])
                objc_call(win, b"setTitlebarAppearsTransparent:", True,
                          restype=None,
                          argtypes=[ctypes.c_void_p, ctypes.c_void_p,
                                    ctypes.c_bool])
        except Exception:
            pass

    def _activate(self):
        """Activate our own NSApplication. Tk focus is internal only; macOS
        routes keys to the frontmost app, so without this a re-shown window
        never receives keyboard input."""
        try:
            app = objc_call(OBJC.objc_getClass(b"NSRunningApplication"),
                            b"currentApplication")
            objc_call(app, b"activateWithOptions:", 2, restype=None,
                      argtypes=[ctypes.c_void_p, ctypes.c_void_p,
                                ctypes.c_uint64])
        except Exception:
            pass

    def _activate_app_by_pid(self, pid):
        """Activate another app by its PID using AppKit. This properly
        transfers foreground status so the target app can receive keyboard
        input (unlike aerospace focus --window-id which cannot steal focus
        from the active app)."""
        try:
            app = objc_call(OBJC.objc_getClass(b"NSRunningApplication"),
                            b"runningApplicationWithProcessIdentifier:",
                            ctypes.c_int(pid),
                            restype=ctypes.c_void_p,
                            argtypes=[ctypes.c_void_p, ctypes.c_void_p,
                                      ctypes.c_int])
            if app:
                # 3 = activateAllWindows(1) | activateIgnoringOtherApps(2)
                objc_call(app, b"activateWithOptions:", 3, restype=None,
                          argtypes=[ctypes.c_void_p, ctypes.c_void_p,
                                    ctypes.c_uint64])
        except Exception:
            pass

    def _restore_focus(self):
        """Hand focus back to the window we saved when showing. First activate
        the target app via AppKit (transfers foreground status), then focus the
        specific window within that app via aerospace."""
        saved = (self._saved_wid, self._saved_app_pid)
        if not self._saved_app_pid:
            self._saved_wid = None
            return
        self._activate_app_by_pid(self._saved_app_pid)
        if self._saved_wid:
            subprocess.run([AEROSPACE, "focus", "--window-id",
                            self._saved_wid])
        self._saved_wid = None
        self._saved_app_pid = None

    def take_focus(self):
        if not self._shown:
            return
        # overrideredirect windows ignore the first geometry request on macOS;
        # re-assert now that the window is mapped so it lands centered
        try:
            self.root.geometry(self.geom)
        except tk.TclError:
            pass
        # aerospace re-focuses the previous window after handling the new one,
        # so re-assert activation a few times until it sticks
        self.root.lift()
        self.root.focus_force()
        self.entry.focus_set()
        self._activate()
        self.focus_tries += 1
        if not self.interacted and self.focus_tries < 30:
            try:
                self.root.after(600, self.take_focus)
            except tk.TclError:
                pass

    def on_type(self, ev):
        # navigation keys must not re-run the filter (it resets the selection)
        if ev.state & 0x4 or ev.keysym in ("Up", "Down", "Return", "Escape",
                                           "Tab"):
            return
        self.interacted = True
        q = self.entry.get().strip().lower()
        if q == self.last_q:
            # query unchanged (e.g. releasing a modifier) - keep our position
            return
        self.last_q = q
        if not q:
            self.visible = list(self.order)
        else:
            self.visible = [sid for sid in self.order
                            if q in sid.lower()
                            or any(q in a.lower() for a in self.apps[sid])]
        if self.sel >= len(self.visible):
            self.sel = max(0, len(self.visible) - 1)
        self.rebuild()

    def on_key(self, ev):
        self.interacted = True
        ctrl = bool(ev.state & 0x4)
        shift = bool(ev.state & 0x1)
        tab = ev.keysym == "Tab"
        if ev.keysym == "Down" or (ctrl and ev.keysym == "n") or (tab and not shift):
            if self.visible:
                self.sel = (self.sel + 1) % len(self.visible)
            self.rebuild()
        elif ev.keysym == "Up" or (ctrl and ev.keysym == "p") or (tab and shift):
            if self.visible:
                self.sel = (self.sel - 1) % len(self.visible)
            self.rebuild()
        elif ev.keysym == "Return" or (ctrl and ev.keysym == "j"):
            self.jump()
        elif ev.keysym == "Escape":
            self.hide()
        return "break"

    def _icon_pil(self, app, bundle_id=None):
        key = (app, bundle_id)
        cached = self._icon_cache.get(key)
        if cached is not None:
            return cached
        icon = None
        png = app_icon_png(app, bundle_id)
        if png:
            try:
                icon = Image.open(png).convert("RGBA")
            except Exception:
                icon = None
        if icon is None:
            icon = MISSING_GLYPH
        self._icon_cache[key] = icon
        return icon

    def rebuild(self):
        for wid in self.rows:
            self.canvas.delete(wid)
        self.rows = []
        if self.bg_id is not None:
            self.canvas.delete(self.bg_id)
        # Render the whole frame at 4x so anti-aliasing becomes colour, then
        # downsample once. The frame is opaque except the window's rounded
        # corners, so moving the highlight never changes alpha distribution
        # and the macOS compositor can't leave a ghost of the old selection.
        frame4 = self.bg4.copy()
        d = ImageDraw.Draw(frame4)
        y = ROW_TOP
        for i, sid in enumerate(self.visible):
            if i == self.sel:
                # center the highlight horizontally (left/right inset equal)
                hlx = (WIDTH - self.pill_w) // 2
                d.rounded_rectangle(
                    [hlx * AA, (y + 2) * AA, (hlx + self.pill_w - 1) * AA,
                     (y + 2 + self.pill_h - 1) * AA],
                    radius=PILL_RADIUS * AA, fill=GROUP_BG, outline=BORDER,
                    width=PILL_BORDER * AA)
            cy = y + self.pill_h // 2 + 2
            d.text((TEXT_X * AA, cy * AA), sid, font=self._pil_font,
                   fill=TEXT, anchor="lm")
            ix = ICON_X0
            for app, bid in list(self.apps[sid].items())[:MAX_ICONS]:
                icon = self._icon_pil(app, bid)
                icon4 = icon.resize((icon.width * AA, icon.height * AA),
                                    Image.LANCZOS)
                frame4.paste(icon4, (ix * AA, (cy - ICON_SIZE // 2) * AA),
                             icon4)
                ix += ICON_STRIDE
            extra = len(self.apps[sid]) - MAX_ICONS
            if extra > 0:
                d.text(((ix + 2) * AA, cy * AA), f"+{extra}",
                       font=self._pil_font, fill=DIM, anchor="lm")
            y += ROW_H
        frame = frame4.resize((WIDTH, self.bg4.size[1] // AA), Image.LANCZOS)
        self.bg_img = ImageTk.PhotoImage(frame)
        self.bg_id = self.canvas.create_image(0, 0, image=self.bg_img,
                                              anchor="nw")
        self.canvas.update_idletasks()

    def jump(self):
        if not self.visible:
            self.hide()
            return
        sid = self.visible[self.sel]
        self.hide()
        subprocess.Popen([AEROSPACE, "workspace", sid])

    def mainloop(self):
        self.root.mainloop()

    def _check_signal(self):
        if os.path.exists(TOGGLE_FLAG):
            try:
                os.unlink(TOGGLE_FLAG)
            except OSError:
                pass
            self.toggle()
        try:
            self.root.after(50, self._check_signal)
        except tk.TclError:
            pass

    def toggle(self):
        if self._shown:
            self.hide()
        else:
            self.show()

    def _move_to_focused_workspace(self):
        wid = aerospace("list-windows", "--monitor", "all",
                        "--pid", str(os.getpid()),
                        "--format", "%{window-id}").strip()
        ws = aerospace("list-workspaces", "--focused").strip()
        if wid and ws:
            subprocess.run([AEROSPACE, "move-node-to-workspace",
                            "--window-id", wid, ws])

    def _save_focus(self):
        """Consume the focus id written by the launcher. If it hasn't landed
        yet (race with the 50 ms poll) fall back to querying aerospace
        ourselves — which is safe here because the toggle is already active."""
        wid = None
        pid = None
        try:
            with open(FOCUS_FILE) as fh:
                line = fh.read().strip()
            if line:
                parts = line.split()
                wid = parts[0]
                pid = int(parts[1]) if len(parts) > 1 else None
                os.unlink(FOCUS_FILE)
        except (OSError, ValueError, IndexError):
            pass
        # Launcher hasn't written the file yet — query it ourselves.
        if not wid:
            try:
                line = aerospace("list-windows", "--focused",
                                 "--format", "%{window-id} %{app-pid}").strip()
                wid, _, apid = line.partition(" ")
                if wid and apid:
                    pid = int(apid)
            except Exception:
                pass
        if wid and pid and pid != os.getpid():
            self._saved_wid = wid
            self._saved_app_pid = pid


    def show(self):
        self._save_focus()
        self.sel = 0
        self.last_q = ""
        self.visible = list(self.order)
        self.entry.delete(0, "end")
        self.rebuild()
        self.root.attributes("-alpha", 1)
        self.root.update()
        try:
            self.root.geometry(self.geom)
        except tk.TclError:
            pass
        self.root.update()
        self.root.lift()
        self.root.focus_force()
        self.entry.focus_set()
        self._activate()
        self.root.update()
        self._shown = True

    def hide(self):
        had_saved = self._saved_app_pid is not None
        self._restore_focus()
        if not had_saved:
            self._deactivate()
        self.root.attributes("-alpha", 0)
        self.root.update()
        self._shown = False


def main():
    order, focused, apps = gather()
    if not order:
        return
    sw = Switcher(order, focused, apps)
    # remove any stale toggle flag so we don't toggle on startup
    try:
        os.unlink(TOGGLE_FLAG)
    except OSError:
        pass
    sw.root.after(50, sw._check_signal)
    sw.mainloop()


if __name__ == "__main__":
    main()
