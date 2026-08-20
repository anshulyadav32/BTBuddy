import 'dart:async';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../models/usb_device.dart';
import '../models/serial_event.dart';
import '../models/ussd_session.dart';
import '../models/bluetooth_device_item.dart';
import '../models/bt_notification.dart';
import '../models/sim_card.dart';
import '../models/call_log_item.dart';
import '../models/sms_message.dart';

class BTBuddyService {
  static const _method = MethodChannel('btbuddy/serial');
  static const _events = EventChannel('btbuddy/serial_events');

  // Controllers
  final _devices = StreamController<List<UsbDevice>>.broadcast();
  final _btDevices = StreamController<List<BluetoothDeviceItem>>.broadcast();
  final _eventsController = StreamController<SerialEvent>.broadcast();
  final _ussdController = StreamController<UssdSession>.broadcast();
  final _notificationController = StreamController<BtNotification>.broadcast();
  final _simController = StreamController<List<SimCard>>.broadcast();
  final _callLogsController = StreamController<List<CallLogItem>>.broadcast();

  StreamSubscription? _nativeSubscription;
  Timer? _heartbeatTimer;

  // Devices & State
  List<UsbDevice> _currentDevices = const [];
  List<BluetoothDeviceItem> _currentBtDevices = const [];
  UsbDevice? selectedDevice;
  bool connected = false;
  String connectionPath = '';
  String? _lastConnectedPath;

  // Call Logs & History State
  List<CallLogItem> callLogs = [];

  // SIM Cards State (1=Single, 2=Dual SIM, 3=Triple, 4=Quad)
  int simSlotCount = 2;
  int activeSimSlot = 1;
  List<SimCard> simCards = [];

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
  static const _prefsSimSlots = 'btbuddy.sim_slots';
  static const _prefsActiveSim = 'btbuddy.active_sim';

  // Streams
  Stream<List<UsbDevice>> get devices => _devices.stream;
  Stream<List<BluetoothDeviceItem>> get bluetoothDevices => _btDevices.stream;
  Stream<SerialEvent> get serialEvents => _eventsController.stream;
  Stream<UssdSession> get ussdStream => _ussdController.stream;
  Stream<BtNotification> get notificationStream => _notificationController.stream;
  Stream<List<SimCard>> get simStream => _simController.stream;
  Stream<List<CallLogItem>> get callLogsStream => _callLogsController.stream;

