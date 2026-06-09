import 'dart:async';

import 'package:flutter/material.dart';
import 'package:font_awesome_flutter/font_awesome_flutter.dart';
import 'package:intl/intl.dart';
import 'package:omi/backend/preferences.dart';
import 'package:omi/pages/settings/omi_login_webview.dart';
import 'package:omi/services/heypocket_service.dart';
import 'package:omi/services/omi_api_client.dart';

enum _ConnectionState { idle, checking, connected, error }

class IntegrationsPage extends StatefulWidget {
  const IntegrationsPage({super.key, this.onOmiDisabled, this.onHeyPocketDisabled});

  final VoidCallback? onOmiDisabled;
  final VoidCallback? onHeyPocketDisabled;

  @override
  State<IntegrationsPage> createState() => _IntegrationsPageState();
}

class _IntegrationsPageState extends State<IntegrationsPage> {
  final _prefs = SharedPreferencesUtil();

  // HeyPocket
  final _heypocketController = TextEditingController();
  bool _heypocketObscured = true;
  _ConnectionState _heypocketState = _ConnectionState.idle;
  Timer? _heypocketDebounce;

  // Omi Server Sync
  final _omiRefreshTokenController = TextEditingController();
  final _omiFirebaseApiKeyController = TextEditingController();
  bool _omiObscured = true;
  bool _showOmiManual = false;
  _ConnectionState _omiState = _ConnectionState.idle;
  Timer? _omiDebounce;

  @override
  void initState() {
    super.initState();

    // Init HeyPocket
    final hpKey = _prefs.heypocketApiKey;
    _heypocketController.text = hpKey;
    if (hpKey.isNotEmpty) {
      _heypocketState = _ConnectionState.connected;
      _recheckHeyPocketLaunch();
    }
    _heypocketController.addListener(_onHeyPocketChanged);

    // Init Omi
    _omiRefreshTokenController.text = _prefs.omiRefreshToken;
    _omiFirebaseApiKeyController.text = _prefs.omiFirebaseApiKey;
    if (_prefs.omiRefreshToken.isNotEmpty && _prefs.omiFirebaseApiKey.isNotEmpty) {
      _omiState = _ConnectionState.connected;
      _recheckOmiLaunch();
    }
    _omiRefreshTokenController.addListener(_onOmiChanged);
    _omiFirebaseApiKeyController.addListener(_onOmiChanged);
  }

  Future<void> _recheckHeyPocketLaunch() async {
    final key = _prefs.heypocketApiKey;
    if (key.isEmpty) return;
    final valid = await HeyPocketService.testConnection(key).catchError((_) => true);
    if (!valid && mounted) {
      _prefs.heypocketEnabled = false;
      setState(() => _heypocketState = _ConnectionState.error);
    }
  }

  Future<void> _recheckOmiLaunch() async {
    final rt = _prefs.omiRefreshToken;
    final ak = _prefs.omiFirebaseApiKey;
    if (rt.isEmpty || ak.isEmpty) return;
    final valid = await OmiApiClient.testConnection(refreshToken: rt, apiKey: ak).catchError((_) => true);
    if (valid) {
      unawaited(OmiApiClient.refreshSpeechProfileStatus());
    } else if (mounted) {
      _prefs.omiEnabled = false;
      setState(() => _omiState = _ConnectionState.error);
    }
  }

  @override
  void dispose() {
    _heypocketDebounce?.cancel();
    _heypocketController.removeListener(_onHeyPocketChanged);
    _heypocketController.dispose();

    _omiDebounce?.cancel();
    _omiRefreshTokenController.removeListener(_onOmiChanged);
    _omiFirebaseApiKeyController.removeListener(_onOmiChanged);
    _omiRefreshTokenController.dispose();
    _omiFirebaseApiKeyController.dispose();

    super.dispose();
  }

