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

  // Public web API key — visible in every Firebase web app, safe to hardcode.
  static const _firebaseApiKey = 'AIzaSyDSpVTxMinTZXuV89V07HkNJCgdNIhX0Dk';

  @override
  void initState() {
    super.initState();
    _controller = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setBackgroundColor(const Color(0xFF0D0D0D))
      // Google blocks OAuth in embedded WebViews (detects "wv" in default UA).
      // Override with a standard Chrome Mobile UA so the sign-in flow is allowed.
      ..setUserAgent(
          'Mozilla/5.0 (Linux; Android 10; Mobile) AppleWebKit/537.36 '
          '(KHTML, like Gecko) Chrome/124.0.0.0 Mobile Safari/537.36')
      ..setNavigationDelegate(
        NavigationDelegate(
          onPageStarted: (String url) {
            setState(() => _isLoading = true);
          },
          onPageFinished: (String url) {
            setState(() => _isLoading = false);
          },
          onNavigationRequest: (NavigationRequest request) {
            final uri = Uri.tryParse(request.url);
            // app.omi.me uses signInViaPopup. In a WebView there is no opener,
            // so the Firebase handler page stalls forever waiting to postMessage
            // to window.opener. Intercept the OAuth callback here and exchange
            // the code via Firebase's REST API instead.
            if (uri != null &&
                uri.host == 'based-hardware.firebaseapp.com' &&
                uri.path.startsWith('/__/auth/handler') &&
                uri.queryParameters.containsKey('code')) {
              _exchangeCodeForTokens(request.url);
              return NavigationDecision.prevent;
            }
            return NavigationDecision.navigate;
          },
          onWebResourceError: (WebResourceError error) {
            debugPrint('OmiLoginWebView: WebResourceError: ${error.description}');
          },
        ),
      )
      ..loadRequest(Uri.parse('https://app.omi.me'));
  }

  Future<void> _exchangeCodeForTokens(String callbackUrl) async {
    if (_credentialsCaptured) return;
    if (mounted) setState(() => _isLoading = true);

    try {
      final response = await http.post(
        Uri.parse(
          'https://identitytoolkit.googleapis.com/v1/accounts:signInWithIdp?key=$_firebaseApiKey',
        ),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({
          'requestUri': callbackUrl,
          'returnSecureToken': true,
          'returnIdpCredential': true,
        }),
      );

      if (response.statusCode == 200) {
        final data = jsonDecode(response.body) as Map<String, dynamic>;
        final refreshToken = data['refreshToken'] as String?;
        if (refreshToken != null && mounted && !_credentialsCaptured) {
          _credentialsCaptured = true;
          Navigator.of(context).pop({
            'refreshToken': refreshToken,
            'apiKey': _firebaseApiKey,
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
