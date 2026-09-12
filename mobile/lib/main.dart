import 'package:flutter/material.dart';

import 'config/app_config.dart';
import 'models/product.dart';
import 'screens/login_screen.dart';
import 'screens/settings_screen.dart';
import 'screens/visual_search_screen.dart';
import 'services/auth_service.dart';
import 'services/database_helper.dart';
import 'services/sync_service.dart';
import 'widgets/barcode_scanner_modal.dart';

// ---------------------------------------------------------------------------
// Server URL configured in Settings tab. All services (auth, sync, vision)
// are accessed through a single Nginx reverse proxy URL.
// ---------------------------------------------------------------------------

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await AuthService.instance.init(); // rehydrate tokens from secure storage
  runApp(const RetailApp());
}

class RetailApp extends StatefulWidget {
  const RetailApp({super.key});

  @override
  State<RetailApp> createState() => _RetailAppState();
}

class _RetailAppState extends State<RetailApp> {
  ThemeMode _themeMode = ThemeMode.system;
  bool _isAuthenticated = AuthService.instance.isAuthenticated;

  @override
  void initState() {
    super.initState();
    AppConfig.getThemeMode().then((mode) {
      if (mounted) setState(() => _themeMode = mode);
    });
  }

  void _onLoginSuccess() => setState(() => _isAuthenticated = true);
  void _onLogout()       => setState(() => _isAuthenticated = false);

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Store Retail POS',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(useMaterial3: true, colorSchemeSeed: Colors.indigo),
      darkTheme: ThemeData(
        useMaterial3: true,
        colorSchemeSeed: Colors.indigo,
        brightness: Brightness.dark,
      ),
      themeMode: _themeMode,
      home: _isAuthenticated
          ? MainNavigationScreen(
              onThemeChanged: (mode) => setState(() => _themeMode = mode),
              onLogout: _onLogout,
            )
          : LoginScreen(onLoginSuccess: _onLoginSuccess),
    );
  }
}

// ===========================================================================
// MAIN TAB NAVIGATOR
// ===========================================================================
class MainNavigationScreen extends StatefulWidget {
  final ValueChanged<ThemeMode> onThemeChanged;
  final VoidCallback onLogout;
  const MainNavigationScreen({
    super.key,
    required this.onThemeChanged,
    required this.onLogout,
  });

  @override
  State<MainNavigationScreen> createState() => _MainNavigationScreenState();
}

class _MainNavigationScreenState extends State<MainNavigationScreen> {
  int _currentIndex = 0;
  final List<Product> _basket = [];

  void _addToBasket(Product product) {
    setState(() => _basket.add(product));
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text('Added ${product.name} to basket'),
      duration: const Duration(seconds: 1),
    ));
  }

  @override
  Widget build(BuildContext context) {
    final screens = [
      CatalogSearchScreen(onAddToBasket: _addToBasket),
      VisualSearchScreen(onAddToBasket: _addToBasket),
      BasketCalculatorScreen(
        basket: _basket,
        onClearBasket: () => setState(() => _basket.clear()),
      ),
      SyncControlScreen(onLogout: widget.onLogout),
      SettingsScreen(onThemeChanged: widget.onThemeChanged),
    ];

    return Scaffold(
      body: IndexedStack(index: _currentIndex, children: screens),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _currentIndex,
        onDestinationSelected: (i) => setState(() => _currentIndex = i),
        destinations: [
          const NavigationDestination(icon: Icon(Icons.search), label: 'Catalog'),
          const NavigationDestination(icon: Icon(Icons.camera_alt), label: 'Lens Search'),
          NavigationDestination(
            icon: Badge(
              label: Text('${_basket.length}'),
              isLabelVisible: _basket.isNotEmpty,
              child: const Icon(Icons.calculate_outlined),
            ),
            label: 'Calculator',
          ),
          const NavigationDestination(icon: Icon(Icons.sync), label: 'Sync'),
          const NavigationDestination(
              icon: Icon(Icons.settings_outlined), label: 'Settings'),
        ],
      ),
    );
  }
}

// ===========================================================================
// TAB 1 — CATALOG SEARCH
// ===========================================================================
class CatalogSearchScreen extends StatefulWidget {
  final void Function(Product) onAddToBasket;
  const CatalogSearchScreen({super.key, required this.onAddToBasket});

  @override
  State<CatalogSearchScreen> createState() => _CatalogSearchScreenState();
}

