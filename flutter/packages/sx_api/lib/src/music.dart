import 'client.dart';
import 'json.dart';

/// How the music detector plays the lights. Kept in SX Studio's own settings
/// (`music.json`), never in the show.
///
/// The detector presses buttons by their title, through ShowXpress's
/// VirtualDJ link (OS2L), or on the SX Player when that plays. A title left
/// empty is not used.
class MusicSettings {
  const MusicSettings({
    this.device = '',
    this.beats = true,
    this.breakTitle = '',
    this.build1 = 'AUTO BUILD 1',
    this.build2 = 'AUTO BUILD 2',
    this.build3 = 'AUTO BUILD 3',
    this.snare = 'AUTO SNARE',
    this.snareAlways = false,
    this.gap = 'AUTO GAP',
    this.drop = 'AUTO DROP',
    this.dropBars = 8,
    this.leadMs = 30,
  });

  factory MusicSettings.fromJson(Json j) {
    const d = MusicSettings();
    String s(String k, String def) => j.containsKey(k) ? j.str(k).trim() : def;
    return MusicSettings(
      device: s('device', d.device),
      beats: j.containsKey('beats') ? j.boolean('beats') : d.beats,
      breakTitle: s('breakTitle', d.breakTitle),
      build1: s('build1', d.build1),
      build2: s('build2', d.build2),
      build3: s('build3', d.build3),
      snare: s('snare', d.snare),
      snareAlways: j.boolean('snareAlways'),
      gap: s('gap', d.gap),
      drop: s('drop', d.drop),
      dropBars: j.containsKey('dropBars') ? j.integer('dropBars').clamp(1, 64).toInt() : d.dropBars,
      leadMs: j.containsKey('leadMs') ? j.integer('leadMs').clamp(0, 200).toInt() : d.leadMs,
    );
  }

  /// The audio input to listen to. '' = the first one with DM3 or Yamaha in its name, else Windows' default.
  final String device;

  /// Send every beat to ShowXpress, so its BPM scenes follow the music.
  final bool beats;

  /// On while the kick and bass are gone (a break).
  final String breakTitle;

  /// On while a build is at least 35%, 60% and 85%. One at a time.
  final String build1, build2, build3;

  /// Flashes on every snare hit during a build (or always, with [snareAlways]).
  final String snare;
  final bool snareAlways;

  /// On in the silence just before a drop.
  final String gap;

  /// On for [dropBars] bars from the drop.
  final String drop;
  final int dropBars;

  /// Beats go out this many ms early, to make up for the delay of the audio input.
  final int leadMs;

  /// Every title in use, in the order the screen lists them.
  List<String> get titles => [
    for (final t in [breakTitle, build1, build2, build3, snare, gap, drop])
      if (t.isNotEmpty) t,
  ];

  MusicSettings copyWith({
    String? device,
    bool? beats,
    String? breakTitle,
    String? build1,
    String? build2,
    String? build3,
    String? snare,
    bool? snareAlways,
    String? gap,
    String? drop,
    int? dropBars,
    int? leadMs,
  }) => MusicSettings(
    device: device ?? this.device,
    beats: beats ?? this.beats,
    breakTitle: breakTitle ?? this.breakTitle,
    build1: build1 ?? this.build1,
    build2: build2 ?? this.build2,
    build3: build3 ?? this.build3,
    snare: snare ?? this.snare,
    snareAlways: snareAlways ?? this.snareAlways,
    gap: gap ?? this.gap,
    drop: drop ?? this.drop,
    dropBars: dropBars ?? this.dropBars,
    leadMs: leadMs ?? this.leadMs,
  );

  Json toJson() => {
    'device': device,
    'beats': beats,
    'breakTitle': breakTitle,
    'build1': build1,
    'build2': build2,
    'build3': build3,
    'snare': snare,
    'snareAlways': snareAlways,
    'gap': gap,
    'drop': drop,
    'dropBars': dropBars,
    'leadMs': leadMs,
  };

  @override
  bool operator ==(Object other) => other is MusicSettings && '${other.toJson()}' == '${toJson()}';

  @override
  int get hashCode => '${toJson()}'.hashCode;
}

/// What the music detector is doing now.
class MusicStatus {
  const MusicStatus({
    this.running = false,
    this.device = '',
    this.error = '',
    this.level = -90,
    this.bpm = 0,
    this.bar = 0,
    this.section = '',
    this.build = 0,
    this.lastDrop = '',
    this.link = '',
    this.linkError = '',
    this.on = const [],
    this.recording = '',
    this.recordedS = 0,
  });

