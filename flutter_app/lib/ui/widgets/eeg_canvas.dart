import 'dart:typed_data';
import 'package:flutter/material.dart';

class EegCanvasWidget extends StatelessWidget {
  final Float64List ch1Data;
  final Float64List ch2Data;
  final Float64List? ch3Data;
  final Float64List? ch4Data;
  final bool isDual;
  final double uvScale;
  final bool isSeizure;

  const EegCanvasWidget({
    Key? key,
    required this.ch1Data,
    required this.ch2Data,
    this.ch3Data,
    this.ch4Data,
    required this.isDual,
    required this.uvScale,
    required this.isSeizure,
  }) : super(key: key);

  @override
  Widget build(BuildContext context) {
    return CustomPaint(
      painter: _EegPainter(
        ch1: ch1Data,
        ch2: ch2Data,
        ch3: ch3Data,
        ch4: ch4Data,
        isDual: isDual,
        uvScale: uvScale,
        isSeizure: isSeizure,
      ),
      child: Container(),
    );
  }
}

class _EegPainter extends CustomPainter {
  final Float64List ch1;
  final Float64List ch2;
  final Float64List? ch3;
  final Float64List? ch4;
  final bool isDual;
  final double uvScale;
  final bool isSeizure;

  _EegPainter({
    required this.ch1,
    required this.ch2,
    this.ch3,
    this.ch4,
    required this.isDual,
    required this.uvScale,
    required this.isSeizure,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final w = size.width;
    final h = size.height;

    // Draw grid background
    final gridPaint = Paint()
      ..color = const Color(0x14FFFFFF)
      ..strokeWidth = 1.0;

    for (double x = 0; x < w; x += w / 5) {
      canvas.drawLine(Offset(x, 0), Offset(x, h), gridPaint);
    }

    final numChannels = isDual ? 4 : 2;
    final laneHeight = h / numChannels;

    // Lane separators
    final sepPaint = Paint()
      ..color = const Color(0x1FFFFFFF)
      ..strokeWidth = 1.0;

    for (int i = 1; i < numChannels; i++) {
      canvas.drawLine(Offset(0, i * laneHeight), Offset(w, i * laneHeight), sepPaint);
    }

    // Draw Channels
    _drawLane(canvas, ch1, 0, laneHeight, w, const Color(0xFF00F2FE));
    _drawLane(canvas, ch2, 1, laneHeight, w, const Color(0xFFA855F7));

    if (isDual && ch3 != null && ch4 != null) {
      _drawLane(canvas, ch3!, 2, laneHeight, w, const Color(0xFFF59E0B));
      _drawLane(canvas, ch4!, 3, laneHeight, w, const Color(0xFF10B981));
    }
  }

  void _drawLane(Canvas canvas, Float64List data, int laneIdx, double laneH, double width, Color color) {
    if (data.isEmpty) return;

    final centerY = laneIdx * laneH + (laneH / 2);
    final scaleY = (laneH * 0.45) / uvScale;

    final path = Path();
    final step = width / data.length;

    for (int i = 0; i < data.length; i++) {
      final x = i * step;
      final y = centerY - (data[i] * scaleY);
      if (i == 0) {
        path.moveTo(x, y);
      } else {
        path.lineTo(x, y);
      }
    }

    // Glow effect
    final glowPaint = Paint()
      ..color = color.withValues(alpha: isSeizure ? 0.6 : 0.25)
      ..strokeWidth = isSeizure ? 4.5 : 3.0
      ..style = PaintingStyle.stroke
      ..maskFilter = MaskFilter.blur(BlurStyle.normal, isSeizure ? 6.0 : 3.0);

    canvas.drawPath(path, glowPaint);

    // Sharp Core Waveform
    final tracePaint = Paint()
      ..color = color
      ..strokeWidth = 2.0
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;

    canvas.drawPath(path, tracePaint);
  }

  @override
  bool shouldRepaint(covariant _EegPainter oldDelegate) => true;
}
