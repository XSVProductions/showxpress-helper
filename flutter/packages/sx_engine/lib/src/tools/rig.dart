import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:sx_api/sx_api.dart';

import '../ps_compat.dart';
import '../show/fixtures.dart';
import '../show/live_ini.dart';
import '../show/movers.dart';
import '../show/show_env.dart';
import '../show/text_files.dart';

// TONIGHT'S RIG: tick the movers that are hung tonight. Every chase scene on a
// live button drops the steps that would be dark without them, plus the dark
// gap steps that follow, and gets them back when the heads are ticked again.
// The full scenes are kept in rig_state.json while they are trimmed.
//
// Port of `rig.ps1`.

/// Show files that are saved together: all of them or none.
///
/// The old tools wrote one file after another, so a failure halfway left the
/// show half changed. Here each file goes through [writeTextSafely] in the
/// order added (state files last), and if one fails the files already written
/// are put back as they were.
class RigWrites {
  final _files = <(String, String, bool?)>[];

  bool get isEmpty => _files.isEmpty;

  /// Queues [text] for [path]. [bom] null keeps the file's own byte order mark.
  void add(String path, String text, {bool? bom}) => _files.add((path, text, bom));

  /// Writes everything. Throws [ToolError] after putting the show back when a
  /// write fails.
  void commit() {
    final done = <(String, List<int>?)>[];
    for (final (path, text, bom) in _files) {
      final f = File(path);
      try {
        final before = f.existsSync() ? f.readAsBytesSync() : null;
        writeTextSafely(path, text, bom: bom ?? (before != null && hasBom(before)));
        done.add((path, before));
      } on FileSystemException catch (e) {
        for (final (path, before) in done.reversed) {
          if (before == null) {
            File(path).deleteSync();
          } else {
            writeBytesSafely(path, before);
          }
        }
        final tmp = File('$path.sxtmp');
        if (tmp.existsSync()) tmp.deleteSync();
        throw ToolError("Couldn't save ${p.basename(path)} (${e.osError?.message ?? e.message}). NOTHING was changed.");
      }
    }
  }
}

/// Reads a JSON state file. Missing, empty or `{}` all read as null (no state).
Map<String, Object?>? readRigStateFile(File f) {
  if (!f.existsSync()) return null;
  final text = readText(f.path);
  if (text.trim().isEmpty) return null;
  final j = jsonDecode(text);
  if (j is! Map || j.isEmpty) return null;
  return j.cast<String, Object?>();
}

/// What an old tool's deleted state file becomes: an empty state. A deleted
/// file let Google Drive import bring a stale copy back.
const rigEmptyState = '{}';

/// Splits `-Heads "id,id"` the way the old tools do.
List<String> rigHeadIds(Iterable<String> raw) => [
  for (final s in raw)
    for (final id in s.split(RegExp(r'[,;\s]+')))
      if (id.isNotEmpty) id,
];

/// The text of PowerShell's `"$x"` for a JSON value.
String _psStr(Object? v) => v == null ? '' : '$v';

/// `rig_state.json`: the heads saved as hung (null = all of them) and the
/// full version of every scene that is trimmed now.
class RigState {
  RigState(this.hung, this.scenes);

  factory RigState.read(ShowEnv env) {
    final j = readRigStateFile(env.file('rig_state.json'));
    final scenes = psMap<({String original, String written})>();
    if (j == null) return RigState(null, scenes);
    final h = j['hung'];
    final hung = psTruthy(h)
        ? [
            for (final x in h is List ? h : [h]) _psStr(x),
          ]
        : null;
    final sc = j['scenes'];
    if (sc is Map) {
      sc.forEach((k, v) {
        scenes['$k'] = (original: _psStr(v is Map ? v['original'] : null), written: _psStr(v is Map ? v['written'] : null));
      });
    }
    return RigState(hung, scenes);
  }

  final List<String>? hung;
  final Map<String, ({String original, String written})> scenes;
}

final _stepRx = RegExp(r'\r?\n[ \t]*<Step\b(?:[^>]*/>|[^>]*>.*?</Step>)', dotAll: true);

/// Lit step plus the all-dark steps after it. Leading dark steps belong to
/// the last group, as the scene loops. Empty when fewer than 2 steps light.
List<List<int>> _groups(List<SceneStep> steps) {
  final li = [
    for (var i = 0; i < steps.length; i++)
      if (steps[i].lit.isNotEmpty || steps[i].other) i,
  ];
  if (li.length < 2) return const [];
  return [
    for (var k = 0; k < li.length; k++)
      [
        for (var i = li[k]; i <= (k + 1 < li.length ? li[k + 1] - 1 : steps.length - 1); i++) i,
        if (k + 1 == li.length && li[0] > 0)
          for (var i = 0; i < li[0]; i++) i,
      ],
  ];
}

