import 'package:material_ui/material_ui.dart';

/// Palette officielle de Domolia, inspirée du bouclier émeraude et or.
abstract final class DomoliaColors {
  static const background = Color(0xFF061B10);
  static const surface = Color(0xFF0D2A1B);
  static const raisedSurface = Color(0xFF163A25);
  static const border = Color(0xFF47623E);
  static const gold = Color(0xFFF6CC69);
  static const goldLight = Color(0xFFFFE6A5);
  static const goldDark = Color(0xFFB98932);
  static const onGold = Color(0xFF132318);
  static const cream = Color(0xFFF5EDD6);
  static const muted = Color(0xFFBAC9B4);
}

abstract final class DomoliaTheme {
  static ThemeData get dark => ThemeData(
        useMaterial3: true,
        brightness: Brightness.dark,
        scaffoldBackgroundColor: DomoliaColors.background,
        colorScheme: const ColorScheme.dark(
          primary: DomoliaColors.gold,
          onPrimary: DomoliaColors.onGold,
          primaryContainer: DomoliaColors.raisedSurface,
          onPrimaryContainer: DomoliaColors.goldLight,
          secondary: DomoliaColors.goldLight,
          onSecondary: DomoliaColors.onGold,
          surface: DomoliaColors.surface,
          onSurface: DomoliaColors.cream,
          outline: DomoliaColors.border,
        ),
        appBarTheme: const AppBarTheme(
          backgroundColor: DomoliaColors.background,
          foregroundColor: DomoliaColors.goldLight,
          centerTitle: true,
          elevation: 0,
        ),
        drawerTheme: const DrawerThemeData(
          backgroundColor: DomoliaColors.surface,
        ),
        filledButtonTheme: FilledButtonThemeData(
          style: FilledButton.styleFrom(
            backgroundColor: DomoliaColors.gold,
            foregroundColor: DomoliaColors.onGold,
            minimumSize: const Size.fromHeight(52),
            padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 14),
            textStyle: const TextStyle(fontWeight: FontWeight.w700),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(14),
            ),
          ),
        ),
        outlinedButtonTheme: OutlinedButtonThemeData(
          style: OutlinedButton.styleFrom(
            foregroundColor: DomoliaColors.goldLight,
            side: const BorderSide(color: DomoliaColors.goldDark),
            minimumSize: const Size.fromHeight(52),
            padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 14),
            textStyle: const TextStyle(fontWeight: FontWeight.w600),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(14),
            ),
          ),
        ),
        textButtonTheme: TextButtonThemeData(
          style: TextButton.styleFrom(
            foregroundColor: DomoliaColors.goldLight,
          ),
        ),
        inputDecorationTheme: InputDecorationTheme(
          filled: true,
          fillColor: DomoliaColors.raisedSurface,
          enabledBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(12),
            borderSide: const BorderSide(color: DomoliaColors.border),
          ),
          focusedBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(12),
            borderSide: const BorderSide(
              color: DomoliaColors.gold,
              width: 2,
            ),
          ),
        ),
        dividerColor: DomoliaColors.border,
        snackBarTheme: const SnackBarThemeData(
          backgroundColor: DomoliaColors.raisedSurface,
          contentTextStyle: TextStyle(color: DomoliaColors.cream),
        ),
      );
}
