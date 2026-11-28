import 'dart:io';

import 'package:sx_api/sx_api.dart';

import '../../audio/audio_input.dart';
import '../../audio/music_runner.dart';
import '../../player/player_links.dart';
import '../../show/live_ini.dart';
import '../../show/show_env.dart';
import '../engine.dart';

/// The music detector, in the Strobe tab: settings, start and stop, and
/// what it hears. New in the Flutter app (the PowerShell app has no such
/// thing). Phones reach all of it.
void registerMusicRoutes(Engine e) {
  File file() => musicSettingsFile(e.settingsFolder);
  String? root() {
    try {
      return e.show().root;
    } on ToolError {
      return null;
    }
  }

  final runner = MusicRunner(
    settingsFile: file,
    os2lPort: () {
      final r = root();
      return r == null ? 7350 : readOs2lSetup(r).port;
    },
    playerRunning: () => e.find<PlayerControl>()?.running ?? false,
  );
  e.provide<MusicRunner>(runner);
  e.onStop(runner.stop);

  MusicInfo info([MusicSettings? s]) {
    s ??= readMusicSettings(file());
    final r = root();
    final os2l = r == null ? (on: false, port: 7350) : readOs2lSetup(r);
    var missing = <String>[];
    if (r != null) {
      try {
        final have = {for (final b in LiveInfo.read(ShowEnv(r)).buttons) b.title.trim().toLowerCase()};
        missing = [
          for (final t in s.titles)
            if (!have.contains(t.toLowerCase())) t,
        ];
      } on Object {
        // no live board to check against
      }
    }
    List<String> devices;
    try {
      devices = audioInputNames();
    } on Object {
      devices = const [];
    }
    return MusicInfo(
      settings: s,
      status: runner.status(),
      devices: devices,
      canListen: Platform.isWindows,
      os2lOn: os2l.on || (e.find<PlayerControl>()?.running ?? false),
      os2lPort: os2l.port,
      missing: missing.toSet().toList(),
    );
  }

  e.api.get('/api/music', (req) => info());

  e.api.get('/api/music/status', (req) => {'ok': true, 'status': runner.status().toJson()});

  e.api.post('/api/music/save', (req) async {
    final raw = req.body['settings'];
    if (raw is! Map) throw ToolError('Nothing to save.');
    final s = MusicSettings.fromJson(raw.cast<String, Object?>());
    writeMusicSettings(file(), s);
    await runner.update(s); // a new input starts listening again on it
    return info(s);
  });

  e.api.post('/api/music/start', (req) async => {'ok': true, 'status': (await runner.start()).toJson()});

  e.api.post('/api/music/record', (req) async => {'ok': true, 'status': (await runner.record(req.body['on'] == true)).toJson()});

  e.api.post('/api/music/stop', (req) async => {'ok': true, 'status': (await runner.stop()).toJson()});
}
