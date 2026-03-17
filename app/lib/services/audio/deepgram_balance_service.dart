import 'dart:convert';
import 'package:http/http.dart' as http;

/// Holds the result of a successful balance query.
class DeepgramBalance {
  final double amountDollars;
  final String currency;

  const DeepgramBalance({required this.amountDollars, required this.currency});
}

/// Thrown when the API key lacks billing permissions (HTTP 403).
class DeepgramBillingPermissionException implements Exception {
  @override
  String toString() => 'DeepgramBillingPermissionException: '
      'API key does not have billing permissions. '
      'Check your balance at console.deepgram.com.';
}

/// Thrown when the API key is invalid (HTTP 401).
class DeepgramInvalidKeyException implements Exception {
  @override
  String toString() => 'DeepgramInvalidKeyException: Invalid API key.';
}

/// Fetches the remaining credit balance for a Deepgram account using the
/// official management API — no scraping required.
///
/// Flow:
///   1. GET /v1/projects → extract first project_id
///   2. GET /v1/projects/{id}/balances → parse amount_due / balance
///
/// Permission requirement: the API key must have Owner or Admin role.
/// Restricted (transcription-only) keys return HTTP 403 on billing endpoints.
class DeepgramBalanceService {
  static const String _baseUrl = 'https://api.deepgram.com/v1';

  static Future<DeepgramBalance> fetchBalance(String apiKey) async {
    final projectId = await _fetchProjectId(apiKey);
    return _fetchBalance(apiKey, projectId);
  }

  static Future<String> _fetchProjectId(String apiKey) async {
    final response = await http.get(
      Uri.parse('$_baseUrl/projects'),
      headers: {'Authorization': 'Token $apiKey'},
    );

    if (response.statusCode == 401) throw DeepgramInvalidKeyException();
    if (response.statusCode == 403) throw DeepgramBillingPermissionException();
    if (response.statusCode != 200) {
      throw Exception('Deepgram /projects returned HTTP ${response.statusCode}');
    }

    final json = jsonDecode(response.body) as Map<String, dynamic>;
    final projects = json['projects'] as List<dynamic>?;
    if (projects == null || projects.isEmpty) {
      throw Exception('No Deepgram projects found for this API key.');
    }
    final id = (projects[0] as Map<String, dynamic>)['project_id'] as String?;
    if (id == null || id.isEmpty) throw Exception('Could not read project_id from Deepgram response.');
    return id;
  }

  static Future<DeepgramBalance> _fetchBalance(String apiKey, String projectId) async {
    final response = await http.get(
      Uri.parse('$_baseUrl/projects/$projectId/balances'),
      headers: {'Authorization': 'Token $apiKey'},
    );

    if (response.statusCode == 401) throw DeepgramInvalidKeyException();
    if (response.statusCode == 403) throw DeepgramBillingPermissionException();
    if (response.statusCode != 200) {
      throw Exception('Deepgram /balances returned HTTP ${response.statusCode}');
    }

    final json = jsonDecode(response.body) as Map<String, dynamic>;
    final balances = json['balances'] as List<dynamic>?;
    if (balances == null || balances.isEmpty) {
      throw Exception('No balance entries in Deepgram response.');
    }

    final first = balances[0] as Map<String, dynamic>;
    // Deepgram returns "balance" as the remaining credit amount
    final amount = (first['balance'] as num?)?.toDouble() ?? 0.0;
    final currency = first['purchase_order_id'] as String? ?? 'USD'; // fallback
    // The actual currency field in the API is not documented — default USD
    return DeepgramBalance(amountDollars: amount, currency: 'USD');
  }
}
