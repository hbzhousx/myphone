import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

class DialerKeypad extends StatelessWidget {
  final void Function(String digit) onDigit;
  final VoidCallback onDelete;
  final VoidCallback onCall;
  final String displayedNumber;

  const DialerKeypad({
    super.key,
    required this.onDigit,
    required this.onDelete,
    required this.onCall,
    required this.displayedNumber,
  });

  static const _digits = [
    ['1', '2', '3'],
    ['4', '5', '6'],
    ['7', '8', '9'],
    ['*', '0', '#'],
  ];

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      children: [
        const Spacer(flex: 1),
        // Display area
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 32),
          child: Text(
            displayedNumber.isEmpty ? ' ' : _formatNumber(displayedNumber),
            style: const TextStyle(fontSize: 36, fontWeight: FontWeight.w300, letterSpacing: 2),
            textAlign: TextAlign.center,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        ),
        const SizedBox(height: 32),
        // Digit grid
        ..._digits.map((row) => Padding(
          padding: const EdgeInsets.symmetric(horizontal: 48),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceEvenly,
            children: row.map((digit) => _DigitButton(
              digit: digit,
              onTap: () {
                HapticFeedback.lightImpact();
                onDigit(digit);
              },
            )).toList(),
          ),
        )),
        const SizedBox(height: 16),
        // Bottom row: delete + call
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 48),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceEvenly,
            children: [
              // Delete button
              if (displayedNumber.isNotEmpty)
                SizedBox(
                  width: 72, height: 72,
                  child: IconButton(
                    icon: const Icon(Icons.backspace_outlined, size: 28),
                    onPressed: () {
                      HapticFeedback.lightImpact();
                      onDelete();
                    },
                    color: theme.colorScheme.onSurface,
                  ),
                )
              else
                const SizedBox(width: 72, height: 72),
              // Call button
              SizedBox(
                width: 72, height: 72,
                child: FloatingActionButton(
                  heroTag: 'keypad_call',
                  onPressed: displayedNumber.isNotEmpty ? () {
                    HapticFeedback.heavyImpact();
                    onCall();
                  } : null,
                  backgroundColor: theme.colorScheme.primary,
                  child: const Icon(Icons.call, color: Colors.white, size: 32),
                ),
              ),
              const SizedBox(width: 72, height: 72), // Balance the row
            ],
          ),
        ),
        const Spacer(flex: 1),
      ],
    );
  }

  String _formatNumber(String number) {
    if (number.length <= 4) return number;
    final buffer = StringBuffer();
    for (int i = 0; i < number.length; i++) {
      if (i > 0 && i % 4 == 0) buffer.write(' ');
      buffer.write(number[i]);
    }
    return buffer.toString();
  }
}

class _DigitButton extends StatelessWidget {
  final String digit;
  final VoidCallback onTap;

  const _DigitButton({required this.digit, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(40),
      child: Container(
        width: 72,
        height: 72,
        alignment: Alignment.center,
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Text(
              digit,
              style: TextStyle(
                fontSize: 28,
                fontWeight: FontWeight.w400,
                color: theme.colorScheme.onSurface,
              ),
            ),
            if (_subtext(digit) != null)
              Text(
                _subtext(digit)!,
                style: TextStyle(
                  fontSize: 10,
                  color: theme.colorScheme.onSurfaceVariant,
                  letterSpacing: 2,
                ),
              ),
          ],
        ),
      ),
    );
  }

  String? _subtext(String digit) {
    switch (digit) {
      case '2': return 'ABC';
      case '3': return 'DEF';
      case '4': return 'GHI';
      case '5': return 'JKL';
      case '6': return 'MNO';
      case '7': return 'PQRS';
      case '8': return 'TUV';
      case '9': return 'WXYZ';
      default: return null;
    }
  }
}
