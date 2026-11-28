import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:sx_engine/sx_engine.dart';
import 'package:test/test.dart';

final _bom = String.fromCharCode(0xFEFF);
const _m = 'Intimidator Hybrid 140SR (19ch)';
const _ids = ['11', '12', '13', '14'];
String _name(int n) => n == 1 ? _m : '$_m #$n';

String _fixtures() => [for (var n = 1; n <= 4; n++) '    <Fixture id="${_ids[n - 1]}" name="${_name(n)}" model="$_m"/>'].join('\r\n');

/// A scene like the generated beat scenes: per step, the heads (by number) lit.
String _scene(List<({int len, Set<int> on, int dim})> steps) {
  final b = StringBuffer('<?xml version="1.0" encoding="UTF-8"?>\r\n\r\n<Scene>\r\n  <Fixtures>\r\n${_fixtures()}\r\n  </Fixtures>\r\n  <Steps>\r\n');
  for (final s in steps) {
    b.write('    <Step length="${s.len}">\r\n');
    for (var n = 1; n <= 4; n++) {
      final on = s.on.contains(n);
      b
        ..write('      <Fixture id="${_ids[n - 1]}">\r\n')
        ..write('        <Channel index="5" name="color" value="${n * 10}"/>\r\n')
        ..write('        <Channel index="15" name="dimmer" value="${on ? s.dim : 0}"/>\r\n')
        ..write('        <Channel index="16" name="shutter" value="${on ? 255 : 0}"/>\r\n')
        ..write('      </Fixture>\r\n');
    }
    b.write('    </Step>\r\n');
  }
  b.write('  </Steps>\r\n</Scene>\r\n');
  return b.toString();
}

/// Which heads (by number) each step of a scene lights.
List<Set<int>> _lit(String text) => [
  for (final s in RegExp(r'<Step\b[^>]*>(.*?)</Step>', dotAll: true).allMatches(text))
    {
      for (final f in RegExp(r'<Fixture id="(\d+)">(.*?)</Fixture>', dotAll: true).allMatches(s[1]!))
        if (!f[2]!.contains('name="dimmer" value="0"')) _ids.indexOf(f[1]!) + 1,
    },
];

