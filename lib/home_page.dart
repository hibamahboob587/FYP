import 'package:flutter/material.dart';
import 'package:flutter_tts/flutter_tts.dart';
import 'package:speech_to_text/speech_to_text.dart' as stt;
import 'dart:async';
import 'dart:math' as math;
import 'login_signup_page.dart';

// ── Palette ───────────────────────────────────────────────────────────────────
const _neonBlue   = Color(0xFF00B4FF);
const _neonPurple = Color(0xFF7B2FFF);
const _deepBlack  = Color(0xFF050508);
const _cardBlack  = Color(0xFF0E0E16);
const _darkGrey   = Color(0xFF1A1A28);
const _lightGrey  = Color(0xFF9E9E9E);
const _onSurface  = Color(0xFFE0E0E0);

// ── Data Models ───────────────────────────────────────────────────────────────
class _SensorData {
  final String title, description;
  final IconData icon;
  const _SensorData({required this.title, required this.description, required this.icon});
}

class _Step {
  final IconData icon;
  final String label, detail;
  const _Step({required this.icon, required this.label, required this.detail});
}

class _TeamMember {
  final String name, email;
  const _TeamMember({required this.name, required this.email});
}

// ── Glow Painter ──────────────────────────────────────────────────────────────
class _GlowPainter extends CustomPainter {
  final double t;
  _GlowPainter(this.t);

  @override
  void paint(Canvas canvas, Size size) {
    final cx = size.width / 2;
    final cy = size.height * 0.42;

    final outer = Paint()
      ..shader = RadialGradient(
        colors: [const Color(0xFF00B4FF).withOpacity(0.18 * t), Colors.transparent],
      ).createShader(Rect.fromCircle(center: Offset(cx, cy), radius: 260));
    canvas.drawCircle(Offset(cx, cy), 260, outer);

    final inner = Paint()
      ..shader = RadialGradient(
        colors: [const Color(0xFF7B2FFF).withOpacity(0.12 * t), Colors.transparent],
      ).createShader(Rect.fromCircle(center: Offset(cx, cy), radius: 150));
    canvas.drawCircle(Offset(cx, cy), 150, inner);

    final accent = Paint()
      ..shader = RadialGradient(
        colors: [const Color(0xFF00B4FF).withOpacity(0.08 * t), Colors.transparent],
      ).createShader(
        Rect.fromCircle(center: Offset(size.width * 0.1, size.height * 0.85), radius: 120),
      );
    canvas.drawCircle(Offset(size.width * 0.1, size.height * 0.85), 120, accent);
  }

  @override
  bool shouldRepaint(_GlowPainter old) => old.t != t;
}

// ── TTS page readouts ────────────────────────────────────────────────────────
const _pageReadouts = [
  'Welcome to SmartSight. An AI-driven wearable navigation assistant for the visually impaired. '
      'Say go to login to sign in. Say next to explore features.',
  'Hardware Sensors. SmartSight uses four sensors. '
      'Ultrasonic sensor detects obstacles up to 400 centimetres. '
      'Thermal sensor identifies living objects by heat. '
      'I M U sensor detects falls and sudden motion. '
      'Phone camera captures images for Gemini AI analysis. '
      'Tap any card to hear more. Say next to continue.',
  'How It Works. '
      'Step 1: Sensors scan the environment. '
      'Step 2: ESP32 sends data to the backend. '
      'Step 3: Gemini AI analyses the camera image. '
      'Step 4: The app speaks the scene description. '
      'Step 5: The phone vibrates for critical alerts. '
      'Say next to meet the team.',
  'Meet the Team. SmartSight was built by four members. '
      'Say go to login to get started.',
];

// ── STT voice commands hint per page ─────────────────────────────────────────
const _pageCommands = [
  '"next" • "go to login"',
  '"next" • "back" • tap a card',
  '"next" • "back"',
  '"back" • "go to login"',
];

// ── HomePage ──────────────────────────────────────────────────────────────────
class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> with TickerProviderStateMixin {
  final FlutterTts _tts = FlutterTts();
  final stt.SpeechToText _speech = stt.SpeechToText();
  bool _speechAvailable = false;
  bool _isListening = false;
  bool _navigating = false;

  // Scroll-based page tracking (uses SliverFillViewport internally like PageView)
  final ScrollController _scrollCtrl = ScrollController();
  int _currentPage = 0;
  double _screenHeight = 800;

