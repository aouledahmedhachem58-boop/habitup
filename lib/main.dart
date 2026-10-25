// HabitUp v2 — suivi d'habitudes avec interface 3D.
//
// Aucune dépendance externe : le fichier compile avec un projet Flutter vierge.
// Pour sauvegarder les données entre deux lancements, voir la classe
// HabitStorage (section 2) : un exemple SharedPreferences y est fourni.
//
// Structure du fichier :
//   1. Thème et utilitaires
//   2. Modèle et store (état + persistance)
//   3. Composants visuels (fond aurore, verre, inclinaison 3D, anneau, barres, confettis)
//   4. Pages (Accueil, Habitudes, Aujourd'hui, Progression)
//   5. Éditeur d'habitude et navigation
import 'package:firebase_core/firebase_core.dart';
import 'firebase_options.dart';
import 'dart:convert';
import 'dart:math' as math;
import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

// ─────────────────────────────────────────────────────────────────────────────
// 1. THÈME ET UTILITAIRES
// ─────────────────────────────────────────────────────────────────────────────

class Palette {
  static const bg = Color(0xFF07061A);
  static const surface = Color(0xFF14112E);
  static const violet = Color(0xFF8B5CF6);
  static const cyan = Color(0xFF22D3EE);
  static const pink = Color(0xFFF472B6);
  static const lime = Color(0xFFA3E635);
  static const amber = Color(0xFFFBBF24);
  static const coral = Color(0xFFFB7185);

  static const habitColors = [violet, cyan, pink, lime, amber, coral];
}

const kIcons = <IconData>[
  Icons.fitness_center,
  Icons.menu_book,
  Icons.water_drop,
  Icons.bedtime,
  Icons.self_improvement,
  Icons.directions_run,
  Icons.restaurant,
  Icons.code,
  Icons.brush,
  Icons.savings,
];

/// Couleur avec opacité sans API dépréciée.
Color a(Color c, double o) => c.withAlpha((o.clamp(0.0, 1.0) * 255).round());

const kValidationRatio = 0.5; // un jour compte dans la série à partir de 50 %
const kChallengeDays = 30;

const _weekdays = [
  'Lundi', 'Mardi', 'Mercredi', 'Jeudi', 'Vendredi', 'Samedi', 'Dimanche',
];
const _months = [
  'janvier', 'février', 'mars', 'avril', 'mai', 'juin',
  'juillet', 'août', 'septembre', 'octobre', 'novembre', 'décembre',
];

String frenchDate(DateTime d) =>
    '${_weekdays[d.weekday - 1]} ${d.day} ${_months[d.month - 1]}';

String greeting() {
  final h = DateTime.now().hour;
  if (h < 5) return 'Bonne nuit';
  if (h < 12) return 'Bonjour';
  if (h < 18) return 'Bon après-midi';
  return 'Bonsoir';
}

const kTitle = TextStyle(
  fontSize: 30,
  fontWeight: FontWeight.w800,
  letterSpacing: -0.8,
  height: 1.1,
);
final kMuted = TextStyle(color: a(Colors.white, 0.6), fontSize: 14);

// ─────────────────────────────────────────────────────────────────────────────
// 2. MODÈLE ET STORE
// ─────────────────────────────────────────────────────────────────────────────

class Habit {
  Habit({
    required this.id,
    required this.name,
    required this.goal,
    required this.icon,
    required this.color,
  });

  final String id;
  String name;
  String goal;
  int icon;
  int color;

  IconData get iconData => kIcons[icon % kIcons.length];
  Color get colorValue => Palette.habitColors[color % Palette.habitColors.length];

  Map<String, dynamic> toJson() =>
      {'id': id, 'name': name, 'goal': goal, 'icon': icon, 'color': color};

  factory Habit.fromJson(Map<String, dynamic> j) => Habit(
        id: j['id'] as String,
        name: j['name'] as String,
        goal: (j['goal'] as String?) ?? '',
        icon: (j['icon'] as int?) ?? 0,
        color: (j['color'] as int?) ?? 0,
      );
}

/// Stockage des données sérialisées (JSON). Remplaçable sans toucher au reste.
abstract class HabitStorage {
  Future<String?> read();
  Future<void> write(String data);
}

/// Stockage par défaut : en mémoire (les données durent le temps de la session).
class MemoryStorage implements HabitStorage {
  String? _data;

  @override
  Future<String?> read() async => _data;

  @override
  Future<void> write(String data) async => _data = data;
}

// Pour une sauvegarde permanente :
//   1. flutter pub add shared_preferences
//   2. ajouter l'import  'package:shared_preferences/shared_preferences.dart'
//   3. décommenter la classe ci-dessous
//   4. dans HabitUpApp, remplacer HabitStore() par
//        HabitStore(storage: PrefsStorage())
//
// class PrefsStorage implements HabitStorage {
//   static const _key = 'habitup_v2';
//
//   @override
//   Future<String?> read() async =>
//       (await SharedPreferences.getInstance()).getString(_key);
//
//   @override
//   Future<void> write(String data) async =>
//       (await SharedPreferences.getInstance()).setString(_key, data);
// }

class HabitStore extends ChangeNotifier {
  HabitStore({HabitStorage? storage}) : storage = storage ?? MemoryStorage();

  final HabitStorage storage;

  final List<Habit> habits = [];
  final Map<String, Set<String>> _log = {}; // 'yyyy-MM-dd' -> ids validés
  DateTime challengeStart = today();
  bool ready = false;
  int celebrationTick = 0;

  // ── Dates ──
  static DateTime today() {
    final n = DateTime.now();
    return DateTime(n.year, n.month, n.day);
  }

  static DateTime shift(DateTime d, int days) =>
      DateTime(d.year, d.month, d.day + days);

  static String keyOf(DateTime d) =>
      '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

  static int daysBetween(DateTime from, DateTime to) =>
      DateTime.utc(to.year, to.month, to.day)
          .difference(DateTime.utc(from.year, from.month, from.day))
          .inDays;

  // ── Chargement / sauvegarde ──
  Future<void> load() async {
    try {
      final raw = await storage.read();
      if (raw == null) {
        _seed();
      } else {
        final m = jsonDecode(raw) as Map<String, dynamic>;
        habits
          ..clear()
          ..addAll((m['habits'] as List)
              .map((e) => Habit.fromJson(e as Map<String, dynamic>)));
        _log.clear();
        (m['log'] as Map<String, dynamic>).forEach((k, v) {
          _log[k] = Set<String>.from(v as List);
        });
        challengeStart = DateTime.tryParse(m['start'] as String? ?? '') ?? today();
      }
    } catch (_) {
      // Stockage indisponible ou données corrompues : on repart proprement.
      if (habits.isEmpty) _seed();
    }
    ready = true;
    notifyListeners();
  }

  void _seed() {
    habits
      ..clear()
      ..addAll([
        Habit(id: _newId(), name: 'Faire du sport', goal: '30 minutes', icon: 0, color: 0),
        Habit(id: _newId(), name: 'Lire un livre', goal: '15 minutes', icon: 1, color: 1),
        Habit(id: _newId(), name: "Boire de l'eau", goal: '2 litres', icon: 2, color: 2),
        Habit(id: _newId(), name: 'Bien dormir', goal: '8 heures', icon: 3, color: 3),
      ]);
    challengeStart = today();
  }

