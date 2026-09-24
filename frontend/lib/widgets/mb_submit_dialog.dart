import 'package:flutter/material.dart';

/// "Not listed? Add it now" — the MusicBrainz submission modal
/// (MUSICBRAINZ_SUBMISSION_SPEC.md §10).
///
/// Arrives prefilled from the release data the backend extracted from
/// the actual audio files; every field is editable. On submit it pops
/// with {'data': <edited data>, 'comment': <disambiguation>} and the
/// caller stages the handoff + opens the MB release editor, where the
/// user gives the final (MB-mandated) click under their own account.
class MbSubmitDialog extends StatefulWidget {
  final Map<String, dynamic> data;

  const MbSubmitDialog({super.key, required this.data});

  @override
  State<MbSubmitDialog> createState() => _MbSubmitDialogState();
}

class _MbSubmitDialogState extends State<MbSubmitDialog> {
  static const _bg = Color(0xFF0d1b2a);
  static const _panel = Color(0xFF13253c);
  static const _accent = Color(0xFF00d4ff);

  late final TextEditingController _album;
  late final TextEditingController _artist;
  late final TextEditingController _date;
  late final TextEditingController _label;
  late final TextEditingController _barcode;
  late final TextEditingController _url;
  late final TextEditingController _comment;
  late final List<TextEditingController> _trackTitles;
  late final List<Map<String, dynamic>> _tracks;
  String _format = 'Digital Media';
  String _type = 'Album';

  static const _formats = [
    'Digital Media', 'CD', '12" Vinyl', 'SACD', 'Blu-ray', 'DVD-Audio',
  ];
  static const _types = ['Album', 'EP', 'Single', 'Compilation'];

  @override
  void initState() {
    super.initState();
    final d = widget.data;
    _album = TextEditingController(text: d['album'] ?? '');
    _artist = TextEditingController(text: d['artist'] ?? '');
    _date = TextEditingController(text: d['date'] ?? '');
    _label = TextEditingController(text: d['label'] ?? '');
    _barcode = TextEditingController(text: d['barcode'] ?? '');
    _url = TextEditingController(text: d['url'] ?? '');
    // Backend suggests the disambiguation when the edition announces
    // itself (Atmos in names, Dolby codecs in files) — user approves.
    _comment = TextEditingController(text: d['comment'] ?? '');
    if (_formats.contains(d['format'])) _format = d['format'];
    if (_types.contains(d['type'])) _type = d['type'];
    _tracks = List<Map<String, dynamic>>.from(
      (d['tracks'] as List? ?? []).map((t) => Map<String, dynamic>.from(t)),
    );
    _trackTitles = _tracks
        .map((t) => TextEditingController(text: t['title'] ?? ''))
        .toList();
  }

  @override
  void dispose() {
    for (final c in [_album, _artist, _date, _label, _barcode, _url, _comment,
        ..._trackTitles]) {
      c.dispose();
    }
    super.dispose();
  }

  String _fmtLength(dynamic ms) {
    if (ms == null) return '--:--';
    final s = (ms as int) ~/ 1000;
    return '${s ~/ 60}:${(s % 60).toString().padLeft(2, '0')}';
  }

  void _submit() {
    final data = Map<String, dynamic>.from(widget.data);
    data['album'] = _album.text.trim();
    data['artist'] = _artist.text.trim();
    data['date'] = _date.text.trim();
    data['label'] = _label.text.trim();
    data['barcode'] = _barcode.text.trim();
    data['url'] = _url.text.trim();
    data['format'] = _format;
    data['type'] = _type;
    data['tracks'] = [
      for (var i = 0; i < _tracks.length; i++)
        {
          'number': _tracks[i]['number'],
          'title': _trackTitles[i].text.trim(),
          'length_ms': _tracks[i]['length_ms'],
        }
    ];
    Navigator.of(context).pop({
      'data': data,
      'comment': _comment.text.trim(),
    });
  }

