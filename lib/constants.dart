import 'package:flutter/material.dart';

const musicDir = '/storage/emulated/0/Music';
const defaultDir = musicDir;
const amber = Color(0xFFF2B632);

const kDarkSurface = Color(0xFF0F1015);
const kDarkSheet = Color(0xFF14151B);
const kDarkCard = Color(0xFF1B1D25);

bool _dark(BuildContext c) => Theme.of(c).brightness == Brightness.dark;
Color accent(BuildContext c) => Theme.of(c).colorScheme.primary;
Color okColor(BuildContext c) =>
    _dark(c) ? Colors.greenAccent : Colors.green.shade800;
Color errColor(BuildContext c) =>
    _dark(c) ? Colors.redAccent : Colors.red.shade800;

Color appBgColor(BuildContext c) =>
    _dark(c) ? kDarkSurface : Theme.of(c).scaffoldBackgroundColor;
Color sheetBgColor(BuildContext c) =>
    _dark(c) ? kDarkSheet : Theme.of(c).colorScheme.surface;
Color cardBgColor(BuildContext c) =>
    _dark(c) ? kDarkCard : Theme.of(c).colorScheme.surfaceContainerHigh;
