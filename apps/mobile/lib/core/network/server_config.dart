/// Server connection configuration.
/// Change HOST to your server's LAN IP before building the APK.
library;

class ServerConfig {
  static const String host = '192.168.3.113';
  static const int port = 8080;
  static String get httpBase => 'http://$host:$port';
  static String get wsBase => 'ws://$host:$port';
  static String get apiBase => '$httpBase/v1';
  static String get wsEndpoint => '$wsBase/ws';
}