  factory MusicStatus.fromJson(Json j) => MusicStatus(
    running: j.boolean('running'),
    device: j.str('device'),
    error: j.str('error'),
    level: j.number('level'),
    bpm: j.number('bpm'),
    bar: j.integer('bar'),
    section: j.str('section'),
    build: j.number('build'),
    lastDrop: j.str('lastDrop'),
    link: j.str('link'),
    linkError: j.str('linkError'),
    on: j.strList('on'),
    recording: j.str('recording'),
    recordedS: j.number('recordedS'),
  );

  final bool running;

  /// The audio input it listens to.
  final String device;

  /// Why it isn't listening, '' when it is.
  final String error;

  /// The feed's level in dB (0 = full scale), for a meter.
  final double level;

  /// The tempo, 0 while it isn't known yet.
  final double bpm;

  /// The place in the bar of the last beat, 1 to 4 (0 before the first).
  final int bar;

  /// GROOVE, BREAK, BUILD or DROP ('' while it isn't listening).
  final String section;

  /// The build level, 0..1.
  final double build;

  /// When the last drop was heard (time of day), '' before the first.
  final String lastDrop;

  /// Who gets the beat and the presses: 'ShowXpress', 'SX Player', or '' when nothing answers.
  final String link;
  final String linkError;

  /// The titles held on now.
  final List<String> on;

  /// The WAV file it is recording what it hears to, '' when it isn't.
  final String recording;

  /// How long that recording is so far, in seconds.
  final double recordedS;

  Json toJson() => {
    'running': running,
    'device': device,
    'error': error,
    'level': level,
    'bpm': bpm,
    'bar': bar,
    'section': section,
    'build': build,
    'lastDrop': lastDrop,
    'link': link,
    'linkError': linkError,
    'on': on,
    'recording': recording,
    'recordedS': recordedS,
  };
}

/// What the music card shows: the settings, the status, the audio inputs,
/// and whether ShowXpress's VirtualDJ link (OS2L) is on.
class MusicInfo {
  const MusicInfo({
    required this.settings,
    required this.status,
    required this.devices,
    required this.canListen,
    required this.os2lOn,
    required this.os2lPort,
    required this.missing,
  });

  factory MusicInfo.fromJson(Json j) => MusicInfo(
    settings: MusicSettings.fromJson(j.obj('settings')),
    status: MusicStatus.fromJson(j.obj('status')),
    devices: j.strList('devices'),
    canListen: j.boolean('canListen'),
    os2lOn: j.boolean('os2lOn'),
    os2lPort: j.integer('os2lPort'),
    missing: j.strList('missing'),
  );

  final MusicSettings settings;
  final MusicStatus status;

  /// The audio inputs on this computer.
  final List<String> devices;

  /// False where listening isn't built yet (a Mac) or not allowed (a phone's own audio).
  final bool canListen;

  /// ShowXpress Preferences > Network > Virtual DJ is enabled, and its port.
  final bool os2lOn;
  final int os2lPort;

  /// Titles in the settings that no live button has.
  final List<String> missing;

  Json toJson() => {
    'ok': true,
    'settings': settings.toJson(),
    'status': status.toJson(),
    'devices': devices,
    'canListen': canListen,
    'os2lOn': os2lOn,
    'os2lPort': os2lPort,
    'missing': missing,
  };
}

extension MusicApi on SxClient {
  Future<MusicInfo> music() => get('/api/music', MusicInfo.fromJson);

  Future<MusicStatus> musicStatus() => get('/api/music/status', (j) => MusicStatus.fromJson(j.obj('status')));

  /// Saves the settings. A running detector picks them up at once.
  Future<MusicInfo> musicSave(MusicSettings s) => post('/api/music/save', {'settings': s.toJson()}, MusicInfo.fromJson);

  Future<MusicStatus> musicStart() => post('/api/music/start', const <String, Object?>{}, (j) => MusicStatus.fromJson(j.obj('status')));

  /// Starts recording what the detector hears (listening first if it isn't), or stops the recording.
  Future<MusicStatus> musicRecord(bool on) => post('/api/music/record', {'on': on}, (j) => MusicStatus.fromJson(j.obj('status')));

  Future<MusicStatus> musicStop() => post('/api/music/stop', const <String, Object?>{}, (j) => MusicStatus.fromJson(j.obj('status')));
}