/// Step indexes to take out for [hung], sorted, or null when every step
/// would go (the scene is then left alone).
List<int>? _dropSteps(List<SceneStep> steps, Set<String> hung) {
  final groups = _groups(steps);
  final drop = <int>[];
  var kept = 0;
  for (final g in groups) {
    final s = steps[g.first];
    if (!s.other && s.lit.isNotEmpty && !s.lit.any(hung.contains)) {
      drop.addAll(g);
    } else {
      kept++;
    }
  }
  if (groups.isNotEmpty && kept == 0) return null;
  return drop..sort();
}

/// True when the lit steps don't all light the same movers.
bool _isChase(List<SceneStep> steps) {
  final sets = {
    for (final s in steps)
      if (s.lit.isNotEmpty || s.other) '${psSorted<String>(s.lit, [(x) => x]).join(',')}|${s.other ? 'True' : 'False'}',
  };
  return sets.length > 1 && steps.any((s) => s.lit.isNotEmpty);
}

String _removeSteps(String text, List<int> drop) {
  final b = StringBuffer();
  var pos = 0;
  for (final (i, m) in _stepRx.allMatches(text).indexed) {
    if (drop.contains(i)) {
      b.write(text.substring(pos, m.start));
      pos = m.end;
    }
  }
  b.write(text.substring(pos));
  return b.toString();
}

class _Chase {
  _Chase(this.file, this.path, this.cur, this.base, this.steps, this.trimmed, this.edited, this.titles);

  final String file;
  final String path;
  final String cur;
  final String base;
  final List<SceneStep> steps;
  final bool trimmed;
  final bool edited;
  final List<String> titles;
}

/// What both actions read: the movers, the state and the chase scenes.
class _Rig {
  _Rig._(this.movers, this.state, this.scenes);

  /// [leave]: scene files another tool looks after, not trimmed here.
  factory _Rig.read(ShowEnv env, {Set<String> leave = const {}}) {
    if (!env.file('Live/live.ini').existsSync()) throw ToolError("Show not found at '${env.root}'. NOTHING was changed.");
    final movers = showMovers(env);
    if (movers.isEmpty) throw ToolError('No 140SR/251SR fixtures found in the show. NOTHING was changed.');
    final modelOf = {for (final m in movers) m.id: m.model};
    final state = RigState.read(env);

    // chase scenes: every .scex on a live button whose lit steps don't all
    // light the same movers, plus any still trimmed
    final info = LiveInfo.read(env);
    bool isScex(String n) => n.toLowerCase().endsWith('.scex');
    // SKIP FLASH is rebuilt by skip_flash.ps1 with just the hung heads, not trimmed here
    final skipFiles = [
      for (final b in info.buttons)
        if (psEq(b.title, 'SKIP FLASH') && isScex(b.name)) b.name,
      ...leave,
    ];
    for (final f in skipFiles) {
      state.scenes.remove(f);
    }
    final byFile = psMap<List<String>>();
    for (final b in info.buttons) {
      if (!isScex(b.name) || skipFiles.any((f) => psEq(f, b.name))) continue;
      final titles = byFile.putIfAbsent(b.name, () => []);
      final t = b.title.isNotEmpty ? b.title : b.name.replaceFirst(RegExp(r'\.scex$', caseSensitive: false), '');
      if (!titles.contains(t)) titles.add(t);
    }
    for (final f in state.scenes.keys) {
      byFile.putIfAbsent(f, () => []);
    }

    final defs = FixtureDefs(env);
    final scenes = <_Chase>[];
    Directory? tmp;
    try {
      for (final MapEntry(key: f, value: titles) in byFile.entries) {
        final path = env.path('scenes/$f');
        if (!File(path).existsSync()) continue;
        final cur = readText(path);
        final st = state.scenes[f];
        final trimmed = st != null && psEq(textSha(cur), st.written);
        final base = trimmed ? st.original : cur;
        final List<SceneStep> steps;
        if (trimmed) {
          tmp ??= Directory.systemTemp.createTempSync('sx_rig_');
          final t = File(p.join(tmp.path, 'scene.scex'))..writeAsStringSync(base);
          steps = sceneSteps(defs, t.path, modelOf);
        } else {
          steps = sceneSteps(defs, path, modelOf);
        }
        if (st == null && !_isChase(steps)) continue;
        // unusual file layout: never touch it
        if (_stepRx.allMatches(base).length != steps.length) continue;
        scenes.add(_Chase(f, path, cur, base, steps, trimmed, st != null && !trimmed, titles));
      }
    } finally {
      tmp?.deleteSync(recursive: true);
    }
    return _Rig._(movers, state, scenes);
  }