  // Auto-scroll
  Timer? _autoScrollTimer;
  bool _userScrolling = false;           // true while finger is on screen
  static const _autoScrollDelay = Duration(seconds: 3); // pause after TTS ends

  // Animations
  late AnimationController _glowCtrl;
  late AnimationController _enterCtrl;
  late Animation<double> _glowAnim;
  late Animation<Offset> _slideAnim;
  late Animation<double> _fadeAnim;

  @override
  void initState() {
    super.initState();

    _glowCtrl = AnimationController(vsync: this, duration: const Duration(seconds: 2))
      ..repeat(reverse: true);
    _glowAnim = Tween<double>(begin: 0.4, end: 1.0).animate(
      CurvedAnimation(parent: _glowCtrl, curve: Curves.easeInOut),
    );

    _enterCtrl = AnimationController(vsync: this, duration: const Duration(milliseconds: 550));
    _slideAnim = Tween<Offset>(begin: const Offset(0, 0.1), end: Offset.zero).animate(
      CurvedAnimation(parent: _enterCtrl, curve: Curves.easeOut),
    );
    _fadeAnim = Tween<double>(begin: 0.0, end: 1.0).animate(
      CurvedAnimation(parent: _enterCtrl, curve: Curves.easeOut),
    );
    _enterCtrl.forward();

    _scrollCtrl.addListener(_onScroll);

    Future.delayed(const Duration(milliseconds: 800), _initThenSpeak);
  }

  void _onScroll() {
    if (_screenHeight == 0) return;
    // If the user is dragging, cancel any pending auto-advance
    if (_userScrolling) _cancelAutoScroll();
    final page = (_scrollCtrl.offset / _screenHeight + 0.5)
        .floor()
        .clamp(0, 3);
    if (page != _currentPage) {
      setState(() => _currentPage = page);
      _enterCtrl.forward(from: 0);
      _speakPage(page);
    }
  }

  // ── Auto-scroll helpers ───────────────────────────────────────────────────

  /// Called after TTS finishes for a page — schedules advance to next page.
  void _scheduleAutoScroll() {
    _cancelAutoScroll();
    if (_navigating) return;
    _autoScrollTimer = Timer(_autoScrollDelay, () {
      if (!mounted || _navigating || _userScrolling) return;
      final next = (_currentPage + 1) % 4;   // loop 3 → 0
      _goToPage(next);
    });
  }

  void _cancelAutoScroll() {
    _autoScrollTimer?.cancel();
    _autoScrollTimer = null;
  }

  // ── TTS / STT ─────────────────────────────────────────────────────────────

  Future<void> _initThenSpeak() async {
    _speechAvailable = await _speech.initialize(
      onStatus: _onSpeechStatus,
      onError: (_) {
        if (mounted && !_navigating) {
          Future.delayed(const Duration(seconds: 2), _startListening);
        }
      },
    );
    if (mounted) {
      await _speakPage(0, isIntro: true);
    }
  }

  void _onSpeechStatus(String status) {
    if (!mounted || _navigating) return;
    final wasListening = _isListening;
    setState(() => _isListening = status == 'listening');
    if (wasListening && (status == 'done' || status == 'notListening')) {
      Future.delayed(const Duration(milliseconds: 600), _startListening);
    }
  }

  Future<void> _speakPage(int page, {bool isIntro = false}) async {
    _cancelAutoScroll();
    await _tts.stop();
    await _tts.setLanguage('en-US');
    await _tts.setSpeechRate(0.46);
    await _tts.awaitSpeakCompletion(true);
    await _tts.speak(_pageReadouts[page]);
    if (!mounted || _navigating) return;
    _startListening();
    _scheduleAutoScroll();   // advance to next page after short pause
  }

  void _startListening() {
    if (!_speechAvailable || !mounted || _navigating || _isListening) return;
    _speech.listen(
      onResult: (result) {
        if (!result.finalResult) return;
        final w = result.recognizedWords.toLowerCase();
        _handleVoiceCommand(w);
      },
      listenFor: const Duration(seconds: 20),
      pauseFor: const Duration(seconds: 6),
      cancelOnError: false,
    );
    setState(() => _isListening = true);
  }