  String _newId() =>
      '${DateTime.now().microsecondsSinceEpoch}${math.Random().nextInt(9999)}';

  Future<void> _save() async {
    try {
      await storage.write(
        jsonEncode({
          'habits': habits.map((h) => h.toJson()).toList(),
          'log': _log.map((k, v) => MapEntry(k, v.toList())),
          'start': challengeStart.toIso8601String(),
        }),
      );
    } catch (_) {/* la sauvegarde ne doit jamais faire planter l'app */}
  }

  void _commit() {
    notifyListeners();
    _save();
  }

  // ── Actions ──
  bool isDone(Habit h, DateTime d) => _log[keyOf(d)]?.contains(h.id) ?? false;

  void toggle(Habit h) {
    final set = _log.putIfAbsent(keyOf(today()), () => <String>{});
    final nowDone = set.add(h.id);
    if (!nowDone) set.remove(h.id);
    if (nowDone && habits.isNotEmpty && doneCount(today()) == habits.length) {
      celebrationTick++;
    }
    _commit();
  }

  void add(String name, String goal, int icon, int color) {
    habits.add(Habit(id: _newId(), name: name, goal: goal, icon: icon, color: color));
    _commit();
  }

  void update(Habit h, String name, String goal, int icon, int color) {
    h
      ..name = name
      ..goal = goal
      ..icon = icon
      ..color = color;
    _commit();
  }

  int remove(Habit h) {
    final i = habits.indexOf(h);
    habits.remove(h);
    _commit();
    return i;
  }

  void restore(Habit h, int index) {
    habits.insert(index.clamp(0, habits.length), h);
    _commit();
  }

  void restartChallenge() {
    challengeStart = today();
    _commit();
  }

  // ── Statistiques ──
  int doneCount(DateTime d) => habits.where((h) => isDone(h, d)).length;

  double ratio(DateTime d) =>
      habits.isEmpty ? 0 : doneCount(d) / habits.length;

  bool _valid(DateTime d) =>
      habits.isNotEmpty && doneCount(d) > 0 && ratio(d) >= kValidationRatio;

  int get streak {
    var d = today();
    if (!_valid(d)) d = shift(d, -1); // la journée en cours ne casse pas la série
    var n = 0;
    while (_valid(d) && n < 3650) {
      n++;
      d = shift(d, -1);
    }
    return n;
  }

  int get totalCompletions {
    final ids = habits.map((h) => h.id).toSet();
    return _log.values.fold(0, (sum, s) => sum + s.where(ids.contains).length);
  }

  bool get hasPerfectDay =>
      habits.isNotEmpty &&
      _log.values.any((s) => habits.every((h) => s.contains(h.id)));

  int get xp => totalCompletions * 10;
  int get level => xp ~/ 100 + 1;
  double get levelProgress => (xp % 100) / 100;

  int get challengeDay =>
      (daysBetween(challengeStart, today()) + 1).clamp(1, kChallengeDays).toInt();

  List<DateTime> lastDays(int n) =>
      List.generate(n, (i) => shift(today(), i - (n - 1)));

  /// Taux de réussite moyen sur les 7 derniers jours.
  double get weekAverage {
    final days = lastDays(7);
    return days.map(ratio).reduce((x, y) => x + y) / days.length;
  }
}

class StoreScope extends InheritedNotifier<HabitStore> {
  const StoreScope({super.key, required HabitStore store, required super.child})
      : super(notifier: store);

  static HabitStore of(BuildContext context) {
    final scope = context.dependOnInheritedWidgetOfExactType<StoreScope>();
    assert(scope != null, 'StoreScope introuvable dans l\'arbre de widgets');
    return scope!.notifier!;
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// 3. COMPOSANTS VISUELS
// ─────────────────────────────────────────────────────────────────────────────

/// Fond animé : trois halos de couleur qui dérivent lentement.
class AuroraBackground extends StatefulWidget {
  const AuroraBackground({super.key, required this.child});
  final Widget child;

  @override
  State<AuroraBackground> createState() => _AuroraBackgroundState();
}

class _AuroraBackgroundState extends State<AuroraBackground>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c =
      AnimationController(vsync: this, duration: const Duration(seconds: 22))
        ..repeat();

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  Widget _blob(Color color, double size, Alignment al) => Align(
        alignment: al,
        child: Container(
          width: size,
          height: size,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            gradient: RadialGradient(colors: [a(color, 0.5), a(color, 0)]),
          ),
        ),
      );

  @override
  Widget build(BuildContext context) {
    return Stack(
      fit: StackFit.expand,
      children: [
        const ColoredBox(color: Palette.bg),
        AnimatedBuilder(
          animation: _c,
          builder: (_, _) {
            final t = _c.value * 2 * math.pi;
            return Stack(
              fit: StackFit.expand,
              children: [
                _blob(Palette.violet, 460, Alignment(math.cos(t) * 0.9, -0.8 + math.sin(t) * 0.2)),
                _blob(Palette.cyan, 380, Alignment(-0.9 + math.sin(t) * 0.3, 0.2 + math.cos(t) * 0.4)),
                _blob(Palette.pink, 420, Alignment(0.9 + math.cos(t * 2) * 0.1, 0.9 + math.sin(t) * 0.1)),
              ],
            );
          },
        ),
        widget.child,
      ],
    );
  }
}

/// Carte en verre dépoli.
class GlassCard extends StatelessWidget {
  const GlassCard({
    super.key,
    required this.child,
    this.padding = const EdgeInsets.all(18),
    this.radius = 26,
  });

  final Widget child;
  final EdgeInsets padding;
  final double radius;

  @override
  Widget build(BuildContext context) {
    final r = BorderRadius.circular(radius);
    return ClipRRect(
      borderRadius: r,
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 18, sigmaY: 18),
        child: Container(
          padding: padding,
          decoration: BoxDecoration(
            borderRadius: r,
            gradient: LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: [a(Colors.white, 0.14), a(Colors.white, 0.04)],
            ),
            border: Border.all(color: a(Colors.white, 0.16)),
          ),
          child: child,
        ),
      ),
    );
  }
}

/// Inclinaison 3D qui suit le doigt ou la souris.
/// Utilise un Listener (pas de GestureDetector) pour ne jamais bloquer le défilement.
class Tilt3D extends StatefulWidget {
  const Tilt3D({super.key, required this.child, this.maxAngle = 0.14});
  final Widget child;
  final double maxAngle;

  @override
  State<Tilt3D> createState() => _Tilt3DState();
}

class _Tilt3DState extends State<Tilt3D> {
  Offset _tilt = Offset.zero;
  bool _active = false;

  void _track(Offset p) {
    final box = context.findRenderObject() as RenderBox?;
    if (box == null || !box.hasSize) return;
    final dx = ((p.dx / box.size.width) - 0.5) * 2;
    final dy = ((p.dy / box.size.height) - 0.5) * 2;
    setState(() {
      _active = true;
      _tilt = Offset(dx.clamp(-1.0, 1.0).toDouble(), dy.clamp(-1.0, 1.0).toDouble());
    });
  }

