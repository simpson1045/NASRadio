import 'package:flutter/material.dart';

class ExplicitBadge extends StatelessWidget {
  final double fontSize;

  const ExplicitBadge({super.key, this.fontSize = 9});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
      decoration: BoxDecoration(
        color: Colors.grey.withOpacity(0.3),
        border: Border.all(color: Colors.grey, width: 1),
        borderRadius: BorderRadius.circular(3),
      ),
      child: Text(
        'E',
        style: TextStyle(
          fontSize: fontSize,
          fontWeight: FontWeight.bold,
          color: Colors.grey.shade300,
          letterSpacing: 0.5,
        ),
      ),
    );
  }
}
