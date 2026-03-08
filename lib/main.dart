import 'dart:convert';
import 'dart:math' as math;

import 'package:confetti/confetti.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:table_calendar/table_calendar.dart';

void main() {
  runApp(const NopeApp());
}

final Map<String, Color> presetColors = {
  "Blue": const Color(0xFF4A9EFF),
  "Red": const Color(0xFFFF4A6B),
  "Green": const Color(0xFF4AFF9E),
  "Orange": const Color(0xFFFF9E4A),
  "Purple": const Color(0xFFB44AFF),
};

// ─────────────────────────────────────────────────────────────────────────────
// APP
// ─────────────────────────────────────────────────────────────────────────────
class NopeApp extends StatelessWidget {
  const NopeApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Nope.',
      theme: ThemeData.dark().copyWith(
        scaffoldBackgroundColor: const Color(0xFF080808),
        snackBarTheme: const SnackBarThemeData(behavior: SnackBarBehavior.floating),
        textTheme: ThemeData.dark().textTheme.apply(fontFamily: 'Helvetica Neue'),
      ),
      home: const AppEntry(),
      debugShowCheckedModeBanner: false,
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// ENTRY — checks if intro has been seen
// ─────────────────────────────────────────────────────────────────────────────
class AppEntry extends StatefulWidget {
  const AppEntry({super.key});

  @override
  State<AppEntry> createState() => _AppEntryState();
}

class _AppEntryState extends State<AppEntry> {
  bool? _showIntro;

  @override
  void initState() {
    super.initState();
    _check();
  }

  Future<void> _check() async {
    final prefs = await SharedPreferences.getInstance();
    final seen = prefs.getBool('seen_intro') ?? false;
    setState(() => _showIntro = !seen);
  }

