import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

const MethodChannel _smsChannel = MethodChannel('hesabyar/sms');
const EventChannel _smsEvents = EventChannel('hesabyar/sms_events');

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const HesabyarApp());
}

const Color brand = Color(0xFF087E75);
const Color ink = Color(0xFF172B2A);
const Color incomeColor = Color(0xFF16865B);
const Color expenseColor = Color(0xFFD65353);

class Account {
  Account({
    required this.id,
    required this.name,
    required this.openingBalance,
  });

  final String id;
  String name;
  int openingBalance;

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'openingBalance': openingBalance,
      };

  factory Account.fromJson(Map<String, dynamic> json) => Account(
        id: json['id'] as String,
        name: json['name'] as String,
        openingBalance: (json['openingBalance'] as num?)?.toInt() ?? 0,
      );
}

class MoneyTransaction {
  MoneyTransaction({
    required this.id,
    required this.title,
    required this.amount,
    required this.type,
    required this.accountId,
    required this.date,
    this.note = '',
  });

  final String id;
  String title;
  int amount;
  String type;
  String accountId;
  DateTime date;
  String note;

  Map<String, dynamic> toJson() => {
        'id': id,
        'title': title,
        'amount': amount,
        'type': type,
        'accountId': accountId,
        'date': date.toIso8601String(),
        'note': note,
      };

  factory MoneyTransaction.fromJson(Map<String, dynamic> json) =>
      MoneyTransaction(
        id: json['id'] as String,
        title: json['title'] as String,
        amount: (json['amount'] as num).toInt(),
        type: json['type'] as String,
        accountId: json['accountId'] as String,
        date: DateTime.parse(json['date'] as String),
        note: (json['note'] as String?) ?? '',
      );
}

class HesabyarApp extends StatelessWidget {
  const HesabyarApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'حسابیار',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        useMaterial3: true,
        scaffoldBackgroundColor: const Color(0xFFF5F8F7),
        colorScheme: ColorScheme.fromSeed(
          seedColor: brand,
          primary: brand,
          surface: Colors.white,
        ),
        fontFamily: 'Roboto',
        appBarTheme: const AppBarTheme(
          backgroundColor: Color(0xFFF5F8F7),
          foregroundColor: ink,
          centerTitle: false,
          elevation: 0,
        ),
        cardTheme: CardThemeData(
          color: Colors.white,
          elevation: 0,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(20),
            side: const BorderSide(color: Color(0xFFE8EFED)),
          ),
        ),
        inputDecorationTheme: InputDecorationTheme(
          filled: true,
          fillColor: const Color(0xFFF5F8F7),
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(14),
            borderSide: BorderSide.none,
          ),
        ),
      ),
      builder: (context, child) => Directionality(
        textDirection: TextDirection.rtl,
        child: child ?? const SizedBox.shrink(),
      ),
      home: const HomePage(),
    );
  }
}

