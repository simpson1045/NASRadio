import 'package:flutter/material.dart';

/// A single breadcrumb item with a label and an optional tap action.
class BreadcrumbItem {
  final String label;
  final VoidCallback? onTap; // null = current page (not tappable)

  const BreadcrumbItem({required this.label, this.onTap});
}

/// Displays a clickable breadcrumb trail: Library > Artist > Album
/// Previous crumbs are tappable to navigate back. Current crumb is highlighted.
class BreadcrumbBar extends StatelessWidget {
  final List<BreadcrumbItem> items;

  const BreadcrumbBar({super.key, required this.items});

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: _buildCrumbs(),
      ),
    );
  }

  List<Widget> _buildCrumbs() {
    final widgets = <Widget>[];

    for (int i = 0; i < items.length; i++) {
      final item = items[i];
      final isLast = i == items.length - 1;

      // Separator (except before first item)
      if (i > 0) {
        widgets.add(
          const Padding(
            padding: EdgeInsets.symmetric(horizontal: 6),
            child: Icon(
              Icons.chevron_right,
              size: 16,
              color: Colors.white38,
            ),
          ),
        );
      }

      // Breadcrumb label
      if (isLast || item.onTap == null) {
        // Current page — bright, not tappable
        widgets.add(
          Text(
            item.label,
            style: const TextStyle(
              color: Color(0xFF00d4ff),
              fontSize: 14,
              fontWeight: FontWeight.w600,
            ),
            overflow: TextOverflow.ellipsis,
          ),
        );
      } else {
        // Previous page — dimmer, tappable
        widgets.add(
          GestureDetector(
            onTap: item.onTap,
            child: MouseRegion(
              cursor: SystemMouseCursors.click,
              child: Text(
                item.label,
                style: const TextStyle(
                  color: Colors.white54,
                  fontSize: 14,
                  fontWeight: FontWeight.w400,
                ),
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ),
        );
      }
    }

    return widgets;
  }
}
