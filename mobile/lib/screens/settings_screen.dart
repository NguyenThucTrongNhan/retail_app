import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;

import '../config/app_config.dart';
import '../services/database_helper.dart';

class SettingsScreen extends StatefulWidget {
  final ValueChanged<ThemeMode> onThemeChanged;
  const SettingsScreen({super.key, required this.onThemeChanged});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  final _urlCtrl = TextEditingController();

  // Store profile
  String _storeName = '';
  String _currencySymbol = r'$';

  // Server
  bool _isTesting = false;
  String? _testResult;
  bool _testOk = false;

  // Sync
  bool _autoSyncOnStart = false;

  // Appearance
  ThemeMode _themeMode = ThemeMode.system;
  int _productsPerPage = 30;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _urlCtrl.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final results = await Future.wait([
      AppConfig.getServerUrl(),
      AppConfig.getStoreName(),
      AppConfig.getCurrencySymbol(),
      AppConfig.getAutoSyncOnStart(),
      AppConfig.getThemeMode(),
      AppConfig.getProductsPerPage(),
    ]);
    if (!mounted) return;
    setState(() {
      _urlCtrl.text = results[0] as String;
      _storeName = results[1] as String;
      _currencySymbol = results[2] as String;
      _autoSyncOnStart = results[3] as bool;
      _themeMode = results[4] as ThemeMode;
      _productsPerPage = results[5] as int;
    });
  }

  // ---------------------------------------------------------------------------
  // Server
  // ---------------------------------------------------------------------------
  Future<void> _testConnection() async {
    setState(() {
      _isTesting = true;
      _testResult = null;
    });
    try {
      final base = _urlCtrl.text.trim().replaceAll(RegExp(r'/$'), '');
      final response = await http
          .get(Uri.parse('$base/health'))
          .timeout(const Duration(seconds: 5));
      setState(() {
        _testOk = response.statusCode == 200;
        _testResult = _testOk
            ? 'Server reachable'
            : 'Server returned HTTP ${response.statusCode}';
      });
    } catch (e) {
      setState(() {
        _testOk = false;
        _testResult = 'Unreachable: $e';
      });
    } finally {
      setState(() => _isTesting = false);
    }
  }

  Future<void> _saveUrl() async {
    final url = _urlCtrl.text.trim();
    if (url.isEmpty) return;
    await AppConfig.setServerUrl(url);
    if (mounted) {
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('Server URL saved')));
    }
  }

  // ---------------------------------------------------------------------------
  // Dialogs
  // ---------------------------------------------------------------------------
  Future<void> _editTextField(
    String title,
    String current,
    Future<void> Function(String) onSave, {
    TextInputType keyboard = TextInputType.text,
  }) async {
    final ctrl = TextEditingController(text: current);
    final result = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(title),
        content: TextField(
          controller: ctrl,
          autofocus: true,
          keyboardType: keyboard,
          decoration: const InputDecoration(border: OutlineInputBorder()),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('Cancel')),
          ElevatedButton(
            onPressed: () => Navigator.pop(ctx, ctrl.text.trim()),
            child: const Text('Save'),
          ),
        ],
      ),
    );
    ctrl.dispose();
    if (result != null && result.isNotEmpty) await onSave(result);
  }

  Future<void> _pickTheme() async {
    final picked = await showDialog<ThemeMode>(
      context: context,
      builder: (ctx) => SimpleDialog(
        title: const Text('Theme'),
        children: [
          _themeOption(ctx, ThemeMode.system, 'System default'),
          _themeOption(ctx, ThemeMode.light, 'Light'),
          _themeOption(ctx, ThemeMode.dark, 'Dark'),
        ],
      ),
    );
    if (picked != null) {
      await AppConfig.setThemeMode(picked);
      setState(() => _themeMode = picked);
      widget.onThemeChanged(picked);
    }
  }

  Widget _themeOption(BuildContext ctx, ThemeMode mode, String label) {
    return SimpleDialogOption(
      onPressed: () => Navigator.pop(ctx, mode),
      child: Row(
        children: [
          Icon(
            _themeMode == mode
                ? Icons.radio_button_checked
                : Icons.radio_button_off,
            color: Theme.of(ctx).colorScheme.primary,
          ),
          const SizedBox(width: 10),
          Text(label),
        ],
      ),
    );
  }

  Future<void> _pickPerPage() async {
    const options = [20, 30, 50];
    final picked = await showDialog<int>(
      context: context,
      builder: (ctx) => SimpleDialog(
        title: const Text('Products per page'),
        children: options
            .map((n) => SimpleDialogOption(
                  onPressed: () => Navigator.pop(ctx, n),
                  child: Row(
                    children: [
                      Icon(
                        _productsPerPage == n
                            ? Icons.radio_button_checked
                            : Icons.radio_button_off,
                        color: Theme.of(ctx).colorScheme.primary,
                      ),
                      const SizedBox(width: 10),
                      Text('$n items'),
                    ],
                  ),
                ))
            .toList(),
      ),
    );
    if (picked != null) {
      await AppConfig.setProductsPerPage(picked);
      setState(() => _productsPerPage = picked);
    }
  }

  Future<void> _confirmClearData() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Clear local data?'),
        content: const Text(
          'This deletes all locally synced products and categories. '
          'Run sync again to restore them.',
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancel')),
          ElevatedButton(
            style: ElevatedButton.styleFrom(
                backgroundColor: Colors.red, foregroundColor: Colors.white),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Clear'),
          ),
        ],
      ),
    );
    if (confirmed == true && mounted) {
      await DatabaseHelper.instance.clearLocalData();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('Local data cleared. Run sync to restore products.'),
        ));
      }
    }
  }

  // ---------------------------------------------------------------------------
  // Build
  // ---------------------------------------------------------------------------
  String get _themeModeLabel => switch (_themeMode) {
        ThemeMode.light => 'Light',
        ThemeMode.dark => 'Dark',
        _ => 'System default',
      };

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;

    return Scaffold(
      appBar: AppBar(title: const Text('Settings')),
      body: ListView(
        padding: const EdgeInsets.symmetric(vertical: 8),
        children: [
          // ── Store Profile ────────────────────────────────────────────────
          _sectionHeader('Store Profile', cs),
          _tile(
            icon: Icons.storefront_outlined,
            title: 'Store name',
            subtitle: _storeName.isEmpty ? 'Tap to set' : _storeName,
            onTap: () => _editTextField('Store name', _storeName, (v) async {
              await AppConfig.setStoreName(v);
              setState(() => _storeName = v);
            }),
          ),
          _tile(
            icon: Icons.attach_money,
            title: 'Currency symbol',
            subtitle: _currencySymbol,
            onTap: () =>
                _editTextField('Currency symbol', _currencySymbol, (v) async {
              await AppConfig.setCurrencySymbol(v);
              setState(() => _currencySymbol = v);
            }),
          ),

          // ── Server ──────────────────────────────────────────────────────
          _sectionHeader('Server', cs),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
            child: TextField(
              controller: _urlCtrl,
              decoration: InputDecoration(
                labelText: 'Server URL',
                hintText: 'https://retail.yourdomain.com',
                border: const OutlineInputBorder(),
                prefixIcon: const Icon(Icons.dns_outlined),
                suffixIcon: IconButton(
                  icon: const Icon(Icons.save_outlined),
                  tooltip: 'Save URL',
                  onPressed: _saveUrl,
                ),
              ),
              keyboardType: TextInputType.url,
              autocorrect: false,
              onChanged: (_) => setState(() => _testResult = null),
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 2),
            child: OutlinedButton.icon(
              onPressed: _isTesting ? null : _testConnection,
              icon: _isTesting
                  ? const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2))
                  : const Icon(Icons.wifi_tethering),
              label: Text(_isTesting ? 'Testing…' : 'Test Connection'),
            ),
          ),
          if (_testResult != null)
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 4, 20, 0),
              child: Row(
                children: [
                  Icon(
                    _testOk ? Icons.check_circle : Icons.error_outline,
                    color: _testOk ? Colors.green : Colors.red,
                    size: 16,
                  ),
                  const SizedBox(width: 6),
                  Flexible(
                    child: Text(
                      _testResult!,
                      style: TextStyle(
                          fontSize: 13,
                          color: _testOk ? Colors.green : Colors.red),
                    ),
                  ),
                ],
              ),
            ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 10, 16, 4),
            child: Container(
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: cs.primaryContainer.withOpacity(0.3),
                borderRadius: BorderRadius.circular(8),
              ),
              child: const Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('Quick reference',
                      style:
                          TextStyle(fontWeight: FontWeight.bold, fontSize: 12)),
                  SizedBox(height: 4),
                  Text('• Production:   https://retail.yourdomain.com',
                      style: TextStyle(fontSize: 12)),
                  Text('• Android emulator (dev):   http://10.0.2.2',
                      style: TextStyle(fontSize: 12)),
                  Text('• LAN dev:   http://192.168.x.x',
                      style: TextStyle(fontSize: 12)),
                ],
              ),
            ),
          ),

          // ── Sync ────────────────────────────────────────────────────────
          _sectionHeader('Sync', cs),
          SwitchListTile(
            secondary: const Icon(Icons.sync),
            title: const Text('Auto-sync on app start'),
            subtitle: const Text('Runs delta sync each time the app opens'),
            value: _autoSyncOnStart,
            onChanged: (v) async {
              await AppConfig.setAutoSyncOnStart(v);
              setState(() => _autoSyncOnStart = v);
            },
          ),
          _tile(
            icon: Icons.delete_sweep_outlined,
            title: 'Clear local product data',
            subtitle: 'Removes all products and categories — re-sync required',
            iconColor: Colors.red,
            onTap: _confirmClearData,
          ),

          // ── Appearance ──────────────────────────────────────────────────
          _sectionHeader('Appearance', cs),
          _tile(
            icon: Icons.brightness_6_outlined,
            title: 'Theme',
            subtitle: _themeModeLabel,
            onTap: _pickTheme,
          ),
          _tile(
            icon: Icons.format_list_numbered_outlined,
            title: 'Products per page',
            subtitle: '$_productsPerPage items',
            onTap: _pickPerPage,
          ),

          // ── About ───────────────────────────────────────────────────────
          _sectionHeader('About', cs),
          _tile(
            icon: Icons.info_outline,
            title: 'App version',
            subtitle: '1.0.0 (build 1)',
            onTap: null,
          ),
          const SizedBox(height: 24),
        ],
      ),
    );
  }

  Widget _sectionHeader(String label, ColorScheme cs) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 20, 16, 4),
      child: Text(
        label.toUpperCase(),
        style: TextStyle(
          fontSize: 11,
          fontWeight: FontWeight.w700,
          letterSpacing: 1.1,
          color: cs.primary,
        ),
      ),
    );
  }

  Widget _tile({
    required IconData icon,
    required String title,
    required String subtitle,
    Color? iconColor,
    required VoidCallback? onTap,
  }) {
    return ListTile(
      leading: Icon(icon, color: iconColor),
      title: Text(title),
      subtitle: Text(subtitle),
      trailing:
          onTap != null ? const Icon(Icons.chevron_right, size: 18) : null,
      onTap: onTap,
    );
  }
}
