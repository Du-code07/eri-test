import 'package:flutter/material.dart';

import '../widgets/app_colors.dart';

/// 시작 화면: 투명 배경의 책 읽는 이리 애니메이션(assets/splash/splash_anim.webp)이
/// 현재 테마 배경색(라이트·편안함·다크) 위에서 바로 재생된 뒤 사라짐
class SplashOverlay extends StatefulWidget {
  const SplashOverlay({super.key, required this.onDone});
  final VoidCallback onDone;

  /// 앱 이름 (설치한 앱 이름과 같게)
  static const String appName = '이리ERI';

  @override
  State<SplashOverlay> createState() => _SplashOverlayState();
}

class _SplashOverlayState extends State<SplashOverlay> with SingleTickerProviderStateMixin {
  static const int _totalMs = 4100;
  static const String _animAsset = 'assets/splash/splash_anim.webp';
  static const String _stillAsset = 'assets/splash/splash_still.webp';

  late final AnimationController _c = AnimationController(vsync: this, duration: const Duration(milliseconds: _totalMs));

  double _seg(double t, double a, double b, [Curve curve = Curves.linear]) {
    if (t <= a) return 0;
    if (t >= b) return 1;
    return curve.transform((t - a) / (b - a));
  }

  double _ms(int ms) => ms / _totalMs;

  bool _started = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_started) return;
    _started = true;
    final String target = Anim.off.value ? _stillAsset : _animAsset;
    precacheImage(AssetImage(target), context)
        .catchError((_) {})
        .timeout(const Duration(milliseconds: 600), onTimeout: () {})
        .whenComplete(_start);
  }

  void _start() {
    if (!mounted) return;
    if (Anim.off.value) {
      _c.value = _ms(2500);
      Future<void>.delayed(const Duration(milliseconds: 1000), () {
        if (mounted) widget.onDone();
      });
      return;
    }
    _c.forward().whenCompleteOrCancel(() {
      if (mounted) widget.onDone();
    });
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final Color bg = Theme.of(context).scaffoldBackgroundColor;
    final Color fg = Theme.of(context).colorScheme.onSurface;
    const double animSize = 210;
    final String assetPath = Anim.off.value ? _stillAsset : _animAsset;

    return Material(
      type: MaterialType.transparency,
      child: AbsorbPointer(
        child: AnimatedBuilder(
          animation: _c,
          builder: (context, _) {
            final double t = _c.value;
            final double intro = _seg(t, 0, _ms(450), Curves.easeOutCubic);
            final double name = _seg(t, _ms(250), _ms(700), Curves.easeOutCubic);
            final double out = _seg(t, _ms(3750), 1, Curves.easeInCubic);

            return Opacity(
              opacity: (1 - out).clamp(0.0, 1.0),
              child: ColoredBox(
                color: bg,
                child: Center(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Opacity(
                        opacity: 1.0,
                        child: Transform.scale(
                          scale: (0.95 + 0.05 * intro) * (1 + 0.04 * out),
                          child: SizedBox(
                            width: animSize,
                            height: animSize,
                            child: Image.asset(
                              assetPath,
                              fit: BoxFit.contain,
                              filterQuality: FilterQuality.high,
                              gaplessPlayback: true,
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(height: 14),
                      Opacity(
                        opacity: name.clamp(0.0, 1.0),
                        child: Transform.translate(
                          offset: Offset(0, 14 * (1 - name)),
                          child: Text(
                            SplashOverlay.appName,
                            style: TextStyle(color: fg, fontSize: 26, fontWeight: FontWeight.w800, letterSpacing: 0.6),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            );
          },
        ),
      ),
    );
  }
}
