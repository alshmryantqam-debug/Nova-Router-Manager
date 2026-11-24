import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:nova_router_manager/core/network/routeros_client.dart';

void main() {
  test('closing during REST connection prevents a late reconnect', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    var requestCount = 0;
    server.listen((request) async {
      requestCount++;
      request.response.headers.contentType = ContentType.json;
      request.response.write('{"name":"unexpected"}');
      await request.response.close();
    });

    final client = RouterOsClient(
      host: '127.0.0.1',
      port: server.port,
      username: 'nova-test',
      password: 'test-password',
      useRestApi: true,
      autoReconnect: false,
    );

    try {
      final connecting = client.connect();
      await client.close();

      await expectLater(connecting, throwsA(isA<StateError>()));
      expect(client.isConnected, isFalse);
      expect(client.isAuthenticated, isFalse);
      expect(requestCount, 0);
    } finally {
      await client.close();
      await server.close(force: true);
    }
  });

  test('REST mutations send RouterOS arguments as a JSON body', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final mutation = Completer<Map<String, String>>();

    server.listen((request) async {
      if (request.uri.path == '/rest/system/identity') {
        request.response.headers.contentType = ContentType.json;
        request.response.write('{"name":"nova-test"}');
        await request.response.close();
        return;
      }

      final body = await utf8.decoder.bind(request).join();
      if (!mutation.isCompleted) {
        mutation.complete(<String, String>{
          'method': request.method,
          'path': request.uri.path,
          'contentType': request.headers.contentType?.mimeType ?? '',
          'authorization': request.headers.value(HttpHeaders.authorizationHeader) ?? '',
          'body': body,
        });
      }
      request.response.headers.contentType = ContentType.json;
      request.response.write('{"ret":"*1"}');
      await request.response.close();
    });

    final client = RouterOsClient(
      host: '127.0.0.1',
      port: server.port,
      username: 'nova-test',
      password: 'test-password',
      useRestApi: true,
      autoReconnect: false,
    );

    try {
      await client.connect();
      final result = await client.command(
        '/ip/address/add',
        args: const <String, String>{
          'address': '10.20.30.1/24',
          'interface': 'ether1',
          'comment': 'NOVA:TEST:rest-payload',
        },
      );
      final received = await mutation.future.timeout(const Duration(seconds: 3));

      expect(result.single['ret'], '*1');
      expect(received['method'], 'POST');
      expect(received['path'], '/rest/ip/address/add');
      expect(received['contentType'], 'application/json');
      expect(received['authorization'], 'Basic ${base64Encode(utf8.encode('nova-test:test-password'))}');
      expect(jsonDecode(received['body']!), <String, String>{
        'address': '10.20.30.1/24',
        'interface': 'ether1',
        'comment': 'NOVA:TEST:rest-payload',
      });
    } finally {
      await client.close();
      await server.close(force: true);
    }
  });

  test('REST monitorStream polls once and emits interface counters', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final monitorRequest = Completer<Map<String, String>>();

    server.listen((request) async {
      request.response.headers.contentType = ContentType.json;
      if (request.uri.path == '/rest/system/identity') {
        request.response.write('{"name":"nova-test"}');
      } else if (request.uri.path == '/rest/interface/monitor-traffic' &&
          request.method == 'POST') {
        final body = await utf8.decoder.bind(request).join();
        if (!monitorRequest.isCompleted) {
          monitorRequest.complete(<String, String>{
            'method': request.method,
            'body': body,
          });
        }
        request.response.write(jsonEncode(<Map<String, String>>[
          <String, String>{
            'name': 'ether1',
            'rx-bits-per-second': '1250000',
            'tx-bits-per-second': '640000',
          },
        ]));
      } else {
        request.response.statusCode = HttpStatus.notFound;
        request.response.write('{}');
      }
      await request.response.close();
    });

    final client = RouterOsClient(
      host: '127.0.0.1',
      port: server.port,
      username: 'nova-test',
      password: 'test-password',
      useRestApi: true,
      autoReconnect: false,
    );

    try {
      await client.connect();
      final row = await client
          .monitorStream(
            '/interface/monitor-traffic',
            args: const <String, String>{'interface': 'ether1'},
            restPollInterval: const Duration(milliseconds: 10),
          )
          .first
          .timeout(const Duration(seconds: 3));
      final received = await monitorRequest.future.timeout(const Duration(seconds: 3));

      expect(row['name'], 'ether1');
      expect(row['rx-bits-per-second'], '1250000');
      expect(row['tx-bits-per-second'], '640000');
      expect(received['method'], 'POST');
      expect(jsonDecode(received['body']!), <String, String>{
        'interface': 'ether1',
        'once': '',
      });
    } finally {
      await client.close();
      await server.close(force: true);
    }
  });

  test('closing REST client releases its persistent HTTP connection', () async {
    final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final requestReceived = Completer<void>();
    final peerClosed = Completer<void>();
    Socket? peer;

    server.listen((socket) {
      peer = socket;
      var responded = false;
      socket.listen(
        (data) async {
          if (responded) return;
          responded = true;
          if (!requestReceived.isCompleted) requestReceived.complete();
          const body = '{"name":"nova-test"}';
          socket.write(
            'HTTP/1.1 200 OK\r\n'
            'Content-Type: application/json\r\n'
            'Content-Length: ${body.length}\r\n'
            'Connection: keep-alive\r\n'
            '\r\n'
            '$body',
          );
          await socket.flush();
        },
        onDone: () {
          if (!peerClosed.isCompleted) peerClosed.complete();
        },
        onError: (Object _) {
          if (!peerClosed.isCompleted) peerClosed.complete();
        },
      );
    });

    final client = RouterOsClient(
      host: '127.0.0.1',
      port: server.port,
      username: 'nova-test',
      password: 'test-password',
      useRestApi: true,
      autoReconnect: false,
    );

    try {
      await client.connect().timeout(const Duration(seconds: 3));
      await requestReceived.future.timeout(const Duration(seconds: 3));
      await client.close();
      await peerClosed.future.timeout(const Duration(seconds: 3));
    } finally {
      await client.close();
      peer?.destroy();
      await server.close();
    }
  });
}