  void _onIntroComplete() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('seen_intro', true);
    if (mounted) {
      Navigator.of(context).pushReplacement(
        PageRouteBuilder(
          pageBuilder: (_, __, ___) => const NopeHome(),
          transitionDuration: const Duration(milliseconds: 600),
          transitionsBuilder: (_, anim, __, child) =>
              FadeTransition(opacity: anim, child: child),
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_showIntro == null) {
      return const Scaffold(backgroundColor: Color(0xFF080808));
    }
    if (_showIntro!) {
      return IntroScreen(onComplete: _onIntroComplete);
    }
    return const NopeHome();
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// INTRO SCREEN
// ─────────────────────────────────────────────────────────────────────────────
class IntroScreen extends StatefulWidget {
  final VoidCallback onComplete;
  const IntroScreen({required this.onComplete, super.key});

  @override
  State<IntroScreen> createState() => _IntroScreenState();
}

class _IntroScreenState extends State<IntroScreen>
    with TickerProviderStateMixin {
  late AnimationController _titleCtrl;
  late AnimationController _subCtrl;
  late AnimationController _btnCtrl;
  late AnimationController _lineCtrl;

  late Animation<double> _titleFade;
  late Animation<Offset> _titleSlide;
  late Animation<double> _subFade;
  late Animation<double> _btnFade;
  late Animation<double> _lineWidth;

  @override
  void initState() {
    super.initState();

    _titleCtrl = AnimationController(vsync: this, duration: const Duration(milliseconds: 800));
    _subCtrl = AnimationController(vsync: this, duration: const Duration(milliseconds: 600));
    _btnCtrl = AnimationController(vsync: this, duration: const Duration(milliseconds: 500));
    _lineCtrl = AnimationController(vsync: this, duration: const Duration(milliseconds: 700));

    _titleFade = CurvedAnimation(parent: _titleCtrl, curve: Curves.easeOut);
    _titleSlide = Tween<Offset>(begin: const Offset(0, 0.15), end: Offset.zero)
        .animate(CurvedAnimation(parent: _titleCtrl, curve: Curves.easeOut));
    _subFade = CurvedAnimation(parent: _subCtrl, curve: Curves.easeOut);
    _btnFade = CurvedAnimation(parent: _btnCtrl, curve: Curves.easeOut);
    _lineWidth = CurvedAnimation(parent: _lineCtrl, curve: Curves.easeOut);

    _runSequence();
  }

  Future<void> _runSequence() async {
    await Future.delayed(const Duration(milliseconds: 300));
    _titleCtrl.forward();
    await Future.delayed(const Duration(milliseconds: 400));
    _lineCtrl.forward();
    await Future.delayed(const Duration(milliseconds: 300));
    _subCtrl.forward();
    await Future.delayed(const Duration(milliseconds: 400));
    _btnCtrl.forward();
  }

  @override
  void dispose() {
    _titleCtrl.dispose();
    _subCtrl.dispose();
    _btnCtrl.dispose();
    _lineCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final w = MediaQuery.of(context).size.width;

    return Scaffold(
      backgroundColor: const Color(0xFF080808),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 32),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Spacer(flex: 3),

              // Big title
              FadeTransition(
                opacity: _titleFade,
                child: SlideTransition(
                  position: _titleSlide,
                  child: const Text(
                    "nope.",
                    style: TextStyle(
                      fontSize: 88,
                      fontWeight: FontWeight.w900,
                      color: Colors.white,
                      letterSpacing: -4,
                      height: 1.0,
                    ),
                  ),
                ),
              ),

              const SizedBox(height: 16),

              // Animated line
              AnimatedBuilder(
                animation: _lineWidth,
                builder: (_, __) => Container(
                  height: 2,
                  width: _lineWidth.value * (w - 64),
                  color: Colors.white,
                ),
              ),

              const SizedBox(height: 20),

              // Tagline
              FadeTransition(
                opacity: _subFade,
                child: const Text(
                  "resist the urge.\ntrack the streak.\ngrow the streak.",
                  style: TextStyle(
                    fontSize: 20,
                    color: Color(0xFF888888),
                    fontWeight: FontWeight.w400,
                    height: 1.6,
                    letterSpacing: -0.3,
                  ),
                ),
              ),

              const Spacer(flex: 2),

              // Features
              FadeTransition(
                opacity: _subFade,
                child: Column(
                  children: const [
                    _IntroFeature(icon: Icons.block, text: "Hit NOPE once a day per habit"),
                    SizedBox(height: 14),
                    _IntroFeature(icon: Icons.local_fire_department, text: "Build streaks. Don't break the chain."),
                    SizedBox(height: 14),
                    _IntroFeature(icon: Icons.calendar_month, text: "See your wins on a calendar"),
                  ],
                ),
              ),

              const Spacer(flex: 2),

              // CTA button
              FadeTransition(
                opacity: _btnFade,
                child: _PressableButton(
                  onTap: widget.onComplete,
                  child: Container(
                    width: double.infinity,
                    padding: const EdgeInsets.symmetric(vertical: 20),
                    decoration: BoxDecoration(
                      color: Colors.white,
                      borderRadius: BorderRadius.circular(16),
                    ),
                    child: const Center(
                      child: Text(
                        "let's go →",
                        style: TextStyle(
                          color: Color(0xFF080808),
                          fontSize: 18,
                          fontWeight: FontWeight.w800,
                          letterSpacing: -0.3,
                        ),
                      ),
                    ),
                  ),
                ),
              ),

              const SizedBox(height: 48),
            ],
          ),
        ),
      ),
    );
  }
}

class _IntroFeature extends StatelessWidget {
  final IconData icon;
  final String text;
  const _IntroFeature({required this.icon, required this.text});

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Icon(icon, color: Colors.white38, size: 20),
        const SizedBox(width: 12),
        Text(
          text,
          style: const TextStyle(
            color: Color(0xFF666666),
            fontSize: 15,
            fontWeight: FontWeight.w400,
          ),
        ),
      ],
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// MODEL
// ─────────────────────────────────────────────────────────────────────────────
class Habit {
  String id;
  String name;
  String tonePack;
  int streak;
  int longestStreak;
  int lastTapMillis;
  int colorValue;
  List<String> urgeLog;
  String? lastLine;

  Habit({
    required this.id,
    required this.name,
    this.tonePack = 'Light',
    this.streak = 0,
    this.longestStreak = 0,
    this.lastTapMillis = 0,
    List<String>? urgeLog,
    this.lastLine,
    this.colorValue = 0xFF4A9EFF,
  }) : urgeLog = urgeLog ?? [];

  DateTime? get lastTap =>
      lastTapMillis == 0 ? null : DateTime.fromMillisecondsSinceEpoch(lastTapMillis);

  bool tappedToday(DateTime now) {
    if (lastTap == null) return false;
    final lt = lastTap!;
    return lt.year == now.year && lt.month == now.month && lt.day == now.day;
  }

  void refreshForToday(DateTime now) {
    if (lastTap == null) return;
    final last = DateTime(lastTap!.year, lastTap!.month, lastTap!.day);
    final yesterday = DateTime(now.year, now.month, now.day).subtract(const Duration(days: 1));
    if (last.isBefore(yesterday)) streak = 0;
  }

