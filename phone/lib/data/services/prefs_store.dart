import 'package:lanmic/domain/phone_state.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Last TV address and talk mode. Never the PIN.
class PrefsStore {
  Future<({String? ip, TalkMode mode})> load() async {
    final p = await SharedPreferences.getInstance();
    return (
      ip: p.getString('ip'),
      mode: p.getString('mode') == 'keep' ? TalkMode.keep : TalkMode.hold,
    );
  }

  Future<void> save({String? ip, TalkMode? mode}) async {
    final p = await SharedPreferences.getInstance();
    if (ip != null) await p.setString('ip', ip);
    if (mode != null) await p.setString('mode', mode.name);
  }
}
