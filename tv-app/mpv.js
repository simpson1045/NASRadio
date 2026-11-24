// NASRadio TV: the audio player is mpv, not Chromium (Phase 3, Nov 21, 2026).
// Chromium can't decode Dolby (E-AC-3/AC-3/TrueHD) or DTS, and no browser can
// pass a bitstream through to HDMI, so a Dolby Atmos track sat IDLE on ELKO.
// mpv in WASAPI exclusive mode bitstreams them to the Denon untouched (the
// same audio settings as ELKO's movie mpv.conf), and plays everything else
// (FLAC, multichannel FLAC, stereo) as PCM. The page keeps drawing the screen;
// caf_local.js drives this through preload.js.
//
// mpv runs hidden with --no-config, so the movie config (fullscreen, GPU,
// verbose log) never applies to music, and music never changes movies.
const { spawn } = require('child_process');
const fs = require('fs');
const net = require('net');

const PIPE = '\\\\.\\pipe\\nasradio-tv-mpv';
const DEFAULT_EXE = 'C:\\Program Files\\MPV Player\\mpv.exe';

// Properties the page needs; time-pos is throttled before it's forwarded.
const OBSERVED = ['pause', 'paused-for-cache', 'duration', 'time-pos', 'idle-active'];
const TIME_POS_EVERY_MS = 250;

class MpvController {
  constructor(exe, onEvent, log) {
    this.exe = exe || DEFAULT_EXE;
    this.onEvent = onEvent;   // (event object) -> sent on to the page
    this.log = log || console.log;
    this.proc = null;
    this.sock = null;
    this.buf = '';
    this.nextId = 1;
    this.lastTimePosAt = 0;
    this.stopped = false;
  }

  available() {
    return fs.existsSync(this.exe);
  }

  start() {
    if (!this.available()) {
      this.log(`[mpv] not found at ${this.exe}: the page plays through Chromium instead`);
      return false;
    }
    const args = [
      '--no-config', '--idle=yes', '--no-video', '--force-window=no',
      '--audio-display=no', '--terminal=no', '--keep-open=no',
      `--input-ipc-server=${PIPE}`,
      // ELKO's movie mpv.conf audio, proven with the Denon:
      '--audio-exclusive=yes', '--audio-spdif=ac3,eac3,dts-hd,truehd',
      '--wasapi-exclusive-buffer=100000', '--audio-buffer=1.0',
      // Music, not movies: the source's own channel layout (stereo stays
      // stereo so the Denon's upmixer can work on it), no video sync delay.
      '--audio-channels=auto',
      '--cache=yes', '--demuxer-max-bytes=200MiB', '--network-timeout=30',
      // One file at a time: the backend sends a LOAD per track.
      '--gapless-audio=no',
    ];
    this.proc = spawn(this.exe, args, { windowsHide: true, stdio: 'ignore' });
    this.log(`[mpv] started pid ${this.proc.pid}`);
    this.proc.on('exit', (code) => {
      this.log(`[mpv] exited (${code})`);
      this.proc = null;
      this.sock = null;
      this.onEvent({ event: 'mpv-exit' });
      if (!this.stopped) setTimeout(() => this.start(), 3000);
    });
    this.connect(0);
    return true;
  }

  connect(attempt) {
    const sock = net.connect(PIPE);
    sock.on('connect', () => {
      this.sock = sock;
      this.buf = '';
      OBSERVED.forEach((p, i) => this.send(['observe_property', i + 1, p]));
      this.log('[mpv] IPC connected');
      this.onEvent({ event: 'mpv-ready' });
    });
    sock.on('data', (d) => this.onData(d));
    sock.on('error', () => {
      if (this.sock !== sock && attempt < 50 && this.proc) {
        setTimeout(() => this.connect(attempt + 1), 100);
      }
    });
    sock.on('close', () => { if (this.sock === sock) this.sock = null; });
  }

  onData(chunk) {
    this.buf += chunk.toString('utf8');
    let nl;
    while ((nl = this.buf.indexOf('\n')) >= 0) {
      const line = this.buf.slice(0, nl).trim();
      this.buf = this.buf.slice(nl + 1);
      if (!line) continue;
      let msg;
      try { msg = JSON.parse(line); } catch (e) { continue; }
      if (msg.event === 'property-change' && msg.name === 'time-pos') {
        const now = Date.now();
        if (now - this.lastTimePosAt < TIME_POS_EVERY_MS) continue;
        this.lastTimePosAt = now;
      }
      if (msg.event) this.onEvent(msg);
      else if (msg.error && msg.error !== 'success') this.log(`[mpv] command error: ${msg.error}`);
    }
  }

  send(command) {
    if (!this.sock) return false;
    this.sock.write(JSON.stringify({ command, request_id: this.nextId++ }) + '\n');
    return true;
  }

  stop() {
    this.stopped = true;
    if (this.proc) {
      try { this.send(['quit']); } catch (e) { /* closing anyway */ }
      const p = this.proc;
      setTimeout(() => { try { p.kill(); } catch (e) { /* gone */ } }, 1000);
    }
  }
}

module.exports = { MpvController };
