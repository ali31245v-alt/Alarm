import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:image_picker/image_picker.dart';
import 'package:google_mlkit_image_labeling/google_mlkit_image_labeling.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:timezone/data/latest.dart' as tzdata;
import 'package:timezone/timezone.dart' as tz;

const bg = Color(0xFF0D0B17);
const panel = Color(0xFF19152A);
const purple = Color(0xFF9B7BFF);
const softPurple = Color(0xFF2C2349);
final notifications = FlutterLocalNotificationsPlugin();
final navigatorKey = GlobalKey<NavigatorState>();
const ringtoneChannel = MethodChannel('smart_alarm/ringtone');
const challengeTargets = <String, List<String>>{
  'فرشاة الأسنان': ['toothbrush', 'brush', 'dental'],
  'المغسلة': ['sink', 'faucet', 'washbasin', 'bathroom'],
  'كوب ماء': ['cup', 'mug', 'glass', 'water bottle', 'bottle'],
  'السرير': ['bed', 'pillow', 'bedroom', 'mattress'],
  'الباب': ['door', 'doorknob'],
  'الحذاء': ['shoe', 'footwear', 'sneaker', 'boot'],
  'المكتب': ['desk', 'table', 'computer desk'],
  'المرحاض': ['toilet', 'bathroom'],
};
void openChallengeFromPayload(String? payload) {
  if (payload == null || payload.isEmpty) return;
  navigatorKey.currentState?.push(MaterialPageRoute(
    builder: (_) => AlarmChallengeScreen(target: challengeTargets.containsKey(payload) ? payload : 'فرشاة الأسنان'),
  ));
}

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  tzdata.initializeTimeZones();
  const settings = InitializationSettings(
    android: AndroidInitializationSettings('@mipmap/ic_launcher'),
    iOS: DarwinInitializationSettings(),
  );
  await notifications.initialize(settings,
    onDidReceiveNotificationResponse: (response) => openChallengeFromPayload(response.payload));
  final launchDetails = await notifications.getNotificationAppLaunchDetails();
  final androidNotifications = notifications.resolvePlatformSpecificImplementation<
      AndroidFlutterLocalNotificationsPlugin>();
  await androidNotifications?.requestNotificationsPermission();
  await androidNotifications?.requestExactAlarmsPermission();
  runApp(const SmartAlarmApp());
  if (launchDetails?.didNotificationLaunchApp == true) {
    WidgetsBinding.instance.addPostFrameCallback((_) =>
      openChallengeFromPayload(launchDetails?.notificationResponse?.payload));
  }
}

class AlarmItem {
  AlarmItem(this.id, this.hour, this.minute, this.label, this.enabled, this.days, this.target);
  final int id;
  int hour;
  int minute;
  String label;
  bool enabled;
  List<int> days;
  String target;

  Map<String, dynamic> toJson() => {
    'id': id, 'hour': hour, 'minute': minute, 'label': label,
    'enabled': enabled, 'days': days, 'target': target,
  };

  factory AlarmItem.fromJson(Map<String, dynamic> j) => AlarmItem(
    j['id'] as int, j['hour'] as int, j['minute'] as int,
    j['label'] as String? ?? 'منبّه', j['enabled'] as bool? ?? true,
    (j['days'] as List<dynamic>? ?? []).cast<int>(),
    j['target'] as String? ?? 'فرشاة الأسنان',
  );
}

class AlarmStore extends ChangeNotifier {
  final alarms = <AlarmItem>[];
  int nextId = 1;

