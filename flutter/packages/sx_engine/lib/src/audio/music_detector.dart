import 'dart:math' as math;
import 'dart:typed_data';

// The music detector: listens to the DJ feed and finds kick and snare hits,
// the tempo (a beat clock that runs ahead of the music, with bar 1), and the
// sections of EDM-style music: GROOVE, BREAK (kick and bass gone), BUILD
// (snare roll speeding up and/or a riser, with a level 0..1), the GAP just
// before a drop, DROP (kick and bass back after a build) and RETURN (back
// after a break without a build).
//
// Port of `tools/audio/detector.py`, step for step. The Python version is the
// one to try ideas on (it draws timelines of real recordings). Change one,
// change the other, and keep the names the same.
//
// Pure maths: no clock, no audio device. Feed it samples, get events back.

// ---------------------------------------------------------------- settings
const _hopS = 0.010; // analysis step
const _lowHz = 150.0; // kick and bass: below this
const _midLoHz = 1000.0, _midHiHz = 5000.0; // snare / clap crack
const _highHz = 7000.0; // hats, risers

const _kickMinDb = 6.0; // an onset is a rise of at least this many dB...
const _snareMinDb = 6.0;
const _kickRel = 0.55; // ...and at least this share of the recent loudest onset
const _snareRel = 0.60;
const _kickHalfLifeS = 1.5, _snareHalfLifeS = 3.0; // how fast the loudest recent hit is forgotten
const _kickCapDb = 14.0, _snareCapDb = 24.0; // one huge hit can't raise the bar past this
const _kickWin = 1, _kickBack = 2, _kickSpan = 10; // hops: level window, how far back to compare, over how many
const _snareWin = 2, _snareBack = 2, _snareSpan = 1;
const _envHz = 25.0; // low band: squared, then this low-pass
const _kickLagS = 0.020, _snareLagS = 0.012; // the peak comes this long after the hit starts
const _fluxMaxDb = 30.0;
const _kickGapS = 0.120; // two kicks can't be closer than this
const _snareGapS = 0.045; // a 1/32 roll at 150 BPM is 50 ms
const _silenceDb = -60.0; // below this nothing counts

const _bpmMin = 75.0, _bpmMax = 180.0;
const _bpmCenter = 122.0; // tempo prior: favours the usual dance range
const _tempoWinS = 6.0;
const _tempoEveryS = 0.5;
const _lockS = 6.0, _lockKicks = 3; // this many kicks on the beat clock within this long = locked
const _switchMargin = 1.5; // a different tempo must repeat this much more clearly to take over
const _pllPhase = 0.30; // how much of a kick's timing error moves the beat
const _pllPeriod = 0.04; // ...and the tempo
const _pllWindow = 0.22; // a kick within this share of a beat of the clock counts

const _refUpS = 1.0, _refDownS = 45.0; // the groove level follows the low end up in a second, down only slowly
const _breakDb = 10.0; // low end this far under the groove level = break
const _breakHoldBeats = 1.5;
const _cutGateDb = 3.0; // with the low end less cut than this (over ~1.5 s) nothing is a build
const _dropDb = 2.0; // low end back within this of the groove level = drop / return
const _kickBackDb = 2.5; // a kick within this of the groove's kicks = the kick is back at full weight
const _minBreakBeats = 4.0;
const _buildOn = 0.35, _buildOff = 0.20;
const _bigDropBuild = 0.50; // a break whose build reached this ends in a DROP
const _dropBeats = 32.0; // how long DROP lasts before GROOVE
const _gapDb = 15.0;
// A build is a trend, so it is judged on three 1.5 s steps (four 1.5 s averages,
// the last 6 s): each step must go the same way, none can be most of the
// whole (that is a cut, not a fade), and the whole must go far enough.
const _stepS = 1.5, _steps = 3;
const _stepMaxShare = 0.6;
const _fadeStepDb = 0.7, _fadeFromDb = 3.0, _fadeFullDb = 10.0; // the low end fading out further each step
const _riseStepDb = 0.4, _riseFromDb = 2.0, _riseFullDb = 7.0; // the highs climbing each step (a riser, a filter opening)
const _rollFrom = 1.5, _rollFull = 4.0; // snares per beat: 8ths and faster count as a roll, 16ths as a full one
const _buildRiseS = 1.0; // how fast the build level follows the score up

