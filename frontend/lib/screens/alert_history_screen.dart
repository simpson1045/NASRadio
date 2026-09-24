import 'package:flutter/material.dart';
import '../services/weather_service.dart';
import '../main.dart' show globalWeatherService;

class AlertHistoryScreen extends StatelessWidget {
  const AlertHistoryScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Weather Alert History'),
      ),
      body: ListenableBuilder(
        listenable: globalWeatherService,
        builder: (context, child) {
          final alerts = globalWeatherService.alertHistory;

          if (alerts.isEmpty) {
            return const Center(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(Icons.check_circle_outline,
                      color: Colors.white38, size: 64),
                  SizedBox(height: 16),
                  Text(
                    'No weather alerts',
                    style: TextStyle(color: Colors.white54, fontSize: 16),
                  ),
                  SizedBox(height: 8),
                  Text(
                    'Recent alerts will appear here',
                    style: TextStyle(color: Colors.white38, fontSize: 13),
                  ),
                ],
              ),
            );
          }

          return ListView.builder(
            padding: const EdgeInsets.all(16),
            itemCount: alerts.length,
            itemBuilder: (context, index) {
              final alert = alerts[index];
              return _buildAlertCard(alert);
            },
          );
        },
      ),
    );
  }

  Widget _buildAlertCard(WeatherAlert alert) {
    Color severityColor;
    if (alert.severity == 'Extreme') {
      severityColor = const Color(0xFFB71C1C);
    } else if (alert.severity == 'Severe') {
      severityColor = const Color(0xFFD32F2F);
    } else if (alert.severity == 'Moderate') {
      severityColor = const Color(0xFFE65100);
    } else {
      severityColor = const Color(0xFFF9A825);
    }

    String timeStr = '';
    if (alert.onset != null) {
      final now = DateTime.now();
      final diff = now.difference(alert.onset!);
      if (diff.inMinutes < 60) {
        timeStr = '${diff.inMinutes}m ago';
      } else if (diff.inHours < 24) {
        timeStr = '${diff.inHours}h ago';
      } else {
        timeStr = '${diff.inDays}d ago';
      }
    }

    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      decoration: BoxDecoration(
        color: const Color(0xFF1a2332),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: severityColor.withValues(alpha: 0.4),
          width: 1,
        ),
      ),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                  decoration: BoxDecoration(
                    color: severityColor,
                    borderRadius: BorderRadius.circular(6),
                  ),
                  child: Text(
                    alert.severity,
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 11,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    alert.event,
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 15,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ),
                if (timeStr.isNotEmpty)
                  Text(
                    timeStr,
                    style: const TextStyle(
                      color: Colors.white38,
                      fontSize: 12,
                    ),
                  ),
              ],
            ),
            if (alert.headline.isNotEmpty) ...[
              const SizedBox(height: 8),
              Text(
                alert.headline,
                style: const TextStyle(
                  color: Colors.white70,
                  fontSize: 13,
                ),
              ),
            ],
            if (alert.expires != null) ...[
              const SizedBox(height: 8),
              Text(
                'Expires: ${_formatTime(alert.expires!)}',
                style: const TextStyle(
                  color: Colors.white38,
                  fontSize: 12,
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  String _formatTime(DateTime dt) {
    final hour = dt.hour > 12 ? dt.hour - 12 : (dt.hour == 0 ? 12 : dt.hour);
    final amPm = dt.hour >= 12 ? 'PM' : 'AM';
    final min = dt.minute.toString().padLeft(2, '0');
    return '$hour:$min $amPm';
  }
}
