import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../widgets/dialer_keypad.dart';

class KeypadScreen extends ConsumerStatefulWidget {
  const KeypadScreen({super.key});
  @override
  ConsumerState<KeypadScreen> createState() => _KeypadScreenState();
}

class _KeypadScreenState extends ConsumerState<KeypadScreen> {
  String _number = '';

  void _onDigit(String digit) => setState(() => _number += digit);

  void _onDelete() {
    if (_number.isNotEmpty) {
      setState(() => _number = _number.substring(0, _number.length - 1));
    }
  }

  void _onCall() {
    if (_number.isNotEmpty) {
      context.go('/call/$_number');
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Keypad')),
      body: DialerKeypad(
        displayedNumber: _number,
        onDigit: _onDigit,
        onDelete: _onDelete,
        onCall: _onCall,
      ),
    );
  }
}
