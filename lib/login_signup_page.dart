import 'dart:async';
import 'package:flutter/material.dart';
import 'package:intl_phone_field/intl_phone_field.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:flutter_tts/flutter_tts.dart';
import 'package:speech_to_text/speech_to_text.dart' as stt;
import 'post_login_page.dart';
import 'package:intl/intl.dart';

// Neon blue / black / grey palette
const _neonBlue = Color(0xFF00B4FF);
const _deepBlack = Color(0xFF0A0A0A);
const _cardBlack = Color(0xFF121212);
const _darkGrey = Color(0xFF1E1E1E);
const _lightGrey = Color(0xFF9E9E9E);
const _onSurface = Color(0xFFE0E0E0);

class LoginSignupPage extends StatefulWidget {
  const LoginSignupPage({super.key});

  @override
  LoginSignupPageState createState() => LoginSignupPageState();
}

class LoginSignupPageState extends State<LoginSignupPage> {
  final _formKey = GlobalKey<FormState>();
  final emailController = TextEditingController();
  final passwordController = TextEditingController();
  final nameController = TextEditingController();
  final dobController = TextEditingController();
  final caregiverEmailController = TextEditingController();
  final deviceIdController = TextEditingController();

  // Focus nodes — tapping a field stops the voice guide so user can type freely
  final _emailFocus        = FocusNode();
  final _passwordFocus     = FocusNode();
  final _nameFocus         = FocusNode();
  final _caregiverFocus    = FocusNode();
  final _deviceFocus       = FocusNode();

  String phoneNumber = '';
  String gender = 'Male';
  bool isLoginMode = true;
  bool _guideRunning = false;   // true while auto voice-guide is active

  final FlutterTts _tts = FlutterTts();
  final stt.SpeechToText _speech = stt.SpeechToText();
  bool _speechAvailable = false;
  bool _isListening = false;
  String _listeningFor = '';

  @override
  void initState() {
    super.initState();
    // Tapping any field stops the voice guide so the user can type manually
    for (final fn in [_emailFocus, _passwordFocus, _nameFocus, _caregiverFocus, _deviceFocus]) {
      fn.addListener(() {
        if (fn.hasFocus && _guideRunning) _cancelGuide();
      });
    }
    _initSpeechAndGuide();
  }

  /// Stops TTS + STT and lets the user type freely
  void _cancelGuide() {
    _guideRunning = false;
    _tts.stop();
    _speech.stop();
    if (mounted) setState(() { _isListening = false; _listeningFor = ''; _guideRunning = false; });
  }

  Future<void> _initSpeechAndGuide() async {
    await _tts.setLanguage('en-US');
    await _tts.setSpeechRate(0.48);
    _speechAvailable = await _speech.initialize();
    await Future.delayed(const Duration(milliseconds: 600));
    if (mounted) _runLoginGuide();
  }

  Future<void> _speak(String text) async {
    await _tts.stop();
    await _tts.speak(text);
    // Approximate wait for TTS to finish speaking
    final ms = (text.length * 55).clamp(800, 8000);
    await Future.delayed(Duration(milliseconds: ms));
  }

  Future<void> _runLoginGuide() async {
    if (!mounted) return;
    _guideRunning = true;
    await _speak(
      'Login page. I will guide you through each field. '
      'You can speak your answer, or tap any field to type manually.',
    );
    if (!mounted || !_guideRunning) return;
    await _listenForField(emailController, 'email', 'Email field. Please say your email address.');
    if (!mounted || !_guideRunning) return;
    await _listenForField(passwordController, 'password', 'Password field. Please say your password.');
    if (!mounted || !_guideRunning) return;
    _guideRunning = false;
    await _speak('All fields filled. Say login to submit, or tap the Login button.');
    if (!mounted) return;
    _listenForSubmitCommand();
  }

  Future<void> _listenForField(
    TextEditingController ctrl,
    String fieldName,
    String prompt,
  ) async {
    if (!_speechAvailable || !mounted) return;
    await _speak(prompt);
    if (!mounted) return;

    setState(() {
      _isListening = true;
      _listeningFor = fieldName;
    });

    final resultCompleter = Completer<String>();

    _speech.listen(
      onResult: (r) {
        if (r.finalResult && !resultCompleter.isCompleted) {
          resultCompleter.complete(r.recognizedWords);
        }
      },
      listenFor: const Duration(seconds: 12),
      pauseFor: const Duration(seconds: 4),
    );

    String spoken = '';
    try {
      spoken = await resultCompleter.future.timeout(const Duration(seconds: 14));
    } catch (_) {
      // Timeout — no speech detected
    }

    await _speech.stop();

    if (!mounted) return;
    setState(() {
      _isListening = false;
      _listeningFor = '';
    });

    if (spoken.trim().isNotEmpty) {
      ctrl.text = spoken.trim();
      await _speak('$fieldName set.');
    } else {
      await _speak(
        'No input heard for $fieldName. You can type it or tap the microphone button.',
      );
    }
  }

