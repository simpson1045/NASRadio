import 'package:flutter/material.dart';

class AlphabetScrollBar extends StatefulWidget {
  final ScrollController scrollController;
  final List<String> items;

  const AlphabetScrollBar({
    super.key,
    required this.scrollController,
    required this.items,
  });

  @override
  State<AlphabetScrollBar> createState() => _AlphabetScrollBarState();
}

class _AlphabetScrollBarState extends State<AlphabetScrollBar> {
  void _scrollToLetter(String letter) {
    int index;

    if (letter == '#') {
      index = widget.items.indexWhere(
        (item) => RegExp(r'^[0-9]').hasMatch(item),
      );
    } else {
      index = widget.items.indexWhere(
        (item) => item.toUpperCase().startsWith(letter),
      );
    }

    if (index != -1 && widget.scrollController.hasClients) {
      // Calculate average item height from current scroll position
      final currentPosition = widget.scrollController.position.pixels;
      final maxExtent = widget.scrollController.position.maxScrollExtent;
      final viewportHeight = widget.scrollController.position.viewportDimension;

      // Estimate: total scrollable height / number of items
      final totalHeight = maxExtent + viewportHeight;
      final averageItemHeight = totalHeight / widget.items.length;

      print('📏 Average item height: $averageItemHeight');

      final position = index * averageItemHeight;
      final targetPosition = position.clamp(0.0, maxExtent);

      widget.scrollController.animateTo(
        targetPosition,
        duration: const Duration(milliseconds: 300),
        curve: Curves.easeInOut,
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final alphabet = ['#', ...('ABCDEFGHIJKLMNOPQRSTUVWXYZ'.split(''))];

    return Container(
      width: 24,
      alignment: Alignment.center,
      child: SingleChildScrollView(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: alphabet.map((letter) {
            return GestureDetector(
              onTap: () => _scrollToLetter(letter),
              child: Container(
                height: 18,
                alignment: Alignment.center,
                child: Text(
                  letter,
                  style: const TextStyle(
                    fontSize: 14,
                    color: Color(0xFF00d4ff),
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ),
            );
          }).toList(),
        ),
      ),
    );
  }
}
