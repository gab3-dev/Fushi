import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/ai/chatgpt_plan_auth.dart';
import 'package:fushi/src/sync/pkce_oauth.dart';
import 'package:fushi_engine/ai/ai_chat_client.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:pointycastle/export.dart';

class _MemorySecretStore implements ChatGptPlanSecretStore {
  final Map<String, String> values = <String, String>{};

  @override
  Future<void> delete(String key) async {
    values.remove(key);
  }

  @override
  Future<String?> read(String key) async => values[key];

  @override
  Future<void> write(String key, String value) async {
    values[key] = value;
  }
}

AsymmetricKeyPair<PublicKey, PrivateKey> _makeRsaKeyPair() {
  final math.Random entropy = math.Random.secure();
  final SecureRandom random = FortunaRandom()
    ..seed(
      KeyParameter(
        Uint8List.fromList(List<int>.generate(32, (_) => entropy.nextInt(256))),
      ),
    );
  final RSAKeyGenerator generator = RSAKeyGenerator()
    ..init(
      ParametersWithRandom(
        RSAKeyGeneratorParameters(BigInt.from(65537), 1024, 64),
        random,
      ),
    );
  return generator.generateKeyPair();
}

String _signIdToken(
  RSAPrivateKey privateKey, {
  required String nonce,
  required String audience,
  required DateTime now,
}) {
  final String header = _base64Url(
    utf8.encode(
      jsonEncode(<String, Object?>{
        'alg': 'RS256',
        'typ': 'JWT',
        'kid': 'test-key',
      }),
    ),
  );
  final String payload = _base64Url(
    utf8.encode(
      jsonEncode(<String, Object?>{
        'iss': 'https://auth.openai.com',
        'sub': 'chatgpt-subject',
        'aud': audience,
        'nonce': nonce,
        'email': 'plus@example.com',
        'email_verified': true,
        'iat': now.millisecondsSinceEpoch ~/ 1000,
        'nbf': now.millisecondsSinceEpoch ~/ 1000,
        'exp': now.add(const Duration(hours: 1)).millisecondsSinceEpoch ~/ 1000,
      }),
    ),
  );
  final RSASigner signer = RSASigner(SHA256Digest(), '0609608648016503040201')
    ..init(true, PrivateKeyParameter<RSAPrivateKey>(privateKey));
  final RSASignature signature = signer.generateSignature(
    Uint8List.fromList(utf8.encode('$header.$payload')),
  );
  return '$header.$payload.${_base64Url(signature.bytes)}';
}

String _base64Url(List<int> bytes) =>
    base64Url.encode(bytes).replaceAll('=', '');

List<int> _bigIntBytes(BigInt value) {
  final String hex = value
      .toRadixString(16)
      .padLeft(((value.bitLength + 7) ~/ 8) * 2, '0');
  return <int>[
    for (int i = 0; i < hex.length; i += 2)
      int.parse(hex.substring(i, i + 2), radix: 16),
  ];
}

Map<String, Object?> _savedCredential({
  String refreshToken = 'old-refresh',
}) => <String, Object?>{
  'clientId': 'oaiapp_registered-client',
  'hostId': 'urn:uuid:00000000-0000-4000-8000-000000000001',
  'subject': 'chatgpt-subject',
  'accountLabel': 'plus@example.com',
  'email': 'plus@example.com',
  'idToken': 'retained-id-token',
  'accessToken': 'expired-access',
  'refreshToken': refreshToken,
  'accessTokenExpiresAt': 0,
  'scopes':
      'openid profile email offline_access resource.invoke chatgpt.tokens.use.direct',
};

