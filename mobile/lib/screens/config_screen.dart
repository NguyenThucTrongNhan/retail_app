import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;

import '../config/app_config.dart';

/// Lets staff set the shop PC's IP address once.
/// Both the Fastify sync server (port 8080) and the Python vision service
/// (port 8081) are derived automatically from that single IP.
///
/// Access via the gear icon on the Sync tab.
class ConfigScreen extends StatefulWidget {
  const ConfigScreen({super.key});

  @override
  State<ConfigScreen> createState() => _ConfigScreenState();
}

class _ConfigScreenState extends State<ConfigScreen> {
  final _ipCtrl = TextEditingController();
  bool _isTesting = false;
  String? _testResult;
  bool _testOk = false;

  @override
  void initState() {
    super.initState();
    AppConfig.getServerIp().then((ip) {
      if (mounted) _ipCtrl.text = ip;
    });
  }

  @override
  void dispose() {
    _ipCtrl.dispose();
    super.dispose();
  }

  String get _syncUrl => 'http://${_ipCtrl.text}:8080/api/v1';
  String get _visionUrl => 'http://${_ipCtrl.text}:8081';

  Future<void> _testConnection() async {
    setState(() { _isTesting = true; _testResult = null; });
    try {
      final response = await http
          .get(Uri.parse('http://${_ipCtrl.text}:8080/health'))
          .timeout(const Duration(seconds: 5));
      if (response.statusCode == 200) {
        setState(() { _testOk = true; _testResult = 'Sync server reachable'; });
      } else {
        setState(() { _testOk = false; _testResult = 'Server returned HTTP ${response.statusCode}'; });
      }
    } catch (e) {
      setState(() { _testOk = false; _testResult = 'Unreachable: $e'; });
    } finally {
      setState(() => _isTesting = false);
    }
  }

  Future<void> _save() async {
    final ip = _ipCtrl.text.trim();
    if (ip.isEmpty) return;
    await AppConfig.setServerIp(ip);
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Server IP saved.')),
      );
      Navigator.pop(context);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Server Configuration')),
      body: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Shop Server IP / Hostname',
              style: TextStyle(fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 8),
            TextField(
              controller: _ipCtrl,
              decoration: const InputDecoration(
                hintText: 'e.g. 192.168.1.50',
                border: OutlineInputBorder(),
                prefixIcon: Icon(Icons.dns_outlined),
              ),
              keyboardType: TextInputType.url,
              onChanged: (_) => setState(() { _testResult = null; }),
            ),
            const SizedBox(height: 20),
            const Text('Derived endpoints:', style: TextStyle(color: Colors.grey, fontSize: 12)),
            const SizedBox(height: 4),
            _urlRow(Icons.sync, 'Sync API', _syncUrl),
            const SizedBox(height: 4),
            _urlRow(Icons.camera_alt_outlined, 'Vision AI', _visionUrl),
            const SizedBox(height: 24),

            // Connection test
            OutlinedButton.icon(
              onPressed: _isTesting ? null : _testConnection,
              icon: _isTesting
                  ? const SizedBox(width: 16, height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2))
                  : const Icon(Icons.wifi_tethering),
              label: Text(_isTesting ? 'Testing…' : 'Test Connection'),
            ),
            if (_testResult != null) ...[
              const SizedBox(height: 8),
              Row(
                children: [
                  Icon(
                    _testOk ? Icons.check_circle : Icons.error_outline,
                    color: _testOk ? Colors.green : Colors.red,
                    size: 18,
                  ),
                  const SizedBox(width: 6),
                  Expanded(child: Text(_testResult!,
                      style: TextStyle(
                          color: _testOk ? Colors.green : Colors.red))),
                ],
              ),
            ],
            const Spacer(),

            // Quick-reference hints
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: Colors.indigo.shade50,
                borderRadius: BorderRadius.circular(8),
              ),
              child: const Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('Quick reference', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 12)),
                  SizedBox(height: 4),
                  Text('• Same machine (web / USB cable):  localhost', style: TextStyle(fontSize: 12)),
                  Text('• Android emulator:  10.0.2.2', style: TextStyle(fontSize: 12)),
                  Text('• Physical phone on shop Wi-Fi:  192.168.x.x', style: TextStyle(fontSize: 12)),
                ],
              ),
            ),
            const SizedBox(height: 16),
            ElevatedButton(
              style: ElevatedButton.styleFrom(
                minimumSize: const Size.fromHeight(50),
                backgroundColor: Colors.indigo,
                foregroundColor: Colors.white,
              ),
              onPressed: _save,
              child: const Text('Save & Close'),
            ),
          ],
        ),
      ),
    );
  }

  Widget _urlRow(IconData icon, String label, String url) {
    return Row(
      children: [
        Icon(icon, size: 14, color: Colors.grey),
        const SizedBox(width: 6),
        Text('$label: ', style: const TextStyle(fontSize: 12, color: Colors.grey)),
        Flexible(
          child: Text(url,
              style: const TextStyle(fontSize: 12, fontFamily: 'monospace'),
              overflow: TextOverflow.ellipsis),
        ),
      ],
    );
  }
}
