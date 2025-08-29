import 'dart:convert';
import 'dart:math' as math;

import 'package:confetti/confetti.dart';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:table_calendar/table_calendar.dart';
void main() {
  runApp(const NopeApp());
}

final Map<String, Color> presetColors = {
  "Blue": Colors.blue,
  "Red": Colors.red,
  "Green": Colors.green,
  "Orange": Colors.orange,
  "Purple": Colors.purple,
};

class NopeApp extends StatelessWidget {
  const NopeApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Nope.',
      theme: ThemeData.dark().copyWith(
        scaffoldBackgroundColor: const Color(0xFF0B0B0B),
        snackBarTheme: const SnackBarThemeData(behavior: SnackBarBehavior.floating),
      ),
      home: const NopeHome(),
      debugShowCheckedModeBanner: false,
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// MODEL
// ─────────────────────────────────────────────────────────────────────────────
class Habit {
  String id;
  String name;
  String tonePack; // Light | Dark | Dry | Savage
  int streak;
  int longestStreak;
  int lastTapMillis; // last day you pressed NOPE for this habit
  int colorValue;    // store color as int
  List<String> urgeLog; // ISO timestamps
  String? lastLine; // last adaptive comment shown

  Habit({
    required this.id,
    required this.name,
    this.tonePack = 'Light',
    this.streak = 0,
    this.longestStreak = 0,
    this.lastTapMillis = 0,
    List<String>? urgeLog,
    this.lastLine,
    this.colorValue = 0xFF2196F3, // default color blue
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
    if (last.isBefore(yesterday)) {
      streak = 0;
    }
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

  // ✅ Only one toJson
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

  // ✅ Only one fromJson
  factory Habit.fromJson(Map<String, dynamic> j) => Habit(
        id: j['id'] as String,
        name: j['name'] as String,
        tonePack: (j['tonePack'] as String?) ?? 'Light',
        streak: (j['streak'] as int?) ?? 0,
        longestStreak: (j['longestStreak'] as int?) ?? 0,
        lastTapMillis: (j['lastTapMillis'] as int?) ?? 0,
        urgeLog: (j['urgeLog'] as List?)?.map((e) => e.toString()).toList() ?? [],
        lastLine: j['lastLine'] as String?,
        colorValue: (j['colorValue'] as int?) ?? 0xFF2196F3,
      );
}
// ─────────────────────────────────────────────────────────────────────────────
// HOME (MULTI-HABIT)
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
      "You’re stronger than your impulses!",
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

  Set<DateTime> _allNopeDays() {
  final days = <DateTime>{};
  for (final h in habits) {
    for (final iso in h.urgeLog) {
      final dt = DateTime.parse(iso);
      days.add(DateTime(dt.year, dt.month, dt.day)); // normalize to date only
    }
  }
  return days;
  }
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

  // ─────────── Persistence
  Future<void> _loadHabits() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString('habits');
    final now = DateTime.now();

    if (raw != null && raw.isNotEmpty) {
      final list = (jsonDecode(raw) as List).cast<Map<String, dynamic>>();
      habits = list.map(Habit.fromJson).toList();
      // refresh missed days
      for (final h in habits) {
        h.refreshForToday(now);
      }
    } else {
      habits = []; // start empty
    }
    setState(() {});
  }

  Future<void> _saveHabits() async {
    final prefs = await SharedPreferences.getInstance();
    final encoded = jsonEncode(habits.map((e) => e.toJson()).toList());
    await prefs.setString('habits', encoded);
  }