  // HeyPocket logic
  Future<void> _onHeyPocketChanged() async {
    final text = _heypocketController.text;
    if (text.isEmpty) {
      _heypocketDebounce?.cancel();
      await _prefs.setHeypocketApiKey('');
      _prefs.heypocketEnabled = false;
      setState(() => _heypocketState = _ConnectionState.idle);
      return;
    }
    _heypocketDebounce?.cancel();
    if (text.length <= 10 || !text.startsWith('pk_')) return;
    _heypocketDebounce = Timer(const Duration(milliseconds: 800), () => _testHeyPocket(text));
  }

  Future<void> _testHeyPocket(String key) async {
    setState(() => _heypocketState = _ConnectionState.checking);
    try {
      final result = await HeyPocketService.testConnection(key);
      if (_heypocketController.text != key) return;
      if (result) {
        _prefs.heypocketKeySetAt = DateTime.now().millisecondsSinceEpoch;
        await _prefs.setHeypocketApiKey(key);
        _prefs.heypocketEnabled = true;
        unawaited(_prefs.clearAllAutoUploadRetries());
        setState(() => _heypocketState = _ConnectionState.connected);
      } else {
        _prefs.heypocketEnabled = false;
        setState(() => _heypocketState = _ConnectionState.error);
      }
    } catch (_) {
      if (_heypocketController.text != key) return;
      _prefs.heypocketEnabled = false;
      setState(() => _heypocketState = _ConnectionState.error);
    }
  }

  // Omi logic
  void _onOmiChanged() {
    final rt = _omiRefreshTokenController.text.trim();
    final ak = _omiFirebaseApiKeyController.text.trim();

    if (rt.isEmpty || ak.isEmpty) {
      _omiDebounce?.cancel();
      _prefs.setOmiRefreshToken(rt);
      _prefs.setOmiFirebaseApiKey(ak);
      _prefs.omiEnabled = false;
      setState(() => _omiState = _ConnectionState.idle);
      return;
    }

    _omiDebounce?.cancel();
    _omiDebounce = Timer(const Duration(milliseconds: 800), () => _testOmi(rt, ak));
  }

  Future<void> _testOmi(String rt, String ak) async {
    setState(() => _omiState = _ConnectionState.checking);
    try {
      final result = await OmiApiClient.testConnection(refreshToken: rt, apiKey: ak);
      if (_omiRefreshTokenController.text.trim() != rt || _omiFirebaseApiKeyController.text.trim() != ak) return;
      if (result) {
        final isNew = _prefs.omiRefreshToken != rt;
        await _prefs.setOmiRefreshToken(rt);
        await _prefs.setOmiFirebaseApiKey(ak);
        if (isNew) _prefs.omiEnabled = true;
        setState(() => _omiState = _ConnectionState.connected);
      } else {
        _prefs.omiEnabled = false;
        setState(() => _omiState = _ConnectionState.error);
      }
    } catch (_) {
      _prefs.omiEnabled = false;
      setState(() => _omiState = _ConnectionState.error);
    }
  }

  Future<void> _openOmiLogin({bool fallback = false}) async {
    final result = await Navigator.of(context).push<Map<String, String>>(
      MaterialPageRoute(builder: (_) => OmiLoginWebView(startFallback: fallback)),
    );

    if (result != null) {
      final rt = result['refreshToken']!;
      final ak = result['apiKey']!;

      setState(() => _omiState = _ConnectionState.checking);
      final valid = await OmiApiClient.testConnection(refreshToken: rt, apiKey: ak);
      if (valid && mounted) {
        await _prefs.setOmiRefreshToken(rt);
        await _prefs.setOmiFirebaseApiKey(ak);
        _prefs.omiAuthUid = result['uid'] ?? '';
        _prefs.omiAuthEmail = result['email'] ?? '';
        _prefs.omiConnectedViaFallback = result['flow'] == 'fallback';
        final idToken = result['idToken'] ?? '';
        if (idToken.isNotEmpty) {
          await _prefs.setOmiIdToken(idToken);
          final expiresIn = int.tryParse(result['expiresIn'] ?? '') ?? 3600;
          _prefs.omiTokenExpiry = DateTime.now().millisecondsSinceEpoch + expiresIn * 1000;
        }
        _prefs.omiEnabled = true;
        unawaited(_prefs.clearAllAutoUploadRetries());
        _omiRefreshTokenController.removeListener(_onOmiChanged);
        _omiFirebaseApiKeyController.removeListener(_onOmiChanged);
        _omiRefreshTokenController.text = rt;
        _omiFirebaseApiKeyController.text = ak;
        _omiRefreshTokenController.addListener(_onOmiChanged);
        _omiFirebaseApiKeyController.addListener(_onOmiChanged);
        setState(() => _omiState = _ConnectionState.connected);
      } else if (mounted) {
        setState(() => _omiState = _ConnectionState.error);
      }
    }
  }