/// The part of the music playing now.
enum MusicSection {
  groove('GROOVE'),
  breakdown('BREAK'),
  build('BUILD'),
  drop('DROP');

  const MusicSection(this.label);

  /// The name the Python version and the status use.
  final String label;
}

/// What an event is.
enum MusicEventKind {
  kick,
  snare,

  /// A beat of the beat clock. [MusicEvent.value] is the BPM, [MusicEvent.bar] the place in the bar, 1 to 4.
  beat,

  /// The section changed to [MusicEvent.section].
  section,

  /// The build level now (every 100 ms during a break or build), in [MusicEvent.value].
  build,

  /// The silence just before a drop. [MusicEvent.value] is the build level.
  gap,

  /// Kick and bass back after a build. [MusicEvent.value] is how high the build got.
  drop,

  /// Kick and bass back after a break without a build.
  back,
}

/// One thing the detector found. [t] is in seconds of audio fed so far.
class MusicEvent {
  const MusicEvent(this.t, this.kind, {this.value = 0, this.bar = 0, this.section});

  final double t;
  final MusicEventKind kind;
  final double value;
  final int bar;
  final MusicSection? section;

  @override
  String toString() =>
      '${t.toStringAsFixed(3)} ${kind.name} ${value.toStringAsFixed(2)}${bar > 0 ? ' $bar' : ''}${section != null ? ' ${section!.label}' : ''}';
}

double _db(double e) => 10.0 * math.log(e + 1e-12) / math.ln10;

double _emaCoef(double tauS) => 1.0 - math.exp(-_hopS / tauS);

double _log2(double x) => math.log(x) / math.ln2;

/// RBJ cookbook low or high-pass. Direct form I, one sample at a time.
class _Biquad {
  _Biquad.lowPass(double f0, double fs) : this._(true, f0, fs);
  _Biquad.highPass(double f0, double fs) : this._(false, f0, fs);

  _Biquad._(bool low, double f0, double fs) {
    const q = 0.7071;
    final w0 = 2 * math.pi * f0 / fs, c = math.cos(w0), a = math.sin(w0) / (2 * q);
    final a0 = 1 + a;
    if (low) {
      b0 = (1 - c) / 2 / a0;
      b1 = (1 - c) / a0;
    } else {
      b0 = (1 + c) / 2 / a0;
      b1 = -(1 + c) / a0;
    }
    b2 = b0;
    a1 = -2 * c / a0;
    a2 = (1 - a) / a0;
  }

  late final double b0, b1, b2, a1, a2;
  double _x1 = 0, _x2 = 0, _y1 = 0, _y2 = 0;

  double run(double x) {
    final y = b0 * x + b1 * _x1 + b2 * _x2 - a1 * _y1 - a2 * _y2;
    _x2 = _x1;
    _x1 = x;
    _y2 = _y1;
    _y1 = y;
    return y;
  }
}

/// A few biquads in a row.
class _Band {
  _Band(this._stages);

  final List<_Biquad> _stages;

  double run(double x) {
    for (final s in _stages) {
      x = s.run(x);
    }
    return x;
  }
}

/// Peak picking on the rise of a band's level. Port of `Onsets`.
///
/// The level is the band's energy over the last [win] hops. The rise is that
/// level against the loudest level between [back] and [back] + span - 1 hops
/// ago. The kick uses a long span, so the dip and swell where a kick's tail
/// meets the bass doesn't read as another kick.
///
/// The threshold follows the loudest recent onsets (a peak that fades with
/// its half-life, and one huge hit counts for no more than [cap] dB), so
/// quieter hits in the same band stay under it, and it adapts to the level of
/// the feed by itself. [lagS] is how late the picked peak is, on average,
/// after the hit starts: it is taken off the reported time.
class _Onsets {
  _Onsets({
    required this.minDb,
    required this.gapS,
    required this.rel,
    required this.cap,
    required double halfLife,
    required this.win,
    required this.back,
    required int span,
    required this.lagS,
  }) : _decay = math.pow(0.5, _hopS / halfLife).toDouble(),
       _en = List<double>.filled(win, 0, growable: true),
       _lv = List<double>.filled(back + span, _silenceDb, growable: true);

