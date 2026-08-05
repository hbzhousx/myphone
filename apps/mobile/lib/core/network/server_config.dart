/// Server connection configuration.
/// Change HOST to your server's LAN IP before building the APK.
library;

class ServerConfig {
  static const String host = String.fromEnvironment(
    'MYPHONE_SERVER_HOST',
    defaultValue: '192.168.3.113',
  );
  static const int port = int.fromEnvironment(
    'MYPHONE_SERVER_PORT',
    defaultValue: 8080,
  );
  static const bool useTls = bool.fromEnvironment(
    'MYPHONE_SERVER_TLS',
    defaultValue: false,
  );

  static String get httpBase => '${useTls ? 'https' : 'http'}://$host:$port';
  static String get wsBase => '${useTls ? 'wss' : 'ws'}://$host:$port';
  static String get apiBase => '$httpBase/v1';
  static String get wsEndpoint => '$wsBase/ws';
}
