import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import '../ps_compat.dart';
import '../show/fixtures.dart';
import '../show/movers.dart';
import '../show/show_env.dart';
import '../show/text_files.dart';
import 'rig.dart';

// TONIGHT'S LAYOUT: after Tonight's Rig or Rig Test saves, three things follow
// the heads that are hung tonight and where they hang in ShowXpress's 2D view
// (the Fixtures tab, where the user puts each head on its truss):
//
// - The beat scenes. They light groups of heads (left and right, back and
//   sides, every other head, a build from the middle out), and they were
//   made for the 3D view's old layout. They are made again from the hung
//   heads' places in the 2D view, keeping each step's timing and values.
// - The 2D view hides the heads that aren't hung and shows the ones that are.
// - The 3D view puts each hung head where it is in the 2D view, up on the
//   truss, and takes out the ones that aren't hung. They come back as they
//   were when they are hung again.
//
// The full beat scenes and the 3D view's taken-out heads are kept in
// rig_layout.json.
//
// New in the Flutter app.

/// How a beat scene's groups are made from where the heads hang.
enum BeatPattern {
  /// The left half, then the right half.
  leftRight,

  /// The back row, then the rest. With one row: the middle, then the outside.
  backSides,

  /// Every other head across each row: the left head of each T-bar, then the right one.
  alternate,

  /// From the middle out, a bit more each step, then everything.
  build,
}

/// The beat scenes that follow the layout, by file name, and their patterns.
const layoutScenes = {
  'BEAT LEFT RIGHT.scex': BeatPattern.leftRight,
  'BEAT BACK SIDES.scex': BeatPattern.backSides,
  'BEAT UP DOWN.scex': BeatPattern.alternate,
  'BEAT BUILD.scex': BeatPattern.build,
  'BUILD UP STROBE.scex': BeatPattern.leftRight,
};

/// A hung head and where its icon is in the 2D view (top-left corner, pixels).
typedef HeadAt = ({String id, int x, int y});

/// The groups the beat scenes light, made from where the hung heads are.
class RigGroups {
  RigGroups._(this.left, this.right, this.back, this.sides, this.a, this.b, this.rings);

  /// Groups for [heads]. Heads less than 60 px apart up and down are one
  /// row, and less than 40 px apart in distance from the middle one ring.
  factory RigGroups.of(List<HeadAt> heads) {
    if (heads.isEmpty) return RigGroups._(const [], const [], const [], const [], const [], const [], const []);
    final xs = heads.map((h) => h.x);
    final mid = (xs.reduce((a, b) => a < b ? a : b) + xs.reduce((a, b) => a > b ? a : b)) / 2;

    // rows, top of the page (the back) first; each left to right
    final byY = psSorted<HeadAt>(heads, [(h) => h.y, (h) => h.x]);
    final rows = <List<HeadAt>>[];
    for (final h in byY) {
      if (rows.isEmpty || h.y - rows.last.first.y > 60) rows.add([]);
      rows.last.add(h);
    }
    for (final r in rows) {
      r.sort((p, q) => p.x.compareTo(q.x));
    }

    // left and right; a head in the middle goes with the smaller side
    final left = <String>[], right = <String>[], middle = <String>[];
    for (final h in heads) {
      if (h.x < mid - 20) {
        left.add(h.id);
      } else if (h.x > mid + 20) {
        right.add(h.id);
      } else {
        middle.add(h.id);
      }
    }
    for (final id in middle) {
      (left.length <= right.length ? left : right).add(id);
    }

    // rings, from the middle out
    final byD = psSorted<HeadAt>(heads, [(h) => (h.x - mid).abs(), (h) => h.y, (h) => h.x]);
    final rings = <List<String>>[];
    double? ringD;
    for (final h in byD) {
      final d = (h.x - mid).abs();
      if (ringD == null || d - ringD > 40) {
        rings.add([]);
        ringD = d;
      }
      rings.last.add(h.id);
    }

    // back and sides
    final List<String> back, sides;
    if (rows.length > 1) {
      back = [for (final h in rows.first) h.id];
      sides = [
        for (final r in rows.skip(1))
          for (final h in r) h.id,
      ];
    } else if (rings.length > 1) {
      back = [for (final r in rings.take(rings.length ~/ 2)) ...r];
      sides = [for (final r in rings.skip(rings.length ~/ 2)) ...r];
    } else {
      back = left;
      sides = right;
    }

    // every other head across each row
    final a = <String>[], b = <String>[];
    for (final r in rows) {
      for (final (i, h) in r.indexed) {
        (i.isEven ? a : b).add(h.id);
      }
    }
    return RigGroups._(left, right, back, sides, a, b, rings);
  }