  Future<void> load() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString('alarms_v1');
    if (raw != null) {
      try {
        alarms.addAll((jsonDecode(raw) as List<dynamic>).map(
          (e) => AlarmItem.fromJson(e as Map<String, dynamic>)));

        if (alarms.isNotEmpty) {
          nextId = alarms.map((a) => a.id).reduce((a, b) => a > b ? a : b) + 1;
        }
      } catch (_) {}
    }
    notifyListeners();
  }

  Future<void> save() async {
    final p = await SharedPreferences.getInstance();
    await p.setString('alarms_v1', jsonEncode(alarms.map((a) => a.toJson()).toList()));
  }

  Future<void> add(int h, int m, String label, List<int> days, String target) async {
    final a = AlarmItem(nextId++, h, m, label.trim().isEmpty ? 'منبّه' : label.trim(), true, days, target);
    alarms.add(a);
    await schedule(a);
    await save();
    notifyListeners();
  }

  Future<void> toggle(AlarmItem a, bool value) async {
    a.enabled = value;
    if (value) {
      await schedule(a);
    } else {
      await notifications.cancel(a.id);
      for (final d in a.days) { await notifications.cancel(a.id * 10 + d); }
    }
    await save();
    notifyListeners();
  }

  Future<void> remove(AlarmItem a) async {
    alarms.remove(a);
    await notifications.cancel(a.id);
    for (final d in a.days) { await notifications.cancel(a.id * 10 + d); }
    await save();
    notifyListeners();
  }

  Future<void> schedule(AlarmItem a) async {
    await notifications.cancel(a.id);
    final now = DateTime.now();
    var next = DateTime(now.year, now.month, now.day, a.hour, a.minute);
    if (!next.isAfter(now)) next = next.add(const Duration(days: 1));
    const details = NotificationDetails(android: AndroidNotificationDetails(
      'smart_alarm_channel', 'المنبّهات',
      channelDescription: 'تنبيهات تطبيق المنبّه الذكي',
      importance: Importance.max, priority: Priority.max,
      category: AndroidNotificationCategory.alarm,
      fullScreenIntent: true, ongoing: true, autoCancel: false,
      visibility: NotificationVisibility.public,
    ));
    if (a.days.isEmpty) {
      await notifications.zonedSchedule(
        a.id, a.label, 'حان وقت المنبّه ⏰', tz.TZDateTime.from(next, tz.local),
        details, payload: a.target, androidScheduleMode: AndroidScheduleMode.exactAllowWhileIdle,
        uiLocalNotificationDateInterpretation: UILocalNotificationDateInterpretation.absoluteTime,
      );
    } else {
      for (final d in a.days) {
        var date = DateTime(now.year, now.month, now.day, a.hour, a.minute);
        var delta = (d - date.weekday) % 7;
        if (delta == 0 && !date.isAfter(now)) delta = 7;
        date = date.add(Duration(days: delta));
        await notifications.zonedSchedule(
          a.id * 10 + d, a.label, 'حان وقت المنبّه ⏰',
          tz.TZDateTime.from(date, tz.local), details, payload: a.target,
          androidScheduleMode: AndroidScheduleMode.exactAllowWhileIdle,
          uiLocalNotificationDateInterpretation: UILocalNotificationDateInterpretation.absoluteTime,
          matchDateTimeComponents: DateTimeComponents.dayOfWeekAndTime,
        );
      }
    }
  }
}


