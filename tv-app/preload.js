// Lets the page (caf_local.js) tell the app when a cast starts and ends, so
// the window comes forward over whatever ELKO is showing and steps back out
// of the way afterwards, like a Chromecast taking the TV.
//
// Also the page's line to mpv, the audio player (mpv.js): commands go to
// mpv, mpv's events come back. `mpv` is null when mpv isn't installed; the
// page then plays through Chromium as before.
const { contextBridge, ipcRenderer } = require('electron');

const mpvAvailable = ipcRenderer.sendSync('nasradio-mpv-available');

contextBridge.exposeInMainWorld('nasradioTV', {
  setActive: (on) => ipcRenderer.send('nasradio-tv-active', !!on),
  mpv: mpvAvailable
    ? {
        command: (args) => ipcRenderer.send('nasradio-mpv-command', args),
        onEvent: (cb) => ipcRenderer.on('nasradio-mpv-event', (_e, ev) => cb(ev)),
      }
    : null,
});
