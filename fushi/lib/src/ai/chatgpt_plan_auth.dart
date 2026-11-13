import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:http/http.dart' as http;
import 'package:pointycastle/export.dart';
import 'package:url_launcher/url_launcher.dart';

import 'package:fushi/src/sync/pkce_oauth.dart';
import 'package:fushi_engine/ai/ai_chat_client.dart'
    show AiChatFailure, installAiChatPlanAccessTokenResolver;
import 'package:fushi_engine/utils/net/app_http.dart';

const String _issuer = 'https://auth.openai.com';
const String _resource = 'https://api.openai.com/v1';
const String _authorizeEndpoint = '$_issuer/api/accounts/authorize';
const String _tokenEndpoint = '$_issuer/api/accounts/oauth/token';
const String _discoveryEndpoint = '$_issuer/.well-known/openid-configuration';
const String _hostIdKey = 'fushi.ai.chatgpt_plan.host_id.v1';
const String _credentialKeyPrefix = 'fushi.ai.chatgpt_plan.credential.';
const String _requiredPlanScope = 'chatgpt.tokens.use.direct';
const String _identityScopes = 'openid profile email';
const String _planScopes = 'offline_access resource.invoke $_requiredPlanScope';

abstract interface class ChatGptPlanSecretStore {
  Future<String?> read(String key);
  Future<void> write(String key, String value);
  Future<void> delete(String key);
}

final class FlutterChatGptPlanSecretStore implements ChatGptPlanSecretStore {
  const FlutterChatGptPlanSecretStore();

  static const FlutterSecureStorage _storage = FlutterSecureStorage(
    aOptions: AndroidOptions(resetOnError: false),
    iOptions: IOSOptions(
      accessibility: KeychainAccessibility.first_unlock_this_device,
    ),
    mOptions: MacOsOptions(
      usesDataProtectionKeychain: false,
      accessibility: KeychainAccessibility.first_unlock_this_device,
    ),
  );

  @override
  Future<String?> read(String key) => _storage.read(key: key);

  @override
  Future<void> write(String key, String value) =>
      _storage.write(key: key, value: value);

  @override
  Future<void> delete(String key) => _storage.delete(key: key);
}

typedef ChatGptPlanBrowserLauncher =
    Future<bool> Function(Uri authorizationUri);

class ChatGptPlanAccount {
  const ChatGptPlanAccount({
    required this.clientId,
    required this.subject,
    required this.accountLabel,
  });

  final String clientId;
  final String subject;
  final String accountLabel;
}

/// OAuth session for the official open-source / locally hosted ChatGPT-plan
/// integration. OAuth credentials are kept in the platform secure store; the
/// AI-provider preferences store only a reference to this record.
class ChatGptPlanAuthStore {
  ChatGptPlanAuthStore({
    ChatGptPlanSecretStore? secretStore,
    http.Client? client,
    ChatGptPlanBrowserLauncher? browserLauncher,
    Random? random,
    DateTime Function()? clock,
  }) : _secretStore = secretStore ?? const FlutterChatGptPlanSecretStore(),
       _client = client ?? createAppHttpIoClient(),
       _ownsClient = client == null,
       _browserLauncher = browserLauncher ?? _launchBrowser,
       _random = random ?? Random.secure(),
       _clock = clock ?? DateTime.now;

  static final ChatGptPlanAuthStore instance = ChatGptPlanAuthStore();

  final ChatGptPlanSecretStore _secretStore;
  final http.Client _client;
  final bool _ownsClient;
  final ChatGptPlanBrowserLauncher _browserLauncher;
  final Random _random;
  final DateTime Function() _clock;
  final Map<String, Future<String>> _refreshing = <String, Future<String>>{};
  Map<String, Object?>? _discovery;
  List<Map<String, Object?>>? _jwks;

  static Future<bool> _launchBrowser(Uri uri) =>
      launchUrl(uri, mode: LaunchMode.externalApplication);

  void dispose() {
    if (_ownsClient) _client.close();
  }