class AlarmChallengeScreen extends StatefulWidget {
  const AlarmChallengeScreen({super.key, required this.target});
  final String target;
  @override State<AlarmChallengeScreen> createState() => _AlarmChallengeScreenState();
}
class _AlarmChallengeScreenState extends State<AlarmChallengeScreen> {
  bool checking = false;
  @override void initState() { super.initState(); ringtoneChannel.invokeMethod('start').catchError((_) {}); }
  Future<void> stopRinging() async { try { await ringtoneChannel.invokeMethod('stop'); } catch (_) {} }
  @override void dispose() { stopRinging(); super.dispose(); }
  String message = 'التقط صورة واضحة للشيء الذي اخترته.';
  Future<void> takePhoto() async {
    if (checking) return;
    setState(() { checking = true; message = 'جارٍ فحص الصورة…'; });
    try {
      final photo = await ImagePicker().pickImage(source: ImageSource.camera, imageQuality: 82);
      if (photo == null) {
        if (mounted) setState(() { checking = false; message = 'لم تُلتقط صورة. حاول مجدداً.'; });
        return;
      }
      final aliases = challengeTargets[widget.target] ?? [widget.target.toLowerCase()];
      final labeler = ImageLabeler(options: ImageLabelerOptions(confidenceThreshold: 0.40));
      try {
        final labels = await labeler.processImage(InputImage.fromFilePath(photo.path));
        final found = labels.any((label) {
          final text = label.label.toLowerCase();
          return aliases.any((alias) => text.contains(alias) || alias.contains(text));
        });
        if (!mounted) return;
        if (found) {
          setState(() { checking = false; message = 'تم التعرّف على الهدف بنجاح!'; });
          await stopRinging();
          await Future.delayed(const Duration(milliseconds: 650));
          if (mounted) Navigator.of(context).pop();
        } else {
          setState(() { checking = false; message = 'لم نتعرّف على ${widget.target}. جرّب إضاءة أوضح أو زاوية مختلفة.'; });
        }
      } finally {
        await labeler.close();
      }
    } catch (_) {
      if (mounted) setState(() { checking = false; message = 'تعذّر فحص الصورة. تحقق من إذن الكاميرا وحاول مجدداً.'; });
    }
  }
  @override Widget build(BuildContext context) => Directionality(
    textDirection: TextDirection.rtl,
    child: PopScope(canPop: false, child: Scaffold(
      backgroundColor: const Color(0xFF0D0B17),
      body: SafeArea(child: Padding(padding: const EdgeInsets.all(24), child: Column(
        mainAxisAlignment: MainAxisAlignment.center, children: [
          Container(width: 100, height: 100, decoration: BoxDecoration(
            color: const Color(0xFF2C2349), borderRadius: BorderRadius.circular(30)),
            child: const Icon(Icons.camera_alt_rounded, color: Color(0xFF9B7BFF), size: 52)),
          const SizedBox(height: 28),
          const Text('حان وقت الاستيقاظ', textAlign: TextAlign.center,
            style: TextStyle(fontSize: 27, fontWeight: FontWeight.bold)),
          const SizedBox(height: 12),
          Text('التحدّي: صوّر ${widget.target}', textAlign: TextAlign.center,
            style: const TextStyle(fontSize: 19, color: Color(0xFFC7B8FF))),
          const SizedBox(height: 18),
          Container(width: double.infinity, padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(color: const Color(0xFF19152A), borderRadius: BorderRadius.circular(18)),
            child: Text(message, textAlign: TextAlign.center, style: const TextStyle(color: Colors.white70))),
          const SizedBox(height: 24),
          SizedBox(width: double.infinity, height: 58, child: FilledButton.icon(
            onPressed: checking ? null : takePhoto,
            style: FilledButton.styleFrom(backgroundColor: const Color(0xFF9B7BFF),
              foregroundColor: const Color(0xFF160E2C), shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18))),
            icon: checking ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2))
              : const Icon(Icons.camera_alt_rounded),
            label: Text(checking ? 'جارٍ التحقق…' : 'فتح الكاميرا والتصوير', style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
          )),
          const SizedBox(height: 12),
          const Text('يتم فحص الصورة على الجهاز، وقد يخطئ التعرّف حسب الإضاءة وزاوية التصوير.',
            textAlign: TextAlign.center, style: TextStyle(color: Colors.white38, fontSize: 12)),
        ],
      ))),
    )),
  );
}

class SmartAlarmApp extends StatefulWidget {
  const SmartAlarmApp({super.key});
  @override State<SmartAlarmApp> createState() => _SmartAlarmAppState();
}
class _SmartAlarmAppState extends State<SmartAlarmApp> {
  final store = AlarmStore();
  @override void initState() { super.initState(); store.load(); }
  @override void dispose() { store.dispose(); super.dispose(); }
  @override Widget build(BuildContext context) => AnimatedBuilder(
    animation: store,
    builder: (_, __) => MaterialApp(
      debugShowCheckedModeBanner: false,
      navigatorKey: navigatorKey,
      title: 'المنبّه الذكي',
      theme: ThemeData(useMaterial3: true, brightness: Brightness.dark,
        scaffoldBackgroundColor: bg,
        colorScheme: ColorScheme.fromSeed(seedColor: purple, brightness: Brightness.dark)),
      home: HomeScreen(store: store),
    ),
  );
}

