import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../models/serial_event.dart';
import '../models/usb_device.dart';
import '../models/sms_message.dart';
import '../models/phone_contact.dart';
import '../models/ussd_session.dart';
import '../models/bluetooth_device_item.dart';
import '../models/bt_notification.dart';
import '../models/sim_card.dart';
import '../models/call_log_item.dart';
import '../services/btbuddy_service.dart';
import '../utils/at_error_helper.dart';
import '../widgets/logo_badge.dart';

class HomeScreen extends StatefulWidget {
  final BTBuddyService service;
  const HomeScreen({super.key, required this.service});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> with SingleTickerProviderStateMixin {
  late final BTBuddyService service;
  late final TabController _tabController;

  // Text Controllers
  final dialerNumberController = TextEditingController();
  final smsRecipientController = TextEditingController();
  final smsBodyController = TextEditingController();
  final contactNameController = TextEditingController();
  final contactNumberController = TextEditingController();
  final contactSearchController = TextEditingController();
  final ussdCodeController = TextEditingController();
  final ussdReplyController = TextEditingController();
  final pushTitleController = TextEditingController(text: 'Meeting Reminder');
  final pushBodyController = TextEditingController(text: 'Team standup in 5 minutes on Mac');
  final btRenameController = TextEditingController();
  final terminal = TextEditingController();
  final logScrollController = ScrollController();

  // State
  final List<SerialEvent> logs = [];
  List<UsbDevice> devices = [];
  List<BluetoothDeviceItem> btDevices = [];
  List<SmsMessage> messages = [];
  SmsMessage? selectedMessage;
  List<PhoneContact> contacts = [];
  List<CallLogItem> callLogs = [];
  String contactSearchQuery = '';
  String deviceFilter = 'All'; // 'All', 'USB', 'Bluetooth'
  int historySubFilter = 0; // 0=All, 1=Dialed, 2=Received, 3=Missed, 4=USSD

  // Multi-SIM State
  List<SimCard> simCards = [];
  int selectedSimSlot = 1;

  // Subscriptions & Timers
  StreamSubscription? eventSub;
  StreamSubscription? ussdSub;
  StreamSubscription? notifSub;
  StreamSubscription? simSub;
  StreamSubscription? callLogSub;
  Timer? devicePoll;
  Timer? callTimer;
  Timer? _scrollDebounceTimer;

  int baud = 115200;
  String status = 'Disconnected';
  String? connectedPath;
  bool busy = false;
  bool _syncingAll = false;
  bool _refreshing = false;
  bool _scanning = false;
  bool _scanningBt = false;
  String? connectingPath;

  // Incoming Call Overlay State
  bool isIncomingCallActive = false;
  String incomingCallerNumber = '';
  String incomingCallerName = '';

  // Phone Diagnostics & Metrics
  String phoneModel = 'Phone Device';
  String phoneManufacturer = 'MediaTek / Kechaoda';
  String phoneFirmware = '';
  String? operatorName;
  String? imeiNumber;
  int signalLevel = 0; // 0 - 31
  int batteryLevel = 0; // %
  bool isCharging = false;
  String callState = 'IDLE';
  int callDurationSeconds = 0;
  int volumeLevel = 5;
  bool micMuted = false;
  int alertProfile = 0; // 0=Normal, 1=Silent, 2=Vibrate
  bool btPowerOn = false;
  String pushAppSource = 'Mac Alert';
  int phoneHubSubTab = 0; // 0: Keypad & USSD, 1: Contacts, 2: History
  int dashboardSubTab = 0; // 0: Overview, 1: Serial Ports, 2: Bluetooth & Eject, 3: BT Notifier, 4: Terminal

  @override
  void initState() {
    super.initState();
    service = widget.service;
    _tabController = TabController(length: 3, vsync: this);
    connectedPath = service.connectionPath;
    status = service.connected ? 'Connected' : 'Disconnected';
    simCards = service.simCards;
    selectedSimSlot = service.activeSimSlot;
    callLogs = service.callLogs;

    eventSub = service.serialEvents.listen((event) {
      if (!mounted) return;
      if (logs.length > 250) {
        logs.removeRange(0, logs.length - 150);
      }
      logs.add(event);
      if (event.type == 'connected') {
        setState(() {
          status = 'Connected';
          connectedPath = service.connectionPath;
        });
      } else if (event.type == 'disconnected') {
        setState(() {
          status = 'Disconnected';
          connectedPath = null;
          isIncomingCallActive = false;
        });
      } else if (_tabController.index == 0 && dashboardSubTab == 3) {
        // Redraw only if user is actively watching AT Terminal tab
        setState(() {});
      }
      _parseSerialEvent(event);
      _scrollLog();
    });

    ussdSub = service.ussdStream.listen((session) {
      if (!mounted) return;
      setState(() {});
      if (session.isInteractive) {
        _showInteractiveUssdDialog(session);
      }
    });

    notifSub = service.notificationStream.listen((notif) {
      if (!mounted) return;
      setState(() {});
      if (notif.type == BtNotificationType.incomingCall) {
        setState(() {
          isIncomingCallActive = true;
          incomingCallerNumber = notif.metadata?['number'] ?? 'Unknown Caller';
          final match = contacts.where((c) => c.number.contains(incomingCallerNumber));
          incomingCallerName = match.isNotEmpty ? match.first.name : '';
        });
      }
    });

    simSub = service.simStream.listen((list) {
      if (!mounted) return;
      setState(() {
        simCards = list;
        selectedSimSlot = service.activeSimSlot;
      });
    });

    callLogSub = service.callLogsStream.listen((list) {
      if (!mounted) return;
      setState(() => callLogs = list);
    });

    _refresh();
    _refreshBtDevices();

    // Lightweight disconnected polling only
    devicePoll = Timer.periodic(
      const Duration(seconds: 8),
      (_) {
        if (!service.connected && !busy && !_scanning && !_refreshing) {
          _refresh();
        }
      },
    );
  }

  void _parseSerialEvent(SerialEvent event) {
    final text = event.data;
    // Signal Quality
    if (text.contains('+CSQ:')) {
      final match = RegExp(r'\+CSQ:\s*(\d+)').firstMatch(text);
      if (match != null) {
        final val = int.tryParse(match.group(1) ?? '0') ?? 0;
        setState(() => signalLevel = val.clamp(0, 31));
      }
    }
    // Battery
    if (text.contains('+CBC:')) {
      final match = RegExp(r'\+CBC:\s*(\d+),\s*(\d+)').firstMatch(text);
      if (match != null) {
        setState(() {
          isCharging = match.group(1) != '0';
          batteryLevel = (int.tryParse(match.group(2) ?? '0') ?? 0).clamp(0, 100);
        });
      }
    }
    // Model & Firmware
    if (text.contains('+CGMM:')) {
      final match = RegExp(r'\+CGMM:\s*"?([^"\r\n]+)"?').firstMatch(text);
      if (match != null) {
        setState(() => phoneModel = match.group(1) ?? phoneModel);
      }
    }
    if (text.contains('+CGMR:')) {
      final match = RegExp(r'\+CGMR:\s*"?([^"\r\n]+)"?').firstMatch(text);
      if (match != null) {
        setState(() => phoneFirmware = match.group(1) ?? '');
      }
    }
    // Operator
    if (text.contains('+COPS:')) {
      final match = RegExp(r'\+COPS:\s*\d+,\s*\d+,\s*"([^"]+)"').firstMatch(text);
      if (match != null) {
        setState(() => operatorName = match.group(1));
      }
    }
    // BT Power
    if (text.contains('+BTPOWER:')) {
      final match = RegExp(r'\+BTPOWER:\s*(\d+)').firstMatch(text);
      if (match != null) {
        setState(() => btPowerOn = match.group(1) == '1');
      }
    }
  }

  Future<void> _refresh() async {
    if (_refreshing) return;
    _refreshing = true;
    try {
      final result = await service.refreshDevices();
      if (!mounted) return;
      setState(() {
        devices = result;
        if (service.connected) {
          status = 'Connected';
          connectedPath = service.connectionPath;
        } else {
          status = 'Disconnected';
          connectedPath = null;
        }
      });

      // Auto-connect to preferred device if available and not currently connected
      if (!service.connected && !busy && service.shouldAutoConnectNow()) {
        final target = service.selectedDevice;
        if (target != null) {
          _addLog('info', 'Auto-connecting to preferred device ${target.name} (${target.path})…');
          _connectToDevice(target);
        }
      }
    } catch (e) {
      _addLog('error', 'Device refresh error: $e');
    } finally {
      if (mounted) setState(() => _refreshing = false);
    }
  }

  Future<void> _refreshBtDevices() async {
    try {
      final list = await service.refreshBluetoothDevices();
      if (mounted) setState(() => btDevices = list);
    } catch (_) {}
  }

  Future<void> _scan() async {
    if (_scanning || busy) return;
    setState(() => _scanning = true);
    _addLog('info', 'Scanning for USB and Bluetooth endpoints…');
    try {
      if (service.connected) {
        service.btScan(start: true).ignore();
      }
      await Future.delayed(const Duration(milliseconds: 800));
      final result = await service.refreshDevices();
      await _refreshBtDevices();
      if (!mounted) return;
      setState(() => devices = result);
      _addLog('info', 'Scan complete: ${result.length} device endpoint(s) & ${btDevices.length} BT device(s) found.');
    } catch (e) {
      _addLog('error', 'Scan failed: $e');
    } finally {
      if (mounted) setState(() => _scanning = false);
    }
  }

  Future<void> _connectToDevice(UsbDevice device) async {
    setState(() {
      busy = true;
      connectingPath = device.path;
    });
    try {
      if (service.connected) {
        await service.disconnect();
      }
      await service.connectTo(device, baud: baud);
      setState(() {
        status = 'Connected';
        connectedPath = device.path;
        phoneModel = device.name;
        phoneManufacturer = device.manufacturer;
      });
      await _send('AT');
      _showSuccessBanner('Connected to ${device.name}', title: 'Device Ready', icon: Icons.bluetooth_connected);
      await _syncPhoneCompanionData();
    } catch (e) {
      _addLog('error', 'Connection failed: $e');
      _showErrorBanner(
        e.toString(),
        contextTitle: 'Failed to Connect to ${device.name}',
        onRetry: () => _connectToDevice(device),
      );
    } finally {
      if (mounted) {
        setState(() {
          busy = false;
          connectingPath = null;
        });
      }
    }
  }

  Future<void> _disconnect() async {
    setState(() => busy = true);
    try {
      await service.disconnect();
      setState(() {
        status = 'Disconnected';
        connectedPath = null;
        callState = 'IDLE';
        isIncomingCallActive = false;
      });
      callTimer?.cancel();
    } catch (e) {
      _addLog('error', 'Disconnect failed: $e');
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> _syncPhoneCompanionData() async {
    if (status != 'Connected') return;
    _addLog('info', 'Syncing phone companion status, SIMs, old messages & call history…');

    Future<void> safeRun(Future<dynamic> Function() action) async {
      if (status != 'Connected') return;
      try {
        await action();
        await Future.delayed(const Duration(milliseconds: 100));
      } catch (_) {}
    }

    await safeRun(() => service.model());
    await safeRun(() => service.firmware());
    await safeRun(() => service.signalQuality());
    await safeRun(() => service.batteryStatus());
    await safeRun(() => service.operatorName());
    await safeRun(() => service.detectSimCards());
    await safeRun(() => _syncAllOldData(silent: true));
    await safeRun(() => _loadContacts());
  }

  Future<void> _syncAllOldData({bool silent = false}) async {
    if (status != 'Connected') return;
    setState(() => _syncingAll = true);
    _addLog('info', 'Syncing all old SMS messages and call history across SIMs…');
    try {
      final res = await service.syncAllOldMessagesAndCalls();
      final msgs = await service.syncAllSmsMessages();
      if (mounted) {
        setState(() {
          messages = msgs;
          callLogs = service.callLogs;
          if (messages.isNotEmpty && selectedMessage == null) {
            selectedMessage = messages.first;
          }
        });
        if (!silent) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(
                'Synced ${res['smsCount']} SMS messages & ${res['callsCount']} call logs across ${res['simCount']} SIM slots.',
              ),
              backgroundColor: Colors.green.shade800,
            ),
          );
        }
      }
    } catch (e) {
      _addLog('error', 'Full sync error: $e');
    } finally {
      if (mounted) setState(() => _syncingAll = false);
    }
  }

  Future<void> _loadCallLogs() async {
    if (status != 'Connected') return;
    try {
      final logs = await service.syncCallLogs();
      if (mounted) setState(() => callLogs = logs);
    } catch (e) {
      _addLog('error', 'Call logs fetch error: $e');
    }
  }

