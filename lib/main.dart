import 'package:flutter/material.dart';
import 'app.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  PaintingBinding.instance.imageCache.maximumSize = 25;
  PaintingBinding.instance.imageCache.maximumSizeBytes = 10 << 20; // 10MB memory cap
  runApp(const BTBuddyApp());
}