  // ─────────── Actions
  void _addHabit() async {
    final created = await showDialog<Habit>(
      context: context,
      builder: (context) {
        final nameCtrl = TextEditingController();
        final streakCtrl = TextEditingController();
        // String tone = 'Light';
        Color selectedColor = presetColors["Blue"]!;
        return StatefulBuilder(
          builder: (context, setState) {
            return AlertDialog(
              backgroundColor: const Color(0xFF141414),
              title: const Text("Add Habit"),
              content: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  TextField(
                    controller: nameCtrl,
                    decoration: const InputDecoration(
                      labelText: "Habit name",
                      hintText: "e.g., No Vaping",
                    ),
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: streakCtrl,
                    keyboardType: TextInputType.number,
                    decoration: const InputDecoration(
                      labelText: "Current streak (days resisted)",
                      hintText: "0",
                    ),
                  ),
                  const SizedBox(height: 12),
                  // Color picker (preset colors)
                  Align(
                    alignment: Alignment.centerLeft,
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text("Color", style: TextStyle(fontSize: 13, color: Colors.white70)),
                        const SizedBox(height: 6),
                        Wrap(
                          spacing: 10,
                          children: presetColors.entries.map((entry) {
                            return GestureDetector(
                              onTap: () {
                                setState(() {
                                  selectedColor = entry.value;
                                });
                              },
                              child: Container(
                                width: 36,
                                height: 36,
                                decoration: BoxDecoration(
                                  color: entry.value,
                                  shape: BoxShape.circle,
                                  border: Border.all(
                                    color: entry.value == selectedColor ? Colors.white : Colors.transparent,
                                    width: 3,
                                  ),
                                ),
                              ),
                            );
                          }).toList(),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
              actions: [
                TextButton(onPressed: () => Navigator.pop(context), child: const Text("Cancel")),
                ElevatedButton(
                  onPressed: () {
                    final name = nameCtrl.text.trim();
                    if (name.isEmpty) return;
                    final streak = int.tryParse(streakCtrl.text.trim()) ?? 0;
                    final h = Habit(
                      id: DateTime.now().millisecondsSinceEpoch.toString(),
                      name: name,
                      // tonePack: tone,
                      streak: streak,
                      longestStreak: streak,
                      lastTapMillis: 0,
                      colorValue: selectedColor.value,
                    );
                    Navigator.pop(context, h);
                  },
                  child: const Text("Add"),
                ),
              ],
            );
          },
        );
      },
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
    setState(() {
      h.streak = 0;
      h.lastTapMillis = 0;
      h.lastLine = "Streak reset. Get back on track!";
    });
    _saveHabits();
  }

  String _adaptiveMessage(Habit h) {
    final msgs = tonePacks[h.tonePack] ?? tonePacks['Light']!;
    if (h.streak < 5) {
      return "Early days — stay strong!";
    } else if (h.streak < 15) {
      return msgs[math.Random().nextInt(msgs.length)];
    } else if (h.streak < 30) {
      return "🔥 You're building serious momentum!";
    } else {
      return "🏆 Legend mode unlocked. ${h.streak} days!";
    }
  }

  void _pressNope(Habit h) {
    final now = DateTime.now();
    setState(() {
      // Refresh to check if they missed days before counting today
      h.refreshForToday(now);

      final incremented = h.registerNope(now);
      if (incremented) {
        _confettiController.play();
        h.lastLine = _adaptiveMessage(h);
      } else {
        h.lastLine = "Already counted today. Come back tomorrow ✌️";
      }
    });
    _saveHabits();

    // Optional toast for instant feedback
    final msg = h.lastLine ?? 'Nice.';
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(msg), duration: const Duration(seconds: 2)),
    );
  }

  void _changeTone(Habit h, String tone) {
    setState(() => h.tonePack = tone);
    _saveHabits();
  }

  void _changeColor(Habit h, Color newColor) {
    setState(() {
      h.colorValue = newColor.value;
    });
    _saveHabits();
  }

  // ─────────── UI
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
    title: const Text("nope."),
    actions: [
      if (habits.isNotEmpty)
        IconButton(
          tooltip: "Calendar view",
          icon: const Icon(Icons.calendar_today),
          onPressed: () {
            Navigator.push(
              context,
              MaterialPageRoute(
                builder: (_) => CalendarView(habits: habits),
              ),
            );
          },
        ),
      if (habits.isNotEmpty)
        IconButton(
          tooltip: "Reset all streaks",
          onPressed: () {
            for (final h in habits) {
              h.streak = 0;
              h.lastTapMillis = 0;
              h.lastLine = "Reset. New chapter starts now.";
            }
            setState(() {});
            _saveHabits();
          },
          icon: const Icon(Icons.restart_alt),
        ),
    ],
  ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _addHabit,
        label: const Text("Add Habit"),
        icon: const Icon(Icons.add),
      ),
      body: Stack(
        children: [
          // Main scrollable content
          if (habits.isEmpty)
            const _EmptyState()
          else
            SingleChildScrollView(
              padding: const EdgeInsets.only(bottom: 96),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  ...habits.map((h) => Dismissible(
                        key: ValueKey(h.id),
                        background: Container(
                          margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                          decoration: BoxDecoration(
                            color: Colors.redAccent.withOpacity(0.2),
                            borderRadius: BorderRadius.circular(16),
                          ),
                          alignment: Alignment.centerLeft,
                          padding: const EdgeInsets.only(left: 24),
                          child: const Icon(Icons.delete_outline),
                        ),
                        direction: DismissDirection.startToEnd,
                        confirmDismiss: (_) async {
                          return await showDialog<bool>(
                                context: context,
                                builder: (_) => AlertDialog(
                                  backgroundColor: const Color(0xFF141414),
                                  title: const Text("Delete habit?"),
                                  content: Text("This removes \"${h.name}\" and its history."),
                                  actions: [
                                    TextButton(onPressed: () => Navigator.pop(context, false), child: const Text("Cancel")),
                                    ElevatedButton(onPressed: () => Navigator.pop(context, true), child: const Text("Delete")),
                                  ],
                                ),
                              ) ??
                              false;
                        },
                        onDismissed: (_) => _deleteHabit(h),
                        child: _HabitCard(
                          habit: h,
                          toneOptions: tonePacks.keys.toList(),
                          onNope: () => _pressNope(h),
                          onReset: () => _resetHabit(h),
                          onToneChanged: (t) => _changeTone(h, t),
                          onColorChanged: (color) => _changeColor(h, color),
                        ),
                      )),
                  const SizedBox(height: 12),
                ],
              ),
            ),
          // Confetti overlay for any habit success
          Positioned.fill(
            child: IgnorePointer(
              child: Align(
                alignment: Alignment.center,
                child: ConfettiWidget(
                  confettiController: _confettiController,
                  blastDirectionality: BlastDirectionality.explosive,
                  shouldLoop: false,
                  maxBlastForce: 20,
                  minBlastForce: 5,
                  emissionFrequency: 0.03,
                  numberOfParticles: 20,
                  gravity: 0.4,
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
// WIDGETS
// ─────────────────────────────────────────────────────────────────────────────
class _HabitCard extends StatelessWidget {
  final Habit habit;
  final List<String> toneOptions;
  final VoidCallback onNope;
  final VoidCallback onReset;
  final ValueChanged<String> onToneChanged;
  final ValueChanged<Color> onColorChanged;

  const _HabitCard({
    required this.habit,
    required this.toneOptions,
    required this.onNope,
    required this.onReset,
    required this.onToneChanged,
    required this.onColorChanged,
  });

  @override
  Widget build(BuildContext context) {
    final lastUrges = habit.urgeLog.reversed.take(3).toList();

    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      color: const Color(0xFF141414),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 14, 16, 16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Title row + actions + color selector
            Row(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                Expanded(
                  child: Text(
                    habit.name,
                    style: const TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
                  ),
                ),
                // Color selector next to reset button
                _CircularColorSelector(
                  currentColorValue: habit.colorValue,
                  onColorChanged: onColorChanged,
                ),
                const SizedBox(width: 4),
                IconButton(
                  tooltip: "Reset streak",
                  onPressed: onReset,
                  icon: const Icon(Icons.refresh),
                ),
              ],
            ),
            const SizedBox(height: 4),
            Row(
              children: [
                Text("Streak: ${habit.streak} day${habit.streak == 1 ? '' : 's'}"),
                const SizedBox(width: 12),
                Text("Best: ${habit.longestStreak}"),
                if (habit.lastTap != null) ...[
                  const SizedBox(width: 12),
                  Text(
                    "Last: ${habit.lastTap!.toLocal().toString().split('.').first}",
                    style: const TextStyle(fontSize: 12, color: Colors.white54),
                  ),
                ],
              ],
            ),
            const SizedBox(height: 12),
            // NOPE button
            Center(
              child: ElevatedButton(
                style: ElevatedButton.styleFrom(
                  backgroundColor: const Color(0xFF222222),
                  shape: const CircleBorder(),
                  padding: const EdgeInsets.all(40), // controls the size of the circle
                ),
                onPressed: onNope,
                child: const Text(
                  "NOPE.",
                  style: TextStyle(
                    fontSize: 24,
                    fontWeight: FontWeight.w800,
                    letterSpacing: 2,
                  ),
                ),
              ),
            ),

            if (habit.lastLine != null) ...[
              const SizedBox(height: 12),
              Text(
                habit.lastLine!,
                textAlign: TextAlign.left,
                style: const TextStyle(color: Colors.white70, fontSize: 15),
              ),
            ],

            const SizedBox(height: 10),
            if (lastUrges.isNotEmpty) ...[
              const Text("Recent urges:", style: TextStyle(color: Colors.white70)),
              const SizedBox(height: 6),
              Wrap(
                spacing: 8,
                runSpacing: 6,
                children: lastUrges
                    .map(
                      (iso) => Container(
                        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                        decoration: BoxDecoration(
                          color: const Color(0xFF1E1E1E),
                          borderRadius: BorderRadius.circular(12),
                        ),
                        child: Text(
                          iso.replaceFirst('T', ' ').split('.').first,
                          style: const TextStyle(fontSize: 12, color: Colors.white54),
                        ),
                      ),
                    )
                    .toList(),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _CircularColorSelector extends StatelessWidget {
  final int currentColorValue;
  final ValueChanged<Color> onColorChanged;

  const _CircularColorSelector({
    required this.currentColorValue,
    required this.onColorChanged,
  });

  @override
  Widget build(BuildContext context) {
    Color currentColor = Color(currentColorValue);

    return Center(
      child: GestureDetector(
        onTap: () async {
          final selectedColorName = await showDialog<String>(
            context: context,
            builder: (context) {
              return AlertDialog(
                backgroundColor: const Color(0xFF141414),
                title: const Text("Select Color"),
                content: Wrap(
                  spacing: 10,
                  children: presetColors.entries.map((entry) {
                    return GestureDetector(
                      onTap: () => Navigator.pop(context, entry.key),
                      child: Container(
                        width: 40,
                        height: 40,
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
              );
            },
          );

          if (selectedColorName != null) {
            onColorChanged(presetColors[selectedColorName]!);
          }
        },
        child: Container(
          width: 36,
          height: 36,
          decoration: BoxDecoration(
            color: currentColor,
            shape: BoxShape.circle,
            border: Border.all(color: Colors.white, width: 2),
          ),
        ),
      ),
    );
  }
}

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
      appBar: AppBar(title: const Text("Calendar")),
      body: Column(
        children: [
          TableCalendar(
            firstDay: DateTime.utc(2023, 1, 1),
            lastDay: DateTime.now().add(const Duration(days: 365)),
            focusedDay: _focusedDay,
            calendarFormat: CalendarFormat.month,
            selectedDayPredicate: (day) => isSameDay(_selectedDay, day),
            onDaySelected: (selectedDay, focusedDay) {
              setState(() {
                _selectedDay = selectedDay;
                _focusedDay = focusedDay;
              });
            },
            calendarBuilders: CalendarBuilders(
              markerBuilder: (context, day, events) {
                final habits = habitsOnDay(day);
                if (habits.isEmpty) return null;
                return Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: habits.map((h) {
                    return Container(
                      width: 6,
                      height: 6,
                      margin: const EdgeInsets.symmetric(horizontal: 1),
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: Color(h.colorValue),
                      ),
                    );
                  }).toList(),
                );
              },
            ),
          ),
          const SizedBox(height: 12),
          if (_selectedDay != null)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    "Habits resisted on ${_selectedDay!.toLocal().toString().split(' ')[0]}:",
                    style: const TextStyle(fontWeight: FontWeight.bold),
                  ),
                  const SizedBox(height: 6),
                  ...habitsOnDay(_selectedDay!).map((h) {
                    return Row(
                      children: [
                        Container(
                          width: 12,
                          height: 12,
                          margin: const EdgeInsets.only(right: 6),
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            color: Color(h.colorValue),
                          ),
                        ),
                        Text(h.name),
                      ],
                    );
                  }).toList(),
                ],
              ),
            ),
        ],
      ),
    );
  }
}

class _EmptyState extends StatelessWidget {
  const _EmptyState();

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 24),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: const [
            Icon(Icons.flag_circle_outlined, size: 60, color: Colors.white30),
            SizedBox(height: 14),
            Text(
              "No habits yet",
              style: TextStyle(fontSize: 18, color: Colors.white70),
            ),
            SizedBox(height: 8),
            Text(
              "Tap “Add Habit” to start tracking.\nPress NOPE once per day per habit to grow your streak.",
              textAlign: TextAlign.center,
              style: TextStyle(color: Colors.white54),
            ),
          ],
        ),
      ),
    );
  }
}