  void _release() => setState(() {
        _active = false;
        _tilt = Offset.zero;
      });

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      onHover: (e) => _track(e.localPosition),
      onExit: (_) => _release(),
      child: Listener(
        onPointerDown: (e) => _track(e.localPosition),
        onPointerMove: (e) => _track(e.localPosition),
        onPointerUp: (_) => _release(),
        onPointerCancel: (_) => _release(),
        child: TweenAnimationBuilder<Offset>(
          tween: Tween(begin: Offset.zero, end: _tilt),
          duration: Duration(milliseconds: _active ? 80 : 500),
          curve: _active ? Curves.linear : Curves.elasticOut,
          builder: (_, v, child) => Transform(
            alignment: Alignment.center,
            transform: Matrix4.identity()
              ..setEntry(3, 2, 0.0012)
              ..rotateX(-v.dy * widget.maxAngle)
              ..rotateY(v.dx * widget.maxAngle),
            child: child,
          ),
          child: widget.child,
        ),
      ),
    );
  }
}

/// Barre de progression en dégradé avec animation.
class GradientBar extends StatelessWidget {
  const GradientBar({super.key, required this.value, this.height = 10});
  final double value;
  final double height;

  @override
  Widget build(BuildContext context) {
    final r = BorderRadius.circular(height);
    return TweenAnimationBuilder<double>(
      tween: Tween(end: value.clamp(0.0, 1.0).toDouble()),
      duration: const Duration(milliseconds: 700),
      curve: Curves.easeOutCubic,
      builder: (_, v, _) => Container(
        height: height,
        alignment: Alignment.centerLeft,
        decoration: BoxDecoration(color: a(Colors.white, 0.1), borderRadius: r),
        child: FractionallySizedBox(
          widthFactor: v,
          child: Container(
            decoration: BoxDecoration(
              borderRadius: r,
              gradient: const LinearGradient(
                colors: [Palette.cyan, Palette.violet, Palette.pink],
              ),
              boxShadow: [BoxShadow(color: a(Palette.violet, 0.55), blurRadius: 10)],
            ),
          ),
        ),
      ),
    );
  }
}

class GradientButton extends StatelessWidget {
  const GradientButton({super.key, required this.label, required this.onTap, this.icon});
  final String label;
  final IconData? icon;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final r = BorderRadius.circular(20);
    return DecoratedBox(
      decoration: BoxDecoration(
        borderRadius: r,
        gradient: const LinearGradient(colors: [Palette.violet, Palette.cyan]),
        boxShadow: [
          BoxShadow(color: a(Palette.violet, 0.5), blurRadius: 24, offset: const Offset(0, 10)),
        ],
      ),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          borderRadius: r,
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 16, horizontal: 24),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                if (icon != null) ...[
                  Icon(icon, color: Colors.white),
                  const SizedBox(width: 10),
                ],
                Text(label,
                    style: const TextStyle(
                        fontSize: 16, fontWeight: FontWeight.w700, color: Colors.white)),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Pastille d'habitude qui se retourne en 3D quand elle est validée.
class FlipBadge extends StatelessWidget {
  const FlipBadge({super.key, required this.icon, required this.color, required this.done});
  final IconData icon;
  final Color color;
  final bool done;

  Widget _face(IconData i, Color c) => Container(
        width: 52,
        height: 52,
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(18),
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [Color.lerp(c, Colors.white, 0.25)!, c],
          ),
          boxShadow: [BoxShadow(color: a(c, 0.55), blurRadius: 16, offset: const Offset(0, 6))],
        ),
        child: Icon(i, color: Colors.white, size: 26),
      );

  @override
  Widget build(BuildContext context) {
    return TweenAnimationBuilder<double>(
      tween: Tween(end: done ? 1.0 : 0.0),
      duration: const Duration(milliseconds: 550),
      curve: Curves.easeOutBack,
      builder: (_, v, _) {
        final back = v > 0.5;
        return Transform(
          alignment: Alignment.center,
          transform: Matrix4.identity()
            ..setEntry(3, 2, 0.002)
            ..rotateY(v * math.pi),
          child: back
              ? Transform(
                  alignment: Alignment.center,
                  transform: Matrix4.identity()..rotateY(math.pi),
                  child: _face(Icons.check_rounded, Palette.lime),
                )
              : _face(icon, color),
        );
      },
    );
  }
}

/// Anneau de progression en relief, qui flotte doucement.
class HeroRing extends StatefulWidget {
  const HeroRing({super.key, required this.value, required this.caption});
  final double value;
  final String caption;

  @override
  State<HeroRing> createState() => _HeroRingState();
}