  /// Installs the process-wide resolver used by app-created [AiChatClient]s.
  void install() => installAiChatPlanAccessTokenResolver(accessToken);

  Future<ChatGptPlanAccount> signIn({
    required String credentialId,
    String agentName = 'Fushi',
  }) async {
    final _ChatGptPlanCredential? previous = await _readCredential(
      credentialId,
    );
    final String hostId = await _hostId();
    final HttpServer server;
    try {
      server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    } on Object {
      throw const AiChatFailure('chatgpt_plan_callback_unavailable');
    }
    final String redirectUri = 'http://127.0.0.1:${server.port}/auth/callback';
    final String state = _randomToken();
    final String nonce = _randomToken();
    final String verifier = PkceOAuthFlow.generateCodeVerifier();
    final bool needsConsent =
        previous != null &&
        !previous.scopes.split(RegExp(r'\s+')).contains(_requiredPlanScope);
    final Uri authorizationUri = Uri.parse(_authorizeEndpoint).replace(
      queryParameters: <String, String>{
        'client_id': previous?.clientId ?? 'dynamic_agent_client',
        if (previous == null) 'agent_name_hint': agentName,
        'ext_agent_host_id': hostId,
        if (previous?.idToken case final String hint) 'id_token_hint': hint,
        if (previous?.email case final String email) 'login_hint': email,
        'response_type': 'code',
        'redirect_uri': redirectUri,
        'scope': '$_identityScopes $_planScopes',
        if (needsConsent) 'prompt': 'consent',
        'resource': _resource,
        'state': state,
        'nonce': nonce,
        'code_challenge_method': 'S256',
        'code_challenge': PkceOAuthFlow.codeChallenge(verifier),
      },
    );

    final Completer<({String code, String? clientId})> callback =
        Completer<({String code, String? clientId})>();
    final StreamSubscription<HttpRequest> subscription = server.listen((
      HttpRequest request,
    ) async {
      if (request.uri.path != '/auth/callback' || callback.isCompleted) {
        request.response
          ..statusCode = HttpStatus.notFound
          ..write('Not found');
        await request.response.close();
        return;
      }
      final Map<String, String> query = request.uri.queryParameters;
      request.response
        ..statusCode = HttpStatus.ok
        ..headers.contentType = ContentType.html
        ..write(_callbackPage(success: query.containsKey('code')));
      await request.response.close();
      if (query['state'] != state) {
        callback.completeError(
          const AiChatFailure('chatgpt_plan_state_invalid'),
        );
      } else if (query['error'] != null) {
        callback.completeError(
          const AiChatFailure('chatgpt_plan_authorization_declined'),
        );
      } else if (query['code'] case final String code when code.isNotEmpty) {
        callback.complete((code: code, clientId: query['client_id']));
      } else {
        callback.completeError(
          const AiChatFailure('chatgpt_plan_callback_invalid'),
        );
      }
    });
    try {
      if (!await _browserLauncher(authorizationUri)) {
        throw const AiChatFailure('chatgpt_plan_browser_unavailable');
      }
      final ({String code, String? clientId}) result = await callback.future
          .timeout(const Duration(minutes: 5));
      final String clientId = previous?.clientId ?? result.clientId ?? '';
      if (clientId.isEmpty ||
          (previous != null &&
              result.clientId != null &&
              result.clientId != previous.clientId)) {
        throw const AiChatFailure('chatgpt_plan_client_invalid');
      }
      final Map<String, Object?> tokens = await _exchangeCode(
        clientId: clientId,
        code: result.code,
        verifier: verifier,
        redirectUri: redirectUri,
      );
      final String grantedScope = (tokens['scope'] as String? ?? '').trim();
      final String idToken = tokens['id_token'] as String? ?? '';
      final Map<String, Object?> claims = await _verifyIdToken(
        idToken,
        clientId: clientId,
        nonce: nonce,
      );
      final String subject = claims['sub'] as String? ?? '';
      if (subject.isEmpty ||
          (previous != null && previous.subject != subject)) {
        throw const AiChatFailure('chatgpt_plan_account_mismatch');
      }
      final String accessToken = tokens['access_token'] as String? ?? '';
      final String refreshToken = tokens['refresh_token'] as String? ?? '';
      final int expiresIn = (tokens['expires_in'] as num?)?.toInt() ?? 0;
      if (!grantedScope.split(RegExp(r'\s+')).contains(_requiredPlanScope)) {
        // Keep the issued registration and validated identity so the next
        // explicit attempt can ask for consent again with the same client ID.
        await _writeCredential(
          credentialId,
          _ChatGptPlanCredential(
            clientId: clientId,
            hostId: hostId,
            subject: subject,
            accountLabel:
                (claims['email'] as String?) ??
                (claims['name'] as String?) ??
                'ChatGPT',
            email: claims['email'] as String?,
            name: claims['name'] as String?,
            idToken: idToken,
            accessToken: accessToken,
            refreshToken: refreshToken,
            accessTokenExpiresAt: 0,
            scopes: grantedScope,
          ),
        );
        throw const AiChatFailure('chatgpt_plan_scope_missing');
      }
      if (accessToken.isEmpty || refreshToken.isEmpty || expiresIn <= 0) {
        throw const AiChatFailure('chatgpt_plan_token_invalid');
      }
      final _ChatGptPlanCredential stored = _ChatGptPlanCredential(
        clientId: clientId,
        hostId: hostId,
        subject: subject,
        accountLabel:
            (claims['email'] as String?) ??
            (claims['name'] as String?) ??
            'ChatGPT',
        email: claims['email'] as String?,
        name: claims['name'] as String?,
        idToken: idToken,
        accessToken: accessToken,
        refreshToken: refreshToken,
        accessTokenExpiresAt: _clock()
            .add(Duration(seconds: expiresIn))
            .millisecondsSinceEpoch,
        scopes: grantedScope,
      );
      await _writeCredential(credentialId, stored);
      return stored.toAccount();
    } on TimeoutException {
      throw const AiChatFailure('chatgpt_plan_callback_timeout');
    } finally {
      await subscription.cancel();
      await server.close(force: true);
    }
  }

