import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:path/path.dart' as p;
import 'package:sx_api/sx_api.dart';

import 'audio_input.dart';
import 'audio_recorder.dart';
import 'music_actions.dart';
import 'music_detector.dart';

// Listens to the mixer and plays the lights from what it hears: on its own
// isolate, so the 5 ms audio loop never waits for the engine and the engine
// never waits for it. What it hears goes to ShowXpress over OS2L (VirtualDJ's
// lighting link, see music_actions.dart). When the SX Player plays instead,
// it listens on the same port, so the same messages reach it.

/// The settings file, in SX Studio's own settings folder.
File musicSettingsFile(String settingsDir) => File(p.join(settingsDir, 'music.json'));

/// The settings in [f], or the defaults.
MusicSettings readMusicSettings(File f) {
  try {
    if (!f.existsSync()) return const MusicSettings();
    final j = jsonDecode(f.readAsStringSync());
    return j is Map ? MusicSettings.fromJson(j.cast<String, Object?>()) : const MusicSettings();
  } on Object {
    return const MusicSettings();
  }
}

/// Writes [s] to [f] (to a temporary name first, then swapped in).
void writeMusicSettings(File f, MusicSettings s) {
  f.parent.createSync(recursive: true);
  final tmp = File('${f.path}.tmp')..writeAsStringSync(const JsonEncoder.withIndent('  ').convert(s.toJson()));
  tmp.renameSync(f.path);
}

/// ShowXpress's VirtualDJ link from its param.ini, two folders above the
/// show: on (`OS2LENABLE = yes`) and its port (7350 when not set).
({bool on, int port}) readOs2lSetup(String showRoot) {
  final f = File(p.join(p.dirname(p.dirname(showRoot)), 'param.ini'));
  var on = false, port = 7350;
  if (f.existsSync()) {
    for (final l in const LineSplitter().convert(f.readAsStringSync())) {
      final m = RegExp(r'^(OS2L\w+) = (.*)$', caseSensitive: false).firstMatch(l);
      if (m == null) continue;
      final k = m[1]!.toUpperCase(), v = m[2]!.trim();
      if (k == 'OS2LENABLE') on = v.toLowerCase() == 'yes';
      if (k == 'OS2LPORT') port = int.tryParse(v) ?? port;
    }
  }
  return (on: on, port: port);
}

/// Starts and stops the listener, passes it new settings, and keeps its last status.
class MusicRunner {
  MusicRunner({required this.settingsFile, required this.os2lPort, required this.playerRunning, String Function()? recordingsFolder})
    : recordingsFolder = recordingsFolder ?? defaultRecordingsFolder;

  final File Function() settingsFile;

  /// Where to send OS2L. Read again at every start.
  final int Function() os2lPort;

  /// True while the SX Player plays: then it, not ShowXpress, gets the messages.
  final bool Function() playerRunning;

  /// Where recordings of what it hears go.
  final String Function() recordingsFolder;

  _Listener? _l;
  String _device = ''; // the input the running listener opened
  MusicStatus _status = const MusicStatus();

  bool get running => _l?.alive ?? false;

  /// The listener's last status, with who gets the messages named.
  MusicStatus status() {
    final s = _status;
    final live = running;
    return MusicStatus.fromJson({
      ...s.toJson(),
      'running': live,
      'link': live && s.link.isNotEmpty ? (playerRunning() ? 'SX Player' : 'ShowXpress') : '',
      if (!live) 'section': '',
      if (!live) 'on': <String>[],
      if (!live) 'recording': '',
      if (!live) 'recordedS': 0,
    });
  }

  /// Starts listening. A problem shows up in the status's `error`.
  Future<MusicStatus> start() async {
    if (running) return status();
    _status = const MusicStatus();
    try {
      final s = readMusicSettings(settingsFile());
      _device = s.device;
      _l = await _Listener.spawn((settings: s.toJson(), port: os2lPort()), (s) => _status = s);
      // give it a moment to open the input, so the answer says whether it worked
      await Future<void>.delayed(const Duration(milliseconds: 400));
    } on Object catch (e) {
      _status = MusicStatus(error: 'Could not start listening: $e');
    }
    return status();
  }

  /// New settings for a running listener. A different input can't be
  /// swapped in on the fly, so then it stops and starts again on the new one.
  Future<void> update(MusicSettings s) async {
    if (!running) return;
    if (s.device.trim() != _device.trim()) {
      await stop();
      await start();
      return;
    }
    _l?.commands.send(s.toJson());
  }

  /// Starts recording what it hears to a new WAV file in [recordingsFolder]
  /// (listening first, when it isn't), or stops the recording. Stopping
  /// listening stops the recording too.
  Future<MusicStatus> record(bool on) async {
    if (on) {
      if (!running) await start();
      if (!running) return status();
      final path = p.join(recordingsFolder(), recordingName(DateTime.now()));
      _l?.commands.send('rec:$path');
    } else {
      if (!running) return status();
      _l?.commands.send('rec-stop');
    }
    // the listener's next status says whether it is recording
    await Future<void>.delayed(const Duration(milliseconds: 300));
    return status();
  }

  /// Stops listening: every button it holds is released first.
  Future<MusicStatus> stop() async {
    final l = _l;
    _l = null;
    if (l != null && l.alive) {
      l.commands.send('q');
      await l.exited.timeout(const Duration(seconds: 3), onTimeout: () {});
    }
    return status();
  }
}

typedef _Args = ({Json settings, int port});

class _Listener {
  late final SendPort commands;
  final _exited = Completer<void>();

  Future<void> get exited => _exited.future;
  bool get alive => !_exited.isCompleted;

