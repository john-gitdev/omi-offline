import 'dart:convert';
import 'dart:math';
import 'package:flutter/material.dart';
import 'package:font_awesome_flutter/font_awesome_flutter.dart';
import 'package:http/http.dart' as http;
import 'package:webview_flutter/webview_flutter.dart';

enum _FlowMode { omiBacked, fallback }

class OmiLoginWebView extends StatefulWidget {
  const OmiLoginWebView({super.key, this.startFallback = false});

  final bool startFallback;

  @override
  State<OmiLoginWebView> createState() => _OmiLoginWebViewState();
}

class _OmiLoginWebViewState extends State<OmiLoginWebView> {
  late final WebViewController _controller;
  bool _isLoading = true;
  bool _credentialsCaptured = false;
  String? _errorMessage;

  // Fallback flow picks up the key from the intercepted WebView URL;
  // the Omi-backed flow uses this fixed key for api.omi.me's Firebase project.
  static const _omiBackedFirebaseApiKey = 'AIzaSyA88gHcmiAxjN_aE23tHRWXOgFfapyO6dk';

  String? _apiKey;
  _FlowMode _flowMode = _FlowMode.omiBacked;
  String? _state; // CSRF state for the Omi-backed flow

  // Fallback-only state
  String? _sessionId;

  static const _omiAuthorizeUrl = 'https://api.omi.me/v1/auth/authorize';
  static const _omiTokenUrl = 'https://api.omi.me/v1/auth/token';
  static const _omiRedirectUri = 'omi-ambient-companion://auth/callback';
  static const _firebaseSignInIdpUrl = 'https://identitytoolkit.googleapis.com/v1/accounts:signInWithIdp';
  static const _firebaseSignInCustomUrl = 'https://identitytoolkit.googleapis.com/v1/accounts:signInWithCustomToken';
  static const _firebaseCreateAuthUriUrl = 'https://identitytoolkit.googleapis.com/v1/accounts:createAuthUri';

  @override
  void initState() {
    super.initState();
    _controller = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setBackgroundColor(const Color(0xFF0D0D0D))
      // Google blocks OAuth in embedded WebViews (detects "wv" in default UA).
      // Override with a standard Chrome Mobile UA so sign-in is allowed.
      ..setUserAgent('Mozilla/5.0 (Linux; Android 10; Mobile) AppleWebKit/537.36 '
          '(KHTML, like Gecko) Chrome/124.0.0.0 Mobile Safari/537.36')
      ..setNavigationDelegate(
        NavigationDelegate(
          onPageStarted: (_) => setState(() => _isLoading = true),
          onPageFinished: (_) => setState(() => _isLoading = false),
          onNavigationRequest: _onNavigationRequest,
          onWebResourceError: (e) => debugPrint('OmiLoginWebView: WebResourceError: ${e.description}'),
        ),
      );
    if (widget.startFallback) {
      _activateFallback();
    } else {
      _startOmiBackedFlow();
    }
  }

  NavigationDecision _onNavigationRequest(NavigationRequest request) {
    final uri = Uri.tryParse(request.url);
    debugPrint('OmiLoginWebView: navigate → ${request.url}');
    if (uri == null) return NavigationDecision.navigate;

    // Omi-backed flow: intercept omi://auth/callback
    if (_flowMode == _FlowMode.omiBacked &&
        uri.scheme == 'omi-ambient-companion' &&
        uri.host == 'auth' &&
        uri.path == '/callback') {
      _handleOmiCallback(uri.queryParameters['code'], uri.queryParameters['state']);
      return NavigationDecision.prevent;
    }

    // Fallback flow: existing Firebase popup interception
    if (_flowMode == _FlowMode.fallback &&
        uri.host == 'based-hardware.firebaseapp.com' &&
        uri.path.startsWith('/__/auth/handler')) {
      if (uri.queryParameters.containsKey('code')) {
        _exchangeCodeForTokensFallback(request.url);
        return NavigationDecision.prevent;
      }
      if (uri.queryParameters['authType'] == 'signInViaPopup') {
        final key = uri.queryParameters['apiKey'];
        if (key != null) {
          _startDirectAuthFlow(key, uri);
          return NavigationDecision.prevent;
        }
      }
    }

    return NavigationDecision.navigate;
  }