  Future<String> accessToken(String credentialId) async {
    final _ChatGptPlanCredential? credential = await _readCredential(
      credentialId,
    );
    if (credential == null ||
        !credential.scopes.split(RegExp(r'\s+')).contains(_requiredPlanScope)) {
      throw const AiChatFailure('chatgpt_plan_auth_required');
    }
    if (credential.refreshToken.isEmpty) {
      throw const AiChatFailure('chatgpt_plan_reauth_required');
    }
    if (credential.accessTokenExpiresAt >
        _clock().add(const Duration(seconds: 60)).millisecondsSinceEpoch) {
      return credential.accessToken;
    }
    final Future<String>? current = _refreshing[credentialId];
    if (current != null) return current;
    final Future<String> refresh = _refresh(credentialId, credential);
    _refreshing[credentialId] = refresh;
    try {
      return await refresh;
    } finally {
      if (identical(_refreshing[credentialId], refresh)) {
        _refreshing.remove(credentialId);
      }
    }
  }

  Future<ChatGptPlanAccount?> account(String credentialId) async =>
      (await _readCredential(credentialId))?.toAccount();

  Future<bool> needsWelcome(String credentialId) async =>
      await _secretStore.read('$_credentialKeyPrefix$credentialId.welcome') !=
      'shown';

  Future<void> markWelcomeShown(String credentialId) =>
      _secretStore.write('$_credentialKeyPrefix$credentialId.welcome', 'shown');