  Future<void> _deleteOmi() async {
    await OmiApiClient.signOut();
    _prefs.omiConnectedViaFallback = false;
    if (!mounted) return;
    _omiRefreshTokenController.clear();
    _omiFirebaseApiKeyController.clear();
    setState(() {
      _omiState = _ConnectionState.idle;
      _showOmiManual = false;
    });
  }

  void _deleteHeyPocket() {
    _heypocketController.clear();
    setState(() {
      _heypocketState = _ConnectionState.idle;
    });
  }

  Widget _buildIndicator(_ConnectionState state) {
    switch (state) {
      case _ConnectionState.checking:
        return const SizedBox(
          width: 12,
          height: 12,
          child: CircularProgressIndicator(strokeWidth: 1.5, color: Colors.grey),
        );
      case _ConnectionState.connected:
        return Container(
            width: 10, height: 10, decoration: const BoxDecoration(color: Colors.green, shape: BoxShape.circle));
      case _ConnectionState.error:
        return Container(
            width: 10, height: 10, decoration: const BoxDecoration(color: Colors.redAccent, shape: BoxShape.circle));
      case _ConnectionState.idle:
        return Container(
            width: 10, height: 10, decoration: BoxDecoration(color: Colors.grey.shade600, shape: BoxShape.circle));
    }
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
          'Integrations',
          style: TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.w600),
        ),
        centerTitle: true,
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          // Omi Server Sync
          _buildIntegrationSection(
            title: 'Omi Cloud',
            subtitle: 'Auto-upload main recordings to your Omi account',
            state: _omiState,
            enabled: _prefs.omiEnabled,
            onEnabledChanged: (v) {
              _prefs.omiEnabled = v;
              if (!v) widget.onOmiDisabled?.call();
              setState(() {});
            },
            autoUpload: _prefs.omiAutoUpload,
            autoUploadSinceMs: _prefs.omiAutoUploadAt,
            onAutoUploadChanged: (v) {
              _prefs.omiAutoUpload = v;
              setState(() {});
            },
            onDelete: _omiState != _ConnectionState.connected ? _deleteOmi : null,
            trailingWidget: _omiState == _ConnectionState.connected
                ? Container(
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                    decoration: BoxDecoration(
                      color: Colors.grey.shade800,
                      borderRadius: BorderRadius.circular(6),
                    ),
                    child: Text(
                      _prefs.omiConnectedViaFallback ? 'Web App' : 'Direct',
                      style: TextStyle(color: Colors.grey.shade400, fontSize: 11),
                    ),
                  )
                : null,
            fields: [
              if (_omiState != _ConnectionState.connected) ...[
                SizedBox(
                  width: double.infinity,
                  child: ElevatedButton(
                    onPressed: _omiState == _ConnectionState.checking ? null : _openOmiLogin,
                    style: ElevatedButton.styleFrom(
                      backgroundColor: Colors.deepPurpleAccent,
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                      padding: const EdgeInsets.symmetric(vertical: 12),
                    ),
                    child: const Text('Log in with Omi',
                        style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
                  ),
                ),
                const SizedBox(height: 8),
                SizedBox(
                  width: double.infinity,
                  child: OutlinedButton(
                    onPressed: _omiState == _ConnectionState.checking ? null : () => _openOmiLogin(fallback: true),
                    style: OutlinedButton.styleFrom(
                      side: BorderSide(color: Colors.grey.shade600),
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                      padding: const EdgeInsets.symmetric(vertical: 12),
                    ),
                    child: Text('Log in via app.omi.me',
                        style: TextStyle(color: Colors.grey.shade400, fontWeight: FontWeight.bold)),
                  ),
                ),
                const SizedBox(height: 4),
                Center(
                  child: TextButton(
                    onPressed: () => setState(() => _showOmiManual = !_showOmiManual),
                    child: Text(
                      _showOmiManual ? 'Hide manual entry' : 'Enter manually',
                      style: TextStyle(color: Colors.grey.shade400, fontSize: 12),
                    ),
                  ),
                ),
              ],
              if (_omiState == _ConnectionState.connected) ...[
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                  decoration: BoxDecoration(
                    color: const Color(0xFF2C2C2E),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Row(
                    children: [
                      const Icon(Icons.account_circle_outlined, color: Colors.grey, size: 18),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          _prefs.omiAuthEmail.isNotEmpty ? _prefs.omiAuthEmail : 'Omi Account',
                          style: const TextStyle(color: Colors.white70, fontSize: 13),
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 10),
                SizedBox(
                  width: double.infinity,
                  child: OutlinedButton(
                    onPressed: _deleteOmi,
                    style: OutlinedButton.styleFrom(
                      side: const BorderSide(color: Colors.redAccent),
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                      padding: const EdgeInsets.symmetric(vertical: 12),
                    ),
                    child:
                        const Text('Log out', style: TextStyle(color: Colors.redAccent, fontWeight: FontWeight.bold)),
                  ),
                ),
                Center(
                  child: TextButton(
                    onPressed: () => setState(() => _showOmiManual = !_showOmiManual),
                    child: Text(
                      _showOmiManual ? 'Hide credentials' : 'Enter manually',
                      style: TextStyle(color: Colors.grey.shade400, fontSize: 12),
                    ),
                  ),
                ),
              ],
              if (_showOmiManual) ...[
                _buildField(
                  controller: _omiRefreshTokenController,
                  hint: 'Refresh Token',
                  obscured: _omiObscured,
                  onToggleObscure: () => setState(() => _omiObscured = !_omiObscured),
                ),
                const SizedBox(height: 12),
                _buildField(
                  controller: _omiFirebaseApiKeyController,
                  hint: 'Firebase API Key',
                  obscured: _omiObscured,
                  onToggleObscure: () => setState(() => _omiObscured = !_omiObscured),
                ),
              ],
            ],
          ),
          const SizedBox(height: 16),

          // HeyPocket
          _buildIntegrationSection(
            title: 'HeyPocket',
            subtitle: 'Auto-upload main recordings to HeyPocket',
            state: _heypocketState,
            enabled: _prefs.heypocketEnabled,
            onEnabledChanged: (v) {
              _prefs.heypocketEnabled = v;
              if (!v) widget.onHeyPocketDisabled?.call();
              setState(() {});
            },
            autoUpload: _prefs.heypocketAutoUpload,
            autoUploadSinceMs: _prefs.heypocketKeySetAt,
            onAutoUploadChanged: (v) {
              _prefs.heypocketAutoUpload = v;
              setState(() {});
            },
            onDelete: _deleteHeyPocket,
            fields: [
              _buildField(
                controller: _heypocketController,
                hint: 'API key (pk_...)',
                obscured: _heypocketObscured,
                onToggleObscure: () => setState(() => _heypocketObscured = !_heypocketObscured),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildIntegrationSection({
    required String title,
    required String subtitle,
    required _ConnectionState state,
    required bool enabled,
    required ValueChanged<bool> onEnabledChanged,
    required bool autoUpload,
    required int autoUploadSinceMs,
    required ValueChanged<bool> onAutoUploadChanged,
    required List<Widget> fields,
    VoidCallback? onDelete,
    Widget? trailingWidget,
  }) {
    final isChecking = state == _ConnectionState.checking;
    final isConnected = state == _ConnectionState.connected;

    return Container(
      decoration: BoxDecoration(
        color: const Color(0xFF1C1C1E),
        borderRadius: BorderRadius.circular(16),
      ),
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Text(
                title,
                style: const TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.w600),
              ),
              const SizedBox(width: 8),
              _buildIndicator(state),
              if (trailingWidget != null || onDelete != null) ...[
                const Spacer(),
                if (trailingWidget != null) trailingWidget,
                if (onDelete != null)
                  IconButton(
                    onPressed: onDelete,
                    icon: const Icon(Icons.delete_outline, color: Colors.grey, size: 20),
                    padding: EdgeInsets.zero,
                    constraints: const BoxConstraints(),
                    visualDensity: VisualDensity.compact,
                  ),
              ],
            ],
          ),
          const SizedBox(height: 12),
          ...fields,
          const SizedBox(height: 12),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('Enabled', style: TextStyle(color: Colors.white, fontSize: 14)),
            subtitle: Text(
              'Use this integration for uploads and passthrough',
              style: TextStyle(color: Colors.grey.shade500, fontSize: 12),
            ),
            value: enabled,
            activeThumbColor: Colors.deepPurpleAccent,
            onChanged: isChecking || !isConnected ? null : onEnabledChanged,
          ),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('Auto-Upload', style: TextStyle(color: Colors.white, fontSize: 14)),
            subtitle: Text(
              subtitle,
              style: TextStyle(color: Colors.grey.shade500, fontSize: 12),
            ),
            value: autoUpload,
            activeThumbColor: Colors.deepPurpleAccent,
            onChanged: isChecking || !isConnected || !enabled ? null : onAutoUploadChanged,
          ),
          if (autoUpload && isConnected && autoUploadSinceMs > 0)
            Padding(
              padding: const EdgeInsets.only(top: 2, bottom: 4),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Icon(Icons.schedule, size: 13, color: Colors.grey.shade500),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      'Auto-uploading recordings started after ${_formatCutoff(autoUploadSinceMs)}. '
                      'Earlier recordings aren\'t sent automatically — open one and tap the cloud icon to upload it.',
                      style: TextStyle(color: Colors.grey.shade500, fontSize: 11, height: 1.3),
                    ),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }

  /// Formats the auto-upload cutoff timestamp (epoch ms) for display, honoring
  /// the user's 12/24-hour preference.
  String _formatCutoff(int ms) {
    final dt = DateTime.fromMillisecondsSinceEpoch(ms);
    final pattern = _prefs.use24HourTime ? 'MMM d, yyyy · HH:mm' : 'MMM d, yyyy · h:mm a';
    return DateFormat(pattern).format(dt);
  }

  Widget _buildField({
    required TextEditingController controller,
    required String hint,
    required bool obscured,
    required VoidCallback onToggleObscure,
  }) {
    return TextField(
      controller: controller,
      obscureText: obscured,
      style: const TextStyle(color: Colors.white, fontSize: 14),
      decoration: InputDecoration(
        hintText: hint,
        hintStyle: TextStyle(color: Colors.grey.shade600, fontSize: 14),
        filled: true,
        fillColor: const Color(0xFF2C2C2E),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(10),
          borderSide: BorderSide.none,
        ),
        contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        suffixIcon: IconButton(
          icon: FaIcon(
            obscured ? FontAwesomeIcons.eye : FontAwesomeIcons.eyeSlash,
            size: 14,
            color: Colors.grey,
          ),
          onPressed: onToggleObscure,
          tooltip: obscured ? 'Show API key' : 'Hide API key',
        ),
      ),
    );
  }
}