  // ─── Omi-backed flow ──────────────────────────────────────────────────────

  Future<void> _startOmiBackedFlow() async {
    _apiKey = _omiBackedFirebaseApiKey;
    _state = _generateState();
    _flowMode = _FlowMode.omiBacked;
    final url = '$_omiAuthorizeUrl'
        '?provider=google'
        '&redirect_uri=${Uri.encodeComponent(_omiRedirectUri)}'
        '&state=${Uri.encodeComponent(_state!)}';
    debugPrint('OmiLoginWebView: [new] loading authorize URL');
    _controller.loadRequest(Uri.parse(url));
  }

  Future<void> _handleOmiCallback(String? code, String? returnedState) async {
    if (_credentialsCaptured) return;

    if (returnedState != _state) {
      debugPrint('OmiLoginWebView: [new] state mismatch — aborting');
      _setError('Something went wrong during sign-in. Please try again.');
      return;
    }
    if (code == null || code.isEmpty) {
      debugPrint('OmiLoginWebView: [new] callback missing code');
      _setError('Sign-in was cancelled or didn\'t complete. Please try again.');
      return;
    }

    if (mounted) setState(() => _isLoading = true);

    try {
      final tokenRes = await http.post(
        Uri.parse(_omiTokenUrl),
        headers: {'Content-Type': 'application/x-www-form-urlencoded'},
        body: {
          'grant_type': 'authorization_code',
          'code': code,
          'redirect_uri': _omiRedirectUri,
          'use_custom_token': 'true',
        },
      ).timeout(const Duration(seconds: 15));

      debugPrint('OmiLoginWebView: [new] v1/auth/token → ${tokenRes.statusCode}');
      if (tokenRes.statusCode < 200 || tokenRes.statusCode >= 300) {
        _setError('Sign-in didn\'t complete. Please try again.');
        return;
      }

      final tokenJson = jsonDecode(tokenRes.body) as Map<String, dynamic>;
      final session = await _signInWithFirebase(tokenJson);
      if (session == null) {
        _setError('Couldn\'t finish signing you in. Please try again.');
        return;
      }

      _credentialsCaptured = true;
      debugPrint('OmiLoginWebView: [new] auth complete');
      if (mounted) Navigator.of(context).pop({...session, 'flow': 'omi_backed'});
    } catch (e) {
      debugPrint('OmiLoginWebView: [new] error occurred');
      _setError('No internet connection. Check your connection and try again.');
    }
  }

  Future<Map<String, String>?> _signInWithFirebase(Map<String, dynamic> tokenJson) async {
    final result = await _signInWithProviderCredential(tokenJson);
    if (result != null) return result;
    final customToken = tokenJson['custom_token'] as String?;
    if (customToken != null && customToken.isNotEmpty) {
      return _signInWithCustomToken(customToken);
    }
    return null;
  }

  Future<Map<String, String>?> _signInWithProviderCredential(Map<String, dynamic> tokenJson) async {
    final idToken = tokenJson['id_token'] as String?;
    if (idToken == null || idToken.isEmpty) return null;

    final provider = tokenJson['provider'] as String? ?? 'google';
    final providerId = tokenJson['provider_id'] as String? ?? (provider == 'apple' ? 'apple.com' : 'google.com');
    final accessToken = tokenJson['access_token'] as String? ?? '';

    final postBody =
        StringBuffer('id_token=${Uri.encodeComponent(idToken)}&providerId=${Uri.encodeComponent(providerId)}');
    if (accessToken.isNotEmpty) postBody.write('&access_token=${Uri.encodeComponent(accessToken)}');

    try {
      final res = await http
          .post(
            Uri.parse('$_firebaseSignInIdpUrl?key=$_apiKey'),
            headers: {'Content-Type': 'application/json'},
            body: jsonEncode({
              'postBody': postBody.toString(),
              'requestUri': 'http://localhost',
              'returnIdpCredential': true,
              'returnSecureToken': true,
            }),
          )
          .timeout(const Duration(seconds: 15));
      debugPrint('OmiLoginWebView: [new] signInWithIdp → ${res.statusCode}');
      if (res.statusCode == 200) return _extractSession(res.body);
    } catch (e) {
      debugPrint('OmiLoginWebView: [new] signInWithIdp error occurred');
    }
    return null;
  }

