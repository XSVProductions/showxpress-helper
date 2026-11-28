import 'dart:async';

import 'package:flutter/material.dart';
import 'package:sx_api/sx_api.dart';

import '../../app_state.dart';
import '../../theme.dart';
import '../../widgets/sx_widgets.dart';

/// The music detector, in the Strobe tab: listens to the DJ feed from the
/// mixer and presses ShowXpress buttons for the break, the build, snare
/// hits, the gap and the drop, and sends ShowXpress every beat.
///
/// Its settings save on their own (they are SX Studio's, not the show's),
/// so this card doesn't touch the tab's Save bar.
class MusicCard extends StatefulWidget {
  const MusicCard({super.key});

  @override
  State<MusicCard> createState() => _MusicCardState();
}

class _MusicCardState extends State<MusicCard> {
  MusicInfo? _info;
  MusicSettings? _edit; // what the fields hold
  var _error = '';
  var _busy = false;
  Timer? _poll;

  final _fields = <String, TextEditingController>{};

  @override
  void initState() {
    super.initState();
    _load();
    _poll = Timer.periodic(const Duration(seconds: 1), (_) => _pollStatus());
  }

  @override
  void dispose() {
    _poll?.cancel();
    for (final c in _fields.values) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final i = await AppScope.read(context).client.music();
      if (!mounted) return;
      setState(() {
        _info = i;
        _edit = i.settings;
        _error = '';
        _fillFields(i.settings);
      });
    } on ApiException catch (e) {
      if (mounted) setState(() => _error = e.message);
    }
  }

  Future<void> _pollStatus() async {
    final i = _info;
    if (i == null || !i.status.running || _busy) return;
    try {
      final s = await AppScope.read(context).client.musicStatus();
      if (!mounted) return;
      setState(() => _info = MusicInfo.fromJson({...i.toJson(), 'status': s.toJson()}));
    } on ApiException {
      // the next poll tries again
    }
  }

  void _fillFields(MusicSettings s) {
    final values = {
      'device': s.device,
      'breakTitle': s.breakTitle,
      'build1': s.build1,
      'build2': s.build2,
      'build3': s.build3,
      'snare': s.snare,
      'gap': s.gap,
      'drop': s.drop,
      'dropBars': '${s.dropBars}',
      'leadMs': '${s.leadMs}',
    };
    for (final e in values.entries) {
      (_fields[e.key] ??= TextEditingController()).text = e.value;
    }
  }

  MusicSettings _fromFields() {
    String f(String k) => _fields[k]?.text.trim() ?? '';
    final base = _edit ?? const MusicSettings();
    return base.copyWith(
      device: f('device'),
      breakTitle: f('breakTitle'),
      build1: f('build1'),
      build2: f('build2'),
      build3: f('build3'),
      snare: f('snare'),
      gap: f('gap'),
      drop: f('drop'),
      dropBars: (int.tryParse(f('dropBars')) ?? base.dropBars).clamp(1, 64).toInt(),
      leadMs: (int.tryParse(f('leadMs')) ?? base.leadMs).clamp(0, 200).toInt(),
    );
  }

  bool get _changed => _info != null && _fromFields() != _info!.settings;

  Future<void> _run(Future<void> Function(SxClient c) call) async {
    setState(() => _busy = true);
    try {
      await call(AppScope.read(context).client);
    } on ApiException catch (e) {
      if (mounted) setState(() => _error = e.message);
    }
    if (mounted) setState(() => _busy = false);
  }

  Future<void> _save() => _run((c) async {
    final i = await c.musicSave(_fromFields());
    if (!mounted) return;
    setState(() {
      _info = i;
      _edit = i.settings;
      _error = '';
      _fillFields(i.settings);
    });
  });

  Future<void> _startStop(bool start) => _run((c) async {
    if (start && _changed) {
      final i = await c.musicSave(_fromFields());
      _edit = i.settings;
    }
    final s = start ? await c.musicStart() : await c.musicStop();
    if (!mounted) return;
    final i = _info;
    setState(() {
      if (i != null) _info = MusicInfo.fromJson({...i.toJson(), 'settings': (_edit ?? i.settings).toJson(), 'status': s.toJson()});
      _error = '';
    });
  });

  Future<void> _record(bool on) => _run((c) async {
    if (on && _changed) {
      final i = await c.musicSave(_fromFields());
      _edit = i.settings;
    }
    final s = await c.musicRecord(on);
    if (!mounted) return;
    final i = _info;
    setState(() {
      if (i != null) _info = MusicInfo.fromJson({...i.toJson(), 'settings': (_edit ?? i.settings).toJson(), 'status': s.toJson()});
      _error = '';
    });
  });

  @override
  Widget build(BuildContext context) {
    final i = _info;
    final run = i?.status.running ?? false;
    final recording = i?.status.recording.isNotEmpty ?? false;
    return SxCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SxHeader(
            'Music detector',
            sub:
                'Listens to the DJ feed from the mixer and presses your ShowXpress buttons for the break, the build, snare hits, the gap and the drop. '
                'It also sends ShowXpress every beat, so BPM scenes follow the music.',
            actions: [
              if (i != null)
                FilledButton(
                  onPressed: _busy || (!i.status.running && !i.canListen && !_fileInput) ? null : () => _startStop(!run),
                  child: Text(run ? 'Stop' : 'Start listening'),
                ),
            ],
          ),
          ErrorBox(_error),
          if (i == null && _error.isEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 14),
              child: Text('Reading the settings.', style: Sx.sub),
            ),
          if (i != null) ...[
            if (!i.canListen)
              _note('Listening to the mixer works on Windows for now. To try a recording here, type file: and the path of a WAV file as the input.'),
            if (!i.os2lOn)
              _note(
                "ShowXpress's VirtualDJ link is off, so it won't hear the beat or the button presses. Turn it on in ShowXpress: Preferences > Network > Virtual DJ: Enable (port ${i.os2lPort}).",
              ),
            if (i.status.error.isNotEmpty) ErrorBox(i.status.error),
            _statusBox(i.status),
            GroupLabel('Input'),
            _inputRow(i),
            const SizedBox(height: 10),
            Wrap(
              spacing: 10,
              runSpacing: 6,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                OutlinedButton.icon(
                  onPressed: _busy || (!i.status.running && !i.canListen && !_fileInput) ? null : () => _record(!recording),
                  icon: Icon(recording ? Icons.stop : Icons.fiber_manual_record, size: 16, color: recording ? null : Sx.redText),
                  label: Text(recording ? 'Stop recording' : 'Record'),
                ),
                Text('Saves what it hears as a WAV file in Music > SX Studio recordings, with a list of the breaks, builds and drops it found.', style: Sx.sub),
              ],
            ),
            GroupLabel('Buttons it presses'),
            Text('Type the title of a ShowXpress button for each moment. Leave one empty to skip it.', style: Sx.sub),
            const SizedBox(height: 8),
            _titleField('breakTitle', 'Break', 'on while the kick and bass are gone'),
            _titleField('build1', 'Build, low', 'on from 35% build'),
            _titleField('build2', 'Build, middle', 'on from 60%'),
            _titleField('build3', 'Build, high', 'on from 85%'),
            _titleField('snare', 'Snare hit', 'flashes on each snare in a build'),
            _titleField('gap', 'Gap', 'on in the silence before the drop'),
            _titleField('drop', 'Drop', 'on from the drop'),
            if (i.missing.isNotEmpty)
              _note('No live button is called ${i.missing.join(', ')}. Make those buttons in ShowXpress (your strobe scenes), or change the titles here.'),
            GroupLabel('Timing'),
            Wrap(
              spacing: 18,
              runSpacing: 8,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                _numField('dropBars', 'Drop button on for', 'bars'),
                _numField('leadMs', 'Beats go out', 'ms early'),
                _check('Send the beat to ShowXpress', (_edit ?? i.settings).beats, (v) => setState(() => _edit = (_edit ?? i.settings).copyWith(beats: v))),
                _check(
                  'Snare flashes outside builds too',
                  (_edit ?? i.settings).snareAlways,
                  (v) => setState(() => _edit = (_edit ?? i.settings).copyWith(snareAlways: v)),
                ),
              ],
            ),
            const SizedBox(height: 14),
            Row(
              children: [
                Expanded(
                  child: Text(
                    _changed ? 'Not saved yet.${run ? ' The detector picks the changes up when you save.' : ''}' : 'Saved in SX Studio, not in the show.',
                    style: Sx.sub,
                  ),
                ),
                OutlinedButton(onPressed: _busy || !_changed ? null : () => setState(() => _fillFields(_edit = i.settings)), child: const Text('Undo')),
                const SizedBox(width: 8),
                FilledButton(onPressed: _busy || !_changed ? null : _save, child: const Text('Save settings')),
              ],
            ),
          ],
        ],
      ),
    );
  }

  static String _clock(double seconds) {
    final s = seconds.floor();
    final m = s ~/ 60;
    return '${m ~/ 60}:${(m % 60).toString().padLeft(2, '0')}:${(s % 60).toString().padLeft(2, '0')}';
  }

  bool get _fileInput => (_fields['device']?.text.trim().toLowerCase() ?? '').startsWith('file:');

  Widget _note(String text) => Container(
    width: double.infinity,
    margin: const EdgeInsets.only(top: 12),
    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
    decoration: Sx.tint(Sx.amber),
    child: Text(text, style: TextStyle(color: Sx.text, fontSize: 13)),
  );

  Color _sectionColor(String s) => switch (s) {
    'BREAK' => Sx.blue,
    'BUILD' => Sx.amber,
    'DROP' => Sx.red,
    _ => Sx.dim,
  };

  Widget _statusBox(MusicStatus s) {
    if (!s.running) {
      return Padding(
        padding: const EdgeInsets.only(top: 12),
        child: Text('Not listening.', style: Sx.sub),
      );
    }
    final c = _sectionColor(s.section);
    final small = TextStyle(color: Sx.dim, fontSize: 12.5);
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.only(top: 12),
      padding: const EdgeInsets.all(12),
      decoration: Sx.tint(c),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Wrap(
            spacing: 14,
            runSpacing: 6,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              Text(
                s.section.isEmpty ? 'LISTENING' : s.section,
                style: TextStyle(fontFamily: Sx.display, fontSize: 18, fontWeight: FontWeight.w700, color: c, letterSpacing: 1),
              ),
              Text(
                s.bpm > 0 ? '${s.bpm.toStringAsFixed(1)} BPM' : 'finding the beat',
                style: TextStyle(color: Sx.text, fontSize: 14, fontWeight: FontWeight.w600),
              ),
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  for (var b = 1; b <= 4; b++)
                    Container(
                      width: 12,
                      height: 12,
                      margin: const EdgeInsets.only(right: 4),
                      decoration: BoxDecoration(
                        color: s.bar == b ? (b == 1 ? Sx.accent : Sx.text) : Sx.panel,
                        border: Border.all(color: Sx.line),
                        borderRadius: BorderRadius.circular(3),
                      ),
                    ),
                ],
              ),
              Text('input ${s.level.toStringAsFixed(0)} dB', style: small),
              if (s.lastDrop.isNotEmpty) Text('last drop ${s.lastDrop}', style: small),
            ],
          ),
          if (s.section == 'BREAK' || s.section == 'BUILD') ...[
            const SizedBox(height: 10),
            Row(
              children: [
                SizedBox(width: 44, child: Text('build', style: small)),
                Expanded(
                  child: Container(
                    height: 8,
                    decoration: BoxDecoration(color: Sx.panel, borderRadius: BorderRadius.circular(4)),
                    alignment: Alignment.centerLeft,
                    child: FractionallySizedBox(
                      widthFactor: s.build.clamp(0.0, 1.0).toDouble(),
                      child: Container(
                        decoration: BoxDecoration(color: Sx.amber, borderRadius: BorderRadius.circular(4)),
                      ),
                    ),
                  ),
                ),
                SizedBox(width: 44, child: Text(' ${(s.build * 100).round()}%', style: small)),
              ],
            ),
          ],
          const SizedBox(height: 8),
          Text(
            s.link.isNotEmpty
                ? 'Sending to ${s.link}.${s.on.isEmpty ? '' : ' Holding ${s.on.join(', ')}.'}'
                : (s.linkError.isEmpty ? 'Connecting to ShowXpress.' : s.linkError),
            style: TextStyle(color: s.link.isNotEmpty ? Sx.text : Sx.redText, fontSize: 12.5),
          ),
          Text('Listening to ${s.device}.', style: small),
          if (s.recording.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Text(
                'Recording ${_clock(s.recordedS)} to ${s.recording}, with what it found in an events file next to it.',
                style: TextStyle(color: Sx.redText, fontSize: 12.5, fontWeight: FontWeight.w600),
              ),
            ),
        ],
      ),
    );
  }

  Widget _inputRow(MusicInfo i) {
    final c = _fields['device']!;
    final items = <String, String>{'': 'Automatic (the DM3, or the default input)', for (final d in i.devices) d: d};
    return Wrap(
      spacing: 10,
      runSpacing: 8,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        if (i.devices.isNotEmpty)
          SizedBox(
            width: 340,
            child: SxMenu<String>(
              items: items,
              value: items.containsKey(c.text) ? c.text : null,
              hint: c.text.isEmpty ? '' : 'Typed below',
              onPick: (v) => setState(() => c.text = v),
            ),
          ),
        SizedBox(
          width: 340,
          child: TextField(
            controller: c,
            onChanged: (_) => setState(() {}),
            decoration: const InputDecoration(hintText: 'Or type part of its name, or file: and a WAV path', isDense: true),
          ),
        ),
        Text('Send the DJ channels to USB out 1-2 on the DM3.', style: Sx.sub),
      ],
    );
  }

  Widget _titleField(String key, String label, String help) => Padding(
    padding: const EdgeInsets.only(bottom: 6),
    child: Wrap(
      spacing: 10,
      runSpacing: 4,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        SizedBox(
          width: 110,
          child: Text(
            label,
            style: TextStyle(color: Sx.text, fontSize: 13, fontWeight: FontWeight.w600),
          ),
        ),
        SizedBox(
          width: 220,
          child: TextField(
            controller: _fields[key],
            onChanged: (_) => setState(() {}),
            decoration: const InputDecoration(hintText: 'not used', isDense: true),
          ),
        ),
        Text(help, style: Sx.sub),
      ],
    ),
  );

  Widget _numField(String key, String before, String after) => Row(
    mainAxisSize: MainAxisSize.min,
    children: [
      Text(before, style: TextStyle(color: Sx.text, fontSize: 13)),
      const SizedBox(width: 8),
      SizedBox(
        width: 56,
        child: TextField(
          controller: _fields[key],
          keyboardType: TextInputType.number,
          textAlign: TextAlign.right,
          onChanged: (_) => setState(() {}),
          decoration: const InputDecoration(isDense: true),
        ),
      ),
      const SizedBox(width: 6),
      Text(after, style: Sx.sub),
    ],
  );

  Widget _check(String text, bool value, ValueChanged<bool> onChanged) => Row(
    mainAxisSize: MainAxisSize.min,
    children: [
      Checkbox(value: value, onChanged: (v) => onChanged(v ?? false), visualDensity: VisualDensity.compact),
      Text(text, style: TextStyle(color: Sx.text, fontSize: 13)),
    ],
  );
}
