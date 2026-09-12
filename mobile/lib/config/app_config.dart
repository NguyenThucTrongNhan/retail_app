import 'package:flutter/material.dart';

import '../services/database_helper.dart';

/// Central settings store. All values are persisted as Isar SyncMetadata
/// key-value pairs so they survive app restarts without a separate prefs package.
///
/// In production all services are accessed through a single Nginx URL:
///   /api/v1/auth/*   → auth service
///   /api/v1/sync/*   → main backend
///   /api/v1/search/* → vision service
class AppConfig {
  AppConfig._();

  static const _keyUrl = 'server_url';
  static const _keyStoreName = 'store_name';
  static const _keyCurrency = 'currency_symbol';
  static const _keyThemeMode = 'theme_mode';
  static const _keyProductsPerPage = 'products_per_page';
  static const _keyAutoSync = 'auto_sync_on_start';

  // ---------------------------------------------------------------------------
  // Server
  // ---------------------------------------------------------------------------
  static Future<String> getServerUrl() async {
    final stored = await DatabaseHelper.instance.getMetaValue(_keyUrl);
    if (stored != null && stored.isNotEmpty) return stored;
    return 'http://10.0.2.2'; // Android emulator default (Nginx on port 80)
  }

  static Future<void> setServerUrl(String url) =>
      DatabaseHelper.instance.setMetaValue(_keyUrl, url.trim().replaceAll(RegExp(r'/$'), ''));

  static Future<String> apiBaseUrl() async => '${await getServerUrl()}/api/v1';

  static Future<String> syncBaseUrl() async => await apiBaseUrl();

  static Future<String> authBaseUrl() async => await apiBaseUrl();

  static Future<String> visionBaseUrl() async => await apiBaseUrl();

  // Keep for backwards compat with settings screen migration
  @Deprecated('Use getServerUrl / setServerUrl')
  static Future<String> getServerIp() async => getServerUrl();

  @Deprecated('Use getServerUrl / setServerUrl')
  static Future<void> setServerIp(String ip) => setServerUrl(ip);

  // ---------------------------------------------------------------------------
  // Store profile
  // ---------------------------------------------------------------------------
  static Future<String> getStoreName() async =>
      await DatabaseHelper.instance.getMetaValue(_keyStoreName) ?? '';

  static Future<void> setStoreName(String name) =>
      DatabaseHelper.instance.setMetaValue(_keyStoreName, name.trim());

  static Future<String> getCurrencySymbol() async =>
      await DatabaseHelper.instance.getMetaValue(_keyCurrency) ?? r'$';

  static Future<void> setCurrencySymbol(String symbol) =>
      DatabaseHelper.instance.setMetaValue(_keyCurrency, symbol.trim());

  // ---------------------------------------------------------------------------
  // Appearance
  // ---------------------------------------------------------------------------
  static Future<ThemeMode> getThemeMode() async {
    final v = await DatabaseHelper.instance.getMetaValue(_keyThemeMode);
    switch (v) {
      case 'light':
        return ThemeMode.light;
      case 'dark':
        return ThemeMode.dark;
      default:
        return ThemeMode.system;
    }
  }

  static Future<void> setThemeMode(ThemeMode mode) {
    final v = switch (mode) {
      ThemeMode.light => 'light',
      ThemeMode.dark => 'dark',
      _ => 'system',
    };
    return DatabaseHelper.instance.setMetaValue(_keyThemeMode, v);
  }

  static Future<int> getProductsPerPage() async {
    final v = await DatabaseHelper.instance.getMetaValue(_keyProductsPerPage);
    return int.tryParse(v ?? '') ?? 30;
  }

  static Future<void> setProductsPerPage(int n) =>
      DatabaseHelper.instance.setMetaValue(_keyProductsPerPage, '$n');

  // ---------------------------------------------------------------------------
  // Sync
  // ---------------------------------------------------------------------------
  static Future<bool> getAutoSyncOnStart() async {
    final v = await DatabaseHelper.instance.getMetaValue(_keyAutoSync);
    return v == 'true';
  }

  static Future<void> setAutoSyncOnStart(bool enabled) =>
      DatabaseHelper.instance.setMetaValue(_keyAutoSync, '$enabled');
}
