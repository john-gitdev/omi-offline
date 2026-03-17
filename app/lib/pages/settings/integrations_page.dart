import 'package:flutter/material.dart';
import 'package:font_awesome_flutter/font_awesome_flutter.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:omi/backend/preferences.dart';
import 'package:omi/services/audio/deepgram_balance_service.dart';
import 'package:omi/services/audio/deepgram_transcription_service.dart';

class IntegrationsPage extends StatefulWidget {
  const IntegrationsPage({super.key});

  @override
  State<IntegrationsPage> createState() => _IntegrationsPageState();
}

class _IntegrationsPageState extends State<IntegrationsPage> {
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
        ),
        title: const Text(
          'Integrations',
          style: TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.w600),
        ),
        centerTitle: true,
      ),
      body: ListView(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        children: const [
          _DeepgramIntegrationCard(),
          SizedBox(height: 24),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Deepgram integration card
// ---------------------------------------------------------------------------

class _DeepgramIntegrationCard extends StatefulWidget {
  const _DeepgramIntegrationCard();

  @override
  State<_DeepgramIntegrationCard> createState() => _DeepgramIntegrationCardState();
}

class _DeepgramIntegrationCardState extends State<_DeepgramIntegrationCard> {
  late bool _enabled;
  late bool _fallbackToVad;
  late int _splitGapSeconds;
  late TextEditingController _apiKeyController;
  bool _apiKeyObscured = true;

  // Balance check state
  bool _balanceLoading = false;
  String? _balanceText;
  String? _balanceError;

  @override
  void initState() {
    super.initState();
    final prefs = SharedPreferencesUtil();
    _enabled = prefs.deepgramEnabled;
    _fallbackToVad = prefs.deepgramFallbackToVad;
    _splitGapSeconds = prefs.deepgramSplitGapSeconds;
    _apiKeyController = TextEditingController();
    prefs.readDeepgramApiKey().then((key) {
      if (mounted) setState(() => _apiKeyController.text = key);
    });
  }

  @override
  void dispose() {
    _apiKeyController.dispose();
    super.dispose();
  }

  void _saveApiKey(String value) {
    SharedPreferencesUtil().writeDeepgramApiKey(value);
    // Reset balance display when key changes
    setState(() {
      _balanceText = null;
      _balanceError = null;
    });
  }

  void _toggleEnabled(bool value) {
    setState(() => _enabled = value);
    SharedPreferencesUtil().deepgramEnabled = value;
  }

  void _toggleFallback(bool value) {
    setState(() => _fallbackToVad = value);
    SharedPreferencesUtil().deepgramFallbackToVad = value;
  }

  void _setSplitGap(double value) {
    final seconds = value.round();
    setState(() => _splitGapSeconds = seconds);
    SharedPreferencesUtil().deepgramSplitGapSeconds = seconds;
  }

  Future<void> _checkBalance() async {
    final apiKey = _apiKeyController.text.trim();
    if (apiKey.isEmpty) {
      setState(() => _balanceError = 'Enter an API key first.');
      return;
    }
    setState(() {
      _balanceLoading = true;
      _balanceText = null;
      _balanceError = null;
    });
    try {
      final balance = await DeepgramBalanceService.fetchBalance(apiKey);
      if (mounted) {
        setState(() {
          _balanceLoading = false;
          _balanceText = '\$${balance.amountDollars.toStringAsFixed(2)} ${balance.currency} remaining';
        });
      }
    } on DeepgramBillingPermissionException {
      if (mounted) {
        setState(() {
          _balanceLoading = false;
          _balanceError = 'billing_permission';
        });
      }
    } on DeepgramInvalidKeyException {
      if (mounted) {
        setState(() {
          _balanceLoading = false;
          _balanceError = 'Invalid API key.';
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _balanceLoading = false;
          _balanceError = 'Could not reach Deepgram.';
        });
      }
    }
  }

  String _overlapLabel(int gapSeconds) {
    final overlap = DeepgramTranscriptionService.computeOverlap(gapSeconds);
    final mins = overlap.inSeconds ~/ 60;
    final secs = overlap.inSeconds % 60;
    if (secs == 0) return '${mins}m overlap';
    return '${mins}m ${secs}s overlap';
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: const Color(0xFF1C1C1E),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
          color: _enabled ? Colors.deepPurpleAccent.withValues(alpha: 0.4) : Colors.transparent,
          width: 1.5,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Header
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
            child: Row(
              children: [
                Container(
                  width: 36,
                  height: 36,
                  decoration: BoxDecoration(
                    color: Colors.deepPurpleAccent.withValues(alpha: 0.15),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: const Center(
                    child: FaIcon(FontAwesomeIcons.waveSquare, color: Colors.deepPurpleAccent, size: 18),
                  ),
                ),
                const SizedBox(width: 12),
                const Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Deepgram',
                        style: TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.w600),
                      ),
                      Text(
                        'AI-powered conversation splitting & transcription',
                        style: TextStyle(color: Color(0xFF8E8E93), fontSize: 12),
                      ),
                    ],
                  ),
                ),
                Switch(
                  value: _enabled,
                  onChanged: _toggleEnabled,
                  activeColor: Colors.deepPurpleAccent,
                ),
              ],
            ),
          ),

          const Padding(
            padding: EdgeInsets.symmetric(horizontal: 16, vertical: 12),
            child: Divider(color: Color(0xFF2C2C2E), height: 1),
          ),

          // API key field
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    const Text('API Key', style: TextStyle(color: Color(0xFF8E8E93), fontSize: 13)),
                    const Spacer(),
                    GestureDetector(
                      onTap: () => launchUrl(Uri.parse('https://console.deepgram.com/')),
                      child: const Text(
                        'Get API Key →',
                        style: TextStyle(color: Colors.deepPurpleAccent, fontSize: 12),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                TextField(
                  key: const Key('deepgram_api_key_field'),
                  controller: _apiKeyController,
                  obscureText: _apiKeyObscured,
                  style: const TextStyle(color: Colors.white, fontSize: 14, fontFamily: 'monospace'),
                  decoration: InputDecoration(
                    hintText: 'xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx',
                    hintStyle: TextStyle(color: Colors.grey.shade700, fontSize: 13),
                    filled: true,
                    fillColor: const Color(0xFF0D0D0D),
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(8),
                      borderSide: BorderSide(color: Colors.grey.shade800),
                    ),
                    enabledBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(8),
                      borderSide: BorderSide(color: Colors.grey.shade800),
                    ),
                    focusedBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(8),
                      borderSide: const BorderSide(color: Colors.deepPurpleAccent),
                    ),
                    contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                    suffixIcon: IconButton(
                      icon: FaIcon(
                        _apiKeyObscured ? FontAwesomeIcons.eye : FontAwesomeIcons.eyeSlash,
                        color: Colors.grey.shade600,
                        size: 16,
                      ),
                      onPressed: () => setState(() => _apiKeyObscured = !_apiKeyObscured),
                    ),
                  ),
                  onChanged: _saveApiKey,
                ),
              ],
            ),
          ),

          const SizedBox(height: 12),

          // Check Balance button + result
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Row(
              children: [
                OutlinedButton(
                  key: const Key('deepgram_check_balance'),
                  onPressed: _balanceLoading ? null : _checkBalance,
                  style: OutlinedButton.styleFrom(
                    foregroundColor: Colors.deepPurpleAccent,
                    side: const BorderSide(color: Colors.deepPurpleAccent, width: 1),
                    padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                    minimumSize: Size.zero,
                    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  ),
                  child: _balanceLoading
                      ? const SizedBox(
                          width: 14,
                          height: 14,
                          child: CircularProgressIndicator(strokeWidth: 2, color: Colors.deepPurpleAccent),
                        )
                      : const Text('Check Balance', style: TextStyle(fontSize: 13)),
                ),
                const SizedBox(width: 12),
                if (_balanceText != null)
                  Text(_balanceText!, style: const TextStyle(color: Colors.green, fontSize: 13))
                else if (_balanceError == 'billing_permission')
                  Expanded(
                    child: Tooltip(
                      message: 'Your API key doesn\'t have billing permissions.\n'
                          'Please check your balance on console.deepgram.com.',
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          const FaIcon(FontAwesomeIcons.circleInfo, color: Colors.orange, size: 14),
                          const SizedBox(width: 6),
                          Text(
                            'No billing access',
                            style: TextStyle(color: Colors.orange.shade300, fontSize: 13),
                          ),
                        ],
                      ),
                    ),
                  )
                else if (_balanceError != null)
                  Text(_balanceError!, style: TextStyle(color: Colors.red.shade400, fontSize: 13)),
              ],
            ),
          ),

          const Padding(
            padding: EdgeInsets.symmetric(horizontal: 16, vertical: 12),
            child: Divider(color: Color(0xFF2C2C2E), height: 1),
          ),

          // Split gap slider
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    const Text('Conversation Split Gap', style: TextStyle(color: Color(0xFF8E8E93), fontSize: 13)),
                    Column(
                      crossAxisAlignment: CrossAxisAlignment.end,
                      children: [
                        Text(
                          _splitGapSeconds == 0 ? 'Immediate' : '${_splitGapSeconds}s gap',
                          style: const TextStyle(color: Colors.white, fontSize: 14, fontWeight: FontWeight.w500),
                        ),
                        Text(
                          _overlapLabel(_splitGapSeconds),
                          style: const TextStyle(color: Colors.deepPurpleAccent, fontSize: 11),
                        ),
                      ],
                    ),
                  ],
                ),
                const SizedBox(height: 4),
                SliderTheme(
                  data: SliderTheme.of(context).copyWith(
                    thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 7),
                    trackHeight: 3,
                    overlayShape: const RoundSliderOverlayShape(overlayRadius: 14),
                    activeTrackColor: Colors.deepPurpleAccent,
                    inactiveTrackColor: const Color(0xFF3A3A3C),
                    thumbColor: Colors.deepPurpleAccent,
                    overlayColor: Colors.deepPurpleAccent.withValues(alpha: 0.2),
                  ),
                  child: Slider(
                    key: const Key('deepgram_split_gap_slider'),
                    value: _splitGapSeconds.toDouble(),
                    min: 0,
                    max: 600,
                    divisions: 60,
                    onChanged: _setSplitGap,
                  ),
                ),
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Text('0s', style: TextStyle(color: Colors.grey.shade600, fontSize: 11)),
                    Text('10 min', style: TextStyle(color: Colors.grey.shade600, fontSize: 11)),
                  ],
                ),
              ],
            ),
          ),

          const Padding(
            padding: EdgeInsets.symmetric(horizontal: 16, vertical: 12),
            child: Divider(color: Color(0xFF2C2C2E), height: 1),
          ),

          // Fallback option
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text('When Deepgram is Unreachable', style: TextStyle(color: Color(0xFF8E8E93), fontSize: 13)),
                const SizedBox(height: 10),
                _FallbackOption(
                  key: const Key('deepgram_fallback_vad'),
                  selected: _fallbackToVad,
                  icon: FontAwesomeIcons.waveform,
                  label: 'Fall back to VAD immediately',
                  subtitle: 'Use energy-based silence detection offline',
                  onTap: () => _toggleFallback(true),
                ),
                const SizedBox(height: 8),
                _FallbackOption(
                  key: const Key('deepgram_fallback_queue'),
                  selected: !_fallbackToVad,
                  icon: FontAwesomeIcons.clockRotateLeft,
                  label: 'Queue and retry when online',
                  subtitle: 'Wait for connectivity, then smart-split',
                  onTap: () => _toggleFallback(false),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _FallbackOption extends StatelessWidget {
  final bool selected;
  final IconData icon;
  final String label;
  final String subtitle;
  final VoidCallback onTap;

  const _FallbackOption({
    super.key,
    required this.selected,
    required this.icon,
    required this.label,
    required this.subtitle,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 150),
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: selected ? Colors.deepPurpleAccent.withValues(alpha: 0.12) : const Color(0xFF0D0D0D),
          borderRadius: BorderRadius.circular(10),
          border: Border.all(
            color: selected ? Colors.deepPurpleAccent : const Color(0xFF3A3A3C),
            width: 1.5,
          ),
        ),
        child: Row(
          children: [
            FaIcon(icon, color: selected ? Colors.deepPurpleAccent : Colors.grey.shade500, size: 18),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    label,
                    style: TextStyle(
                      color: selected ? Colors.white : Colors.grey.shade400,
                      fontSize: 14,
                      fontWeight: selected ? FontWeight.w500 : FontWeight.normal,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(subtitle, style: TextStyle(color: Colors.grey.shade600, fontSize: 12)),
                ],
              ),
            ),
            if (selected)
              const FaIcon(FontAwesomeIcons.circleCheck, color: Colors.deepPurpleAccent, size: 16),
          ],
        ),
      ),
    );
  }
}