  final double minDb, gapS, rel, cap, lagS;
  final int win, back;
  final double _decay;
  final List<double> _en; // last [win] energies, oldest first
  final List<double> _lv; // last levels, oldest first
  double _prev2 = 0, _cand = 0, _peak = 0, _last = -1e9;

  /// The band's level now (dB, over the window).
  double get level => _lv.last;

  /// Feeds one hop's energy. Returns the strength of an onset found one hop
  /// ago, or null. Its time is [when] of [t].
  double? step(double e, double t) {
    _en
      ..removeAt(0)
      ..add(e);
    var sum = 0.0;
    for (final v in _en) {
      sum += v;
    }
    final now = math.max(_db(sum / _en.length), _silenceDb);
    var before = -1e18;
    for (var i = 0; i <= _lv.length - back; i++) {
      before = math.max(before, _lv[i]);
    }
    _lv
      ..removeAt(0)
      ..add(now);
    final f = math.min(_fluxMaxDb, math.max(0.0, now - before));
    final prev2 = _prev2, cand = _cand;
    _prev2 = cand;
    _cand = f;
    _peak *= _decay;
    final thr = math.max(minDb, rel * _peak);
    final tc = when(t);
    if (cand >= thr && cand >= prev2 && cand > f && tc - _last >= gapS) {
      _last = tc;
      _peak = math.max(_peak, math.min(cand, cap));
      return cand;
    }
    return null;
  }

  double when(double t) => t - _hopS - lagS;
}

/// A fixed-size list of the newest values, oldest first.
class _Ring {
  _Ring(this.size);

  final int size;
  final _v = <double>[];

  void add(double x) {
    _v.add(x);
    if (_v.length > size) _v.removeAt(0);
  }

  int get length => _v.length;
  bool get isEmpty => _v.isEmpty;
  double get last => _v.last;
  double operator [](int i) => _v[i];
  Iterable<double> get values => _v;
}

/// The detector. Port of `Detector`.
///
/// [leadS] gives each beat out that long before it happens (the beat clock is
/// a prediction), to make up for the delay of the audio input and of whatever
/// plays the lights.
class MusicDetector {
  MusicDetector(this.fs, {this.leadS = 0})
    : _hop = math.max(1, (fs * _hopS).round()),
      _low = _Band([_Biquad.lowPass(_lowHz, fs.toDouble()), _Biquad.lowPass(_lowHz, fs.toDouble())]),
      _mid = _Band([
        _Biquad.highPass(_midLoHz, fs.toDouble()),
        _Biquad.highPass(_midLoHz, fs.toDouble()),
        _Biquad.lowPass(_midHiHz, fs.toDouble()),
        _Biquad.lowPass(_midHiHz, fs.toDouble()),
      ]),
      _high = _Band([_Biquad.highPass(_highHz, fs.toDouble()), _Biquad.highPass(_highHz, fs.toDouble())]),
      _lowEnv = _Biquad.lowPass(_envHz, fs.toDouble()),
      _env = List<double>.filled((_tempoWinS / _hopS).round(), 0);

  /// Samples per second of what is fed.
  final int fs;
  double leadS;

  final int _hop;
  final _Band _low, _mid, _high;
  final _Biquad _lowEnv;
  final _kickOn = _Onsets(
    minDb: _kickMinDb,
    gapS: _kickGapS,
    rel: _kickRel,
    cap: _kickCapDb,
    halfLife: _kickHalfLifeS,
    win: _kickWin,
    back: _kickBack,
    span: _kickSpan,
    lagS: _kickLagS,
  );
  final _snareOn = _Onsets(
    minDb: _snareMinDb,
    gapS: _snareGapS,
    rel: _snareRel,
    cap: _snareCapDb,
    halfLife: _snareHalfLifeS,
    win: _snareWin,
    back: _snareBack,
    span: _snareSpan,
    lagS: _snareLagS,
  );

  // the hop being summed
  int _inHop = 0;
  double _sl = 0, _sm = 0, _sh = 0, _sf = 0;

  /// Hops done.
  int n = 0;

  // tempo
  final List<double> _env; // onset strength per hop, oldest first, a ring at [_envAt]
  int _envAt = 0;
  final _estimates = _Ring(5);
  final _onGrid = _Ring(16); // times of kicks that landed on the beat clock
  int _offCount = 0;
  double _period = 0; // s, 0 = no tempo yet
  double _nextBeat = 0;
  int _beatN = 0; // beats given out
  int _barOff = 0;
  final _kicksT = _Ring(64);
  final _snaresT = _Ring(128);
  var _slot = <double>[0, 0, 0, 0]; // snare weight per bar position
  Map<int, double> _scores = const {};

