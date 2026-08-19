import 'dart:async';
import 'package:flutter/material.dart';
import '../models/serial_event.dart';
import '../models/usb_device.dart';
import '../services/btbuddy_service.dart';

class HomeScreen extends StatefulWidget {
  final BTBuddyService service;
  const HomeScreen({super.key, required this.service});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  late final BTBuddyService service;
  final number = TextEditingController();
  final terminal = TextEditingController();
  final scroll = ScrollController();
  final List<SerialEvent> logs = [];
  final Set<String> _autoConnectAttemptedPaths = {};
  StreamSubscription? eventSub;
  Timer? devicePoll;
  List<UsbDevice> devices = [];
  UsbDevice? selected;
  int baud = 115200;
  String status = 'Disconnected';
  String callStatus = 'IDLE';
  bool busy = false;
  bool _refreshing = false;

  @override
  void initState() {
    super.initState();
    service = widget.service;
    selected = service.selectedDevice;
    eventSub = service.serialEvents.listen((event) {
      if (!mounted) return;
      setState(() {
        logs.add(event);
        if (event.type == 'connected') status = 'Connected';
        if (event.type == 'disconnected') status = 'Disconnected';
      });
      _scrollLog();
    });
    _refresh(autoConnect: true);
    devicePoll = Timer.periodic(
      const Duration(seconds: 2),
      (_) => _refresh(autoConnect: true),
    );
  }

  Future<void> _refresh({bool autoConnect = false}) async {
    if (busy || _refreshing) return;
    _refreshing = true;
    try {
      final result = await service.refreshDevices();
      if (!mounted) return;
      setState(() {
        devices = result;
        selected = service.selectedDevice;
        _autoConnectAttemptedPaths.removeWhere(
          (path) => !result.any((device) => device.path == path),
        );
      });

      if (service.connected &&
          !result.any((device) => device.path == service.connectionPath)) {
        _addLog('error', 'USB device was removed: ${service.connectionPath}');
        await _disconnect();
        return;
      }

      final device = selected;
      if (autoConnect &&
          status != 'Connected' &&
          device != null &&
          _autoConnectAttemptedPaths.add(device.path)) {
        _addLog('info', 'USB device detected. Connecting to ${device.path}…');
        await _connect();
      }
    } catch (e) {
      _addLog('error', e.toString());
    } finally {
      _refreshing = false;
    }
  }

