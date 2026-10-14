import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Gère le thème clair / sombre de Kwetu Park.
///
/// Le choix de l'utilisateur est mémorisé localement (shared_preferences) afin
/// d'être restauré au prochain lancement de l'application.
class ThemeController {
  ThemeController._();

  static const _preferenceKey = 'kwetu_theme_mode';

  /// Mode courant observé par `MaterialApp`.
  static final ValueNotifier<ThemeMode> mode = ValueNotifier<ThemeMode>(
    ThemeMode.light,
  );

  static bool get isDark => mode.value == ThemeMode.dark;

  /// Restaure le thème mémorisé avant le premier rendu.
  static Future<void> load() async {
    try {
      final preferences = await SharedPreferences.getInstance();
      mode.value = preferences.getString(_preferenceKey) == 'dark'
          ? ThemeMode.dark
          : ThemeMode.light;
    } catch (_) {
      mode.value = ThemeMode.light;
    }
  }

  /// Bascule entre clair et sombre, puis enregistre le choix.
  static Future<void> toggle() async {
    mode.value = isDark ? ThemeMode.light : ThemeMode.dark;
    await setDark(isDark);
  }

  static Future<void> setDark(bool dark) async {
    try {
      final preferences = await SharedPreferences.getInstance();
      await preferences.setString(_preferenceKey, dark ? 'dark' : 'light');
    } catch (_) {
      // Le thème reste appliqué pour la session même si l'écriture échoue.
    }
  }
}
