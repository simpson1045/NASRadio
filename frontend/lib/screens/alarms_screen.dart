import 'package:flutter/material.dart';

import '../services/alarm_service.dart';
import '../widgets/alarm_source_picker.dart';

const _accent = Color(0xFF00d4ff);

String _fmtTime(int hour, int minute) {
  final h = hour % 12 == 0 ? 12 : hour % 12;
  return '$h:${minute.toString().padLeft(2, '0')} ${hour < 12 ? 'AM' : 'PM'}';
}

/// Wake-up alarm list: add, edit, toggle, delete, test.
class AlarmsScreen extends StatefulWidget {
  const AlarmsScreen({super.key});

  @override
  State<AlarmsScreen> createState() => _AlarmsScreenState();
}

class _AlarmsScreenState extends State<AlarmsScreen>
    with WidgetsBindingObserver {
  final _svc = AlarmService.instance;
  List<WakeAlarm> _alarms = [];
  DateTime? _next;
  Map<String, bool> _perms = const {};
  bool _loading = true;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _refresh();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  // Back from Android settings (permission toggles), or a one-time alarm
  // switched itself off after ringing: reload.
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) _refresh();
  }

  void _sort() => _alarms.sort(
      (a, b) => (a.hour * 60 + a.minute).compareTo(b.hour * 60 + b.minute));

  Future<void> _refresh() async {
    final alarms = await _svc.load();
    final next = await _svc.nextAlarmAt();
    final perms = await _svc.permissions();
    if (!mounted) return;
    setState(() {
      _alarms = alarms;
      _sort();
      _next = next;
      _perms = perms;
      _loading = false;
    });
  }

  Future<void> _save() async {
    setState(() => _saving = true);
    try {
      final next = await _svc.save(_alarms);
      if (mounted) setState(() => _next = next);
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  String get _nextLabel {
    final next = _next;
    if (next == null) return 'No alarms set';
    final diff = next.difference(DateTime.now());
    final h = diff.inHours;
    final m = diff.inMinutes % 60;
    final inText = h > 0 ? '${h}h ${m}m' : '${diff.inMinutes < 1 ? '<1' : m}m';
    final day = WakeAlarm.dayNames[next.weekday - 1];
    return 'Next alarm: $day ${_fmtTime(next.hour, next.minute)} (in $inText)';
  }

  Future<void> _edit([WakeAlarm? existing]) async {
    final draft = existing?.copy() ??
        WakeAlarm(
          id: _alarms.fold<int>(0, (m, a) => a.id > m ? a.id : m) + 1,
          hour: 7,
          minute: 0,
        );
    final result = await Navigator.of(context).push<WakeAlarm>(
      MaterialPageRoute(
        fullscreenDialog: true,
        builder: (_) => _AlarmEditorPage(alarm: draft, isNew: existing == null),
      ),
    );
    if (result == null) return;
    setState(() {
      _alarms.removeWhere((a) => a.id == result.id);
      _alarms.add(result..enabled = true);
      _sort();
    });
    await _save();
  }

  Future<void> _test(WakeAlarm a) async {
    // Make sure the alarm (and its song list) is saved before ringing it.
    if (!a.enabled) {
      setState(() => a.enabled = true);
    }
    await _save();
    await _svc.testIn(a.id, 60);
    final next = await _svc.nextAlarmAt();
    if (!mounted) return;
    setState(() => _next = next);
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text('"${a.label}" will ring in 1 minute. Lock the phone to try it.'),
    ));
  }

  Widget _permissionBanner() {
    final rows = <Widget>[
      if (_perms['notifications'] == false)
        _bannerRow("Notifications are off, so the alarm screen can't appear.",
            'Allow', () async {
          await _svc.requestNotifications();
          await _refresh();
        }),
      if (_perms['exact'] == false)
        _bannerRow('Android is blocking exact alarms.', 'Fix',
            _svc.openExactAlarmSettings),
      if (_perms['fullScreen'] == false)
        _bannerRow("Alarms can't show over the lock screen yet.", 'Fix',
            _svc.openFullScreenSettings),
    ];
    if (rows.isEmpty) return const SizedBox.shrink();
    return Card(
      color: const Color(0xFF3a2a10),
      margin: const EdgeInsets.fromLTRB(16, 8, 16, 8),
      child: Padding(
        padding: const EdgeInsets.all(8),
        child: Column(children: rows),
      ),
    );
  }

  Widget _bannerRow(String msg, String action, Future<void> Function() fix) =>
      Row(
        children: [
          Expanded(
            child: Padding(
              padding: const EdgeInsets.only(left: 4),
              child:
                  Text(msg, style: const TextStyle(color: Colors.orangeAccent)),
            ),
          ),
          TextButton(onPressed: fix, child: Text(action)),
        ],
      );

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Alarms'),
        bottom: _saving
            ? const PreferredSize(
                preferredSize: Size.fromHeight(2),
                child: LinearProgressIndicator(minHeight: 2),
              )
            : null,
      ),
      floatingActionButton: FloatingActionButton(
        onPressed: () => _edit(),
        backgroundColor: _accent,
        foregroundColor: Colors.black,
        child: const Icon(Icons.add),
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: const EdgeInsets.only(bottom: 96),
              children: [
                _permissionBanner(),
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
                  child: Text(_nextLabel,
                      style: const TextStyle(color: Colors.grey)),
                ),
                if (_alarms.isEmpty)
                  const Padding(
                    padding: EdgeInsets.all(32),
                    child: Text(
                      'No alarms yet. Tap + to add one.',
                      textAlign: TextAlign.center,
                      style: TextStyle(color: Colors.grey),
                    ),
                  ),
                for (final a in _alarms)
                  Dismissible(
                    key: ValueKey(a.id),
                    direction: DismissDirection.endToStart,
                    background: Container(
                      color: Colors.red.shade900,
                      alignment: Alignment.centerRight,
                      padding: const EdgeInsets.only(right: 24),
                      child: const Icon(Icons.delete, color: Colors.white),
                    ),
                    onDismissed: (_) {
                      setState(() => _alarms.remove(a));
                      _save();
                    },
                    child: ListTile(
                      onTap: () => _edit(a),
                      title: Text(
                        _fmtTime(a.hour, a.minute),
                        style: TextStyle(
                          fontSize: 32,
                          fontWeight: FontWeight.w300,
                          color: a.enabled ? Colors.white : Colors.grey,
                        ),
                      ),
                      subtitle: Text(
                        '${a.label} · ${a.daysLabel}\n${a.sourceLabel}',
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                      ),
                      isThreeLine: true,
                      trailing: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          IconButton(
                            tooltip: 'Test in 1 minute',
                            icon: const Icon(Icons.alarm_on, color: Colors.grey),
                            onPressed: () => _test(a),
                          ),
                          Switch(
                            value: a.enabled,
                            activeTrackColor: _accent,
                            onChanged: (v) {
                              setState(() => a.enabled = v);
                              _save();
                            },
                          ),
                        ],
                      ),
                    ),
                  ),
              ],
            ),
    );
  }
}

