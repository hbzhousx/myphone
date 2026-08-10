import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

class SettingsState {
  final bool notificationsEnabled;
  final bool residentEnabled;

  const SettingsState({
    this.notificationsEnabled = true,
    this.residentEnabled = true,
  });

  SettingsState copyWith({bool? notificationsEnabled, bool? residentEnabled}) {
    return SettingsState(
      notificationsEnabled: notificationsEnabled ?? this.notificationsEnabled,
      residentEnabled: residentEnabled ?? this.residentEnabled,
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
  static const _residentKey = 'settings_resident';

  SettingsNotifier() : super(const SettingsState()) {
    _load();
  }

  Future<void> _load() async {
    final notif = await _storage.read(key: _notifKey);
    final resident = await _storage.read(key: _residentKey);
    state = SettingsState(
      notificationsEnabled: notif != 'false',
      residentEnabled: resident != 'false',
    );
  }

  Future<void> toggleNotifications() async {
    final newVal = !state.notificationsEnabled;
    await _storage.write(key: _notifKey, value: newVal.toString());
    state = state.copyWith(notificationsEnabled: newVal);
  }

  Future<void> toggleResident() async {
    final newVal = !state.residentEnabled;
    await _storage.write(key: _residentKey, value: newVal.toString());
    state = state.copyWith(residentEnabled: newVal);
  }
}

final settingsProvider =
    StateNotifierProvider<SettingsNotifier, SettingsState>(
        (ref) => SettingsNotifier());
