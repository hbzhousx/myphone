import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'app/router.dart';
import 'app/theme.dart';
import 'core/storage/database.dart';
import 'core/storage/key_manager.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;

  final dbKey = await KeyManager.getOrCreateDbKey();
  DatabaseManager.instance.setEncryptionKey(dbKey);

  runApp(
    const ProviderScope(
      child: MyPhoneApp(),
    ),
  );
}

class MyPhoneApp extends ConsumerWidget {
  const MyPhoneApp({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final router = ref.watch(routerProvider);

    return MaterialApp.router(
      title: 'MyPhone',
      theme: appTheme,
      darkTheme: darkAppTheme,
      themeMode: ThemeMode.system,
      routerConfig: router,
      debugShowCheckedModeBanner: false,
    );
  }
}