  Future<bool> signOut(String credentialId) async {
    // A concurrent refresh rotates the refresh token. Wait for it before
    // revoking and deleting, so that it cannot write a fresh credential back
    // after sign-out completes.
    final Future<String>? pendingRefresh = _refreshing[credentialId];
    if (pendingRefresh != null) {
      try {
        await pendingRefresh;
      } on Object {
        // Even an expired/rejected refresh must still be cleared locally.
      }
    }
    final _ChatGptPlanCredential? credential = await _readCredential(
      credentialId,
    );
    if (credential == null) return true;
    bool revoked = false;
    try {
      final Map<String, Object?> metadata = await _loadDiscovery();
      if (metadata['issuer'] != _issuer) {
        throw const AiChatFailure('chatgpt_plan_discovery_failed');
      }
      final String endpoint = metadata['revocation_endpoint'] as String? ?? '';
      if (endpoint.isNotEmpty) {
        final Uri revokeUri = Uri.parse(endpoint);
        if (revokeUri.scheme != 'https' ||
            revokeUri.host != 'auth.openai.com') {
          throw const AiChatFailure('chatgpt_plan_discovery_failed');
        }
        final http.Response response = await _client
            .post(
              revokeUri,
              headers: <String, String>{
                'content-type': 'application/x-www-form-urlencoded',
              },
              body: <String, String>{
                'token': credential.refreshToken,
                'token_type_hint': 'refresh_token',
                'client_id': credential.clientId,
              },
            )
            .timeout(const Duration(seconds: 20));
        revoked = response.statusCode == HttpStatus.ok;
      }
    } on Object {
      revoked = false;
    } finally {
      await _secretStore.delete(_credentialStorageKey(credentialId));
    }
    return revoked;
  }

  Future<String> _refresh(
    String credentialId,
    _ChatGptPlanCredential old,
  ) async {
    try {
      final http.Response response = await _client
          .post(
            Uri.parse(_tokenEndpoint),
            headers: <String, String>{
              'content-type': 'application/x-www-form-urlencoded',
            },
            body: <String, String>{
              'grant_type': 'refresh_token',
              'client_id': old.clientId,
              'refresh_token': old.refreshToken,
              'resource': _resource,
            },
          )
          .timeout(const Duration(seconds: 20));
      if (response.statusCode != HttpStatus.ok) {
        final String code = _oauthErrorCode(response.bodyBytes);
        if (code == 'invalid_grant' || code == 'invalid_refresh_token') {
          await _writeCredential(
            credentialId,
            old.copyWith(
              accessToken: '',
              refreshToken: '',
              accessTokenExpiresAt: 0,
            ),
          );
          throw const AiChatFailure('chatgpt_plan_reauth_required');
        }
        throw const AiChatFailure('chatgpt_plan_refresh_failed');
      }
      final Object? decoded = jsonDecode(response.body);
      if (decoded is! Map) {
        throw const AiChatFailure('chatgpt_plan_refresh_failed');
      }
      final String access = decoded['access_token'] as String? ?? '';
      final String replacementRefresh =
          decoded['refresh_token'] as String? ?? old.refreshToken;
      final int expiresIn = (decoded['expires_in'] as num?)?.toInt() ?? 0;
      if (access.isEmpty || expiresIn <= 0) {
        throw const AiChatFailure('chatgpt_plan_refresh_failed');
      }
      final _ChatGptPlanCredential updated = old.copyWith(
        accessToken: access,
        refreshToken: replacementRefresh,
        accessTokenExpiresAt: _clock()
            .add(Duration(seconds: expiresIn))
            .millisecondsSinceEpoch,
        scopes: decoded['scope'] as String? ?? old.scopes,
      );
      await _writeCredential(credentialId, updated);
      return access;
    } on AiChatFailure {
      rethrow;
    } on Object {
      throw const AiChatFailure('chatgpt_plan_refresh_failed');
    }
  }

  Future<Map<String, Object?>> _exchangeCode({
    required String clientId,
    required String code,
    required String verifier,
    required String redirectUri,
  }) async {
    try {
      final http.Response response = await _client
          .post(
            Uri.parse(_tokenEndpoint),
            headers: <String, String>{
              'content-type': 'application/x-www-form-urlencoded',
            },
            body: <String, String>{
              'grant_type': 'authorization_code',
              'client_id': clientId,
              'code': code,
              'code_verifier': verifier,
              'redirect_uri': redirectUri,
              'resource': _resource,
            },
          )
          .timeout(const Duration(seconds: 20));
      if (response.statusCode != HttpStatus.ok) {
        throw const AiChatFailure('chatgpt_plan_token_exchange_failed');
      }
      final Object? decoded = jsonDecode(response.body);
      if (decoded is! Map) {
        throw const AiChatFailure('chatgpt_plan_token_exchange_failed');
      }
      return decoded.cast<String, Object?>();
    } on AiChatFailure {
      rethrow;
    } on Object {
      throw const AiChatFailure('chatgpt_plan_token_exchange_failed');
    }
  }