class _CatalogSearchScreenState extends State<CatalogSearchScreen> {
  final TextEditingController _searchCtrl = TextEditingController();
  final ScrollController _scrollCtrl = ScrollController();
  List<Product> _products = [];
  bool _isLoading = true;
  bool _isLoadingMore = false;
  bool _hasMore = true;
  int _currentOffset = 0;
  int _searchGeneration = 0;
  int _pageSize = 30;

  @override
  void initState() {
    super.initState();
    _scrollCtrl.addListener(_onScroll);
    AppConfig.getProductsPerPage().then((n) {
      if (mounted) setState(() => _pageSize = n);
      _refresh();
    });
  }

  @override
  void dispose() {
    _scrollCtrl.dispose();
    _searchCtrl.dispose();
    super.dispose();
  }

  void _onScroll() {
    if (_scrollCtrl.position.pixels >=
        _scrollCtrl.position.maxScrollExtent - 200) {
      _loadMore();
    }
  }

  Future<void> _refresh() async {
    _searchGeneration++;
    final generation = _searchGeneration;
    setState(() {
      _isLoading = true;
      _currentOffset = 0;
      _hasMore = true;
      _products = [];
    });
    final results = await DatabaseHelper.instance.searchProducts(
      _searchCtrl.text,
      limit: _pageSize,
      offset: 0,
    );
    if (!mounted || generation != _searchGeneration) return;
    setState(() {
      _products = results;
      _currentOffset = results.length;
      _hasMore = results.length == _pageSize;
      _isLoading = false;
    });
  }

  Future<void> _loadMore() async {
    if (_isLoadingMore || !_hasMore || _isLoading) return;
    final generation = _searchGeneration;
    setState(() => _isLoadingMore = true);
    final results = await DatabaseHelper.instance.searchProducts(
      _searchCtrl.text,
      limit: _pageSize,
      offset: _currentOffset,
    );
    if (!mounted || generation != _searchGeneration) {
      if (mounted) setState(() => _isLoadingMore = false);
      return;
    }
    setState(() {
      _products.addAll(results);
      _currentOffset += results.length;
      _hasMore = results.length == _pageSize;
      _isLoadingMore = false;
    });
  }

