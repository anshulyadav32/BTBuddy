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
    expect(find.text('ControlBuddy'), findsWidgets);

    // Verify 3 Consolidated Master Navigation Tabs
    expect(find.widgetWithText(Tab, 'Dashboard & Connection'), findsOneWidget);
    expect(find.widgetWithText(Tab, 'Phone & Contacts'), findsOneWidget);
    expect(find.widgetWithText(Tab, 'Messages'), findsOneWidget);

    // Verify Sub-Navigation Segmented Buttons in Dashboard & Connection
    expect(find.byType(SegmentedButton<int>), findsWidgets);
    expect(find.text('Overview & Telemetry'), findsOneWidget);
    expect(find.text('AT Terminal & Logs'), findsWidgets);

    // Verify Metric Cards & Status
    expect(find.text('Battery'), findsOneWidget);
    expect(find.text('Cellular Signal'), findsOneWidget);
  });

  testWidgets('renders Android Phone & Contacts tab with keypad, recents, and contacts',
      (WidgetTester tester) async {
    tester.view.physicalSize = const Size(1800, 1000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });

    await tester.pumpWidget(const BTBuddyApp());
    await tester.pump(const Duration(milliseconds: 200));

    // Tap on Phone & Contacts Tab
    await tester.tap(find.widgetWithText(Tab, 'Phone & Contacts'));
    await tester.pump(const Duration(milliseconds: 500));
    await tester.pump(const Duration(milliseconds: 500));

    // Verify Android Dialer Sub-Navigation
    expect(find.text('Keypad'), findsWidgets);
    expect(find.text('Recents'), findsWidgets);
    expect(find.text('Contacts'), findsWidgets);

    // Verify Android Keypad Grid digits
    expect(find.text('1'), findsWidgets);
    expect(find.text('2'), findsWidgets);
    expect(find.text('ABC'), findsWidgets);
    expect(find.text('0'), findsWidgets);

    // Verify Dual SIM or Call button
    expect(find.textContaining('SIM'), findsWidgets);
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

    // Tap on AT Terminal segment
    await tester.ensureVisible(find.text('AT Terminal & Logs').first);
    await tester.tap(find.text('AT Terminal & Logs').first);
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('AT Command Console'), findsOneWidget);
  });
}
