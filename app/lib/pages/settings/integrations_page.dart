import 'dart:async';

import 'package:flutter/material.dart';
import 'package:font_awesome_flutter/font_awesome_flutter.dart';
import 'package:omi/backend/preferences.dart';
import 'package:omi/services/heypocket_service.dart';
import 'package:omi/services/omi_api_client.dart';

enum _ConnectionState { idle, checking, connected, error }

class IntegrationsPage extends StatefulWidget {
  const IntegrationsPage({super.key});

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
    if (!valid && mounted) {
      _prefs.omiSyncEnabled = false;
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
      _prefs.omiSyncEnabled = false;
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
        await _prefs.setOmiRefreshToken(rt);
        await _prefs.setOmiFirebaseApiKey(ak);
        setState(() => _omiState = _ConnectionState.connected);
      } else {
        _prefs.omiSyncEnabled = false;
        setState(() => _omiState = _ConnectionState.error);
      }
    } catch (_) {
      _prefs.omiSyncEnabled = false;
      setState(() => _omiState = _ConnectionState.error);
    }
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
        return Container(width: 10, height: 10, decoration: const BoxDecoration(color: Colors.green, shape: BoxShape.circle));
      case _ConnectionState.error:
        return Container(width: 10, height: 10, decoration: const BoxDecoration(color: Colors.redAccent, shape: BoxShape.circle));
      case _ConnectionState.idle:
        return Container(width: 10, height: 10, decoration: BoxDecoration(color: Colors.grey.shade600, shape: BoxShape.circle));
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
            subtitle: 'Sync processed recordings to your official Omi account',
            state: _omiState,
            enabled: _prefs.omiSyncEnabled,
            onEnabledChanged: (v) {
              _prefs.omiSyncEnabled = v;
              setState(() {});
            },
            fields: [
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
          ),
          const SizedBox(height: 16),

          // HeyPocket
          _buildIntegrationSection(
            title: 'HeyPocket',
            subtitle: 'Auto-upload new recordings matching your filters',
            state: _heypocketState,
            enabled: _prefs.heypocketEnabled,
            onEnabledChanged: (v) {
              _prefs.heypocketEnabled = v;
              setState(() {});
            },
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
    required List<Widget> fields,
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
            ],
          ),
          const SizedBox(height: 12),
          ...fields,
          const SizedBox(height: 12),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('Enabled', style: TextStyle(color: Colors.white, fontSize: 14)),
            subtitle: Text(
              subtitle,
              style: TextStyle(color: Colors.grey.shade500, fontSize: 12),
            ),
            value: enabled,
            activeColor: Colors.deepPurpleAccent,
            onChanged: isChecking || !isConnected ? null : onEnabledChanged,
          ),
        ],
      ),
    );
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
          tooltip: obscured ? 'Show key' : 'Hide key',
        ),
      ),
    );
  }
}