  void _showEditModal(Product product) {
    final priceCtrl =
        TextEditingController(text: product.price.toStringAsFixed(2));
    final stockCtrl =
        TextEditingController(text: product.stockQuantity.toString());

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
      builder: (ctx) => Padding(
        padding: EdgeInsets.only(
          bottom: MediaQuery.of(ctx).viewInsets.bottom + 20,
          top: 20, left: 20, right: 20,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(product.name,
                style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
            Text('SKU: ${product.sku}',
                style: const TextStyle(color: Colors.grey)),
            const SizedBox(height: 16),
            TextField(
              controller: priceCtrl,
              decoration: const InputDecoration(
                  labelText: 'Selling Price (\$)', border: OutlineInputBorder()),
              keyboardType:
                  const TextInputType.numberWithOptions(decimal: true),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: stockCtrl,
              decoration: const InputDecoration(
                  labelText: 'Stock Quantity', border: OutlineInputBorder()),
              keyboardType: TextInputType.number,
            ),
            const SizedBox(height: 20),
            ElevatedButton(
              style: ElevatedButton.styleFrom(
                minimumSize: const Size.fromHeight(50),
                backgroundColor: Colors.indigo,
                foregroundColor: Colors.white,
              ),
              onPressed: () async {
                final newPrice = double.tryParse(priceCtrl.text);
                final newStock = int.tryParse(stockCtrl.text);
                if (newPrice != null && newStock != null) {
                  await DatabaseHelper.instance
                      .updateProductLocally(product.id, newPrice, newStock);
                  if (ctx.mounted) { Navigator.pop(ctx); _refresh(); }
                }
              },
              child: const Text('Save (syncs on next connection)'),
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Catalog Search'),
        actions: [
          IconButton(
            icon: const Icon(Icons.qr_code_scanner),
            tooltip: 'Scan Barcode',
            onPressed: () {
              showModalBottomSheet(
                context: context,
                isScrollControlled: true,
                builder: (_) => BarcodeScannerModal(
                  onBarcodeScanned: (barcode) async {
                    final messenger = ScaffoldMessenger.of(context);
                    final results =
                        await DatabaseHelper.instance.searchProducts(barcode);
                    if (results.isNotEmpty && mounted) {
                      widget.onAddToBasket(results.first);
                    } else if (mounted) {
                      messenger.showSnackBar(SnackBar(
                        content: Text('Barcode not in catalog: $barcode'),
                        backgroundColor: Colors.red.shade800,
                      ));
                    }
                  },
                ),
              );
            },
          ),
        ],
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.all(12),
            child: TextField(
              controller: _searchCtrl,
              decoration: InputDecoration(
                hintText: 'Search 5,000 items by name, SKU or barcode…',
                prefixIcon: const Icon(Icons.search),
                suffixIcon: _searchCtrl.text.isNotEmpty
                    ? IconButton(
                        icon: const Icon(Icons.clear),
                        onPressed: () { _searchCtrl.clear(); _refresh(); })
                    : null,
                border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(12)),
              ),
              onChanged: (_) => _refresh(),
            ),
          ),
          Expanded(
            child: _isLoading
                ? const Center(child: CircularProgressIndicator())
                : _products.isEmpty
                    ? const Center(
                        child: Text('No products found. Run sync first.'))
                    : ListView.builder(
                        controller: _scrollCtrl,
                        itemCount: _products.length +
                            (_hasMore || _isLoadingMore ? 1 : 0),
                        itemBuilder: (_, i) {
                          if (i == _products.length) {
                            return Padding(
                              padding:
                                  const EdgeInsets.symmetric(vertical: 16),
                              child: Center(
                                child: _isLoadingMore
                                    ? const SizedBox(
                                        width: 24,
                                        height: 24,
                                        child: CircularProgressIndicator(
                                            strokeWidth: 2),
                                      )
                                    : const SizedBox.shrink(),
                              ),
                            );
                          }
                          final p = _products[i];
                          return ListTile(
                            leading: CircleAvatar(
                              backgroundColor: Colors.indigo.shade50,
                              child: Text(p.sku.replaceAll('SKU-', ''),
                                  style: const TextStyle(
                                      fontSize: 10,
                                      fontWeight: FontWeight.bold)),
                            ),
                            title: Text(p.name),
                            subtitle: Text(
                                'Stock: ${p.stockQuantity} | ${p.barcode ?? 'No barcode'}'),
                            trailing: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Text('\$${p.price.toStringAsFixed(2)}',
                                    style: const TextStyle(
                                        fontSize: 16,
                                        fontWeight: FontWeight.bold,
                                        color: Colors.green)),
                                IconButton(
                                  icon: const Icon(Icons.add_shopping_cart,
                                      color: Colors.indigo),
                                  onPressed: () => widget.onAddToBasket(p),
                                ),
                              ],
                            ),
                            onTap: () => _showEditModal(p),
                          );
                        },
                      ),
          ),
        ],
      ),
    );
  }
}

// ===========================================================================
// TAB 3 — BASKET CALCULATOR
// ===========================================================================
class BasketCalculatorScreen extends StatelessWidget {
  final List<Product> basket;
  final VoidCallback onClearBasket;

  const BasketCalculatorScreen({
    super.key,
    required this.basket,
    required this.onClearBasket,
  });

  double get _total => basket.fold(0.0, (sum, p) => sum + p.price);

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Quick Total Calculator'),
        actions: [
          if (basket.isNotEmpty)
            IconButton(
              icon: const Icon(Icons.delete_outline),
              tooltip: 'Clear basket',
              onPressed: onClearBasket,
            ),
        ],
      ),
      body: basket.isEmpty
          ? const Center(
              child: Text('Basket empty. Tap + in Catalog to add items.'))
          : Column(
              children: [
                Expanded(
                  child: ListView.builder(
                    itemCount: basket.length,
                    itemBuilder: (_, i) {
                      final item = basket[i];
                      return ListTile(
                        title: Text(item.name),
                        subtitle: Text('SKU: ${item.sku}'),
                        trailing: Text('\$${item.price.toStringAsFixed(2)}',
                            style: const TextStyle(
                                fontSize: 16, fontWeight: FontWeight.bold)),
                      );
                    },
                  ),
                ),
                Container(
                  padding: const EdgeInsets.all(20),
                  decoration: BoxDecoration(
                    color: Colors.indigo.shade50,
                    borderRadius:
                        const BorderRadius.vertical(top: Radius.circular(20)),
                  ),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      const Text('Total:',
                          style: TextStyle(
                              fontSize: 22, fontWeight: FontWeight.bold)),
                      Text('\$${_total.toStringAsFixed(2)}',
                          style: const TextStyle(
                              fontSize: 28,
                              fontWeight: FontWeight.bold,
                              color: Colors.indigo)),
                    ],
                  ),
                ),
              ],
            ),
    );
  }
}