  void _listenForSubmitCommand() {
    if (!_speechAvailable || !mounted) return;
    _speech.listen(
      onResult: (r) {
        if (!r.finalResult) return;
        final words = r.recognizedWords.toLowerCase();
        if (words.contains('login') ||
            words.contains('log in') ||
            words.contains('submit')) {
          _speech.stop();
          if (mounted && _formKey.currentState!.validate()) loginUser();
        } else {
          Future.delayed(
            const Duration(milliseconds: 400),
            _listenForSubmitCommand,
          );
        }
      },
      listenFor: const Duration(seconds: 15),
      pauseFor: const Duration(seconds: 5),
    );
  }

  Future<void> _onMicTapped(
    TextEditingController ctrl,
    String fieldName,
    String prompt,
  ) async {
    await _speech.stop();
    await _listenForField(ctrl, fieldName, prompt);
  }

  @override
  void dispose() {
    _tts.stop();
    _speech.stop();
    emailController.dispose();
    passwordController.dispose();
    nameController.dispose();
    dobController.dispose();
    caregiverEmailController.dispose();
    deviceIdController.dispose();
    _emailFocus.dispose();
    _passwordFocus.dispose();
    _nameFocus.dispose();
    _caregiverFocus.dispose();
    _deviceFocus.dispose();
    super.dispose();
  }

  // =====================
  // INPUT DECORATION
  // =====================
  InputDecoration _inputDecoration(String label) {
    return InputDecoration(
      labelText: label,
      labelStyle: const TextStyle(color: _lightGrey, fontSize: 17),
      filled: true,
      fillColor: _darkGrey,
      enabledBorder: OutlineInputBorder(
        borderSide: BorderSide(color: _neonBlue.withOpacity(0.35), width: 1.2),
        borderRadius: BorderRadius.circular(12),
      ),
      focusedBorder: const OutlineInputBorder(
        borderSide: BorderSide(color: _neonBlue, width: 2),
        borderRadius: BorderRadius.all(Radius.circular(12)),
      ),
      errorBorder: const OutlineInputBorder(
        borderSide: BorderSide(color: Colors.redAccent, width: 1.2),
        borderRadius: BorderRadius.all(Radius.circular(12)),
      ),
      focusedErrorBorder: const OutlineInputBorder(
        borderSide: BorderSide(color: Colors.redAccent, width: 2),
        borderRadius: BorderRadius.all(Radius.circular(12)),
      ),
      errorStyle: const TextStyle(color: Colors.redAccent),
    );
  }

