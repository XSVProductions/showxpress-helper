import 'package:flutter/material.dart';
import 'package:sx_api/sx_api.dart';

import '../../app_state.dart';
import '../../theme.dart';
import '../../widgets/sx_widgets.dart';
import '../remote/remote_row.dart';
import '../rig/rig_widgets.dart';

/// Rig Test: which 140 hangs where tonight. RIG ID lights every 140 in its
/// own look, the user taps each truss spot and picks the look seen there, and
/// Save writes the spots to ShowXpress's 2D view.
class RtScreen extends StatefulWidget {
  const RtScreen(BuildContext _, {super.key});

  @override
  State<RtScreen> createState() => _RtScreenState();
}

class _RtScreenState extends State<RtScreen> with ShowWatcher, RigReloads {
  RtPreview? _data;
  var _error = '';

  /// Slot key to head id, saved or not.
  final _assign = <String, String>{};
  var _extra = false;

  /// Also update Tonight's Rig and SKIP FLASH when saving.
  var _rig = true;

  @override
  String get tabId => 'rt';

  @override
  void initState() {
    super.initState();
    load();
  }

  @override
  Future<void> load() async {
    final app = AppScope.read(context);
    try {
      final d = await app.client.rt();
      if (!mounted) return;
      setState(() {
        _data = d;
        _error = '';
        _reset(d);
      });
    } on ApiException catch (e) {
      if (!mounted) return;
      setState(() {
        _data = null;
        _error = e.message;
      });
    }
    app.setDirty(tabId, false);
  }

  void _reset(RtPreview d) {
    _assign
      ..clear()
      ..addAll(d.assign);
    _extra = d.extra;
  }

  @override
  bool get dirty {
    final d = _data;
    if (d == null) return false;
    final keys = {...d.assign.keys, ..._assign.keys};
    return _extra != d.extra || keys.any((k) => (d.assign[k] ?? '') != (_assign[k] ?? ''));
  }

  void _edit(VoidCallback f) {
    setState(f);
    AppScope.read(context).setDirty(tabId, dirty);
  }

  bool _used(RtPreview d, String key) => _extra || !d.slots.firstWhere((s) => s.key == key).extra;

  /// The spots that count: set, and not on a middle tower unless those are in use.
  Map<String, String> _placed(RtPreview d) => {
    for (final e in _assign.entries)
      if (e.value.isNotEmpty && _used(d, e.key)) e.key: e.value,
  };

  RtHead? _head(RtPreview d, String? id) => d.heads.where((h) => h.id == id).firstOrNull;

  String _hint(AppState app, RtPreview? d) {
    if (d == null) return '';
    if (app.sxOpen) return 'ShowXpress is open. A save waits until it closes (it rewrites the 2D view when it closes).';
    final n = _placed(d).length;
    if (n == 0) return 'Put at least one mover on a truss.';
    return '$n mover(s) on trusses. The 140 positions in the 2D view change${_rig ? ", plus Tonight's Rig and SKIP FLASH" : ''}. The BEAT scenes and the 3D view follow where the heads are.';
  }

