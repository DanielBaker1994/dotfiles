//! ghostty-strip-bar — the AeroSpace workspace strip as a tiny native panel.
//!
//! Every workspace with its open apps (real app icons), the focused one
//! highlighted, click a workspace to switch to it. The panel is a borderless,
//! non-activating, always-on-top `NSPanel` pinned to the top-right of the
//! frontmost visible Ghostty window, and hidden while no Ghostty window is on
//! screen (AeroSpace parks other workspaces' windows off-screen). Unlike a
//! Ghostty window it has no minimum height, so it is only as tall as it needs
//! to be (`STRIP_BAR_HEIGHT`, default 24pt).
//!
//! Data comes from the `aerospace` CLI: a background thread watches
//! `aerospace subscribe --all` and flags a refresh on every event.

use std::cell::RefCell;
use std::io::{BufRead, BufReader};
use std::process::{Command, Stdio};
use std::sync::atomic::{AtomicBool, Ordering};
use std::time::{Duration, Instant};

use objc2::rc::Retained;
use objc2::runtime::AnyObject;
use objc2::{define_class, msg_send, sel, DefinedClass, MainThreadMarker, MainThreadOnly};
use objc2_app_kit::{
    NSApplication, NSApplicationActivationPolicy, NSBackingStoreType, NSColor, NSEvent, NSFont,
    NSImageView, NSPanel, NSScreen, NSTextField, NSView, NSWindowCollectionBehavior,
    NSWindowStyleMask, NSWorkspace,
};
use objc2_foundation::{
    NSArray, NSDictionary, NSNumber, NSObject, NSObjectProtocol, NSPoint, NSRect, NSSize, NSString,
    NSTimer,
};

const AEROSPACE: &str = "/opt/homebrew/bin/aerospace";
const MARGIN: f64 = 6.0; // gap to the Ghostty window's top-right corner
const PAD_X: f64 = 10.0;
const ICON_GAP: f64 = 4.0;
const GROUP_GAP: f64 = 14.0;
const LABEL_GAP: f64 = 5.0;

static DIRTY: AtomicBool = AtomicBool::new(true);

#[derive(Clone, PartialEq)]
struct App {
    name: String,
    path: String,
}

#[derive(Clone, PartialEq)]
struct Group {
    ws: String,
    apps: Vec<App>,
}

struct Hit {
    x0: f64,
    x1: f64,
    ws: String,
}

/// Append a line to ~/.cache/ghostty-strip/bar.log (or $STRIP_BAR_LOG).
fn log(msg: &str) {
    use std::io::Write;
    let path = std::env::var("STRIP_BAR_LOG").unwrap_or_else(|_| {
        let dir = format!("{}/.cache/ghostty-strip", std::env::var("HOME").unwrap_or_default());
        let _ = std::fs::create_dir_all(&dir);
        format!("{dir}/bar.log")
    });
    if let Ok(mut f) = std::fs::OpenOptions::new().create(true).append(true).open(path) {
        let secs = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .map(|d| d.as_secs())
            .unwrap_or(0);
        let _ = writeln!(f, "{secs} pid {} {msg}", std::process::id());
    }
}

// -- aerospace ---------------------------------------------------------------

fn aerospace_bin() -> &'static str {
    if std::path::Path::new(AEROSPACE).exists() {
        AEROSPACE
    } else {
        "aerospace"
    }
}

fn aerospace(args: &[&str]) -> String {
    Command::new(aerospace_bin())
        .args(args)
        .output()
        .map(|o| String::from_utf8_lossy(&o.stdout).into_owned())
        .unwrap_or_default()
}

/// (focused workspace, groups) — letters first, then numbers: G M Y 1 2 9.
fn snapshot() -> (String, Vec<Group>) {
    let focused = aerospace(&["list-workspaces", "--focused"]).trim().to_string();
    let mut groups: Vec<Group> = Vec::new();
    let out = aerospace(&[
        "list-windows",
        "--all",
        "--format",
        "%{workspace}|%{app-name}|%{app-bundle-path}",
    ]);
    for line in out.lines() {
        let parts: Vec<&str> = line.split('|').collect();
        if parts.len() != 3 {
            continue;
        }
        let app = App { name: parts[1].to_string(), path: parts[2].to_string() };
        match groups.iter_mut().find(|g| g.ws == parts[0]) {
            Some(g) => {
                if !g.apps.contains(&app) {
                    g.apps.push(app);
                }
            }
            None => groups.push(Group { ws: parts[0].to_string(), apps: vec![app] }),
        }
    }
    if !focused.is_empty() && !groups.iter().any(|g| g.ws == focused) {
        groups.push(Group { ws: focused.clone(), apps: vec![] });
    }
    groups.sort_by_key(|g| {
        let n = g.ws.parse::<u32>().ok();
        (n.is_some(), n.unwrap_or(0), g.ws.clone())
    });
    (focused, groups)
}

