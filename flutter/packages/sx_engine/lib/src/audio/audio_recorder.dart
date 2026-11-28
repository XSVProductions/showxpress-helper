import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:path/path.dart' as p;

import 'music_detector.dart';

// Records what the music detector hears, to try the detector on a real set
// afterwards: the sound as a 16-bit mono WAV (what the detector itself works
// on), and next to it a text file of what it found, by time in the
// recording. Played back as the input (`file:` and the WAV's path), the
// recording gives the detector the same sound again.
//
// New in the Flutter app.

/// The longest recording, in seconds. About 950 MB at 44.1 kHz.
const maxRecordingS = 3 * 3600;

/// Where recordings go: `Music\SX Studio recordings` in the user's folder.
String defaultRecordingsFolder() {
  final home = Platform.environment['USERPROFILE'] ?? Platform.environment['HOME'] ?? Directory.systemTemp.path;
  return p.join(home, 'Music', 'SX Studio recordings');
}

/// A recording's file name for [when], like `SX recording 2026-11-28 21-05-09.wav`.
String recordingName(DateTime when) {
  String two(int v) => v.toString().padLeft(2, '0');
  return 'SX recording ${when.year}-${two(when.month)}-${two(when.day)} ${two(when.hour)}-${two(when.minute)}-${two(when.second)}.wav';
}

/// Writes the detector's input to a WAV file as it comes, and its events to
/// a text file beside it. The WAV's header is brought up to date at every
/// flush, so a recording cut short (the app closed, the laptop off) still
/// opens.
class AudioRecorder {
  AudioRecorder._(this.path, this.fs, this.t0, this._wav, this._log);

  /// Starts a recording at [path] (made with its folder), [fs] samples a
  /// second. [t0] is the detector's time (seconds fed) at its start.
  factory AudioRecorder.start(String path, int fs, {double t0 = 0}) {
    File(path).parent.createSync(recursive: true);
    final wav = File(path).openSync(mode: FileMode.write)..writeFromSync(_header(fs, 0));
    final log = File(eventsPathOf(path)).openSync(mode: FileMode.write)
      ..writeStringSync('# What the music detector found in ${p.basename(path)}, by time in the recording.\r\n');
    return AudioRecorder._(path, fs, t0, wav, log);
  }

  /// The text file of events next to the WAV at [wavPath].
  static String eventsPathOf(String wavPath) => '${p.withoutExtension(wavPath)} events.txt';

  final String path;
  final int fs;

  /// The detector's time at the start of the recording: event times are counted from it.
  final double t0;
  final RandomAccessFile _wav, _log;
  final _buf = BytesBuilder(copy: false);
  int _frames = 0, _flushed = 0;
  bool _closed = false;
  String _lastBuild = '';
  double _lastBuildT = -1;

  /// Seconds recorded.
  double get seconds => _frames / fs;

  /// True once [maxRecordingS] is reached: nothing more is written.
  bool get full => _frames >= maxRecordingS * fs;

  /// Adds mono samples (-1..1).
  void add(Float64List x) {
    if (_closed || x.isEmpty) return;
    final n = math.min(x.length, maxRecordingS * fs - _frames);
    if (n <= 0) return;
    final out = ByteData(n * 2);
    for (var i = 0; i < n; i++) {
      out.setInt16(i * 2, (x[i] * 32767).round().clamp(-32768, 32767).toInt(), Endian.little);
    }
    _buf.add(out.buffer.asUint8List());
    _frames += n;
    if (_frames - _flushed >= fs) flush(); // about once a second
  }

  /// Writes down a detector event: the section changes, the gap, drops and
  /// returns, and the build level about once a second while it changes.
  void event(MusicEvent e) {
    if (_closed) return;
    final at = _time(e.t - t0);
    switch (e.kind) {
      case MusicEventKind.section:
        _line('$at  ${e.section!.label}');
      case MusicEventKind.gap:
        _line('$at  gap');
      case MusicEventKind.drop:
        _line('$at  DROP (build reached ${(e.value * 100).round()}%)');
      case MusicEventKind.back:
        _line('$at  back (no build)');
      case MusicEventKind.build:
        final pct = '${(e.value * 100).round()}%';
        if (pct != _lastBuild && e.t - _lastBuildT >= 1.0) {
          _lastBuild = pct;
          _lastBuildT = e.t;
          _line('$at    build $pct');
        }
      case MusicEventKind.kick || MusicEventKind.snare || MusicEventKind.beat:
        break;
    }
  }

  /// Writes down a line of its own at detector time [t], like what the lights were sent.
  void note(double t, String text) {
    if (!_closed) _line('${_time(t - t0)}  $text');
  }

  void _line(String s) => _log.writeStringSync('$s\r\n');

  static String _time(double t) {
    final s = math.max(0.0, t);
    final m = s ~/ 60;
    return '${m ~/ 60}:${(m % 60).toString().padLeft(2, '0')}:${(s % 60).toStringAsFixed(1).padLeft(4, '0')}';
  }

  /// Writes what is buffered and brings the header up to date.
  void flush() {
    if (_closed) return;
    if (_buf.isNotEmpty) _wav.writeFromSync(_buf.takeBytes());
    _flushed = _frames;
    final pos = _wav.positionSync();
    _wav
      ..setPositionSync(0)
      ..writeFromSync(_header(fs, _frames * 2))
      ..setPositionSync(pos);
    _log.flushSync();
  }

  /// Finishes the recording. Calling it again does nothing.
  void close() {
    if (_closed) return;
    flush();
    _closed = true;
    _wav.closeSync();
    _log.closeSync();
  }

  static Uint8List _header(int fs, int dataBytes) {
    final b = ByteData(44);
    void str(int at, String s) {
      for (var i = 0; i < s.length; i++) {
        b.setUint8(at + i, s.codeUnitAt(i));
      }
    }

    str(0, 'RIFF');
    b.setUint32(4, 36 + dataBytes, Endian.little);
    str(8, 'WAVE');
    str(12, 'fmt ');
    b
      ..setUint32(16, 16, Endian.little)
      ..setUint16(20, 1, Endian.little) // PCM
      ..setUint16(22, 1, Endian.little) // mono
      ..setUint32(24, fs, Endian.little)
      ..setUint32(28, fs * 2, Endian.little)
      ..setUint16(32, 2, Endian.little)
      ..setUint16(34, 16, Endian.little);
    str(36, 'data');
    b.setUint32(40, dataBytes, Endian.little);
    return b.buffer.asUint8List();
  }
}