void main() {
  test(
    'Sign in registers a local host, validates OAuth state and signed identity',
    () async {
      final _MemorySecretStore secrets = _MemorySecretStore();
      final DateTime now = DateTime.utc(2026, 11, 11, 12);
      final AsymmetricKeyPair<PublicKey, PrivateKey> pair = _makeRsaKeyPair();
      final RSAPublicKey publicKey = pair.publicKey as RSAPublicKey;
      String? expectedNonce;
      String? issuedClientId;
      final http.Client client = MockClient((http.Request request) async {
        switch (request.url.path) {
          case '/api/accounts/oauth/token':
            final Map<String, String> form = Uri.splitQueryString(request.body);
            issuedClientId = form['client_id'];
            final String verifier = form['code_verifier']!;
            expect(form['grant_type'], 'authorization_code');
            expect(form['code'], 'authorization-code');
            expect(form['redirect_uri'], contains('/auth/callback'));
            expect(PkceOAuthFlow.codeChallenge(verifier), isNotEmpty);
            return http.Response(
              jsonEncode(<String, Object?>{
                'access_token': 'access-token',
                'refresh_token': 'refresh-token',
                'id_token': _signIdToken(
                  pair.privateKey as RSAPrivateKey,
                  nonce: expectedNonce!,
                  audience: issuedClientId!,
                  now: now,
                ),
                'token_type': 'Bearer',
                'expires_in': 3600,
                'scope':
                    'openid profile email offline_access resource.invoke chatgpt.tokens.use.direct',
              }),
              200,
            );
          case '/.well-known/openid-configuration':
            return http.Response(
              jsonEncode(<String, Object?>{
                'issuer': 'https://auth.openai.com',
                'jwks_uri': 'https://auth.openai.com/.well-known/jwks.json',
                'revocation_endpoint': 'https://auth.openai.com/revoke',
              }),
              200,
            );
          case '/.well-known/jwks.json':
            return http.Response(
              jsonEncode(<String, Object?>{
                'keys': <Map<String, Object?>>[
                  <String, Object?>{
                    'kty': 'RSA',
                    'kid': 'test-key',
                    'alg': 'RS256',
                    'use': 'sig',
                    'n': _base64Url(_bigIntBytes(publicKey.modulus!)),
                    'e': _base64Url(_bigIntBytes(publicKey.exponent!)),
                  },
                ],
              }),
              200,
            );
          default:
            fail('Unexpected ChatGPT auth request: ${request.url.path}');
        }
      });
      final ChatGptPlanAuthStore auth = ChatGptPlanAuthStore(
        secretStore: secrets,
        client: client,
        clock: () => now,
        browserLauncher: (Uri authorizationUri) async {
          expect(
            authorizationUri.queryParameters['client_id'],
            'dynamic_agent_client',
          );
          expect(
            authorizationUri.queryParameters['scope'],
            contains('chatgpt.tokens.use.direct'),
          );
          final String hostId =
              authorizationUri.queryParameters['ext_agent_host_id']!;
          expect(hostId, startsWith('urn:uuid:'));
          expectedNonce = authorizationUri.queryParameters['nonce'];
          final Uri redirect = Uri.parse(
            authorizationUri.queryParameters['redirect_uri']!,
          );
          final Uri callback = redirect.replace(
            queryParameters: <String, String>{
              'code': 'authorization-code',
              'state': authorizationUri.queryParameters['state']!,
              'client_id': 'oaiapp_registered-client',
            },
          );
          final http.Response callbackResponse = await http.get(callback);
          expect(callbackResponse.statusCode, 200);
          return true;
        },
      );
      addTearDown(auth.dispose);

      final ChatGptPlanAccount account = await auth.signIn(
        credentialId: 'provider-1',
      );

      expect(account.clientId, 'oaiapp_registered-client');
      expect(account.subject, 'chatgpt-subject');
      expect(account.accountLabel, 'plus@example.com');
      expect(issuedClientId, account.clientId);
      final String? saved =
          secrets.values['fushi.ai.chatgpt_plan.credential.provider-1'];
      expect(saved, isNotNull);
      expect(jsonDecode(saved!)['refreshToken'], 'refresh-token');
      expect(await auth.needsWelcome('provider-1'), isTrue);
      await auth.markWelcomeShown('provider-1');
      expect(await auth.needsWelcome('provider-1'), isFalse);
    },
  );

  test(
    'refresh rotates OAuth tokens in secure storage and returns new access token',
    () async {
      final _MemorySecretStore secrets = _MemorySecretStore()
        ..values['fushi.ai.chatgpt_plan.credential.provider-1'] = jsonEncode(
          _savedCredential(),
        );
      final DateTime now = DateTime.utc(2026, 11, 11);
      final MockClient client = MockClient((http.Request request) async {
        expect(request.method, 'POST');
        expect(
          request.url,
          Uri.parse('https://auth.openai.com/api/accounts/oauth/token'),
        );
        expect(Uri.splitQueryString(request.body), <String, String>{
          'grant_type': 'refresh_token',
          'client_id': 'oaiapp_registered-client',
          'refresh_token': 'old-refresh',
          'resource': 'https://api.openai.com/v1',
        });
        return http.Response(
          jsonEncode(<String, Object?>{
            'access_token': 'fresh-access',
            'refresh_token': 'rotated-refresh',
            'expires_in': 3600,
            'scope': _savedCredential()['scopes'],
          }),
          200,
        );
      });
      final ChatGptPlanAuthStore auth = ChatGptPlanAuthStore(
        secretStore: secrets,
        client: client,
        clock: () => now,
      );
      addTearDown(auth.dispose);

      expect(await auth.accessToken('provider-1'), 'fresh-access');
      final Map<String, Object?> updated =
          jsonDecode(
                secrets.values['fushi.ai.chatgpt_plan.credential.provider-1']!,
              )
              as Map<String, Object?>;
      expect(updated['accessToken'], 'fresh-access');
      expect(updated['refreshToken'], 'rotated-refresh');
      expect(updated['clientId'], 'oaiapp_registered-client');
      expect(
        updated['accessTokenExpiresAt'],
        now.add(const Duration(seconds: 3600)).millisecondsSinceEpoch,
      );
    },
  );

  test(
    'terminal refresh failure keeps registration for reauthorization only',
    () async {
      final _MemorySecretStore secrets = _MemorySecretStore()
        ..values['fushi.ai.chatgpt_plan.credential.provider-1'] = jsonEncode(
          _savedCredential(),
        );
      final ChatGptPlanAuthStore auth = ChatGptPlanAuthStore(
        secretStore: secrets,
        client: MockClient(
          (http.Request _) async => http.Response(
            jsonEncode(<String, String>{'error': 'invalid_grant'}),
            400,
          ),
        ),
      );
      addTearDown(auth.dispose);

      await expectLater(
        auth.accessToken('provider-1'),
        throwsA(
          isA<AiChatFailure>().having(
            (AiChatFailure failure) => failure.message,
            'message',
            'chatgpt_plan_reauth_required',
          ),
        ),
      );
      final ChatGptPlanAccount? account = await auth.account('provider-1');
      expect(account?.clientId, 'oaiapp_registered-client');
      final Map<String, Object?> stored =
          jsonDecode(
                secrets.values['fushi.ai.chatgpt_plan.credential.provider-1']!,
              )
              as Map<String, Object?>;
      expect(stored['refreshToken'], isEmpty);
      expect(stored['accessToken'], isEmpty);
    },
  );
}
