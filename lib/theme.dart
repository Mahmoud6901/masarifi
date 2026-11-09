import 'package:flutter/material.dart';

/// Masarifi's visual system: a nocturnal terminal, pinned by the Fey reference.
/// Colour is signal only: [growth] for positive, [warm] for the one highlight
/// and due-soon, [signal] for the active navigation mark, [negative] for loss.
@immutable
class MasarifiColors extends ThemeExtension<MasarifiColors> {
  const MasarifiColors({
    required this.canvas,
    required this.card,
    required this.well,
    required this.hairline,
    required this.ink,
    required this.muted,
    required this.growth,
    required this.warm,
    required this.signal,
    required this.negative,
  });

  final Color canvas;
  final Color card;
  final Color well;
  final Color hairline;
  final Color ink;
  final Color muted;
  final Color growth;
  final Color warm;
  final Color signal;
  final Color negative;

  static const dark = MasarifiColors(
    canvas: Color(0xFF0B0B0B),
    card: Color(0xFF191919),
    well: Color(0xFF131313),
    hairline: Color(0xFF2B2B2B),
    ink: Color(0xFFFFFFFF),
    muted: Color(0xFF868F97),
    growth: Color(0xFF4EBE96),
    warm: Color(0xFFFFA16C),
    signal: Color(0xFF479FFA),
    negative: Color(0xFFE5736B),
  );

  static const light = MasarifiColors(
    canvas: Color(0xFFF5F5F6),
    card: Color(0xFFFFFFFF),
    well: Color(0xFFEBEBED),
    hairline: Color(0xFFDADADD),
    ink: Color(0xFF0B0B0B),
    muted: Color(0xFF5A636B),
    growth: Color(0xFF1B7F60),
    warm: Color(0xFFB4501A),
    signal: Color(0xFF1F6FD1),
    negative: Color(0xFFC2433B),
  );

  @override
  MasarifiColors copyWith({
    Color? canvas,
    Color? card,
    Color? well,
    Color? hairline,
    Color? ink,
    Color? muted,
    Color? growth,
    Color? warm,
    Color? signal,
    Color? negative,
  }) => MasarifiColors(
    canvas: canvas ?? this.canvas,
    card: card ?? this.card,
    well: well ?? this.well,
    hairline: hairline ?? this.hairline,
    ink: ink ?? this.ink,
    muted: muted ?? this.muted,
    growth: growth ?? this.growth,
    warm: warm ?? this.warm,
    signal: signal ?? this.signal,
    negative: negative ?? this.negative,
  );

  @override
  MasarifiColors lerp(ThemeExtension<MasarifiColors>? other, double t) {
    if (other is! MasarifiColors) return this;
    return MasarifiColors(
      canvas: Color.lerp(canvas, other.canvas, t)!,
      card: Color.lerp(card, other.card, t)!,
      well: Color.lerp(well, other.well, t)!,
      hairline: Color.lerp(hairline, other.hairline, t)!,
      ink: Color.lerp(ink, other.ink, t)!,
      muted: Color.lerp(muted, other.muted, t)!,
      growth: Color.lerp(growth, other.growth, t)!,
      warm: Color.lerp(warm, other.warm, t)!,
      signal: Color.lerp(signal, other.signal, t)!,
      negative: Color.lerp(negative, other.negative, t)!,
    );
  }
}

extension MasarifiThemeX on BuildContext {
  /// Falls back to the palette for the current brightness when a host app
  /// (or a test) mounts a screen without [masarifiTheme].
  MasarifiColors get mc {
    final theme = Theme.of(this);
    return theme.extension<MasarifiColors>() ??
        (theme.brightness == Brightness.dark
            ? MasarifiColors.dark
            : MasarifiColors.light);
  }
}

/// Money and figures align in columns: tabular numerals everywhere.
const tabular = [FontFeature.tabularFigures()];

const double _radiusCard = 16;
const double _radiusPill = 99;

