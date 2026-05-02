import 'package:flutter/material.dart';
import 'home_page.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:geolocator/geolocator.dart';
import 'package:vibration/vibration.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:camera/camera.dart';
import 'package:web_socket_channel/web_socket_channel.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';
import 'package:http/http.dart' as http;
import 'package:flutter_tts/flutter_tts.dart';
import 'package:flutter_image_compress/flutter_image_compress.dart';

class PostLoginPage extends StatefulWidget {
  const PostLoginPage({super.key});

  @override
  State<PostLoginPage> createState() => _PostLoginPageState();
}

class _PostLoginPageState extends State<PostLoginPage> {
  final FlutterTts _tts = FlutterTts();
  bool _hasSpokenForCurrentAlert = false;
  bool _hasHapticForCurrentAlert = false;
  bool _ttsEnabled = true;
  String _lastMessage = "No alerts";
  final String _locationApiUrl =
      "${dotenv.env['BACKEND_URL'] ?? 'http://192.168.1.100:8000'}/update-location";
  Timer? _locationTimer;

  // _isAlertMode is DERIVED from _lastMessage — they can never be out of sync.
  // Icon = ALERT  when message is anything other than the safe placeholder.
  // Icon = SAFE   when message is "No alerts".
  bool get _isAlertMode => _lastMessage != "No alerts" && _lastMessage.isNotEmpty;
  bool _isSpeaking = false;

  // Single-speaker gate — prevents polling + camera from talking over each other
  String _lastSpokenMessage = '';
  DateTime? _lastSpokenAt;
  static const _speakCooldown = Duration(seconds: 4);

  // After TTS finishes, suppress polling from re-pushing the same alert for 5 s
  // so the card stays on "No alerts" and the icon stays SAFE after speech ends.
  DateTime? _alertSuppressUntil;

  final String _apiUrl =
      "${dotenv.env['BACKEND_URL'] ?? 'http://192.168.1.100:8000'}/latest-status";

  // Backend /detect URL — image is POSTed here; backend calls Gemini and returns instruction
  late final String _detectUrl =
      "${dotenv.env['BACKEND_URL'] ?? 'http://192.168.1.100:8000'}/detect";

  double _latestDistanceCm = 0; // updated by poll loop

  // ── Camera + WebSocket ─────────────────────────────────────────────────────
  final http.Client _httpClient = http.Client();
  CameraController? _cameraController;
  WebSocketChannel? _wsChannel;
  Timer? _wsPingTimer;
  bool _wsConnected = false;
  int _wsGeneration = 0;
  bool _cameraCapturing = false;
  DateTime? _lastCapture;
  static const _captureCooldown = Duration(seconds: 5);
  final String _wsUrl = dotenv.env['WS_URL'] ?? 'ws://192.168.1.100:8000/ws';

  Future<void> _initCamera() async {
    try {
      // Dispose any existing broken controller first
      if (_cameraController != null) {
        try {
          await _cameraController!.dispose();
        } catch (_) {}
        _cameraController = null;
      }

      final cameras = await availableCameras();
      if (cameras.isEmpty) {
        print('[CAM] no cameras found on device');
        return;
      }

      final controller = CameraController(
        cameras.first,
        ResolutionPreset.medium,
        enableAudio: false,
      );

      await controller.initialize();
      _cameraController = controller;
      print('[CAM] camera initialised: ${cameras.first.name}');
    } catch (e) {
      print('[CAM] init error: $e');
      _cameraController = null;
    }
  }

  // Central TTS gate — ALL speech must go through here.
  // Blocks if already speaking, same message repeated, or within cooldown.
  Future<void> _speak(String message, {String reason = ''}) async {
    if (!_ttsEnabled || !mounted || message.isEmpty) return;
    if (_isSpeaking) {
      print('[TTS] blocked — already speaking');
      return;
    }
    if (message == _lastSpokenMessage &&
        _lastSpokenAt != null &&
        DateTime.now().difference(_lastSpokenAt!) < _speakCooldown) {
      print('[TTS] blocked — same message within cooldown');
      return;
    }
    _lastSpokenMessage = message;
    _lastSpokenAt = DateTime.now();

    if (reason.isNotEmpty) triggerHaptic(reason);

    await _tts.stop();
    _tts.speak(message);
    print('[TTS] speaking: "$message"');
  }