class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  static const _storageKey = 'hesabyar_data_v1';
  int _tab = 0;
  bool _loading = true;
  List<Account> _accounts = [];
  List<MoneyTransaction> _transactions = [];
  bool _smsEnabled = false;
  List<String> _smsSenders = [];
  List<Map<String, dynamic>> _smsRecords = [];
  StreamSubscription<dynamic>? _smsSubscription;

  @override
  void initState() {
    super.initState();
    _loadData();
  }

  @override
  void dispose() {
    _smsSubscription?.cancel();
    super.dispose();
  }

  Future<void> _loadData() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_storageKey);
    if (raw != null) {
      try {
        final data = jsonDecode(raw) as Map<String, dynamic>;
        _accounts = (data['accounts'] as List<dynamic>? ?? [])
            .map((e) => Account.fromJson(Map<String, dynamic>.from(e as Map)))
            .toList();
        _transactions = (data['transactions'] as List<dynamic>? ?? [])
            .map((e) => MoneyTransaction.fromJson(
                Map<String, dynamic>.from(e as Map)))
            .toList();
        _smsRecords = (data['smsRecords'] as List<dynamic>? ?? [])
            .map((e) => Map<String, dynamic>.from(e as Map))
            .toList();
      } catch (_) {
        _accounts = [];
        _transactions = [];
      }
    }
    if (_accounts.isEmpty) {
      _accounts = [
        Account(
          id: DateTime.now().microsecondsSinceEpoch.toString(),
          name: 'کیف پول نقدی',
          openingBalance: 0,
        )
      ];
      await _saveData();
    }
    try {
      final config = await _smsChannel.invokeMapMethod<String, dynamic>('getSmsConfig');
      _smsEnabled = config?['enabled'] == true;
      _smsSenders = (config?['senders'] as List<dynamic>? ?? []).cast<String>();
      await _syncIncomingSms();
    } on PlatformException {
      // SMS integration is available only on Android.
    } on MissingPluginException {
      // Keep the rest of the app usable on unsupported platforms.
    }
    if (mounted) setState(() => _loading = false);
    if (mounted) {
      _smsSubscription = _smsEvents.receiveBroadcastStream().listen(
        (_) => _syncIncomingSms(),
        onError: (_) {},
      );
      // Catch messages received between the initial load and stream setup.
      await _syncIncomingSms();
    }
  }


  String _normalizeDigits(String value) {
    const fa = '۰۱۲۳۴۵۶۷۸۹';
    const ar = '٠١٢٣٤٥٦٧٨٩';
    for (var i = 0; i < 10; i++) {
      value = value.replaceAll(fa[i], '$i').replaceAll(ar[i], '$i');
    }
    return value;
  }

  Map<String, dynamic> _parseSms(Map<String, dynamic> sms) {
    final body = _normalizeDigits((sms['body'] ?? '').toString());
    final receivedAt = DateTime.fromMillisecondsSinceEpoch(
      (sms['timestamp'] as num?)?.toInt() ?? DateTime.now().millisecondsSinceEpoch,
    );
    final transactionType = RegExp(r'(انتقال|برداشت|واریز|خرید)').firstMatch(body)?.group(1) ?? 'نامشخص';
    final amountMatch = RegExp(
      r'(?:خرید|برداشت|واریز|انتقال|مبلغ|پرداخت)\s*[:：]?\s*([0-9,٬.]+)',
    ).firstMatch(body);
    final rawAmount = amountMatch?.group(1);
    final balanceMatch = RegExp(r'مانده\s*[:：]?\s*([0-9,٬.]+)').firstMatch(body);
    final dateMatch = RegExp(r'(?<![0-9])([0-9]{6})(?=[-–—])').firstMatch(body)
        ?? RegExp(r'([0-9]{1,4}[/-][0-9]{1,2}[/-][0-9]{1,4})').firstMatch(body);
    final timeMatch = RegExp(r'(?<![0-9])([0-2]?[0-9]:[0-5][0-9])').firstMatch(body);
    final cardMatch = RegExp(r'کارت\s*([0-9]{4})').firstMatch(body);
    final sender = (sms['sender'] ?? '').toString();
    final key = '${sender}_${receivedAt.millisecondsSinceEpoch}_${body.hashCode}';
    return {
      'id': key,
      'sender': sender,
      'transactionType': transactionType,
      'amount': rawAmount == null ? null : int.tryParse(rawAmount.replaceAll(',', '').replaceAll('٬', '').replaceAll('.', '')),
      'balance': balanceMatch?.group(1) == null ? null : int.tryParse(balanceMatch!.group(1)!.replaceAll(',', '').replaceAll('٬', '').replaceAll('.', '')),
      'cardLast4': cardMatch?.group(1),
      'unit': body.contains('ریال') ? 'ریال' : (body.contains('تومان') ? 'تومان' : 'واحد نامشخص'),
      'date': dateMatch?.group(1) ?? '${receivedAt.year.toString().padLeft(4, '0')}/${receivedAt.month.toString().padLeft(2, '0')}/${receivedAt.day.toString().padLeft(2, '0')}',
      'time': timeMatch?.group(1) ?? '${receivedAt.hour.toString().padLeft(2, '0')}:${receivedAt.minute.toString().padLeft(2, '0')}',
      'receivedAt': receivedAt.toIso8601String(),
      'body': body,
    };
  }

  Future<void> _syncIncomingSms() async {
    try {
      final incoming = await _smsChannel.invokeListMethod<dynamic>('getPendingSms') ?? [];
      var changed = false;
      for (final item in incoming) {
        if (item is! Map) continue;
        final record = _parseSms(Map<String, dynamic>.from(item));
        if (!_smsRecords.any((e) => e['id'] == record['id'])) {
          _smsRecords.insert(0, record);
          changed = true;
        }
      }
      if (incoming.isNotEmpty) {
        await _smsChannel.invokeMethod<void>('clearPendingSms');
      }
      if (changed) {
        await _saveData();
        if (mounted) setState(() {});
      }
    } on PlatformException {
      // Permission may be unavailable or revoked.
    } on MissingPluginException {
      // Unsupported platform.
    }
  }

  Future<bool> _setSmsMonitoring(bool enabled) async {
    try {
      if (enabled) {
        final granted = await _smsChannel.invokeMethod<bool>('hasSmsPermission') ?? false;
        if (!granted) {
          final permissionResult = await _smsChannel
              .invokeMapMethod<String, dynamic>('requestSmsPermission');
          final permissionGranted = permissionResult?['granted'] == true;
          if (!permissionGranted) {
            final canAskAgain = permissionResult?['canAskAgain'] == true;
            if (!canAskAgain && mounted) {
              await _showSmsPermissionSettingsDialog();
            } else {
              _notify('مجوز دریافت پیامک داده نشد. برای فعال‌سازی دوباره تلاش کن.');
            }
            return false;
          }
        }
      }
      await _smsChannel.invokeMethod<void>('setSmsConfig', {
        'enabled': enabled,
        'senders': _smsSenders,
      });
      setState(() => _smsEnabled = enabled);
      if (enabled) await _syncIncomingSms();
      return true;
    } on PlatformException catch (e) {
      _notify('تنظیم پیامک انجام نشد: ${e.message ?? 'خطای نامشخص'}');
      return false;
    } on MissingPluginException {
      _notify('قابلیت پیامک فقط در نسخه اندروید در دسترس است.');
      return false;
    }
  }

  Future<void> _showSmsPermissionSettingsDialog() async {
    if (!mounted) return;
    final openSettings = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('مجوز پیامک غیرفعال است'),
        content: const Text(
          'دسترسی پیامک رد شده و اندروید دیگر پنجره درخواست را نمایش نمی‌دهد. '
          'برای فعال‌سازی، وارد تنظیمات برنامه شو و مجوز پیامک را دستی روشن کن.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('فعلاً نه'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('رفتن به تنظیمات'),
          ),
        ],
      ),
    );
    if (openSettings == true) {
      try {
        await _smsChannel.invokeMethod<bool>('openAppSettings');
      } on PlatformException catch (e) {
        _notify('باز کردن تنظیمات ناموفق بود: ${e.message ?? 'خطای نامشخص'}');
      }
    }
  }

  Future<void> _addSmsSender(StateSetter refresh) async {
    final controller = TextEditingController();
    String? value;
    try {
      value = await showDialog<String>(
        context: context,
        builder: (dialogContext) => AlertDialog(
          title: const Text('افزودن فرستنده پیامک'),
          content: TextField(
            controller: controller,
            keyboardType: TextInputType.text,
            textCapitalization: TextCapitalization.none,
            autofocus: true,
            decoration: const InputDecoration(
              labelText: 'شماره، سرشماره یا نام فرستنده',
              hintText: 'مثلاً 3000، 0912... یا نام بانک',
              helperText: 'اگر پیامک به‌جای شماره، نام فرستنده دارد، همان نام نمایشی را وارد کن.',
            ),
            onSubmitted: (text) =>
                Navigator.pop(dialogContext, text.trim()),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext),
              child: const Text('انصراف'),
            ),
            FilledButton(
              onPressed: () =>
                  Navigator.pop(dialogContext, controller.text.trim()),
              child: const Text('افزودن'),
            ),
          ],
        ),
      );
    } finally {
      controller.dispose();
    }

    if (!mounted || value == null) return;
    final sender = value.trim();
    if (sender.isEmpty) {
      _notify('شماره یا نام فرستنده را وارد کن.');
      return;
    }

    final alreadyExists = _smsSenders.any(
      (item) => item.trim().toLowerCase() == sender.toLowerCase(),
    );
    if (alreadyExists) {
      _notify('این فرستنده قبلاً اضافه شده است.');
      return;
    }

    // Update the visible list immediately. Native persistence must not
    // block the settings page from showing the newly added sender.
    _smsSenders.add(sender);
    refresh(() {});

    try {
      await _smsChannel.invokeMethod<void>('setSmsConfig', {
        'enabled': _smsEnabled,
        'senders': List<String>.from(_smsSenders),
      });
    } on PlatformException catch (e) {
      _notify('فرستنده در صفحه اضافه شد، اما ذخیره اندروید ناموفق بود: '
          '${e.message ?? 'خطای نامشخص'}');
    } on MissingPluginException {
      _notify('فرستنده در صفحه اضافه شد؛ ذخیره‌سازی پیامک فقط در نسخه اندروید فعال است.');
    }
  }

  Future<void> _openSmsSettings() async {
    await _syncIncomingSms();
    if (!mounted) return;
    await Navigator.push<void>(
      context,
      MaterialPageRoute(
        builder: (pageContext) => StatefulBuilder(
          builder: (context, refresh) => Scaffold(
            appBar: AppBar(title: const Text('خواندن پیامک‌ها')),
            body: ListView(
              padding: const EdgeInsets.all(16),
              children: [
                Card(
                  child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text('حریم خصوصی و دسترسی',
                            style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
                        const SizedBox(height: 8),
                        const Text('با فعال‌سازی، حسابیار فقط پیامک‌های جدیدِ شماره‌هایی را که در این صفحه انتخاب می‌کنی دریافت می‌کند. پیامک‌های قدیمی خوانده نمی‌شوند. اطلاعات روی همین دستگاه می‌ماند.'),
                        const SizedBox(height: 8),
                        SwitchListTile(
                          contentPadding: EdgeInsets.zero,
                          title: const Text('فعال‌سازی دریافت پیامک'),
                          value: _smsEnabled,
                          onChanged: (value) async {
                            if (value && _smsSenders.isEmpty) {
                              _notify('ابتدا حداقل یک شماره فرستنده اضافه کن.');
                              return;
                            }
                            final ok = await _setSmsMonitoring(value);
                            if (!ok && value && mounted) {
                              refresh(() {});
                            }
                            refresh(() {});
                          },
                        ),
                        Text(
                          'برای دریافت پیامک، مجوز حساس SMS از اندروید درخواست می‌شود.',
                          style: TextStyle(color: Colors.grey.shade600, fontSize: 12),
                        ),
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: 12),
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    const Text('فرستنده‌های مجاز', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
                    TextButton.icon(
                      onPressed: () => _addSmsSender(refresh),
                      icon: const Icon(Icons.add),
                      label: const Text('افزودن شماره'),
                    ),
                  ],
                ),
                if (_smsSenders.isEmpty)
                  const Card(child: Padding(padding: EdgeInsets.all(16), child: Text('هنوز شماره‌ای انتخاب نشده است.')))
                else
                  ..._smsSenders.map((sender) => Card(
                    child: ListTile(
                      leading: const Icon(Icons.sms_outlined, color: brand),
                      title: Text(sender, textDirection: TextDirection.ltr),
                      trailing: IconButton(
                        icon: const Icon(Icons.delete_outline),
                        onPressed: () async {
                          _smsSenders.remove(sender);
                          await _setSmsMonitoring(_smsEnabled && _smsSenders.isNotEmpty);
                          if (_smsSenders.isEmpty) _smsEnabled = false;
                          refresh(() {});
                        },
                      ),
                    ),
                  )),
                const SizedBox(height: 16),
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    const Text('پیامک‌های پردازش‌شده', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
                    TextButton(onPressed: () async { await _syncIncomingSms(); refresh(() {}); }, child: const Text('به‌روزرسانی')),
                  ],
                ),
                if (_smsRecords.isEmpty)
                  const Card(child: Padding(padding: EdgeInsets.all(16), child: Text('هنوز پیامک جدیدی دریافت نشده است.')))
                else
                  ..._smsRecords.map((record) => Card(
                    child: ListTile(
                      leading: const Icon(Icons.receipt_long_outlined, color: brand),
                      title: Text('${record['transactionType'] ?? 'تراکنش'} • ${record['amount'] == null ? 'مبلغ شناسایی نشد' : _digits((record['amount'] as num).toInt()) + ' ' + (record['unit'] ?? 'واحد نامشخص')}'),
                      subtitle: Text('${record['sender']}  •  ${record['date']}  •  ${record['time']}\n${record['body']}', maxLines: 4, overflow: TextOverflow.ellipsis),
                      isThreeLine: true,
                    ),
                  )),
                if (_smsRecords.isNotEmpty)
                  Align(
                    alignment: Alignment.centerLeft,
                    child: TextButton.icon(
                      onPressed: () async {
                        final yes = await showDialog<bool>(
                          context: context,
                          builder: (ctx) => AlertDialog(
                            title: const Text('پاک‌کردن سوابق پیامک'),
                            content: const Text('فقط سوابق استخراج‌شده در حسابیار پاک می‌شوند.'),
                            actions: [
                              TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('انصراف')),
                              FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('پاک‌کردن')),
                            ],
                          ),
                        );
                        if (yes == true) {
                          _smsRecords.clear();
                          await _saveData();
                          refresh(() {});
                        }
                      },
                      icon: const Icon(Icons.delete_sweep_outlined),
                      label: const Text('پاک‌کردن سوابق'),
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Future<void> _saveData() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      _storageKey,
      jsonEncode({
        'schemaVersion': 1,
        'accounts': _accounts.map((e) => e.toJson()).toList(),
        'transactions': _transactions.map((e) => e.toJson()).toList(),
        'smsRecords': _smsRecords,
      }),
    );
  }

  int _balanceFor(String accountId) {
    var total = _accounts
        .where((a) => a.id == accountId)
        .fold<int>(0, (sum, a) => sum + a.openingBalance);
    for (final tx in _transactions.where((t) => t.accountId == accountId)) {
      total += tx.type == 'income' ? tx.amount : -tx.amount;
    }
    return total;
  }

  int get _totalBalance =>
      _accounts.fold<int>(0, (sum, a) => sum + _balanceFor(a.id));

  int _sum(String type, [Iterable<MoneyTransaction>? source]) =>
      (source ?? _transactions)
          .where((t) => t.type == type)
          .fold<int>(0, (sum, t) => sum + t.amount);

  String _money(int value) => '${_digits(value)} تومان';

  String _digits(int value) {
    final s = value.abs().toString();
    final out = StringBuffer();
    for (var i = 0; i < s.length; i++) {
      if (i > 0 && (s.length - i) % 3 == 0) out.write(',');
      out.write(s[i]);
    }
    return '${value < 0 ? '-' : ''}$out';
  }

  String _date(DateTime date) =>
      '${date.year}/${date.month.toString().padLeft(2, '0')}/${date.day.toString().padLeft(2, '0')}';

  void _notify(String message) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message), behavior: SnackBarBehavior.floating),
    );
  }

  Future<void> _addTransaction({String? initialType}) async {
    if (_accounts.isEmpty) {
      _notify('ابتدا یک حساب بسازید.');
      return;
    }
    final title = TextEditingController();
    final amount = TextEditingController();
    final note = TextEditingController();
    var type = initialType ?? 'expense';
    var accountId = _accounts.first.id;
    var date = DateTime.now();
    final formKey = GlobalKey<FormState>();
    final saved = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: Text(type == 'income' ? 'ثبت درآمد' : 'ثبت هزینه'),
          content: SizedBox(
            width: 420,
            child: Form(
              key: formKey,
              child: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    SegmentedButton<String>(
                      segments: const [
                        ButtonSegment(
                          value: 'expense',
                          label: Text('هزینه'),
                          icon: Icon(Icons.south_west),
                        ),
                        ButtonSegment(
                          value: 'income',
                          label: Text('درآمد'),
                          icon: Icon(Icons.north_east),
                        ),
                      ],
                      selected: {type},
                      onSelectionChanged: (v) =>
                          setDialogState(() => type = v.first),
                    ),
                    const SizedBox(height: 14),
                    TextFormField(
                      controller: title,
                      decoration:
                          const InputDecoration(labelText: 'عنوان تراکنش'),
                      validator: (v) =>
                          v == null || v.trim().isEmpty ? 'عنوان را وارد کنید' : null,
                    ),
                    const SizedBox(height: 10),
                    TextFormField(
                      controller: amount,
                      keyboardType: TextInputType.number,
                      decoration: const InputDecoration(
                        labelText: 'مبلغ به تومان',
                        prefixIcon: Icon(Icons.payments_outlined),
                      ),
                      validator: (v) {
                        final n = int.tryParse((v ?? '').replaceAll(',', ''));
                        return n == null || n <= 0 ? 'مبلغ معتبر وارد کنید' : null;
                      },
                    ),
                    const SizedBox(height: 10),
                    DropdownButtonFormField<String>(
                      value: accountId,
                      decoration: const InputDecoration(labelText: 'حساب'),
                      items: _accounts
                          .map((a) => DropdownMenuItem(
                                value: a.id,
                                child: Text(a.name),
                              ))
                          .toList(),
                      onChanged: (v) =>
                          setDialogState(() => accountId = v ?? accountId),
                    ),
                    const SizedBox(height: 10),
                    TextFormField(
                      controller: note,
                      decoration:
                          const InputDecoration(labelText: 'توضیحات (اختیاری)'),
                    ),
                    const SizedBox(height: 8),
                    ListTile(
                      contentPadding: EdgeInsets.zero,
                      leading: const Icon(Icons.calendar_month_outlined),
                      title: const Text('تاریخ تراکنش'),
                      subtitle: Text(_date(date)),
                      trailing: TextButton(
                        onPressed: () async {
                          final picked = await showDatePicker(
                            context: context,
                            initialDate: date,
                            firstDate: DateTime(2000),
                            lastDate: DateTime(2100),
                          );
                          if (picked != null) {
                            setDialogState(() => date = picked);
                          }
                        },
                        child: const Text('تغییر'),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext, false),
              child: const Text('انصراف'),
            ),
            FilledButton(
              onPressed: () {
                if (formKey.currentState!.validate()) {
                  final value =
                      int.parse(amount.text.replaceAll(',', '').trim());
                  _transactions.insert(
                    0,
                    MoneyTransaction(
                      id: DateTime.now().microsecondsSinceEpoch.toString(),
                      title: title.text.trim(),
                      amount: value,
                      type: type,
                      accountId: accountId,
                      date: date,
                      note: note.text.trim(),
                    ),
                  );
                  Navigator.pop(dialogContext, true);
                }
              },
              child: const Text('ثبت تراکنش'),
            ),
          ],
        ),
      ),
    );
    if (saved == true) {
      await _saveData();
      if (mounted) setState(() {});
      _notify('تراکنش با موفقیت ثبت شد.');
    }
  }

  Future<void> _addAccount() async {
    final name = TextEditingController();
    final balance = TextEditingController(text: '0');
    final formKey = GlobalKey<FormState>();
    final saved = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('افزودن حساب'),
        content: Form(
          key: formKey,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextFormField(
                controller: name,
                decoration: const InputDecoration(labelText: 'نام حساب'),
                validator: (v) =>
                    v == null || v.trim().isEmpty ? 'نام حساب را وارد کنید' : null,
              ),
              const SizedBox(height: 12),
              TextFormField(
                controller: balance,
                keyboardType: TextInputType.number,
                decoration: const InputDecoration(
                  labelText: 'موجودی اولیه (تومان)',
                ),
                validator: (v) =>
                    int.tryParse((v ?? '').trim()) == null ? 'مبلغ معتبر نیست' : null,
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('انصراف'),
          ),
          FilledButton(
            onPressed: () {
              if (formKey.currentState!.validate()) {
                _accounts.add(Account(
                  id: DateTime.now().microsecondsSinceEpoch.toString(),
                  name: name.text.trim(),
                  openingBalance: int.parse(balance.text.trim()),
                ));
                Navigator.pop(dialogContext, true);
              }
            },
            child: const Text('ذخیره حساب'),
          ),
        ],
      ),
    );
    if (saved == true) {
      await _saveData();
      if (mounted) setState(() {});
      _notify('حساب اضافه شد.');
    }
  }

  Future<void> _deleteTransaction(MoneyTransaction tx) async {
    final yes = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('حذف تراکنش'),
        content: Text('تراکنش «${tx.title}» حذف شود؟'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('انصراف'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('حذف'),
          ),
        ],
      ),
    );
    if (yes == true) {
      setState(() => _transactions.removeWhere((t) => t.id == tx.id));
      await _saveData();
      _notify('تراکنش حذف شد.');
    }
  }

  Future<void> _backup() async {
    final backup = const JsonEncoder.withIndent('  ').convert({
      'app': 'Hesabyar',
      'version': 1,
      'createdAt': DateTime.now().toIso8601String(),
      'accounts': _accounts.map((e) => e.toJson()).toList(),
      'transactions': _transactions.map((e) => e.toJson()).toList(),
    });
    await showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('پشتیبان‌گیری اطلاعات'),
        content: const Text(
          'متن پشتیبان را کپی و در یک فایل امن ذخیره کنید. برای بازیابی، همین متن را وارد کنید.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('بستن'),
          ),
          FilledButton.icon(
            onPressed: () {
              Clipboard.setData(ClipboardData(text: backup));
              Navigator.pop(context);
              _notify('متن پشتیبان کپی شد.');
            },
            icon: const Icon(Icons.copy),
            label: const Text('کپی نسخه پشتیبان'),
          ),
        ],
      ),
    );
  }

  Future<void> _restore() async {
    final controller = TextEditingController();
    final restored = await showDialog<Map<String, dynamic>?>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('بازیابی اطلاعات'),
        content: SizedBox(
          width: 440,
          child: TextField(
            controller: controller,
            minLines: 5,
            maxLines: 10,
            decoration: const InputDecoration(
              hintText: 'متن JSON نسخه پشتیبان را اینجا وارد کنید',
              alignLabelWithHint: true,
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('انصراف'),
          ),
          FilledButton(
            onPressed: () {
              try {
                final data = jsonDecode(controller.text) as Map<String, dynamic>;
                if (data['accounts'] is! List ||
                    data['transactions'] is! List) {
                  throw const FormatException();
                }
                Navigator.pop(context, data);
              } catch (_) {
                _notify('متن پشتیبان معتبر نیست.');
              }
            },
            child: const Text('بررسی و بازیابی'),
          ),
        ],
      ),
    );
    if (restored == null) return;
    try {
      final accounts = (restored['accounts'] as List)
          .map((e) => Account.fromJson(Map<String, dynamic>.from(e as Map)))
          .toList();
      final transactions = (restored['transactions'] as List)
          .map((e) => MoneyTransaction.fromJson(
              Map<String, dynamic>.from(e as Map)))
          .toList();
      if (accounts.isEmpty ||
          transactions.any((t) => !accounts.any((a) => a.id == t.accountId))) {
        throw const FormatException();
      }
      setState(() {
        _accounts = accounts;
        _transactions = transactions;
      });
      await _saveData();
      _notify('اطلاعات با موفقیت بازیابی شد.');
    } catch (_) {
      _notify('ساختار نسخه پشتیبان قابل بازیابی نیست.');
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }
    final pages = [
      _dashboard(),
      _transactionsPage(),
      _reportsPage(),
      _accountsPage(),
      _settingsPage(),
    ];
    return Scaffold(
      appBar: AppBar(
        title: const Row(
          children: [
            Icon(Icons.account_balance_wallet_rounded, color: brand),
            SizedBox(width: 9),
            Text('حسابیار', style: TextStyle(fontWeight: FontWeight.w800)),
          ],
        ),
        actions: [
          IconButton(
            tooltip: 'ثبت هزینه',
            onPressed: () => _addTransaction(initialType: 'expense'),
            icon: const Icon(Icons.add_circle_outline),
          ),
        ],
      ),
      body: SafeArea(
        child: IndexedStack(index: _tab, children: pages),
      ),
      floatingActionButton: _tab == 0 || _tab == 1
          ? FloatingActionButton.extended(
              onPressed: () => _addTransaction(),
              backgroundColor: brand,
              foregroundColor: Colors.white,
              icon: const Icon(Icons.add),
              label: const Text('تراکنش جدید'),
            )
          : null,
      bottomNavigationBar: NavigationBar(
        selectedIndex: _tab,
        onDestinationSelected: (v) => setState(() => _tab = v),
        destinations: const [
          NavigationDestination(
              icon: Icon(Icons.home_outlined),
              selectedIcon: Icon(Icons.home),
              label: 'خانه'),
          NavigationDestination(
              icon: Icon(Icons.receipt_long_outlined),
              selectedIcon: Icon(Icons.receipt_long),
              label: 'تراکنش‌ها'),
          NavigationDestination(
              icon: Icon(Icons.insert_chart_outlined),
              selectedIcon: Icon(Icons.insert_chart),
              label: 'گزارش'),
          NavigationDestination(
              icon: Icon(Icons.account_balance_outlined),
              selectedIcon: Icon(Icons.account_balance),
              label: 'حساب‌ها'),
          NavigationDestination(
              icon: Icon(Icons.settings_outlined),
              selectedIcon: Icon(Icons.settings),
              label: 'تنظیمات'),
        ],
      ),
    );
  }

  Widget _dashboard() {
    final recent = [..._transactions]..sort((a, b) => b.date.compareTo(a.date));
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 100),
      children: [
        Container(
          padding: const EdgeInsets.all(22),
          decoration: BoxDecoration(
            gradient: const LinearGradient(
              colors: [Color(0xFF087E75), Color(0xFF075B59)],
              begin: Alignment.topRight,
              end: Alignment.bottomLeft,
            ),
            borderRadius: BorderRadius.circular(24),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text('موجودی کل دارایی',
                  style: TextStyle(color: Colors.white70, fontSize: 14)),
              const SizedBox(height: 10),
              Text(
                _money(_totalBalance),
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 28,
                  fontWeight: FontWeight.w800,
                ),
              ),
              const SizedBox(height: 22),
              Row(
                children: [
                  Expanded(
                    child: _whiteMetric(
                        'درآمد کل', _money(_sum('income')), Icons.trending_up),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: _whiteMetric(
                        'هزینه کل', _money(_sum('expense')), Icons.trending_down),
                  ),
                ],
              ),
            ],
          ),
        ),
        const SizedBox(height: 22),
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            const Text('حساب‌های من',
                style: TextStyle(fontSize: 17, fontWeight: FontWeight.bold)),
            TextButton(
              onPressed: () => setState(() => _tab = 3),
              child: const Text('مشاهده همه'),
            ),
          ],
        ),
        SizedBox(
          height: 112,
          child: ListView.separated(
            scrollDirection: Axis.horizontal,
            itemCount: _accounts.length,
            separatorBuilder: (_, __) => const SizedBox(width: 10),
            itemBuilder: (context, i) {
              final account = _accounts[i];
              return Container(
                width: 190,
                padding: const EdgeInsets.all(15),
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(18),
                  border: Border.all(color: const Color(0xFFE8EFED)),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Icon(Icons.account_balance_wallet_outlined,
                        color: brand),
                    const Spacer(),
                    Text(account.name,
                        maxLines: 1, overflow: TextOverflow.ellipsis),
                    Text(_money(_balanceFor(account.id)),
                        style: const TextStyle(
                            fontWeight: FontWeight.bold, color: ink)),
                  ],
                ),
              );
            },
          ),
        ),
        const SizedBox(height: 18),
        const Text('آخرین تراکنش‌ها',
            style: TextStyle(fontSize: 17, fontWeight: FontWeight.bold)),
        const SizedBox(height: 8),
        if (recent.isEmpty)
          _emptyState('هنوز تراکنشی ثبت نشده است')
        else
          ...recent.take(5).map(_transactionTile),
      ],
    );
  }

  Widget _whiteMetric(String title, String value, IconData icon) => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(icon, color: Colors.white70, size: 17),
              const SizedBox(width: 5),
              Text(title, style: const TextStyle(color: Colors.white70)),
            ],
          ),
          const SizedBox(height: 5),
          Text(value,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                  color: Colors.white, fontWeight: FontWeight.bold)),
        ],
      );

  Widget _transactionsPage() {
    final items = [..._transactions]..sort((a, b) => b.date.compareTo(a.date));
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 100),
      children: [
        const Text('همه تراکنش‌ها',
            style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold)),
        const SizedBox(height: 12),
        if (items.isEmpty)
          _emptyState('برای شروع، اولین درآمد یا هزینه را ثبت کنید')
        else
          ...items.map(_transactionTile),
      ],
    );
  }

  Widget _transactionTile(MoneyTransaction tx) {
    final isIncome = tx.type == 'income';
    final account = _accounts.where((a) => a.id == tx.accountId);
    return Card(
      margin: const EdgeInsets.only(bottom: 9),
      child: ListTile(
        leading: CircleAvatar(
          backgroundColor:
              (isIncome ? incomeColor : expenseColor).withValues(alpha: .10),
          child: Icon(
            isIncome ? Icons.south_west : Icons.north_east,
            color: isIncome ? incomeColor : expenseColor,
          ),
        ),
        title: Text(tx.title,
            style: const TextStyle(fontWeight: FontWeight.w600)),
        subtitle: Text(
          '${_date(tx.date)} • ${account.isEmpty ? 'حساب حذف‌شده' : account.first.name}',
        ),
        trailing: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            Text(
              '${isIncome ? '+' : '−'}${_money(tx.amount)}',
              style: TextStyle(
                fontWeight: FontWeight.bold,
                color: isIncome ? incomeColor : expenseColor,
                fontSize: 12,
              ),
            ),
            PopupMenuButton<String>(
              padding: EdgeInsets.zero,
              constraints: const BoxConstraints(),
              icon: const Icon(Icons.more_horiz, size: 20),
              onSelected: (v) {
                if (v == 'delete') _deleteTransaction(tx);
              },
              itemBuilder: (_) => const [
                PopupMenuItem(value: 'delete', child: Text('حذف تراکنش')),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _reportsPage() {
    final now = DateTime.now();
    final monthItems = _transactions
        .where((t) => t.date.year == now.year && t.date.month == now.month)
        .toList();
    final yearItems =
        _transactions.where((t) => t.date.year == now.year).toList();
    final monthIncome = _sum('income', monthItems);
    final monthExpense = _sum('expense', monthItems);
    final yearIncome = _sum('income', yearItems);
    final yearExpense = _sum('expense', yearItems);
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        const Text('گزارش عملکرد',
            style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold)),
        const SizedBox(height: 5),
        Text('گزارش‌ها بر اساس تاریخ ثبت‌شده تراکنش‌ها محاسبه می‌شوند.',
            style: TextStyle(color: Colors.grey.shade600)),
        const SizedBox(height: 18),
        _reportCard(
          title: 'گزارش ماه جاری',
          subtitle: '${_monthName(now.month)} ${now.year}',
          income: monthIncome,
          expense: monthExpense,
        ),
        const SizedBox(height: 14),
        _reportCard(
          title: 'گزارش سال جاری',
          subtitle: now.year.toString(),
          income: yearIncome,
          expense: yearExpense,
        ),
      ],
    );
  }

  String _monthName(int month) {
    const months = [
      'ژانویه', 'فوریه', 'مارس', 'آوریل', 'مه', 'ژوئن',
      'ژوئیه', 'اوت', 'سپتامبر', 'اکتبر', 'نوامبر', 'دسامبر'
    ];
    return months[month - 1];
  }

  Widget _reportCard({
    required String title,
    required String subtitle,
    required int income,
    required int expense,
  }) {
    final net = income - expense;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(18),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(title,
                style:
                    const TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
            Text(subtitle, style: TextStyle(color: Colors.grey.shade600)),
            const SizedBox(height: 18),
            _reportLine('مجموع درآمد', income, incomeColor),
            const SizedBox(height: 12),
            _reportLine('مجموع هزینه', expense, expenseColor),
            const Divider(height: 26),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                const Text('خالص (درآمد منهای هزینه)',
                    style: TextStyle(fontWeight: FontWeight.bold)),
                Text(
                  _money(net),
                  style: TextStyle(
                    color: net >= 0 ? incomeColor : expenseColor,
                    fontWeight: FontWeight.w800,
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _reportLine(String label, int value, Color color) => Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Row(children: [
            CircleAvatar(radius: 5, backgroundColor: color),
            const SizedBox(width: 8),
            Text(label),
          ]),
          Text(_money(value),
              style: TextStyle(color: color, fontWeight: FontWeight.bold)),
        ],
      );

  Widget _accountsPage() {
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            const Text('حساب‌ها و صندوق‌ها',
                style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold)),
            FilledButton.icon(
              onPressed: _addAccount,
              icon: const Icon(Icons.add),
              label: const Text('حساب جدید'),
            ),
          ],
        ),
        const SizedBox(height: 12),
        ..._accounts.map((account) => Card(
              child: ListTile(
                leading: const CircleAvatar(
                  backgroundColor: Color(0xFFE5F3F0),
                  child: Icon(Icons.account_balance_wallet, color: brand),
                ),
                title: Text(account.name,
                    style: const TextStyle(fontWeight: FontWeight.bold)),
                subtitle: Text('موجودی اولیه: ${_money(account.openingBalance)}'),
                trailing: Text(
                  _money(_balanceFor(account.id)),
                  style: const TextStyle(
                      color: brand, fontWeight: FontWeight.w800),
                ),
              ),
            )),
        const SizedBox(height: 12),
        Text(
          'برای جلوگیری از به‌هم‌ریختن سوابق مالی، حذف حساب در این نسخه غیرفعال است.',
          style: TextStyle(color: Colors.grey.shade600, fontSize: 12),
        ),
      ],
    );
  }

  Widget _settingsPage() {
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        const Text('تنظیمات',
            style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold)),
        const SizedBox(height: 14),
        Card(
          child: Column(
            children: [
              ListTile(
                leading: const Icon(Icons.sms_outlined, color: brand),
                title: const Text('خواندن پیامک‌ها'),
                subtitle: const Text('استخراج مبلغ، تاریخ و ساعت از فرستنده‌های منتخب'),
                trailing: const Icon(Icons.chevron_left),
                onTap: _openSmsSettings,
              ),
              const Divider(height: 1, indent: 16, endIndent: 16),
              ListTile(
                leading: const Icon(Icons.backup_outlined, color: brand),
                title: const Text('پشتیبان‌گیری'),
                subtitle: const Text('کپی اطلاعات در قالب JSON'),
                trailing: const Icon(Icons.chevron_left),
                onTap: _backup,
              ),
              const Divider(height: 1, indent: 16, endIndent: 16),
              ListTile(
                leading: const Icon(Icons.restore, color: brand),
                title: const Text('بازیابی اطلاعات'),
                subtitle: const Text('وارد کردن متن نسخه پشتیبان'),
                trailing: const Icon(Icons.chevron_left),
                onTap: _restore,
              ),
            ],
          ),
        ),
        const SizedBox(height: 18),
        Card(
          child: const Padding(
            padding: EdgeInsets.all(18),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('درباره حسابیار',
                    style: TextStyle(fontWeight: FontWeight.bold)),
                SizedBox(height: 8),
                Text('نسخه ۱.۰.۰'),
                SizedBox(height: 5),
                Text('مدیریت ساده و آفلاین دخل‌وخرج شخصی'),
              ],
            ),
          ),
        ),
        const SizedBox(height: 12),
        Text(
          'اطلاعات شما روی همین دستگاه ذخیره می‌شود. برای جلوگیری از ازدست‌رفتن داده‌ها، مرتب نسخه پشتیبان تهیه کنید.',
          style: TextStyle(color: Colors.grey.shade600, fontSize: 12),
        ),
      ],
    );
  }

  Widget _emptyState(String message) => Container(
        padding: const EdgeInsets.all(28),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(20),
          border: Border.all(color: const Color(0xFFE8EFED)),
        ),
        child: Column(
          children: [
            const Icon(Icons.receipt_long_outlined, size: 38, color: brand),
            const SizedBox(height: 10),
            Text(message, textAlign: TextAlign.center),
          ],
        ),
      );
}