  Future<void> _pick(RtPreview d, RtSlot slot) async {
    final cur = _assign[slot.key];
    final picked = await showDialog<String>(
      context: context,
      builder: (context) => _PickDialog(d: d, slot: slot, current: cur, assign: _assign, used: (k) => _used(d, k)),
    );
    if (picked == null) return;
    _edit(() {
      if (picked.isEmpty) {
        _assign.remove(slot.key);
      } else {
        _assign.removeWhere((_, v) => v == picked);
        _assign[slot.key] = picked;
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final app = AppScope.of(context);
    final d = _data;
    final placed = d == null ? const <String, String>{} : _placed(d);
    final b = TextStyle(color: Sx.text, fontWeight: FontWeight.w700);
    return ScreenBody(
      bar: SaveBar(
        hint: _hint(app, d),
        actions: [
          TextButton(onPressed: d != null && _assign.isNotEmpty ? () => _edit(_assign.clear) : null, child: const Text('New event')),
          TextButton(onPressed: d != null && dirty ? () => _edit(() => _reset(d)) : null, child: const Text('Undo')),
          FilledButton(
            onPressed: d != null && placed.isNotEmpty
                ? () => runSave(
                    context,
                    () => app.client.rtApply(placed, extra: _extra, rig: _rig),
                    what: 'rt',
                    busy: 'Saving the 2D view.',
                    after: () async {
                      await load();
                      app.showEdited();
                    },
                  )
                : null,
            child: const Text('Save to 2D view'),
          ),
        ],
      ),
      children: [
        SxCard(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              RigHeader(
                'Rig test: which mover is where',
                dirty: d == null ? null : dirty,
                onRefresh: load,
                subText: Text.rich(
                  TextSpan(
                    style: Sx.sub,
                    children: [
                      TextSpan(text: '1. ', style: b),
                      TextSpan(text: 'RIG ID', style: b),
                      const TextSpan(
                        text:
                            ' comes on in ShowXpress by itself (green bar below, or press it on the SETUP page). Every 140 lights in its own look (key below). ',
                      ),
                      TextSpan(text: '2. ', style: b),
                      const TextSpan(text: 'Tap each truss spot and pick the look you see on that head. '),
                      TextSpan(text: '3. ', style: b),
                      const TextSpan(text: 'Close ShowXpress (save first) and press '),
                      TextSpan(text: 'Save to 2D view', style: b),
                      const TextSpan(text: '.'),
                    ],
                  ),
                ),
              ),
              // The old `#rtrem`, under the header (`margin: 12px 0 0`).
              const RemoteRow(
                tab: 'rt',
                margin: EdgeInsets.only(top: 12),
                sets: [
                  RemoteSet('RIG ID', ['RIG ID']),
                ],
              ),
              ErrorBox(_error),
              if (d == null && _error.isEmpty)
                Padding(
                  padding: const EdgeInsets.only(top: 14),
                  child: Text('Reading the show.', style: Sx.sub),
                ),
              if (d != null) ...[
                _install(d, b),
                const SizedBox(height: 12),
                HeadGrid(gap: 6, children: [for (final h in d.heads) _LegendTile(h)]),
                const SizedBox(height: 14),
                _map(d, placed),
                const SizedBox(height: 12),
                Wrap(
                  alignment: WrapAlignment.spaceBetween,
                  runSpacing: 6,
                  spacing: 12,
                  children: [
                    _Check('Bigger event: 2 extra towers (top middle and bottom middle)', _extra, (v) => _edit(() => _extra = v)),
                    _Check("Also update Tonight's Rig and Strobe (heads not on a truss = not hung)", _rig, (v) => setState(() => _rig = v)),
                  ],
                ),
                if (d.saved case final s? when s.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(top: 10),
                    child: Text('Rig Test last saved ${s.replaceFirst('T', ' ')}', style: Sx.sub),
                  ),
              ],
            ],
          ),
        ),
      ],
    );
  }

  /// The old `#rtinst` warning box: RIG ID missing or out of date, with the button that fixes it.
  Widget _install(RtPreview d, TextStyle b) {
    final i = d.install;
    final String before, after, button;
    if (!i.scene || !i.button) {
      (before, after, button) = ('The ', " button isn't in the show yet.", 'Add RIG ID to the SETUP page');
    } else if (i.old) {
      (before, after, button) = ('The ', ' scene in the show is the old one (amber instead of light green, no visible flash).', 'Update RIG ID');
    } else {
      return const SizedBox.shrink();
    }
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.only(top: 12),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: Sx.tint(Sx.red),
      child: Wrap(
        spacing: 8,
        runSpacing: 8,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          Text.rich(
            TextSpan(
              style: TextStyle(color: Sx.redText, fontSize: 13),
              children: [
                TextSpan(text: before),
                const TextSpan(
                  text: 'RIG ID',
                  style: TextStyle(fontWeight: FontWeight.w700),
                ),
                TextSpan(text: after),
              ],
            ),
          ),
          MiniButton(
            button,
            primary: true,
            onPressed: () => runSave(
              context,
              () => AppScope.read(context).client.rtInstall(),
              what: 'install',
              busy: i.scene && i.button ? 'Updating RIG ID.' : 'Adding RIG ID.',
              after: load,
            ),
          ),
        ],
      ),
    );
  }

  /// The truss plan, the old app's `.rtmap`: three towers over the spare
  /// heads, three under, and the DJ booth at the bottom.
  Widget _map(RtPreview d, Map<String, String> placed) {
    final phone = MediaQuery.sizeOf(context).width <= 640;
    final gap = phone ? 6.0 : 12.0;
    Widget tower(String key) {
      final slots = d.slots.where((s) => s.tower == key).toList();
      final t = Container(
        padding: phone ? const EdgeInsets.all(6) : const EdgeInsets.fromLTRB(10, 8, 10, 10),
        decoration: BoxDecoration(
          color: Sx.panel,
          border: Border.all(color: Sx.line),
          borderRadius: BorderRadius.circular(12),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('${slots.first.towerName} tower'.toUpperCase(), style: Sx.label),
            const SizedBox(height: 6),
            IntrinsicHeight(
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  for (final (i, s) in slots.indexed) ...[
                    if (i > 0) SizedBox(width: phone ? 4 : 6),
                    Expanded(
                      child: _SlotTile(
                        slot: s,
                        head: _head(d, _assign[s.key]),
                        changed: (d.assign[s.key] ?? '') != (_assign[s.key] ?? ''),
                        onTap: () => _pick(d, s),
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ],
        ),
      );
      return Expanded(
        child: slots.first.extra && !_extra ? Visibility(visible: false, maintainSize: true, maintainAnimation: true, maintainState: true, child: t) : t,
      );
    }

    Widget row(List<String> keys) => Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (final (i, k) in keys.indexed) ...[if (i > 0) SizedBox(width: gap), tower(k)],
      ],
    );

    final spare = d.heads.where((h) => !placed.containsValue(h.id)).toList();
    return Container(
      padding: EdgeInsets.all(phone ? 8 : 14),
      decoration: BoxDecoration(
        color: Sx.well,
        border: Border.all(color: Sx.line),
        borderRadius: BorderRadius.circular(14),
      ),
      child: Column(
        children: [
          row(['tl', 'tm', 'tr']),
          SizedBox(height: gap),
          DashedBox(
            color: Sx.line,
            radius: 12,
            padding: const EdgeInsets.all(10),
            child: SizedBox(
              width: double.infinity,
              child: Column(
                children: [
                  Text(
                    spare.isEmpty ? 'Every 140 is on a truss' : 'Not on a truss, grouped in the middle of the 2D page',
                    style: TextStyle(color: Sx.dim, fontSize: 12),
                    textAlign: TextAlign.center,
                  ),
                  if (spare.isNotEmpty) ...[
                    const SizedBox(height: 6),
                    Wrap(
                      spacing: 4,
                      runSpacing: 4,
                      alignment: WrapAlignment.center,
                      children: [
                        for (final h in spare)
                          Container(
                            padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
                            decoration: BoxDecoration(
                              color: Sx.panel,
                              border: Border.all(color: Sx.line),
                              borderRadius: BorderRadius.circular(6),
                            ),
                            child: Text('#${h.num}', style: TextStyle(color: Sx.text, fontSize: 12)),
                          ),
                      ],
                    ),
                  ],
                ],
              ),
            ),
          ),
          SizedBox(height: gap),
          row(['bl', 'bm', 'br']),
          SizedBox(height: gap),
          Container(
            width: double.infinity,
            padding: const EdgeInsets.only(top: 6),
            decoration: BoxDecoration(
              border: Border(top: BorderSide(color: Sx.accent.withValues(alpha: .5), width: 2)),
            ),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(Icons.arrow_drop_up, size: 18, color: Sx.accent),
                Text(
                  'DJ BOOTH (you)',
                  style: TextStyle(color: Sx.accent, fontSize: 12, fontWeight: FontWeight.w600, letterSpacing: 1),
                ),
                Icon(Icons.arrow_drop_up, size: 18, color: Sx.accent),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// A head's look, the old app's `.dot`: a circle in the head's RIG ID color.
/// The old page blinked it for a flashing look. This app never animates, so
/// the word "flashing" next to it carries that.
class _Dot extends StatelessWidget {
  const _Dot(this.h);

  final RtHead h;

  @override
  Widget build(BuildContext context) => Container(
    width: 18,
    height: 18,
    margin: const EdgeInsets.only(right: 5),
    decoration: BoxDecoration(
      // The head's real color from the scene, not a theme color.
      color: Color(0xFF000000 | (int.tryParse(h.hex, radix: 16) ?? 0)),
      shape: BoxShape.circle,
      border: Border.all(color: Sx.text.withValues(alpha: .25), width: 2),
    ),
  );
}

/// One entry of the key, the old app's `.legend2 div`: dot, number, look.
class _LegendTile extends StatelessWidget {
  const _LegendTile(this.h);

  final RtHead h;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 5),
    decoration: BoxDecoration(
      color: Sx.panel,
      border: Border.all(color: Sx.line),
      borderRadius: BorderRadius.circular(8),
    ),
    child: Column(
      children: [
        Padding(padding: const EdgeInsets.only(left: 5), child: _Dot(h)),
        Text(
          '#${h.num}',
          style: TextStyle(fontWeight: FontWeight.w700, fontSize: 13, color: Sx.text),
        ),
        Text(
          h.flash ? '${h.look} flashing' : h.look,
          style: TextStyle(fontSize: 11.5, color: Sx.text),
          textAlign: TextAlign.center,
          maxLines: 2,
        ),
      ],
    ),
  );
}

/// One mover spot on a tower, the old app's `.slot`: dashed when empty,
/// solid once a head is picked, an inner blue line when not saved yet.
class _SlotTile extends StatelessWidget {
  const _SlotTile({required this.slot, required this.head, required this.changed, required this.onTap});

  final RtSlot slot;
  final RtHead? head;
  final bool changed;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final h = head;
    final phone = MediaQuery.sizeOf(context).width <= 640;
    final body = Container(
      constraints: BoxConstraints(minHeight: phone ? 58 : 64),
      padding: phone ? const EdgeInsets.symmetric(horizontal: 2, vertical: 5) : const EdgeInsets.symmetric(horizontal: 5, vertical: 7),
      decoration: changed
          ? BoxDecoration(
              border: Border.all(color: Sx.blue),
              borderRadius: BorderRadius.circular(9),
            )
          : null,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            '${slot.side} mover',
            style: TextStyle(color: Sx.mute, fontSize: 10.5),
            textAlign: TextAlign.center,
          ),
          if (h == null)
            Text(
              'tap to set',
              style: TextStyle(color: Sx.dim, fontSize: 11),
              textAlign: TextAlign.center,
            )
          else ...[
            Wrap(
              alignment: WrapAlignment.center,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                _Dot(h),
                Text(
                  '#${h.num}',
                  style: TextStyle(fontSize: phone ? 14 : 15, fontWeight: FontWeight.w700, color: Sx.text),
                ),
              ],
            ),
            Text(
              h.flash ? '${h.look} flashing' : h.look,
              style: TextStyle(color: Sx.dim, fontSize: 11),
              textAlign: TextAlign.center,
            ),
          ],
        ],
      ),
    );
    return Semantics(
      button: true,
      label: '${slot.towerName} tower, ${slot.side} mover',
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(10),
        child: h == null
            ? DashedBox(color: Sx.line2, radius: 10, fill: Sx.well, padding: const EdgeInsets.all(1), child: body)
            : Container(
                decoration: BoxDecoration(
                  color: Sx.well,
                  border: Border.all(color: Sx.line2),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: body,
              ),
      ),
    );
  }
}

