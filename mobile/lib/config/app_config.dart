import '../services/database_helper.dart';

/// Stores the shop server IP in Isar (SyncMetadata key: 'server_ip').
/// Both backend ports are derived from that single value.
///
///   Sync API  → http://<ip>:8080/api/v1
///   Vision    → http://<ip>:8081
///
/// Defaults to 'localhost' so Flutter web / same-machine dev works out of the box.
/// On a physical Android phone change to the shop PC's LAN IP (e.g. 192.168.1.50).
/// On Android emulator use 10.0.2.2.
class AppConfig {
  AppConfig._();

  static const _keyIp = 'server_ip';
  static const _defaultIp = 'localhost';

  static Future<String> getServerIp() async =>
      await DatabaseHelper.instance.getMetaValue(_keyIp) ?? _defaultIp;

  static Future<void> setServerIp(String ip) =>
      DatabaseHelper.instance.setMetaValue(_keyIp, ip.trim());

  static Future<String> syncBaseUrl() async {
    final ip = await getServerIp();
    return 'http://$ip:8080/api/v1';
  }

  static Future<String> visionBaseUrl() async {
    final ip = await getServerIp();
    return 'http://$ip:8081';
  }
}
