// caf_local.js — stands in for Google's CAF receiver SDK when the cast
// screen runs outside a Chromecast: the NASRadio TV app on ELKO loads
// /cast/tv.html, which is receiver.html with this file in place of the SDK.
//
// It provides the slice of cast.framework that receiver.js uses, plays
// through the page's own <audio id="castMediaElement">, and speaks the same
// Cast messages (receiver / media / heartbeat / our custom namespace) to the
// NASRadio backend over Socket.IO (namespace /castdev), where
// cast_relay.RelayCastSession drives it exactly like the TV. receiver.js
// itself can't tell the difference.
(function () {
  'use strict';

  const params = new URLSearchParams(location.search);
  const PLAYER = params.get('player') || 'ELKO';
  const KEY = params.get('key') || '';

  const NS_CONNECTION = 'urn:x-cast:com.google.cast.tp.connection';
  const NS_HEARTBEAT = 'urn:x-cast:com.google.cast.tp.heartbeat';
  const NS_RECEIVER = 'urn:x-cast:com.google.cast.receiver';
  const NS_MEDIA = 'urn:x-cast:com.google.cast.media';
  const NS_CUSTOM = 'urn:x-cast:com.nasradio.custom';
  const BACKEND = 'sender-nasradio-backend';
  const TRANSPORT_ID = 'web-1';

  // Kept across reloads (a STOP reloads the page) so the backend doesn't
  // read a reload as somebody else taking the screen over.
  let sessionId = sessionStorage.getItem('nasradio_local_session');
  if (!sessionId) {
    sessionId = 'local-' + Math.random().toString(36).slice(2, 10);
    sessionStorage.setItem('nasradio_local_session', sessionId);
  }

  // Any EventType / MessageType name receiver.js asks for maps to itself;
  // the ones this player actually produces are fired below.
  const anyKey = () => new Proxy({}, { get: (_, k) => String(k) });

  const PlayerState = { IDLE: 'IDLE', PLAYING: 'PLAYING', PAUSED: 'PAUSED', BUFFERING: 'BUFFERING' };

  function emitter() {
    const map = new Map();
    return {
      on(types, fn) {
        (Array.isArray(types) ? types : [types]).forEach((t) => {
          if (!map.has(t)) map.set(t, []);
          map.get(t).push(fn);
        });
      },
      fire(type, ev) {
        (map.get(type) || []).forEach((fn) => {
          try { fn(Object.assign({ type }, ev)); } catch (e) { console.error('[caf_local]', type, e); }
        });
      },
    };
  }

  let socket = null;
  let appId = '';
  let audio = null;
  let media = null;          // MediaInformation of the loaded item
  let mediaSessionId = 0;
  let state = PlayerState.IDLE;
  let idleReason = null;
  let loadSeq = 0;
  let backendConnected = false;
  const interceptors = {};
  const pmEvents = emitter();
  const ctxEvents = emitter();
  const customListeners = {};

  // The NASRadio TV app (preload.js) keeps its window hidden until a cast
  // starts; tell it when to come forward and when to step back.
  function setActive(on) {
    if (window.nasradioTV) window.nasradioTV.setActive(on);
  }

  function send(ns, payload) {
    if (socket && socket.connected) socket.emit('cast_frame', { ns, payload });
  }

  function duration() {
    if (audio && isFinite(audio.duration) && audio.duration > 0) return audio.duration;
    return (media && media.duration) || 0;
  }

  function mediaStatus(requestId) {
    const status = [];
    if (media) {
      const st = {
        mediaSessionId, playbackRate: 1, playerState: state,
        currentTime: audio ? audio.currentTime || 0 : 0,
        supportedMediaCommands: 15, volume: { level: 1, muted: false },
        media: {
          contentId: media.contentId, contentType: media.contentType,
          streamType: media.streamType || 'BUFFERED', metadata: media.metadata || {},
          customData: media.customData || {}, duration: duration(),
        },
      };
      if (state === PlayerState.IDLE && idleReason) st.idleReason = idleReason;
      status.push(st);
    }
    send(NS_MEDIA, { type: 'MEDIA_STATUS', requestId: requestId || 0, status });
    pmEvents.fire('MEDIA_STATUS', { mediaStatus: status[0] || null });
  }

  function setState(s, reason) {
    state = s;
    idleReason = s === PlayerState.IDLE ? (reason || null) : null;
    mediaStatus();
  }

  function receiverStatus(requestId, running) {
    send(NS_RECEIVER, {
      type: 'RECEIVER_STATUS', requestId: requestId || 0,
      status: {
        applications: running === false ? [] : [{
          appId, displayName: 'NASRadio', statusText: 'NASRadio', sessionId,
          transportId: TRANSPORT_ID, namespaces: [{ name: NS_MEDIA }, { name: NS_CUSTOM }],
        }],
        volume: { level: 1, muted: false },
      },
    });
  }

  async function intercept(type, request) {
    const fn = interceptors[type];
    return fn ? await fn(request) : request;
  }

  async function load(request) {
    const req = await intercept('LOAD', request);
    if (!req || !req.media || !req.media.contentId) throw new Error('LOAD rejected');
    const seq = ++loadSeq;
    setActive(true);
    media = req.media;
    mediaSessionId += 1;
    pmEvents.fire('PLAYER_LOADING', { media });
    setState(PlayerState.BUFFERING);
    try {
      await new Promise((resolve, reject) => {
        const ok = () => { done(); resolve(); };
        const bad = () => { done(); reject(new Error('could not load ' + media.contentId)); };
        const done = () => {
          audio.removeEventListener('loadedmetadata', ok);
          audio.removeEventListener('error', bad);
        };
        audio.addEventListener('loadedmetadata', ok);
        audio.addEventListener('error', bad);
        audio.src = media.contentId;
        audio.load();
      });
    } catch (e) {
      if (seq === loadSeq) {
        setState(PlayerState.IDLE, 'ERROR');
        pmEvents.fire('ERROR', { detailedErrorCode: 'LOAD_FAILED', reason: String(e) });
      }
      throw e;
    }
    if (seq !== loadSeq) return;  // a newer LOAD took over meanwhile
    const start = Number(req.currentTime) || 0;
    if (start > 0) audio.currentTime = start;
    pmEvents.fire('PLAYER_LOAD_COMPLETE', { media });
    if (req.autoplay === false) {
      setState(PlayerState.PAUSED);
      return;
    }
    try {
      await audio.play();
    } catch (e) {
      console.error('[caf_local] play() refused:', e);
      setState(PlayerState.PAUSED);
    }
  }

  function stopPlayback() {
    setActive(false);
    loadSeq++;
    audio.pause();
    audio.removeAttribute('src');
    audio.load();
    media = null;
    state = PlayerState.IDLE;
    idleReason = 'CANCELLED';
  }

  async function onMedia(p) {
    const rid = p.requestId;
    try {
      if (p.type === 'LOAD') {
        await load({
          media: p.media, autoplay: p.autoplay !== false, currentTime: p.currentTime || 0,
          customData: p.customData, requestId: rid, senderId: BACKEND,
        });
        mediaStatus(rid);
      } else if (p.type === 'PLAY') {
        if (await intercept('PLAY', p)) await audio.play();
      } else if (p.type === 'PAUSE') {
        if (await intercept('PAUSE', p)) audio.pause();
      } else if (p.type === 'SEEK') {
        const r = await intercept('SEEK', p);
        if (r && typeof r.currentTime === 'number') audio.currentTime = r.currentTime;
      } else if (p.type === 'STOP') {
        if (await intercept('STOP', p)) {
          stopPlayback();
          mediaStatus(rid);
          setTimeout(() => location.reload(), 300);  // back to the idle screen, clean
        }
      } else if (p.type === 'GET_STATUS') {
        mediaStatus(rid);
      }
    } catch (e) {
      console.error('[caf_local] media', p.type, 'failed:', e);
      mediaStatus(rid);
    }
  }

  function onFrame(frame) {
    const ns = frame && frame.ns;
    const p = (frame && frame.payload) || {};
    if (ns === NS_HEARTBEAT) {
      if (p.type === 'PING') send(NS_HEARTBEAT, { type: 'PONG' });
    } else if (ns === NS_CONNECTION) {
      // The backend CONNECTs to receiver-0 first, then to our app's
      // transport; only the second one is a sender joining the app.
      if (p.type === 'CONNECT' && frame.dest === TRANSPORT_ID && !backendConnected) {
        backendConnected = true;
        ctxEvents.fire('SENDER_CONNECTED', { senderId: BACKEND, userAgent: 'nasradio-backend' });
      } else if (p.type === 'CLOSE' && backendConnected) {
        backendConnected = false;
        ctxEvents.fire('SENDER_DISCONNECTED', { senderId: BACKEND, reason: 'REQUESTED_BY_SENDER' });
      }
    } else if (ns === NS_RECEIVER) {
      if (p.type === 'GET_STATUS' || p.type === 'LAUNCH') {
        receiverStatus(p.requestId);
      } else if (p.type === 'STOP') {
        stopPlayback();
        receiverStatus(p.requestId, false);
        ctxEvents.fire('SHUTDOWN', {});
        setTimeout(() => location.reload(), 300);
      }
    } else if (ns === NS_MEDIA) {
      onMedia(p);
    } else if (customListeners[ns]) {
      customListeners[ns].forEach((fn) => {
        try { fn({ type: 'message', senderId: BACKEND, data: p }); } catch (e) { console.error('[caf_local] custom', e); }
      });
    }
  }

  function wireAudio(el) {
    audio = el;
    el.addEventListener('playing', () => { setState(PlayerState.PLAYING); pmEvents.fire('PLAYING', {}); });
    el.addEventListener('pause', () => {
      if (el.ended || !media) return;  // 'ended' follows and says FINISHED
      setState(PlayerState.PAUSED);
      pmEvents.fire('PAUSE', {});
    });
    el.addEventListener('waiting', () => { if (media) setState(PlayerState.BUFFERING); });
    el.addEventListener('seeked', () => { if (media) { mediaStatus(); pmEvents.fire('SEEKED', {}); } });
    el.addEventListener('ended', () => {
      setState(PlayerState.IDLE, 'FINISHED');
      pmEvents.fire('MEDIA_FINISHED', { endedReason: 'END_OF_STREAM' });
    });
  }

  const playerManager = {
    getPlayerState: () => state,
    getCurrentTimeSec: () => (audio ? audio.currentTime || 0 : 0),
    getDurationSec: duration,
    getMediaInformation: () => media,
    setMessageInterceptor: (type, fn) => { interceptors[type] = fn; },
    addEventListener: (types, fn) => pmEvents.on(types, fn),
    play: () => audio && audio.play(),
    pause: () => audio && audio.pause(),
    load: (request) => load(request),
    setMediaElement: (el) => wireAudio(el),
  };

  const context = {
    getPlayerManager: () => playerManager,
    addEventListener: (types, fn) => ctxEvents.on(types, fn),
    addCustomMessageListener: (ns, fn) => { (customListeners[ns] = customListeners[ns] || []).push(fn); },
    sendCustomMessage: (ns, senderId, data) => send(ns, data),
    canDisplayType: (type) => !!(audio && audio.canPlayType(type)),
    getDeviceCapabilities: () => ({ display_supported: true, local_player: PLAYER }),
    start(options) {
      const el = (options && options.playbackConfig && options.playbackConfig.mediaElement)
        || document.getElementById('castMediaElement');
      wireAudio(el);
      document.body.classList.add('local-mode');
      socket = io('/castdev', { auth: { player: PLAYER, key: KEY }, transports: ['websocket'] });
      socket.on('castdev_welcome', (w) => {
        appId = (w && w.appId) || '';
        console.log('[caf_local] connected to NASRadio as', w && w.player);
      });
      socket.on('cast_frame', onFrame);
      socket.on('disconnect', () => {
        if (backendConnected) {
          backendConnected = false;
          ctxEvents.fire('SENDER_DISCONNECTED', { senderId: BACKEND, reason: 'ERROR' });
        }
      });
      socket.on('connect_error', (e) => console.warn('[caf_local] backend connection failed:', e && e.message));
    },
  };

  function LoadRequestData() {
    this.media = null; this.autoplay = true; this.currentTime = 0; this.customData = null;
  }
  function MediaInformation() {
    this.contentId = ''; this.contentType = ''; this.streamType = 'BUFFERED';
    this.metadata = {}; this.customData = {};
  }
  function PlaybackConfig() { this.mediaElement = null; }
  function CastReceiverOptions() { this.customNamespaces = {}; }

  window.cast = {
    framework: {
      CastReceiverContext: { getInstance: () => context },
      CastReceiverOptions,
      PlaybackConfig,
      system: { EventType: anyKey(), MessageType: { JSON: 'JSON', STRING: 'STRING' } },
      events: { EventType: anyKey() },
      messages: {
        PlayerState,
        MessageType: anyKey(),
        StreamType: { BUFFERED: 'BUFFERED', LIVE: 'LIVE', NONE: 'NONE' },
        LoadRequestData,
        MediaInformation,
      },
    },
  };
})();
