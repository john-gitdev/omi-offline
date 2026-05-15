import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:font_awesome_flutter/font_awesome_flutter.dart';
import 'package:http/http.dart' as http;
import 'package:webview_flutter/webview_flutter.dart';

class OmiLoginWebView extends StatefulWidget {
  const OmiLoginWebView({super.key});

  @override
  State<OmiLoginWebView> createState() => _OmiLoginWebViewState();
}

class _OmiLoginWebViewState extends State<OmiLoginWebView> {
  late final WebViewController _controller;
  bool _isLoading = true;
  bool _credentialsCaptured = false;
  String? _errorMessage;

  String? _apiKey;
  String? _sessionId;

  static const _firebaseSignInIdpUrl = 'https://identitytoolkit.googleapis.com/v1/accounts:signInWithIdp';
  static const _firebaseCreateAuthUriUrl = 'https://identitytoolkit.googleapis.com/v1/accounts:createAuthUri';

  @override
  void initState() {
    super.initState();
    _controller = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setBackgroundColor(const Color(0xFF0D0D0D))
      ..setUserAgent(
          'Mozilla/5.0 (Linux; Android 10; Mobile) AppleWebKit/537.36 '
          '(KHTML, like Gecko) Chrome/124.0.0.0 Mobile Safari/537.36')
      ..setNavigationDelegate(
        NavigationDelegate(
          onPageStarted: (_) => setState(() => _isLoading = true),
          onPageFinished: (_) => setState(() => _isLoading = false),
          onNavigationRequest: _onNavigationRequest,
          onWebResourceError: (e) => debugPrint('OmiLoginWebView: WebResourceError: ${e.description}'),
        ),
      );
    _loadOmiApp();
  }

  void _loadOmiApp() {
    _controller.loadRequest(Uri.parse('https://app.omi.me'));
  }

  NavigationDecision _onNavigationRequest(NavigationRequest request) {
    final uri = Uri.tryParse(request.url);
    debugPrint('OmiLoginWebView: navigate → ${request.url}');
    if (uri == null) return NavigationDecision.navigate;

    if (uri.host == 'based-hardware.firebaseapp.com' && uri.path.startsWith('/__/auth/handler')) {
      if (uri.queryParameters.containsKey('code')) {
        _exchangeCodeForTokens(request.url);
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
      debugPrint('OmiLoginWebView: createAuthUri failed: ${res.statusCode}');
    } catch (e) {
      debugPrint('OmiLoginWebView: createAuthUri error: $e');
    }

    if (mounted) setState(() => _isLoading = false);
  }

  Future<void> _exchangeCodeForTokens(String callbackUrl) async {
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
      debugPrint('OmiLoginWebView: signInWithIdp → ${res.statusCode}');
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
          });
          return;
        }
      }
      debugPrint('OmiLoginWebView: signInWithIdp failed: ${res.statusCode}');
    } catch (e) {
      debugPrint('OmiLoginWebView: token exchange error: $e');
    }

    if (mounted) setState(() => _isLoading = false);
  }

  void _retry() {
    if (!mounted) return;
    setState(() {
      _errorMessage = null;
      _isLoading = true;
      _sessionId = null;
      _apiKey = null;
    });
    _loadOmiApp();
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
  final VoidCallback onRetry;
  final VoidCallback onDismiss;

  const _ErrorOverlay({required this.message, required this.onRetry, required this.onDismiss});

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
          SizedBox(
            width: double.infinity,
            child: ElevatedButton(
              onPressed: onRetry,
              style: ElevatedButton.styleFrom(
                backgroundColor: Colors.deepPurpleAccent,
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