/// "Pick the look you see on this head." Pops the head's id, '' for
/// nothing hung here, or null for cancel.
class _PickDialog extends StatelessWidget {
  const _PickDialog({required this.d, required this.slot, required this.current, required this.assign, required this.used});

  final RtPreview d;
  final RtSlot slot;
  final String? current;
  final Map<String, String> assign;
  final bool Function(String key) used;

  /// Where a head sits now, if somewhere else ("now top right left").
  String _where(String id) {
    final e = assign.entries.where((e) => e.value == id && e.key != slot.key && used(e.key)).firstOrNull;
    if (e == null) return '';
    final o = d.slots.firstWhere((s) => s.key == e.key);
    return 'now ${o.towerName.toLowerCase()} ${o.side}';
  }

  @override
  Widget build(BuildContext context) {
    final phone = MediaQuery.sizeOf(context).width <= 640;
    Widget grid(bool flash) => Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: HeadGrid(
        wideCols: phone ? 2 : 4,
        narrowCols: phone ? 2 : 4,
        gap: 6,
        children: [
          for (final h in d.heads.where((h) => h.flash == flash))
            InkWell(
              onTap: () => Navigator.pop(context, h.id),
              borderRadius: BorderRadius.circular(9),
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 7),
                decoration: BoxDecoration(
                  color: h.id == current ? Sx.accent.withValues(alpha: .08) : Sx.panel,
                  border: Border.all(color: h.id == current ? Sx.accent : Sx.line),
                  borderRadius: BorderRadius.circular(9),
                ),
                child: Column(
                  children: [
                    Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        _Dot(h),
                        Text('#${h.num}', style: TextStyle(fontSize: 12, color: Sx.text)),
                      ],
                    ),
                    Text(
                      h.look,
                      style: TextStyle(color: Sx.mute, fontSize: 10.5),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    Text(
                      _where(h.id),
                      style: TextStyle(color: Sx.mute, fontSize: 10.5),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ],
                ),
              ),
            ),
        ],
      ),
    );

    return AlertDialog(
      title: Text('${slot.towerName} tower, ${slot.side} mover', style: Sx.title),
      content: SizedBox(
        width: 540,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('Pick the look you see on this head.', style: Sx.sub),
              const GroupLabel('Solid'),
              grid(false),
              const GroupLabel('Flashing'),
              grid(true),
            ],
          ),
        ),
      ),
      actions: [
        OutlinedButton(onPressed: () => Navigator.pop(context, ''), child: const Text('Nothing hung here')),
        OutlinedButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
      ],
    );
  }
}

/// A ticked option under the map, the old app's `label.link`.
class _Check extends StatelessWidget {
  const _Check(this.text, this.value, this.onChanged);

  final String text;
  final bool value;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) => InkWell(
    onTap: () => onChanged(!value),
    child: Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        SizedBox(
          width: 18,
          height: 18,
          child: Checkbox(value: value, onChanged: (v) => onChanged(v ?? false), materialTapTargetSize: MaterialTapTargetSize.shrinkWrap),
        ),
        const SizedBox(width: 8),
        Flexible(
          child: Text(text, style: TextStyle(color: Sx.dim, fontSize: 13)),
        ),
      ],
    ),
  );
}