fn watch_events() {
    loop {
        if let Ok(mut child) = Command::new(aerospace_bin())
            .args(["subscribe", "--all"])
            .stdout(Stdio::piped())
            .stderr(Stdio::null())
            .spawn()
        {
            if let Some(out) = child.stdout.take() {
                for _ in BufReader::new(out).lines().map_while(Result::ok) {
                    DIRTY.store(true, Ordering::Relaxed);
                }
            }
            let _ = child.wait();
        }
        std::thread::sleep(Duration::from_secs(2));
    }
}

// -- where is Ghostty --------------------------------------------------------

#[link(name = "CoreGraphics", kind = "framework")]
extern "C" {
    fn CGWindowListCopyWindowInfo(option: u32, relative_to_window: u32) -> *mut AnyObject;
}

fn num(dict: &NSDictionary, key: &str) -> Option<f64> {
    let key = NSString::from_str(key);
    let v = dict.objectForKey(&key)?;
    Some(v.downcast::<NSNumber>().ok()?.doubleValue())
}

/// The frontmost on-screen Ghostty window as (x, y, w, h) in CG coordinates
/// (origin top-left of the primary display), or None.
fn ghostty_frame(screens: &[(f64, f64, f64, f64)]) -> Option<(f64, f64, f64, f64)> {
    const ON_SCREEN_ONLY: u32 = 1;
    const EXCLUDE_DESKTOP: u32 = 1 << 4;
    // SAFETY: Copy-rule CF call, so we own the +1 array and hand it to Retained.
    let arr: Retained<NSArray<NSDictionary>> = unsafe {
        let p = CGWindowListCopyWindowInfo(ON_SCREEN_ONLY | EXCLUDE_DESKTOP, 0);
        Retained::from_raw(p.cast())?
    };
    for dict in arr.iter() {
        let owner_key = NSString::from_str("kCGWindowOwnerName");
        let owner = dict
            .objectForKey(&owner_key)
            .and_then(|o| o.downcast::<NSString>().ok())
            .map(|s| s.to_string());
        if owner.as_deref() != Some("Ghostty") || num(&dict, "kCGWindowLayer") != Some(0.0) {
            continue;
        }
        let bounds_key = NSString::from_str("kCGWindowBounds");
        let Some(b) = dict
            .objectForKey(&bounds_key)
            .and_then(|o| o.downcast::<NSDictionary>().ok())
        else {
            continue;
        };
        let (Some(x), Some(y), Some(w), Some(h)) =
            (num(&b, "X"), num(&b, "Y"), num(&b, "Width"), num(&b, "Height"))
        else {
            continue;
        };
        // AeroSpace parks hidden workspaces' windows off-screen: ignore windows
        // that are mostly outside every display.
        let visible = screens.iter().any(|&(sx, sy, sw, sh)| {
            let ox = (x + w).min(sx + sw) - x.max(sx);
            let oy = (y + h).min(sy + sh) - y.max(sy);
            ox > 0.0 && oy > 0.0 && ox * oy >= 0.5 * w * h
        });
        if visible && w > 200.0 && h > 100.0 {
            return Some((x, y, w, h));
        }
    }
    None
}

// -- the view ----------------------------------------------------------------

struct ViewIvars {
    hits: RefCell<Vec<Hit>>,
}