  // -------------------------------------------------------------
  // USSD ACTIONS
  // -------------------------------------------------------------
  Future<void> _sendUssd(String code, {int? simSlot}) async {
    final c = code.trim();
    if (c.isEmpty) return;
    ussdCodeController.text = c;
    final slot = simSlot ?? selectedSimSlot;
    setState(() => busy = true);
    _addLog('info', 'Dialing USSD: $c on SIM $slot…');
    try {
      final session = await service.sendUssdWithSim(c, simSlot: slot);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('USSD (SIM $slot) ${session.statusLabel}: ${session.response.replaceAll('\n', ' ')}'),
          backgroundColor: session.isInteractive ? Colors.amber.shade800 : Colors.blueGrey.shade800,
        ),
      );
    } catch (e) {
      _addLog('error', 'USSD error: $e');
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> _replyUssd(String reply) async {
    if (reply.trim().isEmpty) return;
    setState(() => busy = true);
    _addLog('info', 'Sending USSD reply: $reply…');
    try {
      await service.replyUssd(reply.trim());
      ussdReplyController.clear();
    } catch (e) {
      _addLog('error', 'USSD reply error: $e');
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> _cancelUssd() async {
    _addLog('info', 'Cancelling active USSD session…');
    try {
      await service.cancelUssd();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('USSD Session cancelled.')),
        );
      }
    } catch (e) {
      _addLog('error', 'USSD cancel error: $e');
    }
  }

  void _showInteractiveUssdDialog(UssdSession session) {
    showDialog(
      context: context,
      builder: (ctx) {
        return AlertDialog(
          title: const Row(
            children: [
              Icon(Icons.dialpad, color: Colors.amberAccent),
              SizedBox(width: 10),
              Text('Interactive USSD Session'),
            ],
          ),
          content: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 480),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: Colors.black26,
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(color: Colors.amber.withValues(alpha: 0.3)),
                  ),
                  child: SelectableText(
                    session.response,
                    style: const TextStyle(fontFamily: 'monospace', fontSize: 13),
                  ),
                ),
                const SizedBox(height: 16),
                TextField(
                  controller: ussdReplyController,
                  autofocus: true,
                  decoration: const InputDecoration(
                    labelText: 'Enter Option / Reply (e.g. 1, 2, 0)',
                    border: OutlineInputBorder(),
                  ),
                  onSubmitted: (val) {
                    Navigator.pop(ctx);
                    _replyUssd(val);
                  },
                ),
                const SizedBox(height: 10),
                Wrap(
                  spacing: 8,
                  runSpacing: 6,
                  children: ['1', '2', '3', '4', '0'].map((opt) {
                    return ActionChip(
                      label: Text('Option $opt'),
                      onPressed: () {
                        ussdReplyController.text = opt;
                      },
                    );
                  }).toList(),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () {
                Navigator.pop(ctx);
                _cancelUssd();
              },
              child: const Text('Cancel Session', style: TextStyle(color: Colors.redAccent)),
            ),
            FilledButton(
              onPressed: () {
                final reply = ussdReplyController.text;
                Navigator.pop(ctx);
                _replyUssd(reply);
              },
              child: const Text('Send Reply'),
            ),
          ],
        );
      },
    );
  }

  // -------------------------------------------------------------
  // BT NOTIFIER ACTIONS
  // -------------------------------------------------------------
  Future<void> _sendPushNotificationToPhone() async {
    final title = pushTitleController.text.trim();
    final body = pushBodyController.text.trim();
    if (title.isEmpty || body.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Please enter notification title and message body.')),
      );
      return;
    }
    setState(() => busy = true);
    try {
      await service.sendNotificationToPhone(
        title: title,
        body: body,
        appName: pushAppSource,
        vibrate: true,
        tone: 1,
      );
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Notification pushed to phone successfully!'),
          backgroundColor: Colors.green,
        ),
      );
    } catch (e) {
      _addLog('error', 'Push notification failed: $e');
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Push failed: $e'), backgroundColor: Colors.redAccent),
      );
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  // -------------------------------------------------------------
  // CALLS & SMS ACTIONS
  // -------------------------------------------------------------
  Future<void> _loadSms() async {
    if (status != 'Connected') return;
    try {
      final list = await service.syncAllSmsMessages();
      if (mounted) {
        setState(() {
          messages = list;
          if (list.isNotEmpty && selectedMessage == null) {
            selectedMessage = list.first;
          }
        });
      }
    } catch (e) {
      _addLog('error', 'SMS fetch error: $e');
    }
  }

  Future<void> _loadContacts() async {
    if (status != 'Connected') return;
    try {
      final raw = await service.listContacts();
      final parsed = PhoneContact.parseList(raw);
      if (mounted) setState(() => contacts = parsed);
    } catch (_) {}
  }

  Future<void> _sendSms({int? simSlot}) async {
    final number = smsRecipientController.text.trim();
    final text = smsBodyController.text.trim();
    if (number.isEmpty || text.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Please enter both recipient number and message.')),
      );
      return;
    }
    final slot = simSlot ?? selectedSimSlot;
    setState(() => busy = true);
    _addLog('info', 'Sending SMS to $number via SIM $slot…');
    try {
      final r = await service.sendSmsWithSim(number, text, simSlot: slot);
      _addLog('rx', r);
      if (r.contains('ERROR') || r.contains('CMS ERROR') || r.contains('CME ERROR')) {
        _showErrorBanner(
          r,
          contextTitle: 'SMS Sending Failed (SIM $slot)',
          onRetry: () => _sendSms(simSlot: slot),
        );
        return;
      }
      smsBodyController.clear();
      _showSuccessBanner('Message sent to $number via SIM $slot', title: 'SMS Delivered', icon: Icons.send_rounded);
      await _loadSms();
    } catch (e) {
      _addLog('error', 'Send SMS failed: $e');
      _showErrorBanner(
        e.toString(),
        contextTitle: 'SMS Send Error',
        onRetry: () => _sendSms(simSlot: slot),
      );
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> _dial(String target, {int? simSlot}) async {
    final num = target.trim();
    if (num.isEmpty) return;
    final slot = simSlot ?? selectedSimSlot;
    dialerNumberController.text = num;
    setState(() {
      selectedSimSlot = slot;
      service.activeSimSlot = slot;
    });

    // Handle USSD / MMI codes typed directly on Android dialer (e.g. *123#)
    if (num.startsWith('*') || num.contains('#')) {
      await _sendUssd(num, simSlot: slot);
      return;
    }

    setState(() {
      callState = 'DIALING';
      callDurationSeconds = 0;
    });
    _addLog('info', 'Dialing $num via SIM $slot…');
    try {
      final r = await service.dialWithSim(num, simSlot: slot);
      _addLog('rx', r);
      if (r.contains('ERROR') || r.contains('NO CARRIER') || r.contains('BUSY') || r.contains('NO DIALTONE')) {
        setState(() => callState = 'IDLE');
        _showErrorBanner(
          r,
          contextTitle: 'Call Not Placed (SIM $slot)',
          onRetry: () => _dial(num, simSlot: slot),
        );
        return;
      }
      setState(() => callState = 'CALL ACTIVE');
      callTimer?.cancel();
      callTimer = Timer.periodic(const Duration(seconds: 1), (_) {
        if (mounted) setState(() => callDurationSeconds++);
      });
    } catch (e) {
      _addLog('error', 'Dial failed: $e');
      setState(() => callState = 'IDLE');
      _showErrorBanner(
        e.toString(),
        contextTitle: 'Call Error',
        onRetry: () => _dial(num, simSlot: slot),
      );
    }
  }

  Future<void> _hangup() async {
    _addLog('info', 'Hanging up call…');
    try {
      final r = await service.hangup();
      _addLog('rx', r);
      setState(() {
        callState = 'IDLE';
        callDurationSeconds = 0;
        isIncomingCallActive = false;
      });
      callTimer?.cancel();
    } catch (e) {
      _addLog('error', 'Hangup error: $e');
    }
  }

  Future<void> _answer() async {
    _addLog('info', 'Answering call…');
    try {
      final r = await service.answer();
      _addLog('rx', r);
      setState(() {
        callState = 'CALL ACTIVE';
        isIncomingCallActive = false;
      });
      callTimer?.cancel();
      callTimer = Timer.periodic(const Duration(seconds: 1), (_) {
        if (mounted) setState(() => callDurationSeconds++);
      });
    } catch (e) {
      _addLog('error', 'Answer error: $e');
    }
  }

  Future<void> _sendDtmf(String key) async {
    _addLog('tx', 'AT+VTS=$key');
    try {
      final r = await service.dtmf(key);
      _addLog('rx', r);
    } catch (e) {
      _addLog('error', e.toString());
    }
  }

  Future<void> _send(String cmd) async {
    if (cmd.trim().isEmpty) return;
    _addLog('tx', cmd);
    try {
      final response = await service.command(cmd.trim());
      _addLog('rx', response);
    } catch (e) {
      _addLog('error', e.toString());
    }
  }

  void _addLog(String type, String data) {
    if (!mounted) return;
    if (logs.length > 250) {
      logs.removeRange(0, logs.length - 150);
    }
    setState(() => logs.add(SerialEvent(type: type, data: data)));
    _scrollLog();
  }

  void _showErrorBanner(String rawError, {String? contextTitle, VoidCallback? onRetry}) {
    if (!mounted) return;
    final cleanExplanation = AtErrorHelper.formatError(rawError, context: contextTitle ?? '');
    final icon = AtErrorHelper.getIcon(rawError);
    final suggestedAction = AtErrorHelper.getSuggestedAction(rawError);

    ScaffoldMessenger.of(context).hideCurrentSnackBar();
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        behavior: SnackBarBehavior.floating,
        margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        backgroundColor: const Color(0xFF221115),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(12),
          side: BorderSide(color: Colors.redAccent.withValues(alpha: 0.6), width: 1.5),
        ),
        duration: const Duration(seconds: 5),
        content: Row(
          children: [
            Container(
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(
                color: Colors.redAccent.withValues(alpha: 0.2),
                shape: BoxShape.circle,
              ),
              child: Icon(icon, color: Colors.redAccent, size: 20),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (contextTitle != null && contextTitle.isNotEmpty)
                    Text(
                      contextTitle,
                      style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 13, color: Colors.white),
                    ),
                  Text(
                    cleanExplanation,
                    style: const TextStyle(fontSize: 12, color: Colors.white70),
                    maxLines: 3,
                    overflow: TextOverflow.ellipsis,
                  ),
                ],
              ),
            ),
          ],
        ),
        action: onRetry != null
            ? SnackBarAction(
                label: suggestedAction ?? 'Retry',
                textColor: Colors.amberAccent,
                onPressed: onRetry,
              )
            : null,
      ),
    );
  }

  void _showSuccessBanner(String message, {String? title, IconData? icon}) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).hideCurrentSnackBar();
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        behavior: SnackBarBehavior.floating,
        margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        backgroundColor: const Color(0xFF0D2017),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(12),
          side: BorderSide(color: Colors.greenAccent.withValues(alpha: 0.6), width: 1.5),
        ),
        duration: const Duration(seconds: 4),
        content: Row(
          children: [
            Container(
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(
                color: Colors.greenAccent.withValues(alpha: 0.2),
                shape: BoxShape.circle,
              ),
              child: Icon(icon ?? Icons.check_circle_outline_rounded, color: Colors.greenAccent, size: 20),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (title != null && title.isNotEmpty)
                    Text(
                      title,
                      style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 13, color: Colors.white),
                    ),
                  Text(
                    message,
                    style: const TextStyle(fontSize: 12, color: Colors.white70),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  void _scrollLog() {
    _scrollDebounceTimer?.cancel();
    _scrollDebounceTimer = Timer(const Duration(milliseconds: 100), () {
      if (mounted && logScrollController.hasClients) {
        logScrollController.jumpTo(logScrollController.position.maxScrollExtent);
      }
    });
  }

  @override
  void dispose() {
    _scrollDebounceTimer?.cancel();
    eventSub?.cancel();
    ussdSub?.cancel();
    notifSub?.cancel();
    simSub?.cancel();
    callLogSub?.cancel();
    devicePoll?.cancel();
    callTimer?.cancel();
    _tabController.dispose();
    dialerNumberController.dispose();
    smsRecipientController.dispose();
    smsBodyController.dispose();
    contactNameController.dispose();
    contactNumberController.dispose();
    contactSearchController.dispose();
    ussdCodeController.dispose();
    ussdReplyController.dispose();
    pushTitleController.dispose();
    pushBodyController.dispose();
    btRenameController.dispose();
    terminal.dispose();
    logScrollController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final isConnected = status == 'Connected';

    return Scaffold(
      appBar: AppBar(
        titleSpacing: 16,
        title: const LogoBadge(size: 32, withTitle: true, spacing: 10),
        bottom: TabBar(
          controller: _tabController,
          tabs: const [
            Tab(icon: Icon(Icons.dashboard_customize_outlined, size: 18), text: 'Dashboard & Connection'),
            Tab(icon: Icon(Icons.phone_in_talk_outlined, size: 18), text: 'Phone & Contacts'),
            Tab(icon: Icon(Icons.chat_bubble_outline, size: 18), text: 'Messages'),
          ],
        ),
        actions: [
          // 2-Way Link Status Pill
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
            decoration: BoxDecoration(
              color: isConnected
                  ? Colors.green.withValues(alpha: 0.15)
                  : Colors.grey.withValues(alpha: 0.12),
              borderRadius: BorderRadius.circular(999),
              border: Border.all(
                color: isConnected ? Colors.greenAccent : Colors.grey.shade700,
                width: 1.2,
              ),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  isConnected ? Icons.sensors : Icons.sensors_off,
                  size: 14,
                  color: isConnected ? Colors.greenAccent : Colors.grey,
                ),
                const SizedBox(width: 6),
                Text(
                  isConnected ? '2-WAY ACTIVE (${service.pingMs}ms)' : 'DISCONNECTED',
                  style: TextStyle(
                    fontWeight: FontWeight.w800,
                    fontSize: 10,
                    color: isConnected ? Colors.greenAccent : Colors.grey.shade400,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 8),

          // Number of SIMs Live Indicator Badge
          if (isConnected) ...[
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
              decoration: BoxDecoration(
                color: Colors.orange.withValues(alpha: 0.15),
                borderRadius: BorderRadius.circular(999),
                border: Border.all(
                  color: Colors.orangeAccent.withValues(alpha: 0.6),
                  width: 1.2,
                ),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Icon(Icons.sim_card, size: 14, color: Colors.orangeAccent),
                  const SizedBox(width: 6),
                  Text(
                    '${service.simSlotCount} SIMs (Active: SIM $selectedSimSlot)',
                    style: const TextStyle(
                      fontWeight: FontWeight.w800,
                      fontSize: 10,
                      color: Colors.orangeAccent,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 8),
          ],

          // Refresh / Sync Button
          FilledButton.tonalIcon(
            onPressed: isConnected
                ? (_syncingAll ? null : () => _syncAllOldData())
                : _refresh,
            icon: _syncingAll
                ? const SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2))
                : const Icon(Icons.sync, size: 16),
            label: Text(_syncingAll ? 'Syncing…' : (isConnected ? 'Sync Old Msg & Call (${service.simSlotCount} SIMs)' : 'Scan')),
          ),
          const SizedBox(width: 12),
        ],
      ),
      body: Column(
        children: [
          // High-Priority Incoming Call Banner
          if (isIncomingCallActive) _incomingCallBanner(scheme),
          Expanded(
            child: TabBarView(
              controller: _tabController,
              children: [
                _dashboardAndConnectionView(scheme, isConnected),
                _phoneUssdContactsView(scheme, isConnected),
                _messagesView(scheme, isConnected),
              ],
            ),
          ),
        ],
      ),
    );
  }

  // -------------------------------------------------------------
  // INCOMING CALL BANNER (2-Way Live Phone-to-Mac Alert)
  // -------------------------------------------------------------
  Widget _incomingCallBanner(ColorScheme scheme) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
      decoration: BoxDecoration(
        color: Colors.green.shade900.withValues(alpha: 0.8),
        border: const Border(bottom: BorderSide(color: Colors.greenAccent, width: 2)),
      ),
      child: LayoutBuilder(
        builder: (context, constraints) {
          final isNarrow = constraints.maxWidth < 600;
          return isNarrow
              ? Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Row(
                      children: [
                        const Icon(Icons.phone_in_talk, color: Colors.greenAccent, size: 28),
                        const SizedBox(width: 14),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Text(
                                incomingCallerName.isNotEmpty
                                    ? 'INCOMING CALL: $incomingCallerName'
                                    : 'INCOMING CALL',
                                style: const TextStyle(fontWeight: FontWeight.w900, fontSize: 15, color: Colors.white),
                                overflow: TextOverflow.ellipsis,
                              ),
                              Text(
                                incomingCallerNumber,
                                style: const TextStyle(color: Colors.white70, fontSize: 13),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 10),
                    Wrap(
                      spacing: 10,
                      alignment: WrapAlignment.end,
                      children: [
                        FilledButton.icon(
                          onPressed: _answer,
                          icon: const Icon(Icons.call, size: 18),
                          label: const Text('Answer on Phone'),
                          style: FilledButton.styleFrom(backgroundColor: Colors.greenAccent.shade700, foregroundColor: Colors.black),
                        ),
                        FilledButton.tonalIcon(
                          onPressed: _hangup,
                          icon: const Icon(Icons.call_end, size: 18),
                          label: const Text('Reject Call'),
                          style: FilledButton.styleFrom(backgroundColor: Colors.red.withValues(alpha: 0.2), foregroundColor: Colors.white),
                        ),
                      ],
                    ),
                  ],
                )
              : Row(
                  children: [
                    const Icon(Icons.phone_in_talk, color: Colors.greenAccent, size: 28),
                    const SizedBox(width: 14),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(
                            incomingCallerName.isNotEmpty
                                ? 'INCOMING CALL: $incomingCallerName'
                                : 'INCOMING CALL',
                            style: const TextStyle(fontWeight: FontWeight.w900, fontSize: 15, color: Colors.white),
                            overflow: TextOverflow.ellipsis,
                          ),
                          Text(
                            incomingCallerNumber,
                            style: const TextStyle(color: Colors.white70, fontSize: 13),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(width: 12),
                    Wrap(
                      spacing: 10,
                      children: [
                        FilledButton.icon(
                          onPressed: _answer,
                          icon: const Icon(Icons.call, size: 18),
                          label: const Text('Answer on Phone'),
                          style: FilledButton.styleFrom(backgroundColor: Colors.greenAccent.shade700, foregroundColor: Colors.black),
                        ),
                        FilledButton.tonalIcon(
                          onPressed: _hangup,
                          icon: const Icon(Icons.call_end, size: 18),
                          label: const Text('Reject Call'),
                          style: FilledButton.styleFrom(backgroundColor: Colors.red.withValues(alpha: 0.2), foregroundColor: Colors.white),
                        ),
                      ],
                    ),
                  ],
                );
        },
      ),
    );
  }

  // -------------------------------------------------------------
  // TAB 1: DASHBOARD & CONNECTION MASTER HUB
  // -------------------------------------------------------------
  Widget _dashboardAndConnectionView(ColorScheme scheme, bool isConnected) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // 1. TOP QUICK CONNECTION & LINK STATUS HERO BAR
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
          decoration: BoxDecoration(
            color: scheme.surfaceContainerHighest.withValues(alpha: 0.35),
            border: Border(bottom: BorderSide(color: scheme.outlineVariant.withValues(alpha: 0.5))),
          ),
          child: Wrap(
            alignment: WrapAlignment.spaceBetween,
            crossAxisAlignment: WrapCrossAlignment.center,
            spacing: 12,
            runSpacing: 8,
            children: [
              Wrap(
                crossAxisAlignment: WrapCrossAlignment.center,
                spacing: 10,
                runSpacing: 6,
                children: [
                  Container(
                    width: 10,
                    height: 10,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: isConnected ? Colors.greenAccent : Colors.redAccent,
                      boxShadow: isConnected
                          ? [BoxShadow(color: Colors.greenAccent.withValues(alpha: 0.6), blurRadius: 6)]
                          : null,
                    ),
                  ),
                  Text(
                    isConnected ? 'LINKED: $phoneModel' : 'OFFLINE',
                    style: const TextStyle(fontWeight: FontWeight.w900, fontSize: 13, letterSpacing: 0.5),
                  ),
                  if (isConnected)
                    Text(
                      '($connectedPath • $baud baud)',
                      style: const TextStyle(fontFamily: 'monospace', fontSize: 11, color: Colors.grey),
                    ),
                  _telemetryBadge('Ping', isConnected ? '${service.pingMs} ms' : '—', Colors.greenAccent),
                ],
              ),
              Wrap(
                crossAxisAlignment: WrapCrossAlignment.center,
                spacing: 8,
                runSpacing: 6,
                children: [
                  if (isConnected) ...[
                    FilledButton.tonalIcon(
                      onPressed: busy ? null : _disconnect,
                      icon: const Icon(Icons.link_off, size: 16),
                      label: const Text('Disconnect'),
                      style: FilledButton.styleFrom(
                        backgroundColor: Colors.red.withValues(alpha: 0.15),
                        foregroundColor: Colors.redAccent,
                      ),
                    ),
                  ] else ...[
                    if (devices.isNotEmpty)
                      Container(
                        height: 36,
                        padding: const EdgeInsets.symmetric(horizontal: 8),
                        decoration: BoxDecoration(
                          borderRadius: BorderRadius.circular(8),
                          border: Border.all(color: scheme.outlineVariant),
                        ),
                        child: DropdownButtonHideUnderline(
                          child: DropdownButton<String>(
                            value: devices.any((d) => d.path == connectedPath)
                                ? connectedPath
                                : devices.first.path,
                            hint: const Text('Select Port', style: TextStyle(fontSize: 12)),
                            style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold, color: scheme.onSurface),
                            items: devices.map((d) {
                              return DropdownMenuItem(
                                value: d.path,
                                child: Row(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    Icon(d.usb ? Icons.usb : Icons.bluetooth, size: 14),
                                    const SizedBox(width: 6),
                                    Text(d.name, overflow: TextOverflow.ellipsis),
                                  ],
                                ),
                              );
                            }).toList(),
                            onChanged: (p) {
                              final match = devices.where((d) => d.path == p);
                              if (match.isNotEmpty) {
                                _connectToDevice(match.first);
                              }
                            },
                          ),
                        ),
                      ),
                    FilledButton.icon(
                      onPressed: busy || devices.isEmpty ? null : () => _connectToDevice(devices.first),
                      icon: const Icon(Icons.link, size: 16),
                      label: const Text('Quick Connect'),
                    ),
                    OutlinedButton.icon(
                      onPressed: (_scanning || busy) ? null : _scan,
                      icon: const Icon(Icons.radar, size: 16),
                      label: const Text('Scan'),
                    ),
                  ],
                ],
              ),
            ],
          ),
        ),

        // 2. SUB-NAVIGATION SEGMENTED SWITCHER
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          child: SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: SegmentedButton<int>(
              segments: [
                const ButtonSegment<int>(
                  value: 0,
                  label: Text('Overview & Telemetry'),
                  icon: Icon(Icons.analytics_outlined, size: 16),
                ),
                ButtonSegment<int>(
                  value: 1,
                  label: Text('Serial Ports (${devices.length})'),
                  icon: const Icon(Icons.usb, size: 16),
                ),
                ButtonSegment<int>(
                  value: 2,
                  label: Text('Bluetooth & Eject (${btDevices.length})'),
                  icon: const Icon(Icons.bluetooth, size: 16),
                ),
                const ButtonSegment<int>(
                  value: 3,
                  label: Text('AT Terminal & Logs'),
                  icon: Icon(Icons.terminal_outlined, size: 16),
                ),
              ],
              selected: {dashboardSubTab.clamp(0, 3)},
              onSelectionChanged: (set) => setState(() => dashboardSubTab = set.first),
            ),
          ),
        ),

        // 3. ACTIVE SUB-VIEW CONTENT
        Expanded(
          child: IndexedStack(
            index: dashboardSubTab.clamp(0, 3),
            children: [
              _dashboardOverviewSubView(scheme, isConnected),
              _connectionsView(scheme, isConnected),
              _bluetoothManagerView(scheme, isConnected),
              Padding(padding: const EdgeInsets.all(18), child: _consolePanel(scheme, isConnected)),
            ],
          ),
        ),
      ],
    );
  }

  Widget _dashboardOverviewSubView(ColorScheme scheme, bool isConnected) {
    return SingleChildScrollView(
      padding: const EdgeInsets.all(18),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // Hero Phone Card
          Card(
            child: Padding(
              padding: const EdgeInsets.all(20),
              child: Row(
                children: [
                  Container(
                    width: 60,
                    height: 60,
                    decoration: BoxDecoration(
                      color: scheme.primary.withValues(alpha: 0.15),
                      borderRadius: BorderRadius.circular(16),
                      border: Border.all(color: scheme.primary.withValues(alpha: 0.3)),
                    ),
                    child: Icon(
                      isConnected ? Icons.smartphone : Icons.phone_disabled,
                      size: 32,
                      color: isConnected ? scheme.primary : Colors.grey,
                    ),
                  ),
                  const SizedBox(width: 16),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Wrap(
                          crossAxisAlignment: WrapCrossAlignment.center,
                          spacing: 10,
                          runSpacing: 4,
                          children: [
                            Text(
                              isConnected ? phoneModel : 'No Mobile Phone Linked',
                              style: Theme.of(context).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w900),
                            ),
                            Container(
                              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                              decoration: BoxDecoration(
                                color: isConnected
                                    ? Colors.green.withValues(alpha: 0.15)
                                    : Colors.grey.withValues(alpha: 0.15),
                                borderRadius: BorderRadius.circular(6),
                              ),
                              child: Text(
                                isConnected ? '2-WAY FULL DUPLEX' : 'OFFLINE',
                                style: TextStyle(
                                  fontSize: 10,
                                  fontWeight: FontWeight.bold,
                                  color: isConnected ? Colors.greenAccent : Colors.grey,
                                ),
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 4),
                        Text(
                          isConnected
                              ? '$phoneManufacturer • Port: $connectedPath'
                              : 'Select a serial port in the Serial Ports tab to connect to your phone.',
                          style: TextStyle(fontSize: 13, color: scheme.onSurface.withValues(alpha: 0.6)),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 16),

          // 2-Way Connection Telemetry Bar (Responsive Wrap)
          Card(
            color: scheme.surfaceContainerHighest.withValues(alpha: 0.25),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
              child: Wrap(
                crossAxisAlignment: WrapCrossAlignment.center,
                alignment: WrapAlignment.spaceBetween,
                spacing: 12,
                runSpacing: 10,
                children: [
                  Wrap(
                    crossAxisAlignment: WrapCrossAlignment.center,
                    spacing: 10,
                    runSpacing: 8,
                    children: [
                      const Icon(Icons.analytics_outlined, size: 20, color: Colors.cyanAccent),
                      const Text('2-Way Telemetry:', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13)),
                      _telemetryBadge('Ping', isConnected ? '${service.pingMs} ms' : '—', Colors.greenAccent),
                      _telemetryBadge('Tx', '${service.txPackets} pkts (${(service.txBytes / 1024).toStringAsFixed(1)} KB)', Colors.blueAccent),
                      _telemetryBadge('Rx', '${service.rxPackets} pkts (${(service.rxBytes / 1024).toStringAsFixed(1)} KB)', Colors.amberAccent),
                    ],
                  ),
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Text('Auto-Reconnect: ', style: TextStyle(fontSize: 12)),
                      Switch(
                        value: service.autoConnect,
                        onChanged: (v) => setState(() => service.setAutoConnect(v)),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 16),

          // Responsive Metric Cards Grid
          LayoutBuilder(
            builder: (context, constraints) {
              final w = constraints.maxWidth;
              if (w > 800) {
                return Row(
                  children: [
                    Expanded(child: _metricCard(icon: Icons.battery_charging_full, title: 'Battery', value: isConnected ? '$batteryLevel%' : '—', sub: isCharging ? 'Charging via USB' : 'Battery Level', color: Colors.amberAccent, scheme: scheme)),
                    const SizedBox(width: 12),
                    Expanded(child: _metricCard(icon: Icons.signal_cellular_alt, title: 'Cellular Signal', value: isConnected ? '${(signalLevel / 31 * 100).toInt()}%' : '—', sub: operatorName ?? 'Network Provider', color: Colors.greenAccent, scheme: scheme)),
                    const SizedBox(width: 12),
                    Expanded(child: _metricCard(icon: Icons.message, title: 'Messages', value: isConnected ? '${messages.length}' : '—', sub: '${messages.where((m) => m.isUnread).length} unread', color: Colors.cyanAccent, scheme: scheme)),
                    const SizedBox(width: 12),
                    Expanded(child: _metricCard(icon: Icons.bluetooth, title: 'Bluetooth', value: isConnected ? (btPowerOn ? 'ON' : 'OFF') : '—', sub: '${btDevices.length} BT Devices', color: Colors.blueAccent, scheme: scheme)),
                  ],
                );
              } else if (w > 480) {
                return Column(
                  children: [
                    Row(
                      children: [
                        Expanded(child: _metricCard(icon: Icons.battery_charging_full, title: 'Battery', value: isConnected ? '$batteryLevel%' : '—', sub: isCharging ? 'Charging via USB' : 'Battery Level', color: Colors.amberAccent, scheme: scheme)),
                        const SizedBox(width: 12),
                        Expanded(child: _metricCard(icon: Icons.signal_cellular_alt, title: 'Cellular Signal', value: isConnected ? '${(signalLevel / 31 * 100).toInt()}%' : '—', sub: operatorName ?? 'Network Provider', color: Colors.greenAccent, scheme: scheme)),
                      ],
                    ),
                    const SizedBox(height: 12),
                    Row(
                      children: [
                        Expanded(child: _metricCard(icon: Icons.message, title: 'Messages', value: isConnected ? '${messages.length}' : '—', sub: '${messages.where((m) => m.isUnread).length} unread', color: Colors.cyanAccent, scheme: scheme)),
                        const SizedBox(width: 12),
                        Expanded(child: _metricCard(icon: Icons.bluetooth, title: 'Bluetooth', value: isConnected ? (btPowerOn ? 'ON' : 'OFF') : '—', sub: '${btDevices.length} BT Devices', color: Colors.blueAccent, scheme: scheme)),
                      ],
                    ),
                  ],
                );
              } else {
                return Column(
                  children: [
                    _metricCard(icon: Icons.battery_charging_full, title: 'Battery', value: isConnected ? '$batteryLevel%' : '—', sub: isCharging ? 'Charging via USB' : 'Battery Level', color: Colors.amberAccent, scheme: scheme),
                    const SizedBox(height: 10),
                    _metricCard(icon: Icons.signal_cellular_alt, title: 'Cellular Signal', value: isConnected ? '${(signalLevel / 31 * 100).toInt()}%' : '—', sub: operatorName ?? 'Network Provider', color: Colors.greenAccent, scheme: scheme),
                    const SizedBox(height: 10),
                    _metricCard(icon: Icons.message, title: 'Messages', value: isConnected ? '${messages.length}' : '—', sub: '${messages.where((m) => m.isUnread).length} unread', color: Colors.cyanAccent, scheme: scheme),
                    const SizedBox(height: 10),
                    _metricCard(icon: Icons.bluetooth, title: 'Bluetooth', value: isConnected ? (btPowerOn ? 'ON' : 'OFF') : '—', sub: '${btDevices.length} BT Devices', color: Colors.blueAccent, scheme: scheme),
                  ],
                );
              }
            },
          ),
          const SizedBox(height: 16),

          // Cellular Multi-SIM Slots Management
          _multiSimManagerCard(scheme, isConnected),
          const SizedBox(height: 16),

          // Audio Profiles & Quick Actions
          Card(
            child: Padding(
              padding: const EdgeInsets.all(18),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text('PHONE SETTINGS & AUDIO PROFILES', style: TextStyle(fontWeight: FontWeight.bold)),
                  const SizedBox(height: 14),
                  Row(
                    children: [
                      const Icon(Icons.volume_up, size: 20),
                      const SizedBox(width: 10),
                      const Text('Call Volume:'),
                      Expanded(
                        child: Slider(
                          value: volumeLevel.toDouble(),
                          min: 0,
                          max: 7,
                          divisions: 7,
                          label: 'Vol $volumeLevel',
                          onChanged: isConnected
                              ? (v) {
                                  setState(() => volumeLevel = v.round());
                                  service.setVolume(volumeLevel);
                                }
                              : null,
                        ),
                      ),
                      Text('$volumeLevel/7', style: const TextStyle(fontWeight: FontWeight.bold)),
                    ],
                  ),
                  const SizedBox(height: 10),
                  Wrap(
                    spacing: 10,
                    runSpacing: 10,
                    children: [
                      FilledButton.tonalIcon(
                        onPressed: isConnected
                            ? () {
                                setState(() => micMuted = !micMuted);
                                service.setMute(micMuted);
                              }
                            : null,
                        icon: Icon(micMuted ? Icons.mic_off : Icons.mic),
                        label: Text(micMuted ? 'Mic Muted (Unmute)' : 'Mute Mic'),
                      ),
                      OutlinedButton.icon(
                        onPressed: isConnected
                            ? () {
                                setState(() => alertProfile = 0);
                                service.setAlertMode(0);
                              }
                            : null,
                        icon: const Icon(Icons.notifications_active),
                        label: const Text('Normal Alert'),
                      ),
                      OutlinedButton.icon(
                        onPressed: isConnected
                            ? () {
                                setState(() => alertProfile = 1);
                                service.setAlertMode(1);
                              }
                            : null,
                        icon: const Icon(Icons.notifications_off),
                        label: const Text('Silent Mode'),
                      ),
                      OutlinedButton.icon(
                        onPressed: isConnected
                            ? () {
                                setState(() => alertProfile = 2);
                                service.setAlertMode(2);
                              }
                            : null,
                        icon: const Icon(Icons.vibration),
                        label: const Text('Vibrate Mode'),
                      ),
                      FilledButton.tonalIcon(
                        onPressed: isConnected
                            ? () {
                                setState(() => btPowerOn = !btPowerOn);
                                service.btPower(btPowerOn);
                              }
                            : null,
                        icon: Icon(btPowerOn ? Icons.bluetooth_disabled : Icons.bluetooth),
                        label: Text(btPowerOn ? 'Disable Phone BT' : 'Enable Phone BT'),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 16),

          // Quick System Hub Shortcuts
          Card(
            color: scheme.surfaceContainerHighest.withValues(alpha: 0.2),
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text('CONNECTION & DEVICE HUB SHORTCUTS', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 12)),
                  const SizedBox(height: 10),
                  Wrap(
                    spacing: 10,
                    runSpacing: 10,
                    children: [
                      FilledButton.tonalIcon(
                        onPressed: () => setState(() => dashboardSubTab = 1),
                        icon: const Icon(Icons.usb, size: 16),
                        label: Text('Serial Ports (${devices.length})'),
                      ),
                      FilledButton.tonalIcon(
                        onPressed: () => setState(() => dashboardSubTab = 2),
                        icon: const Icon(Icons.bluetooth, size: 16),
                        label: Text('Bluetooth & Eject (${btDevices.length})'),
                      ),
                      FilledButton.tonalIcon(
                        onPressed: () => setState(() => dashboardSubTab = 3),
                        icon: const Icon(Icons.notifications_active_outlined, size: 16),
                        label: const Text('BT Push Notifier'),
                      ),
                      FilledButton.tonalIcon(
                        onPressed: () => setState(() => dashboardSubTab = 4),
                        icon: const Icon(Icons.terminal, size: 16),
                        label: const Text('AT Terminal & Raw Logs'),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _telemetryBadge(String label, String value, Color color) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: color.withValues(alpha: 0.3)),
      ),
      child: Text(
        '$label: $value',
        style: TextStyle(fontSize: 11, fontWeight: FontWeight.bold, color: color),
      ),
    );
  }

  Widget _metricCard({
    required IconData icon,
    required String title,
    required String value,
    required String sub,
    required Color color,
    required ColorScheme scheme,
  }) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(icon, size: 20, color: color),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    title,
                    style: TextStyle(fontSize: 12, color: scheme.onSurface.withValues(alpha: 0.6)),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Text(value, style: TextStyle(fontSize: 20, fontWeight: FontWeight.w900, color: color)),
            const SizedBox(height: 4),
            Text(sub, style: TextStyle(fontSize: 11, color: scheme.onSurface.withValues(alpha: 0.5)), overflow: TextOverflow.ellipsis),
          ],
        ),
      ),
    );
  }

  Widget _multiSimManagerCard(ColorScheme scheme, bool isConnected) {
    final count = service.simSlotCount;
    final activeSlot = service.activeSimSlot;

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(18),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Wrap(
              alignment: WrapAlignment.spaceBetween,
              crossAxisAlignment: WrapCrossAlignment.center,
              spacing: 12,
              runSpacing: 10,
              children: [
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Icon(Icons.sim_card, size: 22, color: Colors.orangeAccent),
                    const SizedBox(width: 10),
                    Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text(
                          'CELLULAR SIM CARDS & MULTI-SIM SLOTS',
                          style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13),
                        ),
                        Text(
                          'Active SIM Slot: SIM $activeSlot | Total Slots: $count (${count == 1 ? "Single SIM" : count == 2 ? "Dual SIM" : count == 3 ? "Triple SIM" : "Quad SIM"})',
                          style: TextStyle(fontSize: 11, color: scheme.onSurface.withValues(alpha: 0.6)),
                        ),
                      ],
                    ),
                  ],
                ),
                Wrap(
                  spacing: 8,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    Text('Slots:', style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: scheme.onSurface.withValues(alpha: 0.8))),
                    DropdownButton<int>(
                      value: count,
                      isDense: true,
                      underline: const SizedBox(),
                      items: const [
                        DropdownMenuItem(value: 1, child: Text('1 SIM (Single)')),
                        DropdownMenuItem(value: 2, child: Text('2 SIMs (Dual)')),
                        DropdownMenuItem(value: 3, child: Text('3 SIMs (Triple)')),
                        DropdownMenuItem(value: 4, child: Text('4 SIMs (Quad)')),
                      ],
                      onChanged: (v) {
                        if (v != null) {
                          setState(() => service.setSimSlotCount(v));
                        }
                      },
                    ),
                    IconButton.filledTonal(
                      icon: const Icon(Icons.refresh, size: 16),
                      tooltip: 'Probe SIM Status',
                      onPressed: isConnected ? () => service.detectSimCards() : null,
                    ),
                  ],
                ),
              ],
            ),
            const SizedBox(height: 14),
            LayoutBuilder(
              builder: (context, constraints) {
                final isWide = constraints.maxWidth > 550;
                final items = List.generate(count, (i) {
                  final slot = i + 1;
                  final sim = simCards.length >= slot
                      ? simCards[slot - 1]
                      : SimCard(slotIndex: slot, label: 'SIM $slot', isActive: slot == activeSlot);
                  final isActive = slot == activeSlot;

                  return Container(
                    padding: const EdgeInsets.all(14),
                    decoration: BoxDecoration(
                      color: isActive
                          ? scheme.primaryContainer.withValues(alpha: 0.25)
                          : scheme.surfaceContainerHighest.withValues(alpha: 0.3),
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(
                        color: isActive ? scheme.primary.withValues(alpha: 0.6) : scheme.outline.withValues(alpha: 0.15),
                        width: isActive ? 1.5 : 1.0,
                      ),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                          children: [
                            Row(
                              children: [
                                Icon(Icons.sim_card_outlined, size: 18, color: isActive ? scheme.primary : Colors.grey),
                                const SizedBox(width: 6),
                                Text(
                                  'SIM $slot',
                                  style: TextStyle(
                                    fontWeight: FontWeight.bold,
                                    fontSize: 14,
                                    color: isActive ? scheme.primary : scheme.onSurface,
                                  ),
                                ),
                              ],
                            ),
                            Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                IconButton(
                                  icon: const Icon(Icons.edit_note_rounded, size: 18),
                                  tooltip: 'Edit SIM Details (Company & Number)',
                                  padding: EdgeInsets.zero,
                                  constraints: const BoxConstraints(),
                                  onPressed: () => _showEditSimDialog(sim),
                                ),
                                const SizedBox(width: 8),
                                Container(
                                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                                  decoration: BoxDecoration(
                                    color: isActive ? Colors.green.withValues(alpha: 0.2) : Colors.grey.withValues(alpha: 0.15),
                                    borderRadius: BorderRadius.circular(6),
                                  ),
                                  child: Text(
                                    isActive ? 'ACTIVE DEFAULT' : 'STANDBY',
                                    style: TextStyle(
                                      fontSize: 10,
                                      fontWeight: FontWeight.bold,
                                      color: isActive ? Colors.greenAccent : Colors.grey,
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          ],
                        ),
                        const SizedBox(height: 8),
                        // Carrier / Company Name
                        Row(
                          children: [
                            const Icon(Icons.business_rounded, size: 14, color: Colors.cyanAccent),
                            const SizedBox(width: 6),
                            Expanded(
                              child: Text(
                                sim.operatorName,
                                style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 13),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 4),
                        // Phone Number
                        InkWell(
                          onTap: () => _showEditSimDialog(sim),
                          borderRadius: BorderRadius.circular(4),
                          child: Padding(
                            padding: const EdgeInsets.symmetric(vertical: 2),
                            child: Row(
                              children: [
                                Icon(
                                  Icons.phone_android_rounded,
                                  size: 14,
                                  color: sim.phoneNumber != null && sim.phoneNumber!.isNotEmpty ? Colors.greenAccent : Colors.grey,
                                ),
                                const SizedBox(width: 6),
                                Expanded(
                                  child: Text(
                                    sim.phoneNumber != null && sim.phoneNumber!.isNotEmpty
                                        ? sim.phoneNumber!
                                        : 'No number set (Tap to add)',
                                    style: TextStyle(
                                      fontSize: 12,
                                      fontWeight: sim.phoneNumber != null && sim.phoneNumber!.isNotEmpty ? FontWeight.w600 : FontWeight.normal,
                                      fontStyle: sim.phoneNumber != null && sim.phoneNumber!.isNotEmpty ? FontStyle.normal : FontStyle.italic,
                                      color: sim.phoneNumber != null && sim.phoneNumber!.isNotEmpty ? scheme.onSurface : scheme.onSurface.withValues(alpha: 0.5),
                                    ),
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          sim.status.label,
                          style: TextStyle(fontSize: 11, color: scheme.onSurface.withValues(alpha: 0.6)),
                        ),
                        const SizedBox(height: 8),
                        Row(
                          children: [
                            Icon(Icons.signal_cellular_alt, size: 14, color: isActive ? Colors.greenAccent : Colors.grey),
                            const SizedBox(width: 6),
                            Expanded(
                              child: LinearProgressIndicator(
                                value: (sim.signalLevel / 31).clamp(0.0, 1.0),
                                backgroundColor: scheme.outline.withValues(alpha: 0.1),
                                valueColor: AlwaysStoppedAnimation<Color>(
                                  isActive ? Colors.greenAccent : scheme.primary.withValues(alpha: 0.5),
                                ),
                              ),
                            ),
                            const SizedBox(width: 8),
                            Text(
                              '${sim.signalPercent}%',
                              style: const TextStyle(fontSize: 11, fontWeight: FontWeight.bold),
                            ),
                          ],
                        ),
                        const SizedBox(height: 10),
                        SizedBox(
                          width: double.infinity,
                          child: OutlinedButton.icon(
                            style: OutlinedButton.styleFrom(
                              padding: const EdgeInsets.symmetric(vertical: 6),
                              side: BorderSide(color: isActive ? Colors.green.withValues(alpha: 0.5) : scheme.outline.withValues(alpha: 0.3)),
                            ),
                            onPressed: isConnected
                                ? () {
                                    setState(() {
                                      selectedSimSlot = slot;
                                      service.setActiveSim(slot);
                                    });
                                  }
                                : null,
                            icon: Icon(isActive ? Icons.check_circle : Icons.radio_button_unchecked, size: 14, color: isActive ? Colors.greenAccent : null),
                            label: Text(isActive ? 'Active for Calls/SMS' : 'Switch to SIM $slot', style: const TextStyle(fontSize: 11)),
                          ),
                        ),
                      ],
                    ),
                  );
                });

                if (isWide && count > 1) {
                  return Row(
                    children: items.map((w) => Expanded(child: Padding(padding: const EdgeInsets.symmetric(horizontal: 4), child: w))).toList(),
                  );
                } else {
                  return Column(
                    children: items.map((w) => Padding(padding: const EdgeInsets.only(bottom: 8), child: w)).toList(),
                  );
                }
              },
            ),
            const Divider(height: 24),
            Wrap(
              alignment: WrapAlignment.spaceBetween,
              crossAxisAlignment: WrapCrossAlignment.center,
              spacing: 12,
              runSpacing: 8,
              children: [
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Icon(Icons.storage, size: 16, color: Colors.cyanAccent),
                    const SizedBox(width: 6),
                    Text(
                      'Synced Data: ${messages.length} SMS • ${callLogs.length} Call Logs across ${service.simSlotCount} SIMs',
                      style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold, color: scheme.onSurface.withValues(alpha: 0.75)),
                    ),
                  ],
                ),
                FilledButton.icon(
                  style: FilledButton.styleFrom(
                    padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                  ),
                  onPressed: isConnected && !_syncingAll ? () => _syncAllOldData() : null,
                  icon: _syncingAll
                      ? const SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                      : const Icon(Icons.sync_alt, size: 16),
                  label: Text(_syncingAll ? 'Syncing All SIMs…' : 'Sync Old SMS & Calls from All SIMs', style: const TextStyle(fontSize: 12)),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  // -------------------------------------------------------------
  // TAB 2: ANDROID PHONE DIALER, RECENTS & CONTACTS
  // -------------------------------------------------------------
  Widget _phoneUssdContactsView(ColorScheme scheme, bool isConnected) {
    // 0: Keypad, 1: Recents, 2: Contacts
    return LayoutBuilder(
      builder: (context, constraints) {
        final isWide = constraints.maxWidth >= 960;

        return Column(
          children: [
            // Top Android Navigation Bar
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
              decoration: BoxDecoration(
                color: scheme.surface,
                border: Border(bottom: BorderSide(color: scheme.outlineVariant.withValues(alpha: 0.3))),
              ),
              child: Row(
                children: [
                  Expanded(
                    child: SegmentedButton<int>(
                      style: SegmentedButton.styleFrom(
                        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                      ),
                      segments: [
                        const ButtonSegment<int>(
                          value: 0,
                          icon: Icon(Icons.dialpad_rounded, size: 18),
                          label: Text('Keypad', style: TextStyle(fontWeight: FontWeight.bold)),
                        ),
                        ButtonSegment<int>(
                          value: 1,
                          icon: const Icon(Icons.history_rounded, size: 18),
                          label: Text(
                            callLogs.isNotEmpty ? 'Recents (${callLogs.length})' : 'Recents',
                            style: const TextStyle(fontWeight: FontWeight.bold),
                          ),
                        ),
                        ButtonSegment<int>(
                          value: 2,
                          icon: const Icon(Icons.people_alt_rounded, size: 18),
                          label: Text(
                            contacts.isNotEmpty ? 'Contacts (${contacts.length})' : 'Contacts',
                            style: const TextStyle(fontWeight: FontWeight.bold),
                          ),
                        ),
                      ],
                      selected: {phoneHubSubTab},
                      onSelectionChanged: (set) {
                        setState(() => phoneHubSubTab = set.first);
                      },
                    ),
                  ),
                ],
              ),
            ),

            // Main Body Area
            Expanded(
              child: isWide
                  ? Row(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        // Left Pane: Recents or Contacts list
                        Expanded(
                          flex: 5,
                          child: phoneHubSubTab == 2
                              ? _buildAndroidContactsList(scheme, isConnected)
                              : _buildAndroidRecentsList(scheme, isConnected),
                        ),
                        VerticalDivider(width: 1, color: scheme.outlineVariant.withValues(alpha: 0.3)),
                        // Right Pane: Android Dialpad Phone Card
                        Expanded(
                          flex: 6,
                          child: Center(
                            child: SingleChildScrollView(
                              padding: const EdgeInsets.all(24),
                              child: ConstrainedBox(
                                constraints: const BoxConstraints(maxWidth: 400),
                                child: _buildAndroidDialpadCard(scheme, isConnected),
                              ),
                            ),
                          ),
                        ),
                      ],
                    )
                  : (phoneHubSubTab == 0
                      ? Center(
                          child: SingleChildScrollView(
                            padding: const EdgeInsets.all(16),
                            child: ConstrainedBox(
                              constraints: const BoxConstraints(maxWidth: 400),
                              child: _buildAndroidDialpadCard(scheme, isConnected),
                            ),
                          ),
                        )
                      : (phoneHubSubTab == 1
                          ? _buildAndroidRecentsList(scheme, isConnected)
                          : _buildAndroidContactsList(scheme, isConnected))),
            ),
          ],
        );
      },
    );
  }

  // -------------------------------------------------------------
  // ANDROID DIALPAD CARD
  // -------------------------------------------------------------
  Widget _buildAndroidDialpadCard(ColorScheme scheme, bool isConnected) {
    if (callState != 'IDLE') {
      return _buildInCallCard(scheme, isConnected);
    }

    // Match contact from digits
    PhoneContact? matchedContact;
    final digits = dialerNumberController.text.replaceAll(RegExp(r'\D'), '');
    if (digits.isNotEmpty) {
      for (final c in contacts) {
        final cDigits = c.number.replaceAll(RegExp(r'\D'), '');
        if (cDigits.endsWith(digits) || cDigits.contains(digits) || c.name.toLowerCase().contains(dialerNumberController.text.toLowerCase())) {
          matchedContact = c;
          break;
        }
      }
    }

    return Card(
      elevation: 3,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(28)),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // Matched Contact Preview (T9 Style)
            if (matchedContact != null)
              GestureDetector(
                onTap: () {
                  setState(() => dialerNumberController.text = matchedContact!.number);
                },
                child: Container(
                  margin: const EdgeInsets.only(bottom: 8),
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                  decoration: BoxDecoration(
                    color: scheme.primaryContainer.withValues(alpha: 0.3),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Icon(Icons.person_rounded, size: 16, color: scheme.primary),
                      const SizedBox(width: 6),
                      Text(
                        matchedContact.name,
                        style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13, color: scheme.primary),
                      ),
                      const SizedBox(width: 6),
                      Text(
                        '(${matchedContact.number})',
                        style: TextStyle(fontSize: 12, color: scheme.onSurface.withValues(alpha: 0.6)),
                      ),
                    ],
                  ),
                ),
              )
            else
              const SizedBox(height: 12),

            // Large Formatted Phone Number Display
            Container(
              alignment: Alignment.center,
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
              child: SelectableText(
                dialerNumberController.text.isEmpty ? ' ' : dialerNumberController.text,
                textAlign: TextAlign.center,
                style: const TextStyle(
                  fontSize: 32,
                  fontWeight: FontWeight.w600,
                  letterSpacing: 1.5,
                  fontFamily: 'monospace',
                ),
              ),
            ),
            const SizedBox(height: 16),

            // Android Dialpad 3x4 Grid
            _buildAndroidDialpadGrid(scheme, isConnected),
            const SizedBox(height: 20),

            // Bottom Call & Action Bar
            Wrap(
              alignment: WrapAlignment.center,
              crossAxisAlignment: WrapCrossAlignment.center,
              spacing: 12,
              runSpacing: 10,
              children: [
                // Empty placeholder or Add Contact button
                if (dialerNumberController.text.isNotEmpty && matchedContact == null)
                  IconButton(
                    icon: const Icon(Icons.person_add_outlined, size: 22),
                    tooltip: 'Add to contacts',
                    onPressed: () {
                      contactNumberController.text = dialerNumberController.text;
                      contactNameController.clear();
                      _showAddContactDialog();
                    },
                  ),

                // Call Button(s)
                if (service.simSlotCount > 1)
                  Wrap(
                    spacing: 8,
                    runSpacing: 6,
                    alignment: WrapAlignment.center,
                    children: List.generate(service.simSlotCount, (index) {
                      final slot = index + 1;
                      final sim = simCards.length >= slot ? simCards[slot - 1] : null;
                      final op = sim?.operatorName ?? 'SIM $slot';
                      final num = sim?.phoneNumber;

                      return FilledButton.icon(
                        style: FilledButton.styleFrom(
                          backgroundColor: slot == 1 ? Colors.green.shade700 : Colors.teal.shade700,
                          foregroundColor: Colors.white,
                          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
                        ),
                        onPressed: isConnected && dialerNumberController.text.trim().isNotEmpty
                            ? () {
                                setState(() => selectedSimSlot = slot);
                                _dial(dialerNumberController.text.trim(), simSlot: slot);
                              }
                            : null,
                        icon: const Icon(Icons.phone_rounded, size: 18),
                        label: Column(
                          mainAxisSize: MainAxisSize.min,
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              'SIM $slot • $op',
                              style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 12),
                            ),
                            if (num != null && num.isNotEmpty)
                              Text(
                                num,
                                style: const TextStyle(fontSize: 10, color: Colors.white70),
                              ),
                          ],
                        ),
                      );
                    }),
                  )
                else
                  Builder(builder: (context) {
                    final sim = simCards.isNotEmpty ? simCards.first : null;
                    final op = sim?.operatorName ?? 'Carrier';
                    final num = sim?.phoneNumber;

                    return FilledButton.icon(
                      style: FilledButton.styleFrom(
                        backgroundColor: Colors.green.shade700,
                        foregroundColor: Colors.white,
                        padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
                      ),
                      onPressed: isConnected && dialerNumberController.text.trim().isNotEmpty
                          ? () => _dial(dialerNumberController.text.trim(), simSlot: 1)
                          : null,
                      icon: const Icon(Icons.phone_rounded, size: 22),
                      label: Column(
                        mainAxisSize: MainAxisSize.min,
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text('Call via $op', style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 13)),
                          if (num != null && num.isNotEmpty)
                            Text(num, style: const TextStyle(fontSize: 10, color: Colors.white70)),
                        ],
                      ),
                    );
                  }),

                // Backspace Button
                if (dialerNumberController.text.isNotEmpty)
                  GestureDetector(
                    onLongPress: () {
                      setState(() => dialerNumberController.clear());
                    },
                    child: IconButton(
                      icon: const Icon(Icons.backspace_outlined, size: 22),
                      tooltip: 'Backspace (Hold to clear)',
                      onPressed: () {
                        final t = dialerNumberController.text;
                        if (t.isNotEmpty) {
                          setState(() => dialerNumberController.text = t.substring(0, t.length - 1));
                        }
                      },
                    ),
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  // -------------------------------------------------------------
  // ANDROID DIALPAD 3x4 GRID
  // -------------------------------------------------------------
  Widget _buildAndroidDialpadGrid(ColorScheme scheme, bool isConnected) {
    const keys = [
      {'digit': '1', 'sub': '➿'},
      {'digit': '2', 'sub': 'ABC'},
      {'digit': '3', 'sub': 'DEF'},
      {'digit': '4', 'sub': 'GHI'},
      {'digit': '5', 'sub': 'JKL'},
      {'digit': '6', 'sub': 'MNO'},
      {'digit': '7', 'sub': 'PQRS'},
      {'digit': '8', 'sub': 'TUV'},
      {'digit': '9', 'sub': 'WXYZ'},
      {'digit': '*', 'sub': ''},
      {'digit': '0', 'sub': '+'},
      {'digit': '#', 'sub': ''},
    ];

    return GridView.builder(
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: 3,
        crossAxisSpacing: 14,
        mainAxisSpacing: 14,
        childAspectRatio: 1.15,
      ),
      itemCount: keys.length,
      itemBuilder: (context, i) {
        final item = keys[i];
        final digit = item['digit']!;
        final sub = item['sub']!;

        return Material(
          color: scheme.surfaceContainerHighest.withValues(alpha: 0.45),
          shape: const CircleBorder(),
          clipBehavior: Clip.antiAlias,
          child: InkWell(
            onTap: isConnected
                ? () {
                    setState(() => dialerNumberController.text += digit);
                    if (callState != 'IDLE') _sendDtmf(digit);
                  }
                : null,
            onLongPress: isConnected && digit == '0'
                ? () {
                    setState(() => dialerNumberController.text += '+');
                    if (callState != 'IDLE') _sendDtmf('+');
                  }
                : null,
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Text(
                  digit,
                  style: const TextStyle(fontSize: 24, fontWeight: FontWeight.w600),
                ),
                if (sub.isNotEmpty)
                  Text(
                    sub,
                    style: TextStyle(
                      fontSize: 9,
                      fontWeight: FontWeight.w800,
                      letterSpacing: 1.2,
                      color: scheme.onSurface.withValues(alpha: 0.55),
                    ),
                  ),
              ],
            ),
          ),
        );
      },
    );
  }

  // -------------------------------------------------------------
  // ANDROID IN-CALL CARD (ACTIVE CALL)
  // -------------------------------------------------------------
  Widget _buildInCallCard(ColorScheme scheme, bool isConnected) {
    final caller = dialerNumberController.text.isNotEmpty ? dialerNumberController.text : 'Unknown Contact';

    return Card(
      elevation: 4,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(28)),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 32),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(28),
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [
              Colors.green.shade900.withValues(alpha: 0.3),
              scheme.surface,
            ],
          ),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // Caller Avatar
            CircleAvatar(
              radius: 40,
              backgroundColor: Colors.green.shade700.withValues(alpha: 0.2),
              child: const Icon(Icons.person_rounded, size: 48, color: Colors.greenAccent),
            ),
            const SizedBox(height: 16),

            // Caller Name/Number
            Text(
              caller,
              style: const TextStyle(fontSize: 22, fontWeight: FontWeight.bold),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 6),

            // Call Duration & SIM Badge
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
              decoration: BoxDecoration(
                color: Colors.green.withValues(alpha: 0.15),
                borderRadius: BorderRadius.circular(20),
                border: Border.all(color: Colors.greenAccent.withValues(alpha: 0.4)),
              ),
              child: Text(
                callState == 'CALL ACTIVE'
                    ? 'Connected • ${(callDurationSeconds ~/ 60).toString().padLeft(2, '0')}:${(callDurationSeconds % 60).toString().padLeft(2, '0')} (SIM $selectedSimSlot)'
                    : 'Dialing via SIM $selectedSimSlot…',
                style: const TextStyle(color: Colors.greenAccent, fontWeight: FontWeight.bold, fontSize: 13),
              ),
            ),
            const SizedBox(height: 32),

            // In-Call Action Buttons Row
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceEvenly,
              children: [
                // Mute Mic
                IconButton.filledTonal(
                  iconSize: 24,
                  padding: const EdgeInsets.all(16),
                  icon: Icon(micMuted ? Icons.mic_off_rounded : Icons.mic_rounded),
                  onPressed: isConnected
                      ? () {
                          setState(() => micMuted = !micMuted);
                          service.setMute(micMuted);
                        }
                      : null,
                ),

                // Red End Call Button
                FilledButton(
                  style: FilledButton.styleFrom(
                    backgroundColor: Colors.redAccent.shade700,
                    foregroundColor: Colors.white,
                    shape: const CircleBorder(),
                    padding: const EdgeInsets.all(20),
                  ),
                  onPressed: isConnected ? _hangup : null,
                  child: const Icon(Icons.call_end_rounded, size: 30),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  // -------------------------------------------------------------
  // ANDROID RECENTS (CALL LOGS) LIST
  // -------------------------------------------------------------
  Widget _buildAndroidRecentsList(ColorScheme scheme, bool isConnected) {
    final filteredLogs = callLogs.where((log) {
      if (historySubFilter == 1) return log.type == CallType.missed;
      if (historySubFilter == 2) return log.type == CallType.received;
      if (historySubFilter == 3) return log.type == CallType.dialed;
      return true;
    }).toList();

    return Column(
      children: [
        // Top Filter Bar & Sync Button
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          child: Row(
            children: [
              Expanded(
                child: SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  child: Row(
                    children: [
                      FilterChip(
                        label: const Text('All'),
                        selected: historySubFilter == 0,
                        onSelected: (_) => setState(() => historySubFilter = 0),
                      ),
                      const SizedBox(width: 8),
                      FilterChip(
                        label: const Text('Missed'),
                        selected: historySubFilter == 1,
                        onSelected: (_) => setState(() => historySubFilter = 1),
                      ),
                      const SizedBox(width: 8),
                      FilterChip(
                        label: const Text('Incoming'),
                        selected: historySubFilter == 2,
                        onSelected: (_) => setState(() => historySubFilter = 2),
                      ),
                      const SizedBox(width: 8),
                      FilterChip(
                        label: const Text('Outgoing'),
                        selected: historySubFilter == 3,
                        onSelected: (_) => setState(() => historySubFilter = 3),
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(width: 8),
              FilledButton.tonalIcon(
                onPressed: isConnected ? _loadCallLogs : null,
                icon: const Icon(Icons.sync, size: 14),
                label: const Text('Sync', style: TextStyle(fontSize: 12)),
              ),
            ],
          ),
        ),
        const Divider(height: 1),

        // Call Logs List
        Expanded(
          child: filteredLogs.isEmpty
              ? Center(
                  child: Padding(
                    padding: const EdgeInsets.all(24),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(Icons.history_toggle_off_rounded, size: 48, color: scheme.onSurface.withValues(alpha: 0.3)),
                        const SizedBox(height: 12),
                        Text(
                          isConnected ? 'No call history found. Tap Sync.' : 'Connect phone to view call history.',
                          style: TextStyle(color: scheme.onSurface.withValues(alpha: 0.6), fontSize: 13),
                        ),
                      ],
                    ),
                  ),
                )
              : ListView.separated(
                  itemCount: filteredLogs.length,
                  separatorBuilder: (_, __) => const Divider(height: 1, indent: 64),
                  itemBuilder: (context, i) {
                    final log = filteredLogs[i];

                    IconData typeIcon;
                    Color typeColor;
                    switch (log.type) {
                      case CallType.missed:
                        typeIcon = Icons.call_missed_rounded;
                        typeColor = Colors.redAccent;
                        break;
                      case CallType.received:
                        typeIcon = Icons.call_received_rounded;
                        typeColor = Colors.blueAccent;
                        break;
                      case CallType.dialed:
                        typeIcon = Icons.call_made_rounded;
                        typeColor = Colors.greenAccent;
                        break;
                      case CallType.unknown:
                        typeIcon = Icons.phone_rounded;
                        typeColor = Colors.grey;
                        break;
                    }

                    return ListTile(
                      leading: CircleAvatar(
                        backgroundColor: typeColor.withValues(alpha: 0.15),
                        child: Icon(typeIcon, color: typeColor, size: 18),
                      ),
                      title: Text(
                        log.displayName,
                        style: TextStyle(
                          fontWeight: FontWeight.bold,
                          color: log.type == CallType.missed ? Colors.redAccent : null,
                        ),
                      ),
                      subtitle: Row(
                        children: [
                          if (log.number.isNotEmpty && log.name.isNotEmpty) ...[
                            Text('${log.number} • ', style: const TextStyle(fontSize: 12)),
                          ],
                          Text(log.timestamp, style: const TextStyle(fontSize: 12)),
                          if (service.simSlotCount > 1) ...[
                            const SizedBox(width: 6),
                            Container(
                              padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
                              decoration: BoxDecoration(
                                color: scheme.surfaceContainerHighest,
                                borderRadius: BorderRadius.circular(4),
                              ),
                              child: Text('SIM ${log.simSlot}', style: const TextStyle(fontSize: 10, fontWeight: FontWeight.bold)),
                            ),
                          ],
                        ],
                      ),
                      trailing: IconButton(
                        icon: const Icon(Icons.phone_rounded, color: Colors.green, size: 20),
                        tooltip: 'Call ${log.number}',
                        onPressed: isConnected
                            ? () {
                                dialerNumberController.text = log.number;
                                _dial(log.number, simSlot: log.simSlot);
                              }
                            : null,
                      ),
                      onTap: () {
                        setState(() {
                          dialerNumberController.text = log.number;
                          phoneHubSubTab = 0;
                        });
                      },
                    );
                  },
                ),
        ),
      ],
    );
  }

  // -------------------------------------------------------------
  // ANDROID CONTACTS LIST
  // -------------------------------------------------------------
  Widget _buildAndroidContactsList(ColorScheme scheme, bool isConnected) {
    final filteredContacts = contacts.where((c) {
      final q = contactSearchController.text.toLowerCase();
      return c.name.toLowerCase().contains(q) || c.number.contains(q);
    }).toList();

    return Column(
      children: [
        // Search Bar & Sync Contacts Button
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          child: Row(
            children: [
              Expanded(
                child: TextField(
                  controller: contactSearchController,
                  decoration: InputDecoration(
                    hintText: 'Search contacts…',
                    prefixIcon: const Icon(Icons.search_rounded, size: 20),
                    filled: true,
                    fillColor: scheme.surfaceContainerHighest.withValues(alpha: 0.4),
                    border: OutlineInputBorder(borderRadius: BorderRadius.circular(24), borderSide: BorderSide.none),
                    contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                    isDense: true,
                    suffixIcon: contactSearchController.text.isNotEmpty
                        ? IconButton(
                            icon: const Icon(Icons.clear, size: 16),
                            onPressed: () {
                              contactSearchController.clear();
                              setState(() {});
                            },
                          )
                        : null,
                  ),
                  onChanged: (_) => setState(() {}),
                ),
              ),
              const SizedBox(width: 8),
              FilledButton.tonalIcon(
                onPressed: isConnected ? _loadContacts : null,
                icon: const Icon(Icons.sync, size: 14),
                label: const Text('Sync', style: TextStyle(fontSize: 12)),
              ),
            ],
          ),
        ),
        const Divider(height: 1),

        // Contacts List
        Expanded(
          child: filteredContacts.isEmpty
              ? Center(
                  child: Padding(
                    padding: const EdgeInsets.all(24),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(Icons.person_off_outlined, size: 48, color: scheme.onSurface.withValues(alpha: 0.3)),
                        const SizedBox(height: 12),
                        Text(
                          isConnected
                              ? (contactSearchController.text.isNotEmpty
                                  ? 'No contacts match "${contactSearchController.text}"'
                                  : 'No contacts found on SIM. Tap Sync.')
                              : 'Connect phone to sync and dial contacts.',
                          style: TextStyle(color: scheme.onSurface.withValues(alpha: 0.6), fontSize: 13),
                          textAlign: TextAlign.center,
                        ),
                      ],
                    ),
                  ),
                )
              : ListView.separated(
                  itemCount: filteredContacts.length,
                  separatorBuilder: (_, __) => const Divider(height: 1, indent: 64),
                  itemBuilder: (context, i) {
                    final c = filteredContacts[i];
                    final initial = c.name.isNotEmpty ? c.name[0].toUpperCase() : '#';

                    return ListTile(
                      leading: CircleAvatar(
                        backgroundColor: scheme.primary.withValues(alpha: 0.15),
                        child: Text(
                          initial,
                          style: TextStyle(fontWeight: FontWeight.bold, color: scheme.primary),
                        ),
                      ),
                      title: Text(c.name, style: const TextStyle(fontWeight: FontWeight.bold)),
                      subtitle: Text(c.number, style: const TextStyle(fontSize: 12)),
                      trailing: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          IconButton(
                            icon: const Icon(Icons.chat_bubble_outline_rounded, size: 18, color: Colors.cyanAccent),
                            tooltip: 'Send SMS',
                            onPressed: () {
                              smsRecipientController.text = c.number;
                              _tabController.animateTo(2);
                            },
                          ),
                          IconButton(
                            icon: const Icon(Icons.phone_rounded, size: 20, color: Colors.green),
                            tooltip: 'Call ${c.name}',
                            onPressed: isConnected
                                ? () {
                                    dialerNumberController.text = c.number;
                                    _dial(c.number);
                                  }
                                : null,
                          ),
                        ],
                      ),
                      onTap: () {
                        setState(() {
                          dialerNumberController.text = c.number;
                          phoneHubSubTab = 0;
                        });
                      },
                    );
                  },
                ),
        ),
      ],
    );
  }

  void _showEditSimDialog(SimCard sim) {
    final companyController = TextEditingController(text: sim.operatorName);
    final numberController = TextEditingController(text: sim.phoneNumber ?? '');

    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Row(
          children: [
            const Icon(Icons.sim_card_outlined, color: Colors.cyanAccent),
            const SizedBox(width: 8),
            Text('Edit SIM ${sim.slotIndex} Details'),
          ],
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Set carrier / company name and own subscriber phone number for SIM ${sim.slotIndex}:',
              style: const TextStyle(fontSize: 13),
            ),
            const SizedBox(height: 16),
            TextField(
              controller: companyController,
              decoration: const InputDecoration(
                labelText: 'Company / Carrier (e.g. Jio, Airtel, Vi)',
                prefixIcon: Icon(Icons.business_rounded),
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 14),
            TextField(
              controller: numberController,
              decoration: const InputDecoration(
                labelText: 'Phone Number (e.g. +91 98765 43210)',
                prefixIcon: Icon(Icons.phone_android_rounded),
                border: OutlineInputBorder(),
              ),
              keyboardType: TextInputType.phone,
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () async {
              Navigator.pop(ctx);
              await service.updateSimCardDetails(
                sim.slotIndex,
                operatorName: companyController.text.trim(),
                phoneNumber: numberController.text.trim(),
              );
              if (mounted) setState(() => simCards = service.simCards);
            },
            child: const Text('Save Details'),
          ),
        ],
      ),
    );
  }

  void _showAddContactDialog() {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Add Contact'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: contactNameController,
              decoration: const InputDecoration(labelText: 'Name', border: OutlineInputBorder()),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: contactNumberController,
              decoration: const InputDecoration(labelText: 'Phone Number', border: OutlineInputBorder()),
            ),
          ],
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
          FilledButton(
            onPressed: () {
              Navigator.pop(ctx);
              final name = contactNameController.text.trim();
              final number = contactNumberController.text.trim();
              if (name.isNotEmpty && number.isNotEmpty) {
                setState(() {
                  contacts.insert(0, PhoneContact(index: contacts.length + 1, name: name, number: number));
                });
              }
            },
            child: const Text('Save'),
          ),
        ],
      ),
    );
  }

  // -------------------------------------------------------------
  // TAB 4: BLUETOOTH & EJECT
  // -------------------------------------------------------------
  Widget _bluetoothManagerView(ColorScheme scheme, bool isConnected) {
    return Padding(
      padding: const EdgeInsets.all(20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // Responsive Header Card
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Wrap(
                alignment: WrapAlignment.spaceBetween,
                crossAxisAlignment: WrapCrossAlignment.center,
                spacing: 12,
                runSpacing: 10,
                children: [
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Icon(Icons.bluetooth_audio, size: 28, color: Colors.blueAccent),
                      const SizedBox(width: 12),
                      Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Text('BLUETOOTH DEVICE MANAGER & EJECT', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 14)),
                          Text(
                            'Manage paired Mac Bluetooth endpoints, connect, disconnect, or eject/unpair devices.',
                            style: TextStyle(fontSize: 12, color: scheme.onSurface.withValues(alpha: 0.6)),
                          ),
                        ],
                      ),
                    ],
                  ),
                  Wrap(
                    spacing: 10,
                    runSpacing: 8,
                    children: [
                      FilledButton.tonalIcon(
                        onPressed: _refreshBtDevices,
                        icon: const Icon(Icons.refresh, size: 16),
                        label: const Text('Refresh BT Devices'),
                      ),
                      FilledButton.icon(
                        onPressed: isConnected && !_scanningBt
                            ? () async {
                                setState(() => _scanningBt = true);
                                await service.btScan(start: true);
                                await Future.delayed(const Duration(seconds: 2));
                                await _refreshBtDevices();
                                if (mounted) setState(() => _scanningBt = false);
                              }
                            : null,
                        icon: const Icon(Icons.bluetooth_searching, size: 16),
                        label: const Text('Phone BT Scan'),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 16),

          // Bluetooth Devices Table
          Expanded(
            child: Card(
              clipBehavior: Clip.antiAlias,
              child: btDevices.isEmpty
                  ? Center(
                      child: Padding(
                        padding: const EdgeInsets.all(30),
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            const Icon(Icons.bluetooth_disabled, size: 44, color: Colors.grey),
                            const SizedBox(height: 12),
                            const Text('No Bluetooth devices paired or discovered on macOS', style: TextStyle(fontWeight: FontWeight.bold)),
                            const SizedBox(height: 14),
                            FilledButton.icon(
                              onPressed: _refreshBtDevices,
                              icon: const Icon(Icons.refresh),
                              label: const Text('Scan & Refresh'),
                            ),
                          ],
                        ),
                      ),
                    )
                  : ListView.separated(
                      itemCount: btDevices.length,
                      separatorBuilder: (_, __) => const Divider(height: 1),
                      itemBuilder: (context, i) {
                        final d = btDevices[i];
                        return ListTile(
                          leading: CircleAvatar(
                            backgroundColor: d.connected
                                ? Colors.blue.withValues(alpha: 0.2)
                                : Colors.grey.withValues(alpha: 0.15),
                            child: Icon(
                              d.isPhone ? Icons.smartphone : Icons.bluetooth,
                              color: d.connected ? Colors.blueAccent : Colors.grey,
                            ),
                          ),
                          title: Wrap(
                            crossAxisAlignment: WrapCrossAlignment.center,
                            spacing: 8,
                            runSpacing: 4,
                            children: [
                              Text(d.name, style: const TextStyle(fontWeight: FontWeight.bold)),
                              Container(
                                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                                decoration: BoxDecoration(
                                  color: d.connected
                                      ? Colors.green.withValues(alpha: 0.15)
                                      : Colors.grey.withValues(alpha: 0.15),
                                  borderRadius: BorderRadius.circular(6),
                                ),
                                child: Text(
                                  d.connected ? 'CONNECTED' : (d.paired ? 'PAIRED' : 'DISCOVERED'),
                                  style: TextStyle(
                                    fontSize: 10,
                                    fontWeight: FontWeight.bold,
                                    color: d.connected ? Colors.greenAccent : Colors.grey,
                                  ),
                                ),
                              ),
                            ],
                          ),
                          subtitle: Text(
                            'Address: ${d.address} • Type: ${d.typeLabel}',
                            style: const TextStyle(fontFamily: 'monospace', fontSize: 11),
                          ),
                          trailing: Wrap(
                            spacing: 8,
                            runSpacing: 4,
                            crossAxisAlignment: WrapCrossAlignment.center,
                            children: [
                              if (d.connected)
                                OutlinedButton.icon(
                                  onPressed: () => service.disconnectNativeBluetooth(d.address),
                                  icon: const Icon(Icons.bluetooth_disabled, size: 16),
                                  label: const Text('Disconnect'),
                                )
                              else
                                FilledButton.tonalIcon(
                                  onPressed: () => service.connectNativeBluetooth(d.address),
                                  icon: const Icon(Icons.bluetooth_connected, size: 16),
                                  label: const Text('Connect'),
                                ),
                              FilledButton.icon(
                                onPressed: () async {
                                  final confirm = await showDialog<bool>(
                                    context: context,
                                    builder: (ctx) => AlertDialog(
                                      title: const Text('Eject / Unpair Bluetooth Device?'),
                                      content: Text('Are you sure you want to unpair and eject "${d.name}" (${d.address})?'),
                                      actions: [
                                        TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
                                        FilledButton(
                                          style: FilledButton.styleFrom(backgroundColor: Colors.redAccent),
                                          onPressed: () => Navigator.pop(ctx, true),
                                          child: const Text('Eject & Unpair'),
                                        ),
                                      ],
                                    ),
                                  );
                                  if (confirm == true) {
                                    await service.ejectNativeBluetooth(d.address);
                                    if (context.mounted) {
                                      ScaffoldMessenger.of(context).showSnackBar(
                                        SnackBar(content: Text('Ejected ${d.name}')),
                                      );
                                    }
                                  }
                                },
                                icon: const Icon(Icons.eject, size: 16),
                                label: const Text('Eject'),
                                style: FilledButton.styleFrom(
                                  backgroundColor: Colors.red.withValues(alpha: 0.15),
                                  foregroundColor: Colors.redAccent,
                                ),
                              ),
                            ],
                          ),
                        );
                      },
                    ),
            ),
          ),
        ],
      ),
    );
  }

  // -------------------------------------------------------------
  // TAB 5: BT NOTIFIER & NOTIFICATION HUB
  // -------------------------------------------------------------
  Widget _btNotifierView(ColorScheme scheme, bool isConnected) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final isWide = constraints.maxWidth >= 850;

        Widget pushCard = Card(
          child: Padding(
            padding: const EdgeInsets.all(20),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const Row(
                  children: [
                    Icon(Icons.phone_bluetooth_speaker_rounded, color: Colors.cyanAccent),
                    SizedBox(width: 10),
                    Text('BT DIALER COMPANION & REMOTE CONTROLS', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13)),
                  ],
                ),
                const SizedBox(height: 14),
                // BT Dialer Quick Action Deck
                Wrap(
                  spacing: 10,
                  runSpacing: 10,
                  children: [
                    // Find My Phone / Anti-Lost Button
                    FilledButton.icon(
                      style: FilledButton.styleFrom(
                        backgroundColor: Colors.amber.shade800,
                        foregroundColor: Colors.white,
                        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                      ),
                      onPressed: isConnected
                          ? () async {
                              await service.ringPhoneAntiLost();
                              _addLog('info', '🔔 Find My Phone: Ringing and vibrating handset!');
                            }
                          : null,
                      icon: const Icon(Icons.ring_volume_rounded, size: 18),
                      label: const Text('Find My Phone (Anti-Lost Alarm)'),
                    ),

                    // Remote Mic Mute Toggle
                    OutlinedButton.icon(
                      style: OutlinedButton.styleFrom(
                        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                        side: BorderSide(color: micMuted ? Colors.redAccent : scheme.outline),
                      ),
                      onPressed: isConnected
                          ? () async {
                              final nextState = !micMuted;
                              await service.setMutePhoneMic(nextState);
                              if (mounted) setState(() => micMuted = nextState);
                            }
                          : null,
                      icon: Icon(micMuted ? Icons.mic_off : Icons.mic, size: 18, color: micMuted ? Colors.redAccent : null),
                      label: Text(micMuted ? 'Phone Mic Muted' : 'Mute Phone Mic'),
                    ),

                    // Remote Camera Trigger
                    OutlinedButton.icon(
                      style: OutlinedButton.styleFrom(
                        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                      ),
                      onPressed: isConnected
                          ? () async {
                              await service.triggerRemoteCamera();
                              _addLog('info', '📸 Remote camera capture triggered!');
                            }
                          : null,
                      icon: const Icon(Icons.camera_alt_outlined, size: 18),
                      label: const Text('Remote Camera Shutter'),
                    ),
                  ],
                ),
                const SizedBox(height: 16),

                // Remote Volume Slider
                Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: scheme.surfaceContainerHighest.withValues(alpha: 0.3),
                    borderRadius: BorderRadius.circular(10),
                    border: Border.all(color: scheme.outline.withValues(alpha: 0.15)),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          const Row(
                            children: [
                              Icon(Icons.volume_up_rounded, size: 16, color: Colors.cyanAccent),
                              SizedBox(width: 6),
                              Text('Remote Handset Speaker & Ringer Volume:', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 12)),
                            ],
                          ),
                          Text('${volumeLevel * 10}%', style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 12)),
                        ],
                      ),
                      Slider(
                        value: volumeLevel.toDouble(),
                        min: 0,
                        max: 10,
                        divisions: 10,
                        label: '${volumeLevel * 10}%',
                        onChanged: isConnected
                            ? (val) {
                                setState(() => volumeLevel = val.toInt());
                                service.setPhoneSpeakerVolume(val.toInt() * 10);
                              }
                            : null,
                      ),
                    ],
                  ),
                ),

                const Divider(height: 28),

                const Row(
                  children: [
                    Icon(Icons.send_to_mobile, color: Colors.cyanAccent),
                    SizedBox(width: 10),
                    Text('PUSH NOTIFICATION TO PHONE (BT NOTIFIER)', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13)),
                  ],
                ),
                const SizedBox(height: 14),
                Row(
                  children: [
                    const Text('Source App:', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 12)),
                    const SizedBox(width: 12),
                    DropdownButton<String>(
                      value: pushAppSource,
                      items: const [
                        DropdownMenuItem(value: 'Mac Alert', child: Text('Mac System Alert')),
                        DropdownMenuItem(value: 'WhatsApp', child: Text('WhatsApp')),
                        DropdownMenuItem(value: 'Slack', child: Text('Slack')),
                        DropdownMenuItem(value: 'Mail', child: Text('Mail / Outlook')),
                        DropdownMenuItem(value: 'Calendar', child: Text('Calendar Event')),
                        DropdownMenuItem(value: 'Reminders', child: Text('Reminders')),
                      ],
                      onChanged: (v) => setState(() => pushAppSource = v ?? 'Mac Alert'),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: pushTitleController,
                  decoration: const InputDecoration(
                    labelText: 'Notification Title',
                    border: OutlineInputBorder(),
                    contentPadding: EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                  ),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: pushBodyController,
                  maxLines: 3,
                  decoration: const InputDecoration(
                    labelText: 'Notification Message Body',
                    border: OutlineInputBorder(),
                    contentPadding: EdgeInsets.all(12),
                  ),
                ),
                const SizedBox(height: 14),
                FilledButton.icon(
                  onPressed: isConnected && !busy ? _sendPushNotificationToPhone : null,
                  icon: const Icon(Icons.notification_add),
                  label: const Text('Push Notification to Phone Screen & Vibrate'),
                  style: FilledButton.styleFrom(
                    backgroundColor: Colors.cyan.shade700,
                    foregroundColor: Colors.white,
                    padding: const EdgeInsets.symmetric(vertical: 14),
                  ),
                ),
                const Divider(height: 30),
                const Text('BT NOTIFIER SETTINGS & 2-WAY SYNC:', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 12)),
                const SizedBox(height: 8),
                SwitchListTile(
                  title: const Text('Auto-Forward Mac System Notifications to Phone', style: TextStyle(fontSize: 13)),
                  subtitle: const Text('Relays incoming Mac alerts over Bluetooth/Serial to phone buzzer & display', style: TextStyle(fontSize: 11)),
                  value: service.forwardMacNotifications,
                  onChanged: (v) => setState(() => service.setForwardMacNotifications(v)),
                ),
                const Divider(height: 24),
                const Text('2-WAY NOTIFICATION TEST & SIMULATION DECK:', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 12)),
                const SizedBox(height: 10),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    ActionChip(
                      avatar: const Icon(Icons.ring_volume, size: 14, color: Colors.greenAccent),
                      label: const Text('Simulate Incoming Call (Phone → Mac)'),
                      onPressed: () {
                        service.simulateIncomingCall(
                          name: 'Alice Johnson',
                          number: '+1 (555) 019-2834',
                        );
                      },
                    ),
                    ActionChip(
                      avatar: const Icon(Icons.sms, size: 14, color: Colors.cyanAccent),
                      label: const Text('Simulate Incoming SMS (Phone → Mac)'),
                      onPressed: () {
                        service.simulateIncomingSms(
                          sender: '+1 (555) 019-2834',
                          message: 'Hey! Meeting is rescheduled to 4 PM on Mac.',
                        );
                      },
                    ),
                    ActionChip(
                      avatar: const Icon(Icons.battery_alert, size: 14, color: Colors.amberAccent),
                      label: const Text('Simulate Low Battery Alert (Phone → Mac)'),
                      onPressed: () {
                        service.simulatePhoneBatteryWarning(level: 12);
                      },
                    ),
                    ActionChip(
                      avatar: const Icon(Icons.desktop_mac, size: 14, color: Colors.purpleAccent),
                      label: const Text('Test Mac Native Notification'),
                      onPressed: () {
                        service.showMacNotification(
                          title: 'ControlBuddy 2-Way Link',
                          body: 'Mac native notification bridge is working seamlessly!',
                        );
                      },
                    ),
                  ],
                ),
              ],
            ),
          ),
        );

        Widget streamCard = Card(
          child: Padding(
            padding: const EdgeInsets.all(18),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  children: [
                    const Icon(Icons.notifications_outlined, size: 20),
                    const SizedBox(width: 8),
                    Text('Notification Stream (${service.notificationHistory.length})', style: const TextStyle(fontWeight: FontWeight.bold)),
                    const Spacer(),
                    TextButton(
                      onPressed: () => setState(() => service.notificationHistory.clear()),
                      child: const Text('Clear'),
                    ),
                  ],
                ),
                const Divider(height: 12),
                service.notificationHistory.isEmpty
                    ? Container(
                        padding: const EdgeInsets.all(24),
                        alignment: Alignment.center,
                        child: const Text(
                          'No notifications exchanged yet.',
                          style: TextStyle(color: Colors.grey),
                        ),
                      )
                    : ListView.separated(
                        shrinkWrap: true,
                        physics: const NeverScrollableScrollPhysics(),
                        itemCount: service.notificationHistory.length,
                        separatorBuilder: (_, __) => const Divider(height: 1),
                        itemBuilder: (context, i) {
                          final n = service.notificationHistory[i];
                          final isMacToPhone = n.direction == NotificationDirection.macToPhone;
                          return ListTile(
                            leading: CircleAvatar(
                              backgroundColor: isMacToPhone
                                  ? Colors.cyan.withValues(alpha: 0.15)
                                  : Colors.green.withValues(alpha: 0.15),
                              child: Icon(
                                isMacToPhone ? Icons.arrow_forward : Icons.arrow_back,
                                color: isMacToPhone ? Colors.cyanAccent : Colors.greenAccent,
                                size: 18,
                              ),
                            ),
                            title: Row(
                              children: [
                                Text(n.appName, style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 12)),
                                const Spacer(),
                                Text(
                                  isMacToPhone ? 'Mac → Phone' : 'Phone → Mac',
                                  style: TextStyle(
                                    fontSize: 10,
                                    fontWeight: FontWeight.bold,
                                    color: isMacToPhone ? Colors.cyanAccent : Colors.greenAccent,
                                  ),
                                ),
                              ],
                            ),
                            subtitle: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(n.title, style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 13)),
                                Text(n.body, style: const TextStyle(fontSize: 11, color: Colors.grey)),
                              ],
                            ),
                          );
                        },
                      ),
              ],
            ),
          ),
        );

        return SingleChildScrollView(
          padding: const EdgeInsets.all(20),
          child: isWide
              ? Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(flex: 3, child: pushCard),
                    const SizedBox(width: 16),
                    Expanded(flex: 2, child: streamCard),
                  ],
                )
              : Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    pushCard,
                    const SizedBox(height: 16),
                    streamCard,
                  ],
                ),
        );
      },
    );
  }

  // -------------------------------------------------------------
  // TAB 3: MESSAGES (SMS Hub)
  // -------------------------------------------------------------
  Widget _messagesView(ColorScheme scheme, bool isConnected) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final isWide = constraints.maxWidth >= 750;

        Widget inboxList = Card(
          child: Column(
            children: [
              Padding(
                padding: const EdgeInsets.all(14),
                child: Row(
                  children: [
                    const Icon(Icons.inbox, size: 20),
                    const SizedBox(width: 8),
                    Text('SMS Inbox (${messages.length})', style: const TextStyle(fontWeight: FontWeight.bold)),
                    const Spacer(),
                    IconButton(
                      icon: const Icon(Icons.refresh, size: 18),
                      tooltip: 'Refresh messages',
                      onPressed: isConnected ? _loadSms : null,
                    ),
                  ],
                ),
              ),
              const Divider(height: 1),
              Expanded(
                child: messages.isEmpty
                    ? Center(
                        child: Text(
                          isConnected ? 'No SMS messages on phone.' : 'Connect phone to read SMS.',
                          style: const TextStyle(color: Colors.grey),
                        ),
                      )
                    : ListView.separated(
                        itemCount: messages.length,
                        separatorBuilder: (_, __) => const Divider(height: 1),
                        itemBuilder: (context, i) {
                          final msg = messages[i];
                          final isSelected = selectedMessage?.index == msg.index;
                          return ListTile(
                            selected: isSelected,
                            leading: CircleAvatar(
                              child: Text(msg.sender.isNotEmpty ? msg.sender[0].toUpperCase() : '?'),
                            ),
                            title: Text(msg.sender, style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 13)),
                            subtitle: Text(msg.body, maxLines: 1, overflow: TextOverflow.ellipsis),
                            trailing: Text(msg.date, style: const TextStyle(fontSize: 10, color: Colors.grey)),
                            onTap: () => setState(() => selectedMessage = msg),
                          );
                        },
                      ),
              ),
            ],
          ),
        );

        Widget composePanel = Card(
          child: Padding(
            padding: const EdgeInsets.all(18),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                if (selectedMessage != null) ...[
                  Row(
                    children: [
                      CircleAvatar(
                        child: Text(selectedMessage!.sender.isNotEmpty ? selectedMessage!.sender[0].toUpperCase() : '?'),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(selectedMessage!.sender, style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
                            Text('Received: ${selectedMessage!.date}', style: const TextStyle(fontSize: 11, color: Colors.grey)),
                          ],
                        ),
                      ),
                      IconButton(
                        icon: const Icon(Icons.reply, size: 20),
                        tooltip: 'Reply',
                        onPressed: () {
                          smsRecipientController.text = selectedMessage!.sender;
                        },
                      ),
                      IconButton(
                        icon: const Icon(Icons.delete_outline, size: 20, color: Colors.redAccent),
                        tooltip: 'Delete',
                        onPressed: () async {
                          await service.deleteSms(selectedMessage!.index);
                          await _loadSms();
                        },
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  Container(
                    padding: const EdgeInsets.all(14),
                    decoration: BoxDecoration(
                      color: scheme.surfaceContainerHighest.withValues(alpha: 0.3),
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: SelectableText(selectedMessage!.body, style: const TextStyle(fontSize: 14)),
                  ),
                  const Divider(height: 24),
                ],
                const Text('COMPOSE NEW SMS', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13)),
                const SizedBox(height: 10),
                TextField(
                  controller: smsRecipientController,
                  keyboardType: TextInputType.phone,
                  decoration: const InputDecoration(
                    labelText: 'Recipient Number (e.g. +1234567890)',
                    prefixIcon: Icon(Icons.phone),
                    border: OutlineInputBorder(),
                    contentPadding: EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                  ),
                ),
                const SizedBox(height: 10),
                Expanded(
                  child: TextField(
                    controller: smsBodyController,
                    maxLines: null,
                    expands: true,
                    decoration: const InputDecoration(
                      hintText: 'Type your message text here...',
                      border: OutlineInputBorder(),
                      contentPadding: EdgeInsets.all(12),
                    ),
                  ),
                ),
                const SizedBox(height: 10),
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    if (service.simSlotCount > 1)
                      Wrap(
                        spacing: 6,
                        children: List.generate(service.simSlotCount, (i) {
                          final slot = i + 1;
                          final isSel = selectedSimSlot == slot;
                          return ChoiceChip(
                            avatar: Icon(Icons.sim_card, size: 13, color: isSel ? Colors.greenAccent : null),
                            label: Text('SIM $slot', style: const TextStyle(fontSize: 11)),
                            selected: isSel,
                            onSelected: (val) {
                              if (val) {
                                setState(() => selectedSimSlot = slot);
                                service.setActiveSim(slot);
                              }
                            },
                          );
                        }),
                      )
                    else
                      const SizedBox(),
                    FilledButton.icon(
                      onPressed: isConnected ? () => _sendSms(simSlot: selectedSimSlot) : null,
                      icon: const Icon(Icons.send),
                      label: Text(service.simSlotCount > 1 ? 'Send via SIM $selectedSimSlot' : 'Send SMS'),
                      style: FilledButton.styleFrom(
                        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        );

        return Padding(
          padding: const EdgeInsets.all(20),
          child: isWide
              ? Row(
                  children: [
                    Expanded(flex: 2, child: inboxList),
                    const SizedBox(width: 16),
                    Expanded(flex: 3, child: composePanel),
                  ],
                )
              : Column(
                  children: [
                    Expanded(flex: 2, child: inboxList),
                    const SizedBox(height: 16),
                    Expanded(flex: 3, child: composePanel),
                  ],
                ),
        );
      },
    );
  }

  // -------------------------------------------------------------
  // TAB 6: TERMINAL & SERIAL / CONNECTIONS
  // -------------------------------------------------------------
  Widget _connectionsView(ColorScheme scheme, bool isConnected) {
    final filteredDevices = devices.where((d) {
      if (deviceFilter == 'USB') return d.usb;
      if (deviceFilter == 'Bluetooth') return !d.usb;
      return true;
    }).toList();

    final usbCount = devices.where((d) => d.usb).length;
    final btCount = devices.where((d) => !d.usb).length;

    return Padding(
      padding: const EdgeInsets.all(20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // Responsive Header Bar
          Wrap(
            alignment: WrapAlignment.spaceBetween,
            crossAxisAlignment: WrapCrossAlignment.center,
            spacing: 12,
            runSpacing: 10,
            children: [
              Wrap(
                crossAxisAlignment: WrapCrossAlignment.center,
                spacing: 10,
                runSpacing: 6,
                children: [
                  const Icon(Icons.hub_outlined, size: 22),
                  Text(
                    'Discovered Serial & USB Endpoints',
                    style: Theme.of(context).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.bold),
                  ),
                  Wrap(
                    spacing: 6,
                    children: [
                      ChoiceChip(
                        label: Text('All (${devices.length})'),
                        selected: deviceFilter == 'All',
                        onSelected: (_) => setState(() => deviceFilter = 'All'),
                      ),
                      ChoiceChip(
                        avatar: const Icon(Icons.usb, size: 14),
                        label: Text('USB ($usbCount)'),
                        selected: deviceFilter == 'USB',
                        onSelected: (_) => setState(() => deviceFilter = 'USB'),
                      ),
                      ChoiceChip(
                        avatar: const Icon(Icons.bluetooth, size: 14),
                        label: Text('Bluetooth ($btCount)'),
                        selected: deviceFilter == 'Bluetooth',
                        onSelected: (_) => setState(() => deviceFilter = 'Bluetooth'),
                      ),
                    ],
                  ),
                ],
              ),
              Wrap(
                crossAxisAlignment: WrapCrossAlignment.center,
                spacing: 10,
                runSpacing: 8,
                children: [
                  Container(
                    height: 36,
                    padding: const EdgeInsets.symmetric(horizontal: 10),
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(color: scheme.outlineVariant),
                    ),
                    child: DropdownButtonHideUnderline(
                      child: DropdownButton<int>(
                        value: baud,
                        isDense: true,
                        style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold, color: scheme.onSurface),
                        items: const [
                          DropdownMenuItem(value: 9600, child: Text('9600 baud')),
                          DropdownMenuItem(value: 19200, child: Text('19200 baud')),
                          DropdownMenuItem(value: 38400, child: Text('38400 baud')),
                          DropdownMenuItem(value: 57600, child: Text('57600 baud')),
                          DropdownMenuItem(value: 115200, child: Text('115200 baud')),
                        ],
                        onChanged: (v) => setState(() => baud = v ?? 115200),
                      ),
                    ),
                  ),
                  OutlinedButton.icon(
                    onPressed: (_refreshing || busy) ? null : _refresh,
                    icon: const Icon(Icons.refresh, size: 16),
                    label: const Text('Refresh'),
                  ),
                  FilledButton.icon(
                    onPressed: (_scanning || busy) ? null : _scan,
                    icon: const Icon(Icons.radar, size: 16),
                    label: const Text('Scan Devices'),
                  ),
                ],
              ),
            ],
          ),
          if (_scanning || _refreshing) ...[
            const SizedBox(height: 10),
            const LinearProgressIndicator(minHeight: 2),
          ],
          const SizedBox(height: 14),
          Expanded(
            child: Card(
              clipBehavior: Clip.antiAlias,
              child: filteredDevices.isEmpty
                  ? (devices.isEmpty ? _emptyDevicesView() : _emptyFilterView())
                  : _deviceTable(scheme, filteredDevices),
            ),
          ),
        ],
      ),
    );
  }

  Widget _emptyFilterView() {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.filter_list_off, size: 36, color: Colors.grey),
            const SizedBox(height: 10),
            Text('No devices matching filter "$deviceFilter"', style: const TextStyle(fontWeight: FontWeight.bold)),
            const SizedBox(height: 10),
            TextButton(
              onPressed: () => setState(() => deviceFilter = 'All'),
              child: const Text('Show All Devices'),
            ),
          ],
        ),
      ),
    );
  }

  Widget _deviceTable(ColorScheme scheme, List<UsbDevice> listToDisplay) {
    return SingleChildScrollView(
      scrollDirection: Axis.vertical,
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: ConstrainedBox(
          constraints: const BoxConstraints(minWidth: 780),
          child: DataTable(
            headingRowColor: WidgetStateProperty.all(scheme.surfaceContainerHighest.withValues(alpha: 0.5)),
            columnSpacing: 22,
            horizontalMargin: 18,
            columns: const [
              DataColumn(label: Text('DEVICE NAME', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 12))),
              DataColumn(label: Text('TYPE', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 12))),
              DataColumn(label: Text('PORT / PATH', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 12))),
              DataColumn(label: Text('STATUS', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 12))),
              DataColumn(label: Text('ACTION', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 12))),
            ],
            rows: listToDisplay.map((d) {
              final isThisConnected = status == 'Connected' && connectedPath == d.path;
              final isConnecting = connectingPath == d.path;

              return DataRow(
                color: WidgetStateProperty.resolveWith<Color?>((states) {
                  if (isThisConnected) return scheme.primary.withValues(alpha: 0.08);
                  return null;
                }),
                cells: [
                  DataCell(
                    Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(
                          d.usb ? Icons.usb : Icons.bluetooth,
                          size: 18,
                          color: isThisConnected ? Colors.greenAccent : (d.usb ? scheme.primary : Colors.blueAccent),
                        ),
                        const SizedBox(width: 10),
                        Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            Text(
                              d.name,
                              style: TextStyle(fontWeight: isThisConnected ? FontWeight.bold : FontWeight.w600, fontSize: 13),
                            ),
                            Text(
                              d.manufacturer,
                              style: TextStyle(fontSize: 11, color: scheme.onSurface.withValues(alpha: 0.55)),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                  DataCell(
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 4),
                      decoration: BoxDecoration(
                        color: d.usb ? scheme.primary.withValues(alpha: 0.12) : Colors.blueAccent.withValues(alpha: 0.12),
                        borderRadius: BorderRadius.circular(6),
                        border: Border.all(color: d.usb ? scheme.primary.withValues(alpha: 0.35) : Colors.blueAccent.withValues(alpha: 0.35)),
                      ),
                      child: Text(
                        d.usb ? 'USB' : 'Bluetooth',
                        style: TextStyle(fontSize: 11, fontWeight: FontWeight.w700, color: d.usb ? scheme.primary : Colors.blueAccent),
                      ),
                    ),
                  ),
                  DataCell(
                    Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(d.path, style: const TextStyle(fontFamily: 'monospace', fontSize: 12)),
                        const SizedBox(width: 4),
                        IconButton(
                          icon: const Icon(Icons.copy, size: 14),
                          onPressed: () {
                            Clipboard.setData(ClipboardData(text: d.path));
                            ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Copied ${d.path}')));
                          },
                        ),
                      ],
                    ),
                  ),
                  DataCell(
                    Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        if (isThisConnected)
                          _statusPill('ACTIVE SERIAL LINK', Colors.greenAccent, Colors.green)
                        else if (!d.usb)
                          _statusPill(d.btConnected ? 'BT CONNECTED' : 'BT DISCONNECTED', d.btConnected ? Colors.cyanAccent : Colors.grey.shade400, Colors.cyan)
                        else
                          _statusPill('USB READY', scheme.primary, Colors.blue),
                      ],
                    ),
                  ),
                  DataCell(
                    isThisConnected
                        ? FilledButton.tonalIcon(
                            onPressed: busy ? null : _disconnect,
                            icon: const Icon(Icons.link_off, size: 16),
                            label: const Text('Disconnect'),
                            style: FilledButton.styleFrom(backgroundColor: Colors.red.withValues(alpha: 0.15), foregroundColor: Colors.redAccent),
                          )
                        : FilledButton.icon(
                            onPressed: (busy || isConnecting) ? null : () => _connectToDevice(d),
                            icon: isConnecting
                                ? const SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2))
                                : const Icon(Icons.link, size: 16),
                            label: Text(isConnecting ? 'Connecting…' : 'Connect'),
                          ),
                  ),
                ],
              );
            }).toList(),
          ),
        ),
      ),
    );
  }

  Widget _statusPill(String label, Color color, Color bg) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: bg.withValues(alpha: 0.15),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: color.withValues(alpha: 0.6)),
      ),
      child: Text(label, style: TextStyle(fontSize: 11, fontWeight: FontWeight.bold, color: color)),
    );
  }

  Widget _emptyDevicesView() {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(30),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.usb_off, size: 40, color: Colors.grey),
            const SizedBox(height: 12),
            const Text('No USB or Bluetooth serial devices detected', style: TextStyle(fontWeight: FontWeight.bold)),
            const SizedBox(height: 16),
            FilledButton.icon(
              onPressed: _scan,
              icon: const Icon(Icons.radar),
              label: const Text('Scan Devices'),
            ),
          ],
        ),
      ),
    );
  }

  Widget _consolePanel(ColorScheme scheme, bool isConnected) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Wrap(
              alignment: WrapAlignment.spaceBetween,
              crossAxisAlignment: WrapCrossAlignment.center,
              spacing: 8,
              runSpacing: 6,
              children: [
                Wrap(
                  crossAxisAlignment: WrapCrossAlignment.center,
                  spacing: 8,
                  runSpacing: 6,
                  children: [
                    const Icon(Icons.terminal, size: 18),
                    const Text('AT Command Console', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13)),
                    ActionChip(label: const Text('AT (Ping)', style: TextStyle(fontSize: 11)), onPressed: isConnected ? () => _send('AT') : null),
                    ActionChip(label: const Text('AT+CSQ', style: TextStyle(fontSize: 11)), onPressed: isConnected ? () => _send('AT+CSQ') : null),
                    ActionChip(label: const Text('AT+CUSD=1,"*123#",15', style: TextStyle(fontSize: 11)), onPressed: isConnected ? () => _send('AT+CUSD=1,"*123#",15') : null),
                  ],
                ),
                TextButton(onPressed: () => setState(() => logs.clear()), child: const Text('Clear Log')),
              ],
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                Expanded(
                  child: SizedBox(
                    height: 38,
                    child: TextField(
                      controller: terminal,
                      decoration: const InputDecoration(
                        hintText: 'Enter AT command...',
                        border: OutlineInputBorder(),
                        contentPadding: EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                      ),
                      onSubmitted: isConnected ? _send : null,
                    ),
                  ),
                ),
                const SizedBox(width: 10),
                FilledButton.icon(
                  onPressed: isConnected ? () => _send(terminal.text) : null,
                  icon: const Icon(Icons.send, size: 16),
                  label: const Text('Send'),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Expanded(
              child: Container(
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  color: Colors.black.withValues(alpha: 0.4),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: ListView.builder(
                  controller: logScrollController,
                  itemCount: logs.length,
                  itemBuilder: (_, i) {
                    final e = logs[i];
                    return SelectableText(
                      '[${e.time.hour.toString().padLeft(2, '0')}:${e.time.minute.toString().padLeft(2, '0')}:${e.time.second.toString().padLeft(2, '0')}] ${e.type.toUpperCase()}: ${e.data}',
                      style: TextStyle(
                        fontFamily: 'monospace',
                        fontSize: 11,
                        color: e.type == 'tx'
                            ? Colors.cyanAccent
                            : e.type == 'rx'
                                ? Colors.greenAccent
                                : e.type == 'error'
                                    ? Colors.redAccent
                                    : Colors.amberAccent,
                      ),
                    );
                  },
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
