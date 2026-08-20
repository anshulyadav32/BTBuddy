import 'dart:async';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../models/usb_device.dart';
import '../models/serial_event.dart';
import '../models/ussd_session.dart';
import '../models/bluetooth_device_item.dart';
import '../models/bt_notification.dart';

class BTBuddyService {
  static const _method = MethodChannel('btbuddy/serial');
  static const _events = EventChannel('btbuddy/serial_events');

  // Controllers
  final _devices = StreamController<List<UsbDevice>>.broadcast();
  final _btDevices = StreamController<List<BluetoothDeviceItem>>.broadcast();
  final _eventsController = StreamController<SerialEvent>.broadcast();
  final _ussdController = StreamController<UssdSession>.broadcast();
  final _notificationController = StreamController<BtNotification>.broadcast();

  StreamSubscription? _nativeSubscription;
  Timer? _heartbeatTimer;

  // Devices & State
  List<UsbDevice> _currentDevices = const [];
  List<BluetoothDeviceItem> _currentBtDevices = const [];
  UsbDevice? selectedDevice;
  bool connected = false;
  String connectionPath = '';
  String? _lastConnectedPath;

  // 2-Way Telemetry
  int txBytes = 0;
  int rxBytes = 0;
  int txPackets = 0;
  int rxPackets = 0;
  int pingMs = 0;
  DateTime? lastHeartbeat;

  // USSD State
  final List<UssdSession> ussdHistory = [];
  UssdSession? activeUssdSession;

  // Notifications State
  final List<BtNotification> notificationHistory = [];
  bool forwardMacNotifications = true;
  bool soundAlerts = true;

  // Settings
  bool autoConnect = true;
  final Set<String> _autoAttemptedThisSession = {};
  bool preferKechaoda = true;

  static const _prefsAuto = 'btbuddy.auto_connect';
  static const _prefsLastPath = 'btbuddy.last_connected_path';
  static const _prefsPreferKechaoda = 'btbuddy.prefer_kechaoda';
  static const _prefsForwardNotifs = 'btbuddy.forward_notifs';

  // Streams
  Stream<List<UsbDevice>> get devices => _devices.stream;
  Stream<List<BluetoothDeviceItem>> get bluetoothDevices => _btDevices.stream;
  Stream<SerialEvent> get serialEvents => _eventsController.stream;
  Stream<UssdSession> get ussdStream => _ussdController.stream;
  Stream<BtNotification> get notificationStream => _notificationController.stream;

  List<UsbDevice> get currentDevices => List.unmodifiable(_currentDevices);
  List<BluetoothDeviceItem> get currentBtDevices => List.unmodifiable(_currentBtDevices);
  String? get lastConnectedPath => _lastConnectedPath;

  BTBuddyService() {
    _nativeSubscription = _events.receiveBroadcastStream().listen(
      (event) {
        final map = Map<dynamic, dynamic>.from(event as Map);
        final type = '${map['type'] ?? 'rx'}';
        final data = '${map['data'] ?? ''}';

        // Update telemetry if present
        if (map['txBytes'] != null) txBytes = int.tryParse('${map['txBytes']}') ?? txBytes;
        if (map['rxBytes'] != null) rxBytes = int.tryParse('${map['rxBytes']}') ?? rxBytes;
        if (map['txPackets'] != null) txPackets = int.tryParse('${map['txPackets']}') ?? txPackets;
        if (map['rxPackets'] != null) rxPackets = int.tryParse('${map['rxPackets']}') ?? rxPackets;

        if (type == 'connected') {
          connected = true;
          _startHeartbeat();
        }
        if (type == 'disconnected') {
          connected = false;
          _stopHeartbeat();
        }

        // Handle Unsolicited Result Codes (URC)
        _handleUnsolicitedEvents(type, data, map);

        _eventsController.add(SerialEvent(type: type, data: data));
      },
      onError: (Object error) {
        _eventsController.add(
          SerialEvent(type: 'error', data: error.toString()),
        );
      },
    );
    _loadPreferences();
  }

