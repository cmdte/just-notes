import 'package:flutter/material.dart';

class Note {
  Note({
    required this.id,
    required this.title,
    required this.content,
    required this.colorValue,
    required this.updatedAt,
    required this.order,
  });

  final String id;
  String title;
  String content;
  int colorValue;
  DateTime updatedAt;

  /// Lower values appear first on the board (user-arranged order).
  double order;

  Color get color => Color(colorValue);

  Map<String, dynamic> toPlainJson() => <String, dynamic>{
        'title': title,
        'content': content,
        'color': colorValue,
        'updatedAt': updatedAt.toIso8601String(),
        'order': order,
      };

  static Note fromPlainJson(String id, Map<String, dynamic> j) => Note(
        id: id,
        title: j['title'] as String,
        content: j['content'] as String,
        colorValue: j['color'] as int,
        updatedAt: DateTime.parse(j['updatedAt'] as String),
        order: (j['order'] as num).toDouble(),
      );

  Note copy() => Note(
        id: id,
        title: title,
        content: content,
        colorValue: colorValue,
        updatedAt: updatedAt,
        order: order,
      );
}

/// Sticky-note palette. The first entry is the default for new notes.
const stickyPalette = <int>[
  0xFF37474F, // charcoal (default)
  0xFF90CAF9, // blue
  0xFFA5D6A7, // green
  0xFFFFCC80, // orange
  0xFFEF9A9A, // red
];

/// Returns a sticky color tuned for the current brightness:
/// - light mode → original color
/// - dark mode  → desaturated, darker variant (no-op for already-dark colors)
Color stickyColorFor(int value, Brightness brightness) {
  final base = Color(value);
  if (brightness == Brightness.light) return base;
  final hsl = HSLColor.fromColor(base);
  // Already-dark colors stay as-is in dark mode; only pastels get dimmed.
  if (hsl.lightness < 0.5) return base;
  return hsl
      .withLightness((hsl.lightness * 0.35).clamp(0.0, 1.0))
      .withSaturation((hsl.saturation * 0.65).clamp(0.0, 1.0))
      .toColor();
}

/// Foreground text color that contrasts with [bg].
Color stickyForegroundFor(Color bg) =>
    bg.computeLuminance() > 0.5 ? Colors.black87 : Colors.white;