  Future<Map<String, String>?> _signInWithCustomToken(String customToken) async {
    try {
      final res = await http
          .post(
            Uri.parse('$_firebaseSignInCustomUrl?key=$_apiKey'),
            headers: {'Content-Type': 'application/json'},
            body: jsonEncode({'token': customToken, 'returnSecureToken': true}),
          )
          .timeout(const Duration(seconds: 15));
      debugPrint('OmiLoginWebView: [new] signInWithCustomToken → ${res.statusCode}');
      if (res.statusCode == 200) return _extractSession(res.body);
    } catch (e) {
      debugPrint('OmiLoginWebView: [new] signInWithCustomToken error occurred');
    }
    return null;
  }

  Map<String, String>? _extractSession(String body) {
    try {
      final json = jsonDecode(body) as Map<String, dynamic>;
      final refreshToken = json['refreshToken'] as String?;
      if (refreshToken == null || refreshToken.isEmpty) return null;
      return {
        'refreshToken': refreshToken,
        'apiKey': _apiKey!,
        'uid': (json['localId'] as String?) ?? '',
        'email': (json['email'] as String?) ?? '',
        'idToken': (json['idToken'] as String?) ?? '',
        'expiresIn': json['expiresIn']?.toString() ?? '3600',
      };
    } catch (_) {
      return null;
    }
  }

  String _generateState() {
    final rand = Random.secure();
    return List.generate(32, (_) => rand.nextInt(256)).map((b) => b.toRadixString(16).padLeft(2, '0')).join();
  }

  void _setError(String message) {
    if (!mounted || _credentialsCaptured) return;
    setState(() {
      _isLoading = false;
      _errorMessage = message;
    });
  }

  void _retry() {
    if (!mounted) return;
    setState(() {
      _errorMessage = null;
      _isLoading = true;
      _state = null;
      _sessionId = null;
      _apiKey = null;
    });
    _startOmiBackedFlow();
  }

  void _activateFallback() {
    if (!mounted || _credentialsCaptured) return;
    setState(() {
      _errorMessage = null;
      _isLoading = true;
      _flowMode = _FlowMode.fallback;
      _state = null;
      _sessionId = null;
      _apiKey = null;
    });
    _controller.loadRequest(Uri.parse('https://app.omi.me'));
  }

  // ─── Fallback flow (existing) ──────────────────────────────────────────────

