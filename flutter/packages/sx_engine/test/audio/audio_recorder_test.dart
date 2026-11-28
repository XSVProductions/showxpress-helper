import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:path/path.dart' as p;
import 'package:sx_engine/src/audio/audio_input.dart';
import 'package:sx_engine/src/audio/audio_recorder.dart';
import 'package:sx_engine/src/audio/music_detector.dart';
import 'package:test/test.dart';

void main() {
  late Directory tmp;

  setUp(() => tmp = Directory.systemTemp.createTempSync('sx_recorder'));
  tearDown(() => tmp.deleteSync(recursive: true));

  Float64List tone(int n, int from) => Float64List.fromList([for (var i = 0; i < n; i++) 0.5 * math.sin((from + i) * 0.05)]);

  test('the recording plays back as an input, with the same sound', () {
    final path = p.join(tmp.path, 'sub', 'set.wav');
    final r = AudioRecorder.start(path, 8000);
    r
      ..add(tone(3000, 0))
      ..add(tone(9000, 3000))
      ..close();
    expect(r.seconds, 1.5);
    final back = WavFileInput(path);
    expect(back.fs, 8000);
    final f = File(path).openSync();
    final all = Uint8List(24000);
    f
      ..setPositionSync(44)
      ..readIntoSync(all);
    f.closeSync();
    back.close();
    final d = ByteData.sublistView(all);
    for (final i in [0, 2999, 3000, 11999]) {
      expect(d.getInt16(i * 2, Endian.little) / 32767, closeTo(0.5 * math.sin(i * 0.05), 1e-4));
    }
  });

  test('a recording cut short still has a correct header up to the last flush', () {
    final path = p.join(tmp.path, 'cut.wav');
    final r = AudioRecorder.start(path, 8000)..add(tone(20000, 0)); // flushed once a second of sound
    final b = ByteData.sublistView(File(path).readAsBytesSync());
    final data = b.getUint32(40, Endian.little);
    expect(data, greaterThanOrEqualTo(2 * 8000));
    expect(File(path).lengthSync(), 44 + data);
    r.close();
    expect(ByteData.sublistView(File(path).readAsBytesSync()).getUint32(40, Endian.little), 40000);
  });

  test('the events file has the sections, drops and lights, by time in the recording', () {
    final path = p.join(tmp.path, 'ev.wav');
    final r = AudioRecorder.start(path, 8000, t0: 100);
    r
      ..event(const MusicEvent(160, MusicEventKind.section, section: MusicSection.build))
      ..event(const MusicEvent(160.5, MusicEventKind.kick, value: 10))
      ..event(const MusicEvent(161, MusicEventKind.build, value: 0.4))
      ..event(const MusicEvent(161.5, MusicEventKind.build, value: 0.5)) // under a second later: not written
      ..event(const MusicEvent(162.2, MusicEventKind.build, value: 0.7))
      ..note(163, 'lights: AUTO BUILD 2')
      ..event(const MusicEvent(3700, MusicEventKind.drop, value: 0.82))
      ..close();
    final lines = File(AudioRecorder.eventsPathOf(path)).readAsLinesSync();
    expect(lines.skip(1), [
      '0:01:00.0  BUILD',
      '0:01:01.0    build 40%',
      '0:01:02.2    build 70%',
      '0:01:03.0  lights: AUTO BUILD 2',
      '1:00:00.0  DROP (build reached 82%)',
    ]);
  });

  test('file names sort by date and Windows accepts them', () {
    expect(recordingName(DateTime(2026, 11, 28, 21, 5, 9)), 'SX recording 2026-11-28 21-05-09.wav');
    expect(AudioRecorder.eventsPathOf('/x/SX recording 1.wav'), endsWith('SX recording 1 events.txt'));
  });
}