  Widget _section(String title) {
    return Padding(
      padding: const EdgeInsets.only(top: 18, bottom: 10),
      child: Row(
        children: [
          Text(
            title.toUpperCase(),
            style: const TextStyle(
              color: _accent,
              fontSize: 11,
              fontWeight: FontWeight.bold,
              letterSpacing: 1.4,
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Container(height: 1, color: Colors.white.withOpacity(0.06)),
          ),
        ],
      ),
    );
  }

  Widget _field(
    String label,
    TextEditingController c, {
    String? helper,
    IconData? icon,
  }) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: TextField(
        controller: c,
        style: const TextStyle(fontSize: 13.5),
        decoration: InputDecoration(
          labelText: label,
          helperText: helper,
          prefixIcon: icon == null
              ? null
              : Icon(icon, size: 18, color: Colors.grey[500]),
        ),
      ),
    );
  }

  Widget _dropdown(
    String label,
    String value,
    List<String> options,
    ValueChanged<String> onChanged,
  ) {
    return DropdownButtonFormField<String>(
      initialValue: value,
      dropdownColor: _panel,
      style: const TextStyle(fontSize: 13.5, color: Colors.white),
      items: [
        for (final o in options) DropdownMenuItem(value: o, child: Text(o)),
      ],
      onChanged: (v) => onChanged(v!),
      decoration: InputDecoration(labelText: label),
    );
  }

  Widget _trackRow(int i) {
    return Container(
      margin: const EdgeInsets.only(bottom: 6),
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: _panel,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        children: [
          Container(
            width: 24,
            height: 24,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: _accent.withOpacity(0.12),
              shape: BoxShape.circle,
            ),
            child: Text(
              '${_tracks[i]['number']}',
              style: const TextStyle(
                color: _accent,
                fontSize: 11,
                fontWeight: FontWeight.bold,
              ),
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: TextField(
              controller: _trackTitles[i],
              style: const TextStyle(fontSize: 13.5),
              decoration: const InputDecoration(
                isDense: true,
                filled: false,
                border: InputBorder.none,
                enabledBorder: InputBorder.none,
                focusedBorder: UnderlineInputBorder(
                  borderSide: BorderSide(color: _accent),
                ),
                contentPadding: EdgeInsets.symmetric(vertical: 8),
              ),
            ),
          ),
          const SizedBox(width: 10),
          Text(
            _fmtLength(_tracks[i]['length_ms']),
            style: TextStyle(
              color: Colors.grey[500],
              fontSize: 12,
              fontFeatures: const [FontFeature.tabularFigures()],
            ),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final inputTheme = Theme.of(context).copyWith(
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: _panel,
        isDense: true,
        labelStyle: TextStyle(color: Colors.grey[400], fontSize: 13),
        floatingLabelStyle: const TextStyle(color: _accent, fontSize: 13),
        helperStyle: TextStyle(color: Colors.grey[600], fontSize: 10.5),
        contentPadding:
            const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(10),
          borderSide: BorderSide(color: Colors.white.withOpacity(0.08)),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(10),
          borderSide: BorderSide(color: Colors.white.withOpacity(0.08)),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(10),
          borderSide: const BorderSide(color: _accent, width: 1.4),
        ),
      ),
    );

    return Dialog(
      backgroundColor: _bg,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      child: Theme(
        data: inputTheme,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 580, maxHeight: 700),
          child: Column(
            children: [
              // Header
              Container(
                padding: const EdgeInsets.fromLTRB(20, 16, 10, 14),
                decoration: BoxDecoration(
                  border: Border(
                    bottom: BorderSide(color: Colors.white.withOpacity(0.06)),
                  ),
                ),
                child: Row(
                  children: [
                    Container(
                      padding: const EdgeInsets.all(8),
                      decoration: BoxDecoration(
                        color: _accent.withOpacity(0.12),
                        borderRadius: BorderRadius.circular(10),
                      ),
                      child:
                          const Icon(Icons.library_add, color: _accent, size: 20),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Text(
                            'Add release to MusicBrainz',
                            style: TextStyle(
                                fontSize: 16, fontWeight: FontWeight.bold),
                          ),
                          const SizedBox(height: 2),
                          Text(
                            'Prefilled from the audio files — review, edit, '
                            'then continue to the MusicBrainz editor.',
                            style: TextStyle(
                                fontSize: 11, color: Colors.grey[500]),
                          ),
                        ],
                      ),
                    ),
                    IconButton(
                      icon: const Icon(Icons.close),
                      color: Colors.grey[500],
                      onPressed: () => Navigator.of(context).pop(),
                    ),
                  ],
                ),
              ),
              // Body
              Expanded(
                child: ListView(
                  padding: const EdgeInsets.fromLTRB(20, 4, 20, 12),
                  children: [
                    _section('Release'),
                    _field('Release title', _album, icon: Icons.album),
                    _field('Artist', _artist, icon: Icons.person),
                    Row(
                      children: [
                        Expanded(
                            child: _dropdown('Type', _type, _types,
                                (v) => setState(() => _type = v))),
                        const SizedBox(width: 12),
                        Expanded(
                            child: _dropdown('Format', _format, _formats,
                                (v) => setState(() => _format = v))),
                      ],
                    ),
                    _section('Details'),
                    _field('Release date (YYYY-MM-DD)', _date,
                        icon: Icons.event),
                    _field('Label', _label, icon: Icons.business),
                    _field('Barcode (UPC/EAN)', _barcode,
                        icon: Icons.qr_code_2),
                    _field('Disambiguation', _comment,
                        icon: Icons.style,
                        helper:
                            'What sets this edition apart — e.g. "Dolby Atmos"'),
                    _field('Related URL', _url,
                        icon: Icons.link,
                        helper:
                            'Streaming/store page; pick its link type on MB'),
                    _section('Tracklist · ${_tracks.length}'),
                    for (var i = 0; i < _tracks.length; i++) _trackRow(i),
                  ],
                ),
              ),
              // Footer
              Container(
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  border: Border(
                    top: BorderSide(color: Colors.white.withOpacity(0.06)),
                  ),
                ),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        'The final submit happens on musicbrainz.org under '
                        'your account — NASRadio captures the new MBID '
                        'automatically.',
                        style:
                            TextStyle(fontSize: 10.5, color: Colors.grey[600]),
                      ),
                    ),
                    const SizedBox(width: 12),
                    ElevatedButton.icon(
                      onPressed: _submit,
                      icon: const Icon(Icons.open_in_new, size: 18),
                      label: const Text('Continue to MusicBrainz'),
                      style: ElevatedButton.styleFrom(
                        backgroundColor: _accent,
                        foregroundColor: const Color(0xFF001220),
                        padding: const EdgeInsets.symmetric(
                            horizontal: 20, vertical: 14),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(10),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
