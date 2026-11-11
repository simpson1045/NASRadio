// Lets the page (caf_local.js) tell the app when a cast starts and ends, so
// the window comes forward over whatever ELKO is showing and steps back out
// of the way afterwards, like a Chromecast taking the TV.
const { contextBridge, ipcRenderer } = require('electron');

contextBridge.exposeInMainWorld('nasradioTV', {
  setActive: (on) => ipcRenderer.send('nasradio-tv-active', !!on),
});