class HomeScreen extends StatelessWidget {
  const HomeScreen({super.key, required this.store});
  final AlarmStore store;
  @override Widget build(BuildContext context) {
    final now = DateTime.now();
    final hour = (now.hour % 12 == 0 ? 12 : now.hour % 12).toString().padLeft(2, '0');
    final clock = hour + ':' + now.minute.toString().padLeft(2, '0');
    final active = store.alarms.where((a) => a.enabled).length;
    return Directionality(textDirection: TextDirection.rtl, child: Scaffold(
      body: SafeArea(child: ListView(padding: const EdgeInsets.fromLTRB(22, 18, 22, 28), children: [
        Row(children: [
          Container(width: 48, height: 48, decoration: BoxDecoration(color: softPurple, borderRadius: BorderRadius.circular(16)),
            child: const Icon(Icons.alarm_rounded, color: purple, size: 29)),
          const SizedBox(width: 12),
          const Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text('المنبّه الذكي', style: TextStyle(fontSize: 21, fontWeight: FontWeight.bold)),
            SizedBox(height: 3), Text('ابدأ يومك على طريقتك', style: TextStyle(color: Colors.white60)),
          ])),
          IconButton(onPressed: () => showAboutDialog(context: context, applicationName: 'المنبّه الذكي',
            applicationVersion: '1.0.0', children: const [Text('منبّه عربي بتصميم بنفسجي هادئ.')]),
            icon: const Icon(Icons.info_outline_rounded)),
        ]),
        const SizedBox(height: 28),
        Container(padding: const EdgeInsets.all(24), decoration: BoxDecoration(
          gradient: const LinearGradient(colors: [Color(0xFF33245C), Color(0xFF1C1730)], begin: Alignment.topRight, end: Alignment.bottomLeft),
          borderRadius: BorderRadius.circular(28), border: Border.all(color: purple.withOpacity(.25))),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            const Text('الوقت الآن', style: TextStyle(color: Colors.white70)),
            const SizedBox(height: 8),
            Row(crossAxisAlignment: CrossAxisAlignment.end, children: [
              Text(clock, style: const TextStyle(fontSize: 52, height: 1.1, fontWeight: FontWeight.w300)),
              const SizedBox(width: 10),
              Padding(padding: const EdgeInsets.only(bottom: 8),
                child: Text(now.hour >= 12 ? 'مساءً' : 'صباحاً', style: const TextStyle(color: Color(0xFFC7B8FF)))),
            ]),
            const SizedBox(height: 20),
            Row(children: [
              const Icon(Icons.notifications_active_outlined, color: Color(0xFFC7B8FF), size: 19),
              const SizedBox(width: 8), Text(active.toString() + ' منبّهات مفعّلة', style: const TextStyle(color: Colors.white70)),
              const Spacer(), Text(now.day.toString() + '/' + now.month.toString() + '/' + now.year.toString(), style: const TextStyle(color: Colors.white54)),
            ]),
          ]),
        ),
        const SizedBox(height: 28),
        Row(children: [
          const Expanded(child: Text('منبّهاتي', style: TextStyle(fontSize: 22, fontWeight: FontWeight.bold))),
          Text(store.alarms.length.toString() + ' منبّه', style: const TextStyle(color: Colors.white54)),
        ]),
        const SizedBox(height: 14),
        if (store.alarms.isEmpty) Container(padding: const EdgeInsets.symmetric(vertical: 35, horizontal: 20),
          decoration: BoxDecoration(color: panel, borderRadius: BorderRadius.circular(24), border: Border.all(color: Colors.white10)),
          child: const Column(children: [
            Icon(Icons.alarm_off_rounded, color: Color(0xFF8D7BBE), size: 48),
            SizedBox(height: 14), Text('لسّه ما أضفت أي منبّه', style: TextStyle(fontSize: 17, fontWeight: FontWeight.w600)),
            SizedBox(height: 6), Text('اضغط على الزر بالأسفل واضبط أول منبّه إلك', textAlign: TextAlign.center, style: TextStyle(color: Colors.white54)),
          ]))
        else ...store.alarms.map((a) => AlarmCard(alarm: a,
          onToggle: (v) => store.toggle(a, v), onDelete: () => store.remove(a))),
        const SizedBox(height: 22),
        SizedBox(height: 58, child: FilledButton.icon(
          style: FilledButton.styleFrom(backgroundColor: purple, foregroundColor: const Color(0xFF160E2C),
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18))),
          onPressed: () async {
            final draft = await Navigator.push<AlarmDraft>(context, MaterialPageRoute(builder: (_) => const SetAlarmScreen()));
            if (draft != null) await store.add(draft.hour, draft.minute, draft.label, draft.days, draft.target);
          },
          icon: const Icon(Icons.add_alarm_rounded),
          label: const Text('إضافة منبّه جديد', style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
        )),
        const SizedBox(height: 12),
        const Center(child: Text('نظّم وقتك، وابدأ يومك بنشاط ✨', style: TextStyle(color: Colors.white38, fontSize: 12))),
      ])),
    ));
  }
}