  static Future<_Listener> spawn(_Args args, void Function(MusicStatus) onStatus) async {
    final l = _Listener();
    final from = ReceivePort(), exit = ReceivePort();
    final first = Completer<SendPort>();
    from.listen((m) {
      if (m is SendPort) first.complete(m);
      if (m is Json) onStatus(MusicStatus.fromJson(m));
    });
    exit.listen((_) {
      exit.close();
      l._exited.complete();
      if (!first.isCompleted) first.completeError(StateError('the listener stopped at once'));
      Timer(const Duration(milliseconds: 200), from.close);
    });
    await Isolate.spawn(_main, (args, from.sendPort), onExit: exit.sendPort, debugName: 'music');
    l.commands = await first.future;
    return l;
  }
}

/// A connection to whoever listens for OS2L on this computer. Tries again
/// every 2 seconds while nothing answers.
class _Os2lOut {
  _Os2lOut(this.port);

  final int port;
  Socket? _s;
  bool _trying = false;
  var _next = DateTime.utc(1);
  String error = '';

  bool get connected => _s != null;

  void keepUp() {
    if (_s != null || _trying || DateTime.now().isBefore(_next)) return;
    _trying = true;
    _next = DateTime.now().add(const Duration(seconds: 2));
    Socket.connect('127.0.0.1', port, timeout: const Duration(milliseconds: 800)).then(
      (s) {
        s.setOption(SocketOption.tcpNoDelay, true);
        _s = s;
        error = '';
        _trying = false;
        // what comes back is not needed; the end of it means the link is gone
        s.listen((_) {}, onDone: _gone, onError: (Object _) => _gone(), cancelOnError: true);
        s.done.then((_) {}, onError: (Object _) => _gone());
      },
      onError: (Object _) {
        error = 'Nothing is listening on port $port. In ShowXpress: Preferences > Network > Virtual DJ: Enable.';
        _trying = false;
      },
    );
  }

  void _gone() {
    _s?.destroy();
    _s = null;
  }

  void send(List<String> msgs) {
    final s = _s;
    if (s == null || msgs.isEmpty) return;
    try {
      s.add(utf8.encode(msgs.join()));
    } on Object {
      _gone();
    }
  }

  void close() => _gone();
}

Future<void> _main((_Args, SendPort) a) async {
  final (args, owner) = a;
  final commands = ReceivePort();
  owner.send(commands.sendPort);
  var settings = MusicSettings.fromJson(args.settings);

  final AudioInput input;
  try {
    input = openAudioInput(settings.device);
  } on AudioInputError catch (e) {
    owner.send(MusicStatus(error: e.message).toJson());
    commands.close();
    return;
  }
  final det = MusicDetector(input.fs, leadS: settings.leadMs / 1000);
  final actions = MusicActions(settings);
  final out = _Os2lOut(args.port);
  final clock = Stopwatch()..start();
  double now() => clock.elapsedMicroseconds / 1e6;
  var bar = 0;
  var lastDrop = '';
  var lastStatus = -1.0;
  final done = Completer<void>();
  AudioRecorder? rec;
  var recError = '';
  var fed = 0; // samples given to the detector
  var held = '';

  void stopRecording() {
    rec?.close();
    rec = null;
  }

  void status() {
    owner.send(
      MusicStatus(
        running: true,
        device: input.name + (input is WavFileInput && input.finished ? ' (finished)' : ''),
        level: det.level,
        bpm: det.bpm,
        bar: bar,
        section: det.section.label,
        build: det.buildLevel,
        lastDrop: lastDrop,
        link: out.connected ? 'on' : '',
        linkError: out.connected ? '' : out.error,
        on: actions.on.toList(),
        recording: rec?.path ?? '',
        recordedS: rec?.seconds ?? 0,
        error: recError,
      ).toJson(),
    );
  }

  commands.listen((m) {
    if (m == 'q') {
      if (!done.isCompleted) done.complete();
    } else if (m is String && m.startsWith('rec:')) {
      stopRecording();
      try {
        rec = AudioRecorder.start(m.substring(4), input.fs, t0: fed / input.fs);
        recError = '';
      } on FileSystemException catch (e) {
        recError = 'Could not record to ${m.substring(4)}: ${e.osError?.message ?? e.message}';
      }
    } else if (m == 'rec-stop') {
      stopRecording();
    } else if (m is Map) {
      settings = MusicSettings.fromJson(m.cast<String, Object?>());
      out.send(actions.releaseAll());
      actions.settings = settings;
      det.leadS = settings.leadMs / 1000;
    }
  });

  final loop = Timer.periodic(const Duration(milliseconds: 5), (_) {
    out.keepUp();
    final t = now();
    final x = input.read();
    if (x.isNotEmpty) {
      fed += x.length;
      final r = rec;
      if (r != null) {
        r.add(x);
        if (r.full) stopRecording();
      }
      for (final e in det.feed(x)) {
        rec?.event(e);
        if (e.kind == MusicEventKind.beat) bar = e.bar;
        if (e.kind == MusicEventKind.drop) {
          final d = DateTime.now();
          lastDrop = '${d.hour}:${d.minute.toString().padLeft(2, '0')}:${d.second.toString().padLeft(2, '0')}';
        }
        out.send(actions.event(e, t));
      }
    }
    out.send(actions.tick(t));
    final h = actions.on.join(', ');
    if (h != held) {
      held = h;
      rec?.note(fed / input.fs, h.isEmpty ? 'lights: nothing held' : 'lights: $h');
    }
    if (t - lastStatus > 0.2) {
      lastStatus = t;
      status();
    }
  });

  await done.future;
  loop.cancel();
  stopRecording();
  out.send(actions.releaseAll());
  await Future<void>.delayed(const Duration(milliseconds: 50));
  out.close();
  input.close();
  commands.close();
}