  void _initWebSocket() {
    // Bump generation so any callbacks still queued from the previous
    // connection are treated as stale and ignored.
    final int gen = ++_wsGeneration;

    _wsPingTimer?.cancel();
    try {
      _wsChannel?.sink.close();
    } catch (_) {}

    void scheduleReconnect() {
      if (!mounted) return;
      Future.delayed(const Duration(seconds: 5), () {
        // Only reconnect if this is still the most-recent attempt.
        if (gen == _wsGeneration && mounted) _initWebSocket();
      });
    }

    try {
      _wsChannel = WebSocketChannel.connect(Uri.parse(_wsUrl));
      _wsConnected = true;
      print('[WS] Connecting (gen=$gen)...');

      _wsChannel!.stream.listen(
        (msg) {
          if (gen != _wsGeneration) return; // stale
          print('[WS] message received: $msg');
          try {
            final data = jsonDecode(msg as String);
            if (data['capture'] == true) {
              final dist = (data['distance'] is num)
                  ? (data['distance'] as num).toInt()
                  : 150;
              print('[WS] capture=true distance=$dist cm');
              _captureAndDetect(stage: dist);
            }
          } catch (e) {
            print('[WS] parse error: $e');
          }
        },
        onDone: () {
          if (gen != _wsGeneration) return; // stale
          print('[WS] Disconnected (gen=$gen) — reconnecting in 5s');
          _wsConnected = false;
          _wsPingTimer?.cancel();
          scheduleReconnect();
        },
        onError: (e) {
          if (gen != _wsGeneration) return; // stale
          print('[WS] Error (gen=$gen): $e — reconnecting in 5s');
          _wsConnected = false;
          _wsPingTimer?.cancel();
          scheduleReconnect();
        },
        cancelOnError: true,
      );

      // Ping every 25s to keep the connection alive through Android Doze.
      _wsPingTimer = Timer.periodic(const Duration(seconds: 25), (_) {
        if (gen != _wsGeneration) return; // stale timer from old connection
        if (!_wsConnected) return;
        try {
          _wsChannel?.sink.add('ping');
        } catch (_) {
          _wsConnected = false;
          scheduleReconnect();
        }
      });
    } catch (e) {
      print('[WS] Connect exception (gen=$gen): $e — reconnecting in 5s');
      _wsConnected = false;
      scheduleReconnect();
    }
  }

  Future<void> _captureAndDetect({int stage = 260}) async {
    print('[CAM] _captureAndDetect stage=$stage');

    if (_cameraCapturing) {
      print('[CAM] blocked — already capturing'); return;
    }
    if (_cameraController == null) {
      print('[CAM] blocked — controller null'); return;
    }
    if (!_cameraController!.value.isInitialized) {
      print('[CAM] blocked — not initialised'); return;
    }

    // Stage-based cooldown: closer = shorter cooldown = more urgent
    final Duration cooldown = stage <= 150
        ? const Duration(seconds: 2)
        : stage <= 200
            ? const Duration(seconds: 3)
            : _captureCooldown; // 5s at 260cm

    final now = DateTime.now();
    if (_lastCapture != null && now.difference(_lastCapture!) < cooldown) {
      final remaining = cooldown - now.difference(_lastCapture!);
      print('[CAM] blocked — cooldown ${remaining.inSeconds}s (stage=$stage)'); return;
    }

    _cameraCapturing = true;
    _lastCapture = now;

    try {
      // 1. Take picture
      print('[CAM] taking picture...');
      final file = await _cameraController!.takePicture();

      // 2. Compress — cuts payload from ~400 KB to ~25 KB
      print('[CAM] compressing...');
      final compressed = await FlutterImageCompress.compressWithFile(
        file.path,
        minWidth: 512,
        minHeight: 512,
        quality: 72,
        format: CompressFormat.jpeg,
      );
      final Uint8List bytes = compressed ?? await file.readAsBytes();
      print('[CAM] compressed: ${bytes.length} bytes');

      // 3. POST raw JPEG bytes to backend /detect
      //    Backend calls Gemini (with full logs), falls back to YOLO, returns instruction.
      print('[CAM] → POST /detect (${bytes.length} bytes, dist=${_latestDistanceCm.toStringAsFixed(0)} cm)');
      final t0 = DateTime.now();

      final res = await _httpClient.post(
        Uri.parse(_detectUrl),
        headers: {
          'Content-Type': 'application/octet-stream',
          'ngrok-skip-browser-warning': 'true',
        },
        body: bytes,
      );

      final ms = DateTime.now().difference(t0).inMilliseconds;
      print('[CAM] /detect responded in ${ms}ms — status ${res.statusCode}');

      if (res.statusCode == 200 && mounted) {
        final data        = jsonDecode(res.body);
        final skipped     = data['skipped'] == true;

        if (skipped) {
          print('[CAM] backend busy (camera_in_flight) — skipped');
          return;
        }

        final instruction = (data['message'] ?? '') as String;
        final reason      = (data['reason']  ?? '') as String;

        print('[CAM] instruction: "$instruction"  source: ${data['source']}');

        if (instruction.isNotEmpty && mounted) {
          setState(() => _lastMessage = instruction);
          await _speak(instruction, reason: reason);
        }
      } else {
        print('[CAM] /detect error ${res.statusCode}: ${res.body}');
      }

    } catch (e) {
      print('[CAM] error: $e');
      if (mounted) await _initCamera();
    } finally {
      _cameraCapturing = false;
      print('[CAM] ready for next trigger');
    }
  }