  final List<String> left, right, back, sides, a, b;

  /// Heads by distance from the middle, the nearest first.
  final List<List<String>> rings;

  /// The two groups a two-step [pattern] lights.
  (List<String>, List<String>) split(BeatPattern pattern) => switch (pattern) {
    BeatPattern.leftRight || BeatPattern.build => (left, right),
    BeatPattern.backSides => (back, sides),
    BeatPattern.alternate => (a, b),
  };

  /// What step [k] (1..[of]) of a build lights: more rings each step, all of them at the last.
  List<String> buildLevel(int k, int of) {
    final n = k >= of ? rings.length : (k * rings.length / of).round().clamp(1, rings.length);
    return [for (final r in rings.take(n)) ...r];
  }
}

/// Where a head at [x], [y] in the 2D view goes in the 3D view: across the
/// room as in the 2D view, the top of the page at the back, up on the truss.
/// The 3D view counts in feet: the page's width is 16 ft and its height 10.
String position3d(int x, int y) {
  String f(double v) {
    final s = v.toStringAsFixed(2);
    return s == '-0.00' ? '0.00' : s;
  }

  return '${f((x - 448) / 448 * 8)},${f(_trussHeight)},${f(-10 + y / 592 * 10)}';
}

const _trussHeight = 9.0;

/// An ini file kept as lines, written back as found (byte order mark and line
/// endings too).
class _Ini {
  _Ini(this.path, this.bom, this.nl, this.lines, this.text);

  factory _Ini.read(String path) {
    final b = File(path).readAsBytesSync();
    final bom = hasBom(b);
    final t = utf8.decode(bom ? Uint8List.sublistView(b, 3) : b, allowMalformed: true);
    return _Ini(path, bom, t.contains('\r\n') ? '\r\n' : '\n', t.split(RegExp(r'\r?\n')), t);
  }

  final String path;
  final bool bom;
  final String nl;
  final List<String> lines;
  final String text;

  String get newText => lines.join(nl);

  /// The section `[name]` as (header line, end), the end before trailing blank lines.
  (int, int)? find(String name) {
    final header = '[$name]';
    var start = -1, i = 0;
    for (; i < lines.length; i++) {
      if (start < 0) {
        if (psEq(lines[i].trim(), header)) start = i;
      } else if (lines[i].startsWith('[')) {
        break;
      }
    }
    if (start < 0) return null;
    var end = i;
    while (end > start + 1 && lines[end - 1].trim().isEmpty) {
      end--;
    }
    return (start, end);
  }

  /// The value of [key] in section [name], or null.
  String? get(String name, String key) {
    final se = find(name);
    if (se == null) return null;
    final rx = RegExp('^${RegExp.escape(key)}\\s*=\\s*(.*)\$', caseSensitive: false);
    for (var i = se.$1 + 1; i < se.$2; i++) {
      final m = rx.firstMatch(lines[i]);
      if (m != null) return m[1]!.trim();
    }
    return null;
  }

