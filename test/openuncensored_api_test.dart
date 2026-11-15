import 'dart:convert';

import 'package:domolia/ai/openuncensored_api.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

http.Response jsonResponse(Object data, [int status = 200]) =>
    http.Response(jsonEncode(data), status,
      headers: {'content-type': 'application/json'});

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const key = 'ou-cus_TEST_KEY_123456';
  const checkout = {
    'payment_url': 'https://checkout.stripe.com/c/pay/test',
    'session_id': 'cs_test_123',
    'claim_token': 'test-claim-secret',
  };

  test('Balance parses all USD fields, including pending usage', () async {
    final api = OpenUncensoredApi(client: MockClient((request) async {
      expect(request.url.path, '/v1/credits');
      expect(request.headers['Authorization'], 'Bearer $key');
      return jsonResponse({
        'object': 'credits',
        'data': {
          'remaining_usd': 4.18, 'balance_usd': 4.2,
          'pending_usage_usd': 0.02, 'currency': 'usd',
        },
      });
    }));
    final balance = await api.balance(key);
    expect(balance.remainingUsd, 4.18);
    expect(balance.pendingUsd, 0.02);
    api.close();
  });

  test('Zero balance and zero pending are supported', () async {
    final parsed = OuBalance.parse({'data': {
      'remaining_usd': 0, 'balance_usd': 0, 'currency': 'usd',
    }});
    expect(parsed.remainingUsd, 0);
    expect(parsed.pendingUsd, 0);
  });

  test('Malformed balances and unexpected currency fail closed', () {
    expect(() => OuBalance.parse({'data': {'currency': 'eur'}}),
      throwsA(isA<OpenUncensoredFailure>()));
  });

  test('Initial checkout uses cents, without passing a key', () async {
    final api = OpenUncensoredApi(client: MockClient((request) async {
      expect(request.method, 'POST');
      expect(request.url.path, '/api/agent/checkout');
      expect(jsonDecode(request.body), {'credits': 1000});
      expect(request.headers.containsKey('Authorization'), false);
      return jsonResponse(checkout);
    }));
    final session = await api.checkout(cents: 1000);
    expect(session.sessionId, 'cs_test_123');
    expect(session.paymentUrl.host, 'checkout.stripe.com');
  });

  test('Topup checkout always sends the exact chosen key', () async {
    final api = OpenUncensoredApi(client: MockClient((request) async {
      expect(jsonDecode(request.body), {'credits': 500, 'key': key});
      return jsonResponse(checkout);
    }));
    await api.checkout(cents: 500, topUpKey: key);
  });

  test('Invalid checkout amounts are rejected without sending HTTP', () async {
    var calls = 0;
    final api = OpenUncensoredApi(client: MockClient((request) async {
      calls++;
      return jsonResponse(checkout);
    }));
    await expectLater(api.checkout(cents: 499), throwsA(isA<OpenUncensoredFailure>()));
    await expectLater(api.checkout(cents: 100001), throwsA(isA<OpenUncensoredFailure>()));
    expect(calls, 0);
  });

  test('Payment status pending, paid and expired', () async {
    for (final raw in [
      {'status': 'pending'},
      {'status': 'paid', 'api_key': key, 'balance_cents': 1000},
      {'status': 'expired'},
    ]) {
      final expected = OuCheckoutStatus.values.firstWhere(
        (status) => status.name == raw['status']);
      expect(OuCheckoutResult.parse(raw).status, expected);
    }
  });

  test('Polling uses bearer claim token rather than API key', () async {
    final api = OpenUncensoredApi(client: MockClient((request) async {
      expect(request.url.path, '/api/agent/checkout/cs_test_123');
      expect(request.headers['Authorization'], 'Bearer claim-test');
      return jsonResponse({'status': 'paid', 'api_key': key});
    }));
    final paid = await api.check('cs_test_123', 'claim-test');
    expect(paid.apiKey, key);
  });

  test('Malformed status and unsafe payment redirect are rejected', () {
    expect(() => OuCheckoutResult.parse({'status': 'refunded'}),
      throwsA(isA<OpenUncensoredFailure>()));
    expect(() => OuCheckout.parse({
      ...checkout, 'payment_url': 'https://evil.example/pay',
    }), throwsA(isA<OpenUncensoredFailure>()));
  });

  test('API errors conceal any token in a remote error body', () async {
    final api = OpenUncensoredApi(client: MockClient((request) async =>
      http.Response('{"api_key":"$key"}', 401)));
    try {
      await api.balance(key);
      fail('401 must throw');
    } on OpenUncensoredFailure catch (error) {
      expect(error.toString(), isNot(contains(key)));
      expect(error.statusCode, 401);
    }
  });

  test('Catalogue is filtered by availability and explicit tools', () async {
    final api = OpenUncensoredApi(client: MockClient((request) async {
      expect(request.url.queryParameters['available'], 'true');
      return jsonResponse({'data': [
        {'id': 'candidate-tool', 'modality': 'text',
          'supports_tools': true, 'available': true,
          'pricing': {'prompt': '0.000001', 'completion': '0.000002'}},
        {'id': 'candidate-unknown', 'modality': 'text', 'available': true},
        {'id': 'offline', 'modality': 'text', 'available': false},
        {'id': 'image', 'modality': 'image'},
      ]});
    }));
    final models = await api.models();
    expect(models.map((item) => item.id),
      ['candidate-tool', 'candidate-unknown']);
    expect(models.first.toolCompatible, true);
    expect(models.last.toolCompatible, false);
  });

  test('Incoherent model catalogue fails', () async {
    final api = OpenUncensoredApi(client: MockClient((request) async =>
      jsonResponse({'models': []})));
    await expectLater(api.models(), throwsA(isA<OpenUncensoredFailure>()));
  });

  test('No request follows untrusted redirects', () async {
    final api = OpenUncensoredApi(client: MockClient((request) async {
      expect(request.followRedirects, false);
      return http.Response('', 302, headers: {'location': 'https://elsewhere.test'});
    }));
    await expectLater(api.balance(key),
      throwsA(isA<OpenUncensoredFailure>()));
  });
}