class AlarmCard extends StatelessWidget {
  const AlarmCard({super.key, required this.alarm, required this.onToggle, required this.onDelete});
  final AlarmItem alarm;
  final ValueChanged<bool> onToggle;
  final VoidCallback onDelete;
  @override Widget build(BuildContext context) {
    final time = TimeOfDay(hour: alarm.hour, minute: alarm.minute);
    const names = ['اث', 'ثل', 'أر', 'خم', 'جم', 'سب', 'أح'];
    final repeat = alarm.days.isEmpty ? 'مرة واحدة' : alarm.days.map((d) => names[d - 1]).join(' · ');
    return Container(margin: const EdgeInsets.only(bottom: 12), padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(color: panel, borderRadius: BorderRadius.circular(22),
        border: Border.all(color: alarm.enabled ? purple.withOpacity(.22) : Colors.white10)),
      child: Row(children: [
        Container(width: 48, height: 48, decoration: BoxDecoration(color: alarm.enabled ? softPurple : Colors.white10, borderRadius: BorderRadius.circular(15)),
          child: Icon(Icons.alarm_rounded, color: alarm.enabled ? purple : Colors.white38)),
        const SizedBox(width: 13),
        Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(time.format(context), style: TextStyle(fontSize: 28, fontWeight: FontWeight.w500, color: alarm.enabled ? Colors.white : Colors.white38)),
          const SizedBox(height: 4), Text(alarm.label, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontWeight: FontWeight.w600)),
          const SizedBox(height: 4), Text(repeat, style: const TextStyle(color: Colors.white54, fontSize: 12)),
        ])),
        Column(children: [
          Switch(value: alarm.enabled, activeColor: purple, onChanged: onToggle),
          IconButton(visualDensity: VisualDensity.compact, tooltip: 'حذف المنبّه', onPressed: onDelete,
            icon: const Icon(Icons.delete_outline_rounded, color: Colors.white38, size: 21)),
        ]),
      ]),
    );
  }
}

class AlarmDraft {
  const AlarmDraft(this.hour, this.minute, this.label, this.days, this.target);
  final int hour, minute;
  final String label;
  final List<int> days;
  final String target;
}

class SetAlarmScreen extends StatefulWidget {
  const SetAlarmScreen({super.key});
  @override State<SetAlarmScreen> createState() => _SetAlarmScreenState();
}
class _SetAlarmScreenState extends State<SetAlarmScreen> {
  TimeOfDay selectedTime = TimeOfDay.now();
  final labelController = TextEditingController(text: 'منبّه جديد');
  final selectedDays = <int>{};
  String selectedTarget = 'فرشاة الأسنان';
  @override void dispose() { labelController.dispose(); super.dispose(); }