define_class!(
    #[unsafe(super(NSView))]
    #[thread_kind = MainThreadOnly]
    #[name = "GSBarView"]
    #[ivars = ViewIvars]
    struct BarView;

    impl BarView {
        /// Children (labels, icons) must not swallow clicks.
        #[unsafe(method(hitTest:))]
        fn hit_test(&self, _point: NSPoint) -> Option<&NSView> {
            Some(&**self)
        }

        #[unsafe(method(acceptsFirstMouse:))]
        fn accepts_first_mouse(&self, _event: Option<&NSEvent>) -> bool {
            true
        }

        #[unsafe(method(mouseDown:))]
        fn mouse_down(&self, event: &NSEvent) {
            let p = self.convertPoint_fromView(event.locationInWindow(), None);
            let ws = self
                .ivars()
                .hits
                .borrow()
                .iter()
                .find(|h| p.x >= h.x0 && p.x <= h.x1)
                .map(|h| h.ws.clone());
            let Some(ws) = ws else {
                log(&format!("click x={:.0} y={:.0}: no workspace there", p.x, p.y));
                return;
            };
            // test hook: record the click instead of switching workspace
            if std::env::var("STRIP_BAR_LOG").is_ok() {
                log(&format!("click x={:.0}: workspace {ws} (not switched: STRIP_BAR_LOG)", p.x));
                return;
            }
            let rc = Command::new(aerospace_bin())
                .args(["workspace", &ws])
                .stdout(Stdio::null())
                .stderr(Stdio::null())
                .status()
                .map(|s| s.code().unwrap_or(-1))
                .unwrap_or(-2);
            log(&format!("click x={:.0}: workspace {ws}, aerospace exit {rc}", p.x));
        }
    }

    unsafe impl NSObjectProtocol for BarView {}
);

impl BarView {
    fn create(mtm: MainThreadMarker) -> Retained<BarView> {
        let this = BarView::alloc(mtm).set_ivars(ViewIvars { hits: RefCell::new(Vec::new()) });
        let view: Retained<BarView> = unsafe { msg_send![super(this), init] };
        view.setWantsLayer(true);
        if let Some(layer) = view.layer() {
            let bg = NSColor::colorWithSRGBRed_green_blue_alpha(0.10, 0.105, 0.15, 0.96);
            layer.setBackgroundColor(Some(&bg.CGColor()));
            let border = NSColor::colorWithSRGBRed_green_blue_alpha(1.0, 1.0, 1.0, 0.10);
            layer.setBorderColor(Some(&border.CGColor()));
            layer.setBorderWidth(1.0);
        }
        view
    }

    /// Rebuild the labels and icons; returns the width the content needs.
    fn rebuild(&self, mtm: MainThreadMarker, focused: &str, groups: &[Group], height: f64) -> f64 {
        for sv in self.subviews().to_vec() {
            sv.removeFromSuperview();
        }
        if let Some(layer) = self.layer() {
            layer.setCornerRadius(height / 2.0);
        }
        let icon = (height - 8.0).clamp(12.0, 22.0);
        let font = NSFont::systemFontOfSize(11.0);
        let accent = NSColor::colorWithSRGBRed_green_blue_alpha(0.48, 0.64, 0.97, 1.0);
        let dim = NSColor::colorWithSRGBRed_green_blue_alpha(0.45, 0.47, 0.56, 1.0);
        let mut hits = Vec::new();
        let mut x = PAD_X;
        for g in groups {
            let x0 = x;
            let label = NSTextField::labelWithString(&NSString::from_str(&g.ws), mtm);
            label.setFont(Some(&font));
            label.setTextColor(Some(if g.ws == focused { &accent } else { &dim }));
            label.sizeToFit();
            let lf = label.frame().size;
            label.setFrame(NSRect::new(
                NSPoint::new(x, ((height - lf.height) / 2.0).round()),
                lf,
            ));
            self.addSubview(&label);
            x += lf.width + LABEL_GAP;
            for (i, app) in g.apps.iter().enumerate() {
                if i > 0 {
                    x += ICON_GAP;
                }
                let img = NSWorkspace::sharedWorkspace().iconForFile(&NSString::from_str(&app.path));
                let iv = NSImageView::imageViewWithImage(&img, mtm);
                iv.setFrame(NSRect::new(
                    NSPoint::new(x, ((height - icon) / 2.0).round()),
                    NSSize::new(icon, icon),
                ));
                self.addSubview(&iv);
                x += icon;
            }
            hits.push(Hit { x0: x0 - GROUP_GAP / 2.0, x1: x + GROUP_GAP / 2.0, ws: g.ws.clone() });
            x += GROUP_GAP;
        }
        *self.ivars().hits.borrow_mut() = hits;
        (x - GROUP_GAP + PAD_X).max(PAD_X * 2.0)
    }
}

// -- the controller (timer tick) ---------------------------------------------

struct CtlIvars {
    panel: Retained<NSPanel>,
    view: Retained<BarView>,
    height: f64,
    state: RefCell<State>,
}

