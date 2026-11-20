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

  TvState _state = TvState.listening;
  String _address = _noNetwork;
  String _pin = '';
  StreamSubscription<ReceiverStatus>? _sub;
  Timer? _timer;

  TvState get state => _state;
  String get address => _address;
  String get pin => _pin;

  Future<void> init() async {
    _sub = source.status.listen((s) {
      if (s.state == _state) return;
      _state = s.state;
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
