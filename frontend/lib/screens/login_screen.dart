import 'package:flutter/material.dart';
import '../services/auth_service.dart';
import '../widgets/server_settings_dialog.dart';

/// Sign-in screen. On success, AuthService notifies listeners and the auth
/// gate swaps this out for the app — no manual navigation needed.
///
/// Responsive: past [_wideBreakpoint] (desktop windows, the 5K iMac) it
/// splits into a hero pane (scaled-up pulsing logo) beside a sign-in card,
/// instead of stretching the phone-sized centered column across the void.
class LoginScreen extends StatefulWidget {
  const LoginScreen({super.key});

  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  static const _wideBreakpoint = 1100.0;

  final _usernameController = TextEditingController();
  final _passwordController = TextEditingController();
  final _passwordFocus = FocusNode();
  bool _submitting = false;
  bool _obscure = true;
  String? _error;

  @override
  void dispose() {
    _usernameController.dispose();
    _passwordController.dispose();
    _passwordFocus.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    final username = _usernameController.text.trim();
    final password = _passwordController.text;
    if (username.isEmpty || password.isEmpty) {
      setState(() => _error = 'Enter your username and password');
      return;
    }
    setState(() {
      _submitting = true;
      _error = null;
    });
    final error = await AuthService.instance.login(username, password);
    if (!mounted) return;
    setState(() {
      _submitting = false;
      _error = error; // null on success; the gate swaps us out
    });
  }

  Future<void> _openServerSettings() async {
    final changed = await showDialog<bool>(
      context: context,
      builder: (_) => const ServerSettingsDialog(),
    );
    if (changed == true && mounted) {
      // A stale "can't reach server" error may no longer apply.
      setState(() => _error = null);
    }
  }