class _HeroRingState extends State<HeroRing> with SingleTickerProviderStateMixin {
  late final AnimationController _c =
      AnimationController(vsync: this, duration: const Duration(seconds: 6))
        ..repeat(reverse: true);

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _c,
      builder: (_, child) {
        final t = Curves.easeInOut.transform(_c.value) * 2 - 1;
        return Transform(
          alignment: Alignment.center,
          transform: Matrix4.identity()
            ..setEntry(3, 2, 0.0015)
            ..rotateX(0.32 + t * 0.06)
            ..rotateY(t * 0.14),
          child: child,
        );
      },
      child: SizedBox(
        width: 230,
        height: 230,
        child: TweenAnimationBuilder<double>(
          tween: Tween(end: widget.value),
          duration: const Duration(milliseconds: 1000),
          curve: Curves.easeOutCubic,
          builder: (_, v, _) => CustomPaint(
            painter: _RingPainter(v),
            child: Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text('${(widget.value * 100).round()}%',
                      style: const TextStyle(
                          fontSize: 48, fontWeight: FontWeight.w800, letterSpacing: -1.5)),
                  Text(widget.caption, style: kMuted),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _RingPainter extends CustomPainter {
  _RingPainter(this.value);
  final double value;

  @override
  void paint(Canvas canvas, Size size) {
    const stroke = 24.0;
    final center = Offset(size.width / 2, size.height / 2);
    final r = size.width / 2 - stroke;
    final rect = Rect.fromCircle(center: center, radius: r);

    Paint base() => Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = stroke
      ..strokeCap = StrokeCap.round;

    // Rail
    canvas.drawCircle(center, r, base()..color = a(Colors.white, 0.08));
    if (value <= 0) return;
    final sweep = 2 * math.pi * value.clamp(0.0, 1.0);

    // Épaisseur (extrusion) : l'arc répété vers le bas, de plus en plus sombre.
    for (var i = 12; i >= 1; i--) {
      canvas.drawArc(
        rect.shift(Offset(0, i * 1.3)),
        -math.pi / 2,
        sweep,
        false,
        base()..color = Color.lerp(Palette.violet, Colors.black, 0.6)!,
      );
    }

    // Halo
    canvas.drawArc(
      rect,
      -math.pi / 2,
      sweep,
      false,
      base()
        ..color = a(Palette.cyan, 0.5)
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 16),
    );

    // Face supérieure en dégradé
    canvas.drawArc(
      rect,
      -math.pi / 2,
      sweep,
      false,
      base()
        ..shader = const SweepGradient(
          colors: [Palette.cyan, Palette.violet, Palette.pink],
          transform: GradientRotation(-math.pi / 2),
        ).createShader(rect),
    );
  }

  @override
  bool shouldRepaint(_RingPainter old) => old.value != value;
}

/// Histogramme isométrique (faces avant, droite et dessus).
class IsoBars extends StatelessWidget {
  const IsoBars({super.key, required this.values, required this.labels, required this.highlight});
  final List<double> values;
  final List<String> labels;
  final int highlight;

  @override
  Widget build(BuildContext context) => SizedBox(
        height: 210,
        width: double.infinity,
        child: CustomPaint(painter: _BarsPainter(values, labels, highlight)),
      );
}

class _BarsPainter extends CustomPainter {
  _BarsPainter(this.values, this.labels, this.highlight);
  final List<double> values;
  final List<String> labels;
  final int highlight;

  void _text(Canvas c, String s, Offset center, TextStyle st) {
    final tp = TextPainter(
      text: TextSpan(text: s, style: st),
      textDirection: TextDirection.ltr,
    )..layout();
    tp.paint(c, center - Offset(tp.width / 2, tp.height / 2));
  }

  @override
  void paint(Canvas canvas, Size size) {
    final slot = size.width / values.length;
    final bw = slot * 0.42;
    final d = bw * 0.38; // profondeur
    final base = size.height - 26;
    final maxH = size.height - 70;

    for (var i = 0; i < values.length; i++) {
      final v = values[i].clamp(0.0, 1.0);
      final h = math.max(8.0, v * maxH);
      final x = slot * i + (slot - bw - d) / 2;
      final top = base - h;

      final front = v >= 0.999
          ? Palette.lime
          : (v == 0 ? a(Colors.white, 0.18) : Palette.violet);
      final side = Color.lerp(front, Colors.black, 0.4)!;
      final cap = Color.lerp(front, Colors.white, 0.4)!;

      // Ombre au sol
      canvas.drawOval(
        Rect.fromLTWH(x, base - 2, bw + d, 10),
        Paint()..color = a(Colors.black, 0.35)..maskFilter = const MaskFilter.blur(BlurStyle.normal, 5),
      );

      canvas.drawRect(Rect.fromLTWH(x, top, bw, h), Paint()..color = front);

      canvas.drawPath(
        Path()
          ..moveTo(x + bw, top)
          ..lineTo(x + bw + d, top - d * 0.6)
          ..lineTo(x + bw + d, base - d * 0.6)
          ..lineTo(x + bw, base)
          ..close(),
        Paint()..color = side,
      );

      canvas.drawPath(
        Path()
          ..moveTo(x, top)
          ..lineTo(x + d, top - d * 0.6)
          ..lineTo(x + bw + d, top - d * 0.6)
          ..lineTo(x + bw, top)
          ..close(),
        Paint()..color = cap,
      );

      if (v > 0) {
        _text(canvas, '${(v * 100).round()}', Offset(x + bw / 2 + d / 2, top - d * 0.6 - 11),
            TextStyle(color: a(Colors.white, 0.85), fontSize: 11, fontWeight: FontWeight.w600));
      }

      _text(
        canvas,
        labels[i],
        Offset(x + bw / 2 + d / 2, size.height - 6),
        TextStyle(
          color: i == highlight ? Colors.white : a(Colors.white, 0.5),
          fontSize: 12,
          fontWeight: i == highlight ? FontWeight.w800 : FontWeight.w500,
        ),
      );
    }
  }

  @override
  bool shouldRepaint(_BarsPainter old) =>
      old.values != values || old.highlight != highlight;
}

// ── Confettis ──

class _Particle {
  _Particle(math.Random r)
      : angle = -math.pi * (0.1 + r.nextDouble() * 0.8),
        speed = 260 + r.nextDouble() * 520,
        size = 8 + r.nextDouble() * 9,
        rot = r.nextDouble() * math.pi,
        spin = (r.nextDouble() - 0.5) * 12,
        flip = 4 + r.nextDouble() * 8,
        color = Palette.habitColors[r.nextInt(Palette.habitColors.length)];

  final double angle, speed, size, rot, spin, flip;
  final Color color;
}

class ConfettiLayer extends StatefulWidget {
  const ConfettiLayer({super.key});

  @override
  State<ConfettiLayer> createState() => _ConfettiLayerState();
}

class _ConfettiLayerState extends State<ConfettiLayer>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c =
      AnimationController(vsync: this, duration: const Duration(milliseconds: 2600));
  final _rnd = math.Random();
  List<_Particle> _ps = const [];
  int _seen = 0;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final tick = StoreScope.of(context).celebrationTick;
    if (tick != _seen) {
      _seen = tick;
      _ps = List.generate(90, (_) => _Particle(_rnd));
      HapticFeedback.heavyImpact();
      _c.forward(from: 0);
    }
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return IgnorePointer(
      child: AnimatedBuilder(
        animation: _c,
        builder: (_, _) {
          if (!_c.isAnimating) return const SizedBox.shrink();
          return CustomPaint(
            size: Size.infinite,
            painter: _ConfettiPainter(_ps, _c.value),
          );
        },
      ),
    );
  }
}

class _ConfettiPainter extends CustomPainter {
  _ConfettiPainter(this.ps, this.t);
  final List<_Particle> ps;
  final double t;

  @override
  void paint(Canvas canvas, Size size) {
    final s = t * 2.6;
    final origin = Offset(size.width / 2, size.height * 0.4);
    final alpha = t < 0.7 ? 1.0 : 1 - (t - 0.7) / 0.3;
    for (final p in ps) {
      final pos = origin +
          Offset(math.cos(p.angle) * p.speed * s,
              math.sin(p.angle) * p.speed * s + 260 * s * s);
      final h = p.size * 0.6 * math.cos(s * p.flip).abs() + 1; // effet de retournement 3D
      canvas
        ..save()
        ..translate(pos.dx, pos.dy)
        ..rotate(p.rot + p.spin * s)
        ..drawRRect(
          RRect.fromRectAndRadius(
            Rect.fromCenter(center: Offset.zero, width: p.size, height: h),
            const Radius.circular(2),
          ),
          Paint()..color = a(p.color, alpha),
        )
        ..restore();
    }
  }

  @override
  bool shouldRepaint(_ConfettiPainter old) => old.t != t;
}

// ── Petits blocs réutilisables ──

class PageHeader extends StatelessWidget {
  const PageHeader({super.key, required this.title, this.subtitle});
  final String title;
  final String? subtitle;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(bottom: 20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(title, style: kTitle),
            if (subtitle != null) ...[
              const SizedBox(height: 6),
              Text(subtitle!, style: kMuted),
            ],
          ],
        ),
      );
}

class SectionTitle extends StatelessWidget {
  const SectionTitle(this.text, {super.key});
  final String text;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.fromLTRB(2, 26, 2, 12),
        child: Text(text,
            style: const TextStyle(fontSize: 19, fontWeight: FontWeight.w700, letterSpacing: -0.3)),
      );
}

class EmptyState extends StatelessWidget {
  const EmptyState({super.key, required this.icon, required this.text});
  final IconData icon;
  final String text;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 36),
        child: Column(
          children: [
            Icon(icon, size: 54, color: a(Colors.white, 0.35)),
            const SizedBox(height: 14),
            Text(text, textAlign: TextAlign.center, style: kMuted),
          ],
        ),
      );
}