  /// Sets [key] in section [name] (added after [after] or at the end), or takes it out when [value] is null.
  void set(String name, String key, String? value, {String? after}) {
    final se = find(name)!;
    final rx = RegExp('^${RegExp.escape(key)}\\s*=', caseSensitive: false);
    for (var i = se.$1 + 1; i < se.$2; i++) {
      if (rx.hasMatch(lines[i])) {
        if (value == null) {
          lines.removeAt(i);
        } else {
          lines[i] = '$key = $value';
        }
        return;
      }
    }
    if (value == null) return;
    var at = se.$2;
    if (after != null) {
      final ra = RegExp('^${RegExp.escape(after)}\\s*=', caseSensitive: false);
      for (var i = se.$1 + 1; i < se.$2; i++) {
        if (ra.hasMatch(lines[i])) at = i + 1;
      }
    }
    lines.insert(at, '$key = $value');
  }

  /// Takes section [name] out and returns its lines.
  List<String> remove(String name) {
    final se = find(name)!;
    final out = lines.sublist(se.$1, se.$2);
    lines.removeRange(se.$1, se.$2);
    return out;
  }

  /// Adds [section] at the end, before trailing blank lines.
  void append(List<String> section) {
    var ix = lines.length;
    while (ix > 0 && lines[ix - 1].trim().isEmpty) {
      ix--;
    }
    lines.insertAll(ix, section);
  }
}

/// `rig_layout.json`: the full beat scenes while they are fitted to the
/// layout, and the 3D view's sections for heads that aren't hung.
class _LayoutState {
  _LayoutState(this.scenes, this.removed3d);

  factory _LayoutState.read(ShowEnv env) {
    final Map<String, Object?>? j;
    try {
      j = readRigStateFile(env.file('rig_layout.json'));
    } on FormatException {
      throw ToolError("rig_layout.json in the show folder can't be read. NOTHING was changed.");
    }
    final scenes = psMap<({String original, String written})>();
    final removed = <String, List<String>>{};
    final sc = j?['scenes'];
    if (sc is Map) {
      sc.forEach((k, v) {
        if (v is Map) scenes['$k'] = (original: '${v['original'] ?? ''}', written: '${v['written'] ?? ''}');
      });
    }
    final r3 = j?['removed3d'];
    if (r3 is Map) {
      r3.forEach((k, v) {
        if (v is List) removed['$k'] = [for (final l in v) '$l'];
      });
    }
    return _LayoutState(scenes, removed);
  }

  final Map<String, ({String original, String written})> scenes;
  final Map<String, List<String>> removed3d;
}

final _stepRx = RegExp(r'<Step\b[^>]*>(.*?)</Step>', dotAll: true);
final _fixRx = RegExp(r'<Fixture id="(\d+)">(.*?)</Fixture>', dotAll: true);
final _chRx = RegExp(r'<Channel\b[^>]*/>');
final _nameRx = RegExp(r'\bname="([^"]*)"');
final _valueRx = RegExp(r'\bvalue="(\d+)"');
final _fadeRx = RegExp(r'\s+fade="[^"]*"');

/// A mover's dimmer and shutter in one step: what to copy to light or darken another head.
typedef _Look = ({String dimmer, String shutter});

String? _channel(String block, String name) {
  for (final m in _chRx.allMatches(block)) {
    if (psEq(_nameRx.firstMatch(m[0]!)?[1] ?? '', name)) return m[0]!;
  }
  return null;
}

/// [block] with its dimmer and shutter set like [look]'s: the same value,
/// and a fade only if [look] has one. The channel index and everything else stay.
String _setLook(String block, _Look look) {
  String fit(String ch, String like) {
    var out = ch.replaceFirst(_fadeRx, '').replaceFirst(_valueRx, 'value="${_valueRx.firstMatch(like)?[1] ?? '0'}"');
    final fade = _fadeRx.firstMatch(like);
    if (fade != null) out = out.replaceFirst(RegExp(r'\s*/>$'), '${fade[0]}/>');
    return out;
  }

  return block.replaceAllMapped(_chRx, (m) {
    final n = (_nameRx.firstMatch(m[0]!)?[1] ?? '').toLowerCase();
    if (n == 'dimmer') return fit(m[0]!, look.dimmer);
    if (n == 'shutter') return fit(m[0]!, look.shutter);
    return m[0]!;
  });
}