/// [fontFamily] is null in the app (the platform font, SF Pro on iPhone);
/// the preview test passes a loaded family so text renders in widget tests.
ThemeData masarifiTheme(Brightness brightness, {String? fontFamily}) {
  final c = brightness == Brightness.dark
      ? MasarifiColors.dark
      : MasarifiColors.light;

  final scheme = ColorScheme(
    brightness: brightness,
    primary: c.ink,
    onPrimary: c.canvas,
    secondary: c.signal,
    onSecondary: c.canvas,
    error: c.negative,
    onError: c.canvas,
    surface: c.canvas,
    onSurface: c.ink,
    onSurfaceVariant: c.muted,
    surfaceContainerLowest: c.canvas,
    surfaceContainerLow: c.well,
    surfaceContainer: c.card,
    surfaceContainerHigh: c.card,
    surfaceContainerHighest: c.well,
    outline: c.muted,
    outlineVariant: c.hairline,
    primaryContainer: c.card,
    onPrimaryContainer: c.ink,
    errorContainer: c.card,
    onErrorContainer: c.negative,
    shadow: const Color(0xFF000000),
    scrim: const Color(0xCC000000),
  );

  // Display sizes carry the signature: compressed, confident tracking.
  TextStyle t(
    double size,
    FontWeight w,
    double height,
    double em,
    Color color,
  ) => TextStyle(
    fontFamily: fontFamily,
    fontSize: size,
    fontWeight: w,
    height: height,
    letterSpacing: size * em,
    color: color,
    fontFeatures: tabular,
  );

  final text = TextTheme(
    displayLarge: t(54, FontWeight.w700, 1.0, -0.08, c.ink),
    displayMedium: t(48, FontWeight.w700, 1.05, -0.08, c.ink),
    displaySmall: t(34, FontWeight.w700, 1.1, -0.06, c.ink),
    headlineLarge: t(26, FontWeight.w600, 1.2, -0.053, c.ink),
    headlineMedium: t(24, FontWeight.w600, 1.25, -0.053, c.ink),
    headlineSmall: t(20, FontWeight.w600, 1.3, -0.03, c.ink),
    titleLarge: t(18, FontWeight.w600, 1.32, -0.02, c.ink),
    titleMedium: t(16, FontWeight.w600, 1.35, -0.01, c.ink),
    titleSmall: t(14, FontWeight.w600, 1.4, 0, c.ink),
    bodyLarge: t(16, FontWeight.w400, 1.5, 0, c.ink),
    bodyMedium: t(14, FontWeight.w400, 1.5, 0, c.ink),
    bodySmall: t(12, FontWeight.w400, 1.5, 0, c.muted),
    labelLarge: t(14, FontWeight.w500, 1.3, 0, c.ink),
    labelMedium: t(12, FontWeight.w500, 1.3, 0, c.muted),
    labelSmall: t(11, FontWeight.w500, 1.3, 0, c.muted),
  );

  const pill = StadiumBorder();
  final ghostSide = BorderSide(color: c.muted.withValues(alpha: 0.45));

  return ThemeData(
    useMaterial3: true,
    fontFamily: fontFamily,
    brightness: brightness,
    colorScheme: scheme,
    scaffoldBackgroundColor: c.canvas,
    canvasColor: c.canvas,
    textTheme: text,
    primaryTextTheme: text,
    extensions: [c],
    splashFactory: NoSplash.splashFactory,
    highlightColor: Colors.transparent,
    dividerTheme: DividerThemeData(color: c.hairline, space: 1, thickness: 1),
    cardTheme: CardThemeData(
      color: c.card,
      elevation: 0,
      margin: EdgeInsets.zero,
      surfaceTintColor: Colors.transparent,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(_radiusCard),
      ),
    ),
    // Ghost pills: no fill colour; shape and a faint rim define the action.
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        backgroundColor: c.card,
        foregroundColor: c.ink,
        disabledBackgroundColor: c.well,
        disabledForegroundColor: c.muted,
        minimumSize: const Size(64, 48),
        padding: const EdgeInsets.symmetric(horizontal: 22),
        shape: pill,
        side: ghostSide,
        textStyle: text.labelLarge,
        elevation: 0,
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        foregroundColor: c.ink,
        minimumSize: const Size(64, 48),
        shape: pill,
        side: ghostSide,
        textStyle: text.labelLarge,
      ),
    ),
    textButtonTheme: TextButtonThemeData(
      style: TextButton.styleFrom(
        foregroundColor: c.muted,
        minimumSize: const Size(48, 44),
        shape: pill,
        textStyle: text.labelLarge,
      ),
    ),
    iconButtonTheme: IconButtonThemeData(
      style: IconButton.styleFrom(
        foregroundColor: c.ink,
        minimumSize: const Size(48, 48),
      ),
    ),
    floatingActionButtonTheme: FloatingActionButtonThemeData(
      backgroundColor: c.card,
      foregroundColor: c.ink,
      elevation: 0,
      focusElevation: 0,
      hoverElevation: 0,
      highlightElevation: 0,
      shape: const StadiumBorder(),
      extendedTextStyle: text.labelLarge,
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: c.well,
      labelStyle: text.bodyMedium?.copyWith(color: c.muted),
      hintStyle: text.bodyMedium?.copyWith(color: c.muted),
      contentPadding: const EdgeInsets.symmetric(horizontal: 18, vertical: 16),
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(14),
        borderSide: BorderSide.none,
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(14),
        borderSide: BorderSide.none,
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(14),
        borderSide: BorderSide(color: c.ink.withValues(alpha: 0.7)),
      ),
      errorBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(14),
        borderSide: BorderSide(color: c.negative),
      ),
      focusedErrorBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(14),
        borderSide: BorderSide(color: c.negative),
      ),
    ),
    listTileTheme: ListTileThemeData(
      iconColor: c.muted,
      textColor: c.ink,
      titleTextStyle: text.titleMedium,
      subtitleTextStyle: text.bodySmall,
      contentPadding: const EdgeInsets.symmetric(horizontal: 16),
    ),
    chipTheme: ChipThemeData(
      backgroundColor: c.card,
      side: BorderSide(color: c.hairline),
      shape: pill,
      labelStyle: text.labelLarge,
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 10),
    ),
    dialogTheme: DialogThemeData(
      backgroundColor: c.card,
      surfaceTintColor: Colors.transparent,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(_radiusCard + 8),
      ),
      titleTextStyle: text.titleLarge,
      contentTextStyle: text.bodyMedium?.copyWith(color: c.muted),
    ),
    bottomSheetTheme: BottomSheetThemeData(
      backgroundColor: c.card,
      surfaceTintColor: Colors.transparent,
      showDragHandle: true,
      dragHandleColor: c.hairline,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
    ),
    snackBarTheme: SnackBarThemeData(
      backgroundColor: c.card,
      contentTextStyle: text.bodyMedium,
      // Actions such as Undo use the full ink: white on the dark bar. The
      // default (inverse primary) is the canvas colour, black on black.
      actionTextColor: c.ink,
      behavior: SnackBarBehavior.floating,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(_radiusPill),
      ),
    ),
    progressIndicatorTheme: ProgressIndicatorThemeData(
      color: c.muted,
      linearTrackColor: c.hairline,
    ),
    textSelectionTheme: TextSelectionThemeData(
      cursorColor: c.ink,
      selectionColor: c.signal.withValues(alpha: 0.35),
      selectionHandleColor: c.ink,
    ),
    dropdownMenuTheme: DropdownMenuThemeData(
      menuStyle: MenuStyle(
        backgroundColor: WidgetStatePropertyAll(c.card),
        surfaceTintColor: const WidgetStatePropertyAll(Colors.transparent),
      ),
    ),
  );
}
