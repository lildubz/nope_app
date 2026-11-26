import 'dart:convert';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:crypto/crypto.dart';
import 'package:flutter/cupertino.dart' show CupertinoSwitch;
import 'package:device_preview/device_preview.dart';
import 'package:flutter/foundation.dart' show kIsWeb, kReleaseMode;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_timezone/flutter_timezone.dart';
import 'package:local_auth/local_auth.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:table_calendar/table_calendar.dart';
import 'package:timezone/data/latest_all.dart' as tz_data;
import 'package:timezone/timezone.dart' as tz;

import 'glass.dart';

void main() {
  // DevicePreview is a dev-only phone-frame simulator (device sizes, dark
  // mode, text scaling). With enabled: false it just calls builder, so
  // release builds pay nothing for it.
  runApp(
    DevicePreview(
      enabled: !kReleaseMode,
      // The app's own dark canvas instead of DevicePreview's default white,
      // so the liquid-glass UI is judged against the colour it ships on.
      backgroundColor: kGlassBaseDark,
      // Only applies the first time -- after that DevicePreview remembers
      // whatever device you last picked.
      defaultDevice: Devices.ios.iPhone16Pro,
      builder: (context) => const NopeApp(),
    ),
  );
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

// Red for reset/undo actions on done habits.
const Color kResetRed = Color(0xFFE5484D);

// App-wide typeface, bundled as an asset font (pubspec.yaml).
const String kAppFont = 'Inter';

// ─────────────────────────────────────────────────────────────────────────────
// TABLET SCALING — this app is otherwise a fixed phone-width layout, so on a
// tablet's much larger canvas every fixed-size element (icons, the NOPE
// circle, card padding) reads as tiny and sparse. Text already scales up on
// its own via the app-wide TextScaler set in NopeApp, so this helper is only
// for non-text, pixel-sized things that scaler can't touch.
bool isTablet(BuildContext context) => MediaQuery.of(context).size.shortestSide >= 600;

double tabletScale(BuildContext context) => isTablet(context) ? 1.65 : 1.0;

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
    bg: kGlassBaseDark,
    card: Color(0xE6111111),
    dialogBg: Color(0xCC141414),
    raised: Color(0xFF1A1A1A),
    ink: Colors.white,
  );

  static const light = AppColors(
    bg: kGlassBaseLight,
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
    // Bundled Inter everywhere (see pubspec.yaml). Every Text/TextField
    // inherits it through the text themes, so no TextStyle needs to name it.
    textTheme: base.textTheme.apply(fontFamily: kAppFont),
    primaryTextTheme: base.primaryTextTheme.apply(fontFamily: kAppFont),
    snackBarTheme: const SnackBarThemeData(behavior: SnackBarBehavior.floating),
    colorScheme: base.colorScheme.copyWith(primary: kAccent, secondary: kAccent, onSurface: colors.ink),
    // Liquid glass: bars are clear so the page's GlassBackdrop shows through,
    // and nothing tints/shadows them when content scrolls underneath.
    appBarTheme: AppBarTheme(
      backgroundColor: Colors.transparent,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      scrolledUnderElevation: 0,
      foregroundColor: colors.ink,
    ),
    // iOS-style push/pop (with swipe-back) on every platform, not just iOS.
    pageTransitionsTheme: PageTransitionsTheme(
      builders: {
        for (final platform in TargetPlatform.values) platform: const CupertinoPageTransitionsBuilder(),
      },
    ),
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
  return showGlassDialog<Color>(
    context: context,
    builder: (dialogContext) {
      int r = initial.red;
      int g = initial.green;
      int b = initial.blue;
      return StatefulBuilder(
        builder: (context, setDialogState) {
          final current = Color.fromARGB(255, r, g, b);
          return GlassDialog(
            title: "Custom color",
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
              GlassDialogAction(label: "Cancel", onTap: () => Navigator.pop(context)),
              GlassDialogAction(label: "Select", tint: current, onTap: () => Navigator.pop(context, current)),
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

/// A liquid-glass colour swatch tile for the add-habit sheet: glass tinted
/// with [tint] (clear glass when null), more strongly once [selected], with
/// a coloured outline marking the selection.
class _GlassSwatchTile extends StatelessWidget {
  final Color? tint;
  final bool selected;
  final VoidCallback onTap;
  final Widget child;
  final double height;

  const _GlassSwatchTile({
    required this.tint,
    required this.selected,
    required this.onTap,
    required this.child,
    required this.height,
  });

  @override
  Widget build(BuildContext context) {
    const radius = 14.0;
    return AnimatedContainer(
      duration: const Duration(milliseconds: 200),
      curve: Curves.easeOut,
      foregroundDecoration: ShapeDecoration(
        shape: RoundedSuperellipseBorder(
          borderRadius: BorderRadius.circular(radius),
          side: BorderSide(color: selected ? (tint ?? Colors.white) : Colors.transparent, width: 2),
        ),
      ),
      child: GlassButton(
        onTap: onTap,
        shape: glassRounded(radius),
        tint: tint,
        tintStrength: selected ? 0.38 : 0.14,
        // Sits on the sheet's own glass, which already blurred the page.
        blur: 0,
        shadows: glassControlShadow(context),
        pressedScale: 0.93,
        child: SizedBox(height: height, child: Center(child: child)),
      ),
    );
  }
}

// The "pick any colour" tile at the end of the add-habit sheet's colour row.
Widget _customColorCardSwatch({
  required Color current,
  required bool isCustom,
  required VoidCallback onTap,
  double scale = 1.0,
}) {
  return Expanded(
    child: _GlassSwatchTile(
      tint: isCustom ? current : null,
      selected: isCustom,
      onTap: onTap,
      height: 52 * scale,
      child: Container(
        width: 18 * scale,
        height: 18 * scale,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: isCustom ? current : null,
          gradient: isCustom ? null : _customSwatchGradient,
          boxShadow: isCustom ? [BoxShadow(color: current.withValues(alpha: 0.6), blurRadius: 8)] : [],
        ),
        child: Icon(isCustom ? Icons.check : Icons.colorize, color: Colors.white, size: 10 * scale),
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
      fontSize: 19 * tabletScale(context),
      fontWeight: FontWeight.w800,
      letterSpacing: -0.4,
      color: AppColors.of(context).ink,
    );

TextStyle dialogBodyStyle(BuildContext context) => TextStyle(
      fontSize: 14.5 * tabletScale(context),
      fontWeight: FontWeight.w500,
      height: 1.35,
      color: AppColors.of(context).ink.withValues(alpha: 0.75),
    );

// ─────────────────────────────────────────────────────────────────────────────
// GLASS CHROME — app-specific wrappers around glass.dart's primitives
// ─────────────────────────────────────────────────────────────────────────────

/// How strongly a habit's colour tints its glass. Shared by the habit card
/// and the add-habit sheet so the sheet reads as the card being made.
double habitGlassTint(BuildContext context) =>
    Theme.of(context).brightness == Brightness.dark ? 0.18 : 0.14;

/// The small drop shadow that lifts a glass control (swatch, stepper, field)
/// off the glass panel it sits on, so it reads as its own piece of glass.
List<BoxShadow> glassControlShadow(BuildContext context) => [
      BoxShadow(
        color: Colors.black.withValues(alpha: Theme.of(context).brightness == Brightness.dark ? 0.22 : 0.10),
        blurRadius: 10,
        offset: const Offset(0, 4),
      ),
    ];

/// Every popup in the app goes through this, so the dim behind a glass
/// dialog stays light enough for the blur to have colour to work with.
Future<T?> showGlassDialog<T>({required BuildContext context, required WidgetBuilder builder}) {
  return showDialog<T>(
    context: context,
    barrierColor: Colors.black.withValues(alpha: 0.28),
    builder: builder,
  );
}

/// A frosted-glass alert: bold title, scrollable body, and a row of
/// equal-width capsule buttons along the bottom (iOS 26 alert layout).
///
/// Built from a plain Dialog + Column rather than AlertDialog's
/// title/content/actions slots -- those slots go through an OverflowBar +
/// Flexible/ScrollView combo that renders the actions past the dialog's
/// background on this Flutter version once the dialog gets tall enough.
class GlassDialog extends StatelessWidget {
  final String title;
  final Widget content;
  final List<Widget> actions;

  const GlassDialog({required this.title, required this.content, required this.actions, super.key});

  @override
  Widget build(BuildContext context) {
    final scale = tabletScale(context);
    return Dialog(
      backgroundColor: Colors.transparent,
      surfaceTintColor: Colors.transparent,
      shadowColor: Colors.transparent,
      elevation: 0,
      insetPadding: EdgeInsets.symmetric(horizontal: 24 * scale, vertical: 24 * scale),
      child: ConstrainedBox(
        constraints: BoxConstraints(maxWidth: 400 * scale),
        child: Glass(
          shape: glassRounded(32),
          frost: 0.65,
          blur: 30,
          padding: EdgeInsets.fromLTRB(24 * scale, 24 * scale, 24 * scale, 20 * scale),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(title, style: dialogTitleStyle(context)),
              SizedBox(height: 12 * scale),
              Flexible(
                child: SingleChildScrollView(
                  child: DefaultTextStyle.merge(style: dialogBodyStyle(context), child: content),
                ),
              ),
              SizedBox(height: 22 * scale),
              Row(
                children: [
                  for (int i = 0; i < actions.length; i++) ...[
                    if (i > 0) SizedBox(width: 10 * scale),
                    Expanded(child: actions[i]),
                  ],
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// A capsule button for [GlassDialog]'s action row. Pass [tint] for the
/// primary (filled-glass) action; leave it null for a clear-glass one.
class GlassDialogAction extends StatelessWidget {
  final String label;
  final VoidCallback onTap;
  final Color? tint;

  const GlassDialogAction({required this.label, required this.onTap, this.tint, super.key});

  @override
  Widget build(BuildContext context) {
    final scale = tabletScale(context);
    final prominent = tint != null;
    return GlassButton(
      onTap: onTap,
      tint: tint,
      prominent: prominent,
      // Sits on the dialog's own glass, which has already blurred the page.
      blur: 0,
      shadows: prominent ? null : const [],
      padding: EdgeInsets.symmetric(horizontal: 12 * scale, vertical: 14 * scale),
      child: Text(
        label,
        textAlign: TextAlign.center,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(
          fontSize: 15 * scale,
          fontWeight: FontWeight.w700,
          color: prominent ? Colors.white : AppColors.of(context).ink,
        ),
      ),
    );
  }
}

/// Clear navigation bar with a glass-circle back button and a centred
/// title, the iOS 26 way. Used by every pushed screen.
PreferredSizeWidget glassAppBar(BuildContext context, {String? title}) {
  final colors = AppColors.of(context);
  final scale = tabletScale(context);
  final canPop = Navigator.of(context).canPop();
  return AppBar(
    automaticallyImplyLeading: false,
    toolbarHeight: (kToolbarHeight + 8) * scale,
    leadingWidth: 68 * scale,
    centerTitle: true,
    leading: canPop
        ? Padding(
            padding: EdgeInsets.only(left: 16 * scale),
            child: Center(
              child: GlassIconButton(
                icon: Icons.arrow_back_ios_new_rounded,
                tooltip: 'Back',
                size: 44 * scale,
                iconSize: 18 * scale,
                color: colors.ink,
                onTap: () => Navigator.of(context).maybePop(),
              ),
            ),
          )
        : null,
    title: title == null
        ? null
        : Text(
            title,
            style: TextStyle(color: colors.ink, fontWeight: FontWeight.w700, fontSize: 17 * scale, letterSpacing: -0.3),
          ),
  );
}

// ─────────────────────────────────────────────────────────────────────────────
// APP
// ─────────────────────────────────────────────────────────────────────────────
class NopeApp extends StatelessWidget {
  const NopeApp({super.key});

  @override
  Widget build(BuildContext context) {
    // The font (kAppFont) is bundled as an asset and set in buildAppTheme.
    // Only ever name a bundled family -- naming one that isn't bundled (as
    // 'Helvetica Neue' once was) forces a slow font-fallback lookup on every
    // Text widget's first layout.
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
          locale: DevicePreview.locale(context),
          // DevicePreview's MediaQuery (the simulated device's size and text
          // scale) goes on the outside, so the tablet scaler inside sees the
          // previewed device rather than the desktop window.
          builder: (context, child) => DevicePreview.appBuilder(
            context,
            _TabletTextScaler(child: child!),
          ),
        );
      },
    );
  }
}

/// Scales every Text widget app-wide on tablet-sized screens (see
/// tabletScale) -- multiplying the *existing* scaler rather than replacing
/// it so a user's own accessibility text-size setting still stacks on top
/// instead of being clobbered.
class _TabletTextScaler extends StatelessWidget {
  final Widget child;
  const _TabletTextScaler({required this.child});

  @override
  Widget build(BuildContext context) {
    final mq = MediaQuery.of(context);
    if (mq.size.shortestSide < 600) return child;
    final scaled = mq.textScaler.scale(1.0) * 1.6;
    return MediaQuery(
      data: mq.copyWith(textScaler: TextScaler.linear(scaled)),
      child: child,
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// LOADING SCREEN — shown while AppEntry checks whether the intro has been
// seen. Reuses the same "noo-no." wag-finger animation as the native splash
// so the two hand off to each other without a visual jump cut. The wordmark
// is staged in on top of it: finger waves alone, then "nope" slams in, then
// "." slams in beside it a beat later.
// ─────────────────────────────────────────────────────────────────────────────
class LoadingScreen extends StatefulWidget {
  const LoadingScreen({super.key});

  @override
  State<LoadingScreen> createState() => _LoadingScreenState();
}

// Desaturates the wag-finger gif to black-and-white so it reads as a plain
// graphic mark rather than competing in color with the rest of the screen.
const ColorFilter _greyscale = ColorFilter.matrix(<double>[
  0.2126, 0.7152, 0.0722, 0, 0,
  0.2126, 0.7152, 0.0722, 0, 0,
  0.2126, 0.7152, 0.0722, 0, 0,
  0, 0, 0, 1, 0,
]);

class _LoadingScreenState extends State<LoadingScreen>
    with TickerProviderStateMixin {
  late final AnimationController _handExitCtrl = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 400),
  );
  late final AnimationController _nopeCtrl = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 500),
  );
  late final AnimationController _dotCtrl = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 350),
  );

  late final Animation<double> _handExit = CurvedAnimation(
    parent: _handExitCtrl,
    curve: Curves.easeIn,
  );
  late final Animation<double> _nopeScale = Tween<double>(begin: 0.4, end: 1.0)
      .animate(CurvedAnimation(parent: _nopeCtrl, curve: Curves.easeOutBack));
  late final Animation<double> _nopeFade = CurvedAnimation(
    parent: _nopeCtrl,
    curve: const Interval(0.0, 0.6, curve: Curves.easeOut),
  );
  late final Animation<double> _dotScale = Tween<double>(begin: 0.4, end: 1.0)
      .animate(CurvedAnimation(parent: _dotCtrl, curve: Curves.easeOutBack));
  late final Animation<double> _dotFade = CurvedAnimation(
    parent: _dotCtrl,
    curve: const Interval(0.0, 0.6, curve: Curves.easeOut),
  );

  @override
  void initState() {
    super.initState();
    _runSequence();
  }

  Future<void> _runSequence() async {
    await Future.delayed(const Duration(milliseconds: 1500)); // finger plays alone
    if (!mounted) return;
    _handExitCtrl.forward(); // hand flies off to the left...
    await Future.delayed(const Duration(milliseconds: 150));
    if (!mounted) return;
    await _nopeCtrl.forward(); // ...as "nope" slams into its place
    await Future.delayed(const Duration(milliseconds: 250)); // short beat
    if (!mounted) return;
    await _dotCtrl.forward();
  }

  @override
  void dispose() {
    _handExitCtrl.dispose();
    _nopeCtrl.dispose();
    _dotCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final colors = AppColors.of(context);
    final wordmarkStyle = TextStyle(
      fontSize: 104,
      fontWeight: FontWeight.w800,
      color: colors.ink,
      letterSpacing: -3,
    );
    return Scaffold(
      backgroundColor: colors.bg,
      body: Center(
        child: Stack(
          alignment: Alignment.center,
          children: [
            AnimatedBuilder(
              animation: _handExit,
              builder: (context, child) => Opacity(
                opacity: 1 - _handExit.value,
                child: Transform.translate(
                  offset: Offset(-140 * _handExit.value, 0),
                  child: child,
                ),
              ),
              child: ColorFiltered(
                colorFilter: _greyscale,
                child: Image.asset(
                  'assets/loading/noo-no.gif',
                  width: 140,
                  height: 140,
                  filterQuality: FilterQuality.medium,
                  // Falls back to nothing if the asset isn't bundled (e.g.
                  // pubspec.yaml assets not registered / `flutter pub get`
                  // not run yet) instead of throwing and breaking the whole
                  // loading screen.
                  errorBuilder: (context, error, stackTrace) =>
                      const SizedBox(width: 140, height: 140),
                ),
              ),
            ),
            Row(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.baseline,
              textBaseline: TextBaseline.alphabetic,
              children: [
                // Invisible twin of the "." on the right, so the word
                // "nope" itself sits dead centre with the period hanging
                // off to its right.
                Visibility(
                  visible: false,
                  maintainSize: true,
                  maintainAnimation: true,
                  maintainState: true,
                  child: Text(".", style: wordmarkStyle),
                ),
                ScaleTransition(
                  scale: _nopeScale,
                  child: FadeTransition(
                    opacity: _nopeFade,
                    child: Text("nope", style: wordmarkStyle),
                  ),
                ),
                ScaleTransition(
                  scale: _dotScale,
                  child: FadeTransition(
                    opacity: _dotFade,
                    child: Text(".", style: wordmarkStyle),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
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

class _AppEntryState extends State<AppEntry> with WidgetsBindingObserver {
  bool? _showIntro;
  bool _locked = false;
  List<Habit> _habits = [];

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _check();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // Only re-lock once the initial load/intro flow is behind us -- there's
    // nothing worth protecting yet during loading or the one-time intro.
    if (state == AppLifecycleState.paused && _showIntro == false) {
      _reLockIfNeeded();
    }
  }

  Future<void> _reLockIfNeeded() async {
    final hasPasscode = await PasscodeStore.hasPasscode();
    if (hasPasscode && mounted) setState(() => _locked = true);
  }

  Future<void> _check() async {
    // SharedPreferences.getInstance() usually resolves in a couple of
    // milliseconds, which meant LoadingScreen was mounted and unmounted
    // within a single frame -- effectively invisible. Racing it against a
    // minimum-display timer guarantees the loading animation actually gets
    // seen, while still resolving immediately if the prefs lookup is ever
    // slower than this floor. Habits are decoded here too (not just
    // seen_intro) so NopeHome's first frame already has real data instead of
    // flashing empty state while it does its own prefs read.
    //
    // 3200ms gives LoadingScreen's own staged animation (finger alone ->
    // hand flies off -> "nope" slams into its place -> "." slams in,
    // landing at ~2750ms) room to fully play out plus a brief settled hold
    // before this screen gets swapped away -- see LoadingScreen._runSequence.
    final results = await Future.wait([
      _readInitialState(),
      Future.delayed(const Duration(milliseconds: 3200)),
    ]);
    final initial = results[0] as _InitialState;
    if (!mounted) return;
    setState(() {
      _showIntro = !initial.seenIntro;
      _habits = initial.habits;
      _locked = initial.hasPasscode;
    });
  }

  Future<_InitialState> _readInitialState() async {
    final prefs = await SharedPreferences.getInstance();
    final seenIntro = prefs.getBool('seen_intro') ?? false;
    final raw = prefs.getString('habits');
    var habits = <Habit>[];
    if (raw != null && raw.isNotEmpty) {
      final list = (jsonDecode(raw) as List).cast<Map<String, dynamic>>();
      habits = list.map(Habit.fromJson).toList();
      final now = DateTime.now();
      for (final h in habits) {
        h.refreshForToday(now);
      }
    }
    final hasPasscode = await PasscodeStore.hasPasscode();
    return _InitialState(seenIntro: seenIntro, habits: habits, hasPasscode: hasPasscode);
  }

  void _onIntroComplete() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('seen_intro', true);
    // setState (not a Navigator push) so this widget -- and the lifecycle
    // observer above that drives re-locking on resume -- stays mounted for
    // the rest of the app's life instead of being replaced away.
    if (mounted) setState(() => _showIntro = false);
  }

  @override
  Widget build(BuildContext context) {
    Widget child;
    Key key;
    if (_showIntro == null) {
      child = const LoadingScreen();
      key = const ValueKey('loading');
    } else if (_locked) {
      child = LockScreen(onUnlocked: () => setState(() => _locked = false));
      key = const ValueKey('lock');
    } else if (_showIntro!) {
      child = IntroScreen(onComplete: _onIntroComplete);
      key = const ValueKey('intro');
    } else {
      child = NopeHome(initialHabits: _habits);
      key = const ValueKey('home');
    }
    return AnimatedSwitcher(
      duration: const Duration(milliseconds: 300),
      child: KeyedSubtree(key: key, child: child),
    );
  }
}

class _InitialState {
  const _InitialState({required this.seenIntro, required this.habits, required this.hasPasscode});
  final bool seenIntro;
  final List<Habit> habits;
  final bool hasPasscode;
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
    return GlassBackdrop(
      child: Scaffold(
      backgroundColor: Colors.transparent,
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 32),
          // Fixed-size content (88px title, multi-line tagline, three feature
          // rows, a padded CTA) with fixed gaps -- rather than Spacers -- so
          // spacing stays comfortable and consistent instead of collapsing
          // to nothing on a short landscape phone. Center() absorbs any
          // extra room on taller screens; SingleChildScrollView is a
          // fallback for screens too short to fit even the fixed spacing.
          child: SingleChildScrollView(
            child: Center(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.center,
                mainAxisSize: MainAxisSize.min,
                children: [
                  const SizedBox(height: 32),
                  // Big title
                  FadeTransition(
                    opacity: _titleFade,
                    child: SlideTransition(
                      position: _titleSlide,
                      child: Text(
                        "nope.",
                        style: TextStyle(
                          fontSize: 88,
                          fontWeight: FontWeight.w800,
                          color: colors.ink,
                          letterSpacing: -2.6,
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
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        fontSize: 20,
                        color: colors.ink.withValues(alpha: 0.55),
                        fontWeight: FontWeight.w400,
                        height: 1.6,
                        letterSpacing: -0.3,
                      ),
                    ),
                  ),
                  const SizedBox(height: 40),
                  // Features
                  FadeTransition(
                    opacity: _subFade,
                    // Full width even though the column centres its children;
                    // the feature rows inside stay left-aligned.
                    child: SizedBox(
                      width: double.infinity,
                      child: Glass(
                        shape: glassRounded(26),
                        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 20),
                        child: const Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            _IntroFeature(icon: Icons.block, text: "Hit NOPE once a day per habit"),
                            SizedBox(height: 16),
                            _IntroFeature(icon: Icons.local_fire_department, text: "Build streaks. Don't break the chain."),
                            SizedBox(height: 16),
                            _IntroFeature(icon: Icons.calendar_month, text: "See your wins on a calendar"),
                          ],
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(height: 40),
                  // CTA -- filled accent glass capsule.
                  FadeTransition(
                    opacity: _btnFade,
                    child: SizedBox(
                      width: double.infinity,
                      child: GlassButton(
                        onTap: widget.onComplete,
                        tint: kAccent,
                        prominent: true,
                        padding: const EdgeInsets.symmetric(vertical: 20),
                        child: const Text(
                          "let's go →",
                          textAlign: TextAlign.center,
                          style: TextStyle(
                            color: Colors.white,
                            fontSize: 18,
                            fontWeight: FontWeight.w800,
                            letterSpacing: -0.3,
                          ),
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(height: 32),
                ],
              ),
            ),
          ),
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
        Icon(icon, color: colors.ink.withValues(alpha: 0.5), size: 20),
        const SizedBox(width: 12),
        Flexible(
          child: Text(
          text,
          style: TextStyle(
            color: colors.ink.withValues(alpha: 0.75),
            fontSize: 15,
            fontWeight: FontWeight.w500,
          ),
        ),
        ),
      ],
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// APP LOCK — 4-digit passcode + optional biometric unlock, gating access to
// the app past the loading screen. The passcode is stored as a SHA-256 hash
// (never plaintext) -- hashing here is mostly to avoid a raw prefs-file dump
// handing over the code directly; a 4-digit code only has 10,000
// combinations either way, so this isn't meant to resist real brute force.
// ─────────────────────────────────────────────────────────────────────────────
class PasscodeStore {
  PasscodeStore._();

  static const _hashKey = 'lock_passcode_hash';
  static const _biometricKey = 'lock_biometric_enabled';

  static String _hash(String code) => sha256.convert(utf8.encode(code)).toString();

  static Future<bool> hasPasscode() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString(_hashKey) != null;
  }

  static Future<void> setPasscode(String code) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_hashKey, _hash(code));
  }

  static Future<void> clearPasscode() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_hashKey);
    await prefs.remove(_biometricKey);
  }

  static Future<bool> verify(String code) async {
    final prefs = await SharedPreferences.getInstance();
    final stored = prefs.getString(_hashKey);
    return stored != null && stored == _hash(code);
  }

  static Future<bool> isBiometricEnabled() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool(_biometricKey) ?? false;
  }

  static Future<void> setBiometricEnabled(bool enabled) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_biometricKey, enabled);
  }
}

// Four dots showing how many digits have been typed so far. Filled dots turn
// red instead of accent-blue on a rejected attempt, matching the shake that
// plays alongside it.
class _PinDots extends StatelessWidget {
  final int length;
  final int filled;
  final bool error;
  const _PinDots({required this.length, required this.filled, this.error = false});

  @override
  Widget build(BuildContext context) {
    final colors = AppColors.of(context);
    final scale = tabletScale(context);
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: List.generate(length, (i) {
        final isFilled = i < filled;
        return Container(
          margin: EdgeInsets.symmetric(horizontal: 8 * scale),
          width: 16 * scale,
          height: 16 * scale,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: isFilled ? (error ? Colors.redAccent : kAccent) : Colors.transparent,
            border: Border.all(
              color: error ? Colors.redAccent : colors.ink.withValues(alpha: 0.3),
              width: 1.5 * scale,
            ),
          ),
        );
      }),
    );
  }
}

// Shared 0-9 + backspace grid for every passcode screen (lock, set, confirm,
// verify). The bottom-left slot shows a fingerprint button when biometric
// retry is offered, and is otherwise blank so the "0" stays centered.
class _NumericKeypad extends StatelessWidget {
  final ValueChanged<String> onDigit;
  final VoidCallback onBackspace;
  final VoidCallback? onBiometricTap;

  const _NumericKeypad({required this.onDigit, required this.onBackspace, this.onBiometricTap});

  @override
  Widget build(BuildContext context) {
    final colors = AppColors.of(context);
    final scale = tabletScale(context);

    return LayoutBuilder(
      builder: (context, constraints) {
        // Keys are square. Sizing them from width alone (the old
        // Expanded+AspectRatio approach) works in portrait but blows up in
        // landscape, where width vastly exceeds height -- the keypad ends up
        // taller than the screen. The caller wraps this in an Expanded, so
        // constraints.maxHeight here is the real bounded leftover space --
        // bound by both dimensions so the keypad can never overflow it.
        final keySize = math.min(constraints.maxWidth / 3, constraints.maxHeight / 4);

        // Digits are glass discs (the iOS passcode look); the backspace and
        // biometric slots are bare icons, and an empty slot is just space.
        Widget key({String? label, IconData? icon, VoidCallback? onTap}) {
          final Widget face;
          if (label != null) {
            face = GlassButton(
              onTap: onTap,
              shape: const CircleBorder(),
              pressedScale: 0.92,
              shadows: const [],
              child: Center(
                child: Text(
                  label,
                  style: TextStyle(fontSize: 28 * scale, fontWeight: FontWeight.w500, color: colors.ink),
                ),
              ),
            );
          } else if (icon != null && onTap != null) {
            face = GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: onTap,
              child: Center(child: Icon(icon, color: colors.ink.withValues(alpha: 0.7), size: 26 * scale)),
            );
          } else {
            face = const SizedBox.shrink();
          }
          return SizedBox(
            width: keySize,
            height: keySize,
            child: Padding(padding: EdgeInsets.all(9 * scale), child: face),
          );
        }

        return Column(
          mainAxisAlignment: MainAxisAlignment.center,
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(mainAxisAlignment: MainAxisAlignment.center, children: [key(label: '1', onTap: () => onDigit('1')), key(label: '2', onTap: () => onDigit('2')), key(label: '3', onTap: () => onDigit('3'))]),
            Row(mainAxisAlignment: MainAxisAlignment.center, children: [key(label: '4', onTap: () => onDigit('4')), key(label: '5', onTap: () => onDigit('5')), key(label: '6', onTap: () => onDigit('6'))]),
            Row(mainAxisAlignment: MainAxisAlignment.center, children: [key(label: '7', onTap: () => onDigit('7')), key(label: '8', onTap: () => onDigit('8')), key(label: '9', onTap: () => onDigit('9'))]),
            Row(mainAxisAlignment: MainAxisAlignment.center, children: [
              key(icon: onBiometricTap != null ? Icons.fingerprint : null, onTap: onBiometricTap),
              key(label: '0', onTap: () => onDigit('0')),
              key(icon: Icons.backspace_outlined, onTap: onBackspace),
            ]),
          ],
        );
      },
    );
  }
}

// The shake-on-wrong-attempt animation shared by the lock screen and the
// passcode step screen -- factored out since both need the exact same
// "wiggle that decays over the animation" curve.
double _shakeOffset(AnimationController ctrl) {
  final t = ctrl.value;
  return math.sin(t * 14) * 8 * (1 - t);
}

// ─────────────────────────────────────────────────────────────────────────────
// LOCK SCREEN — shown at cold start (if a passcode is set) and again after
// the app is backgrounded and resumed. Auto-triggers biometric auth once on
// entry if enabled; the fingerprint key on the keypad lets the user retry
// after a cancel/failure without backing out to the passcode.
// ─────────────────────────────────────────────────────────────────────────────
class LockScreen extends StatefulWidget {
  final VoidCallback onUnlocked;
  const LockScreen({required this.onUnlocked, super.key});

  @override
  State<LockScreen> createState() => _LockScreenState();
}

class _LockScreenState extends State<LockScreen> with SingleTickerProviderStateMixin {
  final LocalAuthentication _localAuth = LocalAuthentication();
  String _entered = '';
  bool _error = false;
  bool _biometricEnabled = false;
  bool _checkingBiometric = false;

  late final AnimationController _shakeCtrl =
      AnimationController(vsync: this, duration: const Duration(milliseconds: 400));

  @override
  void initState() {
    super.initState();
    _init();
  }

  Future<void> _init() async {
    final enabled = await PasscodeStore.isBiometricEnabled();
    if (!mounted) return;
    setState(() => _biometricEnabled = enabled);
    if (enabled) _tryBiometric();
  }

  Future<void> _tryBiometric() async {
    if (_checkingBiometric) return;
    _checkingBiometric = true;
    try {
      final supported = await _localAuth.isDeviceSupported();
      if (!supported) return;
      final ok = await _localAuth.authenticate(
        localizedReason: 'Unlock nope.',
        options: const AuthenticationOptions(biometricOnly: true, stickyAuth: true),
      );
      if (ok && mounted) widget.onUnlocked();
    } catch (_) {
      // Falls back to the passcode keypad -- a biometric error shouldn't
      // strand the user with no way in.
    } finally {
      _checkingBiometric = false;
    }
  }

  Future<void> _onDigit(String d) async {
    if (_entered.length >= 4) return;
    HapticFeedback.selectionClick();
    setState(() {
      _entered += d;
      _error = false;
    });
    if (_entered.length == 4) {
      final ok = await PasscodeStore.verify(_entered);
      if (ok) {
        widget.onUnlocked();
        return;
      }
      HapticFeedback.heavyImpact();
      _shakeCtrl.forward(from: 0);
      setState(() => _error = true);
      await Future.delayed(const Duration(milliseconds: 400));
      if (mounted) setState(() => _entered = '');
    }
  }

  void _onBackspace() {
    if (_entered.isEmpty) return;
    HapticFeedback.selectionClick();
    setState(() {
      _entered = _entered.substring(0, _entered.length - 1);
      _error = false;
    });
  }

  @override
  void dispose() {
    _shakeCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final colors = AppColors.of(context);
    final scale = tabletScale(context);
    return GlassBackdrop(
      child: Scaffold(
      backgroundColor: Colors.transparent,
      body: SafeArea(
        child: Column(
          children: [
            const Spacer(),
            Text('nope.', style: TextStyle(fontSize: 40 * scale, fontWeight: FontWeight.w800, color: colors.ink, letterSpacing: -1.2)),
            const SizedBox(height: 8),
            Text(
              'Enter passcode',
              style: TextStyle(fontSize: 15 * scale, color: colors.ink.withValues(alpha: 0.55), fontWeight: FontWeight.w500),
            ),
            const SizedBox(height: 32),
            AnimatedBuilder(
              animation: _shakeCtrl,
              builder: (context, child) => Transform.translate(offset: Offset(_shakeOffset(_shakeCtrl), 0), child: child),
              child: _PinDots(length: 4, filled: _entered.length, error: _error),
            ),
            Expanded(
              flex: 10,
              child: Center(
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 32),
                  child: _NumericKeypad(
                    onDigit: _onDigit,
                    onBackspace: _onBackspace,
                    onBiometricTap: _biometricEnabled ? _tryBiometric : null,
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
      ),
    );
  }
}

// A single full-screen passcode-entry step, pushed via Navigator. Used for
// both "type a new code" (validate == null -- just pops with what was typed)
// and "confirm/verify a code" (validate returns an error message to show +
// shake on a wrong attempt, or null to accept and pop with the code). Shared
// by AppLockFlows below so the setup/change/disable flows all look and feel
// exactly like the lock screen itself.
class _PasscodeStepScreen extends StatefulWidget {
  final String title;
  final Future<String?> Function(String code)? validate;

  const _PasscodeStepScreen({required this.title, this.validate});

  @override
  State<_PasscodeStepScreen> createState() => _PasscodeStepScreenState();
}

class _PasscodeStepScreenState extends State<_PasscodeStepScreen> with SingleTickerProviderStateMixin {
  String _entered = '';
  String? _errorText;

  late final AnimationController _shakeCtrl =
      AnimationController(vsync: this, duration: const Duration(milliseconds: 400));

  Future<void> _onDigit(String d) async {
    if (_entered.length >= 4) return;
    HapticFeedback.selectionClick();
    setState(() {
      _entered += d;
      _errorText = null;
    });
    if (_entered.length != 4) return;

    if (widget.validate == null) {
      Navigator.pop(context, _entered);
      return;
    }
    final error = await widget.validate!(_entered);
    if (error == null) {
      if (mounted) Navigator.pop(context, _entered);
      return;
    }
    HapticFeedback.heavyImpact();
    _shakeCtrl.forward(from: 0);
    setState(() => _errorText = error);
    await Future.delayed(const Duration(milliseconds: 400));
    if (mounted) setState(() => _entered = '');
  }

  void _onBackspace() {
    if (_entered.isEmpty) return;
    HapticFeedback.selectionClick();
    setState(() {
      _entered = _entered.substring(0, _entered.length - 1);
      _errorText = null;
    });
  }

  @override
  void dispose() {
    _shakeCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final colors = AppColors.of(context);
    final scale = tabletScale(context);
    return GlassBackdrop(
      child: Scaffold(
      backgroundColor: Colors.transparent,
      appBar: glassAppBar(context),
      body: SafeArea(
        child: Column(
          children: [
            const Spacer(),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 32),
              child: Text(
                widget.title,
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 20 * scale, fontWeight: FontWeight.w800, color: colors.ink),
              ),
            ),
            const SizedBox(height: 28),
            AnimatedBuilder(
              animation: _shakeCtrl,
              builder: (context, child) => Transform.translate(offset: Offset(_shakeOffset(_shakeCtrl), 0), child: child),
              child: _PinDots(length: 4, filled: _entered.length, error: _errorText != null),
            ),
            if (_errorText != null) ...[
              const SizedBox(height: 12),
              Text(_errorText!, style: TextStyle(color: Colors.redAccent, fontSize: 13 * scale, fontWeight: FontWeight.w600)),
            ],
            Expanded(
              flex: 10,
              child: Center(
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 32),
                  child: _NumericKeypad(onDigit: _onDigit, onBackspace: _onBackspace),
                ),
              ),
            ),
          ],
        ),
      ),
      ),
    );
  }
}

// Orchestrates the multi-step passcode flows launched from SettingsScreen.
// Kept separate from PasscodeStore (pure storage) and _PasscodeStepScreen
// (pure single-step UI) so each piece has one job.
class AppLockFlows {
  AppLockFlows._();

  /// Enter once, confirm, save. Returns true if a passcode was set, false if
  /// the user backed out at either step.
  static Future<bool> setNewPasscode(BuildContext context) async {
    final first = await Navigator.push<String>(
      context,
      MaterialPageRoute(builder: (_) => const _PasscodeStepScreen(title: 'Choose a passcode')),
    );
    if (first == null || !context.mounted) return false;

    final confirmed = await Navigator.push<String>(
      context,
      MaterialPageRoute(
        builder: (_) => _PasscodeStepScreen(
          title: 'Confirm passcode',
          validate: (code) async => code == first ? null : "Codes don't match — try again",
        ),
      ),
    );
    if (confirmed == null) return false;

    await PasscodeStore.setPasscode(first);
    return true;
  }

  /// Verifies the existing passcode before a sensitive change (disabling the
  /// lock or setting a new code). Returns true once verified.
  static Future<bool> verifyExisting(BuildContext context) async {
    final result = await Navigator.push<String>(
      context,
      MaterialPageRoute(
        builder: (_) => _PasscodeStepScreen(
          title: 'Enter current passcode',
          validate: (code) async => await PasscodeStore.verify(code) ? null : 'Incorrect passcode',
        ),
      ),
    );
    return result != null;
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// SETTINGS — app lock controls. Reachable from NopeHome's app bar.
// ─────────────────────────────────────────────────────────────────────────────
class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  bool _loading = true;
  bool _hasPasscode = false;
  bool _biometricEnabled = false;
  bool _biometricAvailable = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final hasPasscode = await PasscodeStore.hasPasscode();
    final biometricEnabled = await PasscodeStore.isBiometricEnabled();
    var biometricAvailable = false;
    try {
      final localAuth = LocalAuthentication();
      biometricAvailable = await localAuth.isDeviceSupported() && await localAuth.canCheckBiometrics;
    } catch (_) {
      // Query failing just means we hide the toggle -- passcode-only still works.
    }
    if (!mounted) return;
    setState(() {
      _hasPasscode = hasPasscode;
      _biometricEnabled = biometricEnabled;
      _biometricAvailable = biometricAvailable;
      _loading = false;
    });
  }

  Future<void> _togglePasscode(bool enable) async {
    if (enable) {
      await AppLockFlows.setNewPasscode(context);
    } else {
      final verified = await AppLockFlows.verifyExisting(context);
      if (!verified) return;
      await PasscodeStore.clearPasscode();
    }
    await _load();
  }

  Future<void> _changePasscode() async {
    final verified = await AppLockFlows.verifyExisting(context);
    if (!verified || !mounted) return;
    await AppLockFlows.setNewPasscode(context);
    await _load();
  }

  Future<void> _toggleBiometric(bool enabled) async {
    await PasscodeStore.setBiometricEnabled(enabled);
    await _load();
  }

  @override
  Widget build(BuildContext context) {
    final colors = AppColors.of(context);
    final scale = tabletScale(context);
    // iOS "inset grouped" list: every row lives in one glass panel,
    // separated by hairlines.
    final rows = <Widget>[
      _SettingsSwitchRow(
        scale: scale,
        title: 'Passcode lock',
        subtitle: 'Require a 4-digit passcode to open the app',
        value: _hasPasscode,
        onChanged: _togglePasscode,
      ),
      if (_hasPasscode) ...[
        _SettingsTapRow(
          scale: scale,
          title: 'Change passcode',
          onTap: _changePasscode,
        ),
        if (_biometricAvailable)
          _SettingsSwitchRow(
            scale: scale,
            title: 'Use Face ID / fingerprint',
            subtitle: 'Unlock with biometrics instead of typing the passcode',
            value: _biometricEnabled,
            onChanged: _toggleBiometric,
          ),
      ],
    ];
    return GlassBackdrop(
      child: Scaffold(
        backgroundColor: Colors.transparent,
        appBar: glassAppBar(context, title: 'Settings'),
        body: _loading
            ? const SizedBox.shrink()
            : ListView(
                padding: EdgeInsets.fromLTRB(16 * scale, 8 * scale, 16 * scale, 24 * scale),
                children: [
                  Glass(
                    shape: glassRounded(26),
                    child: Column(
                      children: [
                        for (int i = 0; i < rows.length; i++) ...[
                          if (i > 0)
                            Divider(
                              height: 1,
                              thickness: 0.5,
                              indent: 16 * scale,
                              color: colors.ink.withValues(alpha: 0.12),
                            ),
                          rows[i],
                        ],
                      ],
                    ),
                  ),
                ],
              ),
      ),
    );
  }
}

// A settings row with a title/subtitle and a toggle. Built from scratch
// instead of SwitchListTile so the CupertinoSwitch itself -- not just its text --
// can grow via Transform.scale on tablets; SwitchListTile doesn't expose
// its internal Switch for that.
class _SettingsSwitchRow extends StatelessWidget {
  final double scale;
  final String title;
  final String subtitle;
  final bool value;
  final ValueChanged<bool> onChanged;

  const _SettingsSwitchRow({
    required this.scale,
    required this.title,
    required this.subtitle,
    required this.value,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    final colors = AppColors.of(context);
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: () => onChanged(!value),
      child: Padding(
        padding: EdgeInsets.symmetric(horizontal: 16 * scale, vertical: 14 * scale),
        child: Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(title, style: TextStyle(color: colors.ink, fontWeight: FontWeight.w600, fontSize: 16 * scale)),
                  SizedBox(height: 4 * scale),
                  Text(
                    subtitle,
                    style: TextStyle(color: colors.ink.withValues(alpha: 0.55), fontSize: 13 * scale),
                  ),
                ],
              ),
            ),
            SizedBox(width: 12 * scale),
            Transform.scale(
              scale: scale,
              child: CupertinoSwitch(
                activeTrackColor: kAccent,
                value: value,
                onChanged: onChanged,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// A tappable settings row (no toggle) -- e.g. "Change passcode".
class _SettingsTapRow extends StatelessWidget {
  final double scale;
  final String title;
  final VoidCallback onTap;

  const _SettingsTapRow({required this.scale, required this.title, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final colors = AppColors.of(context);
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: Padding(
        padding: EdgeInsets.symmetric(horizontal: 16 * scale, vertical: 16 * scale),
        child: Row(
          children: [
            Expanded(
              child: Text(title, style: TextStyle(color: colors.ink, fontSize: 16 * scale)),
            ),
            Icon(Icons.arrow_forward_ios_rounded, size: 15 * scale, color: colors.ink.withValues(alpha: 0.35)),
          ],
        ),
      ),
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
        GlassDialogAction(label: "No", onTap: () => Navigator.pop(dialogContext, true)),
        GlassDialogAction(label: "Yes, keep going", tint: kAccent, onTap: () => Navigator.pop(dialogContext, false)),
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
          GlassDialogAction(label: "Got it", tint: kAccent, onTap: () => Navigator.pop(dialogContext, true)),
        ],
      );
      return false;
    }

    final sure = await _dialog(
      context,
      title: "Are you sure?",
      body: sureBody,
      actions: (dialogContext) => [
        GlassDialogAction(label: "Cancel", onTap: () => Navigator.pop(dialogContext, false)),
        GlassDialogAction(label: "Reset", tint: Colors.redAccent, onTap: () => Navigator.pop(dialogContext, true)),
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
    return showGlassDialog<bool>(
      context: context,
      builder: (dialogContext) => GlassDialog(
        title: title,
        content: Text(body),
        actions: actions(dialogContext),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// HOME
// ─────────────────────────────────────────────────────────────────────────────
class NopeHome extends StatefulWidget {
  const NopeHome({super.key, this.initialHabits = const []});

  // Preloaded by AppEntry during the loading screen's minimum-display
  // window, so the first frame here already has real data instead of
  // flashing _EmptyState while _loadHabits does its own prefs read.
  final List<Habit> initialHabits;

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

  // What the home list shows, as ids (so it survives `habits` being
  // reloaded; the saved order in `habits` itself never changes):
  // [_order] -- habits still to do today, in saved order, in an animated
  // list; [_doneIds] -- habits done today, oldest first, gathered into the
  // collapsible stack at the bottom.
  List<String> _order = [];
  List<String> _doneIds = [];
  GlobalKey<SliverAnimatedListState> _listKey = GlobalKey<SliverAnimatedListState>();
  static const _moveOut = Duration(milliseconds: 320);
  static const _moveIn = Duration(milliseconds: 420);

  // Reset "damage" effect: the body shakes and a red vignette flashes over
  // it -- the opposite of a NOPE tap's red X / check celebration.
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
    habits = widget.initialHabits;
    _resort();
    _loadHabits();
  }

  Habit? _byId(String id) {
    for (final h in habits) {
      if (h.id == id) return h;
    }
    return null;
  }

  /// Rebuilds [_order] and [_doneIds] from scratch and gives the list a
  /// fresh key so it re-lays out without animating.
  void _resort() {
    final now = DateTime.now();
    _order = habits.where((h) => !h.tappedToday(now)).map((h) => h.id).toList();
    _doneIds = habits.where((h) => h.tappedToday(now)).map((h) => h.id).toList();
    _listKey = GlobalKey<SliverAnimatedListState>();
  }

  /// A habit finished its done-for-today sequence: it collapses out of the
  /// to-do list and lands on top of the done stack.
  void _settleHabit(Habit h) {
    final from = _order.indexOf(h.id);
    if (from < 0) return;
    setState(() {
      _order.removeAt(from);
      _listKey.currentState?.removeItem(
        from,
        (context, animation) => _listTransition(animation, _habitItem(h, ghost: true)),
        duration: _moveOut,
      );
      _doneIds.add(h.id);
    });
  }

  /// A done habit was reset: it leaves the stack and grows back into the
  /// end of the to-do list.
  void _unsettleHabit(Habit h) {
    setState(() {
      if (!_doneIds.remove(h.id)) return; // was already in the to-do list
      _order.add(h.id);
      _listKey.currentState?.insertItem(_order.length - 1, duration: _moveIn);
    });
  }

  Widget _listTransition(Animation<double> animation, Widget child) => SizeTransition(
        sizeFactor: CurvedAnimation(parent: animation, curve: Curves.easeInOutCubic),
        child: FadeTransition(opacity: animation, child: child),
      );

  @override
  void dispose() {
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
    setState(_resort);
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
      showGlassDialog(
        context: context,
        builder: (dialogContext) => GlassDialog(
          title: "Welcome back",
          content: Text(
            brokenStreaks > 0
                ? "It's been $daysAway days. $brokenStreaks streak${brokenStreaks == 1 ? '' : 's'} reset while you were away — ready for a fresh start?"
                : "It's been $daysAway days since you checked in. Good to see you again.",
          ),
          actions: [
            GlassDialogAction(label: "Let's go", tint: kAccent, onTap: () => Navigator.pop(dialogContext)),
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
      elevation: 0,
      barrierColor: Colors.black.withValues(alpha: 0.25),
      // Material 3's default bottom-sheet theme caps width at 640 and
      // centers it on wide viewports -- fine on phones (narrower anyway)
      // but leaves dead space on either side on tablets. Overriding with an
      // unbounded max width keeps it edge-to-edge on every screen size.
      constraints: const BoxConstraints(maxWidth: double.infinity),
      builder: (context) => _AddHabitSheet(),
    );
    if (created != null) {
      setState(() {
        habits.add(created);
        _order.add(created.id);
        _listKey.currentState?.insertItem(_order.length - 1, duration: _moveIn);
      });
      _saveHabits();
    }
  }

  void _deleteHabit(Habit h) {
    setState(() {
      final at = _order.indexOf(h.id);
      if (at >= 0) {
        _order.removeAt(at);
        // Dismissible has already animated the card away.
        _listKey.currentState?.removeItem(at, (_, _) => const SizedBox.shrink(), duration: Duration.zero);
      }
      _doneIds.remove(h.id);
      habits.removeWhere((x) => x.id == h.id);
    });
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
    // A done habit comes back out of the stack, to the end of the to-do list.
    _unsettleHabit(h);
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
    // h.nope() notifies only this habit's own card. The one setState below
    // is for the evening risk banner, whose "N habits still need a NOPE"
    // count lives up here and changes only when a tap actually counts.
    final incremented = h.nope(now, _adaptiveMessage);
    if (incremented) {
      setState(() {});
      HapticFeedback.heavyImpact();
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

  /// One habit's list entry: its card, swipeable to delete. A [ghost] is the
  /// copy AnimatedList shows collapsing out of a card's old slot during a
  /// move -- inert, and keyed apart from the real card.
  Widget _habitItem(Habit h, {bool ghost = false}) {
    final card = _HabitCard(
      key: ValueKey(ghost ? 'ghost-${h.id}' : h.id),
      habit: h,
      toneOptions: tonePacks.keys.toList(),
      onNope: () => _pressNope(h),
      onReset: () => _resetHabit(h),
      onColorChanged: (c) => _changeColor(h, c),
      onIconChanged: (i) => _changeIcon(h, i),
      // Once its done-for-today sequence finishes, sink it to the bottom.
      onSettled: () => _settleHabit(h),
    );
    if (ghost) return IgnorePointer(child: card);
    return Dismissible(
      key: ValueKey('dismiss-${h.id}'),
      background: Container(
        margin: const EdgeInsets.only(bottom: 14),
        decoration: ShapeDecoration(
          color: Colors.redAccent.withValues(alpha: 0.18),
          shape: glassRounded(28),
        ),
        alignment: Alignment.centerLeft,
        padding: const EdgeInsets.only(left: 24),
        child: const Icon(Icons.delete_outline, color: Colors.redAccent),
      ),
      direction: DismissDirection.startToEnd,
      confirmDismiss: (_) async {
        return await showGlassDialog<bool>(
          context: context,
          builder: (dialogContext) => GlassDialog(
            title: "Delete habit?",
            content: Text('Remove "${h.name}" and its history?'),
            actions: [
              GlassDialogAction(label: "Cancel", onTap: () => Navigator.pop(dialogContext, false)),
              GlassDialogAction(
                label: "Delete",
                tint: Colors.redAccent,
                onTap: () => Navigator.pop(dialogContext, true),
              ),
            ],
          ),
        ) ?? false;
      },
      onDismissed: (_) => _deleteHabit(h),
      child: card,
    );
  }

  @override
  Widget build(BuildContext context) {
    final colors = AppColors.of(context);
    final scale = tabletScale(context);
    final ink2 = colors.ink.withValues(alpha: 0.75);
    final iconSize = 21 * scale;
    final itemSize = 40 * scale;
    return GlassBackdrop(
      child: Scaffold(
      backgroundColor: Colors.transparent,
      appBar: AppBar(
        titleSpacing: 24,
        toolbarHeight: (kToolbarHeight + 8) * scale,
        title: Text(
          "nope.",
          style: TextStyle(
            fontSize: 30 * scale,
            fontWeight: FontWeight.w800,
            color: colors.ink,
            letterSpacing: -0.9,
          ),
        ),
        actions: [
          // Secondary actions share one glass capsule; "add" is the primary
          // action, so it gets its own filled-glass circle (iOS 26 toolbar).
          GlassToolbar(
            height: 44 * scale,
            children: [
              ValueListenableBuilder<ThemeMode>(
                valueListenable: themeModeNotifier,
                builder: (context, mode, _) => GlassToolbarItem(
                  tooltip: mode == ThemeMode.dark ? "Switch to light mode" : "Switch to dark mode",
                  icon: mode == ThemeMode.dark ? Icons.light_mode_rounded : Icons.dark_mode_rounded,
                  size: itemSize,
                  iconSize: iconSize,
                  color: ink2,
                  onTap: () {
                    HapticFeedback.selectionClick();
                    toggleThemeMode();
                  },
                ),
              ),
              if (habits.isNotEmpty)
                GlassToolbarItem(
                  tooltip: "Calendar view",
                  icon: Icons.calendar_month_outlined,
                  size: itemSize,
                  iconSize: iconSize,
                  color: ink2,
                  onTap: () => Navigator.push(
                    context,
                    MaterialPageRoute(builder: (_) => CalendarView(habits: habits)),
                  ),
                ),
              if (habits.isNotEmpty)
                GlassToolbarItem(
                  tooltip: "Reset all streaks",
                  icon: Icons.restart_alt,
                  size: itemSize,
                  iconSize: iconSize,
                  color: ink2,
                  onTap: () async {
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
                    // Everything is to-do again: back to the saved order.
                    setState(_resort);
                    _playResetImpact(magnitude: 1.8);
                    _saveHabits();
                  },
                ),
              GlassToolbarItem(
                tooltip: "Settings",
                icon: Icons.settings_outlined,
                size: itemSize,
                iconSize: iconSize,
                color: ink2,
                onTap: () => Navigator.push(
                  context,
                  MaterialPageRoute(builder: (_) => const SettingsScreen()),
                ),
              ),
            ],
          ),
          SizedBox(width: 8 * scale),
          GlassIconButton(
            tooltip: "Add habit",
            icon: Icons.add_rounded,
            size: 44 * scale,
            iconSize: 24 * scale,
            tint: kAccent,
            prominent: true,
            onTap: _addHabit,
          ),
          SizedBox(width: 16 * scale),
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
                  child: CustomScrollView(
                    slivers: [
                      SliverPadding(
                        padding: EdgeInsets.only(top: isTablet(context) ? 32 : 12, left: 16, right: 16),
                        sliver: SliverAnimatedList(
                          key: _listKey,
                          initialItemCount: _order.length,
                          itemBuilder: (context, i, animation) {
                            final h = _byId(_order[i]);
                            if (h == null) return const SizedBox.shrink();
                            return _listTransition(animation, _habitItem(h));
                          },
                        ),
                      ),
                      // Everything resisted today.
                      if (_order.isEmpty && _doneIds.isNotEmpty)
                        SliverPadding(
                          padding: const EdgeInsets.fromLTRB(16, 0, 16, 18),
                          sliver: SliverToBoxAdapter(child: _AllDoneCard(count: _doneIds.length)),
                        ),
                      if (_doneIds.isNotEmpty)
                        SliverPadding(
                          padding: const EdgeInsets.symmetric(horizontal: 16),
                          sliver: SliverToBoxAdapter(
                            child: _DoneStack(
                              habits: [for (final id in _doneIds) ?_byId(id)],
                              itemBuilder: (h) => _habitItem(h),
                            ),
                          ),
                        ),
                      const SliverToBoxAdapter(child: SizedBox(height: 24)),
                    ],
                  ),
                ),
              ],
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
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
      child: Glass(
      shape: glassRounded(18),
      tint: kAccent,
      tintStrength: 0.22,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
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
    final scale = tabletScale(context);
    final mq = MediaQuery.of(context);
    // A floating glass sheet (inset from the screen edges, all corners
    // rounded) like iOS 26's sheets. It rides up on top of the keyboard via
    // the outer padding.
    return Padding(
      padding: EdgeInsets.fromLTRB(
        8 * scale, 0, 8 * scale, mq.viewInsets.bottom + math.max(8.0, mq.viewPadding.bottom),
      ),
      child: ConstrainedBox(
      // Capped below the full screen height (rather than sizing purely to
      // content) so on shorter devices the sheet scrolls instead of its
      // Column overflowing past the bottom of the screen.
      constraints: BoxConstraints(maxHeight: mq.size.height * 0.88),
      // Same glass as a habit card (tinted with the colour being picked), so
      // the sheet reads as the card you're creating.
      child: Glass(
      shape: glassRounded(36),
      tint: selectedColor,
      tintStrength: habitGlassTint(context),
      blur: 30,
      padding: EdgeInsets.fromLTRB(22 * scale, 14 * scale, 22 * scale, 22 * scale),
      child: SingleChildScrollView(
        child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Handle + close
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Container(
                width: 36 * scale,
                height: 4 * scale,
                decoration: BoxDecoration(
                  color: colors.ink.withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ],
          ),
          SizedBox(height: 22 * scale),

          // Live preview row
          AnimatedContainer(
            duration: const Duration(milliseconds: 250),
            padding: EdgeInsets.all(16 * scale),
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
            // Icon pinned left; the two lines centred across the whole box.
            // The text is inset by the icon's width on *both* sides, so it
            // stays truly centred and a long name can never run under the
            // icon.
            child: Stack(
              alignment: Alignment.center,
              children: [
                Align(
                  alignment: Alignment.centerLeft,
                  child: Icon(selectedIcon, color: selectedColor, size: 44 * scale),
                ),
                Padding(
                  padding: EdgeInsets.symmetric(horizontal: (44 + 14) * scale),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        nameCtrl.text.trim().isEmpty ? "New Habit" : nameCtrl.text.trim(),
                        textAlign: TextAlign.center,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 19 * scale,
                          fontWeight: FontWeight.w800,
                          letterSpacing: -0.5,
                        ),
                      ),
                      SizedBox(height: 2 * scale),
                      Text(
                        "Starting streak: $streak day${streak == 1 ? '' : 's'}",
                        textAlign: TextAlign.center,
                        style: TextStyle(fontSize: 12.5 * scale, color: colors.ink.withValues(alpha: 0.54), fontWeight: FontWeight.w500),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),

          SizedBox(height: 24 * scale),
          Text(
            "NAME",
            style: TextStyle(fontSize: 11.5 * scale, color: colors.ink.withValues(alpha: 0.38), fontWeight: FontWeight.w700, letterSpacing: 0.8),
          ),
          SizedBox(height: 8 * scale),
          _StyledTextField(
            controller: nameCtrl,
            hint: "e.g. junk food, social media, sleeping in, etc.",
            icon: Icons.edit_rounded,
            onChanged: () => setState(() {}),
          ),

          SizedBox(height: 22 * scale),
          Text(
            "STARTING STREAK",
            style: TextStyle(fontSize: 11.5 * scale, color: colors.ink.withValues(alpha: 0.38), fontWeight: FontWeight.w700, letterSpacing: 0.8),
          ),
          SizedBox(height: 8 * scale),
          Glass(
            shape: glassRounded(16),
            // Sits on the sheet's own glass, which already blurred the page.
            blur: 0,
            shadows: const [],
            padding: EdgeInsets.symmetric(horizontal: 6 * scale, vertical: 6 * scale),
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
                      style: TextStyle(fontSize: 18 * scale, fontWeight: FontWeight.w800, letterSpacing: -0.5),
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

          SizedBox(height: 22 * scale),
          Text(
            "COLOR",
            style: TextStyle(fontSize: 11.5 * scale, color: colors.ink.withValues(alpha: 0.38), fontWeight: FontWeight.w700, letterSpacing: 0.8),
          ),
          SizedBox(height: 10 * scale),
          Row(
            children: [
              ...presetColors.entries.map((entry) {
                final isSelected = entry.value == selectedColor;
                return Expanded(
                  child: Padding(
                    padding: EdgeInsets.only(right: 8 * scale),
                    child: _GlassSwatchTile(
                      tint: entry.value,
                      selected: isSelected,
                      height: 52 * scale,
                      onTap: () {
                        HapticFeedback.selectionClick();
                        setState(() => selectedColor = entry.value);
                      },
                      child: AnimatedScale(
                            duration: const Duration(milliseconds: 200),
                            scale: isSelected ? 1.0 : 0.85,
                            child: Container(
                              width: 18 * scale,
                              height: 18 * scale,
                              decoration: BoxDecoration(
                                color: entry.value,
                                shape: BoxShape.circle,
                                boxShadow: isSelected
                                    ? [BoxShadow(color: entry.value.withValues(alpha: 0.6), blurRadius: 8)]
                                    : [],
                              ),
                              child: isSelected
                                  ? Icon(Icons.check, color: Colors.white, size: 12 * scale)
                                  : null,
                            ),
                          ),
                    ),
                  ),
                );
              }),
              _customColorCardSwatch(
                current: selectedColor,
                isCustom: !_isPresetColor(selectedColor),
                scale: scale,
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

          SizedBox(height: 22 * scale),
          Text(
            "ICON",
            style: TextStyle(fontSize: 11.5 * scale, color: colors.ink.withValues(alpha: 0.38), fontWeight: FontWeight.w700, letterSpacing: 0.8),
          ),
          SizedBox(height: 10 * scale),
          Wrap(
            spacing: 10 * scale,
            runSpacing: 10 * scale,
            children: presetIcons.map((icon) {
              final isSelected = icon.codePoint == selectedIcon.codePoint;
              // Glass discs; the selected one fills with the habit colour.
              return GlassIconButton(
                icon: icon,
                size: 44 * scale,
                iconSize: 20 * scale,
                tint: isSelected ? selectedColor : null,
                prominent: isSelected,
                color: isSelected ? Colors.white : colors.ink.withValues(alpha: 0.6),
                // Sits on the sheet's own glass, which already blurred the page.
                blur: 0,
                shadows: isSelected
                    ? [BoxShadow(color: selectedColor.withValues(alpha: 0.45), blurRadius: 12)]
                    : glassControlShadow(context),
                onTap: () {
                  HapticFeedback.selectionClick();
                  setState(() => selectedIcon = icon);
                },
              );
            }).toList(),
          ),

          SizedBox(height: 28 * scale),
          Row(
            children: [
              Expanded(
                child: GlassButton(
                  onTap: () => Navigator.pop(context),
                  blur: 0,
                  shadows: glassControlShadow(context),
                  padding: EdgeInsets.symmetric(vertical: 17 * scale),
                  child: Text(
                    "Cancel",
                    textAlign: TextAlign.center,
                    style: TextStyle(color: colors.ink.withValues(alpha: 0.7), fontSize: 15 * scale, fontWeight: FontWeight.w700),
                  ),
                ),
              ),
              SizedBox(width: 12 * scale),
              Expanded(
                flex: 2,
                child: GlassButton(
                  onTap: _submit,
                  blur: 0,
                  tint: selectedColor,
                  prominent: true,
                  padding: EdgeInsets.symmetric(vertical: 17 * scale),
                  child: Text(
                    "Add Habit",
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      color: Colors.white,
                      fontSize: 15.5 * scale,
                      fontWeight: FontWeight.w800,
                      letterSpacing: -0.2,
                    ),
                  ),
                ),
              ),
            ],
          ),
        ],
        ),
      ),
      ),
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
    final colors = AppColors.of(context);
    final scale = tabletScale(context);
    // Glass key; GlassButton dims itself when onTap is null (e.g. "-" at 0).
    return SizedBox(
      width: 44 * scale,
      height: 44 * scale,
      child: GlassButton(
        onTap: onTap,
        shape: glassRounded(12),
        // Sits on the sheet's own glass, which already blurred the page.
        blur: 0,
        shadows: glassControlShadow(context),
        pressedScale: 0.9,
        child: Center(child: Icon(icon, size: 18 * scale, color: colors.ink)),
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
    final scale = tabletScale(context);
    // A glass well: the Glass supplies the surface and edge, the field
    // itself is borderless and unfilled.
    return Glass(
      shape: glassRounded(16),
      // Sits on the sheet's own glass, which already blurred the page.
      blur: 0,
      shadows: const [],
      child: TextField(
        controller: controller,
        keyboardType: keyboardType,
        onChanged: onChanged == null ? null : (_) => onChanged!(),
        style: TextStyle(color: colors.ink, fontSize: 16 * scale, fontWeight: FontWeight.w600),
        decoration: InputDecoration(
          labelText: label,
          hintText: hint,
          prefixIcon: icon == null ? null : Icon(icon, size: 19 * scale, color: colors.ink.withValues(alpha: 0.45)),
          labelStyle: TextStyle(color: colors.ink.withValues(alpha: 0.38)),
          hintStyle: TextStyle(color: colors.ink.withValues(alpha: 0.35), fontWeight: FontWeight.w500),
          border: InputBorder.none,
          enabledBorder: InputBorder.none,
          focusedBorder: InputBorder.none,
          contentPadding: EdgeInsets.symmetric(vertical: 16 * scale, horizontal: 16 * scale),
          filled: false,
        ),
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

  /// Called once the done-for-today sequence has played and the card has
  /// greyed out -- the list uses it to move the card to the bottom.
  final VoidCallback? onSettled;

  const _HabitCard({
    super.key,
    required this.habit,
    required this.toneOptions,
    required this.onNope,
    required this.onReset,
    required this.onColorChanged,
    required this.onIconChanged,
    this.onToneChanged,
    this.onSettled,
  });

  @override
  State<_HabitCard> createState() => _HabitCardState();
}

class _HabitCardState extends State<_HabitCard> with SingleTickerProviderStateMixin {
  // Tracks the streak value from the previous rebuild so a reset (streak
  // suddenly dropping) can be told apart from a normal +1 NOPE tap -- only
  // the former gets the quick scroll-down-to-0 animation.
  int? _lastKnownStreak;

  /// Drives the "done for today" sequence (see [_NopeStage] for the
  /// timeline): red X over the icon, NOPE button poofs, big check draws in.
  /// Starts finished if the habit was already done today, so reopening the
  /// app shows the end state without replaying it.
  late final AnimationController _celebrate = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1500),
    value: widget.habit.tappedToday(DateTime.now()) ? 1 : 0,
  );

  @override
  void dispose() {
    _celebrate.dispose();
    super.dispose();
  }

  /// Plays the sequence only for the tap that actually counts the habit
  /// for today -- not for a repeat tap on an already-done habit.
  void _handleNope() {
    final wasDone = habit.tappedToday(DateTime.now());
    onNope();
    if (!wasDone && habit.tappedToday(DateTime.now())) {
      _celebrate.forward(from: 0).then((_) {
        if (!mounted) return;
        setState(() {}); // grey out now the sequence has finished
        // Let the grey-out land before the card moves.
        Future.delayed(const Duration(milliseconds: 600), () {
          if (mounted && habit.tappedToday(DateTime.now())) widget.onSettled?.call();
        });
      });
    }
  }

  /// Done for today and the sequence has finished: the card is greyed out
  /// and only its reset button responds.
  bool _isSettled(bool tappedToday) =>
      tappedToday && _celebrate.status == AnimationStatus.completed;

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
        builder: (context, _) => Padding(
          padding: const EdgeInsets.only(bottom: 14),
          child: _buildCard(context),
        ),
      ),
    );
  }

  Widget _buildCard(BuildContext context) {
    final colors = AppColors.of(context);
    final scale = tabletScale(context);
    final habitColor = Color(habit.colorValue);
    final tappedToday = habit.tappedToday(DateTime.now());

    final currentStreak = habit.streak;
    final previousStreak = _lastKnownStreak ?? currentStreak;
    final justReset = currentStreak < previousStreak;
    _lastKnownStreak = currentStreak;

    final settled = _isSettled(tappedToday);

    // A pane of glass washed in the habit's own colour. Once done for today
    // it fades to grey and stops responding -- except the reset button,
    // which sits above the grey layer, in full colour.
    final glassCard = Glass(
      shape: glassRounded(28),
      tint: habitColor,
      tintStrength: habitGlassTint(context),
      child: Padding(
        padding: EdgeInsets.fromLTRB(20 * scale, 18 * scale, 16 * scale, 18 * scale),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Header row -- icon + name centered on the *full* card width via
            // Stack, with the reset button floating on top at the right.
            // (Previously centered via a Row with a spacer sized to match
            // the reset button, which drifted off-center once the button's
            // own icon started scaling for tablets at a different rate than
            // the fixed-width spacer.)
            SizedBox(
              width: double.infinity,
              child: Stack(
              alignment: Alignment.center,
              children: [
                GestureDetector(
                  onTap: () => _showCustomizeSheet(context),
                  child: Column(
                    children: [
                      SizedBox(
                        width: 100 * scale,
                        height: 100 * scale,
                        child: AnimatedBuilder(
                          animation: _celebrate,
                          builder: (context, child) => CustomPaint(
                            // Red X drawn over the icon in the first part of
                            // the sequence (and left there for the day).
                            foregroundPainter: _RedXPainter(
                              progress: tappedToday ? _NopeStage.xPhase.transform(_celebrate.value) : 0,
                            ),
                            child: child,
                          ),
                          child: Icon(
                            habitIconForCodePoint(habit.iconCodePoint),
                            size: 100 * scale,
                            color: habitColor,
                          ),
                        ),
                      ),
                      SizedBox(height: 8 * scale),
                      Text(
                        habit.name,
                        textAlign: TextAlign.center,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 15 * scale,
                          fontWeight: FontWeight.w800,
                          letterSpacing: -0.3,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
              ),
            ),

            SizedBox(height: 4 * scale),

            // Streak info
            // Wrap (not Row) so this never throws a RenderFlex overflow --
            // a fresh habit has no lastTap yet, which used to drop the one
            // Expanded that kept the two fixed-width chips in check; now
            // the chips just wrap to a second line if they don't fit.
            Wrap(
              crossAxisAlignment: WrapCrossAlignment.center,
              spacing: 8 * scale,
              runSpacing: 6 * scale,
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
                _StatChip(
                  label: "best",
                  value: "${habit.longestStreak}d",
                  color: colors.ink.withValues(alpha: 0.24),
                ),
                if (habit.lastTap != null)
                  Text(
                    "last: ${_formatDate(habit.lastTap!)}",
                    style: TextStyle(fontSize: 11 * scale, color: colors.ink.withValues(alpha: 0.3)),
                  ),
              ],
            ),

            SizedBox(height: 18 * scale),
            // NOPE button -> poof -> big check mark
            Center(
              child: _NopeStage(
                animation: _celebrate,
                tappedToday: tappedToday,
                color: habitColor,
                onTap: _handleNope,
              ),
            ),

            // Adaptive message
            if (habit.lastLine != null) ...[
              SizedBox(height: 14 * scale),
              AnimatedSwitcher(
                duration: const Duration(milliseconds: 300),
                child: Text(
                  habit.lastLine!,
                  key: ValueKey(habit.lastLine),
                  style: TextStyle(
                    color: tappedToday ? habitColor.withValues(alpha: 0.8) : colors.ink.withValues(alpha: 0.54),
                    fontSize: 14 * scale,
                    fontStyle: FontStyle.italic,
                  ),
                ),
              ),
            ],
          ],
        ),
      ),
    );

    final resetButton = GlassIconButton(
      tooltip: "Reset streak",
      icon: Icons.refresh_rounded,
      size: 36 * scale,
      iconSize: 18 * scale,
      color: colors.ink.withValues(alpha: 0.55),
      // Sits on the card's glass, which already blurred the page.
      blur: 0,
      shadows: const [],
      onTap: onReset,
    );

    // Once done for today the whole card greys out and drops out of focus,
    // and the only thing left to do -- reset -- comes forward as one crisp
    // button in the middle. [grey] animates 0 -> 1 as that happens.
    return TweenAnimationBuilder<double>(
      // begin == end: no animation on first build (a habit already done
      // when the app opens is simply settled); later changes animate.
      tween: Tween(begin: settled ? 1 : 0, end: settled ? 1 : 0),
      duration: const Duration(milliseconds: 450),
      curve: Curves.easeOut,
      child: IgnorePointer(ignoring: settled, child: glassCard),
      builder: (context, grey, card) {
        return Stack(
          children: [
            if (grey == 0)
              card!
            else ...[
              // Greyed, blurred contents -- the blur clipped to the card's
              // shape so its edge doesn't smear...
              ClipPath(
                clipper: ShapeBorderClipper(shape: glassRounded(28)),
                child: Opacity(
                  opacity: 1 - 0.35 * grey,
                  child: ImageFiltered(
                    imageFilter: ui.ImageFilter.blur(sigmaX: 4 * grey, sigmaY: 4 * grey),
                    child: ColorFiltered(colorFilter: ColorFilter.matrix(_desaturate(grey)), child: card),
                  ),
                ),
              ),
              // ...under a crisp pane of frosted glass, so the card keeps a
              // sharp edge and its contents read as behind glass.
              Positioned.fill(
                child: IgnorePointer(
                  child: Opacity(
                    opacity: grey,
                    child: Glass(shape: glassRounded(28), blur: 0, shadows: const []),
                  ),
                ),
              ),
            ],
            // Small corner reset while the habit is still to do.
            if (grey < 1)
              Positioned(
                top: 18 * scale,
                right: 16 * scale,
                child: IgnorePointer(
                  ignoring: settled,
                  child: Opacity(opacity: 1 - grey, child: resetButton),
                ),
              ),
            // Once it's done: the habit's name and the one reset button,
            // centred and in focus over the greyed-out card.
            if (grey > 0)
              Positioned.fill(
                child: Center(
                  child: IgnorePointer(
                    ignoring: !settled,
                    child: Opacity(
                      opacity: grey,
                      child: Transform.scale(
                        scale: 0.85 + 0.15 * grey,
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Padding(
                              padding: EdgeInsets.symmetric(horizontal: 24 * scale),
                              child: Text(
                                habit.name,
                                textAlign: TextAlign.center,
                                maxLines: 2,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                  fontSize: 20 * scale,
                                  fontWeight: FontWeight.w800,
                                  letterSpacing: -0.4,
                                  color: colors.ink,
                                ),
                              ),
                            ),
                            SizedBox(height: 14 * scale),
                            Semantics(
                              label: "Reset streak",
                              child: GlassButton(
                                onTap: onReset,
                                padding: EdgeInsets.symmetric(horizontal: 22 * scale, vertical: 13 * scale),
                                child: Row(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    Icon(Icons.refresh_rounded, size: 20 * scale, color: kResetRed),
                                    SizedBox(width: 6 * scale),
                                    Text(
                                      "Reset",
                                      style: TextStyle(
                                        fontSize: 16 * scale,
                                        fontWeight: FontWeight.w700,
                                        color: kResetRed,
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
              ),
          ],
        );
      },
    );
  }

  /// Colour matrix blending from full colour (0) to greyscale (1).
  static List<double> _desaturate(double amount) {
    const r = 0.2126, g = 0.7152, b = 0.0722;
    double mix(double identity, double grey) => identity + (grey - identity) * amount;
    return [
      mix(1, r), mix(0, g), mix(0, b), 0, 0,
      mix(0, r), mix(1, g), mix(0, b), 0, 0,
      mix(0, r), mix(0, g), mix(1, b), 0, 0,
      0, 0, 0, 1, 0,
    ];
  }

  void _showCustomizeSheet(BuildContext context) async {
    Color tempColor = Color(habit.colorValue);
    IconData tempIcon = habitIconForCodePoint(habit.iconCodePoint);

    final result = await showGlassDialog<(Color, IconData)>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (context, setDialogState) {
          final colors = AppColors.of(context);
          return GlassDialog(
          title: "Customize habit",
          content: SizedBox(
            width: double.infinity,
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
            GlassDialogAction(label: "Cancel", onTap: () => Navigator.pop(context)),
            GlassDialogAction(label: "Done", tint: tempColor, onTap: () => Navigator.pop(context, (tempColor, tempIcon))),
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
    final scale = tabletScale(context);
    return Glass(
      shape: const StadiumBorder(),
      tint: highlight ? color : null,
      tintStrength: 0.22,
      blur: 0,
      rim: 0.7,
      shadows: const [],
      padding: EdgeInsets.symmetric(horizontal: 11 * scale, vertical: 5 * scale),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            value,
            style: TextStyle(
              fontSize: 14 * scale,
              fontWeight: FontWeight.w800,
              color: highlight ? color : colors.ink.withValues(alpha: 0.7),
              letterSpacing: -0.5,
            ),
          ),
          const SizedBox(width: 3),
          Text(
            label,
            style: TextStyle(
              fontSize: 11 * scale,
              color: highlight ? color.withValues(alpha: 0.8) : colors.ink.withValues(alpha: 0.45),
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

  const _NopeButton({required this.onTap});

  @override
  State<_NopeButton> createState() => _NopeButtonState();
}

class _NopeButtonState extends State<_NopeButton> {
  bool _pressed = false;

  @override
  Widget build(BuildContext context) {
    final colors = AppColors.of(context);
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final scale = tabletScale(context);
    final size = 160 * scale;

    return Semantics(
      button: true,
      label: "NOPE",
      child: GestureDetector(
        onTapDown: (_) => setState(() => _pressed = true),
        onTapUp: (_) {
          setState(() => _pressed = false);
          widget.onTap();
        },
        onTapCancel: () => setState(() => _pressed = false),
        child: AnimatedScale(
          scale: _pressed ? 0.91 : 1.0,
          duration: const Duration(milliseconds: 90),
          curve: Curves.easeOut,
          child: SizedBox(
            width: size,
            height: size,
            child: Glass(
              shape: const CircleBorder(),
              // Frosted-pane look (even rim, edge glints) just for this
              // button; everything else uses the standard liquid glass.
              style: GlassStyle.pane,
              // Sits inside the habit card's glass, which already blurred
              // the page behind it.
              blur: 0,
              frost: 0,
              rim: 1.2,
              shadows: [
                BoxShadow(
                  color: Colors.black.withValues(alpha: _pressed ? 0.08 : (isDark ? 0.22 : 0.08)),
                  blurRadius: _pressed ? 6 : 18,
                  offset: Offset(0, _pressed ? 2 : 6),
                ),
              ],
              child: Stack(
                fit: StackFit.expand,
                children: [
                  // Soft light pooling at the bottom.
                  LiquidLensOptics(glow: _pressed ? 1 : 0),
                  // Press glow.
                  AnimatedOpacity(
                    opacity: _pressed ? 1 : 0,
                    duration: const Duration(milliseconds: 90),
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        gradient: RadialGradient(
                          colors: [
                            Colors.white.withValues(alpha: 0.30),
                            Colors.white.withValues(alpha: 0.02),
                          ],
                        ),
                      ),
                    ),
                  ),
                  // "nope." scaled to span most of the button's diameter
                  // (inset enough to stay clear of the curved edge).
                  Padding(
                    padding: EdgeInsets.symmetric(horizontal: size * 0.13),
                    child: Center(
                      child: FittedBox(
                        fit: BoxFit.scaleDown,
                        child: _ExtraHeavyText("nope.", color: colors.ink, fontSize: 40 * scale),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// "DONE FOR TODAY" SEQUENCE
// ─────────────────────────────────────────────────────────────────────────────

/// The NOPE button's slot on a habit card, which plays the done-for-today
/// sequence when [animation] runs (0 -> 1 over ~1.5s):
///
///   0.00-0.35  a red X draws itself over the habit icon (see [_RedXPainter],
///              driven from the card via [xPhase]);
///   0.35-0.60  the NOPE button swells and fades -- the "poof" -- while
///   0.35-0.80  a ring of smoke puffs bursts out and dissipates;
///   0.55-1.00  a big check mark in the habit's colour draws itself in,
///              with a slight overshoot.
///
/// If the habit isn't done today, the plain NOPE button shows regardless
/// of where the animation was left (e.g. after a reset or a new day).
class _NopeStage extends StatelessWidget {
  final Animation<double> animation;
  final bool tappedToday;
  final Color color;
  final VoidCallback onTap;

  const _NopeStage({
    required this.animation,
    required this.tappedToday,
    required this.color,
    required this.onTap,
  });

  static const xPhase = Interval(0.0, 0.35, curve: Curves.easeInOut);
  static const _poofPhase = Interval(0.35, 0.60, curve: Curves.easeOut);
  static const _puffPhase = Interval(0.35, 0.80, curve: Curves.easeOut);
  static const _checkDraw = Interval(0.55, 0.95, curve: Curves.easeOutCubic);
  static const _checkPop = Interval(0.55, 1.0, curve: Curves.easeOutBack);

  @override
  Widget build(BuildContext context) {
    final size = 160 * tabletScale(context);
    final smoke = AppColors.of(context).ink;
    return AnimatedBuilder(
      animation: animation,
      builder: (context, _) {
        final t = tappedToday ? animation.value : 0.0;
        final poof = _poofPhase.transform(t);
        final puffs = _puffPhase.transform(t);
        final check = _checkDraw.transform(t);
        return SizedBox(
          width: size,
          height: size,
          child: Stack(
            clipBehavior: Clip.none,
            alignment: Alignment.center,
            children: [
              if (poof < 1)
                Opacity(
                  opacity: 1 - poof,
                  child: Transform.scale(scale: 1 + 0.35 * poof, child: _NopeButton(onTap: onTap)),
                ),
              if (puffs > 0 && puffs < 1)
                Positioned.fill(
                  child: IgnorePointer(
                    child: CustomPaint(painter: _PoofPainter(progress: puffs, color: smoke)),
                  ),
                ),
              if (check > 0)
                Semantics(
                  button: true,
                  label: "Done for today",
                  child: GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onTap: onTap,
                    child: Transform.scale(
                      scale: 0.6 + 0.4 * _checkPop.transform(t),
                      child: CustomPaint(
                        size: Size.square(size),
                        painter: _CheckPainter(progress: check, color: color),
                      ),
                    ),
                  ),
                ),
            ],
          ),
        );
      },
    );
  }
}

/// Paints the first [progress] (0-1) of [path] as a stroke. A segment
/// shorter than half the stroke width is skipped, so a round-capped stroke
/// never flashes up as a lone dot on its first frame.
void _drawPartialPath(Canvas canvas, Path path, double progress, Paint paint) {
  if (progress <= 0) return;
  for (final metric in path.computeMetrics()) {
    final length = metric.length * progress.clamp(0.0, 1.0);
    if (length < paint.strokeWidth * 0.5) continue;
    canvas.drawPath(metric.extractPath(0, length), paint);
  }
}

/// A red X over the habit icon that looks scrawled with a marker: each of
/// its two strokes is several overlapping, slightly bowed passes of varying
/// width (the uneven, layered edges of a real marker line), cut through
/// with thin dry-brush streaks, plus a thin flick off one side. The first
/// stroke draws top-left to bottom-right, then the second top-right to
/// bottom-left. It reaches a little past the icon, like a quick mark would.
class _RedXPainter extends CustomPainter {
  final double progress;

  _RedXPainter({required this.progress});

  static const _ink = Color(0xFFC8102E);

  // One marker pass, in units of the icon size, measured across the stroke
  // (perpendicular offsets at each end, how far it bows in the middle).
  static const _passes = [
    // (startOffset, endOffset, bow, width, opacity)
    (-0.030, -0.020, 0.012, 0.085, 0.95),
    (0.000, 0.012, -0.010, 0.100, 1.00),
    (0.034, 0.030, 0.018, 0.065, 0.90),
    (-0.012, 0.042, 0.004, 0.040, 0.85),
  ];

  // Thin flick running just off one edge of the stroke, slightly longer.
  static const _flick = (0.068, 0.074, 0.022, 0.016, 0.90);

  // Dry-brush gaps cut through the ink (perpendicular offsets).
  static const _streaks = [-0.022, 0.010, 0.030];

  @override
  void paint(Canvas canvas, Size size) {
    if (progress <= 0) return;
    final s = size.shortestSide;
    final p1 = (progress * 2).clamp(0.0, 1.0);
    final p2 = (progress * 2 - 1).clamp(0.0, 1.0);

    // Everything in one layer so the dry-brush streaks cut only the ink.
    final bounds = (Offset.zero & size).inflate(s * 0.2);
    canvas.saveLayer(bounds, Paint());
    _stroke(canvas, s, Offset(size.width * 0.08, size.height * 0.10), Offset(size.width * 0.92, size.height * 0.90), p1);
    _stroke(canvas, s, Offset(size.width * 0.90, size.height * 0.08), Offset(size.width * 0.10, size.height * 0.92), p2);
    canvas.restore();
  }

  void _stroke(Canvas canvas, double s, Offset a, Offset b, double progress) {
    if (progress <= 0) return;
    final d = b - a;
    final dir = d / d.distance;
    final perp = Offset(-dir.dy, dir.dx);

    Path pass(double os, double oe, double bow, {double overshoot = 0}) {
      final start = a + perp * (os * s) - dir * (overshoot * s);
      final end = b + perp * (oe * s) + dir * (overshoot * s);
      final control = (start + end) / 2 + perp * (bow * s);
      return Path()
        ..moveTo(start.dx, start.dy)
        ..quadraticBezierTo(control.dx, control.dy, end.dx, end.dy);
    }

    Paint ink(double width, double opacity) => Paint()
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round
      ..strokeWidth = width * s
      ..color = _ink.withValues(alpha: opacity);

    for (final (os, oe, bow, width, opacity) in _passes) {
      _drawPartialPath(canvas, pass(os, oe, bow), progress, ink(width, opacity));
    }
    final (fs, fe, fb, fw, fo) = _flick;
    _drawPartialPath(canvas, pass(fs, fe, fb, overshoot: 0.04), progress, ink(fw, fo));

    // Dry-brush streaks: thin gaps erased from the ink, kept off the ends.
    for (final o in _streaks) {
      final start = a + d * 0.12 + perp * (o * s);
      final end = a + d * 0.88 + perp * (o * s * 1.2);
      _drawPartialPath(
        canvas,
        Path()
          ..moveTo(start.dx, start.dy)
          ..lineTo(end.dx, end.dy),
        progress,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeCap = StrokeCap.round
          ..strokeWidth = s * 0.007
          ..blendMode = BlendMode.dstOut
          ..color = Colors.black.withValues(alpha: 0.75),
      );
    }
  }

  @override
  bool shouldRepaint(_RedXPainter old) => old.progress != progress;
}

/// The "poof": a ring of soft smoke puffs bursting outward from where the
/// NOPE button was, growing as they go and fading to nothing.
class _PoofPainter extends CustomPainter {
  final double progress;
  final Color color;

  _PoofPainter({required this.progress, required this.color});

  static const _count = 12;

  @override
  void paint(Canvas canvas, Size size) {
    final c = size.center(Offset.zero);
    final r = size.shortestSide / 2;
    final fade = 1 - progress;
    for (var i = 0; i < _count; i++) {
      // Alternate puffs travel a little further, so the ring looks ragged
      // rather than perfectly even.
      final reach = i.isEven ? 1.0 : 0.82;
      final angle = i * 2 * math.pi / _count + 0.2;
      final distance = r * (0.55 + 0.6 * reach * progress);
      final puffRadius = r * (0.10 + 0.16 * progress) * (i.isEven ? 1.0 : 0.8);
      final center = c + Offset(math.cos(angle), math.sin(angle)) * distance;
      canvas.drawCircle(
        center,
        puffRadius,
        Paint()
          ..color = color.withValues(alpha: 0.35 * fade)
          ..maskFilter = MaskFilter.blur(BlurStyle.normal, puffRadius * 0.5),
      );
    }
  }

  @override
  bool shouldRepaint(_PoofPainter old) => old.progress != progress || old.color != color;
}

/// A big, round-capped check mark in the habit's colour that draws itself
/// in (short stroke, then the long one), over a soft glow of the same colour.
class _CheckPainter extends CustomPainter {
  final double progress;
  final Color color;

  _CheckPainter({required this.progress, required this.color});

  @override
  void paint(Canvas canvas, Size size) {
    final w = size.width, h = size.height;
    final stroke = size.shortestSide * 0.12;
    final path = Path()
      ..moveTo(w * 0.22, h * 0.53)
      ..lineTo(w * 0.42, h * 0.72)
      ..lineTo(w * 0.80, h * 0.30);
    Paint base() => Paint()
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round
      ..strokeWidth = stroke;
    _drawPartialPath(
      canvas,
      path,
      progress,
      base()
        ..strokeWidth = stroke * 1.6
        ..color = color.withValues(alpha: 0.35)
        ..maskFilter = MaskFilter.blur(BlurStyle.normal, stroke * 0.6),
    );
    _drawPartialPath(canvas, path, progress, base()..color = color);
  }

  @override
  bool shouldRepaint(_CheckPainter old) => old.progress != progress || old.color != color;
}

/// Text heavier than the font's heaviest weight: Inter Black (900), plus a
/// same-coloured stroke traced round every glyph to fatten its strokes.
/// Letter-spacing is opened up by the stroke's width so the fattened letters
/// keep the same gaps between them.
class _ExtraHeavyText extends StatelessWidget {
  final String text;
  final Color color;
  final double fontSize;

  const _ExtraHeavyText(this.text, {required this.color, required this.fontSize});

  @override
  Widget build(BuildContext context) {
    final stroke = fontSize * 0.035;
    final base = TextStyle(
      fontSize: fontSize,
      fontWeight: FontWeight.w900,
      // The title's -3% tracking, widened by the extra stroke.
      letterSpacing: -0.03 * fontSize + stroke,
      height: 1.0,
    );
    return Stack(
      children: [
        Text(
          text,
          style: base.copyWith(
            foreground: Paint()
              ..style = PaintingStyle.stroke
              ..strokeWidth = stroke
              ..strokeJoin = StrokeJoin.round
              ..color = color,
          ),
        ),
        Text(text, style: base.copyWith(color: color)),
      ],
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// DONE-TODAY STACK
// ─────────────────────────────────────────────────────────────────────────────

/// The habits done today, gathered at the bottom of the home list.
///
/// Collapsed, it's an Apple Wallet-style pile: each done habit is a slim
/// greyed pass, stacked so the ones behind show only their top row (icon +
/// name) and the newest sits in front. Pull it up (or tap it) to fan it out
/// into the full cards; tap the "Done today" label to fold it back.
/// Dragging is only listened for while collapsed, so once open the cards
/// scroll with the page normally.
class _DoneStack extends StatefulWidget {
  /// Oldest first; the newest is shown on top of the deck.
  final List<Habit> habits;
  final Widget Function(Habit) itemBuilder;

  const _DoneStack({required this.habits, required this.itemBuilder});

  @override
  State<_DoneStack> createState() => _DoneStackState();
}

class _DoneStackState extends State<_DoneStack> {
  bool _open = false;

  static const _maxPasses = 4;
  static const _passHeight = 64.0;
  static const _passStep = 26.0; // how much of each pass behind shows

  void _setOpen(bool open) {
    if (open == _open) return;
    HapticFeedback.selectionClick();
    setState(() => _open = open);
  }

  @override
  Widget build(BuildContext context) {
    final colors = AppColors.of(context);
    final scale = tabletScale(context);
    final newestFirst = widget.habits.reversed.toList();
    final count = newestFirst.length;

    final header = GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: () => _setOpen(!_open),
      child: Padding(
        padding: EdgeInsets.fromLTRB(4 * scale, 4 * scale, 4 * scale, 10 * scale),
        child: Row(
          children: [
            Text(
              "DONE TODAY",
              style: TextStyle(fontSize: 11.5 * scale, fontWeight: FontWeight.w700, letterSpacing: 0.8, color: colors.ink.withValues(alpha: 0.45)),
            ),
            SizedBox(width: 6 * scale),
            Text(
              "$count",
              style: TextStyle(fontSize: 11.5 * scale, fontWeight: FontWeight.w800, color: colors.ink.withValues(alpha: 0.7)),
            ),
            const Spacer(),
            Text(
                _open ? "Collapse" : "Show all",
                style: TextStyle(fontSize: 12 * scale, fontWeight: FontWeight.w600, color: colors.ink.withValues(alpha: 0.5)),
              ),
          ],
        ),
      ),
    );

    final Widget body;
    if (_open) {
      body = Column(
        key: const ValueKey('open'),
        children: [for (final h in newestFirst) widget.itemBuilder(h)],
      );
    } else {
      // Oldest visible pass at the back (top), newest in front (bottom).
      final passes = newestFirst.take(_maxPasses).toList().reversed.toList();
      final step = _passStep * scale;
      final passHeight = _passHeight * scale;
      body = GestureDetector(
        key: const ValueKey('pile'),
        behavior: HitTestBehavior.opaque,
        // Pull up (or tap) to fan the pile out.
        onVerticalDragEnd: (d) {
          if ((d.primaryVelocity ?? 0) < -150) _setOpen(true);
        },
        onTap: () => _setOpen(true),
        child: Column(
          children: [
            SizedBox(
              height: passHeight + step * (passes.length - 1),
              child: Stack(
                children: [
                  for (var i = 0; i < passes.length; i++)
                    Positioned(
                      left: 0,
                      right: 0,
                      top: step * i,
                      height: passHeight,
                      child: _DonePass(habit: passes[i], height: passHeight),
                    ),
                ],
              ),
            ),
            SizedBox(height: 8 * scale),
            Text(
              count > _maxPasses ? "Pull up to see all $count" : "Pull up to open",
              style: TextStyle(fontSize: 11 * scale, fontWeight: FontWeight.w600, color: colors.ink.withValues(alpha: 0.4)),
            ),
            SizedBox(height: 6 * scale),
          ],
        ),
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        header,
        AnimatedSize(
          duration: const Duration(milliseconds: 380),
          curve: Curves.easeInOutCubic,
          alignment: Alignment.topCenter,
          child: AnimatedSwitcher(
            duration: const Duration(milliseconds: 260),
            child: body,
          ),
        ),
      ],
    );
  }
}

/// One done habit as a slim, greyed "pass" in the collapsed done pile. Its
/// icon and name sit in the top row, the part that stays visible when
/// other passes are stacked in front of it.
class _DonePass extends StatelessWidget {
  final Habit habit;
  final double height;

  const _DonePass({required this.habit, required this.height});

  @override
  Widget build(BuildContext context) {
    final colors = AppColors.of(context);
    final scale = tabletScale(context);
    final muted = Color.lerp(Color(habit.colorValue), colors.ink, 0.55)!.withValues(alpha: 0.75);
    return Glass(
      shape: glassRounded(20),
      tint: Color(habit.colorValue),
      tintStrength: 0.08,
      // Solidly frosted, so the passes stacked behind don't show through;
      // no backdrop blur, since overlapping blurs don't layer cleanly.
      frost: 1,
      blur: 0,
      shadows: [
        BoxShadow(color: Colors.black.withValues(alpha: 0.25), blurRadius: 12, offset: const Offset(0, -2)),
      ],
      padding: EdgeInsets.fromLTRB(14 * scale, 7 * scale, 14 * scale, 0),
      child: Align(
        alignment: Alignment.topLeft,
        child: Row(
          children: [
            Icon(habitIconForCodePoint(habit.iconCodePoint), size: 17 * scale, color: muted),
            SizedBox(width: 8 * scale),
            Expanded(
              child: Text(
                habit.name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(fontSize: 13.5 * scale, fontWeight: FontWeight.w700, color: colors.ink.withValues(alpha: 0.6)),
              ),
            ),
            Icon(Icons.check_rounded, size: 17 * scale, color: muted),
          ],
        ),
      ),
    );
  }
}

/// Shown above the done stack once every habit has been resisted today.
class _AllDoneCard extends StatelessWidget {
  final int count;
  const _AllDoneCard({required this.count});

  @override
  Widget build(BuildContext context) {
    final colors = AppColors.of(context);
    final scale = tabletScale(context);
    return Glass(
      shape: glassRounded(26),
      tint: const Color(0xFF3FB27F),
      tintStrength: 0.22,
      padding: EdgeInsets.symmetric(horizontal: 22 * scale, vertical: 22 * scale),
      child: Column(
        children: [
          Text("🎉", style: TextStyle(fontSize: 34 * scale)),
          SizedBox(height: 8 * scale),
          Text(
            "All clear for today",
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 20 * scale, fontWeight: FontWeight.w800, letterSpacing: -0.4, color: colors.ink),
          ),
          SizedBox(height: 6 * scale),
          Text(
            count == 1
                ? "You resisted your habit today. See you tomorrow."
                : "You resisted all $count of your habits today. See you tomorrow.",
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 14 * scale, height: 1.35, color: colors.ink.withValues(alpha: 0.7)),
          ),
        ],
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
    final scale = tabletScale(context);
    return GlassBackdrop(
      child: Scaffold(
      backgroundColor: Colors.transparent,
      appBar: glassAppBar(context, title: "Calendar"),
      body: SingleChildScrollView(
        padding: EdgeInsets.fromLTRB(16 * scale, 8 * scale, 16 * scale, 24 * scale),
        child: Column(
        children: [
          Glass(
            shape: glassRounded(28),
            padding: EdgeInsets.fromLTRB(8 * scale, 4 * scale, 8 * scale, 12 * scale),
            child: TableCalendar(
            firstDay: DateTime.utc(2023, 1, 1),
            lastDay: DateTime.now().add(const Duration(days: 365)),
            focusedDay: _focusedDay,
            calendarFormat: CalendarFormat.month,
            rowHeight: 52 * scale,
            daysOfWeekHeight: 24 * scale,
            selectedDayPredicate: (day) => isSameDay(_selectedDay, day),
            onDaySelected: (selected, focused) {
              setState(() {
                _selectedDay = selected;
                _focusedDay = focused;
              });
            },
            calendarStyle: CalendarStyle(
              defaultTextStyle: TextStyle(color: colors.ink.withValues(alpha: 0.7), fontSize: 14 * scale),
              weekendTextStyle: TextStyle(color: colors.ink.withValues(alpha: 0.54), fontSize: 14 * scale),
              outsideTextStyle: TextStyle(color: colors.ink.withValues(alpha: 0.24), fontSize: 14 * scale),
              todayDecoration: BoxDecoration(
                color: kAccent.withValues(alpha: 0.35),
                shape: BoxShape.circle,
              ),
              selectedDecoration: const BoxDecoration(
                color: kAccent,
                shape: BoxShape.circle,
              ),
              selectedTextStyle: TextStyle(color: Colors.white, fontWeight: FontWeight.w800, fontSize: 14 * scale),
              todayTextStyle: TextStyle(color: colors.ink, fontWeight: FontWeight.w600, fontSize: 14 * scale),
            ),
            headerStyle: HeaderStyle(
              formatButtonVisible: false,
              titleCentered: true,
              titleTextStyle: TextStyle(
                fontWeight: FontWeight.w800,
                fontSize: 16 * scale,
                letterSpacing: -0.5,
              ),
              leftChevronIcon: Icon(Icons.chevron_left, size: 24 * scale, color: colors.ink.withValues(alpha: 0.54)),
              rightChevronIcon: Icon(Icons.chevron_right, size: 24 * scale, color: colors.ink.withValues(alpha: 0.54)),
            ),
            daysOfWeekStyle: DaysOfWeekStyle(
              weekdayStyle: TextStyle(color: colors.ink.withValues(alpha: 0.38), fontSize: 12 * scale),
              weekendStyle: TextStyle(color: colors.ink.withValues(alpha: 0.24), fontSize: 12 * scale),
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
          ),
          const SizedBox(height: 16),
          if (_selectedDay != null)
            Glass(
              shape: glassRounded(24),
              padding: EdgeInsets.fromLTRB(20 * scale, 18 * scale, 20 * scale, 12 * scale),
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
                          style: TextStyle(
                            fontWeight: FontWeight.w800,
                            fontSize: 16 * scale,
                            letterSpacing: -0.3,
                          ),
                        ),
                        const SizedBox(height: 10),
                        ...onDay.map((entry) => Padding(
                          padding: const EdgeInsets.only(bottom: 8),
                          child: Row(
                            children: [
                              Container(
                                width: 10 * scale,
                                height: 10 * scale,
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
                                  style: TextStyle(color: colors.ink.withValues(alpha: 0.7), fontSize: 14 * scale),
                                ),
                              ),
                              Text(
                                _formatTime(entry.value),
                                style: TextStyle(fontSize: 12 * scale, color: colors.ink.withValues(alpha: 0.4)),
                              ),
                            ],
                          ),
                        )),
                        if (onDay.isEmpty)
                          Text("Nothing logged.", style: TextStyle(color: colors.ink.withValues(alpha: 0.38), fontSize: 14 * scale)),
                      ],
                    );
                  }),
                ],
              ),
            ),
        ],
        ),
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
                fontWeight: FontWeight.w800,
                color: colors.ink.withValues(alpha: 0.12),
                letterSpacing: -1.7,
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