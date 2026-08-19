#!/bin/bash
set -euo pipefail

flutter create --platforms=macos .
flutter pub get

echo ""
echo "BTBuddy macOS scaffold created."
echo "Run:"
echo "  flutter run -d macos"
