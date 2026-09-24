class LyricLine {
  final Duration timestamp;
  final String text;

  LyricLine({required this.timestamp, required this.text});

  /// Parse LRC format lyrics into a list of LyricLines
  /// LRC format: [mm:ss.xx]Lyrics text
  static List<LyricLine> parseLrc(String lrcContent) {
    final lines = <LyricLine>[];
    final regex = RegExp(r'\[(\d{2}):(\d{2})\.(\d{2,3})\](.*)');

    for (final line in lrcContent.split('\n')) {
      final match = regex.firstMatch(line);
      if (match != null) {
        final minutes = int.parse(match.group(1)!);
        final seconds = int.parse(match.group(2)!);
        var milliseconds = int.parse(match.group(3)!);

        // Handle both .xx (centiseconds) and .xxx (milliseconds) formats
        if (match.group(3)!.length == 2) {
          milliseconds *= 10;
        }

        final text = match.group(4)?.trim() ?? '';

        // Skip empty lines
        if (text.isNotEmpty) {
          lines.add(
            LyricLine(
              timestamp: Duration(
                minutes: minutes,
                seconds: seconds,
                milliseconds: milliseconds,
              ),
              text: text,
            ),
          );
        }
      }
    }

    // Sort by timestamp just in case
    lines.sort((a, b) => a.timestamp.compareTo(b.timestamp));
    return lines;
  }
}
