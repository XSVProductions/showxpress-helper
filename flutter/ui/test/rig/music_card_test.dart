import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sx_api/sx_api.dart';
import 'package:sx_studio/screens/skip/music_card.dart';

import 'harness.dart';

FakeEngine _engine(MusicStatus status) => FakeEngine({
  '/api/music': MusicInfo(
    settings: const MusicSettings(device: 'CABLE Output'),
    status: status,
    devices: const ['CABLE Output'],
    canListen: true,
    os2lOn: true,
    os2lPort: 7350,
    missing: const [],
  ).toJson(),
  '/api/music/status': {'ok': true, 'status': status.toJson()},
});

void main() {
  testWidgets('Record asks the engine to record what the detector hears', (tester) async {
    final e = _engine(const MusicStatus());
    final app = await pumpScreen(tester, e, 'skip', (_) => const MusicCard());
    await tap(tester, find.text('Record'));
    expect(e.posts.single.path, '/api/music/record');
    expect(e.posts.single.body, {'on': true});
    await finish(tester, app);
  });

  testWidgets('while recording it shows where and how long, and Stop recording stops it', (tester) async {
    final e = _engine(const MusicStatus(running: true, device: 'CABLE Output', section: 'GROOVE', recording: r'C:\Music\SX recording 1.wav', recordedS: 3725));
    final app = await pumpScreen(tester, e, 'skip', (_) => const MusicCard());
    expect(find.textContaining(r'Recording 1:02:05 to C:\Music\SX recording 1.wav'), findsOneWidget);
    await tap(tester, find.text('Stop recording'));
    expect(e.posts.single.path, '/api/music/record');
    expect(e.posts.single.body, {'on': false});
    await finish(tester, app);
  });
}