// ===========================================================================
// TAB 4 — SYNC CONTROL
// ===========================================================================
class SyncControlScreen extends StatefulWidget {
  final VoidCallback onLogout;
  const SyncControlScreen({super.key, required this.onLogout});

  @override
  State<SyncControlScreen> createState() => _SyncControlScreenState();
}

class _SyncControlScreenState extends State<SyncControlScreen> {
  int _localCount = 0;
  int _lastVersion = 0;
  int _pendingOutbox = 0;
  bool _isSyncing = false;
  String _statusMessage = 'Idle — tap button to sync';

  @override
  void initState() {
    super.initState();
    _loadStats();
  }

  Future<void> _loadStats() async {
    final db = DatabaseHelper.instance;
    final count = await db.getProductCount();
    final version = await db.getLastSyncedVersion();
    final outbox = await db.getPendingOutbox();
    if (mounted) {
      setState(() {
        _localCount = count;
        _lastVersion = version;
        _pendingOutbox = outbox.length;
      });
    }
  }

  Future<void> _triggerSync() async {
    setState(() {
      _isSyncing = true;
      _statusMessage = 'Connecting to backend…';
    });
    try {
      final syncUrl = await AppConfig.syncBaseUrl();
      final authUrl = await AppConfig.authBaseUrl();
      final result = await SyncService(baseUrl: syncUrl, authBaseUrl: authUrl).performSync();
      final action = result.wasInitialImport
          ? 'Initial import: ${result.itemsReceived} products loaded'
          : 'Delta: ${result.itemsReceived} updated';
      final outboxNote = result.outboxFlushed > 0
          ? ' | ${result.outboxFlushed} offline edits pushed'
          : '';
      setState(() => _statusMessage = '$action$outboxNote');
    } catch (e) {
      setState(() => _statusMessage = 'Error: $e');
    } finally {
      await _loadStats();
      if (mounted) setState(() => _isSyncing = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Sync Diagnostics'),
        actions: [
          IconButton(
            icon: const Icon(Icons.logout),
            tooltip: 'Sign out',
            onPressed: () async {
              final authUrl = await AppConfig.authBaseUrl();
              await AuthService.instance.logout(authUrl);
              widget.onLogout();
            },
          ),
        ],
      ),
      body: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          children: [
            Card(
              child: ListTile(
                leading: const Icon(Icons.inventory_2_outlined),
                title: const Text('Local products (Isar)'),
                trailing: Text('$_localCount items',
                    style: const TextStyle(fontWeight: FontWeight.bold)),
              ),
            ),
            Card(
              child: ListTile(
                leading: const Icon(Icons.tag),
                title: const Text('Last synced version'),
                trailing: Text('v$_lastVersion',
                    style: const TextStyle(fontWeight: FontWeight.bold)),
              ),
            ),
            Card(
              child: ListTile(
                leading: Icon(
                  _pendingOutbox > 0
                      ? Icons.upload_outlined
                      : Icons.check_circle_outline,
                  color: _pendingOutbox > 0 ? Colors.orange : Colors.green,
                ),
                title: const Text('Pending offline edits'),
                trailing: Text(
                  _pendingOutbox > 0 ? '$_pendingOutbox queued' : 'All synced',
                  style: TextStyle(
                      fontWeight: FontWeight.bold,
                      color: _pendingOutbox > 0 ? Colors.orange : Colors.green),
                ),
              ),
            ),
            const SizedBox(height: 12),
            Text(_statusMessage,
                style: const TextStyle(color: Colors.grey),
                textAlign: TextAlign.center),
            const Spacer(),
            ElevatedButton.icon(
              style: ElevatedButton.styleFrom(
                minimumSize: const Size.fromHeight(54),
                backgroundColor: Colors.indigo,
                foregroundColor: Colors.white,
              ),
              onPressed: _isSyncing ? null : _triggerSync,
              icon: _isSyncing
                  ? const SizedBox(
                      width: 20, height: 20,
                      child: CircularProgressIndicator(
                          color: Colors.white, strokeWidth: 2))
                  : const Icon(Icons.sync),
              label: Text(_isSyncing ? 'Syncing…' : 'Run Sync Now'),
            ),
          ],
        ),
      ),
    );
  }
}
