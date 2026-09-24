import 'dart:async';

import '../app_logger.dart';
import 'cast_device.dart';
import 'cast_socket.dart';

enum CastSessionState {
  connecting,
  connected,
  closed,
}

class CastSession {
  static const kNamespaceConnection = 'urn:x-cast:com.google.cast.tp.connection';
  static const kNamespaceHeartbeat = 'urn:x-cast:com.google.cast.tp.heartbeat';
  static const kNamespaceReceiver = 'urn:x-cast:com.google.cast.receiver';
  static const kNamespaceDeviceauth = 'urn:x-cast:com.google.cast.tp.deviceauth';
  static const kNamespaceMedia = 'urn:x-cast:com.google.cast.media';

  final String sessionId;
  CastSocket get socket => _socket;
  CastSessionState get state => _state;

  Stream<CastSessionState> get stateStream => _stateController.stream;
  Stream<Map<String, dynamic>> get messageStream => _messageController.stream;

  final CastSocket _socket;
  CastSessionState _state = CastSessionState.connecting;
  String? _transportId;

  /// Join mode: when set, only adopt a transportId from a RECEIVER_STATUS
  /// application whose appId matches. A GET_STATUS (used to JOIN an
  /// already-running receiver after an app restart) can list other apps —
  /// backdrop, someone else's cast — and blindly connecting to
  /// applications[0] would "connect" us to the wrong thing. LAUNCH flow
  /// leaves this null and keeps the original first-app behavior.
  String? expectedAppId;
  // Track session lifetime so we can log "session closed after Xs" —
  // critical for diagnosing the "cast drops after a few songs" pattern,
  // since we need to know whether the drop happens at a fixed interval
  // (idle timeout) or correlates with specific events (song change,
  // network blip, etc.).
  final DateTime _openedAt = DateTime.now();
  int _heartbeatsSent = 0;
  int _heartbeatsReceived = 0;

  // Read by CastService's drop-incident report. We want session uptime
  // and the tx/rx delta (heartbeats sent but never PONG'd) as part of
  // the single-line dump on every disconnect.
  DateTime get openedAt => _openedAt;
  int get heartbeatsSent => _heartbeatsSent;
  int get heartbeatsReceived => _heartbeatsReceived;
  // Sender-initiated heartbeat. The Cast V2 protocol expects the SENDER
  // to send a PING on the heartbeat namespace every ~5 seconds; without
  // it the receiver eventually disconnects (simpson1045's "casting plays a few
  // songs then stops for no reason" — INTERRUPTED idle status fires
  // somewhere in the 5-10 minute range and the session dies). This file
  // previously only RESPONDED to receiver-initiated PINGs which is
  // backwards from how the protocol is meant to work.
  Timer? _heartbeatTimer;
  static const Duration _heartbeatInterval = Duration(seconds: 5);

  final _stateController = StreamController<CastSessionState>.broadcast();
  final _messageController = StreamController<Map<String, dynamic>>.broadcast();

  CastSession._(this.sessionId, this._socket);

  static Future<CastSession> connect(String sessionId, CastDevice device,
      [Duration? timeout]) async {
    final socket = await CastSocket.connect(
      device.host,
      device.port,
      timeout,
    );

    final session = CastSession._(sessionId, socket);

    session._startListening();

    session.sendMessage(kNamespaceConnection, {
      'type': 'CONNECT',
    });

    session._startHeartbeat();

    return session;
  }

  void _startHeartbeat() {
    _heartbeatTimer?.cancel();
    _heartbeatTimer = Timer.periodic(_heartbeatInterval, (_) {
      if (_messageController.isClosed) return;
      try {
        sendMessage(kNamespaceHeartbeat, {'type': 'PING'});
        _heartbeatsSent++;
        // Log a heartbeat summary every 6 ticks (~30 seconds) so we
        // can correlate "cast drops after N songs" complaints with
        // whether the heartbeat was still flowing. NOT per-tick —
        // that'd spam combined.log with one line every 5 seconds.
        if (_heartbeatsSent % 6 == 0) {
          final uptime = DateTime.now().difference(_openedAt).inSeconds;
          AppLogger.instance.info(
            '💓 [Cast] Heartbeat tx=$_heartbeatsSent rx=$_heartbeatsReceived '
            'uptime=${uptime}s state=$_state',
          );
        }

        // Stale-heartbeat detection. If we've sent N more PINGs than
        // we've received PONGs for, the TCP socket is half-open
        // (typical when the phone's WiFi power-saves with the screen
        // off — packets queue in the kernel TX buffer but nothing
        // flows). The OS-level TCP keepalive can take minutes to
        // notice; by then a song has finished, the receiver fired
        // IDLE-FINISHED which we never saw, and the user perceives
        // "cast stops playing after a few songs."
        //
        // Force-close the socket as soon as we detect the half-open
        // state. The session manager's reconnect logic will pick up
        // the closure and re-establish.
        final delta = _heartbeatsSent - _heartbeatsReceived;
        const staleThreshold = 6; // 30s of unanswered PINGs
        if (delta >= staleThreshold) {
          AppLogger.instance.warning(
            '💔 [Cast] Stale heartbeat: tx=$_heartbeatsSent rx=$_heartbeatsReceived '
            '(delta=$delta, ${delta * 5}s without PONG) — force-closing socket '
            'to trigger auto-reconnect',
          );
          _heartbeatTimer?.cancel();
          _heartbeatTimer = null;
          try {
            _socket.close();
          } catch (_) {}
          // The socket's onDone handler will close _messageController and
          // emit a CastSessionState.closed event; auto-reconnect happens
          // in cast_service.dart's _handleDisconnect.
        }
      } catch (e) {
        // Socket closed or write failed — the listener's onDone will
        // tear down state; nothing to do here besides log + skip.
        AppLogger.instance.warning(
          '💔 [Cast] Heartbeat send failed: $e (tx=$_heartbeatsSent before fail)',
        );
      }
    });
  }

