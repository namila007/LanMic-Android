import 'package:lanmic/domain/phone_state.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Last TV address, talk mode and mic boost. Never the PIN.
class PrefsStore {
  Future<({String? ip, TalkMode mode, int micBoostDb})> load() async {
    final p = await SharedPreferences.getInstance();
    return (
      ip: p.getString('ip'),
      mode: p.getString('mode') == 'keep' ? TalkMode.keep : TalkMode.hold,
      micBoostDb: p.getInt('micBoostDb') ?? 0,
    );
  }

  Future<void> save({String? ip, TalkMode? mode, int? micBoostDb}) async {
    final p = await SharedPreferences.getInstance();
    if (ip != null) await p.setString('ip', ip);
    if (mode != null) await p.setString('mode', mode.name);
    if (micBoostDb != null) await p.setInt('micBoostDb', micBoostDb);
  }
}