  List<UsbDevice> get currentDevices => List.unmodifiable(_currentDevices);
  List<BluetoothDeviceItem> get currentBtDevices => List.unmodifiable(_currentBtDevices);
  List<CallLogItem> get currentCallLogs => List.unmodifiable(callLogs);
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
      simSlotCount = prefs.getInt(_prefsSimSlots) ?? 2;
      activeSimSlot = prefs.getInt(_prefsActiveSim) ?? 1;
      _lastConnectedPath = prefs.getString(_prefsLastPath);
      if (_lastConnectedPath != null && _lastConnectedPath!.isNotEmpty) {
        _emit('info', 'Remembered last device: $_lastConnectedPath');
      }
      await _buildInitialSimCards();
    } catch (e) {
      _emit('info', 'Preferences init note: $e');
      _buildInitialSimCards();
    }
  }

  Future<void> _buildInitialSimCards() async {
    final list = <SimCard>[];
    SharedPreferences? prefs;
    try {
      prefs = await SharedPreferences.getInstance();
    } catch (_) {}

    for (int i = 1; i <= simSlotCount; i++) {
      final savedOp = prefs?.getString('btbuddy.sim_operator_$i');
      final savedNum = prefs?.getString('btbuddy.sim_number_$i');

      list.add(SimCard(
        slotIndex: i,
        label: 'SIM $i',
        operatorName: (savedOp != null && savedOp.isNotEmpty)
            ? savedOp
            : (i == 1 ? 'Primary Network' : 'SIM $i Standby'),
        phoneNumber: savedNum,
        status: i == 1 ? SimStatus.ready : SimStatus.inserted,
        signalLevel: i == 1 ? 24 : 18,
        isActive: i == activeSimSlot,
      ));
    }
    simCards = list;
    _simController.add(simCards);
  }

  Future<void> updateSimCardDetails(int slotIndex, {String? operatorName, String? phoneNumber}) async {
    if (slotIndex < 1 || slotIndex > simSlotCount) return;
    try {
      final prefs = await SharedPreferences.getInstance();
      if (operatorName != null) {
        await prefs.setString('btbuddy.sim_operator_$slotIndex', operatorName.trim());
      }
      if (phoneNumber != null) {
        await prefs.setString('btbuddy.sim_number_$slotIndex', phoneNumber.trim());
      }
    } catch (_) {}

    simCards = simCards.map((sim) {
      if (sim.slotIndex == slotIndex) {
        return sim.copyWith(
          operatorName: operatorName != null && operatorName.trim().isNotEmpty ? operatorName.trim() : sim.operatorName,
          phoneNumber: phoneNumber != null && phoneNumber.trim().isNotEmpty ? phoneNumber.trim() : sim.phoneNumber,
        );
      }
      return sim;
    }).toList();

    _simController.add(simCards);
    _emit('info', 'Updated SIM $slotIndex details: ${simCards[slotIndex - 1].operatorName} (${simCards[slotIndex - 1].phoneNumber ?? 'No number'})');
  }

  Future<void> setSimSlotCount(int count) async {
    simSlotCount = count.clamp(1, 4);
    if (activeSimSlot > simSlotCount) {
      activeSimSlot = 1;
    }
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setInt(_prefsSimSlots, simSlotCount);
      await prefs.setInt(_prefsActiveSim, activeSimSlot);
    } catch (_) {}
    _buildInitialSimCards();
    _emit('info', 'Configured phone SIM slots: $simSlotCount (${simSlotCount == 1 ? 'Single SIM' : simSlotCount == 2 ? 'Dual SIM' : simSlotCount == 3 ? 'Triple SIM' : 'Quad SIM'})');
  }

  Future<void> setActiveSim(int slot) async {
    if (slot < 1 || slot > simSlotCount) return;
    activeSimSlot = slot;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setInt(_prefsActiveSim, activeSimSlot);
    } catch (_) {}

    // Send multi-SIM switch commands across diverse modem chipsets
    if (connected) {
      bool switched = false;
      // 1. Try MediaTek dual-SIM command: AT+ESUO
      try {
        final r1 = await command('AT+ESUO=$slot');
        if (r1.contains('OK')) switched = true;
      } catch (_) {}

      // 2. Try 3GPP dual-SIM select: AT+CSUS (0-indexed)
      if (!switched) {
        try {
          final r2 = await command('AT+CSUS=${slot - 1}');
          if (r2.contains('OK')) switched = true;
        } catch (_) {}
      }

      // 3. Try Spreadtrum / Unisoc dual-SIM: AT+DSIM or AT+SIM
      if (!switched) {
        try {
          final r3 = await command('AT+DSIM=$slot');
          if (r3.contains('OK')) switched = true;
        } catch (_) {}
      }
      if (!switched) {
        try {
          await command('AT+SIM=$slot');
        } catch (_) {}
      }
    }

    simCards = simCards.map((sim) => sim.copyWith(isActive: sim.slotIndex == activeSimSlot)).toList();
    _simController.add(simCards);
    _emit('info', 'Active cellular SIM switched to SIM $slot');
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
  bool isExecutingCommand = false;

  void _startHeartbeat() {
    _heartbeatTimer?.cancel();
    _heartbeatTimer = Timer.periodic(const Duration(seconds: 15), (_) async {
      if (!connected || isExecutingCommand) return;
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
    isExecutingCommand = true;
    try {
      final response = await _method.invokeMethod<String>(
        'command',
        {'command': command},
      );
      return response ?? '';
    } finally {
      isExecutingCommand = false;
    }
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
  // BT DIALER COMPANION FUNCTIONS (Anti-Lost, Volume, Mic, Camera)
  // -------------------------------------------------------------
  Future<void> ringPhoneAntiLost() async {
    if (!connected) return;
    _emit('info', 'Triggering Find My Phone / Anti-Lost Alarm on connected device…');
    try {
      // Set volume to max
      await command('AT+CLVL=100');
      await command('AT+CRSL=100');
      await command('AT+CALM=2'); // Vibrate mode
      // Generate tone sequence
      await command('AT+VTS=1,2,3,4,5,6,7,8,9,0,*');
      await Future.delayed(const Duration(milliseconds: 200));
      await command('AT+VTD=10');
    } catch (_) {}
    _emit('info', 'Find My Phone alarm sequence broadcast to handset.');
  }

  Future<String> setPhoneSpeakerVolume(int level) async {
    final clamped = level.clamp(0, 100);
    final resp = await command('AT+CLVL=$clamped');
    try {
      await command('AT+CRSL=$clamped');
    } catch (_) {}
    _emit('info', 'Phone speaker volume set to $clamped%');
    return resp;
  }

  Future<String> setMutePhoneMic(bool mute) async {
    final resp = await command('AT+CMUT=${mute ? 1 : 0}');
    _emit('info', 'Phone microphone ${mute ? 'MUTED' : 'UNMUTED'}');
    return resp;
  }

  Future<String> triggerRemoteCamera() async {
    _emit('info', 'Triggering remote camera shutter over Bluetooth…');
    try {
      final r1 = await command('AT+CKPD="[PHOTO]"');
      if (r1.contains('OK')) return r1;
    } catch (_) {}
    return command('AT+CKPD="[CAMERA]"');
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

  // Multi-SIM Operations
  Future<List<SimCard>> detectSimCards() async {
    if (!connected) return simCards;

    _emit('info', 'Probing cellular SIM slots ($simSlotCount slots), company names & subscriber numbers…');
    final updated = <SimCard>[];

    SharedPreferences? prefs;
    try {
      prefs = await SharedPreferences.getInstance();
    } catch (_) {}

    // 1. Probe Operator Name (Company)
    String mainOperator = 'Network Provider';
    try {
      final ops = await operatorName();
      final match = RegExp(r'\+COPS:\s*\d+,\s*\d+,\s*"([^"]+)"').firstMatch(ops);
      if (match != null && (match.group(1)?.isNotEmpty ?? false)) {
        mainOperator = match.group(1)!;
      }
    } catch (_) {}

    // 2. Probe Subscriber Phone Numbers (AT+CNUM)
    final Map<int, String> detectedNumbers = {};
    try {
      final cnumResp = await command('AT+CNUM');
      final cnumMatches = RegExp(r'\+CNUM:\s*"([^"]*)",\s*"([^"]+)"').allMatches(cnumResp);
      int slotIdx = 1;
      for (final m in cnumMatches) {
        final num = m.group(2) ?? '';
        if (num.isNotEmpty) {
          detectedNumbers[slotIdx] = num;
          slotIdx++;
        }
      }
    } catch (_) {}

    // 3. Fallback to Own Numbers storage (AT+CPBS="ON") if CNUM didn't find numbers
    if (detectedNumbers.isEmpty) {
      try {
        await command('AT+CPBS="ON"');
        final onResp = await command('AT+CPBR=1,5');
        final onMatches = RegExp(r'\+CPBR:\s*(\d+),\s*"([^"]+)"').allMatches(onResp);
        for (final m in onMatches) {
          final idx = int.tryParse(m.group(1) ?? '1') ?? 1;
          final num = m.group(2) ?? '';
          if (num.isNotEmpty) {
            detectedNumbers[idx] = num;
          }
        }
        await command('AT+CPBS="SM"');
      } catch (_) {}
    }

    // 4. Probe Signal Quality
    int mainSignal = 24;
    try {
      final csq = await signalQuality();
      final match = RegExp(r'\+CSQ:\s*(\d+)').firstMatch(csq);
      if (match != null) mainSignal = int.tryParse(match.group(1) ?? '24') ?? 24;
    } catch (_) {}

    for (int i = 1; i <= simSlotCount; i++) {
      SimStatus status = SimStatus.ready;
      try {
        // Probe PIN status for slot
        final pinResp = await (i == 1 ? command('AT+CPIN?') : command('AT+CPIN2?'));
        if (pinResp.contains('SIM PIN')) {
          status = SimStatus.pinRequired;
        } else if (pinResp.contains('SIM PUK')) {
          status = SimStatus.pukRequired;
        } else if (pinResp.contains('NOT INSERTED') || pinResp.contains('ERROR')) {
          status = i == 1 ? SimStatus.noSim : SimStatus.inserted;
        } else if (pinResp.contains('READY')) {
          status = SimStatus.ready;
        }
      } catch (_) {}

      final savedOp = prefs?.getString('btbuddy.sim_operator_$i');
      final savedNum = prefs?.getString('btbuddy.sim_number_$i');
      final detectedNum = detectedNumbers[i];

      final finalOp = (savedOp != null && savedOp.isNotEmpty)
          ? savedOp
          : (i == 1 ? mainOperator : (simSlotCount > 1 ? 'Secondary SIM' : mainOperator));
      final finalNum = (savedNum != null && savedNum.isNotEmpty) ? savedNum : detectedNum;

      updated.add(SimCard(
        slotIndex: i,
        label: 'SIM $i',
        operatorName: finalOp,
        phoneNumber: finalNum,
        status: status,
        signalLevel: i == 1 ? mainSignal : (mainSignal > 6 ? mainSignal - 4 : mainSignal),
        isActive: i == activeSimSlot,
      ));
    }

    simCards = updated;
    _simController.add(simCards);
    return simCards;
  }

  Future<String> dialWithSim(String number, {int? simSlot}) async {
    final slot = simSlot ?? activeSimSlot;
    final clean = number.replaceAll(RegExp(r'[^\d+*#]'), '');
    if (clean.isEmpty) return 'ERROR: Invalid phone number';

    _emit('info', 'Placing call to $clean on SIM $slot…');

    if (slot <= 1) {
      // 1. Direct standard voice dial with semicolon: ATD<number>;
      try {
        final resp = await command('ATD$clean;');
        if (!resp.contains('ERROR') && !resp.contains('NO CARRIER')) {
          return resp;
        }
      } catch (_) {}

      // 2. Direct voice dial without semicolon
      try {
        final r1 = await command('ATD$clean');
        if (!r1.contains('ERROR') && !r1.contains('NO CARRIER')) {
          return r1;
        }
      } catch (_) {}

      // 3. Bluetooth Companion Call format
      try {
        final r2 = await command('AT+BTDIAL="$clean"');
        if (r2.contains('OK') || !r2.contains('ERROR')) return r2;
      } catch (_) {}

      return await command('ATD$clean;');
    } else {
      // Multi-SIM calling
      try {
        await setActiveSim(slot);
      } catch (_) {}

      try {
        final resp = await command('ATD$clean;$slot');
        if (!resp.contains('ERROR') && !resp.contains('NO CARRIER')) {
          return resp;
        }
      } catch (_) {}

      try {
        final r2 = await command('ATD$clean;');
        if (!r2.contains('ERROR') && !r2.contains('NO CARRIER')) {
          return r2;
        }
      } catch (_) {}

      return await command('ATD$clean;');
    }
  }

  Future<String> sendSmsWithSim(String number, String message, {int? simSlot}) async {
    if (simSlot != null && simSlot != activeSimSlot) {
      await setActiveSim(simSlot);
      await Future.delayed(const Duration(milliseconds: 100));
    }
    return sendSms(number, message);
  }

  Future<UssdSession> sendUssdWithSim(String code, {int? simSlot}) async {
    if (simSlot != null && simSlot != activeSimSlot) {
      await setActiveSim(simSlot);
      await Future.delayed(const Duration(milliseconds: 100));
    }
    return sendUssd(code);
  }

  // -------------------------------------------------------------
  // CALL LOGS / CALL HISTORY SYNC (AT+CPBS / AT+CPBR)
  // -------------------------------------------------------------
  Future<List<CallLogItem>> syncCallLogs({int? targetSimSlot}) async {
    if (!connected) return callLogs;

    final slot = targetSimSlot ?? activeSimSlot;
    _emit('info', 'Syncing phone call history (Dialed, Received & Missed Calls on SIM $slot)…');
    final allCalls = <CallLogItem>[];

    Future<void> probeStorage(String storageCode, CallType type) async {
      try {
        final selectResp = await command('AT+CPBS="$storageCode"');
        if (selectResp.contains('ERROR')) {
          await command('AT+CPBS=$storageCode');
        }
        await Future.delayed(const Duration(milliseconds: 50));

        // Probe total used and capacity
        int maxIndex = 30;
        try {
          final cpbsInfo = await command('AT+CPBS?');
          final match = RegExp(r'\+CPBS:\s*"?[^",]*"?,\s*(\d+),\s*(\d+)').firstMatch(cpbsInfo);
          if (match != null) {
            final used = int.tryParse(match.group(1) ?? '0') ?? 0;
            final total = int.tryParse(match.group(2) ?? '30') ?? 30;
            maxIndex = total > 0 ? total : 30;
            if (used == 0) {
              return;
            }
          }
        } catch (_) {}

        String raw = '';
        // Try querying full range
        try {
          raw = await command('AT+CPBR=1,$maxIndex');
        } catch (_) {}

        // Fallbacks for devices with strict smaller range limits
        if (raw.isEmpty || raw.contains('ERROR')) {
          for (final r in [20, 10, 5]) {
            try {
              final test = await command('AT+CPBR=1,$r');
              if (test.isNotEmpty && !test.contains('ERROR')) {
                raw = test;
                break;
              }
            } catch (_) {}
          }
        }

        // If range command fails, try querying individual slots 1..10
        if (raw.isEmpty || raw.contains('ERROR') || !raw.contains('+CPBR:')) {
          final cpbrBuffer = StringBuffer();
          for (int idx = 1; idx <= 10; idx++) {
            try {
              final entry = await command('AT+CPBR=$idx');
              if (entry.contains('+CPBR:') && !entry.contains('ERROR')) {
                cpbrBuffer.writeln(entry);
              }
            } catch (_) {}
          }
          if (cpbrBuffer.isNotEmpty) {
            raw = cpbrBuffer.toString();
          }
        }

        if (raw.isNotEmpty && !raw.contains('ERROR')) {
          final items = CallLogItem.parseCpbrResponse(raw, type: type, simSlot: slot);
          allCalls.addAll(items);
        }
      } catch (_) {}
    }

    // Probing Dialed ("DC"), Received ("RC"), Missed ("MC"), Last Dialed ("LD")
    await probeStorage('DC', CallType.dialed);
    await probeStorage('RC', CallType.received);
    await probeStorage('MC', CallType.missed);
    await probeStorage('LD', CallType.dialed);

    // If multi-SIM is configured and no specific slot requested, also check SIM 2 if possible
    if (targetSimSlot == null && simSlotCount > 1 && activeSimSlot != 2) {
      try {
        await command('AT+ESUO=2');
        await Future.delayed(const Duration(milliseconds: 60));
        await probeStorage('DC', CallType.dialed);
        await probeStorage('RC', CallType.received);
        await probeStorage('MC', CallType.missed);
      } catch (_) {} finally {
        await command('AT+ESUO=$activeSimSlot');
      }
    }

    // Restore default phonebook storage to SIM ("SM") or phone ("ME")
    try {
      await command('AT+CPBS="SM"');
    } catch (_) {}

    // Deduplicate calls by simSlot, type, number, and timestamp
    final Map<String, CallLogItem> uniqueMap = {};
    for (final c in allCalls) {
      final key = '${c.simSlot}_${c.type.name}_${c.number}_${c.timestamp}_${c.index}';
      uniqueMap[key] = c;
    }

    callLogs = uniqueMap.values.toList();
    _callLogsController.add(callLogs);
    _emit('info', 'Call history synced: ${callLogs.length} call logs retrieved across SIMs.');
    return callLogs;
  }

  // -------------------------------------------------------------
  // ALL OLD SMS SYNC ACROSS STORAGES & SIMs (AT+CPMS / AT+CMGL)
  // -------------------------------------------------------------
  Future<List<SmsMessage>> syncAllSmsMessages() async {
    if (!connected) return [];

    _emit('info', 'Syncing all old SMS messages from SIM & phone memory across $simSlotCount SIM slots…');
    final Map<String, SmsMessage> msgMap = {};

    Future<void> probeSmsStorage(String storageCode, int slot) async {
      try {
        // Select message storage
        try {
          await command('AT+CPMS="$storageCode","$storageCode","$storageCode"');
        } catch (_) {
          try {
            await command('AT+CPMS="$storageCode"');
          } catch (_) {}
        }
        await Future.delayed(const Duration(milliseconds: 50));

        // Enable SMS text mode
        try {
          await command('AT+CMGF=1');
        } catch (_) {}

        String raw = '';
        // 1. Try AT+CMGL="ALL"
        try {
          raw = await command('AT+CMGL="ALL"');
        } catch (_) {}

        // 2. Try numeric mode AT+CMGL=4 (Standard GSM 07.05 for ALL)
        if (raw.isEmpty || raw.contains('ERROR') || !raw.contains('+CMG')) {
          try {
            final numResp = await command('AT+CMGL=4');
            if (numResp.isNotEmpty && !numResp.contains('ERROR')) {
              raw = numResp;
            }
          } catch (_) {}
        }

        // 3. Try reading status groups individually
        if (raw.isEmpty || raw.contains('ERROR') || !raw.contains('+CMG')) {
          try {
            final unread = await command('AT+CMGL="REC UNREAD"');
            final read = await command('AT+CMGL="REC READ"');
            final sent = await command('AT+CMGL="STO SENT"');
            raw = '$unread\n$read\n$sent';
          } catch (_) {}
        }

        // 4. Try reading slot indices with AT+CMGR=1..20
        if (raw.isEmpty || raw.contains('ERROR') || !raw.contains('+CMG')) {
          final cmgrBuffer = StringBuffer();
          for (int idx = 1; idx <= 20; idx++) {
            try {
              final r = await command('AT+CMGR=$idx');
              if (r.contains('+CMGR:') && !r.contains('ERROR')) {
                cmgrBuffer.writeln('+CMGL: $idx,$r');
              }
            } catch (_) {}
          }
          if (cmgrBuffer.isNotEmpty) {
            raw = cmgrBuffer.toString();
          }
        }

        if (raw.isNotEmpty && !raw.contains('ERROR')) {
          final list = SmsMessage.parseList(raw, storage: storageCode, simSlot: slot);
          for (final m in list) {
            final key = '${slot}_${m.index}_${m.sender}_${m.date}_${m.body}';
            msgMap[key] = m;
          }
        }
      } catch (_) {}
    }

    // Probe SIM storage ("SM"), Phone memory ("ME"), and Combined ("MT")
    await probeSmsStorage('SM', 1);
    await probeSmsStorage('ME', 1);
    await probeSmsStorage('MT', 1);

    if (simSlotCount > 1) {
      try {
        await command('AT+ESUO=2');
        await Future.delayed(const Duration(milliseconds: 60));
        await probeSmsStorage('SM', 2);
        await probeSmsStorage('ME', 2);
      } catch (_) {} finally {
        await command('AT+ESUO=$activeSimSlot');
      }
    }

    final result = msgMap.values.toList();
    _emit('info', 'SMS sync complete: ${result.length} total messages retrieved across all SIM storages.');
    return result;
  }

  // -------------------------------------------------------------
  // UNIFIED FULL RESYNC (OLD CALLS + OLD SMS + SIM PROBE)
  // -------------------------------------------------------------
  Future<Map<String, dynamic>> syncAllOldMessagesAndCalls() async {
    if (!connected) {
      return {'smsCount': 0, 'callsCount': 0, 'simCount': simSlotCount};
    }

    _emit('info', 'Beginning unified phone sync (All SIMs, Old SMS & Call Logs)…');
    await detectSimCards();
    final smsList = await syncAllSmsMessages();
    final callList = await syncCallLogs();

    return {
      'smsCount': smsList.length,
      'callsCount': callList.length,
      'simCount': simSlotCount,
    };
  }

  void dispose() {
    _stopHeartbeat();
    _nativeSubscription?.cancel();
    _devices.close();
    _btDevices.close();
    _eventsController.close();
    _ussdController.close();
    _notificationController.close();
    _simController.close();
    _callLogsController.close();
  }
}