/// Add/edit: time, repeat days, label, what to play, volume, fade-in.
class _AlarmEditorPage extends StatefulWidget {
  final WakeAlarm alarm;
  final bool isNew;
  const _AlarmEditorPage({required this.alarm, required this.isNew});

  @override
  State<_AlarmEditorPage> createState() => _AlarmEditorPageState();
}

class _AlarmEditorPageState extends State<_AlarmEditorPage> {
  late final WakeAlarm _a = widget.alarm;
  late final TextEditingController _label =
      TextEditingController(text: _a.label);

  static const _fades = [0, 30, 60, 120];
  static const _fadeLabels = ['Off', '30 s', '1 min', '2 min'];

  @override
  void dispose() {
    _label.dispose();
    AlarmService.instance.stopPreview();
    super.dispose();
  }

  Future<void> _pickTime() async {
    final t = await showTimePicker(
      context: context,
      initialTime: TimeOfDay(hour: _a.hour, minute: _a.minute),
    );
    if (t != null) {
      setState(() {
        _a.hour = t.hour;
        _a.minute = t.minute;
      });
    }
  }

  Future<void> _pickSource() async {
    final s = await showAlarmSourcePicker(context);
    if (s == null) return;
    setState(() {
      _a.sourceType = s.type;
      _a.sourceId = s.id;
      _a.sourceName = s.name;
      _a.extra.remove('queue'); // rebuilt on save
    });
  }

