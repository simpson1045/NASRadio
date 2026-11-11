// NASRadio TV: the cast screen as a full-screen app on ELKO (4K, 120 Hz).
// It only hosts the page. /cast/tv.html is served by the NASRadio backend:
// the same receiver the C2 casts, with caf_local.js in place of Google's SDK,
// so the two screens can't drift apart. The backend drives it like a
// Chromecast (backend/app/cast_relay.py).
const { app, BrowserWindow, ipcMain, powerSaveBlocker } = require('electron');
const fs = require('fs');
const path = require('path');

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

if (!app.requestSingleInstanceLock()) {
  app.quit();
} else {
  let win = null;

  app.whenReady().then(() => {
    const cfg = loadConfig();
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