  Future<Map<String, Object?>> _verifyIdToken(
    String token, {
    required String clientId,
    required String nonce,
  }) async {
    final List<String> parts = token.split('.');
    if (parts.length != 3) {
      throw const AiChatFailure('chatgpt_plan_id_token_invalid');
    }
    final Map<String, Object?> header = _decodeJwtPart(parts[0]);
    final Map<String, Object?> claims = _decodeJwtPart(parts[1]);
    final int expiresAt = (claims['exp'] as num?)?.toInt() ?? 0;
    final int notBefore = (claims['nbf'] as num?)?.toInt() ?? 0;
    final int issuedAt = (claims['iat'] as num?)?.toInt() ?? 0;
    final int now = _clock().millisecondsSinceEpoch ~/ 1000;
    if (header['alg'] != 'RS256' ||
        claims['iss'] != _issuer ||
        claims['nonce'] != nonce ||
        expiresAt <= now ||
        notBefore > now + 30 ||
        issuedAt == 0 ||
        issuedAt > now + 30 ||
        claims['sub'] is! String) {
      throw const AiChatFailure('chatgpt_plan_id_token_invalid');
    }
    final Object? audience = claims['aud'];
    final bool audienceMatches =
        audience == clientId ||
        (audience is List && audience.contains(clientId));
    if (!audienceMatches ||
        (audience is List &&
            audience.length > 1 &&
            claims['azp'] != clientId)) {
      throw const AiChatFailure('chatgpt_plan_id_token_invalid');
    }
    final String? kid = header['kid'] as String?;
    if (kid == null ||
        kid.isEmpty ||
        !await _verifyRsa(parts[0], parts[1], parts[2], kid)) {
      throw const AiChatFailure('chatgpt_plan_id_token_invalid');
    }
    return claims;
  }

  Future<bool> _verifyRsa(
    String encodedHeader,
    String encodedPayload,
    String encodedSignature,
    String kid,
  ) async {
    List<Map<String, Object?>> keys = await _loadJwks();
    Map<String, Object?>? jwk = keys
        .where(
          (Map<String, Object?> key) =>
              key['kid'] == kid && key['kty'] == 'RSA',
        )
        .firstOrNull;
    if (jwk == null) {
      _jwks = null;
      keys = await _loadJwks();
      jwk = keys
          .where(
            (Map<String, Object?> key) =>
                key['kid'] == kid && key['kty'] == 'RSA',
          )
          .firstOrNull;
    }
    if (jwk == null ||
        jwk['n'] is! String ||
        jwk['e'] is! String ||
        (jwk['use'] != null && jwk['use'] != 'sig') ||
        (jwk['alg'] != null && jwk['alg'] != 'RS256')) {
      return false;
    }
    try {
      final RSAPublicKey publicKey = RSAPublicKey(
        _bigIntFromBytes(_base64UrlDecode(jwk['n'] as String)),
        _bigIntFromBytes(_base64UrlDecode(jwk['e'] as String)),
      );
      final RSASigner verifier = RSASigner(
        SHA256Digest(),
        '0609608648016503040201',
      )..init(false, PublicKeyParameter<RSAPublicKey>(publicKey));
      final Uint8List signingInput = Uint8List.fromList(
        utf8.encode('$encodedHeader.$encodedPayload'),
      );
      return verifier.verifySignature(
        signingInput,
        RSASignature(Uint8List.fromList(_base64UrlDecode(encodedSignature))),
      );
    } on Object {
      return false;
    }
  }

