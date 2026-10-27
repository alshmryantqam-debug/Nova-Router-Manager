import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'core/network/routeros_client.dart';
import 'core/providers/router_providers.dart';
import 'features/dashboard/dashboard_screen.dart';
import 'features/routers/router_list_screen.dart';

void main() {
  runApp(const ProviderScope(child: NovaRouterManagerApp()));
}

class NovaRouterManagerApp extends StatelessWidget {
  const NovaRouterManagerApp({super.key});

  static const Color _background = Color(0xFF080B12);
  static const Color _surface = Color(0xFF111722);
  static const Color _accent = Color(0xFF8B7CFF);

  @override
  Widget build(BuildContext context) {
    final scheme = ColorScheme.fromSeed(
      seedColor: _accent,
      brightness: Brightness.dark,
      surface: _surface,
    );

    final theme = ThemeData(
      useMaterial3: true,
      brightness: Brightness.dark,
      colorScheme: scheme,
      scaffoldBackgroundColor: _background,
      canvasColor: _surface,
      dividerColor: const Color(0xFF283142),
      appBarTheme: const AppBarTheme(
        backgroundColor: _background,
        foregroundColor: Colors.white,
        elevation: 0,
        centerTitle: false,
        surfaceTintColor: Colors.transparent,
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: const Color(0xFF0B1019),
        labelStyle: const TextStyle(color: Color(0xFF8D9AB0)),
        hintStyle: const TextStyle(color: Color(0xFF5D687B)),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(13),
          borderSide: const BorderSide(color: Color(0xFF283142)),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(13),
          borderSide: const BorderSide(color: Color(0xFF283142)),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(13),
          borderSide: const BorderSide(color: _accent, width: 1.3),
        ),
      ),
      snackBarTheme: SnackBarThemeData(
        behavior: SnackBarBehavior.floating,
        backgroundColor: const Color(0xFF202839),
        contentTextStyle: const TextStyle(color: Colors.white, fontSize: 13),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(13)),
      ),
      floatingActionButtonTheme: const FloatingActionButtonThemeData(
        backgroundColor: _accent,
        foregroundColor: Colors.white,
      ),
      progressIndicatorTheme: const ProgressIndicatorThemeData(
        color: _accent,
        linearTrackColor: Color(0xFF283142),
      ),
    );

    return MaterialApp(
      title: 'Nova Router Manager',
      debugShowCheckedModeBanner: false,
      theme: theme,
      darkTheme: theme,
      themeMode: ThemeMode.dark,
      locale: const Locale('ar'),
      supportedLocales: const <Locale>[
        Locale('ar'),
        Locale('en'),
      ],
      localizationsDelegates: const <LocalizationsDelegate<dynamic>>[
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      builder: (context, child) => Directionality(
        textDirection: TextDirection.rtl,
        child: child ?? const SizedBox.shrink(),
      ),
      home: const _NovaRoot(),
    );
  }
}

/// The active connection is the single source of truth for top-level routing.
/// Connecting from RouterListScreen switches to the dashboard; disconnecting
/// from the dashboard returns to the saved-router list.
class _NovaRoot extends ConsumerWidget {
  const _NovaRoot();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final client = ref.watch(activeRouterClientProvider);

    return AnimatedSwitcher(
      duration: const Duration(milliseconds: 220),
      switchInCurve: Curves.easeOut,
      switchOutCurve: Curves.easeIn,
      child: client == null
          ? const RouterListScreen(key: ValueKey<String>('router-list'))
          : DashboardScreen(key: ValueKey<RouterOsClient>(client)),
    );
  }
}