  // levels
  double _lowAvg = _silenceDb, _highAvg = _silenceDb, _fullFast = _silenceDb, _fullSlow = _silenceDb;
  double _lowSlow = _silenceDb; // the low end over ~1.5 s: how much of it a build has cut
  double _lowFast = _silenceDb; // ...and over ~80 ms: back at full weight?
  final _trendCut = _Ring((_stepS * (_steps + 1) / 0.25).round()); // the low end's cut every 250 ms
  final _trendHigh = _Ring((_stepS * (_steps + 1) / 0.25).round()); // ...and the highs
  double? _ref;
  double? _kickRef; // how loud the groove's kicks are (the low band at each kick)

  // sections
  MusicSection _state = MusicSection.groove;
  double _breakT = 0;
  double? _belowSince;
  double _build = 0, _buildPeak = 0, _dropLeft = 0;
  bool _gapSent = false;

  final _out = <MusicEvent>[];

  /// The section now.
  MusicSection get section => _state;

  /// The build level now, 0..1.
  double get buildLevel => _build;

  /// The tempo, or 0 while it isn't known yet.
  double get bpm => _period > 0 ? 60.0 / _period : 0;

  /// The low band's average level now and the groove level it is compared with (dB), for a meter.
  double get lowLevel => _lowAvg;
  double? get grooveLevel => _ref;

  /// The feed's level now (dB, 0 = full scale), for a meter.
  double get level => _fullSlow;

  /// Feeds mono samples (-1..1). Returns the events they caused, in order.
  List<MusicEvent> feed(Float64List x) {
    _out.clear();
    final inv = 1.0 / _hop;
    for (var i = 0; i < x.length; i++) {
      final s = x[i];
      final lo = _low.run(s);
      _sl += _lowEnv.run(lo * lo);
      final mi = _mid.run(s);
      _sm += mi * mi;
      final hi = _high.run(s);
      _sh += hi * hi;
      _sf += s * s;
      if (++_inHop == _hop) {
        n++;
        _hopDone(n * _hop / fs, math.max(0.0, _sl * inv), _sm * inv, _sh * inv, _sf * inv);
        _inHop = 0;
        _sl = _sm = _sh = _sf = 0;
      }
    }
    return List.of(_out);
  }

  // ------------------------------------------------------------ one hop
  void _hopDone(double t, double el, double em, double eh, double ef) {
    final kick = _kickOn.step(el, t);
    final snare = _snareOn.step(em, t);
    final low = _db(el), high = _db(eh), full = _db(ef);
    final tk = _kickOn.when(t), ts = _snareOn.when(t);
    if (kick != null) {
      _emit(MusicEvent(tk, MusicEventKind.kick, value: kick));
      _kicksT.add(tk);
    }
    if (snare != null) {
      _emit(MusicEvent(ts, MusicEventKind.snare, value: snare));
      _snaresT.add(ts);
    }
    _env[_envAt] = math.min(30.0, kick ?? 0.0) + 0.6 * math.min(30.0, snare ?? 0.0);
    _envAt = (_envAt + 1) % _env.length;

    // levels
    _lowAvg += (low - _lowAvg) * _emaCoef(0.30);
    _highAvg += (high - _highAvg) * _emaCoef(0.50);
    _fullFast += (full - _fullFast) * _emaCoef(0.03);
    _fullSlow += (full - _fullSlow) * _emaCoef(0.50);
    _lowSlow += (low - _lowSlow) * _emaCoef(1.5);
    _lowFast += (low - _lowFast) * _emaCoef(0.08);

    _tempo(t, kick != null ? tk : null);
    _beats(t);
    if (snare != null) _snareSlot(ts);
    _sections(t, kick != null ? tk : null);
  }

  void _emit(MusicEvent e) => _out.add(e);