  Future<List<Map<String, Object?>>> _loadJwks() async {
    final List<Map<String, Object?>>? cached = _jwks;
    if (cached != null) return cached;
    final Map<String, Object?> discovery = await _loadDiscovery();
    if (discovery['issuer'] != _issuer) {
      throw const AiChatFailure('chatgpt_plan_discovery_failed');
    }
    final String jwksUri = discovery['jwks_uri'] as String? ?? '';
    if (jwksUri.isEmpty) {
      throw const AiChatFailure('chatgpt_plan_discovery_failed');
    }
    final Uri jwksEndpoint = Uri.parse(jwksUri);
    if (jwksEndpoint.scheme != 'https' ||
        jwksEndpoint.host != 'auth.openai.com') {
      throw const AiChatFailure('chatgpt_plan_discovery_failed');
    }
    final http.Response response;
    try {
      response = await _client
          .get(jwksEndpoint)
          .timeout(const Duration(seconds: 20));
    } on Object {
      throw const AiChatFailure('chatgpt_plan_discovery_failed');
    }
    final Object? decoded = _decodeJson(response);
    if (response.statusCode != HttpStatus.ok || decoded is! Map) {
      throw const AiChatFailure('chatgpt_plan_discovery_failed');
    }
    final Object? rawKeys = decoded['keys'];
    if (rawKeys is! List) {
      throw const AiChatFailure('chatgpt_plan_discovery_failed');
    }
    return _jwks = <Map<String, Object?>>[
      for (final Object? key in rawKeys)
        if (key is Map) key.cast<String, Object?>(),
    ];
  }

  Future<Map<String, Object?>> _loadDiscovery() async {
    final Map<String, Object?>? cached = _discovery;
    if (cached != null) return cached;
    final http.Response response;
    try {
      response = await _client
          .get(Uri.parse(_discoveryEndpoint))
          .timeout(const Duration(seconds: 20));
    } on Object {
      throw const AiChatFailure('chatgpt_plan_discovery_failed');
    }
    final Object? decoded = _decodeJson(response);
    if (response.statusCode != HttpStatus.ok || decoded is! Map) {
      throw const AiChatFailure('chatgpt_plan_discovery_failed');
    }
    return _discovery = decoded.cast<String, Object?>();
  }

  Future<String> _hostId() async {
    final String? saved = await _secretStore.read(_hostIdKey);
    if (saved != null && saved.startsWith('urn:uuid:')) return saved;
    final List<int> bytes = List<int>.generate(16, (_) => _random.nextInt(256));
    bytes[6] = (bytes[6] & 0x0f) | 0x40;
    bytes[8] = (bytes[8] & 0x3f) | 0x80;
    final String hex = bytes
        .map((int b) => b.toRadixString(16).padLeft(2, '0'))
        .join();
    final String uuid = <String>[
      hex.substring(0, 8),
      hex.substring(8, 12),
      hex.substring(12, 16),
      hex.substring(16, 20),
      hex.substring(20),
    ].join('-');
    final String hostId = 'urn:uuid:$uuid';
    await _secretStore.write(_hostIdKey, hostId);
    return hostId;
  }

  String _randomToken() => base64Url
      .encode(List<int>.generate(32, (_) => _random.nextInt(256)))
      .replaceAll('=', '');

  Future<_ChatGptPlanCredential?> _readCredential(String id) async {
    final String? raw = await _secretStore.read(_credentialStorageKey(id));
    if (raw == null) return null;
    try {
      final Object? decoded = jsonDecode(raw);
      return decoded is Map
          ? _ChatGptPlanCredential.fromJson(decoded.cast<String, Object?>())
          : null;
    } on Object {
      throw const AiChatFailure('chatgpt_plan_auth_storage_error');
    }
  }

  Future<void> _writeCredential(String id, _ChatGptPlanCredential credential) =>
      _secretStore.write(
        _credentialStorageKey(id),
        jsonEncode(credential.toJson()),
      );

  String _credentialStorageKey(String id) => '$_credentialKeyPrefix$id';