void main() {
  late Directory tmp;
  late String root;
  var open = false;
  ShowEnv env() => ShowEnv(root, sxRunning: () => open);
  String read(String rel) => File(p.join(root, rel)).readAsStringSync();
  void write(String rel, String text) => File(p.join(root, rel))
    ..parent.createSync(recursive: true)
    ..writeAsStringSync(text);

  // the 3D view's old layout put #1 and #2 on the left. Tonight #3 and #4 hang
  // on the left tower and #1 and #2 on the right one.
  setUp(() {
    open = false;
    tmp = Directory.systemTemp.createTempSync('sx_layout_');
    root = p.join(tmp.path, 'show');
    write(
      'Live/live.ini',
      '[live]\r\n\r\n[page1]\r\nname = BEAT/BPM\r\nnb_buttons = 2\r\n\r\n'
          '[page1_button1]\r\nline = 1\r\ncolumn = 1\r\nname = BEAT LEFT RIGHT.scex\r\ntitle = BEAT LEFT RIGHT\r\n\r\n'
          '[page1_button2]\r\nline = 1\r\ncolumn = 2\r\nname = BEAT BUILD.scex\r\ntitle = BEAT BUILD\r\n',
    );
    write(
      'scenes/CENTER SPOT.scex',
      '<?xml version="1.0" encoding="UTF-8"?>\r\n<Scene>\r\n  <Fixtures>\r\n${_fixtures()}\r\n  </Fixtures>\r\n  <Steps/>\r\n</Scene>\r\n',
    );
    write(
      'scenes/BEAT LEFT RIGHT.scex',
      _scene([
        (len: 48, on: {1, 2}, dim: 255),
        (len: 48, on: {3, 4}, dim: 255),
      ]),
    );
    write(
      'scenes/BEAT BUILD.scex',
      _scene([
        (len: 30, on: {1}, dim: 200),
        (len: 30, on: {1, 2}, dim: 200),
        (len: 30, on: {1, 2, 3}, dim: 200),
        (len: 30, on: {1, 2, 3, 4}, dim: 200),
      ]),
    );
    write(
      'Editor/2DView/fixtures.ini',
      '$_bom\r\n[${_name(1)}]\r\nPosition = 786,0\r\n[${_name(2)}]\r\nPosition = 896,0\r\n[${_name(3)}]\r\nPosition = 0,0\r\n[${_name(4)}]\r\nPosition = 110,0\r\n[UPLIGHT]\r\nPosition = 439,640\r\n',
    );
    write(
      '3DView/fixtures.ini',
      [
        _bom,
        for (var n = 1; n <= 4; n++) ...[
          '[${_ids[n - 1]}]',
          'Name = ${_name(n)}',
          'Position = ${n - 3}.00,0.00,0.00',
          'Orientation = 0,${80 + n},0',
          'Object = default',
        ],
        '[99]',
        'Name = UPLIGHT',
        'Position = 0.44,0.00,0.00',
        '',
      ].join('\r\n'),
    );
  });
  tearDown(() => tmp.deleteSync(recursive: true));

  group('groups from where the heads hang', () {
    // three T-bars in one row, like the 2D view's top row
    final row = [
      (id: 'a', x: 0, y: 0),
      (id: 'b', x: 110, y: 0),
      (id: 'c', x: 329, y: 0),
      (id: 'd', x: 595, y: 0),
      (id: 'e', x: 786, y: 0),
      (id: 'f', x: 896, y: 0),
    ];

    test('one row: left and right, the middle T-bar against the outside, every other head, a build from the middle', () {
      final g = RigGroups.of(row);
      expect(g.left, ['a', 'b', 'c']);
      expect(g.right, ['d', 'e', 'f']);
      expect(g.back, ['c', 'd']);
      expect(g.sides, ['b', 'e', 'a', 'f']);
      expect(g.a, ['a', 'c', 'e']);
      expect(g.b, ['b', 'd', 'f']);
      expect([for (var k = 1; k <= 4; k++) g.buildLevel(k, 4).length], [2, 4, 4, 6]);
    });

    test('two rows: the back is the top row of the page', () {
      final g = RigGroups.of([(id: 'tl', x: 0, y: 0), (id: 'tr', x: 896, y: 0), (id: 'bl', x: 0, y: 592), (id: 'br', x: 896, y: 592)]);
      expect(g.back, ['tl', 'tr']);
      expect(g.sides, ['bl', 'br']);
      expect(g.left, ['tl', 'bl']);
      expect(g.a, ['tl', 'bl']);
    });

    test('the 3D view gets the 2D place up on the truss, the top of the page at the back', () {
      expect(position3d(0, 0), '-8.00,9.00,-10.00');
      expect(position3d(448, 592), '0.00,9.00,0.00');
      expect(position3d(896, 296), '8.00,9.00,-5.00');
    });
  });

  test('the beat scenes light the heads where they really hang, with their own timing and values', () {
    final r = rigLayoutApply(env(), _ids);
    expect(r.scenes, {'BEAT LEFT RIGHT.scex', 'BEAT BUILD.scex'});
    final lr = read('scenes/BEAT LEFT RIGHT.scex');
    expect(_lit(lr), [
      {3, 4},
      {1, 2},
    ]);
    // the build starts in the middle of the room: the inner head of each tower
    expect(_lit(read('scenes/BEAT BUILD.scex')), [
      {1, 4},
      {1, 4},
      {1, 2, 3, 4},
      {1, 2, 3, 4},
    ]);
    expect(read('scenes/BEAT BUILD.scex'), contains('<Step length="30">'));
    expect(read('scenes/BEAT BUILD.scex'), isNot(contains('name="dimmer" value="255"'))); // the dimmer stays at 200
    expect(lr, contains('<Channel index="5" name="color" value="10"/>')); // colors untouched
    expect(r.out, contains('CHANGED  BEAT LEFT RIGHT: left 2, right 2'));
    // nothing else in the file moved
    expect(lr.replaceAll('value="255"', 'value="0"'), _scene([(len: 48, on: {}, dim: 255), (len: 48, on: {}, dim: 255)]));
  });

  test('heads not hung: hidden in the 2D view, taken out of the 3D view, and back as they were when hung again', () {
    final before3d = read('3DView/fixtures.ini');
    rigLayoutApply(env(), [_ids[0], _ids[2]]);
    final two = read('Editor/2DView/fixtures.ini');
    expect(two, startsWith('\r\n[${_name(1)}]\r\nPosition = 786,0\r\n[${_name(2)}]\r\nPosition = 896,0\r\nHidden = 1\r\n'));
    expect(File(p.join(root, 'Editor/2DView/fixtures.ini')).readAsBytesSync().take(3), [0xEF, 0xBB, 0xBF]); // its byte order mark kept
    expect(two, contains('[${_name(4)}]\r\nPosition = 110,0\r\nHidden = 1\r\n[UPLIGHT]\r\nPosition = 439,640\r\n'));
    final three = read('3DView/fixtures.ini');
    expect(three, isNot(contains('[12]')));
    expect(three, isNot(contains('[14]')));
    expect(three, contains('[11]\r\nName = ${_name(1)}\r\nPosition = 6.04,9.00,-10.00\r\nOrientation = 0,81,0\r\n'));
    expect(three, contains('[99]\r\nName = UPLIGHT\r\nPosition = 0.44,0.00,0.00')); // not a mover: left alone
    // two heads, one each side
    expect(_lit(read('scenes/BEAT LEFT RIGHT.scex')), [
      {3},
      {1},
    ]);

    rigLayoutApply(env(), _ids);
    expect(read('Editor/2DView/fixtures.ini'), isNot(contains('Hidden')));
    final back = read('3DView/fixtures.ini');
    expect(back, contains('[12]\r\nName = ${_name(2)}\r\nPosition = 8.00,9.00,-10.00\r\nOrientation = 0,82,0\r\nObject = default'));
    expect(RegExp(r'^\[', multiLine: true).allMatches(back).length, RegExp(r'^\[', multiLine: true).allMatches(before3d).length);
    // every save starts from the full scene, so the heads left out last time are back in it
    expect(_lit(read('scenes/BEAT LEFT RIGHT.scex')), [
      {3, 4},
      {1, 2},
    ]);
  });

  test('saving the same again changes nothing', () {
    rigLayoutApply(env(), [_ids[0], _ids[2]]);
    final files = {
      for (final f in ['scenes/BEAT LEFT RIGHT.scex', 'Editor/2DView/fixtures.ini', '3DView/fixtures.ini', 'rig_layout.json']) f: read(f),
    };
    final r = rigLayoutApply(env(), [_ids[0], _ids[2]]);
    expect(r.out, contains('same     BEAT LEFT RIGHT'));
    expect(r.out, contains('2D view: already shows just the hung heads'));
    expect(r.out, contains('3D view: already matches'));
    for (final MapEntry(:key, :value) in files.entries) {
      expect(read(key), value, reason: key);
    }
  });

  test('a beat scene that is not two groups in turn is left as it is', () {
    final odd = _scene([
      (len: 48, on: {1}, dim: 255),
      (len: 48, on: {2}, dim: 255),
      (len: 48, on: {3}, dim: 255),
    ]);
    write('scenes/BEAT LEFT RIGHT.scex', odd);
    final r = rigLayoutApply(env(), _ids);
    expect(r.out, contains("left     BEAT LEFT RIGHT: it doesn't light two groups in turn"));
    expect(r.scenes, isNot(contains('BEAT LEFT RIGHT.scex')));
    expect(read('scenes/BEAT LEFT RIGHT.scex'), odd);
  });

  test('a scene changed in ShowXpress since counts as the full scene from then on', () {
    rigLayoutApply(env(), _ids);
    final mine = _scene([
      (len: 24, on: {1, 2}, dim: 255),
      (len: 24, on: {3, 4}, dim: 255),
    ]);
    write('scenes/BEAT LEFT RIGHT.scex', mine);
    final r = rigLayoutApply(env(), _ids);
    expect(r.out, contains('(changed in ShowXpress since last time'));
    expect(read('scenes/BEAT LEFT RIGHT.scex'), contains('<Step length="24">'));
  });

  test('with ShowXpress open nothing is written', () {
    open = true;
    final before = read('scenes/BEAT LEFT RIGHT.scex');
    expect(() => rigLayoutApply(env(), _ids), throwsA(isA<ToolError>()));
    expect(read('scenes/BEAT LEFT RIGHT.scex'), before);
    expect(File(p.join(root, 'rig_layout.json')).existsSync(), isFalse);
  });

  test("Tonight's Rig leaves the beat scenes the layout looks after alone", () {
    final r = rigLayoutApply(env(), [_ids[0], _ids[2]]);
    final fitted = read('scenes/BEAT BUILD.scex');
    final out = rigApply(env(), [_ids[0], _ids[2]], leave: r.scenes);
    expect(out, contains('chase scenes: 0'));
    expect(read('scenes/BEAT BUILD.scex'), fitted);
    expect(rigPreview(env(), leave: r.scenes).scenes, isEmpty);
    expect(rigPreview(env()).scenes.map((s) => s.file), contains('BEAT LEFT RIGHT.scex'));
  });
}
