import 'package:flutter/material.dart';

class HdcdBadge extends StatelessWidget {
  final double fontSize;

  const HdcdBadge({super.key, this.fontSize = 9});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
      decoration: BoxDecoration(
        color: const Color(0xFFFFD700).withOpacity(0.2),
        border: Border.all(color: const Color(0xFFFFD700), width: 1),
        borderRadius: BorderRadius.circular(3),
      ),
      child: Text(
        'HDCD',
        style: TextStyle(
          fontSize: fontSize,
          fontWeight: FontWeight.bold,
          color: const Color(0xFFFFD700),
          letterSpacing: 0.5,
        ),
      ),
    );
  }
}