  /// The credential fields + error + button, shared by both layouts.
  Widget _buildForm() {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        TextField(
          controller: _usernameController,
          enabled: !_submitting,
          textInputAction: TextInputAction.next,
          autofillHints: const [AutofillHints.username],
          decoration: const InputDecoration(
            labelText: 'Username',
            prefixIcon: Icon(Icons.person_outline),
            border: OutlineInputBorder(),
          ),
          onSubmitted: (_) => _passwordFocus.requestFocus(),
        ),
        const SizedBox(height: 14),
        TextField(
          controller: _passwordController,
          focusNode: _passwordFocus,
          enabled: !_submitting,
          obscureText: _obscure,
          autofillHints: const [AutofillHints.password],
          decoration: InputDecoration(
            labelText: 'Password',
            prefixIcon: const Icon(Icons.lock_outline),
            border: const OutlineInputBorder(),
            suffixIcon: IconButton(
              icon: Icon(
                _obscure ? Icons.visibility : Icons.visibility_off,
              ),
              onPressed: () => setState(() => _obscure = !_obscure),
            ),
          ),
          onSubmitted: (_) => _submit(),
        ),
        if (_error != null) ...[
          const SizedBox(height: 14),
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              color: Colors.red.withOpacity(0.15),
              borderRadius: BorderRadius.circular(6),
              border: Border.all(color: Colors.red),
            ),
            child: Row(
              children: [
                const Icon(Icons.error_outline, color: Colors.red, size: 18),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    _error!,
                    style: const TextStyle(color: Colors.red),
                  ),
                ),
              ],
            ),
          ),
        ],
        const SizedBox(height: 22),
        SizedBox(
          width: double.infinity,
          height: 48,
          child: ElevatedButton(
            onPressed: _submitting ? null : _submit,
            style: ElevatedButton.styleFrom(
              backgroundColor: const Color(0xFF00d4ff),
              foregroundColor: Colors.black,
            ),
            child: _submitting
                ? const SizedBox(
                    width: 22,
                    height: 22,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      color: Colors.black,
                    ),
                  )
                : const Text(
                    'Sign In',
                    style: TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
          ),
        ),
      ],
    );
  }

  Widget _wordmark(double fontSize) {
    return Text(
      'NASRadio',
      style: TextStyle(
        fontSize: fontSize,
        fontWeight: FontWeight.bold,
        color: const Color(0xFF00d4ff),
        letterSpacing: 3,
        shadows: const [
          Shadow(color: Color(0x8800d4ff), blurRadius: 16),
        ],
      ),
    );
  }

  /// Phone / small-window layout: the original centered column.
  Widget _narrowLayout() {
    return Center(
      child: SingleChildScrollView(
        clipBehavior: Clip.none,
        padding: const EdgeInsets.all(24),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 400),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const _PulsingLogo(),
              const SizedBox(height: 8),
              _wordmark(28),
              const SizedBox(height: 4),
              const Text(
                'Sign in to continue',
                style: TextStyle(
                  fontSize: 13,
                  color: Colors.grey,
                  letterSpacing: 2,
                ),
              ),
              const SizedBox(height: 28),
              _buildForm(),
            ],
          ),
        ),
      ),
    );
  }

  /// Desktop / large-window layout: hero pane + sign-in card, sized to
  /// actually inhabit a big display instead of floating in it.
  Widget _wideLayout(BoxConstraints constraints) {
    // Scale the hero with the window, within sane bounds.
    final heroSize =
        (constraints.maxHeight * 0.55).clamp(380.0, 640.0).toDouble();
    final logoSize = heroSize * 0.42;

    return Row(
      children: [
        Expanded(
          flex: 5,
          child: Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                _PulsingLogo(size: heroSize, logoSize: logoSize),
                const SizedBox(height: 12),
                _wordmark(46),
                const SizedBox(height: 8),
                const Text(
                  'YOUR LIBRARY. EVERY ROOM. EVERY SCREEN.',
                  style: TextStyle(
                    fontSize: 13,
                    color: Colors.grey,
                    letterSpacing: 3.5,
                  ),
                ),
              ],
            ),
          ),
        ),
        Expanded(
          flex: 4,
          child: Center(
            child: SingleChildScrollView(
              clipBehavior: Clip.none,
              padding: const EdgeInsets.all(32),
              child: Container(
                constraints: const BoxConstraints(maxWidth: 440),
                padding: const EdgeInsets.fromLTRB(36, 40, 36, 36),
                decoration: BoxDecoration(
                  color: const Color(0xFF0d1b2a).withOpacity(0.72),
                  borderRadius: BorderRadius.circular(20),
                  border: Border.all(color: Colors.white.withOpacity(0.07)),
                  boxShadow: const [
                    BoxShadow(
                      color: Color(0x33000000),
                      blurRadius: 40,
                      offset: Offset(0, 16),
                    ),
                  ],
                ),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      'Welcome back',
                      style: TextStyle(
                        fontSize: 24,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    const SizedBox(height: 6),
                    const Text(
                      'Sign in to continue',
                      style: TextStyle(
                        fontSize: 13,
                        color: Colors.grey,
                        letterSpacing: 2,
                      ),
                    ),
                    const SizedBox(height: 28),
                    _buildForm(),
                  ],
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF0a0e27),
      body: Stack(
        children: [
          Container(
            decoration: const BoxDecoration(
              gradient: RadialGradient(
                center: Alignment(0, -0.28),
                radius: 1.15,
                colors: [Color(0xFF132549), Color(0xFF0a0e27)],
              ),
            ),
            child: LayoutBuilder(
              builder: (context, constraints) =>
                  constraints.maxWidth >= _wideBreakpoint
                      ? _wideLayout(constraints)
                      : _narrowLayout(),
            ),
          ),
          Positioned(
            top: 8,
            right: 8,
            child: SafeArea(
              child: IconButton(
                icon: const Icon(Icons.settings_outlined, color: Colors.grey),
                tooltip: 'Server address',
                onPressed: _submitting ? null : _openServerSettings,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Animated NASRadio logo for the login screen — mirrors the Chromecast idle
/// screen: cyan signal-rings pulse outward from behind a gently breathing logo.
class _PulsingLogo extends StatefulWidget {
  final double size;
  final double logoSize;

  const _PulsingLogo({this.size = 320, this.logoSize = 150});

  @override
  State<_PulsingLogo> createState() => _PulsingLogoState();
}

class _PulsingLogoState extends State<_PulsingLogo>
    with TickerProviderStateMixin {
  late final AnimationController _rings;
  late final AnimationController _breathe;

  @override
  void initState() {
    super.initState();
    // 4.8s ring cycle (matches the cast receiver's idlePulse), 4 staggered rings.
    _rings = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 4800),
    )..repeat();
    _breathe = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 2400),
    )..repeat(reverse: true);
  }

  @override
  void dispose() {
    _rings.dispose();
    _breathe.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final size = widget.size;
    // The 1024px logo asset has its rounded corners baked in on a
    // transparent background — no runtime ClipRRect needed. The glow
    // shadow sits on a rect matching the artwork's corner radius
    // (rx 90 at 512 viewBox = 0.176 of the edge).
    final radius = widget.logoSize * 0.176;
    return SizedBox(
      width: size,
      height: size,
      child: Stack(
        alignment: Alignment.center,
        clipBehavior: Clip.none,
        children: [
          // RepaintBoundary: the sweeping rings repaint every frame —
          // isolate them so they don't invalidate (or get invalidated
          // by) anything else. Same for the breathing logo: its layer
          // is rastered once and the per-frame translate/scale becomes
          // a cheap layer transform instead of a shadow re-blur (the
          // 5K jitter fix, along with disabling Impeller's SDF path).
          RepaintBoundary(
            child: AnimatedBuilder(
              animation: _rings,
              builder: (context, _) => CustomPaint(
                size: Size(size, size),
                painter: _RingsPainter(_rings.value, size * 0.344),
              ),
            ),
          ),
          AnimatedBuilder(
            animation: _breathe,
            builder: (context, child) {
              final t = Curves.easeInOut.transform(_breathe.value);
              return Transform.translate(
                offset: Offset(0, -4 * t),
                child: Transform.scale(scale: 1 + 0.015 * t, child: child),
              );
            },
            child: RepaintBoundary(
              child: Container(
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(radius),
                  boxShadow: [
                    BoxShadow(
                      color: const Color(0xFF00d4ff).withOpacity(0.5),
                      blurRadius: 52,
                      spreadRadius: 4,
                    ),
                  ],
                ),
                child: Image.asset(
                  'assets/images/nasradio_logo.png',
                  width: widget.logoSize,
                  height: widget.logoSize,
                  filterQuality: FilterQuality.high,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _RingsPainter extends CustomPainter {
  final double phase; // 0..1, the master ring controller value
  final double baseRadius; // radius at scale 1.0 (was fixed 110 @ 320px box)
  _RingsPainter(this.phase, this.baseRadius);

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2);
    for (int i = 0; i < 4; i++) {
      // Four rings, evenly staggered through the cycle (cast uses 1.2s delays).
      final t = (phase + i * 0.25) % 1.0;

      // scale 0.3 -> 5.0, eased out — sweeps across the whole screen
      final scale = 0.3 + (5.0 - 0.3) * Curves.easeOut.transform(t);

      // opacity: ramp up to 0.55 by 10%, ease down to 0.08 by 70%, fade to 0.
      // Softer peak than the cast screen since these rings fill the display.
      double opacity;
      if (t < 0.1) {
        opacity = (t / 0.1) * 0.55;
      } else if (t < 0.7) {
        opacity = 0.55 + (0.08 - 0.55) * ((t - 0.1) / 0.6);
      } else {
        opacity = 0.08 * (1 - (t - 0.7) / 0.3);
      }
      if (opacity <= 0) continue;

      final color = Color.lerp(
        const Color(0xFF00FFFF),
        const Color(0xFF0088FF),
        t,
      )!.withOpacity(opacity.clamp(0.0, 1.0));

      final paint = Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2.5
        ..color = color;
      canvas.drawCircle(center, baseRadius * scale, paint);
    }
  }

  @override
  bool shouldRepaint(_RingsPainter old) =>
      old.phase != phase || old.baseRadius != baseRadius;
}