  Future<dynamic> close() async {
    _heartbeatTimer?.cancel();
    _heartbeatTimer = null;
    if (!_messageController.isClosed) {
      sendMessage(kNamespaceConnection, {
        'type': 'CLOSE',
      });
      try {
        await _socket.flush();
      } catch (_) {}
    }

    return _socket.close();
  }

  void _startListening() {
    _socket.stream.listen((message) {
      if (_messageController.isClosed) return;

      print('🔌 [Session] Message: ns=${message.namespace} type=${message.payload['type']}');

      if (message.namespace == kNamespaceHeartbeat) {
        final t = message.payload['type'];
        if (t == 'PING') {
          // Receiver-initiated PING. Respond with PONG. Don't AppLogger
          // this — happens too often. Local print() is fine for
          // debugger-only visibility.
          print('🔌 [Session] Responding to PING with PONG');
          sendMessage(kNamespaceHeartbeat, {
            'type': 'PONG',
          });
        } else if (t == 'PONG') {
          // Receiver's response to OUR sender-initiated PING. Track
          // count so the periodic summary in _startHeartbeat can
          // report tx vs rx.
          _heartbeatsReceived++;
        }
      } else if (message.namespace == kNamespaceConnection &&
          message.payload['type'] == 'CLOSE') {
        final uptime = DateTime.now().difference(_openedAt).inSeconds;
        AppLogger.instance.warning(
          '🔌 [Cast] Received CLOSE from receiver after ${uptime}s '
          '(tx=$_heartbeatsSent, rx=$_heartbeatsReceived)',
        );
        close();
      } else if (message.namespace == kNamespaceReceiver) {
        final msgType = message.payload['type'];
        if (msgType == 'RECEIVER_STATUS') {
          _handleReceiverStatus(message.payload);
        } else if (msgType == 'LAUNCH_ERROR') {
          AppLogger.instance.error(
            '❌ [Cast] LAUNCH_ERROR: ${message.payload['reason']} '
            '— full payload: ${message.payload}',
          );
        } else {
          print('🔌 [Session] Receiver message: $msgType');
        }
        _messageController.add(message.payload);
      } else {
        print('🔌 [Session] Other ns=${message.namespace} payload=${message.payload}');
        _messageController.add(message.payload);
      }
    }, onError: (error) {
      final uptime = DateTime.now().difference(_openedAt).inSeconds;
      AppLogger.instance.error(
        '❌ [Cast] Socket stream error after ${uptime}s: $error '
        '(tx=$_heartbeatsSent, rx=$_heartbeatsReceived)',
      );
      _messageController.addError(error);
    }, onDone: () {
      final uptime = DateTime.now().difference(_openedAt).inSeconds;
      AppLogger.instance.warning(
        '🔌 [Cast] Socket stream onDone after ${uptime}s '
        '(tx=$_heartbeatsSent, rx=$_heartbeatsReceived) — closing session',
      );
      _heartbeatTimer?.cancel();
      _heartbeatTimer = null;
      _messageController.close();

      _state = CastSessionState.closed;
      _stateController.add(_state);
      _stateController.close();
    }, cancelOnError: false);
  }

  void _handleReceiverStatus(Map<String, dynamic> payload) {
    final status = payload['status'];
    final hasApps = status?.containsKey('applications') == true;
    print('🔌 [Session] RECEIVER_STATUS: transportId=$_transportId, hasApps=$hasApps');
    if (hasApps) {
      print('🔌 [Session]   apps: ${status['applications']}');
    } else {
      print('🔌 [Session]   status: $status');
    }
    if (_transportId != null) return;

    if (payload['status']?.containsKey('applications') == true) {
      final apps = payload['status']['applications'] as List;
      Map<String, dynamic>? chosen;
      if (expectedAppId != null) {
        for (final a in apps) {
          if (a is Map && a['appId'] == expectedAppId) {
            chosen = Map<String, dynamic>.from(a);
            break;
          }
        }
        if (chosen == null) {
          // Our app isn't among the running applications — stay
          // unconnected and let the caller's timeout / status check
          // decide (join attempt against a TV running something else).
          print('🔌 [Session] RECEIVER_STATUS has no app $expectedAppId — not connecting');
          return;
        }
      } else {
        chosen = Map<String, dynamic>.from(apps[0] as Map);
      }
      _transportId = chosen['transportId'];
      print('🔌 [Session] Got transportId: $_transportId — sending CONNECT');

      // reconnect with new _transportId
      sendMessage(kNamespaceConnection, {
        'type': 'CONNECT',
      });

      _state = CastSessionState.connected;
      _stateController.add(_state);
      final uptime = DateTime.now().difference(_openedAt).inSeconds;
      AppLogger.instance.info(
        '🟢 [Cast] Session connected (handshake took ${uptime}s, transportId=$_transportId)',
      );
    }
  }

  void sendMessage(String namespace, Map<String, dynamic> payload) {
    _socket.sendMessage(
      namespace,
      sessionId,
      _transportId ?? 'receiver-0',
      payload,
    );
  }

  Future<dynamic> flush() {
    return _socket.flush();
  }
}