const _darkLook = (dimmer: '<Channel name="dimmer" value="0"/>', shutter: '<Channel name="shutter" value="0"/>');

/// Fits one beat scene to [groups]. Returns the new text, or a note saying
/// why the scene is left as it is.
({String? text, String note}) _fitScene(String base, BeatPattern pattern, RigGroups groups, List<String> hung, Map<String, String> modelOf, FixtureDefs defs) {
  final steps = _stepRx.allMatches(base).toList();
  if (steps.isEmpty) return (text: null, note: 'it has no steps');
  final inScene = <String>{};
  final lit = <List<String>>[];
  for (final s in steps) {
    final on = <String>[];
    for (final f in _fixRx.allMatches(s[1]!)) {
      final id = f[1]!, model = modelOf[id];
      if (model == null) continue;
      final dim = _channel(f[2]!, 'dimmer'), shut = _channel(f[2]!, 'shutter');
      if (dim == null || shut == null) return (text: null, note: 'not every head has a dimmer and a shutter in every step');
      inScene.add(id);
      final d = psInt(_valueRx.firstMatch(dim)?[1]), sh = psInt(_valueRx.firstMatch(shut)?[1]);
      if (d > 0 && !defs.shutterClosed(model, sh)) on.add(id);
    }
    lit.add(psSorted<String>(on, [(x) => x]));
  }

  // each step: nothing lit, everything lit, or one of the scene's groups
  final partials = <String>[];
  final role = <int>[]; // -1 none, 0 all, k = the k-th group
  for (final l in lit) {
    if (l.isEmpty) {
      role.add(-1);
    } else if (l.length == inScene.length) {
      role.add(0);
    } else {
      final key = l.join(',');
      var k = partials.indexOf(key);
      if (k < 0) {
        partials.add(key);
        k = partials.length - 1;
      }
      role.add(k + 1);
    }
  }
  final hungHere = [
    for (final id in hung)
      if (inScene.contains(id)) id,
  ];
  final List<List<String>> want; // what each group lights now, by group number - 1
  if (pattern == BeatPattern.build) {
    final sets = [for (final p in partials) p.split(',').toSet()];
    for (var i = 1; i < sets.length; i++) {
      if (!sets[i].containsAll(sets[i - 1])) return (text: null, note: "its steps don't build up");
    }
    final of = partials.length + (role.contains(0) ? 1 : 0);
    want = [for (var k = 1; k <= partials.length; k++) groups.buildLevel(k, of)];
  } else {
    if (partials.length != 2) return (text: null, note: "it doesn't light two groups in turn");
    final (x, y) = groups.split(pattern);
    want = [x, y];
  }

  final b = StringBuffer();
  var pos = 0;
  for (final (i, s) in steps.indexed) {
    if (role[i] < 0) continue;
    final now = (role[i] == 0 ? hungHere : want[role[i] - 1]).toSet();
    _Look? litLook, darkLook;
    for (final f in _fixRx.allMatches(s[1]!)) {
      if (!inScene.contains(f[1]!)) continue;
      final look = (dimmer: _channel(f[2]!, 'dimmer')!, shutter: _channel(f[2]!, 'shutter')!);
      if (lit[i].contains(f[1]!)) {
        litLook ??= look;
      } else {
        darkLook ??= look;
      }
    }
    final inner = s[1]!.replaceAllMapped(_fixRx, (f) {
      final id = f[1]!;
      if (!inScene.contains(id) || now.contains(id) == lit[i].contains(id)) return f[0]!;
      final look = now.contains(id) ? litLook! : (darkLook ?? _darkLook);
      return f[0]!.replaceFirst(f[2]!, _setLook(f[2]!, look));
    });
    final start = s.start + s[0]!.indexOf(s[1]!);
    b
      ..write(base.substring(pos, start))
      ..write(inner);
    pos = start + s[1]!.length;
  }
  b.write(base.substring(pos));

  final sizes = switch (pattern) {
    BeatPattern.build => 'from the middle out: ${[for (final w in want) w.length].join(', ')}${role.contains(0) ? ', then all ${hungHere.length}' : ''}',
    BeatPattern.leftRight => 'left ${want[0].length}, right ${want[1].length}',
    BeatPattern.backSides => 'back ${want[0].length}, sides ${want[1].length}',
    BeatPattern.alternate => 'every other head, ${want[0].length} and ${want[1].length}',
  };
  return (text: b.toString(), note: sizes);
}