struct State {
    shown: Option<(String, Vec<Group>)>,
    width: f64,
    last_refresh: Instant,
    visible: bool,
}

define_class!(
    #[unsafe(super(NSObject))]
    #[thread_kind = MainThreadOnly]
    #[name = "GSBarController"]
    #[ivars = CtlIvars]
    struct Controller;

    impl Controller {
        #[unsafe(method(tick:))]
        fn tick(&self, _timer: &NSTimer) {
            self.update();
        }
    }

    unsafe impl NSObjectProtocol for Controller {}
);

impl Controller {
    fn update(&self) {
        let mtm = self.mtm();
        let iv = self.ivars();
        let mut st = iv.state.borrow_mut();

        if DIRTY.swap(false, Ordering::Relaxed) || st.last_refresh.elapsed() > Duration::from_secs(15) {
            st.last_refresh = Instant::now();
            let snap = snapshot();
            if st.shown.as_ref() != Some(&snap) {
                st.width = iv.view.rebuild(mtm, &snap.0, &snap.1, iv.height);
                st.shown = Some(snap);
            }
        }

        // CG coordinates: origin top-left of the primary display.
        let screens = NSScreen::screens(mtm);
        let primary_h = screens.iter().next().map(|s| s.frame().size.height).unwrap_or(0.0);
        let rects: Vec<_> = screens
            .iter()
            .map(|s| {
                let f = s.frame();
                (f.origin.x, primary_h - f.origin.y - f.size.height, f.size.width, f.size.height)
            })
            .collect();

        match ghostty_frame(&rects) {
            Some((x, y, w, _h)) => {
                let (pw, ph) = (st.width, iv.height);
                let frame = NSRect::new(
                    NSPoint::new((x + w - pw - MARGIN).round(), (primary_h - (y + MARGIN) - ph).round()),
                    NSSize::new(pw, ph),
                );
                if iv.panel.frame() != frame {
                    iv.panel.setFrame_display(frame, true);
                    iv.view.setFrame(NSRect::new(NSPoint::new(0.0, 0.0), frame.size));
                }
                if !st.visible {
                    iv.panel.orderFrontRegardless();
                    st.visible = true;
                }
            }
            None => {
                if st.visible {
                    iv.panel.orderOut(None);
                    st.visible = false;
                }
            }
        }
    }
}

fn main() {
    let mtm = MainThreadMarker::new().expect("main thread");
    let app = NSApplication::sharedApplication(mtm);
    app.setActivationPolicy(NSApplicationActivationPolicy::Accessory);

    let height: f64 = std::env::var("STRIP_BAR_HEIGHT")
        .ok()
        .and_then(|v| v.parse().ok())
        .unwrap_or(24.0);

    let view = BarView::create(mtm);
    let panel = NSPanel::initWithContentRect_styleMask_backing_defer(
        NSPanel::alloc(mtm),
        NSRect::new(NSPoint::new(0.0, 0.0), NSSize::new(200.0, height)),
        NSWindowStyleMask::Borderless | NSWindowStyleMask::NonactivatingPanel,
        NSBackingStoreType::Buffered,
        false,
    );
    panel.setLevel(3); // NSFloatingWindowLevel
    panel.setOpaque(false);
    panel.setBackgroundColor(Some(&NSColor::clearColor()));
    panel.setHasShadow(false);
    panel.setHidesOnDeactivate(false);
    unsafe { panel.setReleasedWhenClosed(false) };
    panel.setCollectionBehavior(
        NSWindowCollectionBehavior::CanJoinAllSpaces
            | NSWindowCollectionBehavior::Stationary
            | NSWindowCollectionBehavior::IgnoresCycle
            | NSWindowCollectionBehavior::FullScreenAuxiliary,
    );
    panel.setContentView(Some(&view));

    std::thread::spawn(watch_events);
    log("started");

    let ctl = Controller::alloc(mtm).set_ivars(CtlIvars {
        panel,
        view,
        height,
        state: RefCell::new(State {
            shown: None,
            width: 100.0,
            last_refresh: Instant::now(),
            visible: false,
        }),
    });
    let ctl: Retained<Controller> = unsafe { msg_send![super(ctl), init] };
    unsafe {
        NSTimer::scheduledTimerWithTimeInterval_target_selector_userInfo_repeats(
            0.25,
            &ctl,
            sel!(tick:),
            None,
            true,
        );
    }
    app.run();
}
