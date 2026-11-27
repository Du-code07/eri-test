import 'package:flutter/material.dart';

/// 파일 왼쪽 위 끝에 걸쳐 있는 작은 책갈피 모양 즐겨찾기 표시.
/// 컴팩트·와이드·목록형·표지형 모두 터치로 바로 즐겨찾기를 켜고 끈다.
class FavoriteRibbon extends StatelessWidget {
  const FavoriteRibbon({
    super.key,
    required this.active,
    this.onTap,
    this.width = 14,
    this.height = 22,
    this.onImage = false,
    this.isDark = false,
    this.extraHitArea = 0,
    this.extraHitWidth,
    this.extraHitHeight,
  });

  final bool active;
  final VoidCallback? onTap;
  final double width;
  final double height;

  /// 표지(그림) 위에 놓일 때: 어떤 그림 위에서도 보이도록 흰 테두리 + 옅은 그림자
  final bool onImage;
  final bool isDark;

  /// 누르는 범위를 오른쪽·아래로 이만큼 더 넓힘 (책갈피 위치는 그대로)
  final double extraHitArea;
  final double? extraHitWidth;
  final double? extraHitHeight;

  @override
  Widget build(BuildContext context) {
    final Color outline = onImage ? Colors.white : (isDark ? Colors.white60 : Colors.black45);
    final Color emptyFill = onImage ? Colors.black26 : Colors.transparent;
    final double lift = height * 0.32;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: ClipRect(
        clipper: const _ClipAbove(),
        child: SizedBox(
          width: width + 14 + (extraHitWidth ?? extraHitArea),
          height: height + 8 + (extraHitHeight ?? extraHitArea),
          child: Padding(
            padding: const EdgeInsets.only(left: 7),
            child: Align(
              alignment: Alignment.topLeft,
              child: Transform.translate(
                offset: Offset(0, active ? 0 : -lift),
                child: CustomPaint(
                  size: Size(width, height),
                  painter: _RibbonPainter(
                    fill: active ? const Color(0xFFFFCA28) : emptyFill,
                    stroke: active ? const Color(0xFFFFB300) : outline,
                    shadow: onImage,
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// 위쪽만 자르고 옆·아래는 넉넉히 보이게 하는 자르기
class _ClipAbove extends CustomClipper<Rect> {
  const _ClipAbove();

  @override
  Rect getClip(Size size) => Rect.fromLTRB(-size.width, 0, size.width * 2, size.height * 3);

  @override
  bool shouldReclip(_ClipAbove oldClipper) => false;
}

class _RibbonPainter extends CustomPainter {
  _RibbonPainter({required this.fill, required this.stroke, required this.shadow});

  final Color fill;
  final Color stroke;
  final bool shadow;

  @override
  void paint(Canvas canvas, Size size) {
    final double w = size.width, h = size.height;
    final double sw = (w * 0.13).clamp(1.2, 2.0).toDouble();
    final path = Path()
      ..moveTo(sw / 2, -sw)
      ..lineTo(w - sw / 2, -sw)
      ..lineTo(w - sw / 2, h - sw / 2)
      ..lineTo(w / 2, h - w * 0.42)
      ..lineTo(sw / 2, h - sw / 2)
      ..close();
    if (shadow) {
      canvas.drawShadow(path, Colors.black54, 1.5, false);
    }
    canvas.drawPath(path, Paint()..color = fill);
    canvas.drawPath(
      path,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = sw
        ..strokeJoin = StrokeJoin.round
        ..color = stroke,
    );
  }

  @override
  bool shouldRepaint(_RibbonPainter old) => old.fill != fill || old.stroke != stroke || old.shadow != shadow;
}
