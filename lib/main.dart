import 'dart:convert';
import 'dart:math' as math;

import 'package:confetti/confetti.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_timezone/flutter_timezone.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:table_calendar/table_calendar.dart';
import 'package:timezone/data/latest_all.dart' as tz_data;
import 'package:timezone/timezone.dart' as tz;

void main() {
  runApp(const NopeApp());
  _loadThemeMode();
  _setupDailyReminder();
}

final Map<String, Color> presetColors = {
  "Blue": const Color(0xFF5490D7),
  "Red": const Color(0xFFD7546C),
  "Green": const Color(0xFF547B66),
  "Orange": const Color(0xFFD79054),
  "Purple": const Color(0xFFA054D7),
};

// App-wide accent color. Used for the FAB, calendar selection, and focused
// inputs -- anywhere the UI needs a fixed accent rather than a per-habit color.
const Color kAccent = Color(0xFF5490D7); // Blue

// ─────────────────────────────────────────────────────────────────────────────
// THEME (light / dark)
// ─────────────────────────────────────────────────────────────────────────────
// Global so the toggle button (wherever it lives) doesn't need a callback
// threaded all the way down from NopeApp -- it just flips this and every
// screen listening via AppColors.of(context)/ValueListenableBuilder updates.
final ValueNotifier<ThemeMode> themeModeNotifier = ValueNotifier(ThemeMode.dark);

Future<void> _loadThemeMode() async {
  final prefs = await SharedPreferences.getInstance();
  final isLight = prefs.getBool('isLightMode') ?? false;
  themeModeNotifier.value = isLight ? ThemeMode.light : ThemeMode.dark;
}

Future<void> toggleThemeMode() async {
  final next = themeModeNotifier.value == ThemeMode.dark ? ThemeMode.light : ThemeMode.dark;
  themeModeNotifier.value = next;
  final prefs = await SharedPreferences.getInstance();
  await prefs.setBool('isLightMode', next == ThemeMode.light);
}

// Semantic palette: every screen pulls colors from here instead of hardcoding
// hex values, so the whole app (not just the scaffold background) responds
// to the light/dark toggle.
class AppColors {
  final Color bg;
  final Color card;
  final Color dialogBg;
  final Color raised;
  final Color ink; // base text/icon color -- use .withValues(alpha: ) for secondary/tertiary/faint

  const AppColors({
    required this.bg,
    required this.card,
    required this.dialogBg,
    required this.raised,
    required this.ink,
  });

  // card/dialogBg are deliberately not fully opaque (0xE6 ~= 90%) so cards
  // and popups read as slightly translucent against the scaffold instead of
  // flat opaque panels.
  static const dark = AppColors(
    bg: Color(0xFF080808),
    card: Color(0xE6111111),
    dialogBg: Color(0xCC141414),
    raised: Color(0xFF1A1A1A),
    ink: Colors.white,
  );

  static const light = AppColors(
    bg: Color(0xFFF6F6F8),
    card: Color(0xE6FFFFFF),
    dialogBg: Color(0xCCE8E8EA),
    raised: Color(0xFFEFEFF2),
    ink: Color(0xFF0B0B0C),
  );

  static AppColors of(BuildContext context) {
    return Theme.of(context).brightness == Brightness.dark ? dark : light;
  }
}

ThemeData buildAppTheme(Brightness brightness) {
  final colors = brightness == Brightness.dark ? AppColors.dark : AppColors.light;
  final base = brightness == Brightness.dark ? ThemeData.dark() : ThemeData.light();
  return base.copyWith(
    brightness: brightness,
    scaffoldBackgroundColor: colors.bg,
    // Every AlertDialog/showDialog call below sets its own backgroundColor
    // explicitly via AppColors, so we don't rely on (or risk depending on
    // a possibly-deprecated) ThemeData dialog background field here.
    snackBarTheme: const SnackBarThemeData(behavior: SnackBarBehavior.floating),
    colorScheme: base.colorScheme.copyWith(primary: kAccent, secondary: kAccent),
  );
}

// ─────────────────────────────────────────────────────────────────────────────
// DAILY REMINDER (local push notification, mobile only)
// ─────────────────────────────────────────────────────────────────────────────
// A local notification -- unlike the welcome-back dialog and the in-app risk
// banner -- can nudge someone who never opens the app that day. It's mobile
// only: there's no reliable equivalent for a browser tab that isn't open
// (that needs a real push service + backend), so this deliberately no-ops on
// web rather than pretending to work there.
final FlutterLocalNotificationsPlugin _notificationsPlugin = FlutterLocalNotificationsPlugin();

Future<void> _setupDailyReminder() async {
  if (kIsWeb) return;
  try {
    tz_data.initializeTimeZones();
    final localTz = await FlutterTimezone.getLocalTimezone();
    tz.setLocalLocation(tz.getLocation(localTz));
  } catch (_) {
    // If timezone lookup fails for any reason, fall back to whatever the
    // timezone package defaults to (UTC) rather than crash startup over a
    // reminder notification.
  }

  const androidInit = AndroidInitializationSettings('@mipmap/ic_launcher');
  const darwinInit = DarwinInitializationSettings(
    requestAlertPermission: true,
    requestBadgePermission: true,
    requestSoundPermission: true,
  );

  try {
    await _notificationsPlugin.initialize(
      const InitializationSettings(android: androidInit, iOS: darwinInit, macOS: darwinInit),
    );

    final androidImpl = _notificationsPlugin.resolvePlatformSpecificImplementation<
        AndroidFlutterLocalNotificationsPlugin>();
    await androidImpl?.requestNotificationsPermission();

    await _notificationsPlugin.zonedSchedule(
      0,
      "Don't lose your streak",
      "You haven't hit NOPE today yet — a minute now keeps it alive.",
      _nextDailyReminderTime(hour: 20, minute: 0),
      const NotificationDetails(
        android: AndroidNotificationDetails(
          'daily_reminder',
          'Daily reminder',
          channelDescription: "Reminds you if you haven't checked in yet today",
          importance: Importance.defaultImportance,
        ),
        iOS: DarwinNotificationDetails(),
        macOS: DarwinNotificationDetails(),
      ),
      androidScheduleMode: AndroidScheduleMode.inexactAllowWhileIdle,
      uiLocalNotificationDateInterpretation: UILocalNotificationDateInterpretation.absoluteTime,
      matchDateTimeComponents: DateTimeComponents.time,
    );
  } catch (_) {
    // Best-effort: a habit-reminder notification failing to schedule (e.g.
    // permission denied) shouldn't take down the rest of the app.
  }
}

tz.TZDateTime _nextDailyReminderTime({required int hour, required int minute}) {
  final now = tz.TZDateTime.now(tz.local);
  var scheduled = tz.TZDateTime(tz.local, now.year, now.month, now.day, hour, minute);
  if (scheduled.isBefore(now)) {
    scheduled = scheduled.add(const Duration(days: 1));
  }
  return scheduled;
}

// Icon choices offered when creating/editing a habit -- picked to cover
// common things people are trying to resist or build, so the avatar in the
// add-habit sheet and habit card actually means something. "Block" (a stop
// sign) is first and doubles as the default for new/legacy habits.
const List<IconData> presetIcons = [
  Icons.block,
  Icons.smoking_rooms,
  Icons.local_bar,
  Icons.fastfood,
  Icons.local_cafe,
  Icons.phone_android,
  Icons.sports_esports,
  Icons.shopping_bag,
  Icons.nightlight_round,
  Icons.self_improvement,
  Icons.fitness_center,
];

