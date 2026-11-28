// The rig routes chain several tools in one save, the way `Invoke-Action` in
// df_aim_gui.ps1 does. These check the chaining and the route's own input
// checks on a copy of the real show.
import 'package:sx_api/sx_api.dart';
import 'package:sx_engine/sx_engine.dart';
import 'package:test/test.dart';

import 'parity.dart';
import 'rig_helpers.dart';

class _ClosedSx implements SxApp {
  @override
  bool get running => false;

  @override
  Future<ToolResult> launch() async => const ToolResult(ok: true);

  @override
  Future<ToolResult> close({bool force = false}) async => const ToolResult(ok: true);
}

/// Where the save's report goes on to the beat scenes and the views (`rig_layout.dart`).
const _layout = '\n\n  Beat scenes and views (from where the heads are in the 2D view):\n';

void main() {
  if (paritySkip != null) {
    test('rig routes', () {}, skip: paritySkip);
    return;
  }
  late ShowEnv env;
  late Engine engine;
  late SxClient client;
  final h140 = ids(realMovers.where((m) => m.is140));

  setUp(() async {
    env = copyOfShow();
    engine = Engine(
      EngineConfig(port: 0, token: 't', showPath: env.root),
      sx: _ClosedSx(),
    );
    await engine.start();
    client = SxClient(Uri.parse('http://127.0.0.1:${engine.port}'), token: 't');
  });

  tearDown(() async {
    client.close();
    await engine.stop();
  });

  test('rig save: reversed heads, then the rig, then SKIP FLASH', () async {
    final hung = h140.take(6).toList();
    final r = await client.rigApply(hung, {h140.first: (pan: true, tilt: false)});
    expect(r.ok, isTrue, reason: r.error);
    expect(r.out, startsWith('  Reversed heads:\n  CHANGED  140 #1: pan reversed by SX Studio\n'));
    expect(r.out, contains("values)\n\n  Tonight's Rig:\n  heads hung: 6 of ${realMovers.length}"));
    expect(r.out, contains('\n\n  SKIP FLASH now flashes 6 heads$_layout'));
    // the beat scenes follow where the heads are in the 2D view, and the heads not hung are hidden there
    expect(r.out, contains('  CHANGED  BEAT LEFT RIGHT: left '));
    expect(r.out, contains(RegExp(r'  2D view: \d+ not hung hidden')));
    expect(rigPreview(env, leave: layoutSceneFiles(env)).scenes.map((s) => s.file), isNot(contains('BEAT LEFT RIGHT.scex')));
    expect(FlipState.read(env).heads.keys, [h140.first]);
    expect(skipPreview(env).heads.where((h) => h.on).map((h) => h.id), hung);

    // the same save again: nothing to reverse, so no "Reversed heads" part
    final again = await client.rigApply(hung, {h140.first: (pan: true, tilt: false)});
    expect(again.out, startsWith('  heads hung: 6 of'));
    expect(again.out, contains('\n\n  SKIP FLASH already flashes these 6 heads$_layout'));
    expect(again.out, contains('  same     BEAT LEFT RIGHT'));
    expect(again.out, endsWith('  3D view: already matches'));
  });

  test('rig save with one head leaves SKIP FLASH alone', () async {
    final r = await client.rigApply([h140.first], {});
    expect(r.ok, isTrue, reason: r.error);
    expect(r.out, contains('\n\n  SKIP FLASH not changed (it needs at least 2 heads)$_layout'));
  });

  test('rig save: the rig fails after the reversed heads were saved', () async {
    final r = await client.rigApply(['999'], {h140.first: (pan: true, tilt: false)});
    expect(r.ok, isFalse);
    expect(r.error, "The reversed heads WERE saved, but Tonight's Rig was not: Unknown head(s): 999. NOTHING was changed.");
    expect(r.out, startsWith('  Reversed heads:\n'));
    expect(FlipState.read(env).heads.keys, [h140.first]);
  });

  test('rig save: the reversed heads fail, nothing else runs', () async {
    final r = await client.rigApply([h140.first], {'999': (pan: true, tilt: false)});
    expect(r.error, "Reversed heads NOT saved (nothing was changed): Unknown head '999'. NOTHING was changed.");
  });

  test('route input checks', () async {
    expect((await client.run('/api/rig/apply', {'heads': <String>[]})).error, 'Tick at least one head.');
    expect(
      (await client.run('/api/rig/apply', {
        'heads': ['1x'],
      })).error,
      'Tick at least one head.',
    );
    expect(
      (await client.run('/api/rig/apply', {
        'heads': [h140.first],
        'flip': {
          'abc': {'pan': true},
        },
      })).error,
      'Unknown head.',
    );
    expect((await client.skipApply([h140.first])).error, 'Pick at least 2 heads.');
    expect((await client.rtApply({'zz-l': h140.first, 'tl-l': 'x'}, extra: false, rig: false)).error, 'Put at least one mover on a truss.');
  });

  test('rig test save updates Tonight\'s Rig and SKIP FLASH', () async {
    final assign = {'tl-l': h140[0], 'tl-r': h140[1], 'br-l': h140[2]};
    final r = await client.rtApply(assign, extra: false, rig: true);
    expect(r.ok, isTrue, reason: r.error);
    // the saved rig has two 140s and no 251s hung, so no 251 comes along
    expect(r.out, contains('RIGHEADS: ${assign.values.join(',')}\nSKIPHEADS: ${assign.values.join(',')}\n\n  Tonight\'s Rig:\n  heads hung: 3 of'));
    expect(r.out, contains('\n\n  SKIP FLASH now flashes 3 heads$_layout'));
    expect(RigState.read(env).hung, assign.values);

    final off = await client.rtApply(assign, extra: false, rig: false);
    expect(off.out, isNot(contains("Tonight's Rig")));
  });
}
