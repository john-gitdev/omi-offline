import 'dart:async';

import 'package:flutter/material.dart';
import 'package:font_awesome_flutter/font_awesome_flutter.dart';
import 'package:omi/backend/preferences.dart';
import 'package:omi/services/heypocket_service.dart';

enum _ConnectionState { idle, checking, connected, error }

class IntegrationsPage extends StatefulWidget {
  const IntegrationsPage({super.key});

  @override
  State<IntegrationsPage> createState() => _IntegrationsPageState();
}

class _IntegrationsPageState extends State<IntegrationsPage> {
  final _prefs = SharedPreferencesUtil();
  final _controller = TextEditingController();
  bool _obscured = true;
  _ConnectionState _connState = _ConnectionState.idle;
  Timer? _debounce;

  @override
  void initState() {
    super.initState();
    final saved = _prefs.heypocketApiKey;
    _controller.text = saved;
    if (saved.isNotEmpty) {
      _connState = _ConnectionState.connected;
    }
    _controller.addListener(_onKeyChanged);
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _controller.removeListener(_onKeyChanged);
    _controller.dispose();
    super.dispose();
  }

  void _onKeyChanged() {
    final text = _controller.text;
    if (text.isEmpty) {
      _debounce?.cancel();
      _prefs.heypocketApiKey = '';
      _prefs.heypocketEnabled = false;
      setState(() => _connState = _ConnectionState.idle);
      return;
    }
    _debounce?.cancel();
    if (text.length <= 10 || !text.startsWith('pk_')) return;
    _debounce = Timer(const Duration(milliseconds: 800), () => _testKey(text));
  }

  Future<void> _testKey(String key) async {
    setState(() => _connState = _ConnectionState.checking);
    try {
      final result = await HeyPocketService.testConnection(key);
      if (_controller.text != key) return; // stale
      if (result) {
        _prefs.heypocketApiKey = key;
        setState(() => _connState = _ConnectionState.connected);
      } else {
        _prefs.heypocketEnabled = false;
        setState(() => _connState = _ConnectionState.error);
        if (mounted) {
          ScaffoldMessenger.of(context)
              .showSnackBar(const SnackBar(content: Text('HeyPocket: API key is invalid')));
        }
      }
    } on HeyPocketException catch (e) {
      if (_controller.text != key) return;
      _prefs.heypocketEnabled = false;
      setState(() => _connState = _ConnectionState.error);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('HeyPocket: ${e.message}')));
      }
    }
  }

  Widget _buildIndicator() {
    switch (_connState) {
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
    final isChecking = _connState == _ConnectionState.checking;

    return Scaffold(
      backgroundColor: const Color(0xFF0D0D0D),
      appBar: AppBar(
        backgroundColor: const Color(0xFF0D0D0D),
        elevation: 0,
        leading: IconButton(
          icon: const FaIcon(FontAwesomeIcons.chevronLeft, size: 18),
          onPressed: () => Navigator.of(context).pop(),
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
          Container(
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
                    const Text(
                      'HeyPocket',
                      style: TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.w600),
                    ),
                    const SizedBox(width: 8),
                    _buildIndicator(),
                  ],
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: _controller,
                  obscureText: _obscured,
                  style: const TextStyle(color: Colors.white),
                  decoration: InputDecoration(
                    hintText: 'API key (pk_...)',
                    hintStyle: TextStyle(color: Colors.grey.shade600),
                    filled: true,
                    fillColor: const Color(0xFF2C2C2E),
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(10),
                      borderSide: BorderSide.none,
                    ),
                    suffixIcon: IconButton(
                      icon: FaIcon(
                        _obscured ? FontAwesomeIcons.eye : FontAwesomeIcons.eyeSlash,
                        size: 16,
                        color: Colors.grey,
                      ),
                      onPressed: () => setState(() => _obscured = !_obscured),
                    ),
                  ),
                ),
                const SizedBox(height: 12),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('Auto-upload new recordings', style: TextStyle(color: Colors.white, fontSize: 14)),
                  subtitle: Text(
                    'Recordings matching your duration filter will be sent automatically',
                    style: TextStyle(color: Colors.grey.shade500, fontSize: 12),
                  ),
                  value: _prefs.heypocketEnabled,
                  activeColor: Colors.deepPurpleAccent,
                  onChanged: isChecking || _connState != _ConnectionState.connected
                      ? null
                      : (v) {
                          _prefs.heypocketEnabled = v;
                          setState(() {});
                        },
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