IconData habitIconForCodePoint(int codePoint) {
  return presetIcons.firstWhere(
    (i) => i.codePoint == codePoint,
    orElse: () => presetIcons.first,
  );
}

// Opens a plain RGB-slider color picker and resolves with the chosen color,
// or null if cancelled. Shared by the add-habit sheet and the habit-card
// customize dialog so either flow can pick any color, not just the five
// presets. Deliberately no extra package -- three sliders is enough control
// without pulling in a whole HSV-wheel dependency.
Future<Color?> _pickCustomColor(BuildContext context, Color initial) {
  return showDialog<Color>(
    context: context,
    builder: (dialogContext) {
      int r = initial.red;
      int g = initial.green;
      int b = initial.blue;
      return StatefulBuilder(
        builder: (context, setDialogState) {
          final current = Color.fromARGB(255, r, g, b);
          return AlertDialog(
            backgroundColor: AppColors.of(context).dialogBg,
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
            title: Text("Custom color", style: dialogTitleStyle(context)),
            content: SizedBox(
              width: 280,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Container(
                    width: 56,
                    height: 56,
                    margin: const EdgeInsets.only(bottom: 18),
                    decoration: BoxDecoration(
                      color: current,
                      shape: BoxShape.circle,
                      boxShadow: [BoxShadow(color: current.withValues(alpha: 0.5), blurRadius: 16, spreadRadius: 1)],
                    ),
                  ),
                  _ColorChannelSlider(
                    label: "R",
                    value: r,
                    trackColor: Colors.redAccent,
                    onChanged: (v) => setDialogState(() => r = v),
                  ),
                  _ColorChannelSlider(
                    label: "G",
                    value: g,
                    trackColor: Colors.greenAccent,
                    onChanged: (v) => setDialogState(() => g = v),
                  ),
                  _ColorChannelSlider(
                    label: "B",
                    value: b,
                    trackColor: Colors.lightBlueAccent,
                    onChanged: (v) => setDialogState(() => b = v),
                  ),
                ],
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context),
                child: const Text("Cancel"),
              ),
              ElevatedButton(
                style: ElevatedButton.styleFrom(backgroundColor: current, foregroundColor: Colors.white),
                onPressed: () => Navigator.pop(context, current),
                child: const Text("Select"),
              ),
            ],
          );
        },
      );
    },
  );
}

class _ColorChannelSlider extends StatelessWidget {
  final String label;
  final int value;
  final Color trackColor;
  final ValueChanged<int> onChanged;

  const _ColorChannelSlider({
    required this.label,
    required this.value,
    required this.trackColor,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        SizedBox(
          width: 16,
          child: Text(
            label,
            style: TextStyle(color: trackColor, fontWeight: FontWeight.w800, fontSize: 13),
          ),
        ),
        Expanded(
          child: SliderTheme(
            data: SliderTheme.of(context).copyWith(trackHeight: 3),
            child: Slider(
              value: value.toDouble(),
              min: 0,
              max: 255,
              activeColor: trackColor,
              inactiveColor: trackColor.withValues(alpha: 0.15),
              onChanged: (v) => onChanged(v.round()),
            ),
          ),
        ),
        SizedBox(
          width: 32,
          child: Text(
            "$value",
            textAlign: TextAlign.right,
            style: TextStyle(
              color: AppColors.of(context).ink.withValues(alpha: 0.54),
              fontSize: 12,
              fontWeight: FontWeight.w600,
            ),
          ),
        ),
      ],
    );
  }
}

// A small rainbow-ring icon used on both "pick a custom color" buttons below
// so it reads as "more colors" even before anything custom is chosen.
const SweepGradient _customSwatchGradient = SweepGradient(colors: [
  Color(0xFFD7546C),
  Color(0xFFB6A02B),
  Color(0xFF547B66),
  Color(0xFF5490D7),
  Color(0xFFA054D7),
  Color(0xFFD7546C),
]);

// Rounded-rect swatch matching the add-habit sheet's preset color row.
Widget _customColorCardSwatch({
  required Color current,
  required bool isCustom,
  required VoidCallback onTap,
  required Color ink,
}) {
  return Expanded(
    child: GestureDetector(
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 200),
        curve: Curves.easeOut,
        height: 52,
        decoration: BoxDecoration(
          color: isCustom ? current.withValues(alpha: 0.22) : ink.withValues(alpha: 0.08),
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: isCustom ? current : Colors.transparent, width: 2),
        ),
        child: Center(
          child: Container(
            width: 18,
            height: 18,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: isCustom ? current : null,
              gradient: isCustom ? null : _customSwatchGradient,
              boxShadow: isCustom ? [BoxShadow(color: current.withValues(alpha: 0.6), blurRadius: 8)] : [],
            ),
            child: Icon(isCustom ? Icons.check : Icons.colorize, color: Colors.white, size: 10),
          ),
        ),
      ),
    ),
  );
}

// Plain circle swatch matching the habit-card customize dialog's color row.
Widget _customColorCircleSwatch({
  required Color current,
  required bool isCustom,
  required VoidCallback onTap,
}) {
  return GestureDetector(
    onTap: onTap,
    child: Container(
      width: 42,
      height: 42,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: isCustom ? current : null,
        gradient: isCustom ? null : _customSwatchGradient,
        border: Border.all(color: isCustom ? Colors.white : Colors.transparent, width: 3),
      ),
      child: Icon(isCustom ? Icons.check : Icons.colorize, color: Colors.white, size: 18),
    ),
  );
}

bool _isPresetColor(Color c) => presetColors.values.any((p) => p.value == c.value);

// Shared dialog typography -- every showDialog/AlertDialog in the app routes
// its title and body through these two so no popup ever drifts from the
// app's bold-header, plain-body look (the default AlertDialog text theme is
// much lighter-weight and reads as a different font at a glance).
TextStyle dialogTitleStyle(BuildContext context) => TextStyle(
      fontSize: 19,
      fontWeight: FontWeight.w800,
      letterSpacing: -0.4,
      color: AppColors.of(context).ink,
    );

TextStyle dialogBodyStyle(BuildContext context) => TextStyle(
      fontSize: 14.5,
      fontWeight: FontWeight.w500,
      height: 1.35,
      color: AppColors.of(context).ink.withValues(alpha: 0.75),
    );

// ─────────────────────────────────────────────────────────────────────────────
// APP
// ─────────────────────────────────────────────────────────────────────────────
class NopeApp extends StatelessWidget {
  const NopeApp({super.key});