class StatTile extends StatelessWidget {
  const StatTile({super.key, required this.icon, required this.color, required this.value, required this.label});
  final IconData icon;
  final Color color;
  final String value;
  final String label;

  @override
  Widget build(BuildContext context) => Tilt3D(
        maxAngle: 0.22,
        child: GlassCard(
          radius: 22,
          padding: const EdgeInsets.symmetric(vertical: 16, horizontal: 8),
          child: Column(
            children: [
              Icon(icon, color: color, size: 26),
              const SizedBox(height: 8),
              Text(value, style: const TextStyle(fontSize: 22, fontWeight: FontWeight.w800)),
              const SizedBox(height: 2),
              Text(label, style: TextStyle(fontSize: 11.5, color: a(Colors.white, 0.6))),
            ],
          ),
        ),
      );
}

/// Ligne d'habitude à cocher (Accueil et Aujourd'hui).
class HabitTile extends StatelessWidget {
  const HabitTile({super.key, required this.habit});
  final Habit habit;

  @override
  Widget build(BuildContext context) {
    final store = StoreScope.of(context);
    final done = store.isDone(habit, HabitStore.today());

    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Tilt3D(
        maxAngle: 0.1,
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: () {
            HapticFeedback.selectionClick();
            store.toggle(habit);
          },
          child: GlassCard(
            padding: const EdgeInsets.all(14),
            radius: 24,
            child: Row(
              children: [
                FlipBadge(icon: habit.iconData, color: habit.colorValue, done: done),
                const SizedBox(width: 16),
                Expanded(
                  child: AnimatedOpacity(
                    duration: const Duration(milliseconds: 300),
                    opacity: done ? 0.55 : 1,
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          habit.name,
                          style: TextStyle(
                            fontSize: 16.5,
                            fontWeight: FontWeight.w700,
                            decoration: done ? TextDecoration.lineThrough : null,
                            decorationColor: a(Colors.white, 0.6),
                          ),
                        ),
                        if (habit.goal.isNotEmpty) ...[
                          const SizedBox(height: 3),
                          Text(habit.goal, style: kMuted.copyWith(fontSize: 13)),
                        ],
                      ],
                    ),
                  ),
                ),
                AnimatedContainer(
                  duration: const Duration(milliseconds: 300),
                  width: 28,
                  height: 28,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: done ? Palette.lime : Colors.transparent,
                    border: Border.all(color: done ? Palette.lime : a(Colors.white, 0.3), width: 2),
                  ),
                  child: done
                      ? const Icon(Icons.check_rounded, size: 18, color: Palette.bg)
                      : null,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// 4. PAGES
// ─────────────────────────────────────────────────────────────────────────────

const _pagePadding = EdgeInsets.fromLTRB(20, 20, 20, 130);

class HomePage extends StatelessWidget {
  const HomePage({super.key, required this.onOpenToday});
  final VoidCallback onOpenToday;

  @override
  Widget build(BuildContext context) {
    final s = StoreScope.of(context);
    final now = HabitStore.today();
    final ratio = s.ratio(now);
    final pending = s.habits.where((h) => !s.isDone(h, now)).take(3).toList();

    return ListView(
      padding: _pagePadding,
      children: [
        Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('${greeting()} !', style: kTitle.copyWith(fontSize: 34)),
                  const SizedBox(height: 6),
                  Text('Construis de meilleures habitudes, un jour à la fois.', style: kMuted),
                ],
              ),
            ),
            const SizedBox(width: 12),
            Container(
              width: 50,
              height: 50,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                gradient: const LinearGradient(colors: [Palette.violet, Palette.pink]),
                boxShadow: [BoxShadow(color: a(Palette.pink, 0.45), blurRadius: 16)],
              ),
              child: Text('${s.level}',
                  style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w800)),
            ),
          ],
        ),
        const SizedBox(height: 24),
        Tilt3D(
          maxAngle: 0.1,
          child: GlassCard(
            padding: const EdgeInsets.fromLTRB(20, 20, 20, 22),
            radius: 32,
            child: Column(
              children: [
                Row(
                  children: [
                    const Icon(Icons.emoji_events_rounded, color: Palette.amber, size: 20),
                    const SizedBox(width: 8),
                    Text('Mon challenge · Jour ${s.challengeDay} / $kChallengeDays',
                        style: const TextStyle(fontWeight: FontWeight.w700)),
                  ],
                ),
                const SizedBox(height: 10),
                GradientBar(value: s.challengeDay / kChallengeDays, height: 6),
                const SizedBox(height: 26),
                HeroRing(value: ratio, caption: 'aujourd\'hui'),
                const SizedBox(height: 22),
                Text(
                  '${s.doneCount(now)} sur ${s.habits.length} habitudes terminées',
                  style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 16),
        Row(
          children: [
            Expanded(
              child: StatTile(
                  icon: Icons.local_fire_department_rounded,
                  color: Palette.amber,
                  value: '${s.streak}',
                  label: s.streak > 1 ? 'jours de série' : 'jour de série'),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: StatTile(
                  icon: Icons.bolt_rounded,
                  color: Palette.cyan,
                  value: '${s.xp}',
                  label: 'points XP'),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: StatTile(
                  icon: Icons.task_alt_rounded,
                  color: Palette.lime,
                  value: '${s.totalCompletions}',
                  label: 'validations'),
            ),
          ],
        ),
        const SectionTitle('À faire maintenant'),
        if (s.habits.isEmpty)
          const EmptyState(
              icon: Icons.add_task_rounded,
              text: 'Ajoute ta première habitude dans l\'onglet Habitudes.')
        else if (pending.isEmpty)
          const EmptyState(
              icon: Icons.celebration_rounded, text: 'Tout est terminé. Bravo pour aujourd\'hui !')
        else
          ...pending.map((h) => HabitTile(habit: h)),
        const SizedBox(height: 8),
        GradientButton(
          label: 'Commencer ma journée',
          icon: Icons.play_arrow_rounded,
          onTap: onOpenToday,
        ),
      ],
    );
  }
}

class HabitsPage extends StatelessWidget {
  const HabitsPage({super.key});

  void _delete(BuildContext context, HabitStore s, Habit h) {
    final messenger = ScaffoldMessenger.of(context);
    final index = s.remove(h);
    HapticFeedback.mediumImpact();
    messenger
      ..clearSnackBars()
      ..showSnackBar(SnackBar(
        content: Text('« ${h.name} » supprimée'),
        margin: const EdgeInsets.fromLTRB(16, 0, 16, 110),
        action: SnackBarAction(label: 'Annuler', onPressed: () => s.restore(h, index)),
      ));
  }