  Future<void> _startDirectAuthFlow(String apiKey, Uri popupUri) async {
    _apiKey = apiKey;
    final continueUri = '${popupUri.scheme}://${popupUri.host}${popupUri.path}';
    if (mounted) setState(() => _isLoading = true);

    try {
      final res = await http.post(
        Uri.parse('$_firebaseCreateAuthUriUrl?key=$apiKey'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({
          'continueUri': continueUri,
          'providerId': 'google.com',
          'oauthScope': 'profile email openid',
          'customParameter': {'prompt': 'select_account'},
        }),
      );
      if (res.statusCode == 200) {
        final data = jsonDecode(res.body) as Map<String, dynamic>;
        _sessionId = data['sessionId'] as String?;
        final authUri = data['authUri'] as String?;
        if (_sessionId != null && authUri != null) {
          _controller.loadRequest(Uri.parse(authUri));
          return;
        }
      }
      debugPrint('OmiLoginWebView: [fallback] createAuthUri failed: ${res.statusCode}');
    } catch (e) {
      debugPrint('OmiLoginWebView: [fallback] createAuthUri error occurred');
    }

    if (mounted) setState(() => _isLoading = false);
  }

  Future<void> _exchangeCodeForTokensFallback(String callbackUrl) async {
    if (_credentialsCaptured || _apiKey == null || _sessionId == null) return;
    if (mounted) setState(() => _isLoading = true);

    try {
      final res = await http.post(
        Uri.parse('$_firebaseSignInIdpUrl?key=$_apiKey'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({
          'requestUri': callbackUrl,
          'sessionId': _sessionId,
          'returnSecureToken': true,
          'returnIdpCredential': true,
        }),
      );
      debugPrint('OmiLoginWebView: [fallback] signInWithIdp → ${res.statusCode}');
      if (res.statusCode == 200) {
        final data = jsonDecode(res.body) as Map<String, dynamic>;
        final refreshToken = data['refreshToken'] as String?;
        if (refreshToken != null && mounted && !_credentialsCaptured) {
          _credentialsCaptured = true;
          Navigator.of(context).pop(<String, String>{
            'refreshToken': refreshToken,
            'apiKey': _apiKey!,
            'uid': (data['localId'] as String?) ?? '',
            'email': (data['email'] as String?) ?? '',
            'idToken': (data['idToken'] as String?) ?? '',
            'expiresIn': data['expiresIn']?.toString() ?? '3600',
            'flow': 'fallback',
          });
          return;
        }
      }
      debugPrint('OmiLoginWebView: [fallback] signInWithIdp failed: ${res.statusCode}');
    } catch (e) {
      debugPrint('OmiLoginWebView: [fallback] token exchange error occurred');
    }

    if (mounted) setState(() => _isLoading = false);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF0D0D0D),
      appBar: AppBar(
        backgroundColor: const Color(0xFF0D0D0D),
        elevation: 0,
        leading: IconButton(
          icon: const FaIcon(FontAwesomeIcons.chevronLeft, size: 18),
          onPressed: () => Navigator.of(context).pop(),
          tooltip: 'Back',
        ),
        title: const Text(
          'Log in with Omi',
          style: TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.w600),
        ),
        centerTitle: true,
      ),
      body: Stack(
        children: [
          WebViewWidget(controller: _controller),
          if (_isLoading)
            const Center(
              child: CircularProgressIndicator(color: Colors.deepPurpleAccent),
            ),
          if (_errorMessage != null)
            _ErrorOverlay(
              message: _errorMessage!,
              onFallback: _flowMode == _FlowMode.omiBacked ? _activateFallback : null,
              onRetry: _retry,
              onDismiss: () => Navigator.of(context).pop(),
            ),
        ],
      ),
    );
  }
}

class _ErrorOverlay extends StatelessWidget {
  final String message;
  final VoidCallback? onFallback;
  final VoidCallback onRetry;
  final VoidCallback onDismiss;

  const _ErrorOverlay({required this.message, this.onFallback, required this.onRetry, required this.onDismiss});

  @override
  Widget build(BuildContext context) {
    return Container(
      color: const Color(0xFF0D0D0D),
      padding: const EdgeInsets.all(32),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          const Icon(Icons.error_outline, color: Colors.redAccent, size: 48),
          const SizedBox(height: 16),
          Text(
            message,
            style: const TextStyle(color: Colors.white70, fontSize: 15),
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 24),
          if (onFallback != null) ...[
            SizedBox(
              width: double.infinity,
              child: ElevatedButton(
                onPressed: onFallback,
                style: ElevatedButton.styleFrom(
                  backgroundColor: Colors.deepPurpleAccent,
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                  padding: const EdgeInsets.symmetric(vertical: 12),
                ),
                child: const Text('Try Another Method',
                    style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
              ),
            ),
            const SizedBox(height: 12),
          ],
          SizedBox(
            width: double.infinity,
            child: ElevatedButton(
              onPressed: onRetry,
              style: ElevatedButton.styleFrom(
                backgroundColor: onFallback != null ? Colors.grey.shade800 : Colors.deepPurpleAccent,
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                padding: const EdgeInsets.symmetric(vertical: 12),
              ),
              child: const Text('Retry Login', style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
            ),
          ),
          const SizedBox(height: 12),
          TextButton(
            onPressed: onDismiss,
            child: Text('Go Back', style: TextStyle(color: Colors.grey.shade400, fontSize: 14)),
          ),
        ],
      ),
    );
  }
}
