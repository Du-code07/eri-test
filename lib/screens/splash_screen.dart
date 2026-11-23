import 'package:flutter/material.dart';

import '../widgets/app_colors.dart';

/// 시작 화면: 책 읽는 이리 애니메이션(assets/splash/splash_anim.webp)이
/// 네모 테두리 없이 크림 배경에서 앱 배경색으로 자연스럽게 스며들며 재생된 뒤 사라짐
class SplashOverlay extends StatefulWidget {
  const SplashOverlay({super.key, required this.onDone});
  final VoidCallback onDone;

  /// 앱 이름 (설치한 앱 이름과 같게)
  static const String appName = '이리ERI';

  @override
  State<SplashOverlay> createState() => _SplashOverlayState();
}

class _SplashOverlayState extends State<SplashOverlay> with SingleTickerProviderStateMixin {
  static const int _totalMs = 3100;
  static const String _animAsset = 'assets/splash/splash_anim.webp';
  static const String _stillAsset = 'assets/splash/splash_still.webp';
  static const Color _creamBg = Color(0xFFEFE0C1);

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
    final bool dark = Theme.of(context).brightness == Brightness.dark;
    const double animSize = 290;
    const double haloSize = 340;
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
            final double out = _seg(t, _ms(2750), 1, Curves.easeInCubic);

            return Opacity(
              opacity: (1 - out).clamp(0.0, 1.0),
              child: ColoredBox(
                color: bg,
                child: Center(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Opacity(
                        opacity: intro.clamp(0.0, 1.0),
                        child: Transform.scale(
                          scale: (0.90 + 0.10 * intro) * (1 + 0.04 * out),
                          child: SizedBox(
                            width: haloSize,
                            height: haloSize,
                            child: Stack(
                              alignment: Alignment.center,
                              children: [
                                // 크림 배경이 앱 뒷배경색으로 부드럽게 동화되도록 넓게 퍼지는 그라데이션
                                IgnorePointer(
                                  child: Container(
                                    width: haloSize,
                                    height: haloSize,
                                    decoration: BoxDecoration(
                                      shape: BoxShape.circle,
                                      gradient: RadialGradient(
                                        colors: [
                                          _creamBg.withValues(alpha: dark ? 0.34 : 0.72),
                                          _creamBg.withValues(alpha: dark ? 0.14 : 0.32),
                                          bg.withValues(alpha: 0.0),
                                        ],
                                        stops: const [0.0, 0.62, 1.0],
                                      ),
                                    ),
                                  ),
                                ),
                                // 네모 테두리 없이 가장자리 크림 배경이 방사형으로 투명하게 스며듦
                                SizedBox(
                                  width: animSize,
                                  height: animSize,
                                  child: ShaderMask(
                                    blendMode: BlendMode.dstIn,
                                    shaderCallback: (Rect bounds) => const RadialGradient(
                                      colors: [
                                        Colors.white,
                                        Colors.white,
                                        Color(0x78FFFFFF),
                                        Colors.transparent,
                                      ],
                                      stops: [0.0, 0.68, 0.86, 1.0],
                                    ).createShader(bounds),
                                    child: Image.asset(
                                      assetPath,
                                      fit: BoxFit.contain,
                                      filterQuality: FilterQuality.high,
                                      gaplessPlayback: true,
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(height: 6),
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