  bool registerNope(DateTime now) {
    if (tappedToday(now)) return false;
    streak += 1;
    if (streak > longestStreak) longestStreak = streak;
    lastTapMillis = now.millisecondsSinceEpoch;
    urgeLog.add(now.toIso8601String());
    if (urgeLog.length > 50) urgeLog.removeAt(0);
    return true;
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'tonePack': tonePack,
        'streak': streak,
        'longestStreak': longestStreak,
        'lastTapMillis': lastTapMillis,
        'urgeLog': urgeLog,
        'lastLine': lastLine,
        'colorValue': colorValue,
      };

  factory Habit.fromJson(Map<String, dynamic> j) => Habit(
        id: j['id'] as String,
        name: j['name'] as String,
        tonePack: (j['tonePack'] as String?) ?? 'Light',
        streak: (j['streak'] as int?) ?? 0,
        longestStreak: (j['longestStreak'] as int?) ?? 0,
        lastTapMillis: (j['lastTapMillis'] as int?) ?? 0,
        urgeLog: (j['urgeLog'] as List?)?.map((e) => e.toString()).toList() ?? [],
        lastLine: j['lastLine'] as String?,
        colorValue: (j['colorValue'] as int?) ?? 0xFF4A9EFF,
      );
}

// ─────────────────────────────────────────────────────────────────────────────
// HOME
// ─────────────────────────────────────────────────────────────────────────────
class NopeHome extends StatefulWidget {
  const NopeHome({super.key});

  @override
  State<NopeHome> createState() => _NopeHomeState();
}

class _NopeHomeState extends State<NopeHome> {
  final Map<String, List<String>> tonePacks = {
    'Light': [
      "Way to go! Your future self thanks you.",
      "Small victory today, big success tomorrow.",
      "You're stronger than your impulses!",
      "Every NOPE builds your superpower of self-control.",
      "Look at you, making good choices!",
      "You got this — keep saying NOPE!",
      "Another step toward a better you."
    ],
    'Dark': [
      "You dodged a bullet.",
      "The shadows are pleased with your choice.",
      "Resist today, regret less tomorrow.",
      "Every NOPE is a small miracle in a cruel world.",
      "Ignore this, and chaos wins.",
    ],
    'Dry': [
      "Wow. Groundbreaking.",
      "Skipped it. Yawn.",
      "Oh look, you did the obvious thing.",
      "Predictable, yet thrilling.",
      "Did you really need an app for this? Nope.",
    ],
    'Savage': [
      "Pathetic impulse. Denied.",
      "Your dog is judging you.",
      "Barely survived.",
      "You almost ruined everything. Almost.",
      "LOL nope. Loser move avoided.",
    ],
  };

  List<Habit> habits = [];
  late ConfettiController _confettiController;

  @override
  void initState() {
    super.initState();
    _confettiController = ConfettiController(duration: const Duration(milliseconds: 900));
    _loadHabits();
  }

  @override
  void dispose() {
    _confettiController.dispose();
    super.dispose();
  }