  Map<String, Object?> _decodeJwtPart(String encoded) {
    try {
      final Object? decoded = jsonDecode(
        utf8.decode(_base64UrlDecode(encoded)),
      );
      if (decoded is Map) return decoded.cast<String, Object?>();
    } on Object {
      // Return a shape that fails the typed claim checks below.
    }
    throw const AiChatFailure('chatgpt_plan_id_token_invalid');
  }

  static List<int> _base64UrlDecode(String value) =>
      base64Url.decode(base64Url.normalize(value));

  static BigInt _bigIntFromBytes(List<int> bytes) {
    final String hex = bytes
        .map((int value) => value.toRadixString(16).padLeft(2, '0'))
        .join();
    return BigInt.parse(hex, radix: 16);
  }

  static Object? _decodeJson(http.Response response) {
    try {
      return jsonDecode(response.body);
    } on FormatException {
      return null;
    }
  }

  static String _oauthErrorCode(List<int> body) {
    try {
      final Object? decoded = jsonDecode(utf8.decode(body));
      return decoded is Map ? decoded['error'] as String? ?? '' : '';
    } on Object {
      return '';
    }
  }

  static String _callbackPage({required bool success}) {
    final String text = success
        ? 'Authorization complete. Return to Fushi.'
        : 'Authorization was not completed. Return to Fushi and try again.';
    return '<!doctype html><meta charset="utf-8"><title>Fushi</title>'
        '<p style="font-family:sans-serif;text-align:center;margin-top:4em">$text</p>';
  }
}

class _ChatGptPlanCredential {
  const _ChatGptPlanCredential({
    required this.clientId,
    required this.hostId,
    required this.subject,
    required this.accountLabel,
    required this.email,
    required this.name,
    required this.idToken,
    required this.accessToken,
    required this.refreshToken,
    required this.accessTokenExpiresAt,
    required this.scopes,
  });

  final String clientId;
  final String hostId;
  final String subject;
  final String accountLabel;
  final String? email;
  final String? name;
  final String idToken;
  final String accessToken;
  final String refreshToken;
  final int accessTokenExpiresAt;
  final String scopes;

  ChatGptPlanAccount toAccount() => ChatGptPlanAccount(
    clientId: clientId,
    subject: subject,
    accountLabel: accountLabel,
  );

  _ChatGptPlanCredential copyWith({
    String? accessToken,
    String? refreshToken,
    int? accessTokenExpiresAt,
    String? scopes,
  }) => _ChatGptPlanCredential(
    clientId: clientId,
    hostId: hostId,
    subject: subject,
    accountLabel: accountLabel,
    email: email,
    name: name,
    idToken: idToken,
    accessToken: accessToken ?? this.accessToken,
    refreshToken: refreshToken ?? this.refreshToken,
    accessTokenExpiresAt: accessTokenExpiresAt ?? this.accessTokenExpiresAt,
    scopes: scopes ?? this.scopes,
  );

  Map<String, Object?> toJson() => <String, Object?>{
    'clientId': clientId,
    'hostId': hostId,
    'subject': subject,
    'accountLabel': accountLabel,
    if (email != null) 'email': email,
    if (name != null) 'name': name,
    'idToken': idToken,
    'accessToken': accessToken,
    'refreshToken': refreshToken,
    'accessTokenExpiresAt': accessTokenExpiresAt,
    'scopes': scopes,
  };

  static _ChatGptPlanCredential fromJson(Map<String, Object?> json) =>
      _ChatGptPlanCredential(
        clientId: json['clientId'] as String? ?? '',
        hostId: json['hostId'] as String? ?? '',
        subject: json['subject'] as String? ?? '',
        accountLabel: json['accountLabel'] as String? ?? 'ChatGPT',
        email: json['email'] as String?,
        name: json['name'] as String?,
        idToken: json['idToken'] as String? ?? '',
        accessToken: json['accessToken'] as String? ?? '',
        refreshToken: json['refreshToken'] as String? ?? '',
        accessTokenExpiresAt:
            (json['accessTokenExpiresAt'] as num?)?.toInt() ?? 0,
        scopes: json['scopes'] as String? ?? '',
      );
}
