import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:nova_router_manager/core/network/routeros_client.dart';
import 'package:nova_router_manager/core/network/routeros_verified_client.dart';

void main() {
  test('DHCP make-static is confirmed only after the lease becomes static', () async {
    await _runMakeStaticScenario(applyChange: true);
  });

  test('DHCP make-static is not reported successful when the lease stays dynamic', () async {
    await _runMakeStaticScenario(applyChange: false);
  });
}

Future<void> _runMakeStaticScenario({required bool applyChange}) async {
  var dynamicValue = 'true';
  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  server.listen((request) async {
    final response = request.response;
    response.headers.contentType = ContentType.json;

    if (request.uri.path == '/rest/system/identity') {
      response.write(jsonEncode({'name': 'nova-test'}));
    } else if (request.uri.path == '/rest/ip/dhcp-server/lease/make-static' &&
        request.method == 'POST') {
      await utf8.decoder.bind(request).join();
      if (applyChange) dynamicValue = 'false';
      response.write('{}');
    } else if (request.uri.path == '/rest/ip/dhcp-server/lease' &&
        request.method == 'GET') {
      response.write(jsonEncode([
        {'.id': '*1', 'dynamic': dynamicValue, 'address': '192.0.2.10'},
      ]));
    } else {
      response.statusCode = HttpStatus.notFound;
      response.write('{}');
    }

    await response.close();
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
    final operation = client.verifiedCommand(
      '/ip/dhcp-server/lease/make-static',
      args: const {'numbers': '*1'},
    );

    if (applyChange) {
      await operation;
      expect(dynamicValue, 'false');
    } else {
      await expectLater(operation, throwsA(isA<StateError>()));
      expect(dynamicValue, 'true');
    }
  } finally {
    await client.close();
    await server.close(force: true);
  }
}
