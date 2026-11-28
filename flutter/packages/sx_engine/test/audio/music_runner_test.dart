import 'dart:io';
import 'dart:typed_data';

import 'package:path/path.dart' as p;
import 'package:sx_api/sx_api.dart';
import 'package:sx_engine/src/audio/music_runner.dart';
import 'package:test/test.dart';

/// Ten seconds of silence as a 16-bit mono WAV.
void writeSilence(String path) {
  const fs = 44100, n = fs * 10;
  final b = ByteData(44 + n * 2);
  void str(int at, String s) => b.buffer.asUint8List().setAll(at, s.codeUnits);
  str(0, 'RIFF');
  b.setUint32(4, 36 + n * 2, Endian.little);
  str(8, 'WAVE');
  str(12, 'fmt ');
  b
    ..setUint32(16, 16, Endian.little)
    ..setUint16(20, 1, Endian.little)
    ..setUint16(22, 1, Endian.little)
    ..setUint32(24, fs, Endian.little)
    ..setUint32(28, fs * 2, Endian.little)
    ..setUint16(32, 2, Endian.little)
    ..setUint16(34, 16, Endian.little);
  str(36, 'data');
  b.setUint32(40, n * 2, Endian.little);
  File(path).writeAsBytesSync(b.buffer.asUint8List());
}

void main() {
  late Directory tmp;
  late MusicRunner runner;
  late File settings;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('sx_music_runner');
    writeSilence(p.join(tmp.path, 'first.wav'));
    writeSilence(p.join(tmp.path, 'second.wav'));
    settings = File(p.join(tmp.path, 'music.json'));
    // nothing listens on this port: the link stays off, which this test doesn't need
    runner = MusicRunner(
      settingsFile: () => settings,
      os2lPort: () => 47399,
      playerRunning: () => false,
      recordingsFolder: () => p.join(tmp.path, 'recordings'),
    );
  });

  tearDown(() async {
    await runner.stop();
    tmp.deleteSync(recursive: true);
  });

  MusicSettings withInput(String wav) => MusicSettings.fromJson({...const MusicSettings().toJson(), 'device': 'file:${p.join(tmp.path, wav)}'});

  Future<String> device() async {
    await Future<void>.delayed(const Duration(milliseconds: 500));
    return runner.status().device;
  }

  test('saving a new input while listening switches to it', () async {
    writeMusicSettings(settings, withInput('first.wav'));
    await runner.start();
    expect(await device(), contains('first.wav'));

    final next = withInput('second.wav');
    writeMusicSettings(settings, next);
    await runner.update(next);
    expect(runner.running, isTrue);
    expect(await device(), contains('second.wav'));
  });

  test('other changes keep the same input running', () async {
    final s = withInput('first.wav');
    writeMusicSettings(settings, s);
    await runner.start();
    final changed = MusicSettings.fromJson({...s.toJson(), 'dropBars': 4});
    await runner.update(changed);
    expect(await device(), contains('first.wav'));
  });

  test('record starts listening and writes what it hears until stopped', () async {
    writeMusicSettings(settings, withInput('first.wav'));
    final on = await runner.record(true);
    expect(runner.running, isTrue);
    expect(on.recording, startsWith(p.join(tmp.path, 'recordings', 'SX recording ')));
    await Future<void>.delayed(const Duration(milliseconds: 1500));
    expect(runner.status().recordedS, greaterThan(0.5));
    final off = await runner.record(false);
    expect(off.recording, '');
    expect(runner.running, isTrue, reason: 'stopping the recording keeps listening');
    final wav = File(on.recording);
    expect(wav.lengthSync(), greaterThan(44 + 44100));
    expect(ByteData.sublistView(wav.readAsBytesSync()).getUint32(40, Endian.little), wav.lengthSync() - 44);
    expect(File(p.join(tmp.path, 'recordings', '${p.basenameWithoutExtension(wav.path)} events.txt')).existsSync(), isTrue);
  });

  test('stopping listening stops the recording', () async {
    writeMusicSettings(settings, withInput('first.wav'));
    await runner.record(true);
    await runner.stop();
    expect(runner.status().recording, '');
    expect(Directory(p.join(tmp.path, 'recordings')).listSync().whereType<File>().where((f) => f.path.endsWith('.wav')), hasLength(1));
  });

  test('saving while not listening does not start it', () async {
    await runner.update(withInput('first.wav'));
    expect(runner.running, isFalse);
  });
}