  void _handleVoiceCommand(String w) {
    if (w.contains('login') ||
        w.contains('log in') ||
        w.contains('sign in') ||
        w.contains('get started')) {
      _speech.stop();
      _navigateToLogin();
    } else if (w.contains('next') ||
        w.contains('scroll down') ||
        w.contains('forward') ||
        w.contains('continue')) {
      _goToPage(_currentPage + 1);
    } else if (w.contains('back') ||
        w.contains('previous') ||
        w.contains('scroll up') ||
        w.contains('go back')) {
      _goToPage(_currentPage - 1);
    } else if (w.contains('sensor') || w.contains('hardware')) {
      _goToPage(1);
    } else if (w.contains('how') || w.contains('works') || w.contains('workflow')) {
      _goToPage(2);
    } else if (w.contains('team') || w.contains('member') || w.contains('contact')) {
      _goToPage(3);
    } else if (w.contains('home') || w.contains('start')) {
      _goToPage(0);
    } else if (w.contains('read') || w.contains('repeat') || w.contains('again')) {
      _speakPage(_currentPage);
    }
  }

  void _goToPage(int page) {
    final target = page.clamp(0, 3);
    _scrollCtrl.animateTo(
      target * _screenHeight,
      duration: const Duration(milliseconds: 500),
      curve: Curves.easeInOut,
    );
  }