  @override
  Widget build(BuildContext context) {
    final s = StoreScope.of(context);

    return ListView(
      padding: _pagePadding,
      children: [
        PageHeader(
          title: 'Mes habitudes',
          subtitle: s.habits.isEmpty
              ? 'Crée les habitudes de ton challenge de $kChallengeDays jours.'
              : '${s.habits.length} habitudes dans ton challenge. Glisse vers la gauche pour supprimer.',
        ),
        GradientButton(
          label: 'Ajouter une habitude',
          icon: Icons.add_rounded,
          onTap: () => showHabitEditor(context),
        ),
        const SizedBox(height: 20),
        if (s.habits.isEmpty)
          const EmptyState(
              icon: Icons.checklist_rounded, text: 'Aucune habitude pour le moment.'),
        ...s.habits.map((h) {
          final days = s.lastDays(7);
          return Padding(
            padding: const EdgeInsets.only(bottom: 12),
            child: Dismissible(
              key: ValueKey(h.id),
              direction: DismissDirection.endToStart,
              onDismissed: (_) => _delete(context, s, h),
              background: Container(
                alignment: Alignment.centerRight,
                padding: const EdgeInsets.only(right: 26),
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(24),
                  color: a(Palette.coral, 0.35),
                ),
                child: const Icon(Icons.delete_rounded, color: Colors.white, size: 28),
              ),
              child: Tilt3D(
                maxAngle: 0.1,
                child: GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTap: () => showHabitEditor(context, habit: h),
                  child: GlassCard(
                    radius: 24,
                    padding: const EdgeInsets.all(14),
                    child: Row(
                      children: [
                        FlipBadge(icon: h.iconData, color: h.colorValue, done: false),
                        const SizedBox(width: 16),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(h.name,
                                  style: const TextStyle(fontSize: 16.5, fontWeight: FontWeight.w700)),
                              if (h.goal.isNotEmpty)
                                Padding(
                                  padding: const EdgeInsets.only(top: 3),
                                  child: Text(h.goal, style: kMuted.copyWith(fontSize: 13)),
                                ),
                              const SizedBox(height: 10),
                              Row(
                                children: [
                                  for (final d in days)
                                    Container(
                                      width: 14,
                                      height: 14,
                                      margin: const EdgeInsets.only(right: 6),
                                      decoration: BoxDecoration(
                                        borderRadius: BorderRadius.circular(5),
                                        color: s.isDone(h, d)
                                            ? h.colorValue
                                            : a(Colors.white, 0.12),
                                      ),
                                    ),
                                ],
                              ),
                            ],
                          ),
                        ),
                        Icon(Icons.edit_rounded, color: a(Colors.white, 0.4), size: 20),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          );
        }),
      ],
    );
  }
}

class TodayPage extends StatelessWidget {
  const TodayPage({super.key});

  String _message(double r) {
    if (r == 0) return 'Lance-toi : la première habitude est la plus facile.';
    if (r < 0.5) return 'Bon début, continue sur ta lancée.';
    if (r < 1) return 'Plus que quelques-unes pour une journée parfaite.';
    return 'Journée parfaite ! Reviens demain pour prolonger ta série.';
  }

  @override
  Widget build(BuildContext context) {
    final s = StoreScope.of(context);
    final now = HabitStore.today();
    final r = s.ratio(now);

    return ListView(
      padding: _pagePadding,
      children: [
        PageHeader(title: "Aujourd'hui", subtitle: frenchDate(now)),
        Tilt3D(
          maxAngle: 0.08,
          child: GlassCard(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Text('Habitudes terminées',
                          style: const TextStyle(fontWeight: FontWeight.w700)),
                    ),
                    Text('${s.doneCount(now)}/${s.habits.length}',
                        style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w800)),
                  ],
                ),
                const SizedBox(height: 14),
                GradientBar(value: r, height: 12),
                const SizedBox(height: 12),
                Text(_message(r), style: kMuted),
              ],
            ),
          ),
        ),
        const SizedBox(height: 20),
        if (s.habits.isEmpty)
          const EmptyState(
              icon: Icons.add_task_rounded,
              text: 'Aucune habitude à suivre. Ajoute-en dans l\'onglet Habitudes.'),
        ...s.habits.map((h) => HabitTile(habit: h)),
      ],
    );
  }
}

class _Achievement {
  const _Achievement(this.title, this.desc, this.icon, this.unlocked);
  final String title;
  final String desc;
  final IconData icon;
  final bool unlocked;
}

class ProgressPage extends StatelessWidget {
  const ProgressPage({super.key});

