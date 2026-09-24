import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'cast_channel.pb.dart';

class CastSocketMessage {
  final String namespace;
  final Map<String, dynamic> payload;

  const CastSocketMessage(this.namespace, this.payload);
}

class CastSocket {
  Stream<CastSocketMessage> get stream => _controller.stream;

  final SecureSocket _socket;
  int _requestId = 0;
  final _controller = StreamController<CastSocketMessage>.broadcast();

  CastSocket._(this._socket);

  static Future<CastSocket> connect(String host, int port, [Duration? timeout]) async {
    timeout ??= const Duration(seconds: 10);

    final socket = await SecureSocket.connect(
      host,
      port,
      onBadCertificate: (X509Certificate certificate) => true, // chromecast uses self-signed certificate
      timeout: timeout,
    );

    final castSocket = CastSocket._(socket);
    castSocket._startListening();

    return castSocket;
  }

  // Buffer for accumulating incoming TCP data (messages may be fragmented)
  final _buffer = <int>[];

  void _startListening() {
    _socket.listen((event) {
      if (_controller.isClosed) return;

      _buffer.addAll(event);
      print('🔧 [CastSocket] Received ${event.length} bytes (buffer: ${_buffer.length})');

      // Process all complete messages in the buffer
      while (_buffer.length >= 4) {
        // Read 4-byte big-endian length prefix
        final length = (_buffer[0] << 24) | (_buffer[1] << 16) | (_buffer[2] << 8) | _buffer[3];

        if (_buffer.length < 4 + length) {
          print('🔧 [CastSocket] Waiting for more data (have ${_buffer.length - 4}/$length)');
          break; // Wait for more data
        }

        try {
          final messageBytes = _buffer.sublist(4, 4 + length);
          _buffer.removeRange(0, 4 + length);

          CastMessage message = CastMessage.fromBuffer(messageBytes);
          Map<String, dynamic> payload = jsonDecode(message.payloadUtf8);
          print('🔧 [CastSocket] ← ${message.namespace} from=${message.sourceId} to=${message.destinationId} type=${payload['type']}');
          _controller.add(CastSocketMessage(message.namespace, payload));
        } catch (e) {
          print('❌ [CastSocket] Parse error: $e');
          _buffer.clear();
          break;
        }
      }
    }, onError: (error) {
      print('❌ [CastSocket] Socket error: $error');
      _controller.addError(error);
    }, onDone: () {
      print('🔧 [CastSocket] Socket closed');
      _controller.close();
    }, cancelOnError: false);
  }

  Future<dynamic> close() {
    return _socket.close();
  }

  void sendMessage(String namespace, String sourceId, String destinationId,
      Map<String, dynamic> payload) {
    if (payload['requestId'] == null) {
      payload['requestId'] = _requestId;
      _requestId += 1;
    }

    CastMessage castMessage = CastMessage();
    castMessage.protocolVersion = CastMessage_ProtocolVersion.CASTV2_1_0;
    castMessage.sourceId = sourceId;
    castMessage.destinationId = destinationId;
    castMessage.namespace = namespace;
    castMessage.payloadType = CastMessage_PayloadType.STRING;
    castMessage.payloadUtf8 = jsonEncode(payload);

    Uint8List bytes = castMessage.writeToBuffer();
    Uint32List headers = Uint32List.fromList(
        _writeUInt32BE(List<int>.filled(4, 0), bytes.lengthInBytes));
    Uint32List data =
        Uint32List.fromList(headers.toList()..addAll(bytes.toList()));

    _socket.add(data);
  }

  Future<dynamic> flush() {
    return _socket.flush();
  }

  static final Function _writeUInt32BE = (target, value) {
    target[0] = ((value & 0xffffffff) >> 24);
    target[1] = ((value & 0xffffffff) >> 16);
    target[2] = ((value & 0xffffffff) >> 8);
    target[3] = ((value & 0xffffffff) & 0xff);
    return target;
  };
}