  Future<void> _loadHabits() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString('habits');
    final now = DateTime.now();
    if (raw != null && raw.isNotEmpty) {
      final list = (jsonDecode(raw) as List).cast<Map<String, dynamic>>();
      habits = list.map(Habit.fromJson).toList();
      for (final h in habits) {
        h.refreshForToday(now);
      }
    } else {
      habits = [];
    }
    setState(() {});
  }

  Future<void> _saveHabits() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('habits', jsonEncode(habits.map((e) => e.toJson()).toList()));
  }

  void _addHabit() async {
    final created = await showModalBottomSheet<Habit>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (context) => _AddHabitSheet(),
    );
    if (created != null) {
      setState(() => habits.add(created));
      _saveHabits();
    }
  }

  void _deleteHabit(Habit h) {
    setState(() => habits.removeWhere((x) => x.id == h.id));
    _saveHabits();
  }

  void _resetHabit(Habit h) {
    HapticFeedback.mediumImpact();
    setState(() {
      h.streak = 0;
      h.lastTapMillis = 0;
      h.lastLine = "Reset. New chapter starts now.";
    });
    _saveHabits();
  }

  String _adaptiveMessage(Habit h) {
    final msgs = tonePacks[h.tonePack] ?? tonePacks['Light']!;
    if (h.streak < 5) return "Early days — stay strong!";
    if (h.streak < 15) return msgs[math.Random().nextInt(msgs.length)];
    if (h.streak < 30) return "🔥 You're building serious momentum!";
    return "🏆 Legend mode unlocked. ${h.streak} days!";
  }

  void _pressNope(Habit h) {
    final now = DateTime.now();
    setState(() {
      h.refreshForToday(now);
      final incremented = h.registerNope(now);
      if (incremented) {
        HapticFeedback.heavyImpact();
        _confettiController.play();
        h.lastLine = _adaptiveMessage(h);
      } else {
        HapticFeedback.lightImpact();
        h.lastLine = "Already counted today. Come back tomorrow ✌️";
      }
    });
    _saveHabits();
  }

  void _changeColor(Habit h, Color newColor) {
    setState(() => h.colorValue = newColor.value);
    _saveHabits();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF080808),
      appBar: AppBar(
        backgroundColor: const Color(0xFF080808),
        elevation: 0,
        titleSpacing: 24,
        title: const Text(
          "nope.",
          style: TextStyle(
            fontSize: 28,
            fontWeight: FontWeight.w900,
            color: Colors.white,
            letterSpacing: -1.5,
          ),
        ),
        actions: [
          if (habits.isNotEmpty)
            IconButton(
              tooltip: "Calendar view",
              icon: const Icon(Icons.calendar_month_outlined, color: Colors.white54),
              onPressed: () => Navigator.push(
                context,
                MaterialPageRoute(builder: (_) => CalendarView(habits: habits)),
              ),
            ),
          if (habits.isNotEmpty)
            IconButton(
              tooltip: "Reset all streaks",
              icon: const Icon(Icons.restart_alt, color: Colors.white54),
              onPressed: () {
                HapticFeedback.mediumImpact();
                for (final h in habits) {
                  h.streak = 0;
                  h.lastTapMillis = 0;
                  h.lastLine = "Reset. New chapter starts now.";
                }
                setState(() {});
                _saveHabits();
              },
            ),
          const SizedBox(width: 8),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _addHabit,
        backgroundColor: Colors.white,
        foregroundColor: const Color(0xFF080808),
        elevation: 0,
        label: const Text(
          "Add Habit",
          style: TextStyle(fontWeight: FontWeight.w800, letterSpacing: -0.3),
        ),
        icon: const Icon(Icons.add, size: 20),
      ),
      body: Stack(
        children: [
          if (habits.isEmpty)
            const _EmptyState()
          else
            ListView.builder(
              padding: const EdgeInsets.only(top: 8, bottom: 120, left: 16, right: 16),
              itemCount: habits.length,
              itemBuilder: (context, i) {
                final h = habits[i];
                return Dismissible(
                  key: ValueKey(h.id),
                  background: Container(
                    margin: const EdgeInsets.symmetric(vertical: 6),
                    decoration: BoxDecoration(
                      color: Colors.redAccent.withOpacity(0.15),
                      borderRadius: BorderRadius.circular(20),
                    ),
                    alignment: Alignment.centerLeft,
                    padding: const EdgeInsets.only(left: 24),
                    child: const Icon(Icons.delete_outline, color: Colors.redAccent),
                  ),
                  direction: DismissDirection.startToEnd,
                  confirmDismiss: (_) async {
                    return await showDialog<bool>(
                      context: context,
                      builder: (_) => AlertDialog(
                        backgroundColor: const Color(0xFF141414),
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
                        title: const Text("Delete habit?"),
                        content: Text('Remove "${h.name}" and its history?'),
                        actions: [
                          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text("Cancel")),
                          ElevatedButton(
                            style: ElevatedButton.styleFrom(backgroundColor: Colors.redAccent),
                            onPressed: () => Navigator.pop(context, true),
                            child: const Text("Delete"),
                          ),
                        ],
                      ),
                    ) ?? false;
                  },
                  onDismissed: (_) => _deleteHabit(h),
                  child: _HabitCard(
                    habit: h,
                    toneOptions: tonePacks.keys.toList(),
                    onNope: () => _pressNope(h),
                    onReset: () => _resetHabit(h),
                    onColorChanged: (c) => _changeColor(h, c),
                  ),
                );
              },
            ),
          Positioned.fill(
            child: IgnorePointer(
              child: Align(
                alignment: Alignment.topCenter,
                child: ConfettiWidget(
                  confettiController: _confettiController,
                  blastDirectionality: BlastDirectionality.explosive,
                  shouldLoop: false,
                  maxBlastForce: 25,
                  minBlastForce: 8,
                  emissionFrequency: 0.04,
                  numberOfParticles: 30,
                  gravity: 0.35,
                  colors: [
                    Colors.white,
                    const Color(0xFF4A9EFF),
                    const Color(0xFFFF4A6B),
                    const Color(0xFF4AFF9E),
                    const Color(0xFFFFD700),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// ADD HABIT SHEET (bottom sheet instead of dialog)
// ─────────────────────────────────────────────────────────────────────────────
class _AddHabitSheet extends StatefulWidget {
  @override
  State<_AddHabitSheet> createState() => _AddHabitSheetState();
}

class _AddHabitSheetState extends State<_AddHabitSheet> {
  final nameCtrl = TextEditingController();
  final streakCtrl = TextEditingController();
  Color selectedColor = presetColors["Blue"]!;

  @override
  void dispose() {
    nameCtrl.dispose();
    streakCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: const BoxDecoration(
        color: Color(0xFF111111),
        borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
      ),
      padding: EdgeInsets.fromLTRB(
        24, 16, 24, MediaQuery.of(context).viewInsets.bottom + 32,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Handle
          Center(
            child: Container(
              width: 40,
              height: 4,
              decoration: BoxDecoration(
                color: Colors.white12,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
          ),
          const SizedBox(height: 20),
          const Text(
            "New Habit",
            style: TextStyle(
              fontSize: 26,
              fontWeight: FontWeight.w900,
              letterSpacing: -1,
            ),
          ),
          const SizedBox(height: 20),
          _StyledTextField(
            controller: nameCtrl,
            label: "Habit name",
            hint: "e.g., No Vaping",
          ),
          const SizedBox(height: 12),
          _StyledTextField(
            controller: streakCtrl,
            label: "Current streak (days resisted)",
            hint: "0",
            keyboardType: TextInputType.number,
          ),
          const SizedBox(height: 20),
          const Text(
            "Color",
            style: TextStyle(fontSize: 13, color: Colors.white54, fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: 10),
          Row(
            children: presetColors.entries.map((entry) {
              final isSelected = entry.value == selectedColor;
              return GestureDetector(
                onTap: () => setState(() => selectedColor = entry.value),
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 200),
                  width: isSelected ? 42 : 36,
                  height: isSelected ? 42 : 36,
                  margin: const EdgeInsets.only(right: 10),
                  decoration: BoxDecoration(
                    color: entry.value,
                    shape: BoxShape.circle,
                    boxShadow: isSelected
                        ? [BoxShadow(color: entry.value.withOpacity(0.5), blurRadius: 12, spreadRadius: 2)]
                        : [],
                  ),
                  child: isSelected
                      ? const Icon(Icons.check, color: Colors.white, size: 18)
                      : null,
                ),
              );
            }).toList(),
          ),
          const SizedBox(height: 24),
          _PressableButton(
            onTap: () {
              final name = nameCtrl.text.trim();
              if (name.isEmpty) return;
              final streak = int.tryParse(streakCtrl.text.trim()) ?? 0;
              HapticFeedback.mediumImpact();
              Navigator.pop(
                context,
                Habit(
                  id: DateTime.now().millisecondsSinceEpoch.toString(),
                  name: name,
                  streak: streak,
                  longestStreak: streak,
                  colorValue: selectedColor.value,
                ),
              );
            },
            child: Container(
              width: double.infinity,
              padding: const EdgeInsets.symmetric(vertical: 18),
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(16),
              ),
              child: const Center(
                child: Text(
                  "Add Habit",
                  style: TextStyle(
                    color: Color(0xFF080808),
                    fontSize: 16,
                    fontWeight: FontWeight.w800,
                    letterSpacing: -0.3,
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _StyledTextField extends StatelessWidget {
  final TextEditingController controller;
  final String label;
  final String hint;
  final TextInputType keyboardType;

  const _StyledTextField({
    required this.controller,
    required this.label,
    required this.hint,
    this.keyboardType = TextInputType.text,
  });

  @override
  Widget build(BuildContext context) {
    return TextField(
      controller: controller,
      keyboardType: keyboardType,
      style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w500),
      decoration: InputDecoration(
        labelText: label,
        hintText: hint,
        labelStyle: const TextStyle(color: Colors.white38),
        hintStyle: const TextStyle(color: Colors.white24),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: const BorderSide(color: Colors.white12),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: const BorderSide(color: Colors.white38),
        ),
        filled: true,
        fillColor: Colors.white.withOpacity(0.05),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// HABIT CARD
// ─────────────────────────────────────────────────────────────────────────────
class _HabitCard extends StatelessWidget {
  final Habit habit;
  final List<String> toneOptions;
  final VoidCallback onNope;
  final VoidCallback onReset;
  final ValueChanged<String>? onToneChanged;
  final ValueChanged<Color> onColorChanged;

  const _HabitCard({
    required this.habit,
    required this.toneOptions,
    required this.onNope,
    required this.onReset,
    required this.onColorChanged,
    this.onToneChanged,
  });

  @override
  Widget build(BuildContext context) {
    final habitColor = Color(habit.colorValue);
    final tappedToday = habit.tappedToday(DateTime.now());
    final lastUrges = habit.urgeLog.reversed.take(3).toList();

    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      decoration: BoxDecoration(
        color: const Color(0xFF111111),
        borderRadius: BorderRadius.circular(20),
        border: Border(
          left: BorderSide(color: habitColor, width: 3),
        ),
      ),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 18, 16, 18),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Header row
            Row(
              children: [
                // Color dot (tap to change)
                GestureDetector(
                  onTap: () => _showColorPicker(context),
                  child: Container(
                    width: 12,
                    height: 12,
                    margin: const EdgeInsets.only(right: 10, top: 2),
                    decoration: BoxDecoration(
                      color: habitColor,
                      shape: BoxShape.circle,
                    ),
                  ),
                ),
                Expanded(
                  child: Text(
                    habit.name,
                    style: const TextStyle(
                      fontSize: 20,
                      fontWeight: FontWeight.w800,
                      letterSpacing: -0.5,
                    ),
                  ),
                ),
                IconButton(
                  tooltip: "Reset streak",
                  padding: EdgeInsets.zero,
                  constraints: const BoxConstraints(minWidth: 36, minHeight: 36),
                  onPressed: onReset,
                  icon: const Icon(Icons.refresh, size: 20, color: Colors.white38),
                ),
              ],
            ),

            const SizedBox(height: 4),

            // Streak info
            Row(
              children: [
                _StatChip(
                  label: "streak",
                  value: "${habit.streak}d",
                  color: habitColor,
                  highlight: true,
                ),
                const SizedBox(width: 8),
                _StatChip(
                  label: "best",
                  value: "${habit.longestStreak}d",
                  color: Colors.white24,
                ),
                if (habit.lastTap != null) ...[
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      "last: ${_formatDate(habit.lastTap!)}",
                      style: const TextStyle(fontSize: 11, color: Colors.white30),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ],
              ],
            ),

            const SizedBox(height: 18),

            // NOPE Button
            Center(
              child: _NopeButton(
                onTap: onNope,
                color: habitColor,
                tappedToday: tappedToday,
              ),
            ),

            // Adaptive message
            if (habit.lastLine != null) ...[
              const SizedBox(height: 14),
              AnimatedSwitcher(
                duration: const Duration(milliseconds: 300),
                child: Text(
                  habit.lastLine!,
                  key: ValueKey(habit.lastLine),
                  style: TextStyle(
                    color: tappedToday ? habitColor.withOpacity(0.8) : Colors.white54,
                    fontSize: 14,
                    fontStyle: FontStyle.italic,
                  ),
                ),
              ),
            ],

            // Recent urges
            if (lastUrges.isNotEmpty) ...[
              const SizedBox(height: 12),
              Wrap(
                spacing: 6,
                runSpacing: 6,
                children: lastUrges
                    .map((iso) => Container(
                          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                          decoration: BoxDecoration(
                            color: Colors.white.withOpacity(0.05),
                            borderRadius: BorderRadius.circular(8),
                          ),
                          child: Text(
                            iso.replaceFirst('T', ' ').split('.').first,
                            style: const TextStyle(fontSize: 11, color: Colors.white30),
                          ),
                        ))
                    .toList(),
              ),
            ],
          ],
        ),
      ),
    );
  }

  void _showColorPicker(BuildContext context) async {
    final Color currentColor = Color(habit.colorValue);
    final result = await showDialog<Color>(
      context: context,
      builder: (_) => AlertDialog(
        backgroundColor: const Color(0xFF141414),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        title: const Text("Pick a color"),
        content: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: presetColors.entries.map((entry) {
            return GestureDetector(
              onTap: () => Navigator.pop(context, entry.value),
              child: Container(
                width: 42,
                height: 42,
                margin: const EdgeInsets.symmetric(horizontal: 5),
                decoration: BoxDecoration(
                  color: entry.value,
                  shape: BoxShape.circle,
                  border: Border.all(
                    color: entry.value == currentColor ? Colors.white : Colors.transparent,
                    width: 3,
                  ),
                ),
              ),
            );
          }).toList(),
        ),
      ),
    );
    if (result != null) onColorChanged(result);
  }

  String _formatDate(DateTime dt) {
    final now = DateTime.now();
    final diff = now.difference(dt).inDays;
    if (diff == 0) return "today";
    if (diff == 1) return "yesterday";
    return "${dt.month}/${dt.day}";
  }
}

class _StatChip extends StatelessWidget {
  final String label;
  final String value;
  final Color color;
  final bool highlight;

  const _StatChip({
    required this.label,
    required this.value,
    required this.color,
    this.highlight = false,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      decoration: BoxDecoration(
        color: highlight ? color.withOpacity(0.12) : Colors.white.withOpacity(0.05),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            value,
            style: TextStyle(
              fontSize: 14,
              fontWeight: FontWeight.w800,
              color: highlight ? color : Colors.white54,
              letterSpacing: -0.5,
            ),
          ),
          const SizedBox(width: 3),
          Text(
            label,
            style: TextStyle(
              fontSize: 11,
              color: highlight ? color.withOpacity(0.7) : Colors.white30,
            ),
          ),
        ],
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// ANIMATED NOPE BUTTON
// ─────────────────────────────────────────────────────────────────────────────
class _NopeButton extends StatefulWidget {
  final VoidCallback onTap;
  final Color color;
  final bool tappedToday;

  const _NopeButton({
    required this.onTap,
    required this.color,
    required this.tappedToday,
  });

  @override
  State<_NopeButton> createState() => _NopeButtonState();
}

class _NopeButtonState extends State<_NopeButton> with SingleTickerProviderStateMixin {
  bool _pressed = false;

  @override
  Widget build(BuildContext context) {
    final color = widget.tappedToday ? widget.color : Colors.white;
    final bg = widget.tappedToday
        ? widget.color.withOpacity(0.12)
        : const Color(0xFF1A1A1A);

    return GestureDetector(
      onTapDown: (_) => setState(() => _pressed = true),
      onTapUp: (_) {
        setState(() => _pressed = false);
        widget.onTap();
      },
      onTapCancel: () => setState(() => _pressed = false),
      child: AnimatedScale(
        scale: _pressed ? 0.91 : 1.0,
        duration: const Duration(milliseconds: 100),
        curve: Curves.easeOut,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 300),
          width: 130,
          height: 130,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: bg,
            border: Border.all(
              color: widget.tappedToday ? widget.color : Colors.white12,
              width: widget.tappedToday ? 2 : 1,
            ),
            boxShadow: widget.tappedToday
                ? [BoxShadow(color: widget.color.withOpacity(0.25), blurRadius: 20, spreadRadius: 4)]
                : [],
          ),
          child: Center(
            child: AnimatedDefaultTextStyle(
              duration: const Duration(milliseconds: 300),
              style: TextStyle(
                fontSize: 22,
                fontWeight: FontWeight.w900,
                color: color,
                letterSpacing: 3,
              ),
              child: Text(widget.tappedToday ? "✓" : "NOPE."),
            ),
          ),
        ),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// PRESSABLE BUTTON (reusable animated tap wrapper)
// ─────────────────────────────────────────────────────────────────────────────
class _PressableButton extends StatefulWidget {
  final VoidCallback onTap;
  final Widget child;

  const _PressableButton({required this.onTap, required this.child});

  @override
  State<_PressableButton> createState() => _PressableButtonState();
}

class _PressableButtonState extends State<_PressableButton> {
  bool _pressed = false;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTapDown: (_) => setState(() => _pressed = true),
      onTapUp: (_) {
        setState(() => _pressed = false);
        widget.onTap();
      },
      onTapCancel: () => setState(() => _pressed = false),
      child: AnimatedScale(
        scale: _pressed ? 0.96 : 1.0,
        duration: const Duration(milliseconds: 100),
        child: widget.child,
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// CALENDAR VIEW
// ─────────────────────────────────────────────────────────────────────────────
class CalendarView extends StatefulWidget {
  final List<Habit> habits;
  const CalendarView({required this.habits, super.key});

  @override
  State<CalendarView> createState() => _CalendarViewState();
}

class _CalendarViewState extends State<CalendarView> {
  DateTime _focusedDay = DateTime.now();
  DateTime? _selectedDay;

  List<Habit> habitsOnDay(DateTime day) {
    return widget.habits.where((h) {
      return h.urgeLog.any((iso) {
        final dt = DateTime.parse(iso);
        return dt.year == day.year && dt.month == day.month && dt.day == day.day;
      });
    }).toList();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF080808),
      appBar: AppBar(
        backgroundColor: const Color(0xFF080808),
        elevation: 0,
        title: const Text(
          "Calendar",
          style: TextStyle(fontWeight: FontWeight.w800, letterSpacing: -0.5),
        ),
      ),
      body: Column(
        children: [
          TableCalendar(
            firstDay: DateTime.utc(2023, 1, 1),
            lastDay: DateTime.now().add(const Duration(days: 365)),
            focusedDay: _focusedDay,
            calendarFormat: CalendarFormat.month,
            selectedDayPredicate: (day) => isSameDay(_selectedDay, day),
            onDaySelected: (selected, focused) {
              setState(() {
                _selectedDay = selected;
                _focusedDay = focused;
              });
            },
            calendarStyle: const CalendarStyle(
              defaultTextStyle: TextStyle(color: Colors.white70),
              weekendTextStyle: TextStyle(color: Colors.white54),
              outsideTextStyle: TextStyle(color: Colors.white24),
              todayDecoration: BoxDecoration(
                color: Colors.white24,
                shape: BoxShape.circle,
              ),
              selectedDecoration: BoxDecoration(
                color: Colors.white,
                shape: BoxShape.circle,
              ),
              selectedTextStyle: TextStyle(color: Color(0xFF080808), fontWeight: FontWeight.w800),
              todayTextStyle: TextStyle(color: Colors.white, fontWeight: FontWeight.w600),
            ),
            headerStyle: const HeaderStyle(
              formatButtonVisible: false,
              titleCentered: true,
              titleTextStyle: TextStyle(
                fontWeight: FontWeight.w800,
                fontSize: 16,
                letterSpacing: -0.5,
              ),
              leftChevronIcon: Icon(Icons.chevron_left, color: Colors.white54),
              rightChevronIcon: Icon(Icons.chevron_right, color: Colors.white54),
            ),
            daysOfWeekStyle: const DaysOfWeekStyle(
              weekdayStyle: TextStyle(color: Colors.white38, fontSize: 12),
              weekendStyle: TextStyle(color: Colors.white24, fontSize: 12),
            ),
            calendarBuilders: CalendarBuilders(
              markerBuilder: (context, day, _) {
                final h = habitsOnDay(day);
                if (h.isEmpty) return null;
                return Positioned(
                  bottom: 4,
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: h.map((habit) => Container(
                      width: 5,
                      height: 5,
                      margin: const EdgeInsets.symmetric(horizontal: 1),
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: Color(habit.colorValue),
                      ),
                    )).toList(),
                  ),
                );
              },
            ),
          ),
          const SizedBox(height: 16),
          if (_selectedDay != null)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 24),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    "Resisted on ${_selectedDay!.month}/${_selectedDay!.day}/${_selectedDay!.year}",
                    style: const TextStyle(
                      fontWeight: FontWeight.w800,
                      fontSize: 16,
                      letterSpacing: -0.3,
                    ),
                  ),
                  const SizedBox(height: 10),
                  ...habitsOnDay(_selectedDay!).map((h) => Padding(
                    padding: const EdgeInsets.only(bottom: 8),
                    child: Row(
                      children: [
                        Container(
                          width: 10,
                          height: 10,
                          margin: const EdgeInsets.only(right: 10),
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            color: Color(h.colorValue),
                          ),
                        ),
                        Text(h.name, style: const TextStyle(color: Colors.white70)),
                      ],
                    ),
                  )),
                  if (habitsOnDay(_selectedDay!).isEmpty)
                    const Text("Nothing logged.", style: TextStyle(color: Colors.white38)),
                ],
              ),
            ),
        ],
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// EMPTY STATE
// ─────────────────────────────────────────────────────────────────────────────
class _EmptyState extends StatelessWidget {
  const _EmptyState();

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 32),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Text(
              "nope.",
              style: TextStyle(
                fontSize: 56,
                fontWeight: FontWeight.w900,
                color: Colors.white12,
                letterSpacing: -3,
              ),
            ),
            const SizedBox(height: 16),
            const Text(
              "No habits yet.",
              style: TextStyle(
                fontSize: 20,
                color: Colors.white38,
                fontWeight: FontWeight.w600,
                letterSpacing: -0.5,
              ),
            ),
            const SizedBox(height: 8),
            const Text(
              "Add a habit and hit NOPE\nonce a day to grow your streak.",
              textAlign: TextAlign.center,
              style: TextStyle(
                color: Colors.white24,
                fontSize: 15,
                height: 1.5,
              ),
            ),
          ],
        ),
      ),
    );
  }
}