  // ------------------------------------------------------------ tempo
  void _tempo(double t, double? tk) {
    if (n % (_tempoEveryS / _hopS).round() == 0) {
      var est = _acfBpm();
      if (est != null && _period > 0 && !_worthSwitching(est)) est = 60.0 / _period; // the beat we have still fits: keep it
      if (est != null) {
        _estimates.add(est);
        final med = _median(_estimates.values);
        if (_period == 0) {
          if (_estimates.length >= 3) {
            _period = 60.0 / med;
            final lastK = _kicksT.isEmpty ? t : _kicksT.last;
            final k = ((t - lastK) / _period).ceil();
            _nextBeat = lastK + k * _period;
          }
        } else if ((60.0 / _period - med).abs() / med > 0.03) {
          _offCount++;
          if (_offCount >= 4) {
            // a new tempo for 2 s: take it
            _period = 60.0 / med;
            _offCount = 0;
          }
        } else {
          _offCount = 0;
        }
      }
    }
    if (tk != null && _period > 0) {
      final prev = _nextBeat - _period;
      final near = (tk - prev).abs() < (tk - _nextBeat).abs() ? prev : _nextBeat;
      final err = tk - near;
      if (err.abs() < _pllWindow * _period) {
        _onGrid.add(tk);
        _nextBeat += _pllPhase * err;
        _period += _pllPeriod * err;
        _period = math.min(60.0 / _bpmMin, math.max(60.0 / _bpmMax, _period));
      }
    }
  }

  static double _median(Iterable<double> v) {
    final s = v.toList()..sort();
    final m = s.length ~/ 2;
    return s.length.isOdd ? s[m] : (s[m - 1] + s[m]) / 2;
  }

  double? _acfBpm() {
    final len = _env.length;
    final o = Float64List(len);
    var sum = 0.0;
    for (var i = 0; i < len; i++) {
      final v = _env[(_envAt + i) % len]; // oldest first
      o[i] = v;
      sum += v;
    }
    if (sum < 50) return null;
    final mean = sum / len;
    for (var i = 0; i < len; i++) {
      o[i] -= mean;
    }
    final lo = (60.0 / _bpmMax / _hopS).floor();
    final hi = (60.0 / _bpmMin / _hopS).ceil();
    final scores = <int, double>{};
    for (var lag = lo; lag < 2 * hi + 3; lag++) {
      // up to two slow beats, for _support
      var d = 0.0;
      for (var i = lag; i < len; i++) {
        d += o[i] * o[i - lag];
      }
      scores[lag] = d / (len - lag);
    }
    var best = -1e18;
    var bestLag = 0;
    for (var lag = lo + 1; lag < hi + 1; lag++) {
      final bpm = 60.0 / (lag * _hopS);
      final w = math.exp(-0.5 * math.pow(_log2(bpm / _bpmCenter) / 0.7, 2));
      final s = scores[lag]! * w;
      if (s > best && scores[lag]! >= scores[lag - 1]! && scores[lag]! >= scores[lag + 1]!) {
        best = s;
        bestLag = lag;
      }
    }
    _scores = scores;
    if (bestLag == 0 || scores[bestLag]! <= 0) return null;
    final a = scores[bestLag - 1]!, b = scores[bestLag]!, c = scores[bestLag + 1]!;
    final den = a - 2 * b + c;
    final frac = den != 0 ? 0.5 * (a - c) / den : 0.0;
    var bpm = 60.0 / ((bestLag + frac) * _hopS);
    // half-time feel (kick on 1, snare on 3) reads as half the tempo
    if (bpm < 95.0 && 2 * bpm <= _bpmMax) bpm *= 2;
    return bpm;
  }

  /// How well the last few seconds repeat at [bpm]'s beat, or every two or four beats.
  double _support(double bpm) {
    var best = 0.0;
    for (final mult in const [1, 2, 4]) {
      final i = (60.0 / bpm / _hopS * mult).round();
      final a = _scores[i - 1], b = _scores[i], c = _scores[i + 1];
      if (a != null && b != null && c != null) best = math.max(best, math.max(a, math.max(b, c)));
    }
    return best;
  }