  Future<void> _confirmRestart(BuildContext context, HabitStore s) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: Palette.surface,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
        title: const Text('Relancer le challenge ?'),
        content: const Text(
            'Le compteur repart au jour 1. Ton historique et tes points sont conservés.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Annuler')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Relancer')),
        ],
      ),
    );
    if (ok == true) s.restartChallenge();
  }

  @override
  Widget build(BuildContext context) {
    final s = StoreScope.of(context);
    final days = s.lastDays(7);
    final now = HabitStore.today();

    final achievements = [
      _Achievement('Premier pas', 'Valider une habitude', Icons.flag_rounded, s.totalCompletions >= 1),
      _Achievement('Journée parfaite', 'Tout valider en un jour', Icons.auto_awesome, s.hasPerfectDay),
      _Achievement('Trio', '3 jours de série', Icons.local_fire_department, s.streak >= 3),
      _Achievement('Semaine de feu', '7 jours de série', Icons.whatshot, s.streak >= 7),
      _Achievement('Centurion', '100 validations', Icons.emoji_events, s.totalCompletions >= 100),
      _Achievement('Niveau 5', 'Atteindre le niveau 5', Icons.rocket_launch, s.level >= 5),
    ];

    // Grille de 5 semaines alignée sur les lundis.
    final gridStart = HabitStore.shift(now, -(now.weekday - 1) - 28);

    return ListView(
      padding: _pagePadding,
      children: [
        const PageHeader(title: 'Ma progression'),
        Tilt3D(
          maxAngle: 0.07,
          child: GlassCard(
            padding: const EdgeInsets.fromLTRB(18, 18, 18, 14),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    const Expanded(
                      child: Text('Cette semaine',
                          style: TextStyle(fontSize: 17, fontWeight: FontWeight.w700)),
                    ),
                    Text('moyenne ${(s.weekAverage * 100).round()} %', style: kMuted),
                  ],
                ),
                const SizedBox(height: 18),
                IsoBars(
                  values: days.map(s.ratio).toList(),
                  labels: days.map((d) => _weekdays[d.weekday - 1][0]).toList(),
                  highlight: days.length - 1,
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 16),
        GlassCard(
          child: Row(
            children: [
              Container(
                width: 58,
                height: 58,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  gradient: const LinearGradient(colors: [Palette.violet, Palette.pink]),
                  boxShadow: [BoxShadow(color: a(Palette.pink, 0.4), blurRadius: 16)],
                ),
                child: Text('${s.level}',
                    style: const TextStyle(fontSize: 24, fontWeight: FontWeight.w800)),
              ),
              const SizedBox(width: 16),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('Niveau ${s.level}',
                        style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w700)),
                    const SizedBox(height: 10),
                    GradientBar(value: s.levelProgress, height: 8),
                    const SizedBox(height: 8),
                    Text('${100 - s.xp % 100} XP avant le niveau suivant',
                        style: kMuted.copyWith(fontSize: 12.5)),
                  ],
                ),
              ),
            ],
          ),
        ),
        const SectionTitle('Les 5 dernières semaines'),
        GlassCard(
          child: Column(
            children: [
              Row(
                children: [
                  for (final l in ['L', 'M', 'M', 'J', 'V', 'S', 'D'])
                    Expanded(
                      child: Center(
                        child: Text(l, style: kMuted.copyWith(fontSize: 12)),
                      ),
                    ),
                ],
              ),
              const SizedBox(height: 8),
              for (var w = 0; w < 5; w++)
                Row(
                  children: [
                    for (var d = 0; d < 7; d++)
                      Expanded(
                        child: _HeatCell(
                          date: HabitStore.shift(gridStart, w * 7 + d),
                          today: now,
                          store: s,
                        ),
                      ),
                  ],
                ),
            ],
          ),
        ),
        const SectionTitle('Succès'),
        GridView.count(
          crossAxisCount: 3,
          shrinkWrap: true,
          physics: const NeverScrollableScrollPhysics(),
          mainAxisSpacing: 12,
          crossAxisSpacing: 12,
          childAspectRatio: 0.88,
          children: achievements.map((x) => _AchievementBadge(x)).toList(),
        ),
        const SectionTitle('Challenge de 30 jours'),
        GlassCard(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  const Icon(Icons.calendar_month_rounded, color: Palette.cyan),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Text('Jour ${s.challengeDay} sur $kChallengeDays',
                        style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
                  ),
                ],
              ),
              const SizedBox(height: 14),
              GradientBar(value: s.challengeDay / kChallengeDays),
              const SizedBox(height: 6),
              Align(
                alignment: Alignment.centerRight,
                child: TextButton.icon(
                  onPressed: () => _confirmRestart(context, s),
                  icon: const Icon(Icons.restart_alt_rounded, size: 18),
                  label: const Text('Relancer'),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _HeatCell extends StatelessWidget {
  const _HeatCell({required this.date, required this.today, required this.store});
  final DateTime date;
  final DateTime today;
  final HabitStore store;

  @override
  Widget build(BuildContext context) {
    final future = date.isAfter(today);
    final r = future ? 0.0 : store.ratio(date);
    final isToday = date == today;
    return Padding(
      padding: const EdgeInsets.all(3),
      child: AspectRatio(
        aspectRatio: 1,
        child: Container(
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(9),
            color: future
                ? a(Colors.white, 0.025)
                : (r == 0
                    ? a(Colors.white, 0.07)
                    : Color.lerp(a(Palette.violet, 0.45), Palette.cyan, r)),
            border: isToday ? Border.all(color: Colors.white, width: 1.6) : null,
          ),
        ),
      ),
    );
  }
}

class _AchievementBadge extends StatelessWidget {
  const _AchievementBadge(this.data);
  final _Achievement data;

  @override
  Widget build(BuildContext context) {
    return Tilt3D(
      maxAngle: 0.25,
      child: Opacity(
        opacity: data.unlocked ? 1 : 0.4,
        child: GlassCard(
          radius: 22,
          padding: const EdgeInsets.all(10),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Container(
                width: 44,
                height: 44,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  gradient: LinearGradient(
                    colors: data.unlocked
                        ? [Palette.amber, Palette.coral]
                        : [a(Colors.white, 0.25), a(Colors.white, 0.1)],
                  ),
                  boxShadow: data.unlocked
                      ? [BoxShadow(color: a(Palette.amber, 0.5), blurRadius: 14)]
                      : null,
                ),
                child: Icon(data.unlocked ? data.icon : Icons.lock_rounded,
                    color: Colors.white, size: 22),
              ),
              const SizedBox(height: 8),
              Text(data.title,
                  textAlign: TextAlign.center,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 12.5, fontWeight: FontWeight.w700)),
              const SizedBox(height: 2),
              Text(data.desc,
                  textAlign: TextAlign.center,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontSize: 10.5, color: a(Colors.white, 0.6))),
            ],
          ),
        ),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// 5. ÉDITEUR D'HABITUDE ET NAVIGATION
// ─────────────────────────────────────────────────────────────────────────────

Future<void> showHabitEditor(BuildContext context, {Habit? habit}) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.transparent,
    builder: (_) => HabitEditor(habit: habit),
  );
}

class HabitEditor extends StatefulWidget {
  const HabitEditor({super.key, this.habit});
  final Habit? habit;

  @override
  State<HabitEditor> createState() => _HabitEditorState();
}

class _HabitEditorState extends State<HabitEditor> {
  late final TextEditingController _name =
      TextEditingController(text: widget.habit?.name ?? '');
  late final TextEditingController _goal =
      TextEditingController(text: widget.habit?.goal ?? '');
  late int _icon = widget.habit?.icon ?? 0;
  late int _color = widget.habit?.color ?? 0;
  String? _error;

  @override
  void dispose() {
    _name.dispose();
    _goal.dispose();
    super.dispose();
  }

