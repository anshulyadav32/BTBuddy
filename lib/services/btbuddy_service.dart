import 'dart:async';
import 'package:flutter/services.dart';
import '../models/usb_device.dart';
import '../models/serial_event.dart';

class BTBuddyService {
  static const _method = MethodChannel('btbuddy/serial');
  static const _events = EventChannel('btbuddy/serial_events');

  final _devices = StreamController<List<UsbDevice>>.broadcast();
  final _eventsController = StreamController<SerialEvent>.broadcast();

  StreamSubscription? _nativeSubscription;
  List<UsbDevice> _currentDevices = const [];
  UsbDevice? selectedDevice;
  bool connected = false;
  String connectionPath = '';

  Stream<List<UsbDevice>> get devices => _devices.stream;
  Stream<SerialEvent> get serialEvents => _eventsController.stream;
  List<UsbDevice> get currentDevices => _currentDevices;

  BTBuddyService() {
    _nativeSubscription = _events.receiveBroadcastStream().listen(
      (event) {
        final map = Map<dynamic, dynamic>.from(event as Map);
        final type = '${map['type'] ?? 'rx'}';
        final data = '${map['data'] ?? ''}';
        if (type == 'connected') connected = true;
        if (type == 'disconnected') connected = false;
        _eventsController.add(SerialEvent(type: type, data: data));
      },
      onError: (Object error) {
        _eventsController.add(
          SerialEvent(type: 'error', data: error.toString()),
        );
      },
    );
  }

  Future<List<UsbDevice>> refreshDevices() async {
    final raw =
        await _method.invokeMethod<List<dynamic>>('listUsbDevices') ?? [];
    final uniqueByPath = <String, UsbDevice>{};
    for (final device in raw
        .map((e) => UsbDevice.fromMap(Map<dynamic, dynamic>.from(e as Map)))
        .where((d) => d.usb && d.path.isNotEmpty)) {
      uniqueByPath.putIfAbsent(device.path, () => device);
    }
    _currentDevices = uniqueByPath.values.toList();

    _currentDevices.sort((a, b) {
      int score(UsbDevice d) {
        final s =
            '${d.name} ${d.manufacturer} ${d.model} ${d.path}'.toLowerCase();
        if (s.contains('kechaoda')) return 0;
        if (s.contains('mediatek')) return 1;
        if (s.contains('usb')) return 2;
        return 3;
      }

      return score(a).compareTo(score(b));
    });

    final previouslySelectedPath = selectedDevice?.path;
    final matchingDevice = _currentDevices
        .where((device) => device.path == previouslySelectedPath);
    if (matchingDevice.isNotEmpty) {
      selectedDevice = matchingDevice.first;
    } else if (_currentDevices.isNotEmpty) {
      selectedDevice = _currentDevices.first;
    } else {
      selectedDevice = null;
    }

    _devices.add(_currentDevices);
    return _currentDevices;
  }

  Future<void> connect({int baud = 115200}) async {
    final device = selectedDevice;
    if (device == null) {
      throw StateError('Select a USB device first.');
    }
    await _method.invokeMethod('connect', {
      'path': device.path,
      'baud': baud,
    });
    connected = true;
    connectionPath = device.path;
  }

  Future<void> disconnect() async {
    await _method.invokeMethod('disconnect');
    connected = false;
    connectionPath = '';
  }

  Future<String> command(String command) async {
    final response = await _method.invokeMethod<String>(
      'command',
      {'command': command},
    );
    return response ?? '';
  }

  Future<String> dial(String number) => command('ATD${number.trim()};');

  Future<String> answer() => command('ATA');

  Future<String> hangup() => command('AT+CHUP');

  Future<String> callStatus() => command('AT+CLCC');

  Future<String> dtmf(String digit) => command('AT+VTS=$digit');

  Future<String> signalQuality() => command('AT+CSQ');

  Future<String> model() => command('AT+CGMM');

  Future<String> firmware() => command('AT+CGMR');

  Future<String> operatorName() => command('AT+COPS?');

  void dispose() {
    _nativeSubscription?.cancel();
    _devices.close();
    _eventsController.close();
  }
}
