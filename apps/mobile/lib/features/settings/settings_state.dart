import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

class SettingsState {
  final bool notificationsEnabled;

  const SettingsState({this.notificationsEnabled = true});

  SettingsState copyWith({bool? notificationsEnabled}) {
    return SettingsState(
      notificationsEnabled: notificationsEnabled ?? this.notificationsEnabled,
    );
  }
}

class SettingsNotifier extends StateNotifier<SettingsState> {
  static const _storage = FlutterSecureStorage(
    aOptions: AndroidOptions(
      encryptedSharedPreferences: true,
      resetOnError: true,
    ),
  );
  static const _notifKey = 'settings_notifications';

  SettingsNotifier() : super(const SettingsState()) {
    _load();
  }

  Future<void> _load() async {
    final notif = await _storage.read(key: _notifKey);
    state = SettingsState(notificationsEnabled: notif != 'false');
  }

  Future<void> toggleNotifications() async {
    final newVal = !state.notificationsEnabled;
    await _storage.write(key: _notifKey, value: newVal.toString());
    state = state.copyWith(notificationsEnabled: newVal);
  }
}

final settingsProvider =
    StateNotifierProvider<SettingsNotifier, SettingsState>(
        (ref) => SettingsNotifier());