  Future<void> _sendLocationToBackend() async {
    try {
      bool serviceEnabled = await Geolocator.isLocationServiceEnabled();
      if (!serviceEnabled) return;

      LocationPermission permission = await Geolocator.checkPermission();
      if (permission == LocationPermission.denied) {
        permission = await Geolocator.requestPermission();
        if (permission == LocationPermission.denied) return;
      }

      if (permission == LocationPermission.deniedForever) return;

      Position position = await Geolocator.getCurrentPosition(
        desiredAccuracy: LocationAccuracy.high,
      );

      await http.post(
        Uri.parse(_locationApiUrl),
        headers: {
          "Content-Type": "application/json",
          "ngrok-skip-browser-warning": "true",
        },
        body: jsonEncode({"lat": position.latitude, "lon": position.longitude}),
      );
    } catch (_) {}
  }

  Future<void> triggerHaptic(String reason) async {
    bool? hasVibrator = await Vibration.hasVibrator();
    if (hasVibrator == null || !hasVibrator) return;

    switch (reason) {
      case "vehicle":
        // 🚗 Strong repeated warning
        await Vibration.vibrate(pattern: [0, 400, 200, 400]);
        break;

      case "dog":
        // 🐕 Medium repeated
        await Vibration.vibrate(pattern: [0, 300, 100, 300]);
        break;

      case "stopsign":
        // 🛑 Long vibration
        await Vibration.vibrate(duration: 800);
        break;

      case "trafficlight":
        // 🚦 gentle pulse
        await Vibration.vibrate(pattern: [0, 200, 100, 200]);
        break;

      case "crosswalk":
        // 🚶 short double tap
        await Vibration.vibrate(pattern: [0, 150, 100, 150]);
        break;

      case "person":
      case "door":
        await Vibration.vibrate(pattern: [0, 200, 100, 200]);
        break;

      case "pole":
      case "pothole":
        await Vibration.vibrate(duration: 300);
        break;

      case "no_movement_detected":
        // 🚨 emergency SOS
        await Vibration.vibrate(pattern: [0, 500, 200, 500, 200, 500]);
        break;

      default:
        await Vibration.vibrate(duration: 200);
    }
  }