  @override
  Widget build(BuildContext context) {
    // 'Helvetica Neue' isn't bundled as an asset font (no `fonts:` entry in
    // pubspec.yaml), so we deliberately don't set a custom fontFamily here --
    // doing so used to force a slow Skia font-fallback resolution on every
    // Text widget's first layout (worst on text-heavy screens like the intro
    // and add-habit sheet). Platform default font avoids that.
    return ValueListenableBuilder<ThemeMode>(
      valueListenable: themeModeNotifier,
      builder: (context, mode, _) {
        return MaterialApp(
          title: 'Nope.',
          themeMode: mode,
          theme: buildAppTheme(Brightness.light),
          darkTheme: buildAppTheme(Brightness.dark),
          home: const AppEntry(),
          debugShowCheckedModeBanner: false,
        );
      },
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
          pageBuilder: (_, _, _) => const NopeHome(),
          transitionDuration: const Duration(milliseconds: 600),
          transitionsBuilder: (_, anim, _, child) =>
              FadeTransition(opacity: anim, child: child),
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_showIntro == null) {
      return Scaffold(backgroundColor: AppColors.of(context).bg);
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
    final colors = AppColors.of(context);
    return Scaffold(
      backgroundColor: colors.bg,
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
                  child: Text(
                    "nope.",
                    style: TextStyle(
                      fontSize: 88,
                      fontWeight: FontWeight.w900,
                      color: colors.ink,
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
                builder: (_, _) => Container(
                  height: 2,
                  width: _lineWidth.value * (w - 64),
                  color: colors.ink,
                ),
              ),
              const SizedBox(height: 20),
              // Tagline
              FadeTransition(
                opacity: _subFade,
                child: Text(
                  "resist the urge.\ntrack the streak.\ngrow the streak.",
                  style: TextStyle(
                    fontSize: 20,
                    color: colors.ink.withValues(alpha: 0.55),
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
                child: const Column(
                  children: [
                    _IntroFeature(icon: Icons.block, text: "Hit NOPE once a day per habit"),
                    SizedBox(height: 14),
                    _IntroFeature(icon: Icons.local_fire_department, text: "Build streaks. Don't break the chain."),
                    SizedBox(height: 14),
                    _IntroFeature(icon: Icons.calendar_month, text: "See your wins on a calendar"),
                  ],
                ),
              ),
              const Spacer(flex: 2),
              // CTA button -- inverted (ink bg / bg text) so it stays high
              // contrast in both light and dark mode.
              FadeTransition(
                opacity: _btnFade,
                child: _PressableButton(
                  onTap: widget.onComplete,
                  child: Container(
                    width: double.infinity,
                    padding: const EdgeInsets.symmetric(vertical: 20),
                    decoration: BoxDecoration(
                      color: colors.ink,
                      borderRadius: BorderRadius.circular(16),
                    ),
                    child: Center(
                      child: Text(
                        "let's go →",
                        style: TextStyle(
                          color: colors.bg,
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
    final colors = AppColors.of(context);
    return Row(
      children: [
        Icon(icon, color: colors.ink.withValues(alpha: 0.38), size: 20),
        const SizedBox(width: 12),
        Text(
          text,
          style: TextStyle(
            color: colors.ink.withValues(alpha: 0.6),
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
class Habit extends ChangeNotifier {
  String id;
  String name;
  String tonePack;
  int streak;
  int longestStreak;
  int lastTapMillis;
  int colorValue;
  int iconCodePoint;
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
    this.colorValue = 0xFF5490D7, // Blue — default habit color
    this.iconCodePoint = 0, // 0 == "use the default (block/stop sign)" — see habitIconForCodePoint
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

  /// Handles a NOPE tap end-to-end and notifies only listeners of *this*
  /// habit — the parent list never needs to rebuild for this.
  /// Returns true if the streak actually incremented (vs. already tapped today).
  bool nope(DateTime now, String Function(Habit) messageBuilder) {
    refreshForToday(now);
    final incremented = registerNope(now);
    lastLine = incremented
        ? messageBuilder(this)
        : "Already counted today. Come back tomorrow ✌️";
    notifyListeners();
    return incremented;
  }

  void reset() {
    streak = 0;
    lastTapMillis = 0;
    lastLine = "Reset. New chapter starts now.";
    notifyListeners();
  }

  void setColor(Color c) {
    colorValue = c.value;
    notifyListeners();
  }

  void setIcon(IconData icon) {
    iconCodePoint = icon.codePoint;
    notifyListeners();
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
        'iconCodePoint': iconCodePoint,
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
        colorValue: (j['colorValue'] as int?) ?? 0xFF5490D7,
        iconCodePoint: (j['iconCodePoint'] as int?) ?? 0,
      );
}

// ─────────────────────────────────────────────────────────────────────────────
// RESET CONFIRMATION — shared two-step gate for any destructive streak reset
// ─────────────────────────────────────────────────────────────────────────────
/// Encapsulates the "friction" flow for clearing a streak: a reflective
/// question first, then a hard confirmation. Both the per-habit reset and
/// the reset-all action route through the same [confirm] call so the copy
/// and step order only live in one place. When [hasProgress] is false there
/// is nothing to lose, so answering "No" just shows an acknowledgment
/// instead of a reset confirmation -- and nothing actually resets.
class ResetConfirmation {
  ResetConfirmation._(); // not instantiated — call sites use the static API

  static Future<bool> confirm(
    BuildContext context, {
    required String subtitle,
    required String sureBody,
    bool hasProgress = true,
  }) async {
    final gaveIn = await _dialog(
      context,
      title: "Have you resisted until this point?",
      body: subtitle,
      actions: (dialogContext) => [
        TextButton(
          onPressed: () => Navigator.pop(dialogContext, true),
          child: const Text("No"),
        ),
        ElevatedButton(
          style: ElevatedButton.styleFrom(backgroundColor: kAccent, foregroundColor: Colors.white),
          onPressed: () => Navigator.pop(dialogContext, false),
          child: const Text("Yes, keep going"),
        ),
      ],
    );
    // "Yes, keep going" (or dismissing the dialog) means the streak stays.
    if (gaveIn != true) return false;
    if (!context.mounted) return false;

    if (!hasProgress) {
      // Nothing at stake — just acknowledge, don't ask for a reset
      // confirmation and don't reset anything.
      await _dialog(
        context,
        title: "Nothing to reset yet",
        body: sureBody,
        actions: (dialogContext) => [
          ElevatedButton(
            style: ElevatedButton.styleFrom(backgroundColor: kAccent, foregroundColor: Colors.white),
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text("Got it"),
          ),
        ],
      );
      return false;
    }

    final sure = await _dialog(
      context,
      title: "Are you sure?",
      body: sureBody,
      actions: (dialogContext) => [
        TextButton(
          onPressed: () => Navigator.pop(dialogContext, false),
          child: const Text("Cancel"),
        ),
        ElevatedButton(
          style: ElevatedButton.styleFrom(backgroundColor: Colors.redAccent, foregroundColor: Colors.white),
          onPressed: () => Navigator.pop(dialogContext, true),
          child: const Text("Reset"),
        ),
      ],
    );
    return sure ?? false;
  }

  static Future<bool?> _dialog(
    BuildContext context, {
    required String title,
    required String body,
    required List<Widget> Function(BuildContext) actions,
  }) {
    return showDialog<bool>(
      context: context,
      // Default barrier is 54% black; combined with the dialog's own
      // translucent background that reads as the whole screen going dark.
      // A lighter barrier keeps the dim-behind-the-dialog effect subtle.
      barrierColor: Colors.black.withValues(alpha: 0.3),
      builder: (dialogContext) => AlertDialog(
        backgroundColor: AppColors.of(dialogContext).dialogBg,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        title: Text(title, style: dialogTitleStyle(dialogContext)),
        content: Text(body, style: dialogBodyStyle(dialogContext)),
        actions: actions(dialogContext),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// HOME
// ─────────────────────────────────────────────────────────────────────────────
class NopeHome extends StatefulWidget {
  const NopeHome({super.key});

  @override
  State<NopeHome> createState() => _NopeHomeState();
}

class _NopeHomeState extends State<NopeHome> with TickerProviderStateMixin {
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

  // Reset "damage" effect: the body shakes and a red vignette flashes over
  // it, instead of the celebratory confetti burst used for a NOPE tap.
  // _shakeMagnitude scales how hard each plays -- resetting one habit is a
  // small jolt, resetting all of them hits harder.
  late final AnimationController _shakeController = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 420),
  );
  late final AnimationController _flashController = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 550),
  );
  late final Animation<double> _flashAnimation = CurvedAnimation(
    parent: _flashController,
    curve: Curves.easeOut,
  );
  double _shakeMagnitude = 1.0;

  @override
  void initState() {
    super.initState();
    _confettiController = ConfettiController(duration: const Duration(milliseconds: 900));
    _loadHabits();
  }

  @override
  void dispose() {
    _confettiController.dispose();
    _shakeController.dispose();
    _flashController.dispose();
    super.dispose();
  }

  // Plays the shake + red-flash combo. [magnitude] scales the shake's
  // amplitude and the flash's peak opacity -- 1.0 for a single reset, higher
  // for resetting every habit at once.
  void _playResetImpact({double magnitude = 1.0}) {
    _shakeMagnitude = magnitude;
    _shakeController.forward(from: 0);
    _flashController.forward(from: 0).then((_) => _flashController.reverse());
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
    _checkWelcomeBack(prefs, now);
  }

  // Shows a one-time "welcome back" dialog if it's been a couple of days
  // since the app was last opened. Doesn't require any permissions and works
  // identically on web and mobile, unlike push notifications.
  Future<void> _checkWelcomeBack(SharedPreferences prefs, DateTime now) async {
    final lastOpenedMillis = prefs.getInt('lastOpenedMillis');
    await prefs.setInt('lastOpenedMillis', now.millisecondsSinceEpoch);
    if (lastOpenedMillis == null) return; // first-ever launch, nothing to welcome back from
    if (habits.isEmpty) return; // nothing at stake yet

    final lastOpened = DateTime.fromMillisecondsSinceEpoch(lastOpenedMillis);
    final daysAway = DateTime(now.year, now.month, now.day)
        .difference(DateTime(lastOpened.year, lastOpened.month, lastOpened.day))
        .inDays;
    if (daysAway < 2) return;

    final brokenStreaks = habits.where((h) => h.lastTap != null && !h.tappedToday(now) && h.streak == 0).length;

    if (!mounted) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      showDialog(
        context: context,
        builder: (dialogContext) => AlertDialog(
          backgroundColor: AppColors.of(dialogContext).dialogBg,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
          title: Text("Welcome back", style: dialogTitleStyle(dialogContext)),
          content: Text(
            brokenStreaks > 0
                ? "It's been $daysAway days. $brokenStreaks streak${brokenStreaks == 1 ? '' : 's'} reset while you were away — ready for a fresh start?"
                : "It's been $daysAway days since you checked in. Good to see you again.",
            style: dialogBodyStyle(dialogContext),
          ),
          actions: [
            ElevatedButton(
              style: ElevatedButton.styleFrom(backgroundColor: kAccent, foregroundColor: Colors.white),
              onPressed: () => Navigator.pop(dialogContext),
              child: const Text("Let's go"),
            ),
          ],
        ),
      );
    });
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
    h.dispose();
    _saveHabits();
  }

  Future<void> _resetHabit(Habit h) async {
    final confirmed = await ResetConfirmation.confirm(
      context,
      subtitle: h.streak > 0
          ? 'You\'re ${h.streak} day${h.streak == 1 ? "" : "s"} into resisting "${h.name}". '
              'Resetting clears that streak.'
          : 'You haven\'t started a streak with "${h.name}" yet.',
      sureBody: h.streak > 0
          ? 'You\'ve fought off "${h.name}" for ${h.streak} day${h.streak == 1 ? "" : "s"} '
              'straight. That took real willpower — don\'t let one moment erase it. '
              'Reset anyway?'
          : 'There\'s no streak on "${h.name}" yet, so there\'s nothing to reset.',
      hasProgress: h.streak > 0,
    );
    if (!confirmed) return;

    HapticFeedback.mediumImpact();
    // Habit.reset() calls notifyListeners() itself — only the AnimatedBuilder
    // wrapping this one card rebuilds, so no setState() here.
    h.reset();
    _playResetImpact();
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
    // No setState() — h.nope() notifies only this habit's own listeners,
    // so the other cards in the list never rebuild.
    final incremented = h.nope(now, _adaptiveMessage);
    if (incremented) {
      HapticFeedback.heavyImpact();
      _confettiController.play();
    } else {
      HapticFeedback.lightImpact();
    }
    _saveHabits();
  }

  void _changeColor(Habit h, Color newColor) {
    h.setColor(newColor);
    _saveHabits();
  }

  void _changeIcon(Habit h, IconData newIcon) {
    h.setIcon(newIcon);
    _saveHabits();
  }

  int _habitsAtRiskCount() {
    final now = DateTime.now();
    return habits.where((h) => !h.tappedToday(now)).length;
  }

  // Evening (>=6pm) + at least one habit not yet tapped today. Purely an
  // in-app nudge -- no permissions needed, and it only helps if they've
  // actually opened the app, which is what makes it a safe complement to
  // the (mobile-only) push notification and the welcome-back dialog.
  bool _showRiskBanner() {
    if (habits.isEmpty) return false;
    if (DateTime.now().hour < 18) return false;
    return _habitsAtRiskCount() > 0;
  }

  @override
  Widget build(BuildContext context) {
    final colors = AppColors.of(context);
    return Scaffold(
      backgroundColor: colors.bg,
      appBar: AppBar(
        backgroundColor: colors.bg,
        elevation: 0,
        titleSpacing: 24,
        title: Text(
          "nope.",
          style: TextStyle(
            fontSize: 28,
            fontWeight: FontWeight.w900,
            color: colors.ink,
            letterSpacing: -1.5,
          ),
        ),
        actions: [
          // Light/dark mode switch.
          ValueListenableBuilder<ThemeMode>(
            valueListenable: themeModeNotifier,
            builder: (context, mode, _) => IconButton(
              tooltip: mode == ThemeMode.dark ? "Switch to light mode" : "Switch to dark mode",
              icon: Icon(
                mode == ThemeMode.dark ? Icons.light_mode_rounded : Icons.dark_mode_rounded,
                color: colors.ink.withValues(alpha: 0.54),
              ),
              onPressed: () {
                HapticFeedback.selectionClick();
                toggleThemeMode();
              },
            ),
          ),
          if (habits.isNotEmpty)
            IconButton(
              tooltip: "Calendar view",
              icon: Icon(Icons.calendar_month_outlined, color: colors.ink.withValues(alpha: 0.54)),
              onPressed: () => Navigator.push(
                context,
                MaterialPageRoute(builder: (_) => CalendarView(habits: habits)),
              ),
            ),
          if (habits.isNotEmpty)
            IconButton(
              tooltip: "Reset all streaks",
              icon: Icon(Icons.restart_alt, color: colors.ink.withValues(alpha: 0.54)),
              onPressed: () async {
                final confirmed = await ResetConfirmation.confirm(
                  context,
                  subtitle: "This clears every habit's streak back to zero, not just one.",
                  sureBody: "Every one of these streaks is a day you chose yourself over "
                      "the urge. Resetting wipes all of that away at once. Are you sure?",
                  hasProgress: habits.any((h) => h.streak > 0),
                );
                if (!confirmed) return;

                HapticFeedback.heavyImpact();
                for (final h in habits) {
                  h.reset(); // notifies only that habit's own card
                }
                _playResetImpact(magnitude: 1.8);
                _saveHabits();
              },
            ),
          IconButton(
            tooltip: "Add habit",
            icon: Icon(Icons.add_rounded, color: colors.ink),
            onPressed: _addHabit,
          ),
          const SizedBox(width: 8),
        ],
      ),
      body: Stack(
        children: [
          // Wrapping just the list/empty-state content (not the AppBar) in
          // a decaying horizontal wiggle -- driven by _shakeController and
          // scaled by _shakeMagnitude -- for the reset "damage" effect.
          AnimatedBuilder(
            animation: _shakeController,
            builder: (context, child) {
              final t = _shakeController.value;
              final decay = 1 - t;
              final wiggle = math.sin(t * 14) * 10 * decay * _shakeMagnitude;
              return Transform.translate(offset: Offset(wiggle, 0), child: child);
            },
            child: habits.isEmpty
                ? const _EmptyState()
                : Column(
              children: [
                if (_showRiskBanner())
                  _RiskBanner(count: _habitsAtRiskCount()),
                Expanded(
                  child: ListView.builder(
              padding: const EdgeInsets.only(top: 8, bottom: 24, left: 16, right: 16),
              itemCount: habits.length,
              itemBuilder: (context, i) {
                final h = habits[i];
                return Dismissible(
                  key: ValueKey(h.id),
                  background: Container(
                    margin: const EdgeInsets.symmetric(vertical: 6),
                    decoration: BoxDecoration(
                      color: Colors.redAccent.withValues(alpha: 0.15),
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
                      builder: (dialogContext) => AlertDialog(
                        backgroundColor: AppColors.of(dialogContext).dialogBg,
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
                        title: Text("Delete habit?", style: dialogTitleStyle(dialogContext)),
                        content: Text(
                          'Remove "${h.name}" and its history?',
                          style: dialogBodyStyle(dialogContext),
                        ),
                        actions: [
                          TextButton(onPressed: () => Navigator.pop(dialogContext, false), child: const Text("Cancel")),
                          ElevatedButton(
                            style: ElevatedButton.styleFrom(backgroundColor: Colors.redAccent, foregroundColor: Colors.white),
                            onPressed: () => Navigator.pop(dialogContext, true),
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
                    onIconChanged: (i) => _changeIcon(h, i),
                  ),
                );
              },
                  ),
                ),
              ],
            ),
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
                  numberOfParticles: 18,
                  gravity: 0.35,
                  colors: [
                    colors.ink,
                    kAccent,
                    const Color(0xFFD7546C),
                    const Color(0xFF547B66),
                    const Color(0xFFB6A02B),
                  ],
                ),
              ),
            ),
          ),
          // Red "damage" vignette that flashes in and fades out on reset --
          // scales with _shakeMagnitude so resetting everything hits harder
          // than resetting one habit.
          Positioned.fill(
            child: IgnorePointer(
              child: AnimatedBuilder(
                animation: _flashAnimation,
                builder: (context, _) {
                  final peak = (0.35 * _shakeMagnitude).clamp(0.0, 0.75);
                  final opacity = _flashAnimation.value * peak;
                  if (opacity <= 0) return const SizedBox.shrink();
                  return DecoratedBox(
                    decoration: BoxDecoration(
                      gradient: RadialGradient(
                        radius: 1.1,
                        colors: [
                          Colors.red.withValues(alpha: 0),
                          Colors.red.withValues(alpha: opacity),
                        ],
                        stops: const [0.55, 1.0],
                      ),
                    ),
                  );
                },
              ),
            ),
          ),
        ],
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// EVENING RISK BANNER -- shown above the habit list when it's getting late
// and at least one habit hasn't been tapped yet today.
// ─────────────────────────────────────────────────────────────────────────────
class _RiskBanner extends StatelessWidget {
  final int count;
  const _RiskBanner({required this.count});

  @override
  Widget build(BuildContext context) {
    final colors = AppColors.of(context);
    return Container(
      margin: const EdgeInsets.fromLTRB(16, 8, 16, 0),
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      decoration: BoxDecoration(
        color: kAccent.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: kAccent.withValues(alpha: 0.3)),
      ),
      child: Row(
        children: [
          Icon(Icons.nightlight_round, size: 18, color: kAccent),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              count == 1
                  ? "1 habit still needs a NOPE today."
                  : "$count habits still need a NOPE today.",
              style: TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w600,
                color: colors.ink.withValues(alpha: 0.85),
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
  final streakCtrl = TextEditingController(text: "0");
  Color selectedColor = presetColors["Blue"]!;
  IconData selectedIcon = presetIcons.first;
  int streak = 0;

  @override
  void dispose() {
    nameCtrl.dispose();
    streakCtrl.dispose();
    super.dispose();
  }

  void _setStreak(int value) {
    final clamped = value < 0 ? 0 : value;
    setState(() => streak = clamped);
    streakCtrl.text = clamped.toString();
    streakCtrl.selection = TextSelection.collapsed(offset: streakCtrl.text.length);
  }

  void _submit() {
    final name = nameCtrl.text.trim();
    if (name.isEmpty) return;
    HapticFeedback.mediumImpact();
    Navigator.pop(
      context,
      Habit(
        id: DateTime.now().millisecondsSinceEpoch.toString(),
        name: name,
        streak: streak,
        longestStreak: streak,
        colorValue: selectedColor.value,
        iconCodePoint: selectedIcon.codePoint,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final colors = AppColors.of(context);
    return Container(
      decoration: BoxDecoration(
        color: colors.card,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(32)),
        border: Border.all(color: colors.ink.withValues(alpha: 0.06)),
      ),
      padding: EdgeInsets.fromLTRB(
        22, 14, 22, MediaQuery.of(context).viewInsets.bottom + 28,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Handle + close
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Container(
                width: 36,
                height: 4,
                decoration: BoxDecoration(
                  color: colors.ink.withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ],
          ),
          const SizedBox(height: 22),

          // Live preview row
          AnimatedContainer(
            duration: const Duration(milliseconds: 250),
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              gradient: LinearGradient(
                colors: [
                  selectedColor.withValues(alpha: 0.18),
                  selectedColor.withValues(alpha: 0.04),
                ],
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
              ),
              borderRadius: BorderRadius.circular(20),
              border: Border.all(color: selectedColor.withValues(alpha: 0.25)),
            ),
            child: Row(
              children: [
                Icon(selectedIcon, color: selectedColor, size: 44),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        nameCtrl.text.trim().isEmpty ? "New habit" : nameCtrl.text.trim(),
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontSize: 19,
                          fontWeight: FontWeight.w800,
                          letterSpacing: -0.5,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        "Starting streak: $streak day${streak == 1 ? '' : 's'}",
                        style: TextStyle(fontSize: 12.5, color: colors.ink.withValues(alpha: 0.54), fontWeight: FontWeight.w500),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),

          const SizedBox(height: 24),
          Text(
            "NAME",
            style: TextStyle(fontSize: 11.5, color: colors.ink.withValues(alpha: 0.38), fontWeight: FontWeight.w700, letterSpacing: 0.8),
          ),
          const SizedBox(height: 8),
          _StyledTextField(
            controller: nameCtrl,
            hint: "e.g. smoking, junk food, social media, etc.",
            icon: Icons.edit_rounded,
            onChanged: () => setState(() {}),
          ),

          const SizedBox(height: 22),
          Text(
            "STARTING STREAK",
            style: TextStyle(fontSize: 11.5, color: colors.ink.withValues(alpha: 0.38), fontWeight: FontWeight.w700, letterSpacing: 0.8),
          ),
          const SizedBox(height: 8),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 6),
            decoration: BoxDecoration(
              color: colors.ink.withValues(alpha: 0.05),
              borderRadius: BorderRadius.circular(14),
              border: Border.all(color: colors.ink.withValues(alpha: 0.12)),
            ),
            child: Row(
              children: [
                _StepperButton(
                  icon: Icons.remove_rounded,
                  onTap: streak > 0 ? () => _setStreak(streak - 1) : null,
                ),
                Expanded(
                  child: Center(
                    child: TextField(
                      controller: streakCtrl,
                      textAlign: TextAlign.center,
                      keyboardType: TextInputType.number,
                      inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                      style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w800, letterSpacing: -0.5),
                      decoration: const InputDecoration(
                        border: InputBorder.none,
                        isDense: true,
                        contentPadding: EdgeInsets.zero,
                      ),
                      onChanged: (val) => setState(() => streak = int.tryParse(val) ?? 0),
                    ),
                  ),
                ),
                _StepperButton(
                  icon: Icons.add_rounded,
                  onTap: () => _setStreak(streak + 1),
                ),
              ],
            ),
          ),

          const SizedBox(height: 22),
          Text(
            "COLOR",
            style: TextStyle(fontSize: 11.5, color: colors.ink.withValues(alpha: 0.38), fontWeight: FontWeight.w700, letterSpacing: 0.8),
          ),
          const SizedBox(height: 10),
          Row(
            children: [
              ...presetColors.entries.map((entry) {
                final isSelected = entry.value == selectedColor;
                return Expanded(
                  child: GestureDetector(
                    onTap: () {
                      HapticFeedback.selectionClick();
                      setState(() => selectedColor = entry.value);
                    },
                    child: Padding(
                      padding: const EdgeInsets.only(right: 8),
                      child: AnimatedContainer(
                        duration: const Duration(milliseconds: 200),
                        curve: Curves.easeOut,
                        height: 52,
                        decoration: BoxDecoration(
                          color: entry.value.withValues(alpha: isSelected ? 0.22 : 0.08),
                          borderRadius: BorderRadius.circular(14),
                          border: Border.all(
                            color: isSelected ? entry.value : Colors.transparent,
                            width: 2,
                          ),
                        ),
                        child: Center(
                          child: AnimatedScale(
                            duration: const Duration(milliseconds: 200),
                            scale: isSelected ? 1.0 : 0.85,
                            child: Container(
                              width: 18,
                              height: 18,
                              decoration: BoxDecoration(
                                color: entry.value,
                                shape: BoxShape.circle,
                                boxShadow: isSelected
                                    ? [BoxShadow(color: entry.value.withValues(alpha: 0.6), blurRadius: 8)]
                                    : [],
                              ),
                              child: isSelected
                                  ? const Icon(Icons.check, color: Colors.white, size: 12)
                                  : null,
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                );
              }),
              _customColorCardSwatch(
                current: selectedColor,
                isCustom: !_isPresetColor(selectedColor),
                ink: colors.ink,
                onTap: () async {
                  final picked = await _pickCustomColor(context, selectedColor);
                  if (picked != null) {
                    HapticFeedback.selectionClick();
                    setState(() => selectedColor = picked);
                  }
                },
              ),
            ],
          ),

          const SizedBox(height: 22),
          Text(
            "ICON",
            style: TextStyle(fontSize: 11.5, color: colors.ink.withValues(alpha: 0.38), fontWeight: FontWeight.w700, letterSpacing: 0.8),
          ),
          const SizedBox(height: 10),
          Wrap(
            spacing: 10,
            runSpacing: 10,
            children: presetIcons.map((icon) {
              final isSelected = icon.codePoint == selectedIcon.codePoint;
              return GestureDetector(
                onTap: () {
                  HapticFeedback.selectionClick();
                  setState(() => selectedIcon = icon);
                },
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 200),
                  curve: Curves.easeOut,
                  width: 44,
                  height: 44,
                  decoration: BoxDecoration(
                    color: isSelected ? selectedColor : colors.ink.withValues(alpha: 0.06),
                    shape: BoxShape.circle,
                    border: Border.all(
                      color: isSelected ? Colors.white : Colors.transparent,
                      width: 2,
                    ),
                    boxShadow: isSelected
                        ? [BoxShadow(color: selectedColor.withValues(alpha: 0.45), blurRadius: 10)]
                        : [],
                  ),
                  child: Icon(icon, size: 20, color: isSelected ? Colors.white : colors.ink.withValues(alpha: 0.54)),
                ),
              );
            }).toList(),
          ),

          const SizedBox(height: 28),
          Row(
            children: [
              Expanded(
                child: _PressableButton(
                  onTap: () => Navigator.pop(context),
                  child: Container(
                    padding: const EdgeInsets.symmetric(vertical: 17),
                    decoration: BoxDecoration(
                      color: colors.ink.withValues(alpha: 0.06),
                      borderRadius: BorderRadius.circular(16),
                    ),
                    child: Center(
                      child: Text(
                        "Cancel",
                        style: TextStyle(color: colors.ink.withValues(alpha: 0.6), fontSize: 15, fontWeight: FontWeight.w700),
                      ),
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                flex: 2,
                child: _PressableButton(
                  onTap: _submit,
                  child: Container(
                    padding: const EdgeInsets.symmetric(vertical: 17),
                    decoration: BoxDecoration(
                      gradient: LinearGradient(
                        colors: [selectedColor, selectedColor.withValues(alpha: 0.7)],
                        begin: Alignment.centerLeft,
                        end: Alignment.centerRight,
                      ),
                      borderRadius: BorderRadius.circular(16),
                      boxShadow: [
                        BoxShadow(color: selectedColor.withValues(alpha: 0.35), blurRadius: 16, offset: const Offset(0, 6)),
                      ],
                    ),
                    child: const Center(
                      child: Text(
                        "Add Habit",
                        style: TextStyle(
                          color: Colors.white,
                          fontSize: 15.5,
                          fontWeight: FontWeight.w800,
                          letterSpacing: -0.2,
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _StepperButton extends StatelessWidget {
  final IconData icon;
  final VoidCallback? onTap;
  const _StepperButton({required this.icon, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final enabled = onTap != null;
    final colors = AppColors.of(context);
    return GestureDetector(
      onTap: onTap,
      child: Container(
        width: 44,
        height: 44,
        decoration: BoxDecoration(
          color: colors.ink.withValues(alpha: enabled ? 0.08 : 0.02),
          borderRadius: BorderRadius.circular(10),
        ),
        child: Icon(icon, size: 18, color: enabled ? colors.ink : colors.ink.withValues(alpha: 0.24)),
      ),
    );
  }
}

class _StyledTextField extends StatelessWidget {
  final TextEditingController controller;
  final String? label;
  final String hint;
  final TextInputType keyboardType;
  final IconData? icon;
  final VoidCallback? onChanged;

  const _StyledTextField({
    required this.controller,
    this.label,
    required this.hint,
    this.keyboardType = TextInputType.text,
    this.icon,
    this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    final colors = AppColors.of(context);
    return TextField(
      controller: controller,
      keyboardType: keyboardType,
      onChanged: onChanged == null ? null : (_) => onChanged!(),
      style: TextStyle(color: colors.ink, fontSize: 16, fontWeight: FontWeight.w600),
      decoration: InputDecoration(
        labelText: label,
        hintText: hint,
        prefixIcon: icon == null ? null : Icon(icon, size: 19, color: colors.ink.withValues(alpha: 0.38)),
        labelStyle: TextStyle(color: colors.ink.withValues(alpha: 0.38)),
        hintStyle: TextStyle(color: colors.ink.withValues(alpha: 0.24), fontWeight: FontWeight.w500),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(14),
          borderSide: BorderSide(color: colors.ink.withValues(alpha: 0.12)),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(14),
          borderSide: const BorderSide(color: kAccent),
        ),
        contentPadding: const EdgeInsets.symmetric(vertical: 16, horizontal: 16),
        filled: true,
        fillColor: colors.ink.withValues(alpha: 0.05),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// HABIT CARD
// ─────────────────────────────────────────────────────────────────────────────
class _HabitCard extends StatefulWidget {
  final Habit habit;
  final List<String> toneOptions;
  final VoidCallback onNope;
  final VoidCallback onReset;
  final ValueChanged<String>? onToneChanged;
  final ValueChanged<Color> onColorChanged;
  final ValueChanged<IconData> onIconChanged;

  const _HabitCard({
    required this.habit,
    required this.toneOptions,
    required this.onNope,
    required this.onReset,
    required this.onColorChanged,
    required this.onIconChanged,
    this.onToneChanged,
  });

  @override
  State<_HabitCard> createState() => _HabitCardState();
}

class _HabitCardState extends State<_HabitCard> {
  // Tracks the streak value from the previous rebuild so a reset (streak
  // suddenly dropping) can be told apart from a normal +1 NOPE tap -- only
  // the former gets the quick scroll-down-to-0 animation.
  int? _lastKnownStreak;

  Habit get habit => widget.habit;
  VoidCallback get onNope => widget.onNope;
  VoidCallback get onReset => widget.onReset;
  List<String> get toneOptions => widget.toneOptions;
  ValueChanged<String>? get onToneChanged => widget.onToneChanged;
  ValueChanged<Color> get onColorChanged => widget.onColorChanged;
  ValueChanged<IconData> get onIconChanged => widget.onIconChanged;

  @override
  Widget build(BuildContext context) {
    // RepaintBoundary keeps this card's paints isolated from its siblings.
    // AnimatedBuilder subscribes directly to `habit` (a ChangeNotifier), so
    // this is the *only* widget that rebuilds when this habit changes —
    // tapping NOPE on one card no longer touches the other cards at all.
    return RepaintBoundary(
      child: AnimatedBuilder(
        animation: habit,
        builder: (context, _) => _buildCard(context),
      ),
    );
  }

  Widget _buildCard(BuildContext context) {
    final colors = AppColors.of(context);
    final habitColor = Color(habit.colorValue);
    final tappedToday = habit.tappedToday(DateTime.now());

    final currentStreak = habit.streak;
    final previousStreak = _lastKnownStreak ?? currentStreak;
    final justReset = currentStreak < previousStreak;
    _lastKnownStreak = currentStreak;

    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      decoration: BoxDecoration(
        // Translucent card panel (same treatment as every other card/popup
        // in the app) with the habit's own color tinted on top -- without
        // this base fill the card was just a faint color wash with nothing
        // solid behind it, so the transparency change was invisible here.
        color: colors.card,
        gradient: LinearGradient(
          colors: [
            habitColor.withValues(alpha: 0.24),
            habitColor.withValues(alpha: 0.06),
          ],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
        borderRadius: BorderRadius.circular(20),
      ),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 18, 16, 18),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Header row -- icon + name centered as a block; reset button
            // pinned to the right, balanced by an equal-width spacer on the
            // left so the centered block is actually centered, not just
            // centered-minus-button-width.
            Row(
              children: [
                const SizedBox(width: 36),
                Expanded(
                  child: GestureDetector(
                    onTap: () => _showCustomizeSheet(context),
                    child: Column(
                      children: [
                        Icon(
                          habitIconForCodePoint(habit.iconCodePoint),
                          size: 84,
                          color: habitColor,
                        ),
                        const SizedBox(height: 8),
                        Text(
                          habit.name,
                          textAlign: TextAlign.center,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            fontSize: 15,
                            fontWeight: FontWeight.w800,
                            letterSpacing: -0.3,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
                IconButton(
                  tooltip: "Reset streak",
                  padding: EdgeInsets.zero,
                  constraints: const BoxConstraints(minWidth: 36, minHeight: 36),
                  onPressed: onReset,
                  icon: Icon(Icons.refresh, size: 20, color: colors.ink.withValues(alpha: 0.38)),
                ),
              ],
            ),

            const SizedBox(height: 4),

            // Streak info
            Row(
              children: [
                justReset
                    ? TweenAnimationBuilder<int>(
                        tween: IntTween(begin: previousStreak, end: currentStreak),
                        duration: const Duration(milliseconds: 1100),
                        curve: Curves.easeOut,
                        builder: (context, value, _) => _StatChip(
                          label: "streak",
                          value: "${value}d",
                          color: habitColor,
                          highlight: true,
                        ),
                      )
                    : _StatChip(
                        label: "streak",
                        value: "${currentStreak}d",
                        color: habitColor,
                        highlight: true,
                      ),
                const SizedBox(width: 8),
                _StatChip(
                  label: "best",
                  value: "${habit.longestStreak}d",
                  color: colors.ink.withValues(alpha: 0.24),
                ),
                if (habit.lastTap != null) ...[
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      "last: ${_formatDate(habit.lastTap!)}",
                      style: TextStyle(fontSize: 11, color: colors.ink.withValues(alpha: 0.3)),
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
                    color: tappedToday ? habitColor.withValues(alpha: 0.8) : colors.ink.withValues(alpha: 0.54),
                    fontSize: 14,
                    fontStyle: FontStyle.italic,
                  ),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  void _showCustomizeSheet(BuildContext context) async {
    Color tempColor = Color(habit.colorValue);
    IconData tempIcon = habitIconForCodePoint(habit.iconCodePoint);

    final result = await showDialog<(Color, IconData)>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (context, setDialogState) {
          final colors = AppColors.of(context);
          return AlertDialog(
          backgroundColor: colors.dialogBg,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
          title: Text("Customize habit", style: dialogTitleStyle(context)),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Wrap(
                  alignment: WrapAlignment.center,
                  spacing: 10,
                  runSpacing: 10,
                  children: [
                    ...presetColors.entries.map((entry) {
                      final isSelected = entry.value == tempColor;
                      return GestureDetector(
                        onTap: () => setDialogState(() => tempColor = entry.value),
                        child: Container(
                          width: 42,
                          height: 42,
                          decoration: BoxDecoration(
                            color: entry.value,
                            shape: BoxShape.circle,
                            border: Border.all(
                              color: isSelected ? Colors.white : Colors.transparent,
                              width: 3,
                            ),
                          ),
                        ),
                      );
                    }),
                    _customColorCircleSwatch(
                      current: tempColor,
                      isCustom: !_isPresetColor(tempColor),
                      onTap: () async {
                        final picked = await _pickCustomColor(context, tempColor);
                        if (picked != null) setDialogState(() => tempColor = picked);
                      },
                    ),
                  ],
                ),
                const SizedBox(height: 20),
                Wrap(
                  alignment: WrapAlignment.center,
                  spacing: 8,
                  runSpacing: 8,
                  children: presetIcons.map((icon) {
                    final isSelected = icon.codePoint == tempIcon.codePoint;
                    return GestureDetector(
                      onTap: () => setDialogState(() => tempIcon = icon),
                      child: Container(
                        width: 40,
                        height: 40,
                        decoration: BoxDecoration(
                          color: isSelected ? tempColor : colors.ink.withValues(alpha: 0.06),
                          shape: BoxShape.circle,
                          border: Border.all(
                            color: isSelected ? Colors.white : Colors.transparent,
                            width: 2,
                          ),
                        ),
                        child: Icon(icon, size: 18, color: isSelected ? Colors.white : colors.ink.withValues(alpha: 0.7)),
                      ),
                    );
                  }).toList(),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text("Cancel"),
            ),
            ElevatedButton(
              style: ElevatedButton.styleFrom(backgroundColor: tempColor, foregroundColor: Colors.white),
              onPressed: () => Navigator.pop(context, (tempColor, tempIcon)),
              child: const Text("Done"),
            ),
          ],
          );
        },
      ),
    );

    if (result != null) {
      onColorChanged(result.$1);
      onIconChanged(result.$2);
    }
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
    final colors = AppColors.of(context);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      decoration: BoxDecoration(
        color: highlight ? color.withValues(alpha: 0.12) : colors.ink.withValues(alpha: 0.05),
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
              color: highlight ? color : colors.ink.withValues(alpha: 0.54),
              letterSpacing: -0.5,
            ),
          ),
          const SizedBox(width: 3),
          Text(
            label,
            style: TextStyle(
              fontSize: 11,
              color: highlight ? color.withValues(alpha: 0.7) : colors.ink.withValues(alpha: 0.3),
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

class _NopeButtonState extends State<_NopeButton> {
  bool _pressed = false;

  @override
  Widget build(BuildContext context) {
    final colors = AppColors.of(context);
    final color = widget.tappedToday ? widget.color : colors.ink;
    final bg = widget.tappedToday
        ? widget.color.withValues(alpha: 0.12)
        : colors.raised;

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
              color: widget.tappedToday ? widget.color : colors.ink.withValues(alpha: 0.12),
              width: widget.tappedToday ? 2 : 1,
            ),
            boxShadow: widget.tappedToday
                ? [BoxShadow(color: widget.color.withValues(alpha: 0.25), blurRadius: 20, spreadRadius: 4)]
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

  // Precomputed once (not on every markerBuilder call) so opening/paging the
  // calendar doesn't re-parse every urgeLog entry for every visible day cell.
  // Carries the exact timestamp (not just the habit) so the day list can
  // show when each urge was resisted -- that detail now only lives here,
  // not on the habit card itself.
  late final Map<DateTime, List<MapEntry<Habit, DateTime>>> _habitsByDay = _buildIndex();

  Map<DateTime, List<MapEntry<Habit, DateTime>>> _buildIndex() {
    final index = <DateTime, List<MapEntry<Habit, DateTime>>>{};
    for (final h in widget.habits) {
      for (final iso in h.urgeLog) {
        final dt = DateTime.parse(iso);
        final key = DateTime(dt.year, dt.month, dt.day);
        (index[key] ??= []).add(MapEntry(h, dt));
      }
    }
    return index;
  }

  List<MapEntry<Habit, DateTime>> habitsOnDay(DateTime day) {
    return _habitsByDay[DateTime(day.year, day.month, day.day)] ?? const [];
  }

  static String _formatTime(DateTime dt) {
    final hour24 = dt.hour;
    final period = hour24 >= 12 ? "PM" : "AM";
    final hour12 = hour24 % 12 == 0 ? 12 : hour24 % 12;
    final minute = dt.minute.toString().padLeft(2, "0");
    return "$hour12:$minute $period";
  }

  @override
  Widget build(BuildContext context) {
    final colors = AppColors.of(context);
    return Scaffold(
      backgroundColor: colors.bg,
      appBar: AppBar(
        backgroundColor: colors.bg,
        elevation: 0,
        title: const Text(
          "Calendar",
          style: TextStyle(fontWeight: FontWeight.w800, letterSpacing: -0.5),
        ),
      ),
      body: SingleChildScrollView(
        child: Column(
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
            calendarStyle: CalendarStyle(
              defaultTextStyle: TextStyle(color: colors.ink.withValues(alpha: 0.7)),
              weekendTextStyle: TextStyle(color: colors.ink.withValues(alpha: 0.54)),
              outsideTextStyle: TextStyle(color: colors.ink.withValues(alpha: 0.24)),
              todayDecoration: BoxDecoration(
                color: kAccent.withValues(alpha: 0.35),
                shape: BoxShape.circle,
              ),
              selectedDecoration: const BoxDecoration(
                color: kAccent,
                shape: BoxShape.circle,
              ),
              selectedTextStyle: const TextStyle(color: Colors.white, fontWeight: FontWeight.w800),
              todayTextStyle: TextStyle(color: colors.ink, fontWeight: FontWeight.w600),
            ),
            headerStyle: HeaderStyle(
              formatButtonVisible: false,
              titleCentered: true,
              titleTextStyle: const TextStyle(
                fontWeight: FontWeight.w800,
                fontSize: 16,
                letterSpacing: -0.5,
              ),
              leftChevronIcon: Icon(Icons.chevron_left, color: colors.ink.withValues(alpha: 0.54)),
              rightChevronIcon: Icon(Icons.chevron_right, color: colors.ink.withValues(alpha: 0.54)),
            ),
            daysOfWeekStyle: DaysOfWeekStyle(
              weekdayStyle: TextStyle(color: colors.ink.withValues(alpha: 0.38), fontSize: 12),
              weekendStyle: TextStyle(color: colors.ink.withValues(alpha: 0.24), fontSize: 12),
            ),
            calendarBuilders: CalendarBuilders(
              markerBuilder: (context, day, _) {
                final entries = habitsOnDay(day);
                if (entries.isEmpty) return null;
                // Stretch across the full cell so LayoutBuilder below gets a
                // real bounded width to fit dots into, instead of an
                // unconstrained row that just keeps growing past the cell.
                return Positioned(
                  bottom: 4,
                  left: 0,
                  right: 0,
                  child: LayoutBuilder(
                    builder: (context, constraints) {
                      const dotFootprint = 7.0; // 5px dot + 1px margin each side
                      final maxDots = (constraints.maxWidth / dotFootprint)
                          .floor()
                          .clamp(1, entries.length);
                      return Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        mainAxisSize: MainAxisSize.min,
                        children: entries.take(maxDots).map((entry) => Container(
                          width: 5,
                          height: 5,
                          margin: const EdgeInsets.symmetric(horizontal: 1),
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            color: Color(entry.key.colorValue),
                          ),
                        )).toList(),
                      );
                    },
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
                  Builder(builder: (context) {
                    final onDay = habitsOnDay(_selectedDay!);
                    final colors = AppColors.of(context);
                    return Column(
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
                        ...onDay.map((entry) => Padding(
                          padding: const EdgeInsets.only(bottom: 8),
                          child: Row(
                            children: [
                              Container(
                                width: 10,
                                height: 10,
                                margin: const EdgeInsets.only(right: 10),
                                decoration: BoxDecoration(
                                  shape: BoxShape.circle,
                                  color: Color(entry.key.colorValue),
                                ),
                              ),
                              Expanded(
                                child: Text(
                                  entry.key.name,
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(color: colors.ink.withValues(alpha: 0.7)),
                                ),
                              ),
                              Text(
                                _formatTime(entry.value),
                                style: TextStyle(fontSize: 12, color: colors.ink.withValues(alpha: 0.4)),
                              ),
                            ],
                          ),
                        )),
                        if (onDay.isEmpty)
                          Text("Nothing logged.", style: TextStyle(color: colors.ink.withValues(alpha: 0.38))),
                      ],
                    );
                  }),
                ],
              ),
            ),
        ],
        ),
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
    final colors = AppColors.of(context);
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 32),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Text(
              "nope.",
              style: TextStyle(
                fontSize: 56,
                fontWeight: FontWeight.w900,
                color: colors.ink.withValues(alpha: 0.12),
                letterSpacing: -3,
              ),
            ),
            const SizedBox(height: 16),
            Text(
              "No habits yet.",
              style: TextStyle(
                fontSize: 20,
                color: colors.ink.withValues(alpha: 0.38),
                fontWeight: FontWeight.w600,
                letterSpacing: -0.5,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              "Add a habit and hit NOPE\nonce a day to grow your streak.",
              textAlign: TextAlign.center,
              style: TextStyle(
                color: colors.ink.withValues(alpha: 0.24),
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