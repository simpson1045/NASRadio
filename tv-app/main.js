// NASRadio TV: the cast screen as a full-screen app on ELKO (4K, 120 Hz).
// It only hosts the page. /cast/tv.html is served by the NASRadio backend:
// the same receiver the C2 casts, with caf_local.js in place of Google's SDK,
// so the two screens can't drift apart. The backend drives it like a
// Chromecast (backend/app/cast_relay.py).
const { app, BrowserWindow, ipcMain, powerSaveBlocker, screen } = require('electron');
const fs = require('fs');
const path = require('path');
const { MpvController } = require('./mpv');

// Music has to start without anyone clicking, like on a TV.
app.commandLine.appendSwitch('autoplay-policy', 'no-user-gesture-required');

// nasradio-tv.json next to the .exe (installed copy) or this file (dev):
// {"server": "http://192.168.1.50:5002", "player": "ELKO"}. The player key
// sits beside it in player.key (copied from the backend's data/tv_player_key)
// so the config itself holds no secret.
function loadConfig() {
  for (const dir of [path.dirname(process.execPath), __dirname]) {
    const p = path.join(dir, 'nasradio-tv.json');
    if (!fs.existsSync(p)) continue;
    const cfg = JSON.parse(fs.readFileSync(p, 'utf8'));
    const keyFile = path.join(dir, 'player.key');
    if (!cfg.key && fs.existsSync(keyFile)) cfg.key = fs.readFileSync(keyFile, 'utf8').trim();
    return cfg;
  }
  throw new Error('nasradio-tv.json not found next to the app');
}

// Lay the page out at the C2's size. Google Cast on the C2 lays the receiver
// out at 1280x720 CSS px (dpr 1.5); ELKO's 4K screen at Windows' 200-225%
// scaling gave the same page 1920x1080 or 1707x960, so everything was 2/3
// the size of the Cast screen (Nov 14, 2026). Page zoom = screen / 1280x720
// makes ELKO match the C2 exactly; the extra pixels go to sharpness
// (dpr 3), not to a smaller layout. Re-fit whenever ELKO's display or
// scaling changes (house_elko switches DENON-AVR / LG TV outputs).
const LAYOUT_W = 1280;
const LAYOUT_H = 720;

if (!app.requestSingleInstanceLock()) {
  app.quit();
} else {
  let win = null;
  let mpv = null;

  const fitZoom = () => {
    if (!win || win.isDestroyed()) return;
    // A hidden window's content size isn't the screen yet; the display is.
    let w, h;
    if (win.isVisible()) {
      [w, h] = win.getContentSize();
    } else {
      ({ width: w, height: h } = screen.getDisplayMatching(win.getBounds()).size);
    }
    if (!w || !h) return;
    const f = Math.min(w / LAYOUT_W, h / LAYOUT_H);
    if (Math.abs(win.webContents.getZoomFactor() - f) > 0.001) {
      win.webContents.setZoomFactor(f);
      console.log(`[NASRadio TV] zoom ${f.toFixed(3)} for ${w}x${h}`);
    }
  };

  app.whenReady().then(() => {
    const cfg = loadConfig();
    // The audio player (mpv.js). Started before the page loads: preload.js
    // asks whether it's there as the page starts. "mpv" in nasradio-tv.json
    // overrides the install path.
    mpv = new MpvController(cfg.mpv, (ev) => {
      if (win && !win.isDestroyed()) win.webContents.send('nasradio-mpv-event', ev);
    });
    mpv.start();
    ipcMain.on('nasradio-mpv-available', (e) => { e.returnValue = mpv.available(); });
    ipcMain.on('nasradio-mpv-command', (e, args) => {
      if (Array.isArray(args)) mpv.send(args);
    });
    app.on('will-quit', () => mpv.stop());

    const url = `${cfg.server.replace(/\/$/, '')}/cast/tv.html`
      + `?player=${encodeURIComponent(cfg.player || 'ELKO')}&key=${encodeURIComponent(cfg.key)}`;
    // Hidden until a cast starts: an open app must never cover ELKO's
    // desktop (or a full-screen NASRadio window) on its own.
    win = new BrowserWindow({
      show: false,
      fullscreen: true,
      frame: false,
      autoHideMenuBar: true,
      backgroundColor: '#000000',
      webPreferences: { backgroundThrottling: false, preload: path.join(__dirname, 'preload.js') },
    });
    win.loadURL(url);
    // Zoom is per page load; re-apply on every load and on any size change.
    win.webContents.on('did-finish-load', fitZoom);
    win.on('resize', fitZoom);
    win.on('show', fitZoom);
    screen.on('display-metrics-changed', fitZoom);
    screen.on('display-added', fitZoom);
    screen.on('display-removed', fitZoom);
    // The backend restarts now and then: keep trying until it answers.
    win.webContents.on('did-fail-load', (e, code, desc, failedUrl, isMainFrame) => {
      if (isMainFrame) setTimeout(() => win && win.loadURL(url), 5000);
    });
    powerSaveBlocker.start('prevent-display-sleep');
  });

  // caf_local.js: a cast started (LOAD) or ended (STOP). Windows won't let a
  // background app take the foreground, but a top-most window is allowed
  // over a full-screen one (Oct 30: the first cast played hidden behind
  // the full-screen desktop app).
  ipcMain.on('nasradio-tv-active', (e, on) => {
    if (!win) return;
    if (on) {
      // Drop and re-take top-most so Windows re-stacks us above the
      // taskbar: after a hide/show it otherwise keeps the taskbar on top of
      // a window that isn't the foreground one (Oct 31: it covered the
      // scrubber after a stop + resume).
      win.setAlwaysOnTop(false);
      win.setFullScreen(true);
      win.show();
      win.setAlwaysOnTop(true, 'screen-saver');
      win.moveTop();
      // The shell re-raises the taskbar a moment after a non-foreground
      // full-screen window appears; re-stack once it has settled.
      [800, 2500].forEach((ms) => setTimeout(() => {
        if (!win || !win.isVisible()) return;
        win.setAlwaysOnTop(false);
        win.setAlwaysOnTop(true, 'screen-saver');
        win.moveTop();
      }, ms));
    } else {
      win.setAlwaysOnTop(false);
      win.hide();
    }
  });

  app.on('second-instance', () => {
    if (win) {
      win.show();
      win.focus();
    }
  });
  app.on('window-all-closed', () => app.quit());
}
