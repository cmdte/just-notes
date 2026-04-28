import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// App-level user preferences (theme, etc.) persisted in secure storage.
class AppSettings extends ChangeNotifier {
  AppSettings._(this._themeMode);

  static const _storage = FlutterSecureStorage();
  static const _themeKey = 'pref_theme_mode';

  ThemeMode _themeMode;
  ThemeMode get themeMode => _themeMode;

  static Future<AppSettings> load() async {
    final raw = await _storage.read(key: _themeKey);
    return AppSettings._(_decode(raw));
  }

  Future<void> setThemeMode(ThemeMode mode) async {
    if (_themeMode == mode) return;
    _themeMode = mode;
    notifyListeners();
    await _storage.write(key: _themeKey, value: _encode(mode));
  }

  static String _encode(ThemeMode m) => switch (m) {
        ThemeMode.system => 'system',
        ThemeMode.light => 'light',
        ThemeMode.dark => 'dark',
      };

  static ThemeMode _decode(String? s) => switch (s) {
        'light' => ThemeMode.light,
        'dark' => ThemeMode.dark,
        _ => ThemeMode.system,
      };
}
