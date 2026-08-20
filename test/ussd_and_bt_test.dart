import 'package:flutter_test/flutter_test.dart';
import 'package:btbuddy/models/ussd_session.dart';
import 'package:btbuddy/models/bluetooth_device_item.dart';
import 'package:btbuddy/models/bt_notification.dart';
import 'package:btbuddy/models/usb_device.dart';

void main() {
  group('USSD Session Parser Tests', () {
    test('parses completed USSD response (+CUSD: 0)', () {
      const raw = '+CUSD: 0,"Your balance is \$25.00. Valid till 31-Dec.",15';
      final session = UssdSession.parse(raw, query: '*123#');

      expect(session.query, equals('*123#'));
      expect(session.status, equals(UssdStatus.noActionRequired));
      expect(session.response, contains('Your balance is \$25.00'));
      expect(session.isInteractive, isFalse);
      expect(session.statusLabel, equals('Completed'));
    });

    test('parses interactive prompt USSD (+CUSD: 1)', () {
      const raw = '+CUSD: 1,"1. Balance\n2. Packs\n3. Recharges\n0. Exit",15';
      final session = UssdSession.parse(raw, query: '*121#');

      expect(session.query, equals('*121#'));
      expect(session.status, equals(UssdStatus.actionRequired));
      expect(session.isInteractive, isTrue);
      expect(session.response, contains('1. Balance'));
      expect(session.statusLabel, contains('Interactive Prompt'));
    });

    test('parses terminated by network (+CUSD: 2)', () {
      const raw = '+CUSD: 2';
      final session = UssdSession.parse(raw, query: '*99#');

      expect(session.status, equals(UssdStatus.terminatedByNetwork));
      expect(session.isInteractive, isFalse);
    });

    test('decodes UCS2 hex encoded USSD string', () {
      // Hex for "Hello" -> 0048 0065 006C 006C 006F
      const raw = '+CUSD: 0,"00480065006C006C006F",72';
      final session = UssdSession.parse(raw, query: '*100#');

      expect(session.response, equals('Hello'));
      expect(session.status, equals(UssdStatus.noActionRequired));
    });
  });

  group('Bluetooth Device Item Tests', () {
    test('creates item from map with proper classification', () {
      final map = {
        'name': 'KECHAODA K116',
        'address': '00:1A:7D:DA:71:13',
        'connected': true,
        'paired': true,
        'favorite': false,
        'deviceClass': 512,
        'rssi': -45,
      };

      final item = BluetoothDeviceItem.fromMap(map);
      expect(item.name, equals('KECHAODA K116'));
      expect(item.address, equals('00:1A:7D:DA:71:13'));
      expect(item.connected, isTrue);
      expect(item.paired, isTrue);
      expect(item.isPhone, isTrue);
      expect(item.typeLabel, equals('Mobile Phone'));
    });

    test('identifies audio bluetooth endpoint', () {
      final map = {
        'name': 'AirPods Pro Wireless Headset',
        'address': 'AA:BB:CC:DD:EE:FF',
        'connected': false,
        'paired': true,
        'deviceClass': 1024,
      };

      final item = BluetoothDeviceItem.fromMap(map);
      expect(item.isPhone, isFalse);
      expect(item.typeLabel, equals('Audio Endpoint'));
    });
  });

  group('2-Way Notification Model Tests', () {
    test('creates incoming call notification (Phone -> Mac)', () {
      final notif = BtNotification.phoneIncomingCall(
        callerNumber: '+1234567890',
        callerName: 'John Doe',
      );

      expect(notif.direction, equals(NotificationDirection.phoneToMac));
      expect(notif.type, equals(BtNotificationType.incomingCall));
      expect(notif.title, contains('John Doe'));
      expect(notif.body, equals('+1234567890'));
    });

    test('creates Mac push notification (Mac -> Phone)', () {
      final notif = BtNotification.macPush(
        title: 'Meeting in 10m',
        body: 'Join Google Meet link on Mac',
        appName: 'Calendar',
      );

      expect(notif.direction, equals(NotificationDirection.macToPhone));
      expect(notif.type, equals(BtNotificationType.appAlert));
      expect(notif.appName, equals('Calendar'));
      expect(notif.title, equals('Meeting in 10m'));
    });

    test('creates low battery notification (Phone -> Mac)', () {
      final notif = BtNotification.phoneBatteryWarning(level: 15);

      expect(notif.direction, equals(NotificationDirection.phoneToMac));
      expect(notif.type, equals(BtNotificationType.lowBattery));
      expect(notif.title, contains('Low Phone Battery'));
      expect(notif.body, contains('15%'));
      expect(notif.metadata?['batteryLevel'], equals(15));
    });
  });

  group('USB and Serial Device Model Tests', () {
    test('parses USB modem device correctly', () {
      final map = {
        'name': 'KECHAODA',
        'manufacturer': 'MediaTek Inc',
        'model': 'KECHAODA',
        'path': '/dev/cu.usbmodem22200',
        'vendorId': 3725,
        'productId': 3,
        'usb': true,
        'btConnected': false,
        'btPaired': false,
      };

      final device = UsbDevice.fromMap(map);
      expect(device.name, equals('KECHAODA'));
      expect(device.manufacturer, equals('MediaTek Inc'));
      expect(device.path, equals('/dev/cu.usbmodem22200'));
      expect(device.vendorId, equals(3725));
      expect(device.productId, equals(3));
      expect(device.usb, isTrue);
      expect(device.btConnected, isFalse);
    });

    test('parses Bluetooth serial port device correctly', () {
      final map = {
        'name': 'KECHAODA',
        'manufacturer': 'Bluetooth (Mobile Phone)',
        'model': '',
        'path': '/dev/cu.KECHAODA',
        'vendorId': 0,
        'productId': 0,
        'usb': false,
        'btConnected': true,
        'btPaired': true,
        'btAddress': '37-1e-7c-53-62-61',
      };

      final device = UsbDevice.fromMap(map);
      expect(device.name, equals('KECHAODA'));
      expect(device.manufacturer, equals('Bluetooth (Mobile Phone)'));
      expect(device.path, equals('/dev/cu.KECHAODA'));
      expect(device.usb, isFalse);
      expect(device.btConnected, isTrue);
      expect(device.btPaired, isTrue);
      expect(device.btAddress, equals('37-1e-7c-53-62-61'));
    });
  });
}