  /// A new tempo only wins when it repeats clearly better than the one we follow.
  bool _worthSwitching(double est) {
    final cur = 60.0 / _period;
    if ((cur - est).abs() / est <= 0.03) return true;
    // kicks keep landing on our beat: the tempo is right, whatever else repeats
    if (!_onGrid.isEmpty) {
      final lastK = _onGrid.last;
      final recent = _onGrid.values.where((k) => lastK - k < _lockS).length;
      if (recent >= _lockKicks && n * _hopS - lastK < 3.0) return false;
    }
    // 2:3, 3:4 and 1:2 are what syncopation (dotted kicks, half-time) fakes
    final r = est / cur;
    final tricky = const [0.5, 2 / 3, 0.75, 4 / 3, 1.5, 2.0].any((q) => (r - q).abs() / q < 0.03);
    final margin = _switchMargin * (tricky ? 2.0 : 1.0);
    return _support(est) > margin * math.max(1e-9, _support(cur));
  }

  void _beats(double t) {
    if (_period == 0) return;
    while (t + leadS >= _nextBeat) {
      final pos = (_beatN - _barOff) % 4;
      _emit(MusicEvent(_nextBeat, MusicEventKind.beat, value: 60.0 / _period, bar: pos + 1));
      _beatN++;
      _nextBeat += _period;
      for (var i = 0; i < 4; i++) {
        _slot[i] *= 0.98;
      }
    }
  }

  void _snareSlot(double ts) {
    if (_period == 0) return;
    final prev = _nextBeat - _period;
    final useprev = (ts - prev).abs() <= (ts - _nextBeat).abs();
    final nb = useprev ? _beatN - 1 : _beatN;
    final near = useprev ? prev : _nextBeat;
    if ((ts - near).abs() > 0.15 * _period) return;
    _slot[(nb - _barOff) % 4] += 1.0;
    // four-on-the-floor: snares belong on 2 and 4
    if ((_state == MusicSection.groove || _state == MusicSection.drop) && _kicksPerBeat() > 0.8) {
      final even = _slot[0] + _slot[2], odd = _slot[1] + _slot[3];
      if (even > 6 && even > 2 * odd) {
        _barOff++;
        _slot = [_slot[1], _slot[2], _slot[3], _slot[0]];
      }
    }
  }

  double _kicksPerBeat() {
    if (_period == 0 || _kicksT.isEmpty) return 0;
    final now = _kicksT.last;
    return _kicksT.values.where((k) => now - k < 4 * _period).length / 4.0;
  }

  // ------------------------------------------------------------ sections
  double get _beatS => _period > 0 ? _period : 0.5;

  void _setState(double t, MusicSection s) {
    if (s == _state) return;
    _state = s;
    _emit(MusicEvent(t, MusicEventKind.section, section: s));
  }

  void _sections(double t, double? tk) {
    final b = _beatS;
    if (_ref == null) {
      if (_kicksT.length >= 6 && _lowAvg > _silenceDb + 10) {
        _ref = _lowAvg;
        _lowSlow = _lowAvg;
      }
      return;
    }
    var ref = _ref!;
    final kickLv = tk != null ? _kickOn.level : null;
    if (n % (0.25 / _hopS).round() == 0) {
      _trendCut.add(ref - _lowAvg);
      _trendHigh.add(_highAvg);
    }
    if (_state == MusicSection.groove || _state == MusicSection.drop) {
      // the groove level: up within a second, down only slowly, so a build
      // that takes the low end away over 16 bars still shows as a cut
      final k = _lowSlow > ref ? _emaCoef(_refUpS) : _emaCoef(_refDownS);
      ref += (_lowSlow - ref) * k;
      _ref = ref;
      if (kickLv != null && _lowSlow > ref - _cutGateDb) {
        final kr = _kickRef;
        _kickRef = kr == null ? kickLv : kr + (kickLv - kr) * 0.1;
      }
      if (_state == MusicSection.drop) {
        _dropLeft -= _hopS / b;
        if (_dropLeft <= 0) _setState(t, MusicSection.groove);
      }
      _followBuild(_buildScore(t, b));
      if (_lowAvg < ref - _breakDb) {
        final since = _belowSince ??= t;
        if (t - since >= _breakHoldBeats * b) {
          _startBreak(since, MusicSection.breakdown);
          return;
        }
      } else {
        _belowSince = null;
      }
      // a build with the low end filtered, not gone: no break before it
      if (_build >= _buildOn) _startBreak(t, MusicSection.build);
      return;
    }

    // in a break or a build
    _belowSince = null;
    _followBuild(_buildScore(t, b));
    _buildPeak = math.max(_buildPeak, _build);
    if (_state == MusicSection.breakdown && _build >= _buildOn) {
      _setState(t, MusicSection.build);
    } else if (_state == MusicSection.build && _build < _buildOff) {
      _setState(t, MusicSection.breakdown);
    }
    if (n % (0.1 / _hopS).round() == 0) _emit(MusicEvent(t, MusicEventKind.build, value: _build));

    // the silence right before a drop
    if (_state == MusicSection.build && !_gapSent && _fullFast < _fullSlow - _gapDb) {
      _gapSent = true;
      _emit(MusicEvent(t, MusicEventKind.gap, value: _build));
    }

    // kick and bass are back at full weight: a kick as loud as the groove's,
    // or the low end itself back up
    final longEnough = t - _breakT >= _minBreakBeats * b;
    final kr = _kickRef;
    final kickBack = tk != null && kickLv != null && kr != null && kickLv >= kr - _kickBackDb;
    final lowBack = _lowFast >= ref - _dropDb;
    if (longEnough && (kickBack || lowBack)) {
      final at = kickBack ? tk : t;
      final big = _buildPeak >= _bigDropBuild;
      _emit(MusicEvent(at, big ? MusicEventKind.drop : MusicEventKind.back, value: _buildPeak));
      // the drop is bar 1
      if (_period > 0) {
        final prev = _nextBeat - _period;
        final nb = (at - prev).abs() <= (at - _nextBeat).abs() ? _beatN - 1 : _beatN;
        _barOff = nb % 4;
        _slot = [0, 0, 0, 0];
      }
      _build = 0;
      _lowSlow = math.max(_lowSlow, ref - _dropDb); // the low end is back: no cut left over
      if (big) {
        _dropLeft = _dropBeats;
        _setState(at, MusicSection.drop);
      } else {
        _setState(at, MusicSection.groove);
      }
    }
  }

