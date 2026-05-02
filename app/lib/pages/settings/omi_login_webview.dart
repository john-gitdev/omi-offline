import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:font_awesome_flutter/font_awesome_flutter.dart';
import 'package:webview_flutter/webview_flutter.dart';

class OmiLoginWebView extends StatefulWidget {
  const OmiLoginWebView({super.key});

  @override
  State<OmiLoginWebView> createState() => _OmiLoginWebViewState();
}

class _OmiLoginWebViewState extends State<OmiLoginWebView> {
  late final WebViewController _controller;
  bool _isLoading = true;

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
            // Only attempt extraction on app.omi.me — not on Google's auth pages
            // or Firebase's intermediate redirect handler.
            if (url.startsWith('https://app.omi.me')) {
              _injectExtractionScript();
            }
          },
          onWebResourceError: (WebResourceError error) {
            debugPrint('OmiLoginWebView: WebResourceError: ${error.description}');
          },
        ),
      )
      ..addJavaScriptChannel(
        'OmiLoginChannel',
        onMessageReceived: (JavaScriptMessage message) {
          try {
            final data = jsonDecode(message.message);
            final refreshToken = data['refreshToken'] as String?;
            final apiKey = data['apiKey'] as String?;
            if (refreshToken != null && apiKey != null) {
              Navigator.of(context).pop({'refreshToken': refreshToken, 'apiKey': apiKey});
            }
          } catch (e) {
            debugPrint('OmiLoginWebView: Error parsing JS message: $e');
          }
        },
      )
      ..loadRequest(Uri.parse('https://app.omi.me'));
  }

  void _injectExtractionScript() {
    const script = '''
      (function() {
        var request = indexedDB.open("firebaseLocalStorageDb");
        request.onsuccess = function(event) {
          var db = event.target.result;
          try {
            var transaction = db.transaction(["firebaseLocalStorage"], "readonly");
            var objectStore = transaction.objectStore("firebaseLocalStorage");
            var cursorRequest = objectStore.openCursor();
            cursorRequest.onsuccess = function(event) {
              var cursor = event.target.result;
              if (cursor) {
                var key = cursor.key;
                if (typeof key === 'string' && key.startsWith('firebase:authUser:')) {
                  var raw = cursor.value;
                  // Firebase SDK v8 stores the user object directly; v9+ wraps it under .value
                  var value = (raw && raw.stsTokenManager) ? raw : (raw && raw.value) ? raw.value : null;
                  if (value && value.stsTokenManager && value.stsTokenManager.refreshToken && value.apiKey) {
                    OmiLoginChannel.postMessage(JSON.stringify({
                      refreshToken: value.stsTokenManager.refreshToken,
                      apiKey: value.apiKey
                    }));
                    return;
                  }
                }
                cursor.continue();
              }
            };
          } catch (e) {
            console.error("OmiLoginWebView: Error accessing IndexedDB", e);
          }
        };
        request.onerror = function(event) {
          console.error("OmiLoginWebView: IndexedDB open error", event);
        };
      })();
    ''';
    _controller.runJavaScript(script);
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