  Future<void> _connect() async {
    setState(() => busy = true);
    try {
      await service.connect(baud: baud);
      setState(() => status = 'Connected');
      await _send('AT');
    } catch (e) {
      _addLog('error', e.toString());
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> _disconnect() async {
    try {
      await service.disconnect();
      setState(() => status = 'Disconnected');
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

  Future<void> _call(String action) async {
    if (number.text.trim().isEmpty && action == 'dial') return;
    try {
      String response;
      switch (action) {
        case 'dial':
          response = await service.dial(number.text);
          break;
        case 'answer':
          response = await service.answer();
          break;
        default:
          response = await service.hangup();
      }
      _addLog('rx', response);
      if (action == 'dial') callStatus = 'DIALING';
      if (action == 'answer') callStatus = 'ACTIVE';
      if (action == 'hangup') callStatus = 'IDLE';
      setState(() {});
    } catch (e) {
      _addLog('error', e.toString());
    }
  }

  void _addLog(String type, String data) {
    if (!mounted) return;
    setState(() => logs.add(SerialEvent(type: type, data: data)));
    _scrollLog();
  }

  void _scrollLog() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (scroll.hasClients) {
        scroll.animateTo(
          scroll.position.maxScrollExtent,
          duration: const Duration(milliseconds: 150),
          curve: Curves.easeOut,
        );
      }
    });
  }

  @override
  void dispose() {
    eventSub?.cancel();
    devicePoll?.cancel();
    number.dispose();
    terminal.dispose();
    scroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Row(
          children: [
            Icon(Icons.bluetooth_disabled, size: 24),
            SizedBox(width: 10),
            Text('BTBuddy'),
          ],
        ),
        actions: [
          Icon(
            status == 'Connected' ? Icons.usb : Icons.usb_off,
            color: status == 'Connected' ? Colors.greenAccent : Colors.grey,
          ),
          const SizedBox(width: 18),
        ],
      ),
      body: LayoutBuilder(
        builder: (context, c) {
          final wide = c.maxWidth >= 1050;
          return ListView(
            padding: const EdgeInsets.all(18),
            children: [
              _devicePanel(),
              const SizedBox(height: 14),
              if (wide)
                SizedBox(
                  height: 330,
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Expanded(child: _callPanel()),
                      const SizedBox(width: 14),
                      Expanded(child: _dtmfPanel()),
                    ],
                  ),
                )
              else ...[
                SizedBox(height: 300, child: _callPanel()),
                const SizedBox(height: 14),
                SizedBox(height: 330, child: _dtmfPanel()),
              ],
              const SizedBox(height: 14),
              SizedBox(height: 210, child: _terminalPanel()),
              const SizedBox(height: 14),
              SizedBox(height: 220, child: _logPanel()),
            ],
          );
        },
      ),
    );
  }

  Widget _devicePanel() {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: LayoutBuilder(
          builder: (context, constraints) {
            final compact = constraints.maxWidth < 720;
            final selector = DropdownButtonFormField<UsbDevice>(
              initialValue: selected,
              isExpanded: true,
              decoration: const InputDecoration(
                labelText: 'USB device',
                border: OutlineInputBorder(),
              ),
              items: devices.map((d) {
                return DropdownMenuItem(
                  value: d,
                  child: Text('${d.name}  —  ${d.path}',
                      overflow: TextOverflow.ellipsis),
                );
              }).toList(),
              onChanged: (d) {
                setState(() {
                  selected = d;
                  service.selectedDevice = d;
                });
              },
            );
            final controls = [
              DropdownButton<int>(
                value: baud,
                items: const [
                  DropdownMenuItem(value: 9600, child: Text('9600')),
                  DropdownMenuItem(value: 19200, child: Text('19200')),
                  DropdownMenuItem(value: 38400, child: Text('38400')),
                  DropdownMenuItem(value: 57600, child: Text('57600')),
                  DropdownMenuItem(value: 115200, child: Text('115200')),
                ],
                onChanged: (v) => setState(() => baud = v ?? 115200),
              ),
              OutlinedButton.icon(
                onPressed: _refresh,
                icon: const Icon(Icons.refresh),
                label: const Text('Refresh'),
              ),
              FilledButton.icon(
                onPressed: busy
                    ? null
                    : (status == 'Connected' ? _disconnect : _connect),
                icon: Icon(status == 'Connected' ? Icons.link_off : Icons.link),
                label: Text(status == 'Connected' ? 'Disconnect' : 'Connect'),
              ),
              Text(
                status,
                style: TextStyle(
                  color:
                      status == 'Connected' ? Colors.greenAccent : Colors.grey,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ];

            if (compact) {
              return Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  const Row(children: [
                    Icon(Icons.usb, size: 30),
                    SizedBox(width: 10),
                    Text('USB connection')
                  ]),
                  const SizedBox(height: 14),
                  selector,
                  const SizedBox(height: 12),
                  Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      crossAxisAlignment: WrapCrossAlignment.center,
                      children: controls),
                ],
              );
            }

            return Row(
              children: [
                const Icon(Icons.usb, size: 30),
                const SizedBox(width: 14),
                Expanded(child: selector),
                const SizedBox(width: 12),
                ...controls
                    .expand((control) => [control, const SizedBox(width: 8)])
                    .take(controls.length * 2 - 1),
              ],
            );
          },
        ),
      ),
    );
  }

  Widget _callPanel() {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(18),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('CALL', style: TextStyle(fontWeight: FontWeight.bold)),
            const SizedBox(height: 18),
            TextField(
              controller: number,
              keyboardType: TextInputType.phone,
              decoration: const InputDecoration(
                labelText: 'Phone number',
                prefixIcon: Icon(Icons.phone),
                border: OutlineInputBorder(),
              ),
              onSubmitted: (_) => _call('dial'),
            ),
            const SizedBox(height: 14),
            Wrap(
              spacing: 10,
              runSpacing: 10,
              children: [
                FilledButton.icon(
                  onPressed: status == 'Connected' ? () => _call('dial') : null,
                  icon: const Icon(Icons.phone),
                  label: const Text('Dial'),
                ),
                FilledButton.tonalIcon(
                  onPressed:
                      status == 'Connected' ? () => _call('answer') : null,
                  icon: const Icon(Icons.phone_in_talk),
                  label: const Text('Answer'),
                ),
                FilledButton.tonalIcon(
                  onPressed:
                      status == 'Connected' ? () => _call('hangup') : null,
                  icon: const Icon(Icons.call_end),
                  label: const Text('Hang Up'),
                ),
                OutlinedButton(
                  onPressed: status == 'Connected'
                      ? () async {
                          final r = await service.callStatus();
                          _addLog('rx', r);
                        }
                      : null,
                  child: const Text('Refresh Status'),
                ),
              ],
            ),
            const Spacer(),
            Text('Call status: $callStatus'),
          ],
        ),
      ),
    );
  }

  Widget _dtmfPanel() {
    const keys = [
      '1',
      '2',
      '3',
      '4',
      '5',
      '6',
      '7',
      '8',
      '9',
      '*',
      '0',
      '#',
      'A',
      'B',
      'C',
      'D'
    ];
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(18),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('DTMF', style: TextStyle(fontWeight: FontWeight.bold)),
            const SizedBox(height: 12),
            Expanded(
              child: GridView.count(
                crossAxisCount: 4,
                mainAxisSpacing: 8,
                crossAxisSpacing: 8,
                childAspectRatio: 2.1,
                physics: const NeverScrollableScrollPhysics(),
                children: keys.map((key) {
                  return FilledButton.tonal(
                    onPressed: status == 'Connected'
                        ? () async {
                            _addLog('tx', 'AT+VTS=$key');
                            try {
                              final r = await service.dtmf(key);
                              _addLog('rx', r);
                            } catch (e) {
                              _addLog('error', e.toString());
                            }
                          }
                        : null,
                    child: Text(key, style: const TextStyle(fontSize: 18)),
                  );
                }).toList(),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _terminalPanel() {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          children: [
            Row(
              children: [
                const Text('AT TERMINAL',
                    style: TextStyle(fontWeight: FontWeight.bold)),
                const Spacer(),
                TextButton(
                  onPressed: () => terminal.clear(),
                  child: const Text('Clear'),
                ),
              ],
            ),
            Expanded(
              child: Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: terminal,
                      decoration: const InputDecoration(
                        hintText: 'AT+CSQ',
                        border: OutlineInputBorder(),
                      ),
                      onSubmitted: _send,
                    ),
                  ),
                  const SizedBox(width: 10),
                  FilledButton(
                    onPressed: status == 'Connected'
                        ? () => _send(terminal.text)
                        : null,
                    child: const Text('SEND'),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _logPanel() {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          children: [
            Row(
              children: [
                const Text('TX/RX LOG',
                    style: TextStyle(fontWeight: FontWeight.bold)),
                const Spacer(),
                TextButton(
                  onPressed: () => setState(() => logs.clear()),
                  child: const Text('Clear Log'),
                ),
              ],
            ),
            Expanded(
              child: ListView.builder(
                controller: scroll,
                itemCount: logs.length,
                itemBuilder: (_, i) {
                  final e = logs[i];
                  final prefix = e.type.toUpperCase();
                  return Text(
                    '[${e.time.hour.toString().padLeft(2, '0')}:'
                    '${e.time.minute.toString().padLeft(2, '0')}:'
                    '${e.time.second.toString().padLeft(2, '0')}] '
                    '$prefix: ${e.data}',
                    style: TextStyle(
                      fontFamily: 'monospace',
                      color: e.type == 'error'
                          ? Colors.redAccent
                          : e.type == 'tx'
                              ? Colors.lightBlueAccent
                              : null,
                    ),
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }
}