  void _handleUnsolicitedEvents(String type, String data, Map<dynamic, dynamic> map) {
    if (type == 'incoming_call' || data == 'RING') {
      final notif = BtNotification.phoneIncomingCall(callerNumber: 'Incoming Call (Ringing)...');
      _addNotification(notif);
      showMacNotification(title: 'Incoming Phone Call', body: 'Your mobile phone is ringing!').ignore();
    } else if (type == 'incoming_clip') {
      final number = data.isNotEmpty ? data : 'Unknown Number';
      final notif = BtNotification.phoneIncomingCall(callerNumber: number);
      _addNotification(notif);
      showMacNotification(title: 'Incoming Call', body: 'Caller: $number').ignore();
    } else if (type == 'incoming_sms') {
      final index = data;
      final notif = BtNotification.phoneIncomingSms(
        sender: 'SIM Message #$index',
        message: 'New incoming SMS received on phone.',
      );
      _addNotification(notif);
      showMacNotification(title: 'New SMS Received', body: 'SIM Message received on connected phone.').ignore();
    } else if (type == 'ussd_event' || (data.contains('+CUSD:') && type != 'tx')) {
      final session = UssdSession.parse(data, query: activeUssdSession?.query ?? 'USSD');
      activeUssdSession = session.isInteractive ? session : null;
      ussdHistory.insert(0, session);
      _ussdController.add(session);
    }
  }

  void _addNotification(BtNotification notif) {
    notificationHistory.insert(0, notif);
    _notificationController.add(notif);
  }

  /// Simulate incoming phone call for 2-way testing
  void simulateIncomingCall({String number = '+1 (555) 234-5678', String? name = 'John Doe'}) {
    final notif = BtNotification.phoneIncomingCall(callerNumber: number, callerName: name);
    _addNotification(notif);
    _emit('incoming_clip', number);
    showMacNotification(title: 'Incoming Call: ${name ?? number}', body: number).ignore();
  }

  /// Simulate incoming SMS message for 2-way testing
  void simulateIncomingSms({String sender = '+1 (555) 987-6543', String message = 'Hello from BTBuddy! 2-way link active.'}) {
    final notif = BtNotification.phoneIncomingSms(sender: sender, message: message);
    _addNotification(notif);
    _emit('incoming_sms', sender);
    showMacNotification(title: 'SMS from $sender', body: message).ignore();
  }

  /// Simulate low phone battery warning
  void simulatePhoneBatteryWarning({int level = 12}) {
    final notif = BtNotification.phoneBatteryWarning(level: level);
    _addNotification(notif);
    showMacNotification(title: 'Low Phone Battery ($level%)', body: 'Please plug in phone charger.').ignore();
  }