  InputDecoration _decoration(String label, String hint, {String? error}) => InputDecoration(
        labelText: label,
        hintText: hint,
        errorText: error,
        filled: true,
        fillColor: a(Colors.white, 0.06),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(16),
          borderSide: BorderSide.none,
        ),
      );

  void _save() {
    final name = _name.text.trim();
    if (name.isEmpty) {
      setState(() => _error = 'Donne un nom à ton habitude.');
      return;
    }
    final store = StoreScope.of(context);
    final goal = _goal.text.trim();
    if (widget.habit == null) {
      store.add(name, goal, _icon, _color);
    } else {
      store.update(widget.habit!, name, goal, _icon, _color);
    }
    HapticFeedback.lightImpact();
    Navigator.pop(context);
  }

  @override
  Widget build(BuildContext context) {
    final editing = widget.habit != null;
    return Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(context).bottom),
      child: Container(
        padding: const EdgeInsets.fromLTRB(24, 12, 24, 28),
        decoration: BoxDecoration(
          color: Palette.surface,
          borderRadius: const BorderRadius.vertical(top: Radius.circular(32)),
          border: Border(top: BorderSide(color: a(Colors.white, 0.14))),
        ),
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Center(
                child: Container(
                  width: 42,
                  height: 4,
                  decoration: BoxDecoration(
                    color: a(Colors.white, 0.25),
                    borderRadius: BorderRadius.circular(4),
                  ),
                ),
              ),
              const SizedBox(height: 20),
              Text(editing ? 'Modifier l\'habitude' : 'Nouvelle habitude',
                  style: kTitle.copyWith(fontSize: 24)),
              const SizedBox(height: 20),
              TextField(
                controller: _name,
                autofocus: !editing,
                textCapitalization: TextCapitalization.sentences,
                onChanged: (_) => setState(() => _error = null),
                decoration: _decoration('Nom', 'Ex. : Méditer 10 minutes', error: _error),
              ),
              const SizedBox(height: 14),
              TextField(
                controller: _goal,
                decoration: _decoration('Objectif (facultatif)', 'Ex. : 10 minutes'),
              ),
              const SizedBox(height: 22),
              const Text('Icône', style: TextStyle(fontWeight: FontWeight.w700)),
              const SizedBox(height: 10),
              Wrap(
                spacing: 10,
                runSpacing: 10,
                children: [
                  for (var i = 0; i < kIcons.length; i++)
                    GestureDetector(
                      onTap: () => setState(() => _icon = i),
                      child: AnimatedContainer(
                        duration: const Duration(milliseconds: 200),
                        width: 46,
                        height: 46,
                        decoration: BoxDecoration(
                          borderRadius: BorderRadius.circular(15),
                          color: _icon == i
                              ? a(Palette.habitColors[_color], 0.3)
                              : a(Colors.white, 0.06),
                          border: Border.all(
                            color: _icon == i ? Palette.habitColors[_color] : Colors.transparent,
                            width: 1.8,
                          ),
                        ),
                        child: Icon(kIcons[i], size: 22),
                      ),
                    ),
                ],
              ),
              const SizedBox(height: 22),
              const Text('Couleur', style: TextStyle(fontWeight: FontWeight.w700)),
              const SizedBox(height: 10),
              Row(
                children: [
                  for (var i = 0; i < Palette.habitColors.length; i++)
                    GestureDetector(
                      onTap: () => setState(() => _color = i),
                      child: AnimatedContainer(
                        duration: const Duration(milliseconds: 200),
                        width: 38,
                        height: 38,
                        margin: const EdgeInsets.only(right: 12),
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          color: Palette.habitColors[i],
                          border: Border.all(
                            color: _color == i ? Colors.white : Colors.transparent,
                            width: 2.5,
                          ),
                          boxShadow: _color == i
                              ? [BoxShadow(color: a(Palette.habitColors[i], 0.6), blurRadius: 12)]
                              : null,
                        ),
                      ),
                    ),
                ],
              ),
              const SizedBox(height: 28),
              GradientButton(
                label: editing ? 'Enregistrer' : 'Ajouter l\'habitude',
                icon: Icons.check_rounded,
                onTap: _save,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _NavItem {
  const _NavItem(this.icon, this.label);
  final IconData icon;
  final String label;
}

class FloatingNav extends StatelessWidget {
  const FloatingNav({super.key, required this.index, required this.onChanged});
  final int index;
  final ValueChanged<int> onChanged;

  static const _items = [
    _NavItem(Icons.home_rounded, 'Accueil'),
    _NavItem(Icons.checklist_rounded, 'Habitudes'),
    _NavItem(Icons.today_rounded, "Aujourd'hui"),
    _NavItem(Icons.bar_chart_rounded, 'Progression'),
  ];

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(32),
        boxShadow: [BoxShadow(color: a(Colors.black, 0.5), blurRadius: 30, offset: const Offset(0, 12))],
      ),
      child: GlassCard(
        radius: 32,
        padding: const EdgeInsets.all(8),
        child: Row(
          children: [
            for (var i = 0; i < _items.length; i++)
              Expanded(
                child: GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTap: () {
                    if (i != index) HapticFeedback.selectionClick();
                    onChanged(i);
                  },
                  child: AnimatedContainer(
                    duration: const Duration(milliseconds: 320),
                    curve: Curves.easeOutCubic,
                    padding: const EdgeInsets.symmetric(vertical: 10),
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(24),
                      gradient: i == index
                          ? const LinearGradient(colors: [Palette.violet, Palette.cyan])
                          : null,
                      boxShadow: i == index
                          ? [BoxShadow(color: a(Palette.violet, 0.55), blurRadius: 16, offset: const Offset(0, 6))]
                          : null,
                    ),
                    child: AnimatedScale(
                      scale: i == index ? 1.06 : 1,
                      duration: const Duration(milliseconds: 320),
                      curve: Curves.easeOutBack,
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(_items[i].icon,
                              size: 24,
                              color: i == index ? Colors.white : a(Colors.white, 0.55)),
                          const SizedBox(height: 3),
                          Text(
                            _items[i].label,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontSize: 10.5,
                              fontWeight: i == index ? FontWeight.w800 : FontWeight.w500,
                              color: i == index ? Colors.white : a(Colors.white, 0.55),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class Shell extends StatefulWidget {
  const Shell({super.key});

  @override
  State<Shell> createState() => _ShellState();
}

class _ShellState extends State<Shell> {
  int _index = 0;

  @override
  Widget build(BuildContext context) {
    final pages = <Widget>[
      HomePage(onOpenToday: () => setState(() => _index = 2)),
      const HabitsPage(),
      const TodayPage(),
      const ProgressPage(),
    ];

    return Scaffold(
      backgroundColor: Palette.bg,
      body: AuroraBackground(
        child: Stack(
          children: [
            SafeArea(
              bottom: false,
              child: AnimatedSwitcher(
                duration: const Duration(milliseconds: 350),
                transitionBuilder: (child, anim) => FadeTransition(
                  opacity: anim,
                  child: SlideTransition(
                    position: Tween<Offset>(begin: const Offset(0, 0.03), end: Offset.zero)
                        .animate(anim),
                    child: child,
                  ),
                ),
                child: KeyedSubtree(key: ValueKey(_index), child: pages[_index]),
              ),
            ),
            Align(
              alignment: Alignment.bottomCenter,
              child: SafeArea(
                top: false,
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
                  child: FloatingNav(
                    index: _index,
                    onChanged: (i) => setState(() => _index = i),
                  ),
                ),
              ),
            ),
            const Positioned.fill(child: ConfettiLayer()),
          ],
        ),
      ),
    );
  }
}

class Splash extends StatelessWidget {
  const Splash({super.key});

  @override
  Widget build(BuildContext context) => const Scaffold(
        backgroundColor: Palette.bg,
        body: Center(child: CircularProgressIndicator(color: Palette.violet)),
      );
}

// ─────────────────────────────────────────────────────────────────────────────
// POINT D'ENTRÉE
// ─────────────────────────────────────────────────────────────────────────────

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  SystemChrome.setSystemUIOverlayStyle(const SystemUiOverlayStyle(
    statusBarColor: Colors.transparent,
    statusBarIconBrightness: Brightness.light,
    systemNavigationBarColor: Colors.transparent,
    systemNavigationBarIconBrightness: Brightness.light,
  ));
  runApp(const HabitUpApp());
}

class HabitUpApp extends StatefulWidget {
  const HabitUpApp({super.key});

  @override
  State<HabitUpApp> createState() => _HabitUpAppState();
}

class _HabitUpAppState extends State<HabitUpApp> {
  final HabitStore _store = HabitStore();

  @override
  void initState() {
    super.initState();
    _store.load();
  }

  @override
  void dispose() {
    _store.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final base = ThemeData(
      useMaterial3: true,
      brightness: Brightness.dark,
      colorScheme: ColorScheme.fromSeed(
        seedColor: Palette.violet,
        brightness: Brightness.dark,
      ),
      scaffoldBackgroundColor: Palette.bg,
    );

    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'HabitUp',
      theme: base.copyWith(
        snackBarTheme: SnackBarThemeData(
          behavior: SnackBarBehavior.floating,
          backgroundColor: Palette.surface,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        ),
      ),
      // Le store est placé au-dessus du Navigator : pages, dialogues et feuilles y ont accès.
      builder: (context, child) => StoreScope(store: _store, child: child!),
      home: ListenableBuilder(
        listenable: _store,
        builder: (_, _) => _store.ready ? const Shell() : const Splash(),
      ),
    );
  }
}