  void _done() {
    final text = _label.text.trim();
    _a.label = text.isEmpty ? 'Alarm' : text;
    Navigator.of(context).pop(_a);
  }

  Widget _section(String title) => Padding(
        padding: const EdgeInsets.fromLTRB(16, 20, 16, 6),
        child: Text(title,
            style: const TextStyle(
                color: _accent, fontWeight: FontWeight.bold, fontSize: 15)),
      );

  @override
  Widget build(BuildContext context) {
    final canShuffle =
        _a.sourceType == 'playlist' || _a.sourceType == 'album';
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.isNew ? 'New alarm' : 'Edit alarm'),
        actions: [
          TextButton(onPressed: _done, child: const Text('Save')),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.only(bottom: 32),
        children: [
          Center(
            child: TextButton(
              onPressed: _pickTime,
              child: Text(
                _fmtTime(_a.hour, _a.minute),
                style:
                    const TextStyle(fontSize: 52, fontWeight: FontWeight.w300),
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Wrap(
              alignment: WrapAlignment.center,
              spacing: 4,
              children: [
                for (var i = 0; i < 7; i++)
                  FilterChip(
                    label: Text(WakeAlarm.dayLetters[i]),
                    showCheckmark: false,
                    selected: _a.hasDay(i),
                    onSelected: (on) => setState(() => _a.days =
                        on ? _a.days | (1 << i) : _a.days & ~(1 << i)),
                  ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.only(top: 6),
            child: Text(
              _a.days == 0 ? 'No days picked: rings once.' : _a.daysLabel,
              textAlign: TextAlign.center,
              style: const TextStyle(fontSize: 12, color: Colors.grey),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
            child: TextField(
              controller: _label,
              decoration: const InputDecoration(labelText: 'Label'),
            ),
          ),
          _section('Wake to'),
          ListTile(
            leading: Icon(
              _a.sourceType == null ? Icons.notifications_active : Icons.music_note,
              color: _accent,
            ),
            title: Text(_a.sourceLabel,
                maxLines: 2, overflow: TextOverflow.ellipsis),
            trailing: const Icon(Icons.chevron_right),
            onTap: _pickSource,
          ),
          if (canShuffle)
            SwitchListTile(
              title: const Text('Shuffle'),
              value: _a.shuffle,
              activeTrackColor: _accent,
              onChanged: (v) => setState(() => _a.shuffle = v),
            ),
          _section('Wake volume'),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8),
            child: Row(
              children: [
                const Icon(Icons.volume_down, color: Colors.grey),
                Expanded(
                  child: Slider(
                    value: _a.volume.toDouble(),
                    min: 5,
                    max: 100,
                    divisions: 19,
                    label: '${_a.volume}%',
                    activeColor: _accent,
                    onChanged: (v) => setState(() => _a.volume = v.round()),
                  ),
                ),
                Text('${_a.volume}%',
                    style: const TextStyle(color: Colors.grey)),
                IconButton(
                  tooltip: 'Preview (3 seconds)',
                  icon: const Icon(Icons.play_circle_outline, color: _accent),
                  onPressed: () => AlarmService.instance.preview(_a.volume),
                ),
              ],
            ),
          ),
          const Padding(
            padding: EdgeInsets.symmetric(horizontal: 16),
            child: Text(
              "The alarm uses this level, not your phone's alarm volume. "
              'Preview plays the alarm tone at this level.',
              style: TextStyle(fontSize: 12, color: Colors.grey),
            ),
          ),
          _section('Fade in'),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: SegmentedButton<int>(
              segments: [
                for (var i = 0; i < _fades.length; i++)
                  ButtonSegment(value: _fades[i], label: Text(_fadeLabels[i])),
              ],
              selected: {
                _fades.contains(_a.fadeSeconds) ? _a.fadeSeconds : 60
              },
              onSelectionChanged: (s) =>
                  setState(() => _a.fadeSeconds = s.first),
            ),
          ),
          const Padding(
            padding: EdgeInsets.fromLTRB(16, 6, 16, 0),
            child: Text(
              'Starts nearly silent and rises to the wake volume.',
              style: TextStyle(fontSize: 12, color: Colors.grey),
            ),
          ),
        ],
      ),
    );
  }
}