  void _navigateToLogin() {
    if (!mounted || _navigating) return;
    _navigating = true;
    _cancelAutoScroll();
    _tts.stop();
    _speech.stop();
    Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => const LoginSignupPage()),
    ).then((_) {
      _navigating = false;
      Future.delayed(const Duration(milliseconds: 500), _startListening);
      _scheduleAutoScroll();
    });
  }

  @override
  void dispose() {
    _cancelAutoScroll();
    _tts.stop();
    _speech.stop();
    _glowCtrl.dispose();
    _enterCtrl.dispose();
    _scrollCtrl.dispose();
    super.dispose();
  }

  // ── Page 0 — Hero ─────────────────────────────────────────────────────────

  Widget _buildHeroPage() {
    return GestureDetector(
      behavior: HitTestBehavior.translucent,
      onTap: _navigateToLogin,
      child: Container(
        decoration: const BoxDecoration(
          gradient: RadialGradient(
            center: Alignment(0, -0.25),
            radius: 1.3,
            colors: [Color(0xFF0D1B3E), Color(0xFF050508)],
          ),
        ),
        child: Stack(
          alignment: Alignment.center,
          children: [
            AnimatedBuilder(
              animation: _glowAnim,
              builder: (_, __) => CustomPaint(
                size: const Size(double.infinity, double.infinity),
                painter: _GlowPainter(_glowAnim.value),
              ),
            ),
            Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                // Eye icon with glowing ring
                AnimatedBuilder(
                  animation: _glowAnim,
                  builder: (_, __) => Container(
                    width: 110,
                    height: 110,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      boxShadow: [
                        BoxShadow(
                          color: _neonBlue.withOpacity(_glowAnim.value * 0.75),
                          blurRadius: 45,
                          spreadRadius: 12,
                        ),
                      ],
                      gradient: RadialGradient(colors: [
                        _neonBlue.withOpacity(0.28),
                        _neonPurple.withOpacity(0.12),
                        Colors.transparent,
                      ]),
                    ),
                    child: const Icon(Icons.remove_red_eye_rounded, size: 54, color: _neonBlue),
                  ),
                ),
                const SizedBox(height: 28),
                // App name
                ShaderMask(
                  shaderCallback: (b) => const LinearGradient(
                    colors: [_neonBlue, Color(0xFFB0EEFF), _neonBlue],
                    stops: [0.0, 0.5, 1.0],
                  ).createShader(b),
                  child: const Text(
                    'SmartSight',
                    style: TextStyle(
                      fontSize: 52,
                      fontWeight: FontWeight.w900,
                      color: Colors.white,
                      letterSpacing: 3,
                    ),
                  ),
                ),
                const SizedBox(height: 12),
                const Padding(
                  padding: EdgeInsets.symmetric(horizontal: 40),
                  child: Text(
                    'AI-Driven Wearable Navigation\nfor the Visually Impaired',
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      fontSize: 15,
                      color: _lightGrey,
                      letterSpacing: 0.4,
                      height: 1.65,
                    ),
                  ),
                ),
                const SizedBox(height: 38),
                // Get Started
                AnimatedBuilder(
                  animation: _glowAnim,
                  builder: (_, __) => GestureDetector(
                    onTap: _navigateToLogin,
                    child: Container(
                      padding: const EdgeInsets.symmetric(horizontal: 40, vertical: 14),
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(32),
                        gradient: const LinearGradient(colors: [_neonPurple, _neonBlue]),
                        boxShadow: [
                          BoxShadow(
                            color: _neonBlue.withOpacity(_glowAnim.value * 0.55),
                            blurRadius: 22,
                            spreadRadius: 3,
                          ),
                        ],
                      ),
                      child: const Text(
                        'Get Started',
                        style: TextStyle(
                          fontSize: 18,
                          fontWeight: FontWeight.bold,
                          color: Colors.white,
                          letterSpacing: 1.2,
                        ),
                      ),
                    ),
                  ),
                ),
                const SizedBox(height: 22),
                _buildMicBadge(),
              ],
            ),
            // Scroll hint
            Positioned(
              bottom: 28,
              child: Column(
                children: [
                  const Text('Scroll to explore',
                      style: TextStyle(color: _lightGrey, fontSize: 12, letterSpacing: 0.5)),
                  const SizedBox(height: 4),
                  _buildBouncingArrow(),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  // ── Page 1 — Sensors ──────────────────────────────────────────────────────

  Widget _buildSensorsPage() {
    const sensors = [
      _SensorData(
        title: 'Ultrasonic Sensor',
        description:
            'Detects obstacles up to 400 centimetres. Measures real-time distance for safe path navigation.',
        icon: Icons.sensors,
      ),
      _SensorData(
        title: 'Thermal Sensor',
        description:
            'MLX90614 infrared sensor distinguishes living from non-living objects using heat signatures.',
        icon: Icons.thermostat_rounded,
      ),
      _SensorData(
        title: 'IMU Sensor',
        description:
            'MPU6050 detects motion, orientation changes, and sudden fall events for user safety.',
        icon: Icons.screen_rotation_rounded,
      ),
      _SensorData(
        title: 'Phone Camera',
        description:
            'Captures images sent to Gemini AI for intelligent scene understanding and audio feedback.',
        icon: Icons.camera_alt_rounded,
      ),
    ];

    return _pageShell(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _sectionHeader('Hardware Sensors', 'The intelligence behind SmartSight'),
          const SizedBox(height: 20),
          GridView.builder(
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
              crossAxisCount: 2,
              crossAxisSpacing: 12,
              mainAxisSpacing: 12,
              childAspectRatio: 0.95,
            ),
            itemCount: sensors.length,
            itemBuilder: (_, i) => _buildSensorCard(sensors[i], i),
          ),
          const SizedBox(height: 14),
          _buildVoiceHint(1),
        ],
      ),
    );
  }

  Widget _buildSensorCard(_SensorData s, int index) {
    return TweenAnimationBuilder<double>(
      key: ValueKey('sensor_${_currentPage}_$index'),
      tween: Tween(begin: 0.0, end: 1.0),
      duration: Duration(milliseconds: 400 + index * 80),
      curve: Curves.easeOut,
      builder: (_, v, child) => Opacity(
        opacity: v,
        child: Transform.translate(offset: Offset(0, 20 * (1 - v)), child: child),
      ),
      child: GestureDetector(
        onTap: () async {
          await _tts.stop();
          await _tts.speak('${s.title}. ${s.description}');
        },
        child: Container(
          decoration: BoxDecoration(
            color: _cardBlack,
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: _neonBlue.withOpacity(0.45), width: 1),
            boxShadow: [
              BoxShadow(color: _neonBlue.withOpacity(0.1), blurRadius: 14, offset: const Offset(0, 5)),
            ],
          ),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Container(
                width: 54,
                height: 54,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  gradient: LinearGradient(colors: [
                    _neonBlue.withOpacity(0.3),
                    _neonPurple.withOpacity(0.2),
                  ]),
                ),
                child: Icon(s.icon, color: _neonBlue, size: 28),
              ),
              const SizedBox(height: 10),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 8),
                child: Text(
                  s.title,
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                      fontSize: 13, fontWeight: FontWeight.bold, color: _neonBlue),
                ),
              ),
              const SizedBox(height: 5),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 8),
                child: Text(
                  s.description,
                  textAlign: TextAlign.center,
                  maxLines: 3,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 11, color: _lightGrey, height: 1.4),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  // ── Page 2 — How It Works ─────────────────────────────────────────────────

  Widget _buildWorkflowPage() {
    const steps = [
      _Step(icon: Icons.sensors, label: 'Sensors Detect',
          detail: 'Ultrasonic, thermal, and IMU sensors continuously scan the environment.'),
      _Step(icon: Icons.wifi_rounded, label: 'Data Transmitted',
          detail: 'ESP32 sends sensor readings to the FastAPI backend over Wi-Fi.'),
      _Step(icon: Icons.psychology_rounded, label: 'AI Analysis',
          detail: 'Gemini 2.5 Flash analyses the camera image and identifies objects.'),
      _Step(icon: Icons.record_voice_over_rounded, label: 'Voice Feedback',
          detail: 'Flutter app speaks the scene description aloud via text-to-speech.'),
      _Step(icon: Icons.vibration_rounded, label: 'Haptic Alert',
          detail: 'Phone vibrates to reinforce critical obstacle, drop, and fall warnings.'),
    ];

    return _pageShell(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _sectionHeader('How It Works', 'From sensor to speech in milliseconds'),
          const SizedBox(height: 20),
          ...steps.asMap().entries.map((e) => _buildStepTile(e.value, e.key)),
          _buildVoiceHint(2),
        ],
      ),
    );
  }

  Widget _buildStepTile(_Step step, int index) {
    return TweenAnimationBuilder<double>(
      key: ValueKey('step_${_currentPage}_$index'),
      tween: Tween(begin: 0.0, end: 1.0),
      duration: Duration(milliseconds: 350 + index * 100),
      curve: Curves.easeOut,
      builder: (_, v, child) => Opacity(
        opacity: v,
        child: Transform.translate(offset: Offset(-20 * (1 - v), 0), child: child),
      ),
      child: GestureDetector(
        onTap: () async {
          await _tts.stop();
          await _tts.speak('Step ${index + 1}. ${step.label}. ${step.detail}');
        },
        child: Container(
          margin: const EdgeInsets.only(bottom: 10),
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
          decoration: BoxDecoration(
            color: _cardBlack,
            borderRadius: BorderRadius.circular(14),
            border: Border.all(color: _neonBlue.withOpacity(0.2), width: 1),
          ),
          child: Row(
            children: [
              Container(
                width: 40,
                height: 40,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  gradient: LinearGradient(colors: [
                    _neonPurple.withOpacity(0.6),
                    _neonBlue.withOpacity(0.4),
                  ]),
                ),
                child: Center(
                  child: Text(
                    '${index + 1}',
                    style: const TextStyle(
                        color: Colors.white, fontWeight: FontWeight.bold, fontSize: 16),
                  ),
                ),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(step.label,
                        style: const TextStyle(
                            fontSize: 14, fontWeight: FontWeight.bold, color: _onSurface)),
                    const SizedBox(height: 3),
                    Text(step.detail,
                        style: const TextStyle(fontSize: 12, color: _lightGrey, height: 1.4)),
                  ],
                ),
              ),
              Icon(step.icon, color: _neonBlue.withOpacity(0.6), size: 20),
            ],
          ),
        ),
      ),
    );
  }

  // ── Page 3 — Team ─────────────────────────────────────────────────────────

  Widget _buildTeamPage() {
    const members = [
      _TeamMember(name: 'Team Member 1', email: 'member1@smartsight.dev'),
      _TeamMember(name: 'Team Member 2', email: 'member2@smartsight.dev'),
      _TeamMember(name: 'Team Member 3', email: 'member3@smartsight.dev'),
      _TeamMember(name: 'Team Member 4', email: 'member4@smartsight.dev'),
    ];

    const memberColors = [_neonBlue, _neonPurple, Color(0xFF00E5CC), Color(0xFFFF6B6B)];

    return _pageShell(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _sectionHeader('Meet the Team', 'The minds behind SmartSight'),
          const SizedBox(height: 18),
          ...members.asMap().entries.map(
            (e) => _buildMemberCard(e.value, e.key, memberColors[e.key % memberColors.length]),
          ),
          const SizedBox(height: 14),
          _buildFooterCard(),
          const SizedBox(height: 10),
          _buildVoiceHint(3),
        ],
      ),
    );
  }

  Widget _buildMemberCard(_TeamMember member, int index, Color color) {
    return TweenAnimationBuilder<double>(
      key: ValueKey('member_${_currentPage}_$index'),
      tween: Tween(begin: 0.0, end: 1.0),
      duration: Duration(milliseconds: 380 + index * 90),
      curve: Curves.easeOut,
      builder: (_, v, child) => Opacity(
        opacity: v,
        child: Transform.translate(offset: Offset(0, 16 * (1 - v)), child: child),
      ),
      child: GestureDetector(
        onTap: () async {
          await _tts.stop();
          await _tts.speak('${member.name}. Email: ${member.email}');
        },
        child: Container(
          margin: const EdgeInsets.only(bottom: 12),
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
          decoration: BoxDecoration(
            color: _cardBlack,
            borderRadius: BorderRadius.circular(14),
            border: Border.all(color: color.withOpacity(0.4), width: 1),
            boxShadow: [
              BoxShadow(color: color.withOpacity(0.07), blurRadius: 10, offset: const Offset(0, 4)),
            ],
          ),
          child: Row(
            children: [
              Container(
                width: 46,
                height: 46,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  gradient: LinearGradient(
                    colors: [color.withOpacity(0.5), color.withOpacity(0.18)],
                  ),
                ),
                child: Icon(Icons.person_rounded, color: color, size: 24),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(member.name,
                        style: const TextStyle(
                            fontSize: 15, fontWeight: FontWeight.bold, color: _onSurface)),
                    const SizedBox(height: 2),
                    Text(member.email,
                        style: const TextStyle(fontSize: 12, color: _lightGrey)),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildFooterCard() {
    return Container(
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: _darkGrey,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: _neonBlue.withOpacity(0.18), width: 1),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          ShaderMask(
            shaderCallback: (b) =>
                const LinearGradient(colors: [_neonBlue, Color(0xFFB0EEFF)]).createShader(b),
            child: const Text('SmartSight',
                style: TextStyle(color: Colors.white, fontSize: 20, fontWeight: FontWeight.bold)),
          ),
          const SizedBox(height: 4),
          const Text('AI-Driven Wearable Assistive Device',
              style: TextStyle(color: _lightGrey, fontSize: 12.5)),
          const Divider(color: Colors.white12, height: 20),
          _footerRow(Icons.location_on_rounded, 'Karachi, Pakistan'),
          const SizedBox(height: 6),
          _footerRow(Icons.school_rounded, 'Final Year Project — 2025'),
          const SizedBox(height: 6),
          _footerRow(Icons.email_rounded, 'smartsight@project.dev'),
        ],
      ),
    );
  }

  Widget _footerRow(IconData icon, String text) {
    return Row(
      children: [
        Icon(icon, color: _lightGrey, size: 14),
        const SizedBox(width: 8),
        Expanded(child: Text(text, style: const TextStyle(color: _lightGrey, fontSize: 12))),
      ],
    );
  }

  // ── Shared Widgets ────────────────────────────────────────────────────────

  Widget _pageShell({required Widget child}) {
    return FadeTransition(
      opacity: _fadeAnim,
      child: SlideTransition(
        position: _slideAnim,
        child: Container(
          decoration: const BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              colors: [Color(0xFF06060C), Color(0xFF0A0A16)],
            ),
          ),
          child: SingleChildScrollView(
            physics: const NeverScrollableScrollPhysics(),
            padding: const EdgeInsets.fromLTRB(20, 52, 20, 24),
            child: child,
          ),
        ),
      ),
    );
  }

  Widget _sectionHeader(String title, String subtitle) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        ShaderMask(
          shaderCallback: (b) =>
              const LinearGradient(colors: [_neonBlue, Color(0xFFB0EEFF)]).createShader(b),
          child: Text(title,
              style: const TextStyle(
                  fontSize: 28, fontWeight: FontWeight.w900, color: Colors.white, letterSpacing: 0.4)),
        ),
        const SizedBox(height: 3),
        Text(subtitle, style: const TextStyle(color: _lightGrey, fontSize: 13)),
      ],
    );
  }

  Widget _buildMicBadge() {
    return AnimatedContainer(
      duration: const Duration(milliseconds: 300),
      padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 9),
      decoration: BoxDecoration(
        color: _isListening ? _neonBlue.withOpacity(0.12) : Colors.white.withOpacity(0.05),
        borderRadius: BorderRadius.circular(22),
        border: Border.all(color: _isListening ? _neonBlue : Colors.white24, width: 1),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            _isListening ? Icons.mic_rounded : Icons.mic_off_rounded,
            color: _isListening ? _neonBlue : _lightGrey,
            size: 15,
          ),
          const SizedBox(width: 8),
          Text(
            _isListening ? 'Listening… say "go to login"' : 'Tap anywhere to continue',
            style: TextStyle(color: _isListening ? _neonBlue : _lightGrey, fontSize: 12.5),
          ),
        ],
      ),
    );
  }

  Widget _buildBouncingArrow() {
    return AnimatedBuilder(
      animation: _glowCtrl,
      builder: (_, __) => Transform.translate(
        offset: Offset(0, 5 * math.sin(_glowCtrl.value * math.pi)),
        child: const Icon(Icons.keyboard_arrow_down_rounded, color: _lightGrey, size: 30),
      ),
    );
  }

  /// Small voice command hint shown at the bottom of each non-hero page
  Widget _buildVoiceHint(int page) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
      decoration: BoxDecoration(
        color: Colors.white.withOpacity(0.04),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: Colors.white10),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            _isListening ? Icons.mic_rounded : Icons.mic_off_rounded,
            color: _isListening ? _neonBlue : _lightGrey,
            size: 14,
          ),
          const SizedBox(width: 8),
          Text(
            _pageCommands[page],
            style: const TextStyle(color: _lightGrey, fontSize: 12),
          ),
        ],
      ),
    );
  }

  // ── Page Indicator (right rail) ───────────────────────────────────────────

  static const _pageLabels = ['Home', 'Sensors', 'How It Works', 'Team'];

  Widget _buildPageIndicator() {
    return Positioned(
      right: 12,
      top: 0,
      bottom: 0,
      child: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: List.generate(_pageLabels.length, (i) {
            final active = _currentPage == i;
            return GestureDetector(
              onTap: () => _goToPage(i),
              child: Tooltip(
                message: _pageLabels[i],
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 300),
                  margin: const EdgeInsets.symmetric(vertical: 5),
                  width: active ? 7 : 5,
                  height: active ? 26 : 5,
                  decoration: BoxDecoration(
                    color: active ? _neonBlue : _lightGrey.withOpacity(0.35),
                    borderRadius: BorderRadius.circular(10),
                    boxShadow: active
                        ? [BoxShadow(color: _neonBlue.withOpacity(0.7), blurRadius: 8)]
                        : null,
                  ),
                ),
              ),
            );
          }),
        ),
      ),
    );
  }

  // ── Build ─────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    _screenHeight = MediaQuery.of(context).size.height;

    return Scaffold(
      backgroundColor: _deepBlack,
      extendBodyBehindAppBar: true,
      appBar: _currentPage == 0
          ? null
          : AppBar(
              backgroundColor: Colors.black.withOpacity(0.55),
              elevation: 0,
              title: const Text('SmartSight',
                  style: TextStyle(
                      fontSize: 19, color: _neonBlue, fontWeight: FontWeight.bold, letterSpacing: 1)),
              actions: [
                TextButton(
                  onPressed: _navigateToLogin,
                  child: const Text('Login',
                      style: TextStyle(
                          color: _neonBlue, fontSize: 14, fontWeight: FontWeight.w600)),
                ),
              ],
            ),
      body: Stack(
        children: [
          // Listener detects finger down/up so auto-scroll pauses while user touches
          Listener(
            onPointerDown: (_) {
              _userScrolling = true;
              _cancelAutoScroll();
            },
            onPointerUp: (_) {
              _userScrolling = false;
              // Resume auto-scroll 4 s after finger lifts
              _autoScrollTimer = Timer(const Duration(seconds: 4), () {
                if (!mounted || _navigating || _userScrolling) return;
                _scheduleAutoScroll();
              });
            },
            child: CustomScrollView(
              controller: _scrollCtrl,
              physics: const PageScrollPhysics(),
              slivers: [
                SliverFillViewport(
                  delegate: SliverChildListDelegate([
                    _buildHeroPage(),
                    _buildSensorsPage(),
                    _buildWorkflowPage(),
                    _buildTeamPage(),
                  ]),
                ),
              ],
            ),
          ),
          _buildPageIndicator(),
        ],
      ),
    );
  }
}