  // =====================
  // LARGE MIC BUTTON
  // =====================
  Widget _micButton(
    TextEditingController ctrl,
    String fieldName,
    String prompt,
  ) {
    final isActive = _isListening && _listeningFor == fieldName;
    return Padding(
      padding: const EdgeInsets.only(top: 8, bottom: 4),
      child: SizedBox(
        width: double.infinity,
        height: 54,
        child: ElevatedButton.icon(
          style: ElevatedButton.styleFrom(
            backgroundColor: isActive ? Colors.redAccent : _darkGrey,
            foregroundColor: isActive ? Colors.white : _neonBlue,
            side: BorderSide(
              color: isActive ? Colors.redAccent : _neonBlue,
              width: 1.5,
            ),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(12),
            ),
            elevation: 0,
          ),
          onPressed: isActive ? null : () => _onMicTapped(ctrl, fieldName, prompt),
          icon: Icon(isActive ? Icons.hearing : Icons.mic, size: 22),
          label: Text(
            isActive ? 'Listening...' : 'Speak $fieldName',
            style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w600),
          ),
        ),
      ),
    );
  }

  // =====================
  // BUILD
  // =====================
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: _deepBlack,
      appBar: AppBar(
        backgroundColor: _deepBlack,
        iconTheme: const IconThemeData(color: _neonBlue),
        title: Text(
          isLoginMode ? 'Login' : 'Sign Up',
          style: const TextStyle(
            color: _neonBlue,
            fontWeight: FontWeight.bold,
            fontSize: 22,
          ),
        ),
      ),
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: Form(
          key: _formKey,
          child: ListView(
            children: [
              const SizedBox(height: 8),

              // Manual input banner
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                decoration: BoxDecoration(
                  color: _neonBlue.withOpacity(0.08),
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(color: _neonBlue.withOpacity(0.3)),
                ),
                child: Row(
                  children: [
                    const Icon(Icons.info_outline, color: _neonBlue, size: 18),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        _guideRunning
                            ? 'Voice guide active — tap any field to type manually instead'
                            : 'Type below or use the mic buttons to fill fields by voice',
                        style: const TextStyle(color: _lightGrey, fontSize: 13),
                      ),
                    ),
                    if (_guideRunning)
                      GestureDetector(
                        onTap: _cancelGuide,
                        child: const Text('Skip', style: TextStyle(color: _neonBlue, fontSize: 13)),
                      ),
                  ],
                ),
              ),
              const SizedBox(height: 14),

              if (!isLoginMode) ...[
                TextFormField(
                  controller: nameController,
                  focusNode: _nameFocus,
                  style: const TextStyle(color: _onSurface, fontSize: 17),
                  decoration: _inputDecoration('Full Name'),
                  validator: (v) => v != null && v.isNotEmpty ? null : 'Enter name',
                ),
                const SizedBox(height: 14),

                Theme(
                  data: Theme.of(context).copyWith(
                    textTheme: Theme.of(context)
                        .textTheme
                        .apply(bodyColor: _onSurface),
                  ),
                  child: IntlPhoneField(
                    style: const TextStyle(color: _onSurface, fontSize: 17),
                    dropdownTextStyle: const TextStyle(color: _onSurface),
                    decoration: _inputDecoration('Phone Number'),
                    initialCountryCode: 'US',
                    onChanged: (phone) => phoneNumber = phone.completeNumber,
                  ),
                ),
                const SizedBox(height: 14),

                TextFormField(
                  controller: caregiverEmailController,
                  focusNode: _caregiverFocus,
                  style: const TextStyle(color: _onSurface, fontSize: 17),
                  decoration: _inputDecoration('Caregiver Email'),
                  keyboardType: TextInputType.emailAddress,
                  validator: (v) =>
                      v != null && v.contains('@')
                          ? null
                          : 'Enter valid caregiver email',
                ),
                const SizedBox(height: 14),

                TextFormField(
                  controller: dobController,
                  style: const TextStyle(color: _onSurface, fontSize: 17),
                  decoration: _inputDecoration('Date of Birth (yyyy-mm-dd)'),
                  readOnly: true,
                  onTap: () async {
                    DateTime? date = await showDatePicker(
                      context: context,
                      initialDate: DateTime(2000),
                      firstDate: DateTime(1900),
                      lastDate: DateTime.now(),
                      builder: (ctx, child) => Theme(
                        data: ThemeData.dark().copyWith(
                          colorScheme:
                              const ColorScheme.dark(primary: _neonBlue),
                        ),
                        child: child!,
                      ),
                    );
                    if (date != null) {
                      dobController.text =
                          DateFormat('yyyy-MM-dd').format(date);
                    }
                  },
                ),
                const SizedBox(height: 14),

                TextFormField(
                  controller: deviceIdController,
                  focusNode: _deviceFocus,
                  style: const TextStyle(color: _onSurface, fontSize: 17),
                  decoration: _inputDecoration('Device ID'),
                  validator: (v) =>
                      v != null && v.isNotEmpty ? null : 'Enter device ID',
                ),
                const SizedBox(height: 14),

                DropdownButtonFormField<String>(
                  value: gender,
                  dropdownColor: _cardBlack,
                  style: const TextStyle(color: _onSurface, fontSize: 17),
                  decoration: _inputDecoration('Gender'),
                  items: ['Male', 'Female', 'Other']
                      .map(
                        (g) => DropdownMenuItem(
                          value: g,
                          child: Text(
                            g,
                            style: const TextStyle(color: _onSurface),
                          ),
                        ),
                      )
                      .toList(),
                  onChanged: (val) => gender = val ?? 'Male',
                ),
                const SizedBox(height: 14),
              ],

              // Email + mic
              TextFormField(
                controller: emailController,
                focusNode: _emailFocus,
                style: const TextStyle(color: _onSurface, fontSize: 17),
                decoration: _inputDecoration('Email'),
                keyboardType: TextInputType.emailAddress,
                validator: (v) =>
                    v != null && v.contains('@') ? null : 'Invalid email',
              ),
              _micButton(
                emailController,
                'email',
                'Email field. Please say your email address.',
              ),
              const SizedBox(height: 10),

              // Password + mic
              TextFormField(
                controller: passwordController,
                focusNode: _passwordFocus,
                style: const TextStyle(color: _onSurface, fontSize: 17),
                decoration: _inputDecoration('Password'),
                obscureText: true,
                validator: (v) {
                  if (v == null || v.length < 8) return 'Min 8 chars';
                  if (!RegExp(r'[A-Z]').hasMatch(v)) return '1 capital required';
                  if (!RegExp(r'[!@#\$&*~]').hasMatch(v)) {
                    return '1 special char required';
                  }
                  return null;
                },
              ),
              _micButton(
                passwordController,
                'password',
                'Password field. Please say your password.',
              ),
              const SizedBox(height: 24),

              // Submit — full width large button
              SizedBox(
                width: double.infinity,
                height: 64,
                child: ElevatedButton(
                  style: ElevatedButton.styleFrom(
                    backgroundColor: _neonBlue,
                    foregroundColor: _deepBlack,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(14),
                    ),
                    elevation: 4,
                    shadowColor: _neonBlue.withOpacity(0.4),
                  ),
                  onPressed: () async {
                    if (!_formKey.currentState!.validate()) return;
                    isLoginMode ? await loginUser() : await signupUser();
                  },
                  child: Text(
                    isLoginMode ? 'Login' : 'Sign Up',
                    style: const TextStyle(
                      fontSize: 22,
                      fontWeight: FontWeight.bold,
                      letterSpacing: 1.1,
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 12),

              TextButton(
                onPressed: () {
                  _speech.stop();
                  setState(() => isLoginMode = !isLoginMode);
                },
                child: Text(
                  isLoginMode ? 'Switch to Sign Up' : 'Switch to Login',
                  style: const TextStyle(color: _neonBlue, fontSize: 17),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  // =============================
  // SIGNUP (unchanged logic)
  // =============================
  Future<void> signupUser() async {
    final supabase = Supabase.instance.client;
    final messenger = ScaffoldMessenger.of(context);

    try {
      final res = await supabase.auth.signUp(
        email: emailController.text.trim(),
        password: passwordController.text.trim(),
      );

      final user = res.user;

      if (user == null) {
        throw Exception('Signup failed. Check your email or try again.');
      }

      await supabase.from('users').insert({
        'id': user.id,
        'full_name': nameController.text.trim(),
        'email': emailController.text.trim(),
        'phone_number': phoneNumber,
        'caregiver_email': caregiverEmailController.text.trim(),
        'dob': dobController.text.trim(),
        'gender': gender,
      });
      await supabase.from('devices').insert({
        'device_id': deviceIdController.text.trim(),
        'user_id': user.id,
        'caregiver_email': caregiverEmailController.text.trim(),
      });

      nameController.clear();
      dobController.clear();
      caregiverEmailController.clear();
      deviceIdController.clear();
      phoneNumber = '';

      setState(() => isLoginMode = true);

      messenger.showSnackBar(
        const SnackBar(
          content: Text('Signup successful! Please login.'),
          backgroundColor: Colors.green,
        ),
      );
    } catch (e) {
      messenger.showSnackBar(
        SnackBar(
          content: Text('Signup failed: $e'),
          backgroundColor: Colors.red,
        ),
      );
    }
  }

  // =============================
  // LOGIN (unchanged logic)
  // =============================
  Future<void> loginUser() async {
    final supabase = Supabase.instance.client;
    final navigator = Navigator.of(context);
    final messenger = ScaffoldMessenger.of(context);

    try {
      final res = await supabase.auth.signInWithPassword(
        email: emailController.text.trim(),
        password: passwordController.text.trim(),
      );

      if (res.user != null) {
        navigator.pushReplacement(
          MaterialPageRoute(builder: (_) => const PostLoginPage()),
        );
      }
    } catch (e) {
      messenger.showSnackBar(
        SnackBar(
          content: Text('Login failed: $e'),
          backgroundColor: Colors.red,
        ),
      );
    }
  }
}
