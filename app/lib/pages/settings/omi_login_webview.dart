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
  String? _sessionId;
  String? _apiKey;

  @override
  void initState() {
    super.initState();
    _controller = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setBackgroundColor(const Color(0xFF0D0D0D))
      // Google blocks OAuth in embedded WebViews (detects "wv" in default UA).
      // Override with a standard Chrome Mobile UA so sign-in is allowed.
      ..setUserAgent(
          'Mozilla/5.0 (Linux; Android 10; Mobile) AppleWebKit/537.36 '
          '(KHTML, like Gecko) Chrome/124.0.0.0 Mobile Safari/537.36')
      ..setNavigationDelegate(
        NavigationDelegate(
          onPageStarted: (url) {
            debugPrint('OmiLoginWebView: onPageStarted: $url');
            setState(() => _isLoading = true);
          },
          onPageFinished: (url) {
            debugPrint('OmiLoginWebView: onPageFinished: $url');
            setState(() => _isLoading = false);
          },
          onNavigationRequest: (NavigationRequest request) {
            final uri = Uri.tryParse(request.url);
            debugPrint('OmiLoginWebView: onNavigationRequest to ${request.url}');
            
            if (uri != null &&
                uri.host == 'based-hardware.firebaseapp.com' &&
                uri.path.startsWith('/__/auth/handler')) {
              
              // 1. Detect the OAuth callback to exchange the code for tokens.
              if (uri.queryParameters.containsKey('code')) {
                debugPrint('OmiLoginWebView: Detected OAuth code callback. Exchanging tokens...');
                _exchangeCodeForTokens(request.url);
                return NavigationDecision.prevent;
              }

              // 2. Detect the initial popup trigger to extract the API key dynamically.
              if (uri.queryParameters['authType'] == 'signInViaPopup') {
                final apiKey = uri.queryParameters['apiKey'];
                debugPrint('OmiLoginWebView: Detected popup trigger. Extracted apiKey: $apiKey');
                if (apiKey != null) {
                  _startDirectAuthFlow(apiKey, uri);
                  return NavigationDecision.prevent;
                }
              }
            }
            return NavigationDecision.navigate;
          },
          onWebResourceError: (WebResourceError error) {
            debugPrint('OmiLoginWebView: WebResourceError: ${error.description} (code: ${error.errorCode}, type: ${error.errorType})');
          },
        ),
      )
      ..loadRequest(Uri.parse('https://app.omi.me'));
  }

  Future<void> _startDirectAuthFlow(String apiKey, Uri popupUri) async {
    _apiKey = apiKey;
    final continueUri = '${popupUri.scheme}://${popupUri.host}${popupUri.path}';
    debugPrint('OmiLoginWebView: Starting direct auth flow with continueUri: $continueUri');
    if (mounted) setState(() => _isLoading = true);

    try {
      debugPrint('OmiLoginWebView: Calling createAuthUri...');
      final response = await http.post(
        Uri.parse(
          'https://identitytoolkit.googleapis.com/v1/accounts:createAuthUri?key=$apiKey',
        ),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({
          'continueUri': continueUri,
          'providerId': 'google.com',
          'oauthScope': 'profile email openid',
          'customParameter': {'prompt': 'select_account'},
        }),
      );

      debugPrint('OmiLoginWebView: createAuthUri response: ${response.statusCode}');
      if (response.statusCode == 200) {
        final data = jsonDecode(response.body) as Map<String, dynamic>;
        _sessionId = data['sessionId'] as String?;
        final authUri = data['authUri'] as String?;
        debugPrint('OmiLoginWebView: Obtained sessionId: ${_sessionId != null}, authUri: ${authUri != null}');
        if (_sessionId != null && authUri != null) {
          debugPrint('OmiLoginWebView: Loading authUri: $authUri');
          _controller.loadRequest(Uri.parse(authUri));
          return;
        }
      }
      debugPrint('OmiLoginWebView: createAuthUri failed: ${response.statusCode} ${response.body}');
    } catch (e) {
      debugPrint('OmiLoginWebView: createAuthUri error: $e');
    }

    if (mounted) setState(() => _isLoading = false);
  }

  Future<void> _exchangeCodeForTokens(String callbackUrl) async {
    if (_credentialsCaptured || _apiKey == null || _sessionId == null) {
      debugPrint('OmiLoginWebView: Cannot exchange tokens. Captured: $_credentialsCaptured, ApiKey: ${_apiKey != null}, SessionId: ${_sessionId != null}');
      return;
    }
    if (mounted) setState(() => _isLoading = true);

    try {
      debugPrint('OmiLoginWebView: Calling signInWithIdp...');
      final response = await http.post(
        Uri.parse(
          'https://identitytoolkit.googleapis.com/v1/accounts:signInWithIdp?key=$_apiKey',
        ),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({
          'requestUri': callbackUrl,
          'sessionId': _sessionId,
          'returnSecureToken': true,
          'returnIdpCredential': true,
        }),
      );

      debugPrint('OmiLoginWebView: signInWithIdp response: ${response.statusCode}');
      if (response.statusCode == 200) {
        final data = jsonDecode(response.body) as Map<String, dynamic>;
        final refreshToken = data['refreshToken'] as String?;
        debugPrint('OmiLoginWebView: Token exchange success: ${refreshToken != null}');
        if (refreshToken != null && mounted && !_credentialsCaptured) {
          _credentialsCaptured = true;
          debugPrint('OmiLoginWebView: Popping with success result.');
          Navigator.of(context).pop(<String, String>{
            'refreshToken': refreshToken,
            'apiKey': _apiKey!,
          });
          return;
        }
      }
      debugPrint('OmiLoginWebView: signInWithIdp failed: ${response.statusCode} ${response.body}');
    } catch (e) {
      debugPrint('OmiLoginWebView: Token exchange error: $e');
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
        ],
      ),
    );
  }
}
