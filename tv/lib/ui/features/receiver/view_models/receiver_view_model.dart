import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../../../data/services/network_info_service.dart';
import '../../../../data/services/pin_store.dart';
import '../../../../domain/receiver_status.dart';

const _noNetwork = 'No network';

class ReceiverViewModel extends ChangeNotifier {
  ReceiverViewModel({
    required this.source,
    required this.net,
    required this.pins,
    this.stopService,
  });

  final ReceiverStatusSource source;
  final NetworkInfoService net;
  final PinStore pins;

  /// Stops the background receiver (UDP 5004 + audio). Home/Back leave it running.
  final Future<void> Function()? stopService;

  Future<void> exit() async => stopService?.call();

  ReceiverStatus _status = const ReceiverStatus(TvState.listening);
  String _address = _noNetwork;
  String _pin = '';
  StreamSubscription<ReceiverStatus>? _sub;
  Timer? _timer;

  ReceiverStatus get status => _status;
  TvState get state => _status.state;
  String get address => _address;
  String get pin => _pin;

  Future<void> init() async {
    _sub = source.status.listen((s) {
      final old = _status;
      _status = s;
      // Counters (rx, dropped, underruns) are not shown: skip the rebuild for them.
      if (s.state == old.state &&
          s.rttMs == old.rttMs &&
          s.delayMs == old.delayMs &&
          s.tvDelayMs == old.tvDelayMs &&
          s.lostPermille == old.lostPermille &&
          s.band == old.band) {
        return;
      }
      notifyListeners();
    });
    _pin = (await pins.load()).toString();
    _address = await net.localIpv4() ?? _noNetwork;
    _timer = Timer.periodic(
      const Duration(seconds: 5),
      (_) => _refreshAddress(),
    );
    notifyListeners();
  }

  Future<void> _refreshAddress() async {
    final a = await net.localIpv4() ?? _noNetwork;
    if (a == _address) return;
    _address = a;
    notifyListeners();
  }

  @override
  void dispose() {
    _sub?.cancel();
    _timer?.cancel();
    super.dispose();
  }
}