  Future<void> _autoReloadAndSpeak() async {
    print("🔥 AUTO REFRESH CALLED");
    try {
      final res = await _httpClient.get(
        Uri.parse(_apiUrl),
        headers: {"ngrok-skip-browser-warning": "true"},
      );
      print("🌐 HTTP STATUS: ${res.statusCode}");
      print("📦 BODY: ${res.body}");

      if (res.statusCode == 200) {
        final data = jsonDecode(res.body);

        final bool alert = data["alert"] ?? false;
        final String reason = data["reason"] ?? "";
        final String message = data["message"] ?? "";
        _latestDistanceCm = (data["distance"] ?? 0).toDouble();

        setState(() {
          // Respect the 5-second suppress window after TTS clears the UI.
          final suppress = _alertSuppressUntil != null &&
              DateTime.now().isBefore(_alertSuppressUntil!);
          if (!suppress) {
            // _isAlertMode is a getter derived from _lastMessage — always in sync.
            _lastMessage = (alert && message.isNotEmpty) ? message : "No alerts";
          }
        });

        if (alert && message.isNotEmpty) {
          if (!_hasSpokenForCurrentAlert) {
            _hasSpokenForCurrentAlert = true;
            _hasHapticForCurrentAlert = true;
            await _speak(message, reason: reason);
          }
        } else {
          _hasSpokenForCurrentAlert = false;
          _hasHapticForCurrentAlert = false;
        }
      }
    } catch (e) {
      print("❌ POLL ERROR: $e");
    }
  }

  // 🔁 AUTO LOOP (REPLACES TIMER)
  Future<void> _startAutoRefresh() async {
    while (mounted) {
      await _autoReloadAndSpeak();
      await Future.delayed(const Duration(seconds: 1));
    }
  }

  @override
  void initState() {
    super.initState();

    _tts.setLanguage("en-US");
    _tts.setSpeechRate(0.5);

    // 🔥 NEW: Listeners to start/stop animation
    _tts.setStartHandler(() {
      setState(() => _isSpeaking = true);
    });

    _tts.setCompletionHandler(() {
      setState(() {
        _isSpeaking               = false;
        _lastMessage              = "No alerts";   // icon → SAFE immediately
        _hasSpokenForCurrentAlert = false;
        _hasHapticForCurrentAlert = false;
        // Block polling from flickering the same alert back for 5 s
        _alertSuppressUntil = DateTime.now().add(const Duration(seconds: 5));
      });
      _lastSpokenAt = DateTime.now();
    });

    _tts.setErrorHandler((msg) {
      setState(() => _isSpeaking = false);
    });

    WakelockPlus.enable();
    _autoReloadAndSpeak();
    _startAutoRefresh();
    _sendLocationToBackend();
    Future.microtask(() => _initCamera());
    Future.microtask(() => _initWebSocket());

    _locationTimer = Timer.periodic(
      const Duration(seconds: 30),
      (_) => _sendLocationToBackend(),
    );
  }