  void _startBreak(double since, MusicSection state) {
    _buildPeak = state == MusicSection.build ? _build : 0.0;
    _gapSent = false;
    _breakT = since;
    _belowSince = null;
    _setState(since, state);
  }

  /// How much it sounds like a build now, 0..1. Only with the low end cut (a
  /// build takes the bass away), and then only for something that keeps
  /// going one way: the bass fading out further, the highs climbing, or a
  /// snare roll. A breakdown that just sits there with the bass out is not a
  /// build, and with the kick and bass at full weight nothing is.
  double _buildScore(double t, double b) {
    final cut = _ref! - _lowSlow;
    if (cut < _cutGateDb || _trendCut.length < _trendCut.size) return 0.0;
    final fade = _trend(_trendCut.values.toList(), _fadeStepDb, _fadeFromDb, _fadeFullDb);
    final rise = _trend(_trendHigh.values.toList(), _riseStepDb, _riseFromDb, _riseFullDb);
    final perBeat = _snaresT.values.where((s) => t - s < 2 * b).length / 2.0;
    final roll = math.min(1.0, math.max(0.0, (perBeat - _rollFrom) / (_rollFull - _rollFrom)));
    return 1.0 - (1.0 - fade) * (1.0 - rise) * (1.0 - roll);
  }

  /// The build level follows the score: up in about a second, down at most half a level per 4 beats.
  void _followBuild(double score) {
    if (score > _build) {
      _build += (score - _build) * _emaCoef(_buildRiseS);
    } else {
      _build -= math.min(_build - score, _hopS / (4 * _beatS) * 0.5);
    }
  }
}

/// 0..1: how far [v] (oldest first, every 250 ms) went up over its last
/// [_steps] steps of [_stepS], when every step went up by at least [step] and
/// no step was more than [_stepMaxShare] of the whole. [lo] or less counts 0,
/// [full] or more 1.
double _trend(List<double> v, double step, double lo, double full) {
  final n = (_stepS / 0.25).round();
  final means = <double>[];
  for (var i = _steps; i >= 0; i--) {
    var sum = 0.0;
    for (var j = v.length - (i + 1) * n; j < v.length - i * n; j++) {
      sum += v[j];
    }
    means.add(sum / n);
  }
  final total = means.last - means.first;
  for (var i = 1; i < means.length; i++) {
    final d = means[i] - means[i - 1];
    if (d < step || d > _stepMaxShare * total) return 0.0;
  }
  return math.min(1.0, math.max(0.0, (total - lo) / (full - lo)));
}
