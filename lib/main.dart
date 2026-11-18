import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'core/network/routeros_client.dart';
import 'core/providers/router_providers.dart';
import 'features/dashboard/dashboard_screen.dart';
import 'features/settings/app_security_service.dart';
import 'features/routers/router_list_screen.dart';

void main() {
  runApp(const ProviderScope(child: NovaRouterManagerApp()));
}

class NovaRouterManagerApp extends StatelessWidget {
  const NovaRouterManagerApp({super.key});

  static const Color _background = Color(0xFF030713);
  static const Color _surface = Color(0xFF0A1426);
  static const Color _accent = Color(0xFF18D9FF);
  static const Color _violet = Color(0xFF8B5CFF);

  @override
  Widget build(BuildContext context) {
    const scheme = ColorScheme.dark(
      primary: _accent,
      secondary: _violet,
      tertiary: Color(0xFF37E5B4),
      surface: _surface,
      error: Color(0xFFFF5577),
      onPrimary: Color(0xFF00121A),
      onSecondary: Colors.white,
      onSurface: Color(0xFFEAF4FF),
    );

    final theme = ThemeData(
      useMaterial3: true,
      brightness: Brightness.dark,
      colorScheme: scheme,
      scaffoldBackgroundColor: _background,
      canvasColor: _surface,
      dividerColor: const Color(0xFF1A3150),
      fontFamily: 'sans-serif',
      fontFamilyFallback: const <String>['Noto Sans Arabic', 'Noto Naskh Arabic', 'sans-serif'],
      textTheme: ThemeData.dark().textTheme.apply(
        bodyColor: const Color(0xFFEAF4FF),
        displayColor: Colors.white,
        fontFamily: 'sans-serif',
        fontFamilyFallback: const <String>['Noto Sans Arabic', 'Noto Naskh Arabic', 'sans-serif'],
      ),
      appBarTheme: const AppBarTheme(
        backgroundColor: _background,
        foregroundColor: Colors.white,
        elevation: 0,
        centerTitle: false,
        surfaceTintColor: Colors.transparent,
        titleTextStyle: TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.w900, letterSpacing: 0.2),
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: const Color(0xFF0B1520),
        labelStyle: const TextStyle(color: Color(0xFF8D9AB0)),
        hintStyle: const TextStyle(color: Color(0xFF5D687B)),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(13),
          borderSide: const BorderSide(color: Color(0xFF233747)),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(13),
          borderSide: const BorderSide(color: Color(0xFF233747)),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(13),
          borderSide: const BorderSide(color: _accent, width: 1.6),
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
        linearTrackColor: Color(0xFF1A3150),
      ),
      cardTheme: CardThemeData(
        color: const Color(0xFF0A1426),
        elevation: 0,
        margin: EdgeInsets.zero,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20), side: const BorderSide(color: Color(0xFF1B3B5C))),
      ),
      navigationBarTheme: NavigationBarThemeData(
        backgroundColor: const Color(0xFF050B18),
        indicatorColor: _accent.withValues(alpha: 0.16),
        elevation: 0,
        labelTextStyle: WidgetStateProperty.resolveWith((states) => TextStyle(
          color: states.contains(WidgetState.selected) ? _accent : const Color(0xFF91A5C0),
          fontSize: 11,
          fontWeight: FontWeight.w700,
        )),
      ),
    );

    return MaterialApp(
      title: 'نوڨا (Nova)',
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
      home: const AppPinGate(child: _NovaRoot()),
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
