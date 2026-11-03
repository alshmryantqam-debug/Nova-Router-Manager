import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:nova_router_manager/core/network/routeros_client.dart';

void main() {
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
}