/// The beat scenes SX Studio fits to the layout, as found in [env].
Set<String> layoutSceneFiles(ShowEnv env) => {
  for (final f in layoutScenes.keys)
    if (env.file('scenes/$f').existsSync()) f,
};

/// Fits the beat scenes, the 2D view and the 3D view to the hung [heads].
/// Writes everything together. Returns the report text and the beat scenes
/// it looks after, which Tonight's Rig then leaves alone.
({String out, Set<String> scenes}) rigLayoutApply(ShowEnv env, List<String> heads) {
  env.requireSxClosed();
  final movers = showMovers(env);
  final ids = rigHeadIds(heads);
  final known = {for (final m in movers) m.id};
  final bad = ids.where((i) => !known.contains(i)).toList();
  if (bad.isNotEmpty) throw ToolError('Unknown head(s): ${bad.join(', ')}. NOTHING was changed.');
  final hung = ids.toSet();
  final state = _LayoutState.read(env);
  final rigState = RigState.read(env);
  final writes = RigWrites();
  final out = <String>[];
  final handled = <String>{};

  // where each hung head is in the 2D view
  final twoPath = env.path('Editor/2DView/fixtures.ini');
  final two = File(twoPath).existsSync() ? _Ini.read(twoPath) : null;
  final at = <String, (int, int)>{};
  if (two != null) {
    final rx = RegExp(r'^(-?\d+)\s*,\s*(-?\d+)');
    for (final m in movers) {
      final v = two.get(m.name, 'Position');
      final p = v == null ? null : rx.firstMatch(v);
      if (p != null) at[m.id] = (int.parse(p[1]!), int.parse(p[2]!));
    }
  }
  final placed = [
    for (final m in movers)
      if (hung.contains(m.id) && at.containsKey(m.id)) (id: m.id, x: at[m.id]!.$1, y: at[m.id]!.$2),
  ];
  final unplaced = [
    for (final m in movers)
      if (hung.contains(m.id) && !at.containsKey(m.id)) m.label,
  ];

  // the beat scenes
  final newScenes = <String, Object?>{};
  if (two == null) {
    out.add('  beat scenes left as they are: the show has no 2D view yet (open the 2D view in ShowXpress once)');
    state.scenes.forEach((f, v) => newScenes[f] = {'original': v.original, 'written': v.written});
  } else {
    final groups = RigGroups.of(placed);
    final modelOf = {for (final m in movers) m.id: m.model};
    final defs = FixtureDefs(env);
    final hungOrder = [
      for (final m in movers)
        if (hung.contains(m.id)) m.id,
    ];
    for (final MapEntry(key: f, value: pattern) in layoutScenes.entries) {
      final path = env.path('scenes/$f');
      final name = f.replaceFirst(RegExp(r'\.scex$', caseSensitive: false), '');
      if (!File(path).existsSync()) continue;
      final cur = readText(path);
      final st = state.scenes[f], rs = rigState.scenes[f];
      final String base;
      var note = '';
      if (st != null && psEq(textSha(cur), st.written)) {
        base = st.original;
      } else if (rs != null && psEq(textSha(cur), rs.written)) {
        base = rs.original; // trimmed by an older Tonight's Rig: start from the full scene
      } else {
        base = cur;
        if (st != null) note = ' (changed in ShowXpress since last time - that version now counts as the full scene)';
      }
      final fit = _fitScene(base, pattern, groups, hungOrder, modelOf, defs);
      final text = fit.text ?? cur;
      if (fit.text == null) {
        if (st != null) newScenes[f] = {'original': st.original, 'written': st.written};
        out.add('  left     $name: ${fit.note}');
        continue;
      }
      handled.add(f);
      if (text != base) newScenes[f] = {'original': base, 'written': textSha(text)};
      if (text != cur) {
        writes.add(path, text);
        out.add('  CHANGED  $name: ${fit.note}$note');
      } else {
        out.add('  same     $name: ${fit.note}$note');
      }
    }
    if (unplaced.isNotEmpty) out.add('  not in the 2D view, so only in the all-heads steps: ${unplaced.join(', ')}');
  }

  // the 2D view: heads not hung hidden
  if (two != null) {
    var hid = 0, shown = 0;
    for (final m in movers) {
      if (two.find(m.name) == null) continue;
      final hidden = two.get(m.name, 'Hidden') == '1';
      if (hung.contains(m.id) && hidden) {
        two.set(m.name, 'Hidden', null);
        shown++;
      } else if (!hung.contains(m.id) && !hidden) {
        two.set(m.name, 'Hidden', '1', after: 'Position');
        hid++;
      }
    }
    if (two.newText != two.text) {
      writes.add(two.path, two.newText, bom: two.bom);
      out.add('  2D view: ${[if (hid > 0) '$hid not hung hidden', if (shown > 0) '$shown hung shown again'].join(', ')}');
    } else {
      out.add('  2D view: already shows just the hung heads');
    }
  }

  // the 3D view: hung heads where they are in the 2D view, the rest taken out
  final removed = Map.of(state.removed3d);
  final threePath = env.path('3DView/fixtures.ini');
  if (File(threePath).existsSync()) {
    final three = _Ini.read(threePath);
    var moved = 0, out3 = 0, back = 0;
    for (final m in movers) {
      final has = three.find(m.id) != null;
      if (!hung.contains(m.id)) {
        if (has) {
          removed[m.id] = three.remove(m.id);
          out3++;
        }
        continue;
      }
      if (!has) {
        final saved = removed.remove(m.id);
        if (saved != null) {
          three.append(saved);
        } else {
          // never in the 3D view (the 251s): made like another head of its model, or any mover
          final like =
              movers.where((o) => o.model == m.model && three.find(o.id) != null).firstOrNull ?? movers.where((o) => three.find(o.id) != null).firstOrNull;
          if (like == null) continue;
          final se = three.find(like.id)!;
          three.append([
            '[${m.id}]',
            for (final l in three.lines.sublist(se.$1 + 1, se.$2)) RegExp(r'^Name\s*=', caseSensitive: false).hasMatch(l) ? 'Name = ${m.name}' : l,
          ]);
        }
        back++;
      }
      final p = at[m.id];
      if (p != null) {
        final v = position3d(p.$1, p.$2);
        if (three.get(m.id, 'Position') != v) {
          three.set(m.id, 'Position', v, after: 'Name');
          moved++;
        }
      }
    }
    if (three.newText != three.text) {
      writes.add(three.path, three.newText, bom: three.bom);
      out.add(
        '  3D view: ${[if (moved > 0) '$moved moved to where they hang', if (back > 0) '$back put back', if (out3 > 0) '$out3 not hung taken out (they come back when hung)'].join(', ')}',
      );
    } else {
      out.add('  3D view: already matches');
    }
  }

  // state last
  final statePath = env.path('rig_layout.json');
  if (newScenes.isNotEmpty || removed.isNotEmpty) {
    writes.add(statePath, psJson({'scenes': newScenes, 'removed3d': removed}), bom: false);
  } else if (File(statePath).existsSync() && readText(statePath) != rigEmptyState) {
    writes.add(statePath, rigEmptyState, bom: false);
  }
  writes.commit();
  return (out: out.join('\n'), scenes: handled);
}
