import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../config/app_config.dart';
import '../theme/app_theme.dart';

/// The device on the start page, turned with a finger.
///
/// It shows the picture at [imageAsset] when that file exists, and otherwise a
/// stand-in built here from stacked layers so that it has real thickness when it
/// turns. Either way the drag is the same: left and right spin it, up and down tip
/// it, and it stays where it was left.
///
/// This is a 2D stand-in for a 3D model. To show a real model (a .glb file),
/// replace [_Turntable.child] with a model viewer widget (for example
/// `model_viewer_plus`, which needs a WebView and cannot be checked without a
/// phone); the rest of the page does not change.
class DeviceHero extends StatefulWidget {
  final String imageAsset;
  final double height;

  const DeviceHero({super.key, this.imageAsset = kDeviceImageAsset, this.height = 180});

  @override
  State<DeviceHero> createState() => _DeviceHeroState();
}

class _DeviceHeroState extends State<DeviceHero> {
  late Future<Uint8List?> _image = _load(widget.imageAsset);
  double _yaw = -0.55;
  double _pitch = 0.18;

  static Future<Uint8List?> _load(String path) async {
    if (path.isEmpty) return null;
    try {
      return (await rootBundle.load(path)).buffer.asUint8List();
    } catch (_) {
      return null; // no picture supplied: the stand-in is shown
    }
  }

  @override
  void didUpdateWidget(DeviceHero old) {
    super.didUpdateWidget(old);
    if (old.imageAsset != widget.imageAsset) _image = _load(widget.imageAsset);
  }

  void _drag(DragUpdateDetails d) => setState(() {
        _yaw += d.delta.dx * 0.011;
        _pitch = (_pitch - d.delta.dy * 0.008).clamp(-0.7, 0.7);
      });

  @override
  Widget build(BuildContext context) {
    return Semantics(
      label: 'The Neo device. Drag to turn it.',
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onPanUpdate: _drag,
        child: SizedBox(
          height: widget.height,
          child: Column(children: [
            Expanded(
              child: FutureBuilder<Uint8List?>(
                future: _image,
                builder: (context, snap) {
                  final bytes = snap.data;
                  return _Turntable(
                    key: const ValueKey('device-turntable'),
                    yaw: _yaw,
                    pitch: _pitch,
                    child: bytes == null ? null : Image.memory(bytes, fit: BoxFit.contain),
                  );
                },
              ),
            ),
            const Text('Drag to turn', style: TextStyle(fontSize: 11, color: AppColors.textMuted)),
          ]),
        ),
      ),
    );
  }
}

/// Draws [child] (a picture), or the stand-in when there is none, turned by
/// [yaw] around the vertical axis and [pitch] around the horizontal one.
class _Turntable extends StatelessWidget {
  final double yaw;
  final double pitch;
  final Widget? child;

  const _Turntable({super.key, required this.yaw, required this.pitch, this.child});

  static const _layers = 18;
  static const _depth = 15.0; // half the thickness of the stand-in

  Matrix4 _view() => Matrix4.identity()
    ..setEntry(3, 2, 0.0011)
    ..rotateX(pitch)
    ..rotateY(yaw);

  @override
  Widget build(BuildContext context) {
    final picture = child;
    if (picture != null) {
      return Center(child: Transform(alignment: Alignment.center, transform: _view(), child: picture));
    }
    final view = _view();
    return Center(
      child: Stack(alignment: Alignment.center, clipBehavior: Clip.none, children: [
        for (var i = 0; i < _layers; i++)
          Transform(
            alignment: Alignment.center,
            transform: view.multiplied(Matrix4.translationValues(0, 0, -_depth + 2 * _depth * i / (_layers - 1))),
            child: _Slab(front: i == _layers - 1, shade: i / (_layers - 1)),
          ),
      ]),
    );
  }
}

/// One slice of the stand-in: a rounded body, with a disc and a light on the front one.
class _Slab extends StatelessWidget {
  final bool front;
  final double shade; // 0 = back, 1 = front

  const _Slab({required this.front, required this.shade});

  @override
  Widget build(BuildContext context) {
    final body = Color.lerp(const Color(0xFF0B1220), const Color(0xFF2B3546), shade)!;
    return SizedBox(
      width: 190,
      height: 84,
      child: DecoratedBox(
        decoration: BoxDecoration(color: body, borderRadius: BorderRadius.circular(42)),
        child: front
            ? Stack(children: [
                Positioned(
                  left: 8,
                  top: 8,
                  child: Container(
                    width: 68,
                    height: 68,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: const Color(0xFF0B1220),
                      border: Border.all(color: const Color(0xFF3B475C), width: 3),
                    ),
                  ),
                ),
                Positioned(
                  right: 30,
                  top: 38,
                  child: Container(
                    width: 8,
                    height: 8,
                    decoration: const BoxDecoration(shape: BoxShape.circle, color: AppColors.accent),
                  ),
                ),
              ])
            : null,
      ),
    );
  }
}
