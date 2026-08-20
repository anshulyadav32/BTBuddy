import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:btbuddy/app.dart';
import 'package:btbuddy/widgets/logo_badge.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('shows the BTBuddy interface and 3 consolidated master tabs',
      (WidgetTester tester) async {
    tester.view.physicalSize = const Size(1800, 1000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });

    await tester.pumpWidget(const BTBuddyApp());
    await tester.pump(const Duration(milliseconds: 200));

    // Verify Title & LogoBadge
    expect(find.byType(LogoBadge), findsWidgets);
    expect(find.text('BTBuddy'), findsWidgets);

    // Verify 3 Consolidated Master Navigation Tabs
    expect(find.widgetWithText(Tab, 'Dashboard & Connection'), findsOneWidget);
    expect(find.widgetWithText(Tab, 'Phone, Contacts & USSD'), findsOneWidget);
    expect(find.widgetWithText(Tab, 'Messages'), findsOneWidget);

    // Verify Sub-Navigation Segmented Buttons in Dashboard & Connection
    expect(find.byType(SegmentedButton<int>), findsWidgets);
    expect(find.text('Overview & Telemetry'), findsOneWidget);
    expect(find.text('BT Notifier'), findsWidgets);
    expect(find.text('AT Terminal & Logs'), findsWidgets);

    // Verify Metric Cards & Status
    expect(find.text('Battery'), findsOneWidget);
    expect(find.text('Cellular Signal'), findsOneWidget);
  });

  testWidgets('renders unified Phone, Contacts & USSD tab with keypad, USSD presets, and phonebook',
      (WidgetTester tester) async {
    tester.view.physicalSize = const Size(1800, 1000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });

    await tester.pumpWidget(const BTBuddyApp());
    await tester.pump(const Duration(milliseconds: 200));

    // Tap on Phone, Contacts & USSD Tab
    await tester.tap(find.widgetWithText(Tab, 'Phone, Contacts & USSD'));
    await tester.pump(const Duration(milliseconds: 500));
    await tester.pump(const Duration(milliseconds: 500));

    // Verify Keypad & USSD Engine Header
    expect(find.text('SMART KEYPAD & USSD ENGINE'), findsOneWidget);
    expect(find.text('CALL'), findsOneWidget);
    expect(find.text('USSD'), findsOneWidget);

    // Verify USSD Quick Presets
    expect(find.text('*123# (Main Balance)'), findsOneWidget);
    expect(find.text('*121# (Offers & Packs)'), findsOneWidget);
    expect(find.text('*100# (Account Info)'), findsOneWidget);

    // Verify Live Status Card
    expect(find.text('LIVE CALL & DTMF STATUS'), findsOneWidget);
    expect(find.text('USSD SESSION RESPONDER'), findsOneWidget);

    // Verify Contacts Panel
    expect(find.textContaining('PHONEBOOK & CONTACTS'), findsOneWidget);
    expect(find.text('Search contacts by name or number...'), findsOneWidget);

    // Verify History Panel
    expect(find.textContaining('USSD Execution History'), findsOneWidget);
  });

  testWidgets('switches sub-tabs in Dashboard & Connection hub',
      (WidgetTester tester) async {
    tester.view.physicalSize = const Size(1800, 1000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });

    await tester.pumpWidget(const BTBuddyApp());
    await tester.pump(const Duration(milliseconds: 200));

    // Tap on Bluetooth & Eject segment
    await tester.ensureVisible(find.text('Bluetooth & Eject (0)').first);
    await tester.tap(find.text('Bluetooth & Eject (0)').first);
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('BLUETOOTH DEVICE MANAGER & EJECT'), findsOneWidget);

    // Tap on BT Notifier segment
    await tester.ensureVisible(find.text('BT Notifier').first);
    await tester.tap(find.text('BT Notifier').first);
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('PUSH NOTIFICATION TO PHONE (BT NOTIFIER)'), findsOneWidget);

    // Tap on AT Terminal segment
    await tester.ensureVisible(find.text('AT Terminal & Logs').first);
    await tester.tap(find.text('AT Terminal & Logs').first);
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('AT Command Console'), findsOneWidget);
  });
}