  Future<void> _loadPreferences() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      autoConnect = prefs.getBool(_prefsAuto) ?? true;
      preferKechaoda = prefs.getBool(_prefsPreferKechaoda) ?? true;
      forwardMacNotifications = prefs.getBool(_prefsForwardNotifs) ?? true;
      _lastConnectedPath = prefs.getString(_prefsLastPath);
      if (_lastConnectedPath != null && _lastConnectedPath!.isNotEmpty) {
        _emit('info', 'Remembered last device: $_lastConnectedPath');
      }
    } catch (e) {
      _emit('info', 'Preferences init note: $e');
    }
  }

  Future<void> setAutoConnect(bool value) async {
    autoConnect = value;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(_prefsAuto, value);
    } catch (_) {}
    _emit('info', 'Auto-connect ${value ? 'enabled' : 'disabled'}.');
  }

  Future<void> setPreferKechaoda(bool value) async {
    preferKechaoda = value;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(_prefsPreferKechaoda, value);
    } catch (_) {}
  }

  Future<void> setForwardMacNotifications(bool value) async {
    forwardMacNotifications = value;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(_prefsForwardNotifs, value);
    } catch (_) {}
  }

  Future<void> _rememberLastConnected(String path) async {
    _lastConnectedPath = path;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_prefsLastPath, path);
    } catch (_) {}
  }

  void _emit(String type, String data) {
    _eventsController.add(SerialEvent(type: type, data: data));
  }

  // -------------------------------------------------------------
  // 2-WAY HEARTBEAT & TELEMETRY
  // -------------------------------------------------------------
  void _startHeartbeat() {
    _heartbeatTimer?.cancel();
    _heartbeatTimer = Timer.periodic(const Duration(seconds: 4), (_) async {
      if (!connected) return;
      final stopwatch = Stopwatch()..start();
      try {
        await command('AT+CSQ');
        stopwatch.stop();
        pingMs = stopwatch.elapsedMilliseconds;
        lastHeartbeat = DateTime.now();
      } catch (_) {}
    });
  }

  void _stopHeartbeat() {
    _heartbeatTimer?.cancel();
    _heartbeatTimer = null;
  }

  // -------------------------------------------------------------
  // DEVICE DISCOVERY & SERIAL CONNECTION
  // -------------------------------------------------------------
  UsbDevice? _findPreferredDevice(List<UsbDevice> candidates) {
    if (candidates.isEmpty) return null;
    final remembered = _lastConnectedPath;
    if (remembered != null && remembered.isNotEmpty) {
      final match = candidates.where((d) => d.path == remembered);
      if (match.isNotEmpty) return match.first;
    }
    if (preferKechaoda) {
      final kech = candidates.where((d) {
        final s = '${d.name} ${d.manufacturer} ${d.model} ${d.path}'.toLowerCase();
        return s.contains('kechaoda');
      });
      if (kech.isNotEmpty) return kech.first;
    }
    final med = candidates.where((d) {
      final s = '${d.name} ${d.manufacturer} ${d.model} ${d.path}'.toLowerCase();
      return s.contains('mediatek');
    });
    if (med.isNotEmpty) return med.first;
    if (selectedDevice != null) {
      final stillThere = candidates.where((d) => d.path == selectedDevice!.path);
      if (stillThere.isNotEmpty) return stillThere.first;
    }
    return candidates.first;
  }

  Future<List<UsbDevice>> refreshDevices() async {
    final raw = await _method.invokeMethod<List<dynamic>>('listUsbDevices') ?? [];
    final uniqueByPath = <String, UsbDevice>{};
    for (final device in raw
        .map((e) => UsbDevice.fromMap(Map<dynamic, dynamic>.from(e as Map)))
        .where((d) => d.path.isNotEmpty)) {
      uniqueByPath.putIfAbsent(device.path, () => device);
    }
    final fresh = uniqueByPath.values.toList();

    fresh.sort((a, b) {
      int score(UsbDevice d) {
        final s = '${d.name} ${d.manufacturer} ${d.model} ${d.path}'.toLowerCase();
        final typeBase = d.usb ? 0 : 100;
        if (_lastConnectedPath != null && d.path == _lastConnectedPath) {
          return typeBase;
        }
        if (preferKechaoda && s.contains('kechaoda')) return typeBase + 1;
        if (s.contains('mediatek')) return typeBase + 2;
        if (s.contains('usbmodem')) return typeBase + 3;
        if (s.contains('usb')) return typeBase + 4;
        return typeBase + 5;
      }

      return score(a).compareTo(score(b));
    });

    _currentDevices = fresh;

    final prevSelectedPath = selectedDevice?.path;
    final matchingPrev = _currentDevices.where((device) => device.path == prevSelectedPath);
    final preferred = _findPreferredDevice(_currentDevices);
    if (matchingPrev.isNotEmpty) {
      selectedDevice = matchingPrev.first;
    } else if (preferred != null) {
      selectedDevice = preferred;
    } else {
      selectedDevice = null;
    }

    _devices.add(_currentDevices);
    return _currentDevices;
  }

  bool shouldAutoConnectNow() {
    final device = selectedDevice;
    if (!autoConnect || connected || device == null) return false;
    if (_lastConnectedPath != null && device.path == _lastConnectedPath) {
      return true;
    }
    final s = '${device.name} ${device.manufacturer} ${device.model} ${device.path}'.toLowerCase();
    if (preferKechaoda && s.contains('kechaoda')) return true;
    if (s.contains('mediatek')) return true;
    return _autoAttemptedThisSession.add(device.path);
  }

  bool get connectionLost =>
      !connected &&
      connectionPath.isNotEmpty &&
      !_currentDevices.any((d) => d.path == connectionPath);

  Future<void> connectTo(UsbDevice device, {int baud = 115200}) async {
    selectedDevice = device;
    _emit('info', 'Connecting to ${device.name} (${device.path}) at $baud baud…');
    await _method.invokeMethod('connect', {
      'path': device.path,
      'baud': baud,
    });
    connected = true;
    connectionPath = device.path;
    _rememberLastConnected(device.path).ignore();
    _autoAttemptedThisSession.add(device.path);
    _startHeartbeat();
  }

  Future<void> connect({int baud = 115200}) async {
    final device = selectedDevice;
    if (device == null) {
      throw StateError('Select a serial device first.');
    }
    await connectTo(device, baud: baud);
  }

  Future<void> disconnect() async {
    _stopHeartbeat();
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

  // -------------------------------------------------------------
  // NATIVE BLUETOOTH MANAGEMENT & EJECT
  // -------------------------------------------------------------
  Future<List<BluetoothDeviceItem>> refreshBluetoothDevices() async {
    final raw = await _method.invokeMethod<List<dynamic>>('listBluetoothDevices') ?? [];
    final list = raw
        .map((e) => BluetoothDeviceItem.fromMap(Map<dynamic, dynamic>.from(e as Map)))
        .toList();
    _currentBtDevices = list;
    _btDevices.add(list);
    return list;
  }

  Future<bool> connectNativeBluetooth(String address) async {
    _emit('info', 'Connecting to Bluetooth device: $address…');
    final res = await _method.invokeMethod<bool>('connectBluetoothDevice', {'address': address});
    await refreshBluetoothDevices();
    return res ?? false;
  }

  Future<bool> disconnectNativeBluetooth(String address) async {
    _emit('info', 'Disconnecting Bluetooth device: $address…');
    final res = await _method.invokeMethod<bool>('disconnectBluetoothDevice', {'address': address});
    await refreshBluetoothDevices();
    return res ?? false;
  }

  Future<bool> ejectNativeBluetooth(String address) async {
    _emit('info', 'Ejecting / Unpairing Bluetooth device: $address…');
    final res = await _method.invokeMethod<bool>('ejectBluetoothDevice', {'address': address});
    await refreshBluetoothDevices();
    _emit('info', res == true ? 'Device $address successfully ejected.' : 'Could not eject $address.');
    return res ?? false;
  }

  // -------------------------------------------------------------
  // USSD SYSTEM (AT+CUSD)
  // -------------------------------------------------------------
  Future<UssdSession> sendUssd(String code) async {
    final cleanCode = code.trim();
    _emit('tx', 'AT+CUSD=1,"$cleanCode",15');
    final raw = await _method.invokeMethod<String>('sendUssd', {'code': cleanCode}) ?? '';
    _emit('rx', raw);

    final session = UssdSession.parse(raw, query: cleanCode);
    activeUssdSession = session.isInteractive ? session : null;
    ussdHistory.insert(0, session);
    _ussdController.add(session);
    return session;
  }

  Future<UssdSession> replyUssd(String reply) async {
    final cleanReply = reply.trim();
    _emit('tx', 'AT+CUSD=1,"$cleanReply",15');
    final raw = await _method.invokeMethod<String>('sendUssd', {'code': cleanReply}) ?? '';
    _emit('rx', raw);

    final session = UssdSession.parse(raw, query: 'Reply: $cleanReply');
    activeUssdSession = session.isInteractive ? session : null;
    ussdHistory.insert(0, session);
    _ussdController.add(session);
    return session;
  }

  Future<String> cancelUssd() async {
    _emit('tx', 'AT+CUSD=2');
    final raw = await _method.invokeMethod<String>('cancelUssd') ?? '';
    _emit('rx', raw);
    activeUssdSession = null;
    return raw;
  }

  // -------------------------------------------------------------
  // BT NOTIFIER & 2-WAY NOTIFICATIONS
  // -------------------------------------------------------------
  Future<void> showMacNotification({required String title, required String body}) async {
    try {
      await _method.invokeMethod('showNativeNotification', {
        'title': title,
        'body': body,
      });
    } catch (_) {}
  }

  Future<void> sendNotificationToPhone({
    required String title,
    required String body,
    String appName = 'Mac Alert',
    bool vibrate = true,
    int tone = 1,
  }) async {
    if (!connected) {
      throw StateError('Cannot push notification: No phone connected via serial.');
    }

    _emit('info', 'Pushing BT Notifier alert to phone: [$appName] $title - $body');

    // Trigger ringtone / beep tone / alert profile on phone
    if (vibrate) {
      await command('AT+CALM=2'); // Vibrate mode
    } else {
      await command('AT+CALM=0'); // Normal mode
    }

    // Trigger alert tone via DTMF tone generator
    if (tone > 0) {
      await command('AT+VTS=1');
      await Future.delayed(const Duration(milliseconds: 100));
      await command('AT+VTS=5');
    }

    // Try standard BT Notification or custom display AT commands
    try {
      await command('AT+NOTIFY="$appName","$title","$body"');
    } catch (_) {}

    final notif = BtNotification.macPush(
      title: title,
      body: body,
      appName: appName,
    );
    _addNotification(notif);
  }

  // -------------------------------------------------------------
  // CALLS & PHONEBOOK
  // -------------------------------------------------------------
  Future<String> ping() => command('AT');
  Future<String> dial(String number) => command('ATD${number.trim()};');
  Future<String> answer() => command('ATA');
  Future<String> hangup() => command('AT+CHUP');
  Future<String> callStatus() => command('AT+CLCC');
  Future<String> dtmf(String digit) => command('AT+VTS=$digit');

  // Device & GSM info
  Future<String> signalQuality() => command('AT+CSQ');
  Future<String> batteryStatus() => command('AT+CBC');
  Future<String> imei() => command('AT+CGSN');
  Future<String> manufacturer() => command('AT+CGMI');
  Future<String> model() => command('AT+CGMM');
  Future<String> firmware() => command('AT+CGMR');
  Future<String> operatorName() => command('AT+COPS?');
  Future<String> networkRegistration() => command('AT+CREG?');
  Future<String> simStatus() => command('AT+CPIN?');

  // Phone Bluetooth control
  Future<String> btPower(bool on) => command('AT+BTPOWER=${on ? 1 : 0}');
  Future<String> getBtPower() => command('AT+BTPOWER?');
  Future<String> getBtName() => command('AT+BTNAME?');
  Future<String> setBtName(String name) => command('AT+BTNAME="$name"');
  Future<String> getBtAddress() => command('AT+BTADDR?');
  Future<String> btVisibility(bool visible) => command('AT+BTVIS=${visible ? 1 : 0}');
  Future<String> getBtVisibility() => command('AT+BTVIS?');
  Future<String> btScan({bool start = true}) => command('AT+BTSCAN=${start ? 1 : 0}');
  Future<String> btStatus() => command('AT+BTSTATUS?');
  Future<String> btPair(String deviceId) => command('AT+BTPAIR=$deviceId');
  Future<String> btUnpair(String deviceId) => command('AT+BTUNPAIR=$deviceId');
  Future<String> btConnect(String deviceId) => command('AT+BTCONNECT=$deviceId');
  Future<String> btDisconnect(String deviceId) => command('AT+BTDISCONNECT=$deviceId');

  // Audio & Hardware
  Future<String> setVolume(int level) => command('AT+CLVL=$level');
  Future<String> getVolume() => command('AT+CLVL?');
  Future<String> setMute(bool mute) => command('AT+CMUT=${mute ? 1 : 0}');
  Future<String> setAlertMode(int mode) => command('AT+CALM=$mode');

  // SMS
  Future<String> listSms() async {
    await command('AT+CMGF=1');
    return command('AT+CMGL="ALL"');
  }

  Future<String> readSms(int index) async {
    await command('AT+CMGF=1');
    return command('AT+CMGR=$index');
  }

  Future<String> deleteSms(int index) => command('AT+CMGD=$index');

  Future<String> sendSms(String number, String message) async {
    final response = await _method.invokeMethod<String>(
      'sendSms',
      {'number': number, 'message': message},
    );
    return response ?? '';
  }

  // Contacts / Phonebook
  Future<String> listContacts({int start = 1, int end = 100}) async {
    return command('AT+CPBR=$start,$end');
  }

  Future<String> saveContact(String name, String number) async {
    return command('AT+CPBW=,"$number",129,"$name"');
  }

  void dispose() {
    _stopHeartbeat();
    _nativeSubscription?.cancel();
    _devices.close();
    _btDevices.close();
    _eventsController.close();
    _ussdController.close();
    _notificationController.close();
  }
}
