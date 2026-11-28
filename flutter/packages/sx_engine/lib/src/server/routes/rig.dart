import 'package:sx_api/sx_api.dart';

import '../../ps_compat.dart';
import '../../show/movers.dart';
import '../../show/show_env.dart';
import '../../tools/flip.dart';
import '../../tools/rig.dart';
import '../../tools/rig_layout.dart';
import '../../tools/rig_test.dart';
import '../../tools/skip_flash.dart';
import '../api.dart';
import '../engine.dart';
import '../ps_body.dart';

final _digits = RegExp(r'^\d+$');

/// Tonight's Rig (with Reverse Heads), Strobe and Rig Test.
///
/// Port of their cases in `Invoke-Action` and the request loop of `df_aim_gui.ps1`.
void registerRigRoutes(Engine e) {
  e.api.get('/api/rig', (req) {
    final env = e.show();
    return rigPreview(env, leave: layoutSceneFiles(env));
  });
  e.api.get('/api/skip', (req) => skipPreview(e.show()));
  e.api.get('/api/rt', (req) => rtPreview(e.show()));

  e.api.post('/api/skip/apply', queue: const Queueable('Strobe'), (req) {
    final ids = bodyTexts(req.body['heads']);
    if (ids.any((i) => !_digits.hasMatch(i)) || ids.length < 2) throw ToolError('Pick at least 2 heads.');
    return skipApply(e.show(), ids);
  });

  e.api.post('/api/rig/apply', queue: const Queueable("Tonight's Rig"), (req) {
    final ids = bodyTexts(req.body['heads']);
    if (ids.any((i) => !_digits.hasMatch(i)) || ids.isEmpty) throw ToolError('Tick at least one head.');
    final env = e.show();
    // Reversed heads are saved from this tab too, always the full list, so a
    // queued save that replaces an older one keeps it
    var fo = '';
    final flipBody = req.body['flip'];
    if (flipBody != null) {
      final flip = <String, Flip>{};
      for (final MapEntry(:key, :value) in _properties(flipBody).entries) {
        if (!_digits.hasMatch(key)) throw ToolError('Unknown head.');
        final pan = psTruthy(field(value, 'pan')), tilt = psTruthy(field(value, 'tilt'));
        if (pan || tilt) flip[key] = (pan: pan, tilt: tilt);
      }
      final String fout;
      try {
        fout = flipApply(env, flip);
      } on ToolError catch (x) {
        throw ToolError('Reversed heads NOT saved (nothing was changed): ${x.message}');
      }
      if (!fout.contains('nothing to change')) fo = "  Reversed heads:\n${fout.trimRight()}\n\n  Tonight's Rig:\n";
    }
    final layout = _layout(env, ids);
    final String out;
    try {
      out = rigApply(env, ids, leave: layout.scenes);
    } on ToolError catch (x) {
      if (fo.isEmpty && layout.scenes.isEmpty) rethrow;
      return ToolResult(
        ok: false,
        out: '$fo${layout.out.trimLeft()}',
        error: fo.isNotEmpty ? "The reversed heads WERE saved, but Tonight's Rig was not: ${x.message}" : "Tonight's Rig was not saved: ${x.message}",
      );
    }
    return '$fo$out\n${_updateSkipFlash(env, ids)}${layout.out}';
  });

  e.api.post('/api/rt/install', queue: const Queueable('RIG ID button'), (req) => rtInstall(e.show()));

  e.api.post('/api/rt/apply', queue: const Queueable('Rig Test (2D view)'), (req) {
    final assign = psMap<String>();
    final slot = RegExp(r'^(tl|tr|tm|bl|br|bm)-(l|r)$', caseSensitive: false);
    if (psTruthy(req.body['assign'])) {
      for (final MapEntry(:key, :value) in _properties(req.body['assign']).entries) {
        final id = bodyText(value);
        if (slot.hasMatch(key) && _digits.hasMatch(id)) assign[key] = id;
      }
    }
    if (assign.isEmpty) throw ToolError('Put at least one mover on a truss.');
    final env = e.show();
    var out = rtApply(env, assign, extra: psTruthy(req.body['extra']));
    if (psTruthy(req.body['rig'])) {
      String? last(String prefix) => out.split('\n').where((l) => RegExp('^$prefix: [\\d,]+\$').hasMatch(l)).lastOrNull?.substring(prefix.length + 2);
      final rigHeads = last('RIGHEADS');
      var layoutOut = '';
      if (rigHeads != null) {
        final layout = _layout(env, rigHeadIds([rigHeads]));
        layoutOut = layout.out;
        try {
          out += "\n\n  Tonight's Rig:\n${rigApply(env, rigHeadIds([rigHeads]), leave: layout.scenes)}";
        } on ToolError catch (x) {
          out += "\n\n  Tonight's Rig NOT updated: ${x.message}";
        }
      }
      final skipHeads = last('SKIPHEADS');
      if (skipHeads != null) out += '\n${_updateSkipFlash(env, skipHeads.split(','))}';
      out += layoutOut;
    } else {
      // the heads moved but which are hung didn't change: the beat scenes and views follow
      final hung = RigState.read(env).hung ?? [for (final m in showMovers(env)) m.id];
      out += _layout(env, hung).out;
    }
    return out;
  });
}

/// The beat scenes, the 2D view and the 3D view follow the hung heads
/// ([rigLayoutApply]). The report starts with a blank line. A failure is
/// reported, not thrown, so the rest of the save still goes ahead.
///
/// New in the Flutter app.
({String out, Set<String> scenes}) _layout(ShowEnv env, List<String> heads) {
  try {
    final r = rigLayoutApply(env, heads);
    return (out: '\n\n  Beat scenes and views (from where the heads are in the 2D view):\n${r.out}', scenes: r.scenes);
  } on ToolError catch (x) {
    return (out: '\n\n  Beat scenes and views NOT updated: ${x.message}', scenes: <String>{});
  }
}

/// SKIP FLASH follows the hung heads too. It needs 2 or more.
///
/// Port of `Update-SkipFlash`. Starts with a line break, like the old one.
String _updateSkipFlash(ShowEnv env, List<String> heads) {
  final ids = heads.where(_digits.hasMatch).toList();
  if (ids.length < 2) return '\n  SKIP FLASH not changed (it needs at least 2 heads)';
  final String out;
  try {
    out = skipApply(env, ids);
  } on ToolError catch (x) {
    return '\n  SKIP FLASH NOT updated: ${x.message}';
  }
  return out.contains('nothing to change') ? '\n  SKIP FLASH already flashes these ${ids.length} heads' : '\n  SKIP FLASH now flashes ${ids.length} heads';
}

/// `$x.PSObject.Properties` of a value decoded from a request: an object's
/// fields. Text and lists have their .NET properties (`Length`, `Count`...),
/// none of them a head or a truss, so they stand in as one such name.
/// Numbers and true/false have none.
Map<String, Object?> _properties(Object? v) => switch (v) {
  Map m => m.cast<String, Object?>(),
  String _ => const {'Length': null},
  List _ => const {'Length': null},
  _ => const {},
};