  @override Widget build(BuildContext context) {
    const dayLabels = ['الاثنين', 'الثلاثاء', 'الأربعاء', 'الخميس', 'الجمعة', 'السبت', 'الأحد'];
    return Directionality(textDirection: TextDirection.rtl, child: Scaffold(
      appBar: AppBar(title: const Text('ضبط المنبّه'), backgroundColor: bg),
      body: SafeArea(child: ListView(padding: const EdgeInsets.all(22), children: [
        const Text('خلّي وقتك بإيدك', style: TextStyle(fontSize: 25, fontWeight: FontWeight.bold)),
        const SizedBox(height: 7), const Text('اختَر الوقت المناسب إلك', style: TextStyle(color: Colors.white60)),
        const SizedBox(height: 26),
        InkWell(borderRadius: BorderRadius.circular(26), onTap: () async {
          final picked = await showTimePicker(context: context, initialTime: selectedTime,
            builder: (context, child) => Directionality(textDirection: TextDirection.ltr, child: child!));
          if (picked != null) setState(() => selectedTime = picked);
        }, child: Container(padding: const EdgeInsets.symmetric(vertical: 28),
          decoration: BoxDecoration(color: panel, borderRadius: BorderRadius.circular(26), border: Border.all(color: purple.withOpacity(.3))),
          child: Column(children: [
            const Icon(Icons.access_time_rounded, color: purple, size: 34), const SizedBox(height: 12),
            Text(selectedTime.hour.toString().padLeft(2, '0') + ':' + selectedTime.minute.toString().padLeft(2, '0'),
              style: const TextStyle(fontSize: 52, fontWeight: FontWeight.w300)),
            const SizedBox(height: 8), const Text('اضغط لتغيير الوقت', style: TextStyle(color: Colors.white54)),
          ]))),
        const SizedBox(height: 24), const Text('اسم المنبّه', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
        const SizedBox(height: 10),
        TextField(controller: labelController, maxLength: 40, decoration: InputDecoration(
          hintText: 'مثلاً: وقت الاستيقاظ', filled: true, fillColor: panel,
          prefixIcon: const Icon(Icons.edit_outlined, color: purple),
          border: OutlineInputBorder(borderRadius: BorderRadius.circular(16), borderSide: BorderSide.none))),
        const SizedBox(height: 14),
        const Text('تحدّي التصوير', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
        const SizedBox(height: 8),
        Container(padding: const EdgeInsets.symmetric(horizontal: 14), decoration: BoxDecoration(color: panel, borderRadius: BorderRadius.circular(16)),
          child: DropdownButtonHideUnderline(child: DropdownButton<String>(isExpanded: true, value: selectedTarget,
            items: challengeTargets.keys.map((name) => DropdownMenuItem(value: name, child: Text('صوّر: $name'))).toList(),
            onChanged: (value) { if (value != null) setState(() => selectedTarget = value); }))),
        const SizedBox(height: 8),
        const Text('سيُطلب منك تصوير الهدف عند فتح تحدّي المنبّه، مع التحقق من الصورة على الجهاز.', style: TextStyle(color: Colors.white54, fontSize: 12)),
        const SizedBox(height: 18), const Text('التكرار', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
        const SizedBox(height: 6), const Text('اترك الأيام بدون تحديد لمنبّه لمرة واحدة', style: TextStyle(color: Colors.white54, fontSize: 12)),
        const SizedBox(height: 12),
        ...List.generate(7, (i) => CheckboxListTile(
          value: selectedDays.contains(i + 1),
          onChanged: (v) => setState(() { if (v == true) { selectedDays.add(i + 1); } else { selectedDays.remove(i + 1); } }),
          title: Text(dayLabels[i]), activeColor: purple, tileColor: panel,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
          controlAffinity: ListTileControlAffinity.leading, contentPadding: const EdgeInsets.symmetric(horizontal: 14))),
        const SizedBox(height: 20),
        SizedBox(height: 56, child: FilledButton.icon(
          onPressed: () => Navigator.pop(context, AlarmDraft(selectedTime.hour, selectedTime.minute,
            labelController.text, selectedDays.toList()..sort(), selectedTarget)),
          style: FilledButton.styleFrom(backgroundColor: purple, foregroundColor: const Color(0xFF160E2C),
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(17))),
          icon: const Icon(Icons.check_rounded),
          label: const Text('حفظ المنبّه', style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
        )),
      ])),
    ));
  }
}