  final List<Mover> movers;
  final RigState state;
  final List<_Chase> scenes;
}

/// What the Tonight's Rig screen shows. Writes nothing. [leave] as in [rigApply].
RigPreview rigPreview(ShowEnv env, {Set<String> leave = const {}}) {
  final r = _Rig.read(env, leave: leave);
  final hung = r.state.hung ?? [for (final m in r.movers) m.id];
  final flip = FlipState.read(env);
  return RigPreview(
    show: env.root,
    heads: [
      for (final m in r.movers)
        RigHead(
          id: m.id,
          label: m.label,
          num: m.num,
          is140: m.is140,
          on: hung.any((h) => psEq(h, m.id)),
          rp: flip.heads[m.id]?.pan ?? false,
          rt: flip.heads[m.id]?.tilt ?? false,
        ),
    ],
    scenes: [
      for (final s in r.scenes)
        RigScene(
          file: s.file,
          name: s.file.replaceFirst(RegExp(r'\.scex$', caseSensitive: false), ''),
          titles: s.titles,
          trimmed: s.trimmed,
          edited: s.edited,
          groups: _groups(s.steps),
          steps: [for (final x in s.steps) RigStep(cs: x.cs, lit: x.lit, other: x.other)],
        ),
    ],
  );
}

/// Trims or restores every chase scene for the hung [heads]. Returns the
/// report text. Scene files in [leave] are left alone and forgotten, like
/// SKIP FLASH: the beat scenes that follow the layout (`rig_layout.dart`).
String rigApply(ShowEnv env, List<String> heads, {Set<String> leave = const {}}) {
  final r = _Rig.read(env, leave: leave);
  env.requireSxClosed();
  final ids = rigHeadIds(heads);
  final known = {for (final m in r.movers) m.id};
  final bad = ids.where((i) => !known.contains(i)).toList();
  if (bad.isNotEmpty) throw ToolError('Unknown head(s): ${bad.join(', ')}. NOTHING was changed.');
  if (ids.isEmpty) throw ToolError('Tick at least one head. NOTHING was changed.');
  final hung = ids.toSet();

  final writes = RigWrites();
  final lines = <String>[];
  final newState = <String, Object?>{};
  var changed = 0;
  for (final s in r.scenes) {
    var drop = _dropSteps(s.steps, hung);
    var note = '';
    if (drop == null) {
      drop = const [];
      note = ' (none of its heads are hung - left complete)';
    }
    final text = drop.isNotEmpty ? _removeSteps(s.base, drop) : s.base;
    if (drop.isNotEmpty) newState[s.file] = {'original': s.base, 'written': textSha(text)};
    final kept = s.steps.length - drop.length;
    final what = drop.isNotEmpty ? '$kept of ${s.steps.length} steps' : 'all ${s.steps.length} steps';
    if (s.edited) note += ' (changed in ShowXpress since last time - that version now counts as the full scene)';
    final name = s.file.replaceFirst(RegExp(r'\.scex$', caseSensitive: false), '');
    if (!psEq(text, s.cur)) {
      writes.add(s.path, text);
      changed++;
      lines.add('  CHANGED  $name: $what$note');
    } else {
      lines.add('  same     $name: $what$note');
    }
  }
  final allHung = ids.length == r.movers.length;
  final statePath = env.path('rig_state.json');
  if (!allHung || newState.isNotEmpty) {
    writes.add(statePath, psJson({'hung': allHung ? null : ids, 'scenes': newState}), bom: false);
  } else if (File(statePath).existsSync() && readText(statePath) != rigEmptyState) {
    writes.add(statePath, rigEmptyState, bom: false);
  }
  writes.commit();

  final notHung = [
    for (final m in r.movers)
      if (!hung.contains(m.id)) m.label,
  ];
  return [
    '  heads hung: ${ids.length} of ${r.movers.length}${allHung ? '' : '  (not hung: ${notHung.join(', ')})'}',
    '  chase scenes: ${r.scenes.length}, changed: $changed',
    ...lines,
  ].join('\n');
}
