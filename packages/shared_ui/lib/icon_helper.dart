import 'package:flutter/material.dart';
import 'package:shared_ui/icons.dart';

// Icon mapping function uses the comprehensive materialIcons map from icons.dart
IconData getIconData(String iconName) {
  return materialIcons[iconName] ?? Icons.star_border;
}
