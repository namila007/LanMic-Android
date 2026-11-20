import 'package:flutter_test/flutter_test.dart';
import 'package:lanmic_tv/domain/loss_meter.dart';

final t0 = DateTime.utc(2026, 1, 1);
DateTime at(int ms) => t0.add(Duration(milliseconds: ms));

void main() {
  test('an empty window is unknown', () {
    expect(LossMeter().lostPermille(t0), isNull);
  });

  test('lost slots over all slots, in permille', () {
    final m = LossMeter();
    for (var i = 0; i < 997; i++) {
      m.played(at(i), lost: false);
    }
    for (var i = 0; i < 3; i++) {
      m.played(at(i), lost: true);
    }
    expect(m.lostPermille(at(999)), 3);
  });

  test('discarded frames count as lost and as slots', () {
    final m = LossMeter();
    for (var i = 0; i < 98; i++) {
      m.played(at(0), lost: false);
    }
    m.discarded(at(0), 2);
    expect(m.lostPermille(at(0)), 20);
  });

  test('only the last 10 s count', () {
    final m = LossMeter()
      ..played(at(0), lost: true)
      ..played(at(10500), lost: false);
    expect(m.lostPermille(at(10500)), 0);
    expect(m.lostPermille(at(30000)), isNull);
  });

  test('clear empties the window', () {
    final m = LossMeter()
      ..played(at(0), lost: true)
      ..clear();
    expect(m.lostPermille(at(0)), isNull);
  });
}