  @override
  void dispose() {
    _tts.stop();
    _locationTimer?.cancel();
    WakelockPlus.disable();
    _httpClient.close();
    _cameraController?.dispose();
    _wsPingTimer?.cancel();
    _wsChannel?.sink.close();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    const deepBlack = Color(0xFF0A0A0A);
    const cardBlack = Color(0xFF121212);
    const darkGrey = Color(0xFF1E1E1E);
    const neonBlue = Color(0xFF00B4FF);
    const onSurface = Color(0xFFE0E0E0);
    const lightGrey = Color(0xFF9E9E9E);

    final mainColor = _isAlertMode ? Colors.redAccent : neonBlue;

    return Scaffold(
      backgroundColor: deepBlack,
      appBar: AppBar(
        backgroundColor: deepBlack,
        iconTheme: const IconThemeData(color: neonBlue),
        title: const Text(
          'SmartSight',
          style: TextStyle(
            fontSize: 22,
            fontWeight: FontWeight.bold,
            color: neonBlue,
            letterSpacing: 1.2,
          ),
        ),
        actions: [
          // Refresh — clears stale UI and pulls fresh status from backend
          IconButton(
            icon: const Icon(Icons.refresh_rounded, color: neonBlue, size: 26),
            tooltip: 'Refresh',
            onPressed: () async {
              await _tts.stop();
              setState(() {
                _lastMessage = "No alerts";
                _isSpeaking  = false;
                _hasSpokenForCurrentAlert  = false;
                _hasHapticForCurrentAlert  = false;
              });
              await _autoReloadAndSpeak();
            },
          ),
          TextButton(
            onPressed: () async {
              final navigator = Navigator.of(context);
              await Supabase.instance.client.auth.signOut();
              if (!mounted) return;
              navigator.pushAndRemoveUntil(
                MaterialPageRoute(builder: (_) => HomePage()),
                (_) => false,
              );
            },
            child: const Text(
              'Logout',
              style: TextStyle(
                color: neonBlue,
                fontSize: 17,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        ],
      ),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              const Spacer(),

              // STATUS CIRCLE + RIPPLE
              Stack(
                alignment: Alignment.center,
                children: [
                  if (_isSpeaking) RippleAnimation(color: mainColor),

                  Container(
                    width: 210,
                    height: 210,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: cardBlack,
                      border: Border.all(
                        color: mainColor.withOpacity(0.7),
                        width: 3.5,
                      ),
                      boxShadow: [
                        BoxShadow(
                          color: mainColor.withOpacity(0.25),
                          blurRadius: 28,
                          spreadRadius: 6,
                        ),
                      ],
                    ),
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Icon(
                          _isAlertMode
                              ? Icons.warning_rounded
                              : Icons.shield_rounded,
                          size: 64,
                          color: mainColor,
                        ),
                        const SizedBox(height: 10),
                        Text(
                          _isAlertMode ? 'ALERT ACTIVE' : 'SAFE',
                          textAlign: TextAlign.center,
                          style: TextStyle(
                            fontSize: 20,
                            fontWeight: FontWeight.bold,
                            color: mainColor,
                            letterSpacing: 1.2,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),

              const SizedBox(height: 36),

              // MESSAGE CARD
              Container(
                width: double.infinity,
                padding: const EdgeInsets.symmetric(
                  vertical: 18,
                  horizontal: 24,
                ),
                decoration: BoxDecoration(
                  color: cardBlack,
                  borderRadius: BorderRadius.circular(16),
                  border: Border.all(
                    color: mainColor.withOpacity(0.4),
                    width: 1.2,
                  ),
                  boxShadow: [
                    BoxShadow(
                      color: mainColor.withOpacity(0.08),
                      blurRadius: 12,
                      offset: const Offset(0, 4),
                    ),
                  ],
                ),
                child: Text(
                  _lastMessage,
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                    fontSize: 18,
                    fontWeight: FontWeight.w500,
                    color: onSurface,
                  ),
                ),
              ),

              const Spacer(),

              // VOICE ALERTS TOGGLE
              Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 20,
                  vertical: 14,
                ),
                decoration: BoxDecoration(
                  color: darkGrey,
                  borderRadius: BorderRadius.circular(14),
                  border: Border.all(
                    color: neonBlue.withOpacity(0.25),
                    width: 1,
                  ),
                ),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      Icons.volume_up,
                      size: 24,
                      color: _ttsEnabled ? neonBlue : lightGrey,
                    ),
                    const SizedBox(width: 10),
                    Text(
                      'Voice Alerts',
                      style: TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.w600,
                        color: _ttsEnabled ? onSurface : lightGrey,
                      ),
                    ),
                    const SizedBox(width: 10),
                    Switch(
                      activeColor: neonBlue,
                      activeTrackColor: neonBlue.withOpacity(0.3),
                      inactiveThumbColor: lightGrey,
                      inactiveTrackColor: darkGrey,
                      value: _ttsEnabled,
                      onChanged: (v) {
                        setState(() => _ttsEnabled = v);
                        if (!v) _tts.stop();
                      },
                    ),
                  ],
                ),
              ),

              const SizedBox(height: 20),
            ],
          ),
        ),
      ),
    );
  }
}

// 🔥 NEW: Custom Animation Widget for the Sound Wave
class RippleAnimation extends StatefulWidget {
  final Color color;
  const RippleAnimation({super.key, required this.color});

  @override
  State<RippleAnimation> createState() => _RippleAnimationState();
}

class _RippleAnimationState extends State<RippleAnimation>
    with SingleTickerProviderStateMixin {
  late AnimationController _controller;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 2),
    )..repeat();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _controller,
      builder: (context, child) {
        return Stack(
          alignment: Alignment.center,
          children: [_buildRing(0.0), _buildRing(0.5)],
        );
      },
    );
  }

  Widget _buildRing(double delay) {
    final double value = (_controller.value + delay) % 1.0;
    final double size = 210 + (value * 150);
    final double opacity = (1.0 - value).clamp(0.0, 1.0);

    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        border: Border.all(color: widget.color.withOpacity(opacity), width: 6),
      ),
    );
  }
}
