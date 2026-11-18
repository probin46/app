// ignore_for_file: deprecated_member_use
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:cached_network_image/cached_network_image.dart';
import 'package:camera/camera.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:emoji_picker_flutter/emoji_picker_flutter.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_contacts/flutter_contacts.dart';
import 'package:geolocator/geolocator.dart';
import 'package:google_generative_ai/google_generative_ai.dart';
import 'package:latlong2/latlong.dart';
import 'package:http/http.dart' as http;
import 'package:image_picker/image_picker.dart';
import 'package:intl/intl.dart';
import 'package:just_audio/just_audio.dart';
import 'package:open_filex/open_filex.dart';
import 'package:path_provider/path_provider.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:photo_manager/photo_manager.dart' hide LatLng;
import 'package:provider/provider.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:uuid/uuid.dart';
import 'package:video_player/video_player.dart';

import '../../providers/auth_provider.dart' show LumaAuthProvider;
import '../../providers/chat_provider.dart';
import 'group_chat_screen.dart' show GroupChatScreen;
import '../../services/api_config.dart';
import '../../services/cloudinary_service.dart';

// ═══════════════════════════════════════════════════════════════════════════
// CONFIG
// ═══════════════════════════════════════════════════════════════════════════
const String _kGiphyApiKey = '7tXB3cisPGymcszQX85JFOY6kp3Gz47T';
const String _kGeminiModel = 'gemini-2.0-flash';

// Field names in your Firestore `users` documents.
// PhoneEntryScreen saves the number in `phone`; older docs may use `phone_number`.
const String _kUserPhoneField = 'phone';
const String _kUserPhoneLegacyField = 'phone_number';
const String _kUserNameField = 'display_name';
const String _kUserAvatarField = 'avatar_url';
const String _kUserOnlineField = 'is_online';

const Color _kAccent = Color(0xFF3390EC);
const int _kPageSize = 80;
const List<String> _kQuickReactions = ['👍', '❤️', '😂', '😮', '😢', '🙏'];

const List<Color> _kNameColors = [
  Color(0xFFE17076),
  Color(0xFFFAA774),
  Color(0xFFA695E7),
  Color(0xFF7BC862),
  Color(0xFF6EC9CB),
  Color(0xFF65AADD),
  Color(0xFFEE7AAE),
  Color(0xFFE5B35C),
];

const List<String> _kWallpaperPresets = [
  'color:FFDCE8C8',
  'color:FFC9E4F5',
  'color:FFF3E1D3',
  'color:FFE6DAF2',
  'color:FF0E1621',
  'color:FF1B2B24',
  'color:FF2A2438',
  'color:FF101010',
  'grad:FF74EBD5,FF9FACE6',
  'grad:FFFF9A9E,FFFAD0C4',
  'grad:FF141E30,FF243B55',
  'grad:FF0F2027,FF2C5364',
];

// ═══════════════════════════════════════════════════════════════════════════
// HELPERS
// ═══════════════════════════════════════════════════════════════════════════
String _fmtDur(int s) =>
    '${(s ~/ 60).toString().padLeft(2, '0')}:${(s % 60).toString().padLeft(2, '0')}';

/// Keeps the last 10 digits so "+234 913 405 7359" and "0913 405 7359" match.
String _digitsTail(String raw) {
  final d = raw.replaceAll(RegExp(r'[^0-9]'), '');
  if (d.length >= 10) return d.substring(d.length - 10);
  return d;
}

double _c01(double v) => v < 0 ? 0.0 : (v > 1 ? 1.0 : v);

Color _colorForUid(String? uid) {
  final h = (uid ?? '').codeUnits.fold<int>(0, (a, b) => (a * 31 + b) & 0x7fffffff);
  return _kNameColors[h % _kNameColors.length];
}

DateTime _msgTime(Map<String, dynamic> m) {
  final ts = m['created_at'];
  if (ts is Timestamp) return ts.toDate();
  return DateTime.now();
}

bool _sameDay(DateTime a, DateTime b) =>
    a.year == b.year && a.month == b.month && a.day == b.day;

String _dayLabel(DateTime d) {
  final now = DateTime.now();
  final today = DateTime(now.year, now.month, now.day);
  final day = DateTime(d.year, d.month, d.day);
  final diff = today.difference(day).inDays;
  if (diff == 0) return 'Today';
  if (diff == 1) return 'Yesterday';
  if (d.year == now.year) return DateFormat('MMMM d').format(d);
  return DateFormat('MMMM d, y').format(d);
}

String _stripFormatting(String s) {
  return s
      .replaceAllMapped(RegExp(r'\*\*(.+?)\*\*', dotAll: true), (m) => m.group(1)!)
      .replaceAllMapped(RegExp(r'__(.+?)__', dotAll: true), (m) => m.group(1)!)
      .replaceAllMapped(RegExp(r'`(.+?)`', dotAll: true), (m) => m.group(1)!)
      .replaceAllMapped(RegExp(r'\|\|(.+?)\|\|', dotAll: true), (m) => '▒▒▒')
      .replaceAll('\n', ' ');
}

String _previewOf(Map<String, dynamic>? m) {
  if (m == null || m.isEmpty) return 'Message';
  switch ((m['type'] ?? m['media_type'] ?? 'text').toString()) {
    case 'image':
      return '📷 Photo';
    case 'video':
      return '🎬 Video';
    case 'audio':
      return m['file_name'] != null ? '🎵 ${m['file_name']}' : '🎤 Voice message';
    case 'gif':
      return 'GIF';
    case 'sticker':
      return 'Sticker';
    case 'file':
      return '📎 ${m['file_name'] ?? 'File'}';
    case 'location':
      return '📍 Location';
    case 'live_location':
      return '📍 Live location';
    case 'contact':
      return '👤 ${m['contact_name'] ?? 'Contact'}';
    case 'system':
      return (m['content'] ?? m['text'] ?? '').toString();
    default:
      final t = (m['text'] ?? '').toString();
      return t.isEmpty ? 'Message' : t;
  }
}

String? _firstUrl(String text) {
  final m = RegExp(r'https?://[^\s]+').firstMatch(text);
  if (m == null) return null;
  var u = m.group(0)!;
  while (u.isNotEmpty && '.,;:!?)'.contains(u[u.length - 1])) {
    u = u.substring(0, u.length - 1);
  }
  return u.isEmpty ? null : u;
}

Future<void> _openUrl(String url) async {
  try {
    await launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication);
  } catch (_) {}
}

// ═══════════════════════════════════════════════════════════════════════════
// NATIVE RECORDER (talks directly to MainActivity.kt)
// ═══════════════════════════════════════════════════════════════════════════
class _LocalRecorder {
  static const _channel = MethodChannel('com.lumachat.app/recorder');
  Future<void> start(String path) async => await _channel.invokeMethod('start', {'path': path});
  Future<String?> stop() async => await _channel.invokeMethod<String>('stop');
  Future<void> cancel() async {
    try {
      await _channel.invokeMethod('cancel');
    } catch (_) {}
  }

  /// Optional: returns MediaRecorder.getMaxAmplitude() if MainActivity implements
  /// an `amplitude` method. Returns null when it is not available.
  Future<int?> amplitude() async {
    try {
      return await _channel.invokeMethod<int>('amplitude');
    } catch (_) {
      return null;
    }
  }
}

class _LumaContact {
  final String name;
  final String phone;
  final String uid;
  final String? avatar;
  _LumaContact({required this.name, required this.phone, required this.uid, this.avatar});
}

class _ChatChoice {
  final String id;
  final String title;
  final String? avatar;
  _ChatChoice({required this.id, required this.title, this.avatar});
}


// ═══════════════════════════════════════════════════════════════════════════
// SCREEN
// ═══════════════════════════════════════════════════════════════════════════
class ChatScreen extends StatefulWidget {
  final String? chatId;
  final String? chatName;
  final String? chatAvatar;
  final String? otherUserId;

  const ChatScreen({
    super.key,
    this.chatId,
    this.chatName,
    this.chatAvatar,
    this.otherUserId,
  });

  @override
  State<ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends State<ChatScreen> with WidgetsBindingObserver {
  // Controllers
  final _messageController = TextEditingController();
  final _messageFocus = FocusNode();
  final _scrollController = ScrollController();
  final _picker = ImagePicker();
  final _audioPlayer = AudioPlayer();
  final _LocalRecorder _audioRecorder = _LocalRecorder();

  // Session / chat identity
  String? _currentUserId;
  String? _chatId;
  String? _otherId;
  bool _chatExists = false;
  bool _listenersStarted = false;
  bool _redirected = false;
  String? _loadError;
  bool _isMePremium = false;
  bool _appResumed = true;
  String? _wallpaper;
  Map<String, dynamic>? _myData;
  Map<String, dynamic>? _otherData;
  Map<String, dynamic>? _chatData;
  List<String> _myBlocked = [];

  // UI state
  String? _activePanel; // 'emoji' | 'gif' | 'sticker'
  bool _hasText = false;
  bool _hasSelection = false;
  bool _atBottom = true;
  bool _showFab = false;

  // Messages
  List<Map<String, dynamic>> _live = [];
  List<Map<String, dynamic>> _older = [];
  List<Map<String, dynamic>> _visible = [];
  List<Map<String, dynamic>> _pins = [];
  int _pinIndex = 0;
  bool _messagesLoaded = false;
  bool _loadingOlder = false;
  bool _noMoreOlder = false;
  bool _firstSnapshotDone = false;

  // Unread
  int _unreadCount = 0;
  String? _firstUnreadId;
  String? _dividerAnchorId;
  int _dividerCount = 0;
  final Set<String> _deliveredTried = {};
  final Set<String> _readTried = {};
  final Set<String> _expiredDeleted = {};

  // Subscriptions / timers
  StreamSubscription? _messageSub;
  StreamSubscription? _chatSub;
  StreamSubscription? _typingSub;
  StreamSubscription? _premiumSub;
  StreamSubscription? _pinSub;
  StreamSubscription? _otherSub;
  Timer? _loadingFallback;
  Timer? _ticker;
  Timer? _flashTimer;
  Timer? _typingTimer;

  // Reply / edit / selection
  String? _replyingTo;
  String? _editingId;
  bool _multiSelectMode = false;
  final Set<String> _selectedIds = {};
  String? _highlightId;
  final Map<String, GlobalKey> _msgKeys = {};

  // Typing
  DateTime? _otherTypingAt;
  DateTime? _lastTypingWrite;
  bool _lastTypingShown = false;

  // Voice recording
  bool _isRecording = false;
  bool _recStarting = false;
  bool _recFinishEarly = false;
  bool _recCancel = false;
  int _recSeconds = 0;
  DateTime? _recStart;
  Timer? _ampTimer;
  bool _ampSupported = true;
  final List<double> _ampSamples = [];

  // Audio playback
  String? _loadedAudioId;

  // Downloads
  final Map<String, String> _localCache = {};

  // Attachment sheet
  int _selectedBottomTab = 0;
  final List<AssetEntity> _selectedAssets = [];
  Future<List<AssetEntity>>? _assetsFuture;
  Future<List<AssetEntity>>? _audioFuture;
  Future<List<_LumaContact>>? _contactsFuture;
  final _contactSearch = TextEditingController();
  final _musicSearch = TextEditingController();

  // Live location
  StreamSubscription<Position>? _liveSub;
  Timer? _liveTimer;
  String? _liveMsgId;
  DateTime? _liveUntil;

  // ─── Firestore refs ───
  DocumentReference<Map<String, dynamic>> get _chatRef =>
      FirebaseFirestore.instance.collection('chats').doc(_chatId ?? '_none_');
  CollectionReference<Map<String, dynamic>> get _msgs => _chatRef.collection('messages');
  DocumentReference<Map<String, dynamic>> _msgDoc(String id) => _msgs.doc(id);
  CollectionReference<Map<String, dynamic>> get _pinsRef => _chatRef.collection('pinned_messages');

  // ─── Derived state ───
  bool get _iBlockedOther => _otherId != null && _myBlocked.contains(_otherId);
  bool get _blockedByOther {
    final b = _otherData?['blocked_users'];
    return b is List && b.contains(_currentUserId);
  }

  int get _autoDeleteSeconds => (_chatData?['auto_delete_seconds'] as num?)?.toInt() ?? 0;

  DateTime? get _clearedAt {
    final t = _chatData?['participants_data']?[_currentUserId]?['cleared_at'];
    return t is Timestamp ? t.toDate() : null;
  }

  String _myName() => (_myData?[_kUserNameField] ?? 'You').toString();

  String _otherName() {
    final n = _otherData?[_kUserNameField];
    if (n is String && n.isNotEmpty) return n;
    final w = widget.chatName;
    if (w != null && w.isNotEmpty) return w;
    return 'Chat';
  }

  String? _otherAvatar() {
    final a = _otherData?[_kUserAvatarField];
    if (a is String && a.isNotEmpty) return a;
    final w = widget.chatAvatar;
    return (w != null && w.isNotEmpty) ? w : null;
  }

  String _nameOf(String? uid) => uid == _currentUserId ? _myName() : _otherName();

  String _statusText() {
    if (_iBlockedOther || _blockedByOther) return '';
    if (_isOtherTyping()) return 'typing…';
    final d = _otherData;
    if (d == null) return '';
    if (d[_kUserOnlineField] == true) return 'online';
    final ls = d['last_seen'] ?? d['last_active'];
    if (ls is Timestamp) {
      final t = ls.toDate();
      final now = DateTime.now();
      if (_sameDay(t, now)) return 'last seen today at ${DateFormat('HH:mm').format(t)}';
      if (_sameDay(t, now.subtract(const Duration(days: 1)))) return 'last seen yesterday at ${DateFormat('HH:mm').format(t)}';
      return 'last seen ${DateFormat('MMM d').format(t)}';
    }
    return 'offline';
  }

  bool _isOtherTyping() {
    final t = _otherTypingAt;
    return t != null && DateTime.now().difference(t).inSeconds < 20;
  }

  String? _hardBlockReason() {
    if (_currentUserId == null) return 'Sign in to send messages';
    if (_chatId == null) return 'This chat is not ready yet';
    if (_iBlockedOther) return 'You blocked this user';
    if (_blockedByOther) return 'You can\'t send messages to this user';
    return null;
  }

  String? _blockReason() => _hardBlockReason();

  String _friendlyError(Object e) {
    final s = e.toString();
    if (s.contains('permission-denied')) return 'Firestore rules blocked this chat (permission-denied)';
    if (s.contains('unavailable') || s.contains('TimeoutException')) return 'Network problem. Check your connection';
    return s;
  }

  String _durLabel(int s) {
    if (s % 2592000 == 0) return '${s ~/ 2592000} month';
    if (s % 604800 == 0) return '${s ~/ 604800} week';
    if (s % 86400 == 0) return '${s ~/ 86400} day';
    if (s % 3600 == 0) return '${s ~/ 3600} hour';
    return '$s seconds';
  }

  // ═══════════════════════════════════════════════════════════════════════
  // LIFECYCLE
  // ═══════════════════════════════════════════════════════════════════════
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _messageController.addListener(_onComposerChanged);
    _scrollController.addListener(_onScroll);
    // Safety net: the list can never be stuck on a spinner.
    _loadingFallback = Timer(const Duration(seconds: 5), () {
      if (mounted && !_messagesLoaded) setState(() => _messagesLoaded = true);
    });
    _ticker = Timer.periodic(const Duration(seconds: 1), (_) => _onTick());
    _init();
  }

  void _init() {
    final auth = Provider.of<LumaAuthProvider>(context, listen: false);
    _currentUserId = auth.user?.uid ?? auth.mockUserId;
    _otherId = widget.otherUserId;
    if (_currentUserId == null) {
      _messagesLoaded = true;
      return;
    }
    _listenToMe();
    if (_otherId != null) _listenToOther(_otherId!);
    _resolveChat();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _appResumed = state == AppLifecycleState.resumed;
    if (_appResumed) _syncReceipts();
    if (!_appResumed) _stopTyping();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _loadingFallback?.cancel();
    _ticker?.cancel();
    _flashTimer?.cancel();
    _ampTimer?.cancel();
    _typingTimer?.cancel();
    _messageSub?.cancel();
    _chatSub?.cancel();
    _typingSub?.cancel();
    _premiumSub?.cancel();
    _pinSub?.cancel();
    _otherSub?.cancel();
    _stopTyping();
    _stopLiveLocation(updateUi: false);
    _messageController.dispose();
    _messageFocus.dispose();
    _scrollController.dispose();
    _contactSearch.dispose();
    _musicSearch.dispose();
    _audioPlayer.dispose();
    _audioRecorder.cancel();
    super.dispose();
  }

  void _onTick() {
    if (!mounted) return;
    var changed = false;
    final typing = _isOtherTyping();
    if (typing != _lastTypingShown) {
      _lastTypingShown = typing;
      changed = true;
    }
    if (_isRecording && _recStart != null) {
      final s = DateTime.now().difference(_recStart!).inSeconds;
      if (s != _recSeconds) {
        _recSeconds = s;
        changed = true;
      }
    }
    // Auto-delete: hide expired messages and remove my own expired messages.
    final now = DateTime.now();
    final expired = _visible.where((m) {
      final e = m['expires_at'];
      return e is Timestamp && e.toDate().isBefore(now);
    }).toList();
    if (expired.isNotEmpty) {
      for (final m in expired) {
        final id = m['id'].toString();
        if (m['sender_id'] == _currentUserId && _expiredDeleted.add(id)) {
          _msgDoc(id).delete().catchError((_) {});
        }
      }
      _refreshVisible();
      changed = true;
    }
    if (changed) setState(() {});
  }

  // ═══════════════════════════════════════════════════════════════════════
  // RESOLVING THE CHAT (this is what removes the endless spinner)
  // ═══════════════════════════════════════════════════════════════════════
  String _dmId(String a, String b) => a.compareTo(b) <= 0 ? '${a}_$b' : '${b}_$a';

  Future<String?> _findDirectChat(String me, String other) async {
    final snap = await FirebaseFirestore.instance
        .collection('chats')
        .where('participants', arrayContains: me)
        .limit(200)
        .get()
        .timeout(const Duration(seconds: 10));
    for (final d in snap.docs) {
      final data = d.data();
      final t = (data['type'] ?? 'direct').toString();
      if (t == 'group' || t == 'channel') continue;
      final p = data['participants'];
      if (p is List && p.length == 2 && p.contains(other)) return d.id;
    }
    return null;
  }

  Future<void> _resolveChat() async {
    final me = _currentUserId;
    if (me == null) return;
    if (mounted) setState(() => _loadError = null);
    try {
      var id = widget.chatId;
      if (id == null || id.isEmpty) {
        final other = _otherId;
        if (other == null) {
          if (mounted) {
            setState(() {
              _loadError = 'No chat was selected.';
              _messagesLoaded = true;
            });
          }
          return;
        }
        id = await _findDirectChat(me, other);
        if (id == null) {
          // Brand-new conversation: the chat document is created with the first message.
          if (!mounted) return;
          setState(() {
            _chatId = _dmId(me, other);
            _chatExists = false;
            _messagesLoaded = true;
          });
          _loadWallpaper();
          return;
        }
      }
      if (!mounted) return;
      setState(() {
        _chatId = id;
        _chatExists = true;
      });
      _startListeners();
    } catch (e) {
      if (mounted) {
        setState(() {
          _loadError = _friendlyError(e);
          _messagesLoaded = true;
        });
      }
    }
  }

  void _startListeners() {
    if (_listenersStarted || _chatId == null) return;
    _listenersStarted = true;
    _listenToChat();
    _listenToMessages();
    _listenToPins();
    _listenToTyping();
    _loadWallpaper();
  }

  Future<bool> _ensureChatDoc() async {
    if (_chatExists) return true;
    final me = _currentUserId;
    final other = _otherId;
    final id = _chatId;
    if (me == null || other == null || id == null) return false;
    try {
      await FirebaseFirestore.instance.collection('chats').doc(id).set({
        'type': 'direct',
        'participants': [me, other],
        'participants_data': {
          me: {'role': 'member'},
          other: {'role': 'member'},
        },
        'created_by': me,
        'created_at': FieldValue.serverTimestamp(),
        'last_message': '',
        'last_message_at': FieldValue.serverTimestamp(),
      }, SetOptions(merge: true)).timeout(const Duration(seconds: 15));
      _chatExists = true;
      _startListeners();
      if (mounted) {
        try {
          context.read<ChatProvider>().loadChats();
        } catch (_) {}
      }
      return true;
    } catch (e) {
      _showSnack('Could not start the chat: ${_friendlyError(e)}');
      return false;
    }
  }

  // ═══════════════════════════════════════════════════════════════════════
  // LISTENERS
  // ═══════════════════════════════════════════════════════════════════════
  void _listenToMe() {
    _premiumSub = FirebaseFirestore.instance.collection('users').doc(_currentUserId).snapshots().listen((doc) {
      final d = doc.data();
      if (!mounted || d == null) return;
      setState(() {
        _myData = d;
        _isMePremium = d['is_premium'] == true;
        final b = d['blocked_users'];
        _myBlocked = b is List ? b.map((e) => e.toString()).toList() : [];
      });
    }, onError: (_) {});
  }

  void _listenToOther(String uid) {
    _otherSub?.cancel();
    _otherSub = FirebaseFirestore.instance.collection('users').doc(uid).snapshots().listen((doc) {
      final d = doc.data();
      if (!mounted || d == null) return;
      setState(() => _otherData = d);
    }, onError: (_) {});
  }

  void _redirect(String type, Map<String, dynamic> data) {
    final id = _chatId;
    if (id == null) return;
    final name = (data['name'] ?? data['title'] ?? widget.chatName ?? (type == 'group' ? 'Group' : 'Channel')).toString();
    final avatar = (data['avatar_url'] ?? widget.chatAvatar)?.toString();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      if (type == 'group') {
        Navigator.pushReplacement(
          context,
          MaterialPageRoute(builder: (_) => GroupChatScreen(chatId: id, chatName: name, chatAvatar: avatar)),
        );
      } else {
        Navigator.pushReplacementNamed(context, '/channel', arguments: {'channelId': id, 'channelName': name});
      }
    });
  }

  void _listenToChat() {
    _chatSub = _chatRef.snapshots().listen((doc) {
      if (!mounted || !doc.exists) return;
      final data = doc.data();
      if (data == null) return;
      final type = (data['type'] ?? 'direct').toString();
      if (!_redirected && (type == 'group' || type == 'channel')) {
        _redirected = true;
        _redirect(type, data);
        return;
      }
      setState(() {
        _chatData = data;
        _refreshVisible();
      });
      if (_otherId == null) {
        final p = data['participants'];
        if (p is List) {
          final o = p.map((e) => e.toString()).firstWhere((x) => x != _currentUserId, orElse: () => '');
          if (o.isNotEmpty) {
            _otherId = o;
            _listenToOther(o);
          }
        }
      }
    }, onError: (e) {
      if (mounted) {
        setState(() {
          _loadError = _friendlyError(e);
          _messagesLoaded = true;
        });
      }
    });
  }

  void _listenToMessages() {
    _messageSub = _msgs
        .orderBy('created_at', descending: true)
        .limit(_kPageSize)
        .snapshots(includeMetadataChanges: true)
        .listen((snap) {
      if (!mounted) return;
      final loaded = snap.docs
          .map((d) => <String, dynamic>{'id': d.id, ...d.data(), '_pending': d.metadata.hasPendingWrites})
          .toList();

      setState(() {
        // Messages that fell out of the live window move into the older list (no gaps).
        if (_live.isNotEmpty && loaded.isNotEmpty) {
          final newIds = loaded.map((e) => e['id']).toSet();
          Timestamp? newOldest;
          for (var i = loaded.length - 1; i >= 0; i--) {
            final ts = loaded[i]['created_at'];
            if (ts is Timestamp) {
              newOldest = ts;
              break;
            }
          }
          final oldestTs = newOldest;
          if (oldestTs != null) {
            final dropped = _live.where((m) {
              if (newIds.contains(m['id'])) return false;
              final ts = m['created_at'];
              return ts is Timestamp && ts.compareTo(oldestTs) < 0;
            }).toList();
            if (dropped.isNotEmpty) _older = [...dropped, ..._older];
          }
        }
        _live = loaded;
        _loadError = null;
        if (loaded.isNotEmpty || !snap.metadata.isFromCache) _messagesLoaded = true;
        if (loaded.length < _kPageSize && !snap.metadata.isFromCache) _noMoreOlder = true;
        _refreshVisible();
      });

      if (!_firstSnapshotDone && _messagesLoaded) {
        _firstSnapshotDone = true;
        if (_unreadCount > 0 && _firstUnreadId != null) {
          setState(() {
            _dividerAnchorId = _firstUnreadId;
            _dividerCount = _unreadCount;
          });
          WidgetsBinding.instance.addPostFrameCallback((_) => _jumpToMessage(_dividerAnchorId));
        }
      }
      _syncReceipts();
    }, onError: (e) {
      if (mounted) {
        setState(() {
          _loadError = _friendlyError(e);
          _messagesLoaded = true;
        });
      }
    });
  }

  void _listenToPins() {
    _pinSub = _pinsRef.orderBy('pinned_at', descending: true).snapshots().listen((snap) {
      if (!mounted) return;
      setState(() {
        _pins = snap.docs.map((d) => <String, dynamic>{'id': d.id, ...d.data()}).toList();
        if (_pinIndex >= _pins.length) _pinIndex = 0;
      });
    }, onError: (_) {});
  }

  void _listenToTyping() {
    _typingSub = _chatRef.collection('typing').snapshots().listen((snap) {
      if (!mounted) return;
      DateTime? at;
      for (final doc in snap.docs) {
        if (doc.id == _currentUserId) continue;
        final data = doc.data();
        if (data['is_typing'] != true) continue;
        final t = data['at'];
        at = t is Timestamp ? t.toDate() : DateTime.now();
      }
      setState(() => _otherTypingAt = at);
    }, onError: (_) {});
  }

  Future<void> _loadWallpaper() async {
    try {
      final doc = await FirebaseFirestore.instance.collection('user_settings').doc(_currentUserId).get();
      if (doc.exists && mounted) {
        final data = doc.data();
        final walls = data?['chat_wallpapers'];
        String? v;
        if (walls is Map && _chatId != null && walls[_chatId] is String) v = walls[_chatId] as String;
        v ??= data?['default_wallpaper'] is String ? data!['default_wallpaper'] as String : null;
        if (v != null && v.isNotEmpty) setState(() => _wallpaper = v);
      }
    } catch (_) {}
  }

  // ═══════════════════════════════════════════════════════════════════════
  // VISIBLE LIST / UNREAD / RECEIPTS
  // ═══════════════════════════════════════════════════════════════════════
  bool _isTrackedIncoming(Map<String, dynamic> m) =>
      m['sender_id'] != _currentUserId &&
      m['type'] != 'system' &&
      m['_pending'] != true &&
      m['deleted_for_everyone'] != true &&
      m.containsKey('read_by');

  void _refreshVisible() {
    final seen = <String>{};
    final out = <Map<String, dynamic>>[];
    final me = _currentUserId;
    final now = DateTime.now();
    final cleared = _clearedAt;
    for (final m in [..._live, ..._older]) {
      final id = m['id']?.toString();
      if (id == null || !seen.add(id)) continue;
      if (m['deleted_for_everyone'] == true) continue;
      final df = m['deleted_for'];
      if (df is List && df.contains(me)) continue;
      final exp = m['expires_at'];
      if (exp is Timestamp && exp.toDate().isBefore(now)) continue;
      if (cleared != null) {
        final ts = m['created_at'];
        if (ts is Timestamp && !ts.toDate().isAfter(cleared)) continue;
      }
      out.add(m);
    }
    _visible = out;

    var c = 0;
    String? first;
    for (final m in out) {
      if (!_live.contains(m)) continue;
      if (!_isTrackedIncoming(m)) continue;
      final rb = m['read_by'];
      if (rb is List && !rb.contains(me)) {
        c++;
        first = m['id']?.toString();
      }
    }
    _unreadCount = c;
    _firstUnreadId = first;
  }

  Future<void> _syncReceipts() async {
    final me = _currentUserId;
    if (me == null || !_appResumed || _chatId == null) return;
    final batch = FirebaseFirestore.instance.batch();
    var n = 0;
    for (final m in _live) {
      if (!_isTrackedIncoming(m)) continue;
      final id = m['id'].toString();
      final dt = m['delivered_to'];
      final rb = m['read_by'];
      final delivered = dt is List && dt.contains(me);
      final read = rb is List && rb.contains(me);
      final upd = <String, dynamic>{};
      if (!delivered && _deliveredTried.add(id)) {
        upd['delivered_to'] = FieldValue.arrayUnion([me]);
      }
      if (_atBottom && !read && _readTried.add(id)) {
        upd['read_by'] = FieldValue.arrayUnion([me]);
        upd['delivered_to'] = FieldValue.arrayUnion([me]);
      }
      if (upd.isNotEmpty) {
        batch.update(_msgDoc(id), upd);
        n++;
        if (n >= 400) break;
      }
    }
    if (n > 0) {
      try {
        await batch.commit();
      } catch (_) {}
    }
  }

  Future<void> _syncOlder(String id) async {
    final idx = _older.indexWhere((m) => m['id'] == id);
    if (idx < 0) return;
    try {
      final d = await _msgDoc(id).get();
      final data = d.data();
      if (!mounted) return;
      setState(() {
        if (d.exists && data != null) {
          _older[idx] = <String, dynamic>{'id': d.id, ...data, '_pending': false};
        }
        _refreshVisible();
      });
    } catch (_) {}
  }

  Future<bool> _loadOlder() async {
    if (_loadingOlder || _noMoreOlder || _currentUserId == null || !_chatExists) return false;
    Timestamp? oldest;
    final raw = [..._live, ..._older];
    for (var i = raw.length - 1; i >= 0; i--) {
      final ts = raw[i]['created_at'];
      if (ts is Timestamp) {
        oldest = ts;
        break;
      }
    }
    if (oldest == null) return false;
    setState(() => _loadingOlder = true);
    try {
      final snap = await _msgs
          .orderBy('created_at', descending: true)
          .startAfter([oldest])
          .limit(_kPageSize)
          .get()
          .timeout(const Duration(seconds: 15));
      if (!mounted) return false;
      final more = snap.docs
          .map((d) => <String, dynamic>{'id': d.id, ...d.data(), '_pending': false})
          .toList();
      setState(() {
        _older = [..._older, ...more];
        _loadingOlder = false;
        if (more.length < _kPageSize) _noMoreOlder = true;
        _refreshVisible();
      });
      return more.isNotEmpty;
    } catch (_) {
      if (mounted) setState(() => _loadingOlder = false);
      return false;
    }
  }

  // ═══════════════════════════════════════════════════════════════════════
  // SCROLL / JUMP
  // ═══════════════════════════════════════════════════════════════════════
  void _onScroll() {
    if (!_scrollController.hasClients) return;
    final p = _scrollController.position;
    final atBottom = p.pixels < 80;
    final showFab = p.pixels > 400;
    if (atBottom != _atBottom || showFab != _showFab) {
      setState(() {
        _atBottom = atBottom;
        _showFab = showFab;
      });
      if (atBottom) _syncReceipts();
    }
    if (p.pixels > p.maxScrollExtent - 300) _loadOlder();
  }

  void _scrollToBottom() {
    if (!_scrollController.hasClients) return;
    _scrollController.animateTo(0, duration: const Duration(milliseconds: 300), curve: Curves.easeOut);
  }

  GlobalKey _keyFor(String id) => _msgKeys.putIfAbsent(id, () => GlobalKey());

  Future<void> _jumpToMessage(String? id, {int depth = 0}) async {
    if (id == null || !mounted) return;
    final idx = _visible.indexWhere((m) => m['id'] == id);
    if (idx < 0) {
      if (depth < 8 && !_noMoreOlder) {
        await _loadOlder();
        if (!mounted) return;
        return _jumpToMessage(id, depth: depth + 1);
      }
      _showSnack('Original message was not found');
      return;
    }
    for (var attempt = 0; attempt < 10; attempt++) {
      final ctx = _msgKeys[id]?.currentContext;
      if (ctx != null) {
        await Scrollable.ensureVisible(ctx, duration: const Duration(milliseconds: 300), alignment: 0.4, curve: Curves.easeOut);
        _flash(id);
        return;
      }
      if (!_scrollController.hasClients) return;
      final max = _scrollController.position.maxScrollExtent;
      final est = (max * idx / math.max(1, _visible.length)).clamp(0.0, max).toDouble();
      _scrollController.jumpTo(est);
      await Future.delayed(const Duration(milliseconds: 60));
      if (!mounted) return;
    }
  }

  void _flash(String id) {
    setState(() => _highlightId = id);
    _flashTimer?.cancel();
    _flashTimer = Timer(const Duration(milliseconds: 1400), () {
      if (mounted) setState(() => _highlightId = null);
    });
  }

  // ═══════════════════════════════════════════════════════════════════════
  // COMPOSER STATE
  // ═══════════════════════════════════════════════════════════════════════
  void _onComposerChanged() {
    final text = _messageController.text;
    final sel = _messageController.selection;
    final has = text.trim().isNotEmpty;
    final hasSel = sel.isValid && !sel.isCollapsed;
    if (has != _hasText || hasSel != _hasSelection) {
      setState(() {
        _hasText = has;
        _hasSelection = hasSel;
      });
    }
  }

  void _wrapSelection(String open, [String? close]) {
    close ??= open;
    final t = _messageController.text;
    final s = _messageController.selection;
    if (!s.isValid || s.isCollapsed) return;
    final a = math.min(s.start, s.end);
    final b = math.max(s.start, s.end);
    final hasBefore = a >= open.length && t.substring(a - open.length, a) == open;
    final hasAfter = b + close.length <= t.length && t.substring(b, b + close.length) == close;
    if (hasBefore && hasAfter) {
      final nt = t.substring(0, a - open.length) + t.substring(a, b) + t.substring(b + close.length);
      _messageController.value = TextEditingValue(
        text: nt,
        selection: TextSelection(baseOffset: a - open.length, extentOffset: b - open.length),
      );
      return;
    }
    final nt = t.replaceRange(a, b, '$open${t.substring(a, b)}$close');
    _messageController.value = TextEditingValue(
      text: nt,
      selection: TextSelection(baseOffset: a + open.length, extentOffset: b + open.length),
    );
  }

  void _onTyping(String val) {
    if (val.isEmpty) {
      _stopTyping();
      return;
    }
    if (!_chatExists || _currentUserId == null) return;
    final now = DateTime.now();
    if (_lastTypingWrite == null || now.difference(_lastTypingWrite!).inSeconds >= 3) {
      _lastTypingWrite = now;
      _chatRef.collection('typing').doc(_currentUserId).set({'is_typing': true, 'at': FieldValue.serverTimestamp()}).catchError((_) {});
    }
    _typingTimer?.cancel();
    _typingTimer = Timer(const Duration(seconds: 4), _stopTyping);
  }

  void _stopTyping() {
    _typingTimer?.cancel();
    if (_lastTypingWrite != null && _currentUserId != null && _chatId != null) {
      _lastTypingWrite = null;
      _chatRef.collection('typing').doc(_currentUserId).delete().catchError((_) {});
    }
  }

  // ═══════════════════════════════════════════════════════════════════════
  // SENDING
  // ═══════════════════════════════════════════════════════════════════════
  Future<String?> _postMessage(Map<String, dynamic> data, {bool system = false}) async {
    final me = _currentUserId;
    if (me == null) return null;
    if (!system) {
      final reason = _blockReason();
      if (reason != null) {
        _showSnack(reason);
        return null;
      }
    }
    if (!await _ensureChatDoc()) return null;

    final msgId = const Uuid().v4();
    final ad = _autoDeleteSeconds;
    final payload = <String, dynamic>{
      'id': msgId,
      'sender_id': me,
      'created_at': FieldValue.serverTimestamp(),
      'is_read': false,
      'read_by': [me],
      'delivered_to': [me],
      if (ad > 0 && !system) 'expires_at': Timestamp.fromDate(DateTime.now().add(Duration(seconds: ad))),
      ...data,
    };
    // Not awaited: the local snapshot already shows the message (works offline too).
    _msgs.doc(msgId).set(payload).catchError((e) {
      _showSnack('Send failed: $e');
    });
    _chatRef.update({
      'last_message': _stripFormatting(_previewOf(payload)),
      'last_message_at': FieldValue.serverTimestamp(),
      'last_message_sender_id': me,
    }).catchError((_) {});
    if (!_atBottom) Future.delayed(const Duration(milliseconds: 200), _scrollToBottom);
    return msgId;
  }

  Future<void> _sendText() async {
    final text = _messageController.text.trim();
    if (text.isEmpty) return;
    if (_editingId != null) {
      await _commitEdit(text);
      return;
    }
    final reason = _blockReason();
    if (reason != null) {
      _showSnack(reason);
      return;
    }
    if (!await _ensureChatDoc()) return;

    final replyId = _replyingTo;
    final reply = replyId != null ? _findMessage(replyId) : null;
    _messageController.clear();
    _stopTyping();
    setState(() => _replyingTo = null);

    await _postMessage({
      'text': text,
      'type': 'text',
      'media_type': 'text',
      if (replyId != null) 'reply_to': replyId,
      if (reply != null) 'reply_to_content': _stripFormatting(_previewOf(reply)),
      if (reply != null) 'reply_to_sender': _nameOf(reply['sender_id']?.toString()),
    });
  }

  Future<void> _commitEdit(String text) async {
    final id = _editingId;
    if (id == null) return;
    _messageController.clear();
    setState(() => _editingId = null);
    try {
      await _msgDoc(id).update({'text': text, 'edited': true, 'edited_at': FieldValue.serverTimestamp()});
      final last = _visible.isNotEmpty ? _visible.first : null;
      if (last != null && last['id'] == id) {
        _chatRef.update({'last_message': _stripFormatting(text)}).catchError((_) {});
      }
      _syncOlder(id);
    } catch (e) {
      _showSnack('Edit failed: $e');
    }
  }

  Future<void> _sendSticker(String url) async {
    final id = await _postMessage({'type': 'sticker', 'media_type': 'sticker', 'media_url': url});
    if (id != null && mounted) setState(() => _activePanel = null);
  }

  Future<void> _sendGif(String url) async {
    final id = await _postMessage({'type': 'gif', 'media_type': 'gif', 'media_url': url});
    if (id != null && mounted) setState(() => _activePanel = null);
  }

  Future<void> _pickAndSendMedia(String type) async {
    Navigator.pop(context);
    final x = type == 'image'
        ? await _picker.pickImage(source: ImageSource.gallery, imageQuality: 90)
        : await _picker.pickVideo(source: ImageSource.gallery);
    if (x == null) return;

    final file = File(x.path);
    final size = await file.length();
    final limit = _isMePremium ? (5 * 1024 * 1024 * 1024) : (200 * 1024 * 1024);
    if (size > limit) {
      _showSnack(_isMePremium ? 'Max 5GB' : 'Upgrade to Premium to send files over 200MB!');
      return;
    }

    _showSnack('Uploading...');
    final url = type == 'image'
        ? await CloudinaryService.uploadImage(file, 'luma/chats')
        : await CloudinaryService.uploadVideo(file, 'luma/chats');
    if (url == null) {
      _showSnack('Upload failed');
      return;
    }
    if (mounted) ScaffoldMessenger.of(context).hideCurrentSnackBar();
    await _postMessage({'type': type, 'media_type': type, 'media_url': url});
  }

  Future<void> _sendAssets(List<AssetEntity> assets) async {
    final limit = _isMePremium ? (5 * 1024 * 1024 * 1024) : (200 * 1024 * 1024);
    for (var i = 0; i < assets.length; i++) {
      final a = assets[i];
      try {
        final file = await a.file;
        if (file == null) continue;
        final size = await file.length();
        if (size > limit) {
          _showSnack(_isMePremium ? 'Max 5GB' : 'Upgrade to Premium to send files over 200MB!');
          continue;
        }
        final isVideo = a.type == AssetType.video;
        _showSnack('Uploading ${i + 1}/${assets.length}...');
        final url = isVideo
            ? await CloudinaryService.uploadVideo(file, 'luma/chats')
            : await CloudinaryService.uploadImage(file, 'luma/chats');
        if (url == null) {
          _showSnack('Upload failed');
          continue;
        }
        await _postMessage({
          'type': isVideo ? 'video' : 'image',
          'media_type': isVideo ? 'video' : 'image',
          'media_url': url,
        });
      } catch (e) {
        _showSnack('Send failed: $e');
      }
    }
    if (mounted) ScaffoldMessenger.of(context).hideCurrentSnackBar();
  }

  Future<void> _pickFromCamera({bool closeSheet = false}) async {
    final reason = _blockReason();
    if (reason != null) {
      _showSnack(reason);
      return;
    }
    try {
      if (closeSheet) {
        Navigator.pop(context);
        await Future.delayed(const Duration(milliseconds: 300));
      }
      final XFile? photo = await _picker.pickImage(source: ImageSource.camera);
      if (photo != null) {
        _showSnack('Uploading...');
        final url = await CloudinaryService.uploadImage(File(photo.path), 'luma/chats');
        if (url != null && mounted) {
          ScaffoldMessenger.of(context).hideCurrentSnackBar();
          await _postMessage({'type': 'image', 'media_type': 'image', 'media_url': url});
        } else {
          _showSnack('Upload failed');
        }
      }
    } catch (e) {
      _showSnack('Camera error: $e');
    }
  }

  // ═══════════════════════════════════════════════════════════════════════
  // VOICE RECORDING
  // ═══════════════════════════════════════════════════════════════════════
  Future<void> _startRecording() async {
    if (_isRecording || _recStarting) return;
    final reason = _blockReason();
    if (reason != null) {
      _showSnack(reason);
      return;
    }
    _recStarting = true;
    _recFinishEarly = false;
    try {
      final mic = await Permission.microphone.request();
      if (!mic.isGranted) {
        _showSnack('Microphone permission is required');
        _recStarting = false;
        return;
      }
      final dir = await getTemporaryDirectory();
      final path = '${dir.path}/voice_${DateTime.now().millisecondsSinceEpoch}.m4a';
      await _audioRecorder.start(path);
      HapticFeedback.mediumImpact();
      _ampSamples.clear();
      _ampSupported = true;
      _recStart = DateTime.now();
      if (!mounted) return;
      setState(() {
        _isRecording = true;
        _recSeconds = 0;
        _recCancel = false;
      });
      _ampTimer?.cancel();
      _ampTimer = Timer.periodic(const Duration(milliseconds: 90), (_) async {
        if (!_isRecording) return;
        final a = await _audioRecorder.amplitude();
        if (a == null) {
          _ampSupported = false;
          _ampTimer?.cancel();
          return;
        }
        final v = _c01(a / 32767.0);
        _ampSamples.add(math.sqrt(v));
        if (mounted) setState(() {});
      });
    } catch (e) {
      _showSnack('Could not start recording: $e');
    } finally {
      _recStarting = false;
    }
    if (_recFinishEarly) {
      _recFinishEarly = false;
      await _finishRecording(cancel: true);
    }
  }

  List<int>? _buildWaveform() {
    if (!_ampSupported || _ampSamples.length < 8) return null;
    const bars = 40;
    final out = <int>[];
    for (var i = 0; i < bars; i++) {
      final a = (i * _ampSamples.length / bars).floor();
      final b = math.max(a + 1, ((i + 1) * _ampSamples.length / bars).floor());
      var peak = 0.0;
      for (var j = a; j < b && j < _ampSamples.length; j++) {
        peak = math.max(peak, _ampSamples[j]);
      }
      out.add((peak * 31).round());
    }
    return out;
  }

  Future<void> _finishRecording({required bool cancel}) async {
    if (_recStarting) {
      _recFinishEarly = true;
      return;
    }
    if (!_isRecording) return;
    _ampTimer?.cancel();
    final ms = _recStart == null ? 0 : DateTime.now().difference(_recStart!).inMilliseconds;
    final wave = _buildWaveform();
    setState(() {
      _isRecording = false;
      _recCancel = false;
    });
    if (cancel || ms < 800) {
      await _audioRecorder.cancel();
      if (!cancel) _showSnack('Hold to record, release to send');
      return;
    }
    final path = await _audioRecorder.stop();
    if (path == null) return;

    _showSnack('Uploading voice message...');
    final url = await CloudinaryService.uploadAudio(File(path), 'luma/voices');
    if (url == null) {
      _showSnack('Upload failed');
      return;
    }
    if (mounted) ScaffoldMessenger.of(context).hideCurrentSnackBar();
    await _postMessage({
      'type': 'audio',
      'media_type': 'audio',
      'media_url': url,
      'duration': math.max(1, (ms / 1000).round()),
      if (wave != null) 'waveform': wave,
    });
  }

  // ═══════════════════════════════════════════════════════════════════════
  // AUDIO PLAYBACK
  // ═══════════════════════════════════════════════════════════════════════
  Future<void> _togglePlay(Map<String, dynamic> m) async {
    final id = m['id'].toString();
    final url = m['media_url']?.toString();
    if (url == null) return;
    try {
      if (_loadedAudioId == id) {
        if (_audioPlayer.processingState == ProcessingState.completed) {
          await _audioPlayer.seek(Duration.zero);
          _audioPlayer.play();
        } else if (_audioPlayer.playing) {
          await _audioPlayer.pause();
        } else {
          _audioPlayer.play();
        }
        return;
      }
      setState(() => _loadedAudioId = id);
      await _audioPlayer.setUrl(url);
      _audioPlayer.play();
    } catch (e) {
      _showSnack('Playback failed: $e');
      if (mounted) setState(() => _loadedAudioId = null);
    }
  }

  void _seekAudio(Map<String, dynamic> m, double frac, Duration total) {
    if (_loadedAudioId != m['id'].toString() || total == Duration.zero) {
      _togglePlay(m);
      return;
    }
    _audioPlayer.seek(Duration(milliseconds: (total.inMilliseconds * _c01(frac)).round()));
  }

  // ═══════════════════════════════════════════════════════════════════════
  // DOWNLOAD (cached, with progress)
  // ═══════════════════════════════════════════════════════════════════════
  Future<String?> _download(String url, {required String ext, String? fileName}) async {
    final cached = _localCache[url];
    if (cached != null && File(cached).existsSync()) return cached;

    final dir = await getApplicationDocumentsDirectory();
    final folder = Directory('${dir.path}/luma_downloads');
    if (!folder.existsSync()) folder.createSync(recursive: true);
    final safe = (fileName != null && fileName.isNotEmpty)
        ? fileName.replaceAll(RegExp(r'[^\w\.\- ]'), '_')
        : 'luma.$ext';
    final path = '${folder.path}/${url.hashCode.abs()}_$safe';
    final f = File(path);
    if (f.existsSync()) {
      _localCache[url] = path;
      return path;
    }

    final progress = ValueNotifier<double?>(null);
    var dialogShown = false;
    if (mounted) {
      dialogShown = true;
      showDialog(
        context: context,
        barrierDismissible: false,
        builder: (_) => AlertDialog(
          content: ValueListenableBuilder<double?>(
            valueListenable: progress,
            builder: (_, v, __) => Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(v == null ? 'Downloading…' : 'Downloading… ${(v * 100).round()}%'),
                const SizedBox(height: 14),
                LinearProgressIndicator(value: v),
              ],
            ),
          ),
        ),
      );
    }
    final client = http.Client();
    try {
      final res = await client.send(http.Request('GET', Uri.parse(url))).timeout(const Duration(seconds: 30));
      if (res.statusCode != 200) throw Exception('HTTP ${res.statusCode}');
      final total = res.contentLength ?? 0;
      final sink = f.openWrite();
      var got = 0;
      await for (final chunk in res.stream) {
        sink.add(chunk);
        got += chunk.length;
        if (total > 0) progress.value = got / total;
      }
      await sink.close();
      _localCache[url] = path;
      return path;
    } catch (e) {
      if (f.existsSync()) {
        try {
          f.deleteSync();
        } catch (_) {}
      }
      rethrow;
    } finally {
      client.close();
      if (dialogShown && mounted) Navigator.of(context, rootNavigator: true).pop();
      progress.dispose();
    }
  }

  Future<void> _openMedia(Map<String, dynamic> m) async {
    final url = m['media_url']?.toString();
    if (url == null) return;
    final type = (m['type'] ?? '').toString();
    final ext = type == 'image'
        ? 'jpg'
        : type == 'video'
            ? 'mp4'
            : type == 'audio'
                ? 'm4a'
                : 'bin';
    try {
      final path = await _download(url, ext: ext, fileName: m['file_name']?.toString());
      if (path == null || !mounted) return;
      if (type == 'image') {
        Navigator.push(context, MaterialPageRoute(builder: (_) => _ImageViewerScreen(imagePath: path)));
      } else {
        await OpenFilex.open(path);
      }
    } catch (e) {
      _showSnack('Download failed: $e');
    }
  }

  // ═══════════════════════════════════════════════════════════════════════
  // MESSAGE ACTIONS
  // ═══════════════════════════════════════════════════════════════════════
  Map<String, dynamic>? _findMessage(String? id) {
    if (id == null) return null;
    for (final m in _visible) {
      if (m['id'] == id) return m;
    }
    return null;
  }

  void _startReply(Map<String, dynamic> m) {
    if (_hardBlockReason() != null) return;
    setState(() {
      _replyingTo = m['id'].toString();
      _editingId = null;
    });
    _messageFocus.requestFocus();
  }

  void _startEdit(Map<String, dynamic> m) {
    final text = (m['text'] ?? '').toString();
    setState(() {
      _editingId = m['id'].toString();
      _replyingTo = null;
      _messageController.text = text;
      _messageController.selection = TextSelection.collapsed(offset: text.length);
    });
    _messageFocus.requestFocus();
  }

  void _cancelEdit() {
    _messageController.clear();
    setState(() => _editingId = null);
  }

  Future<void> _toggleReaction(Map<String, dynamic> m, String emoji) async {
    final me = _currentUserId;
    if (me == null) return;
    final id = m['id'].toString();
    final r = m['reactions'];
    final has = r is Map && r[emoji] is List && (r[emoji] as List).contains(me);
    try {
      await _msgDoc(id).update(<Object, Object?>{
        FieldPath(['reactions', emoji]): has ? FieldValue.arrayRemove([me]) : FieldValue.arrayUnion([me]),
      });
      _syncOlder(id);
    } catch (e) {
      _showSnack('Could not react: $e');
    }
  }

  Future<void> _pinMessage(Map<String, dynamic> m) async {
    final id = m['id'].toString();
    try {
      await _pinsRef.doc(id).set({
        'message_id': id,
        'pinned_at': FieldValue.serverTimestamp(),
        'pinned_by': _currentUserId,
        'preview': _stripFormatting(_previewOf(m)),
      });
      await _postMessage({
        'type': 'system',
        'media_type': 'system',
        'content': '${_myName()} pinned a message',
        'system_kind': 'pin',
        'target_id': id,
      }, system: true);
    } catch (e) {
      _showSnack('Could not pin: $e');
    }
  }

  Future<void> _unpin(String messageId) async {
    try {
      await _pinsRef.doc(messageId).delete();
    } catch (e) {
      _showSnack('Could not unpin: $e');
    }
  }

  Future<bool> _confirm(String title, String body, {String action = 'Delete'}) async {
    final r = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(title),
        content: Text(body),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          TextButton(onPressed: () => Navigator.pop(ctx, true), child: Text(action, style: const TextStyle(color: Colors.red))),
        ],
      ),
    );
    return r == true;
  }

  Future<void> _deleteForMe(String id) async {
    try {
      await _msgDoc(id).update({'deleted_for': FieldValue.arrayUnion([_currentUserId])});
      _syncOlder(id);
    } catch (e) {
      _showSnack('Delete failed: $e');
    }
  }

  Future<void> _deleteForEveryone(String id) async {
    try {
      await _msgDoc(id).update({'deleted_for_everyone': true, 'text': 'Deleted'});
      if (_pins.any((p) => p['message_id'] == id)) await _unpin(id);
      _syncOlder(id);
    } catch (e) {
      _showSnack('Delete failed: $e');
    }
  }

  Future<void> _processAiAction(String action, String text) async {
    if (!_isMePremium) {
      _showSnack('Upgrade to Premium to use AI tools!');
      return;
    }
    showDialog(context: context, barrierDismissible: false, builder: (_) => const Center(child: CircularProgressIndicator()));
    try {
      final model = GenerativeModel(model: _kGeminiModel, apiKey: ApiConfig.geminiApiKey);
      final prompt = action == 'summarize'
          ? 'Summarize this message: "$text"'
          : 'Translate this to English: "$text"';
      final response = await model.generateContent([Content.text(prompt)]);
      if (mounted) {
        Navigator.of(context, rootNavigator: true).pop();
        showDialog(
          context: context,
          builder: (_) => AlertDialog(
            title: Text(action.toUpperCase()),
            content: Text(response.text ?? 'No response'),
            actions: [TextButton(onPressed: () => Navigator.pop(context), child: const Text('Close'))],
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        Navigator.of(context, rootNavigator: true).pop();
        _showSnack('AI Error: $e');
      }
    }
  }

  // ─── Forward ───
  Future<List<_ChatChoice>> _loadForwardTargets() async {
    final me = _currentUserId;
    if (me == null) return [];
    final snap = await FirebaseFirestore.instance
        .collection('chats')
        .where('participants', arrayContains: me)
        .limit(50)
        .get()
        .timeout(const Duration(seconds: 15));
    final futures = snap.docs.map((d) async {
      final data = d.data();
      var title = (data['name'] ?? data['group_name'] ?? '').toString();
      String? avatar = (data['avatar_url'] ?? data['photo_url'])?.toString();
      final parts = (data['participants'] as List?)?.map((e) => e.toString()).toList() ?? [];
      if (title.isEmpty && parts.length == 2) {
        final other = parts.firstWhere((p) => p != me, orElse: () => '');
        if (other.isNotEmpty) {
          try {
            final u = await FirebaseFirestore.instance.collection('users').doc(other).get();
            title = (u.data()?[_kUserNameField] ?? '').toString();
            avatar = u.data()?[_kUserAvatarField]?.toString();
          } catch (_) {}
        }
      }
      if (title.isEmpty) title = 'Chat';
      return _ChatChoice(id: d.id, title: title, avatar: avatar);
    });
    return Future.wait(futures);
  }

  Map<String, dynamic> _forwardPayload(Map<String, dynamic> m) {
    const keep = [
      'type', 'media_type', 'text', 'media_url', 'file_name', 'duration', 'waveform',
      'latitude', 'longitude', 'accuracy', 'contact_name', 'contact_phone', 'contact_uid', 'contact_avatar',
    ];
    final out = <String, dynamic>{};
    for (final k in keep) {
      if (m[k] != null) out[k] = m[k];
    }
    if (out['type'] == 'live_location') out['type'] = 'location';
    out['forwarded_from'] = m['forwarded_from'] ?? _nameOf(m['sender_id']?.toString());
    out['forwarded_from_id'] = m['forwarded_from_id'] ?? m['sender_id'];
    return out;
  }

  Future<void> _forwardMessages(List<Map<String, dynamic>> msgs) async {
    final me = _currentUserId;
    if (me == null) return;
    final list = msgs.where((m) => m['type'] != 'system').toList();
    if (list.isEmpty) return;
    list.sort((a, b) => _msgTime(a).compareTo(_msgTime(b)));
    final targets = await showModalBottomSheet<List<_ChatChoice>>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => _ForwardPicker(loader: _loadForwardTargets),
    );
    if (targets == null || targets.isEmpty || !mounted) return;
    try {
      final batch = FirebaseFirestore.instance.batch();
      for (final t in targets) {
        final chatRef = FirebaseFirestore.instance.collection('chats').doc(t.id);
        for (final m in list) {
          final newId = const Uuid().v4();
          final payload = _forwardPayload(m);
          batch.set(chatRef.collection('messages').doc(newId), {
            'id': newId,
            'sender_id': me,
            'created_at': FieldValue.serverTimestamp(),
            'is_read': false,
            'read_by': [me],
            'delivered_to': [me],
            ...payload,
          });
        }
        batch.update(chatRef, {
          'last_message': _stripFormatting(_previewOf(_forwardPayload(list.last))),
          'last_message_at': FieldValue.serverTimestamp(),
          'last_message_sender_id': me,
        });
      }
      await batch.commit();
      _showSnack('Forwarded to ${targets.length} chat${targets.length == 1 ? '' : 's'}');
      if (mounted && _multiSelectMode) {
        setState(() {
          _multiSelectMode = false;
          _selectedIds.clear();
        });
      }
    } catch (e) {
      _showSnack('Forward failed: $e');
    }
  }

  // ═══════════════════════════════════════════════════════════════════════
  // LOCATION (current + live)
  // ═══════════════════════════════════════════════════════════════════════
  Future<void> _sendCurrentLocation(Position pos) async {
    Navigator.pop(context);
    try {
      await _postMessage({
        'type': 'location',
        'media_type': 'location',
        'latitude': pos.latitude,
        'longitude': pos.longitude,
        'accuracy': pos.accuracy,
        'text': 'https://maps.google.com/?q=${pos.latitude},${pos.longitude}',
      });
    } catch (e) {
      _showSnack('Could not send location: $e');
    }
  }

  Future<void> _startLiveLocation(Position pos, Duration duration) async {
    Navigator.pop(context);
    try {
      await _stopLiveLocation();
      final until = DateTime.now().add(duration);
      final id = await _postMessage({
        'type': 'live_location',
        'media_type': 'location',
        'latitude': pos.latitude,
        'longitude': pos.longitude,
        'accuracy': pos.accuracy,
        'live_active': true,
        'live_until': Timestamp.fromDate(until),
        'text': 'https://maps.google.com/?q=${pos.latitude},${pos.longitude}',
      });
      if (id == null) return;
      _liveMsgId = id;
      if (mounted) setState(() => _liveUntil = until);
      _liveSub = Geolocator.getPositionStream(
        locationSettings: const LocationSettings(accuracy: LocationAccuracy.high, distanceFilter: 10),
      ).listen((p) {
        _msgDoc(id).update({
          'latitude': p.latitude,
          'longitude': p.longitude,
          'accuracy': p.accuracy,
          'updated_at': FieldValue.serverTimestamp(),
        }).catchError((_) {});
      }, onError: (_) {});
      _liveTimer = Timer(duration, () => _stopLiveLocation());
    } catch (e) {
      _showSnack('Could not start live location: $e');
    }
  }

  Future<void> _stopLiveLocation({bool updateUi = true}) async {
    _liveSub?.cancel();
    _liveTimer?.cancel();
    _liveSub = null;
    _liveTimer = null;
    final id = _liveMsgId;
    _liveMsgId = null;
    if (updateUi && mounted) setState(() => _liveUntil = null);
    if (id != null && _chatId != null) {
      try {
        await _msgDoc(id).update({'live_active': false});
      } catch (_) {}
    }
  }

  // ═══════════════════════════════════════════════════════════════════════
  // LOADERS (assets / contacts)
  // ═══════════════════════════════════════════════════════════════════════
  Future<List<AssetEntity>> _loadAssets(RequestType type, {int size = 90}) async {
    final ps = await PhotoManager.requestPermissionExtend().timeout(const Duration(seconds: 45));
    if (!ps.hasAccess) throw Exception('Permission denied');
    final paths = await PhotoManager.getAssetPathList(type: type, onlyAll: true).timeout(const Duration(seconds: 20));
    if (paths.isEmpty) return [];
    return paths.first.getAssetListPaged(page: 0, size: size).timeout(const Duration(seconds: 20));
  }

  Future<List<_LumaContact>> _loadLumaContacts() async {
    final granted = await FlutterContacts.requestPermission(readonly: true);
    if (!granted) throw Exception('Contacts permission denied');
    final contacts = await FlutterContacts.getContacts(withProperties: true);
    final usersSnap =
        await FirebaseFirestore.instance.collection('users').limit(3000).get().timeout(const Duration(seconds: 25));

    final byPhone = <String, Map<String, dynamic>>{};
    for (final d in usersSnap.docs) {
      final data = d.data();
      final key = _digitsTail('${data[_kUserPhoneField] ?? data[_kUserPhoneLegacyField] ?? ''}');
      if (key.isNotEmpty) byPhone[key] = {'uid': d.id, ...data};
    }

    final out = <_LumaContact>[];
    final seen = <String>{};
    for (final c in contacts) {
      for (final ph in c.phones) {
        final u = byPhone[_digitsTail(ph.number)];
        if (u != null && u['uid'] != _currentUserId && seen.add(u['uid'])) {
          out.add(_LumaContact(
            name: c.displayName.isNotEmpty ? c.displayName : (u[_kUserNameField] ?? 'Unknown').toString(),
            phone: ph.number,
            uid: u['uid'],
            avatar: u[_kUserAvatarField]?.toString(),
          ));
          break;
        }
      }
    }
    out.sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
    return out;
  }

  void _showSnack(String s) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(s)));
  }

  // ═══════════════════════════════════════════════════════════════════════
  // BUILD
  // ═══════════════════════════════════════════════════════════════════════
  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    final topInset = MediaQuery.of(context).padding.top + 62;

    return Scaffold(
      backgroundColor: theme.scaffoldBackgroundColor,
      extendBodyBehindAppBar: true,
      appBar: PreferredSize(
        preferredSize: const Size.fromHeight(62),
        child: _buildHeader(theme, isDark),
      ),
      body: Stack(
        children: [
          _wallpaperLayer(isDark),
          Padding(
            padding: EdgeInsets.only(top: topInset),
            child: Column(
              children: [
                if (_pins.isNotEmpty) _buildPinnedBar(theme, isDark),
                Expanded(child: _buildListArea(theme, isDark)),
                _buildBottomArea(theme, isDark),
              ],
            ),
          ),
        ],
      ),
    );
  }

  // ─── Wallpaper ───
  Widget _wallpaperLayer(bool isDark) {
    final w = _wallpaper;
    if (w == null || w.isEmpty) return const SizedBox.shrink();
    try {
      if (w.startsWith('color:')) {
        return Positioned.fill(child: ColoredBox(color: Color(int.parse(w.substring(6), radix: 16))));
      }
      if (w.startsWith('grad:')) {
        final cols = w.substring(5).split(',').map((h) => Color(int.parse(h, radix: 16))).toList();
        if (cols.length >= 2) {
          return Positioned.fill(
            child: DecoratedBox(
              decoration: BoxDecoration(
                gradient: LinearGradient(begin: Alignment.topLeft, end: Alignment.bottomRight, colors: cols),
              ),
            ),
          );
        }
        return const SizedBox.shrink();
      }
    } catch (_) {
      return const SizedBox.shrink();
    }
    return Positioned.fill(
      child: Stack(
        fit: StackFit.expand,
        children: [
          CachedNetworkImage(imageUrl: w, fit: BoxFit.cover, errorWidget: (_, __, ___) => const SizedBox.shrink()),
          ColoredBox(color: Colors.black.withOpacity(isDark ? 0.35 : 0.06)),
        ],
      ),
    );
  }

  // ─── Header (floating circles + pill, same style as the group screen) ───
  BoxDecoration _headerDecoration(bool isDark, {double radius = 24}) => BoxDecoration(
        color: isDark ? const Color(0xFF1F2C34) : Colors.white,
        borderRadius: BorderRadius.circular(radius),
        boxShadow: [BoxShadow(color: Colors.black.withOpacity(0.12), blurRadius: 6, offset: const Offset(0, 2))],
      );

  Widget _headerCircle({required IconData icon, required VoidCallback onTap}) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    return Container(
      width: 46,
      height: 46,
      decoration: BoxDecoration(
        color: isDark ? const Color(0xFF1F2C34) : Colors.white,
        shape: BoxShape.circle,
        boxShadow: [BoxShadow(color: Colors.black.withOpacity(0.12), blurRadius: 6, offset: const Offset(0, 2))],
      ),
      child: Material(
        color: Colors.transparent,
        shape: const CircleBorder(),
        child: InkWell(
          customBorder: const CircleBorder(),
          onTap: onTap,
          child: Center(child: Icon(icon, color: theme.colorScheme.onSurface, size: 22)),
        ),
      ),
    );
  }

  void _onBackPressed() {
    if (_activePanel != null) {
      setState(() => _activePanel = null);
      return;
    }
    if (_multiSelectMode) {
      setState(() {
        _multiSelectMode = false;
        _selectedIds.clear();
      });
      return;
    }
    Navigator.pop(context);
  }

  Widget _buildHeader(ThemeData theme, bool isDark) {
    final avatar = _otherAvatar();
    final name = _otherName();
    final status = _statusText();
    final typing = _isOtherTyping();
    return SafeArea(
      bottom: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(8, 6, 8, 6),
        child: Row(
          children: [
            _headerCircle(icon: _multiSelectMode ? Icons.close : Icons.arrow_back, onTap: _onBackPressed),
            const SizedBox(width: 8),
            Expanded(
              child: GestureDetector(
                onTap: _showUserSheet,
                child: Container(
                  height: 46,
                  padding: const EdgeInsets.fromLTRB(4, 0, 12, 0),
                  decoration: _headerDecoration(isDark, radius: 26),
                  child: Row(
                    children: [
                      CircleAvatar(
                        radius: 19,
                        backgroundColor: _kAccent.withOpacity(0.15),
                        backgroundImage: avatar != null ? CachedNetworkImageProvider(avatar) : null,
                        child: avatar == null
                            ? Text(name.isNotEmpty ? name[0].toUpperCase() : '?',
                                style: const TextStyle(color: _kAccent, fontWeight: FontWeight.bold))
                            : null,
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            Text(
                              name,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(color: theme.colorScheme.onSurface, fontSize: 15, fontWeight: FontWeight.w700),
                            ),
                            if (status.isNotEmpty)
                              Text(
                                status,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                  color: (typing || status == 'online') ? _kAccent : theme.colorScheme.onSurface.withOpacity(0.55),
                                  fontSize: 12,
                                ),
                              ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
            const SizedBox(width: 8),
            _headerCircle(icon: Icons.search, onTap: () => _openSearch()),
            const SizedBox(width: 8),
            _headerCircle(icon: Icons.more_vert, onTap: _showMoreMenu),
          ],
        ),
      ),
    );
  }

  // ─── Pinned bar (cycles through multiple pins) ───
  Widget _buildPinnedBar(ThemeData theme, bool isDark) {
    final idx = _pinIndex.clamp(0, _pins.length - 1);
    final p = _pins[idx];
    final mid = p['message_id']?.toString();
    final msg = _findMessage(mid);
    final preview = msg != null ? _stripFormatting(_previewOf(msg)) : (p['preview'] ?? 'Pinned message').toString();
    final segs = math.min(_pins.length, 4);
    return GestureDetector(
      onTap: () {
        _jumpToMessage(mid);
        if (_pins.length > 1) setState(() => _pinIndex = (idx + 1) % _pins.length);
      },
      child: Container(
        margin: const EdgeInsets.fromLTRB(10, 0, 10, 4),
        padding: const EdgeInsets.fromLTRB(12, 6, 4, 6),
        decoration: _headerDecoration(isDark, radius: 16),
        child: Row(
          children: [
            SizedBox(
              height: 32,
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: List.generate(segs, (i) {
                  final active = (idx % segs) == i;
                  return Container(
                    width: 3,
                    height: 28 / segs - 2,
                    margin: const EdgeInsets.symmetric(vertical: 1),
                    decoration: BoxDecoration(
                      color: active ? _kAccent : _kAccent.withOpacity(0.3),
                      borderRadius: BorderRadius.circular(2),
                    ),
                  );
                }),
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    _pins.length > 1 ? 'Pinned message #${idx + 1}' : 'Pinned message',
                    style: const TextStyle(color: _kAccent, fontSize: 12, fontWeight: FontWeight.w700),
                  ),
                  Text(preview, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 13)),
                ],
              ),
            ),
            IconButton(
              visualDensity: VisualDensity.compact,
              icon: const Icon(Icons.close, size: 18),
              onPressed: () => _unpin(mid ?? p['id'].toString()),
            ),
          ],
        ),
      ),
    );
  }

  // ─── Message list ───
  Widget _buildListArea(ThemeData theme, bool isDark) {
    final list = _visible;
    Widget body;
    if (_currentUserId == null) {
      body = const Center(child: Text('Please sign in again to use this chat'));
    } else if (_loadError != null && list.isEmpty) {
      body = Center(
        child: Container(
          margin: const EdgeInsets.all(24),
          padding: const EdgeInsets.all(16),
          decoration: _headerDecoration(isDark, radius: 18),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.error_outline, color: Colors.orange, size: 36),
              const SizedBox(height: 8),
              Text(_loadError!, textAlign: TextAlign.center),
              const SizedBox(height: 8),
              TextButton(
                onPressed: () {
                  setState(() {
                    _loadError = null;
                    _messagesLoaded = false;
                    _listenersStarted = false;
                    _messageSub?.cancel();
                    _chatSub?.cancel();
                    _typingSub?.cancel();
                    _pinSub?.cancel();
                  });
                  _resolveChat();
                },
                child: const Text('Retry'),
              ),
            ],
          ),
        ),
      );
    } else if (!_messagesLoaded) {
      body = const Center(child: SizedBox(width: 28, height: 28, child: CircularProgressIndicator(strokeWidth: 2.5)));
    } else if (list.isEmpty) {
      body = Center(
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
          decoration: _headerDecoration(isDark, radius: 18),
          child: Text('No messages yet. Say hi to ${_otherName()} 👋'),
        ),
      );
    } else {
      body = ListView.builder(
        controller: _scrollController,
        reverse: true,
        cacheExtent: 1200,
        keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
        padding: const EdgeInsets.fromLTRB(8, 8, 8, 8),
        itemCount: list.length + 1,
        itemBuilder: (context, i) {
          if (i == list.length) {
            return _loadingOlder
                ? const Padding(
                    padding: EdgeInsets.all(12),
                    child: Center(child: SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2))),
                  )
                : const SizedBox(height: 4);
          }
          return _buildItem(i, list, theme, isDark);
        },
      );
    }

    return Stack(
      children: [
        Positioned.fill(child: body),
        if (_unreadCount > 0 && !_atBottom)
          Positioned(
            top: 8,
            left: 0,
            right: 0,
            child: Center(
              child: Material(
                color: _kAccent,
                shape: const StadiumBorder(),
                elevation: 3,
                child: InkWell(
                  customBorder: const StadiumBorder(),
                  onTap: () => _firstUnreadId != null ? _jumpToMessage(_firstUnreadId) : _scrollToBottom(),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                    child: Text(
                      '$_unreadCount new message${_unreadCount == 1 ? '' : 's'}',
                      style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w600, fontSize: 13),
                    ),
                  ),
                ),
              ),
            ),
          ),
        if (_showFab)
          Positioned(
            right: 12,
            bottom: 12,
            child: GestureDetector(
              onTap: _scrollToBottom,
              child: Stack(
                clipBehavior: Clip.none,
                children: [
                  Container(
                    width: 44,
                    height: 44,
                    decoration: BoxDecoration(
                      color: isDark ? const Color(0xFF1F2C34) : Colors.white,
                      shape: BoxShape.circle,
                      boxShadow: [BoxShadow(color: Colors.black.withOpacity(0.2), blurRadius: 6, offset: const Offset(0, 2))],
                    ),
                    child: Icon(Icons.keyboard_arrow_down, color: theme.colorScheme.onSurface, size: 28),
                  ),
                  if (_unreadCount > 0)
                    Positioned(
                      top: -6,
                      right: -4,
                      child: Container(
                        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                        decoration: BoxDecoration(color: _kAccent, borderRadius: BorderRadius.circular(10)),
                        child: Text(
                          _unreadCount > 99 ? '99+' : '$_unreadCount',
                          style: const TextStyle(color: Colors.white, fontSize: 11, fontWeight: FontWeight.bold),
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ),
      ],
    );
  }

  Widget _buildItem(int i, List<Map<String, dynamic>> list, ThemeData theme, bool isDark) {
    final m = list[i];
    final id = m['id'].toString();
    final older = i + 1 < list.length ? list[i + 1] : null;
    final newer = i > 0 ? list[i - 1] : null;
    final t = _msgTime(m);
    final showDate = older == null || !_sameDay(t, _msgTime(older));
    final showDivider = id == _dividerAnchorId;
    return KeyedSubtree(
      key: _keyFor(id),
      child: Column(
        children: [
          if (showDate) _dateChip(t, theme, isDark),
          if (showDivider) _unreadDivider(),
          _buildMessageRow(m, newer, theme, isDark),
        ],
      ),
    );
  }

  Widget _dateChip(DateTime t, ThemeData theme, bool isDark) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Center(
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
          decoration: BoxDecoration(
            color: isDark ? const Color(0xCC1F2C34) : Colors.white.withOpacity(0.85),
            borderRadius: BorderRadius.circular(14),
          ),
          child: Text(_dayLabel(t), style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: theme.colorScheme.onSurface.withOpacity(0.75))),
        ),
      ),
    );
  }

  Widget _unreadDivider() {
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.symmetric(vertical: 6),
      padding: const EdgeInsets.symmetric(vertical: 5),
      color: _kAccent.withOpacity(0.14),
      child: Center(
        child: Text(
          '$_dividerCount unread message${_dividerCount == 1 ? '' : 's'}',
          style: const TextStyle(color: _kAccent, fontSize: 12, fontWeight: FontWeight.w700),
        ),
      ),
    );
  }

  Widget _systemRow(Map<String, dynamic> m, ThemeData theme, bool isDark) {
    final text = (m['content'] ?? m['text'] ?? '').toString();
    final target = m['target_id']?.toString();
    final kind = m['system_kind']?.toString();
    return Center(
      child: GestureDetector(
        onTap: (kind == 'pin' && target != null) ? () => _jumpToMessage(target) : null,
        child: Container(
          margin: const EdgeInsets.symmetric(vertical: 5),
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 5),
          decoration: BoxDecoration(
            color: isDark ? const Color(0xCC1F2C34) : Colors.white.withOpacity(0.85),
            borderRadius: BorderRadius.circular(14),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (kind == 'pin') const Padding(padding: EdgeInsets.only(right: 6), child: Icon(Icons.push_pin, size: 13, color: _kAccent)),
              if (kind == 'auto_delete') const Padding(padding: EdgeInsets.only(right: 6), child: Icon(Icons.timer_outlined, size: 13, color: _kAccent)),
              Flexible(
                child: Text(
                  text,
                  textAlign: TextAlign.center,
                  style: TextStyle(fontSize: 12, color: theme.colorScheme.onSurface.withOpacity(0.75)),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _tickIcon(Map<String, dynamic> m, Color base) {
    final me = _currentUserId;
    if (m['_pending'] == true) return Icon(Icons.access_time, size: 13, color: base);
    final rb = m['read_by'];
    final dt = m['delivered_to'];
    final readByOther = (rb is List && rb.any((e) => e != me)) || m['is_read'] == true;
    if (readByOther) return const Icon(Icons.done_all, size: 15, color: Color(0xFF4FC3F7));
    final deliveredToOther = dt is List && dt.any((e) => e != me);
    if (deliveredToOther) return Icon(Icons.done_all, size: 15, color: base);
    return Icon(Icons.done, size: 15, color: base);
  }

  Widget _buildMessageRow(Map<String, dynamic> m, Map<String, dynamic>? newer, ThemeData theme, bool isDark) {
    if (m['type'] == 'system') return _systemRow(m, theme, isDark);

    final id = m['id'].toString();
    final senderId = m['sender_id']?.toString();
    final isMe = senderId == _currentUserId;
    final newerSame = newer != null &&
        newer['type'] != 'system' &&
        newer['sender_id'] == m['sender_id'] &&
        _sameDay(_msgTime(m), _msgTime(newer)) &&
        newer['id'] != _dividerAnchorId;
    final lastInGroup = !newerSame;
    final selected = _selectedIds.contains(id);

    final baseColor = isMe
        ? (isDark ? const Color(0xFF005C4B) : const Color(0xFFEFFDDE))
        : (isDark ? const Color(0xFF1F2C34) : Colors.white);
    var bubbleColor = baseColor;
    if (selected) bubbleColor = Color.alphaBlend(_kAccent.withOpacity(0.3), baseColor);
    if (_highlightId == id) bubbleColor = Color.alphaBlend(_kAccent.withOpacity(0.35), baseColor);

    final maxW = MediaQuery.of(context).size.width * 0.78;
    final metaColor = theme.colorScheme.onSurface.withOpacity(0.5);
    final reactions = m['reactions'];
    final hasReactions = reactions is Map && reactions.values.any((v) => v is List && v.isNotEmpty);

    final bubble = AnimatedContainer(
      duration: const Duration(milliseconds: 250),
      constraints: BoxConstraints(maxWidth: maxW),
      padding: const EdgeInsets.fromLTRB(10, 7, 10, 6),
      decoration: BoxDecoration(
        color: bubbleColor,
        borderRadius: BorderRadius.only(
          topLeft: const Radius.circular(16),
          topRight: const Radius.circular(16),
          bottomLeft: Radius.circular((!isMe && lastInGroup) ? 4 : 16),
          bottomRight: Radius.circular((isMe && lastInGroup) ? 4 : 16),
        ),
        boxShadow: [BoxShadow(color: Colors.black.withOpacity(0.06), blurRadius: 2, offset: const Offset(0, 1))],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          if (m['forwarded_from'] != null)
            Padding(
              padding: const EdgeInsets.only(bottom: 4),
              child: Text(
                'Forwarded from ${m['forwarded_from']}',
                style: const TextStyle(fontSize: 12, fontStyle: FontStyle.italic, color: _kAccent, fontWeight: FontWeight.w600),
              ),
            ),
          if (m['reply_to'] != null) _quotedReply(m),
          ..._contentWidgets(m, isMe, theme, isDark),
          const SizedBox(height: 2),
          Align(
            alignment: Alignment.centerRight,
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (m['expires_at'] != null)
                  Padding(
                    padding: const EdgeInsets.only(right: 4),
                    child: Icon(Icons.timer_outlined, size: 11, color: metaColor),
                  ),
                if (m['edited'] == true)
                  Padding(
                    padding: const EdgeInsets.only(right: 4),
                    child: Text('edited', style: TextStyle(fontSize: 10, fontStyle: FontStyle.italic, color: metaColor)),
                  ),
                Text(DateFormat('HH:mm').format(_msgTime(m)), style: TextStyle(fontSize: 10, color: metaColor)),
                if (isMe) ...[const SizedBox(width: 3), _tickIcon(m, metaColor)],
              ],
            ),
          ),
          if (hasReactions) _reactionsRow(m),
        ],
      ),
    );

    final row = Row(
      mainAxisAlignment: isMe ? MainAxisAlignment.end : MainAxisAlignment.start,
      crossAxisAlignment: CrossAxisAlignment.end,
      children: [
        if (_multiSelectMode)
          Padding(
            padding: const EdgeInsets.only(right: 6, left: 2),
            child: Icon(selected ? Icons.check_circle : Icons.radio_button_unchecked,
                color: selected ? _kAccent : Colors.grey, size: 22),
          ),
        Flexible(
          child: GestureDetector(
            onTap: _multiSelectMode
                ? () => setState(() {
                      selected ? _selectedIds.remove(id) : _selectedIds.add(id);
                      if (_selectedIds.isEmpty) _multiSelectMode = false;
                    })
                : null,
            onDoubleTap: _multiSelectMode ? null : () => _toggleReaction(m, '❤️'),
            onLongPress: _multiSelectMode ? null : () => _showMessageMenu(m),
            child: bubble,
          ),
        ),
      ],
    );

    return Padding(
      padding: EdgeInsets.only(bottom: lastInGroup ? 6 : 2),
      child: _SwipeToReply(
        enabled: !_multiSelectMode && _hardBlockReason() == null,
        onReply: () => _startReply(m),
        child: row,
      ),
    );
  }

  Widget _quotedReply(Map<String, dynamic> m) {
    final rid = m['reply_to']?.toString();
    final orig = _findMessage(rid);
    final name = (m['reply_to_sender'] ?? (orig != null ? _nameOf(orig['sender_id']?.toString()) : 'Message')).toString();
    final preview = orig != null
        ? _stripFormatting(_previewOf(orig))
        : _stripFormatting((m['reply_to_content'] ?? 'Message').toString());
    final color = orig != null ? _colorForUid(orig['sender_id']?.toString()) : _kAccent;
    return GestureDetector(
      onTap: () => _jumpToMessage(rid),
      child: Container(
        margin: const EdgeInsets.only(bottom: 6),
        padding: const EdgeInsets.fromLTRB(8, 4, 8, 4),
        decoration: BoxDecoration(
          color: color.withOpacity(0.12),
          border: Border(left: BorderSide(color: color, width: 3)),
          borderRadius: BorderRadius.circular(6),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(name, maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(color: color, fontSize: 12, fontWeight: FontWeight.w700)),
            Text(preview, maxLines: 2, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 12.5)),
          ],
        ),
      ),
    );
  }

  Widget _reactionsRow(Map<String, dynamic> m) {
    final r = m['reactions'];
    if (r is! Map) return const SizedBox.shrink();
    final me = _currentUserId;
    final chips = <Widget>[];
    r.forEach((k, v) {
      if (v is List && v.isNotEmpty) {
        final mine = v.contains(me);
        chips.add(GestureDetector(
          onTap: () => _toggleReaction(m, k.toString()),
          onLongPress: () => _showWhoReacted(m),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
            decoration: BoxDecoration(
              color: mine ? _kAccent.withOpacity(0.25) : Colors.black.withOpacity(0.07),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: mine ? _kAccent : Colors.transparent),
            ),
            child: Text('$k ${v.length}', style: const TextStyle(fontSize: 13)),
          ),
        ));
      }
    });
    if (chips.isEmpty) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(top: 6),
      child: Wrap(spacing: 4, runSpacing: 4, children: chips),
    );
  }

  List<Widget> _contentWidgets(Map<String, dynamic> m, bool isMe, ThemeData theme, bool isDark) {
    final type = (m['type'] ?? m['media_type'] ?? 'text').toString();
    final url = m['media_url']?.toString();
    final out = <Widget>[];
    final textColor = isMe && isDark ? Colors.white : theme.colorScheme.onSurface;

    switch (type) {
      case 'image':
        if (url != null) out.add(_imageBubble(m, url));
        break;
      case 'video':
        if (url != null) out.add(_VideoBubble(key: ValueKey('vid_${m['id']}'), url: url));
        break;
      case 'audio':
        if (url != null) out.add(_buildAudioBubble(m, isMe, theme));
        break;
      case 'sticker':
      case 'gif':
        if (url != null) {
          out.add(ClipRRect(
            borderRadius: BorderRadius.circular(8),
            child: CachedNetworkImage(imageUrl: url, width: type == 'sticker' ? 150 : 220, fit: BoxFit.contain),
          ));
        }
        break;
      case 'file':
        if (url != null) out.add(_buildFileBubble(m, theme));
        break;
      case 'location':
      case 'live_location':
        if (m['latitude'] != null) out.add(_buildLocationBubble(m));
        break;
      case 'contact':
        out.add(_buildContactBubble(m, theme));
        break;
      default:
        break;
    }

    final hideText = type == 'location' || type == 'live_location' || type == 'contact';
    final text = (m['text'] ?? '').toString();
    if (!hideText && text.isNotEmpty) {
      out.add(Padding(
        padding: EdgeInsets.only(top: out.isEmpty ? 0 : 4),
        child: _RichMessageText(
          text: text,
          style: TextStyle(color: textColor, fontSize: 15.5, height: 1.25),
          mentionNames: const [],
          mentionColor: _kAccent,
          linkColor: _kAccent,
        ),
      ));
      final link = type == 'text' ? _firstUrl(text) : null;
      if (link != null) {
        out.add(Padding(padding: const EdgeInsets.only(top: 6), child: _LinkPreviewCard(url: link)));
      }
    }
    return out;
  }

  Widget _imageBubble(Map<String, dynamic> m, String url) {
    return GestureDetector(
      onTap: () => _openMedia(m),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(10),
        child: Stack(
          alignment: Alignment.topRight,
          children: [
            CachedNetworkImage(
              imageUrl: url,
              width: 230,
              fit: BoxFit.cover,
              placeholder: (_, __) => Container(
                width: 230,
                height: 160,
                color: Colors.black12,
                alignment: Alignment.center,
                child: const SizedBox(width: 24, height: 24, child: CircularProgressIndicator(strokeWidth: 2)),
              ),
              errorWidget: (_, __, ___) => Container(
                width: 230,
                height: 120,
                color: Colors.black12,
                alignment: Alignment.center,
                child: const Icon(Icons.broken_image, color: Colors.grey),
              ),
            ),
            Positioned(
              top: 6,
              right: 6,
              child: Container(
                padding: const EdgeInsets.all(4),
                decoration: const BoxDecoration(color: Colors.black54, shape: BoxShape.circle),
                child: const Icon(Icons.download, size: 16, color: Colors.white),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildFileBubble(Map<String, dynamic> m, ThemeData theme) {
    final name = (m['file_name'] ?? 'File').toString();
    final ext = name.contains('.') ? name.split('.').last.toLowerCase() : '';
    IconData icon = Icons.insert_drive_file;
    if (ext == 'pdf') icon = Icons.picture_as_pdf;
    if (['doc', 'docx', 'txt', 'rtf'].contains(ext)) icon = Icons.description;
    if (['xls', 'xlsx', 'csv'].contains(ext)) icon = Icons.table_chart;
    if (['zip', 'rar', '7z'].contains(ext)) icon = Icons.folder_zip;
    return GestureDetector(
      onTap: () => _openMedia(m),
      child: SizedBox(
        width: 230,
        child: Row(
          children: [
            CircleAvatar(radius: 22, backgroundColor: _kAccent, child: Icon(icon, color: Colors.white)),
            const SizedBox(width: 10),
            Expanded(child: Text(name, maxLines: 2, overflow: TextOverflow.ellipsis, style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 14))),
            const SizedBox(width: 6),
            Icon(Icons.download_rounded, size: 20, color: theme.colorScheme.onSurface.withOpacity(0.5)),
          ],
        ),
      ),
    );
  }

  Widget _buildAudioBubble(Map<String, dynamic> m, bool isMe, ThemeData theme) {
    final id = m['id'].toString();
    final isVoice = m['file_name'] == null;
    final wf = (m['waveform'] is List)
        ? (m['waveform'] as List).map((e) => (e is num ? e.toDouble() : 0.0) / 31.0).toList()
        : null;
    final total = Duration(seconds: (m['duration'] as num?)?.toInt() ?? 0);
    final loaded = _loadedAudioId == id;
    final inactive = theme.colorScheme.onSurface.withOpacity(0.25);

    Widget body(bool playing, Duration pos, Duration dur) {
      final d = dur > Duration.zero ? dur : total;
      final prog = d.inMilliseconds > 0 ? _c01(pos.inMilliseconds / d.inMilliseconds) : 0.0;
      return Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          GestureDetector(
            onTap: () => _togglePlay(m),
            child: Container(
              width: 42,
              height: 42,
              decoration: const BoxDecoration(color: _kAccent, shape: BoxShape.circle),
              child: Icon(playing ? Icons.pause : Icons.play_arrow, color: Colors.white),
            ),
          ),
          const SizedBox(width: 10),
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              if (!isVoice)
                SizedBox(
                  width: 150,
                  child: Text(m['file_name'].toString(), maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
                ),
              GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTapDown: (det) => _seekAudio(m, det.localPosition.dx / 150, d),
                child: SizedBox(
                  width: 150,
                  height: 26,
                  child: CustomPaint(painter: _WavePainter(bars: wf, progress: prog, active: _kAccent, inactive: inactive)),
                ),
              ),
              Text(
                loaded ? '${_fmtDur(pos.inSeconds)} / ${_fmtDur(d.inSeconds)}' : _fmtDur(total.inSeconds),
                style: TextStyle(fontSize: 11, color: theme.colorScheme.onSurface.withOpacity(0.55)),
              ),
            ],
          ),
        ],
      );
    }

    if (!loaded) return body(false, Duration.zero, Duration.zero);
    return StreamBuilder<PlayerState>(
      stream: _audioPlayer.playerStateStream,
      builder: (_, s) {
        final st = s.data;
        final playing = (st?.playing ?? false) && st?.processingState != ProcessingState.completed;
        return StreamBuilder<Duration>(
          stream: _audioPlayer.positionStream,
          builder: (_, p) => body(playing, p.data ?? Duration.zero, _audioPlayer.duration ?? Duration.zero),
        );
      },
    );
  }

  Widget _buildLocationBubble(Map<String, dynamic> msg) {
    final lat = (msg['latitude'] as num).toDouble();
    final lng = (msg['longitude'] as num).toDouble();
    final isLive = msg['type'] == 'live_location';
    final until = (msg['live_until'] as Timestamp?)?.toDate();
    final active = isLive && msg['live_active'] == true && until != null && until.isAfter(DateTime.now());
    final pos = LatLng(lat, lng);
    final mine = msg['sender_id'] == _currentUserId && msg['id'] == _liveMsgId;

    return GestureDetector(
      onTap: () => Navigator.push(
        context,
        MaterialPageRoute(builder: (_) => _LocationViewerScreen(chatId: _chatId ?? '', msgId: msg['id'], lat: lat, lng: lng, live: isLive)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          ClipRRect(
            borderRadius: BorderRadius.circular(8),
            child: SizedBox(
              width: 220,
              height: 140,
              child: AbsorbPointer(
                child: FlutterMap(
                  key: ValueKey('map_${msg['id']}_${lat}_$lng'),
                  options: MapOptions(initialCenter: pos, initialZoom: 15, interactionOptions: const InteractionOptions(flags: InteractiveFlag.none)),
                  children: [
                    TileLayer(urlTemplate: 'https://tile.openstreetmap.org/{z}/{x}/{y}.png', userAgentPackageName: 'com.lumachat.app'),
                    MarkerLayer(markers: [Marker(point: pos, width: 36, height: 36, child: const Icon(Icons.location_on, color: Colors.red, size: 36))]),
                  ],
                ),
              ),
            ),
          ),
          const SizedBox(height: 6),
          Row(mainAxisSize: MainAxisSize.min, children: [
            Icon(isLive ? Icons.location_searching : Icons.location_on, size: 16, color: active ? Colors.green : Colors.red),
            const SizedBox(width: 4),
            Text(
              isLive ? (active ? 'Live location · until ${DateFormat('HH:mm').format(until)}' : 'Live location ended') : 'Location',
              style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
            ),
          ]),
          if (active && mine)
            TextButton(
              style: TextButton.styleFrom(padding: EdgeInsets.zero, minimumSize: const Size(0, 30)),
              onPressed: () => _stopLiveLocation(),
              child: const Text('Stop sharing', style: TextStyle(color: Colors.red)),
            ),
        ],
      ),
    );
  }

  Widget _buildContactBubble(Map<String, dynamic> msg, ThemeData theme) {
    final lines = (msg['text'] ?? '').toString().split('\n');
    final name = (msg['contact_name'] ?? (lines.isNotEmpty ? lines.first : 'Contact')).toString();
    final phone = (msg['contact_phone'] ?? (lines.length > 1 ? lines[1] : '')).toString();
    final avatar = msg['contact_avatar']?.toString();
    return GestureDetector(
      onTap: () {
        Clipboard.setData(ClipboardData(text: phone));
        _showSnack('Number copied');
      },
      child: SizedBox(
        width: 220,
        child: Row(children: [
          CircleAvatar(
            radius: 22,
            backgroundColor: Colors.blue,
            backgroundImage: (avatar != null && avatar.isNotEmpty) ? CachedNetworkImageProvider(avatar) : null,
            child: (avatar == null || avatar.isEmpty)
                ? Text(name.isNotEmpty ? name[0].toUpperCase() : '?', style: const TextStyle(color: Colors.white))
                : null,
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(name, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 15)),
              Text(phone, maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 13, color: theme.colorScheme.onSurface.withOpacity(0.6))),
              const Text('Luma Chat', style: TextStyle(fontSize: 11, color: _kAccent)),
            ]),
          ),
        ]),
      ),
    );
  }

  // ═══════════════════════════════════════════════════════════════════════
  // CONTEXT MENU / REACTIONS
  // ═══════════════════════════════════════════════════════════════════════
  Widget _menuTile(IconData icon, String label, VoidCallback onTap, {Color? color}) {
    return ListTile(
      dense: true,
      leading: Icon(icon, color: color),
      title: Text(label, style: TextStyle(color: color)),
      onTap: onTap,
    );
  }

  void _showMessageMenu(Map<String, dynamic> m) {
    if (m['type'] == 'system') return;
    HapticFeedback.selectionClick();
    final me = _currentUserId;
    final id = m['id'].toString();
    final isMine = m['sender_id'] == me;
    final type = (m['type'] ?? 'text').toString();
    final text = (m['text'] ?? '').toString();
    final isTextual = type == 'text' && text.isNotEmpty;
    final hasDownload = m['media_url'] != null && (type == 'image' || type == 'video' || type == 'file' || type == 'audio');
    final pinned = _pins.any((p) => p['message_id'] == id);
    final canEdit = isMine && type == 'text';
    final canReply = _hardBlockReason() == null;

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (sheetCtx) {
        final isDark = Theme.of(sheetCtx).brightness == Brightness.dark;
        void close() => Navigator.pop(sheetCtx);
        return SafeArea(
          child: Container(
            margin: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              color: isDark ? const Color(0xFF17212B) : Colors.white,
              borderRadius: BorderRadius.circular(20),
            ),
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Padding(
                    padding: const EdgeInsets.fromLTRB(12, 12, 12, 4),
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        for (final e in _kQuickReactions)
                          GestureDetector(
                            onTap: () {
                              close();
                              _toggleReaction(m, e);
                            },
                            child: Padding(padding: const EdgeInsets.all(6), child: Text(e, style: const TextStyle(fontSize: 26))),
                          ),
                        GestureDetector(
                          onTap: () {
                            close();
                            _showReactionPicker(m);
                          },
                          child: Container(
                            width: 34,
                            height: 34,
                            decoration: BoxDecoration(color: Colors.grey.withOpacity(0.2), shape: BoxShape.circle),
                            child: const Icon(Icons.add, size: 20),
                          ),
                        ),
                      ],
                    ),
                  ),
                  const Divider(height: 8),
                  if (canReply)
                    _menuTile(Icons.reply, 'Reply', () {
                      close();
                      _startReply(m);
                    }),
                  if (isTextual)
                    _menuTile(Icons.copy, 'Copy', () {
                      close();
                      Clipboard.setData(ClipboardData(text: text));
                      _showSnack('Copied');
                    }),
                  _menuTile(Icons.forward, 'Forward', () {
                    close();
                    _forwardMessages([m]);
                  }),
                  _menuTile(pinned ? Icons.push_pin_outlined : Icons.push_pin, pinned ? 'Unpin' : 'Pin', () {
                    close();
                    pinned ? _unpin(id) : _pinMessage(m);
                  }),
                  if (canEdit)
                    _menuTile(Icons.edit, 'Edit', () {
                      close();
                      _startEdit(m);
                    }),
                  if (hasDownload)
                    _menuTile(Icons.download, 'Download', () {
                      close();
                      _openMedia(m);
                    }),
                  if (_isMePremium && isTextual) ...[
                    _menuTile(Icons.summarize, 'Summarize (AI)', () {
                      close();
                      _processAiAction('summarize', text);
                    }),
                    _menuTile(Icons.translate, 'Translate (AI)', () {
                      close();
                      _processAiAction('translate', text);
                    }),
                  ],
                  if (m['reactions'] is Map && (m['reactions'] as Map).values.any((v) => v is List && v.isNotEmpty))
                    _menuTile(Icons.emoji_emotions_outlined, 'Who reacted', () {
                      close();
                      _showWhoReacted(m);
                    }),
                  _menuTile(Icons.check_circle_outline, 'Select', () {
                    close();
                    setState(() {
                      _multiSelectMode = true;
                      _selectedIds.add(id);
                    });
                  }),
                  _menuTile(Icons.visibility_off_outlined, 'Delete for me', () {
                    close();
                    _deleteForMe(id);
                  }, color: Colors.red),
                  if (isMine)
                    _menuTile(Icons.delete, 'Delete for everyone', () async {
                      close();
                      if (await _confirm('Delete message?', 'This removes it for both of you.')) {
                        _deleteForEveryone(id);
                      }
                    }, color: Colors.red),
                  const SizedBox(height: 6),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  void _showReactionPicker(Map<String, dynamic> m) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final bg = isDark ? const Color(0xFF17212B) : Colors.white;
    showModalBottomSheet(
      context: context,
      backgroundColor: bg,
      builder: (ctx) => SafeArea(
        child: SizedBox(
          height: 320,
          child: EmojiPicker(
            onEmojiSelected: (cat, emoji) {
              Navigator.pop(ctx);
              _toggleReaction(m, emoji.emoji);
            },
            config: Config(
              height: 320,
              emojiViewConfig: EmojiViewConfig(backgroundColor: bg, columns: 8, emojiSizeMax: 28),
              categoryViewConfig: CategoryViewConfig(
                backgroundColor: bg,
                indicatorColor: _kAccent,
                iconColorSelected: _kAccent,
              ),
              bottomActionBarConfig: BottomActionBarConfig(
                backgroundColor: bg,
                buttonColor: Colors.transparent,
              ),
              searchViewConfig: SearchViewConfig(backgroundColor: bg),
            ),
          ),
        ),
      ),
    );
  }

  void _showWhoReacted(Map<String, dynamic> m) {
    final r = m['reactions'];
    if (r is! Map) return;
    final entries = <MapEntry<String, List<String>>>[];
    r.forEach((k, v) {
      if (v is List && v.isNotEmpty) entries.add(MapEntry(k.toString(), v.map((e) => e.toString()).toList()));
    });
    if (entries.isEmpty) return;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (ctx) => SafeArea(
        child: Container(
          margin: const EdgeInsets.all(10),
          constraints: BoxConstraints(maxHeight: MediaQuery.of(ctx).size.height * 0.6),
          decoration: BoxDecoration(color: isDark ? const Color(0xFF17212B) : Colors.white, borderRadius: BorderRadius.circular(20)),
          child: ListView(
            shrinkWrap: true,
            padding: const EdgeInsets.symmetric(vertical: 10),
            children: [
              const Padding(
                padding: EdgeInsets.fromLTRB(16, 4, 16, 8),
                child: Text('Reactions', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
              ),
              for (final e in entries) ...[
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 8, 16, 2),
                  child: Text('${e.key}  ${e.value.length}', style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600)),
                ),
                for (final uid in e.value)
                  ListTile(
                    dense: true,
                    leading: CircleAvatar(
                      radius: 16,
                      backgroundImage: (uid != _currentUserId && _otherAvatar() != null) ? CachedNetworkImageProvider(_otherAvatar()!) : null,
                      child: (uid == _currentUserId || _otherAvatar() == null) ? const Icon(Icons.person, size: 16) : null,
                    ),
                    title: Text(uid == _currentUserId ? 'You' : _otherName()),
                  ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  // ═══════════════════════════════════════════════════════════════════════
  // PROFILE SHEET / MORE MENU / SEARCH / WALLPAPER / AUTO-DELETE / BLOCK
  // ═══════════════════════════════════════════════════════════════════════
  void _showUserSheet() {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final avatar = _otherAvatar();
    final name = _otherName();
    final status = _statusText();
    final bio = (_otherData?['bio'] ?? _otherData?['about'] ?? '').toString();
    final username = (_otherData?['username'] ?? '').toString();
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (ctx) {
        void close() => Navigator.pop(ctx);
        return SafeArea(
          child: Container(
            margin: const EdgeInsets.all(10),
            padding: const EdgeInsets.fromLTRB(16, 20, 16, 8),
            decoration: BoxDecoration(color: isDark ? const Color(0xFF17212B) : Colors.white, borderRadius: BorderRadius.circular(24)),
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  CircleAvatar(
                    radius: 46,
                    backgroundColor: _kAccent.withOpacity(0.15),
                    backgroundImage: avatar != null ? CachedNetworkImageProvider(avatar) : null,
                    child: avatar == null
                        ? Text(name.isNotEmpty ? name[0].toUpperCase() : '?', style: const TextStyle(color: _kAccent, fontSize: 32, fontWeight: FontWeight.bold))
                        : null,
                  ),
                  const SizedBox(height: 12),
                  Text(name, style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w700)),
                  if (status.isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.only(top: 2),
                      child: Text(status, style: TextStyle(color: status == 'online' ? _kAccent : Colors.grey, fontSize: 13)),
                    ),
                  if (username.isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.only(top: 6),
                      child: Text('@$username', style: const TextStyle(color: _kAccent, fontSize: 14)),
                    ),
                  if (bio.isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.only(top: 10),
                      child: Text(bio, textAlign: TextAlign.center, style: const TextStyle(fontSize: 14)),
                    ),
                  const SizedBox(height: 10),
                  const Divider(height: 1),
                  _menuTile(Icons.search, 'Search in chat', () {
                    close();
                    _openSearch();
                  }),
                  _menuTile(Icons.photo_library_outlined, 'Media, links and files', () {
                    close();
                    _openSearch(tab: 1);
                  }),
                  _menuTile(_iBlockedOther ? Icons.lock_open : Icons.block, _iBlockedOther ? 'Unblock' : 'Block', () {
                    close();
                    _toggleBlock();
                  }, color: Colors.red),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  void _showMoreMenu() {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (sheetCtx) {
        void close() => Navigator.pop(sheetCtx);
        return SafeArea(
          child: Container(
            margin: const EdgeInsets.all(10),
            decoration: BoxDecoration(color: isDark ? const Color(0xFF17212B) : Colors.white, borderRadius: BorderRadius.circular(20)),
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const SizedBox(height: 6),
                  _menuTile(Icons.person_outline, 'View profile', () {
                    close();
                    _showUserSheet();
                  }),
                  _menuTile(Icons.search, 'Search', () {
                    close();
                    _openSearch();
                  }),
                  _menuTile(Icons.photo_library_outlined, 'Media, links and files', () {
                    close();
                    _openSearch(tab: 1);
                  }),
                  if (_pins.isNotEmpty)
                    _menuTile(Icons.push_pin_outlined, 'Pinned messages (${_pins.length})', () {
                      close();
                      _showPinnedList();
                    }),
                  _menuTile(Icons.wallpaper, 'Change wallpaper', () {
                    close();
                    _showWallpaperSheet();
                  }),
                  _menuTile(Icons.timer_outlined, _autoDeleteSeconds > 0 ? 'Auto-delete: ${_durLabel(_autoDeleteSeconds)}' : 'Auto-delete messages', () {
                    close();
                    _showAutoDeleteDialog();
                  }),
                  _menuTile(Icons.check_circle_outline, 'Select messages', () {
                    close();
                    setState(() => _multiSelectMode = true);
                  }),
                  _menuTile(Icons.cleaning_services_outlined, 'Clear history', () {
                    close();
                    _clearHistory();
                  }, color: Colors.red),
                  _menuTile(_iBlockedOther ? Icons.lock_open : Icons.block, _iBlockedOther ? 'Unblock' : 'Block', () {
                    close();
                    _toggleBlock();
                  }, color: Colors.red),
                  const SizedBox(height: 6),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  Future<void> _toggleBlock() async {
    final me = _currentUserId;
    final other = _otherId;
    if (me == null || other == null) return;
    final blocked = _iBlockedOther;
    if (!blocked) {
      final ok = await _confirm('Block ${_otherName()}?', 'They will no longer be able to message you.', action: 'Block');
      if (!ok) return;
    }
    try {
      await FirebaseFirestore.instance.collection('users').doc(me).update({
        'blocked_users': blocked ? FieldValue.arrayRemove([other]) : FieldValue.arrayUnion([other]),
      });
    } catch (e) {
      _showSnack('Could not update block: $e');
    }
  }

  Future<void> _clearHistory() async {
    final me = _currentUserId;
    if (me == null || !_chatExists) {
      _showSnack('Nothing to clear yet');
      return;
    }
    final ok = await _confirm('Clear history?', 'All messages are removed from this chat for you only.', action: 'Clear');
    if (!ok) return;
    try {
      await _chatRef.update(<Object, Object?>{
        FieldPath(['participants_data', me, 'cleared_at']): FieldValue.serverTimestamp(),
      });
    } catch (e) {
      _showSnack('Could not clear: $e');
    }
  }

  Future<void> _setAutoDelete(int seconds) async {
    if (!await _ensureChatDoc()) return;
    try {
      await _chatRef.update({'auto_delete_seconds': seconds});
      await _postMessage({
        'type': 'system',
        'media_type': 'system',
        'content': seconds == 0
            ? '${_myName()} turned off auto-delete'
            : '${_myName()} set messages to auto-delete after ${_durLabel(seconds)}',
        'system_kind': 'auto_delete',
      }, system: true);
    } catch (e) {
      _showSnack('Could not change auto-delete: $e');
    }
  }

  void _showAutoDeleteDialog() {
    const options = <MapEntry<String, int>>[
      MapEntry('Off', 0),
      MapEntry('1 day', 86400),
      MapEntry('1 week', 604800),
      MapEntry('1 month', 2592000),
    ];
    showDialog(
      context: context,
      builder: (ctx) => SimpleDialog(
        title: const Text('Auto-delete messages'),
        children: [
          for (final o in options)
            ListTile(
              dense: true,
              title: Text(o.key),
              trailing: _autoDeleteSeconds == o.value ? const Icon(Icons.check, color: _kAccent) : null,
              onTap: () {
                Navigator.pop(ctx);
                _setAutoDelete(o.value);
              },
            ),
          const Padding(
            padding: EdgeInsets.fromLTRB(24, 4, 24, 8),
            child: Text('Applies to new messages. Both of you will see them disappear.', style: TextStyle(fontSize: 12, color: Colors.grey)),
          ),
        ],
      ),
    );
  }

  Future<void> _openSearch({int tab = 0}) async {
    final result = await Navigator.push<String>(
      context,
      MaterialPageRoute(
        builder: (_) => _ChatSearchScreen(
          initialTab: tab,
          getMessages: () => _visible,
          loadOlder: _loadOlder,
          hasMore: () => !_noMoreOlder && _chatExists,
          nameOf: (uid) => _nameOf(uid),
          avatarOf: (uid) => uid == _currentUserId ? (_myData?[_kUserAvatarField] as String?) : _otherAvatar(),
        ),
      ),
    );
    if (!mounted || result == null) return;
    _jumpToMessage(result);
  }

  void _showPinnedList() {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (ctx) => SafeArea(
        child: Container(
          margin: const EdgeInsets.all(10),
          constraints: BoxConstraints(maxHeight: MediaQuery.of(ctx).size.height * 0.6),
          decoration: BoxDecoration(color: isDark ? const Color(0xFF17212B) : Colors.white, borderRadius: BorderRadius.circular(20)),
          child: ListView(
            shrinkWrap: true,
            padding: const EdgeInsets.symmetric(vertical: 10),
            children: [
              const Padding(
                padding: EdgeInsets.fromLTRB(16, 4, 16, 8),
                child: Text('Pinned messages', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
              ),
              for (final p in _pins)
                ListTile(
                  leading: const Icon(Icons.push_pin, color: _kAccent, size: 20),
                  title: Text(
                    () {
                      final msg = _findMessage(p['message_id']?.toString());
                      return msg != null ? _stripFormatting(_previewOf(msg)) : (p['preview'] ?? 'Pinned message').toString();
                    }(),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                  trailing: IconButton(
                    icon: const Icon(Icons.close, size: 18),
                    onPressed: () {
                      Navigator.pop(ctx);
                      _unpin(p['message_id']?.toString() ?? p['id'].toString());
                    },
                  ),
                  onTap: () {
                    Navigator.pop(ctx);
                    _jumpToMessage(p['message_id']?.toString());
                  },
                ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _setWallpaper(String? value) async {
    final me = _currentUserId;
    final cid = _chatId;
    if (me == null || cid == null) return;
    setState(() => _wallpaper = value);
    try {
      await FirebaseFirestore.instance.collection('user_settings').doc(me).set({
        'chat_wallpapers': {cid: value ?? FieldValue.delete()},
      }, SetOptions(merge: true));
    } catch (e) {
      _showSnack('Could not save wallpaper: $e');
    }
  }

  Future<void> _pickWallpaperFromGallery() async {
    final x = await _picker.pickImage(source: ImageSource.gallery, imageQuality: 85);
    if (x == null) return;
    _showSnack('Uploading wallpaper...');
    final url = await CloudinaryService.uploadImage(File(x.path), 'luma/wallpapers');
    if (url == null) {
      _showSnack('Upload failed');
      return;
    }
    if (mounted) ScaffoldMessenger.of(context).hideCurrentSnackBar();
    await _setWallpaper(url);
  }

  Widget _wallpaperSwatch(String value) {
    BoxDecoration deco;
    try {
      if (value.startsWith('color:')) {
        deco = BoxDecoration(color: Color(int.parse(value.substring(6), radix: 16)), borderRadius: BorderRadius.circular(12));
      } else {
        final cols = value.substring(5).split(',').map((h) => Color(int.parse(h, radix: 16))).toList();
        deco = BoxDecoration(
          gradient: LinearGradient(begin: Alignment.topLeft, end: Alignment.bottomRight, colors: cols),
          borderRadius: BorderRadius.circular(12),
        );
      }
    } catch (_) {
      deco = BoxDecoration(color: Colors.grey, borderRadius: BorderRadius.circular(12));
    }
    final selected = _wallpaper == value;
    return GestureDetector(
      onTap: () {
        Navigator.pop(context);
        _setWallpaper(value);
      },
      child: Container(
        decoration: deco.copyWith(border: Border.all(color: selected ? _kAccent : Colors.black12, width: selected ? 3 : 1)),
        child: selected ? const Center(child: Icon(Icons.check, color: Colors.white)) : null,
      ),
    );
  }

  void _showWallpaperSheet() {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (ctx) => SafeArea(
        child: Container(
          margin: const EdgeInsets.all(10),
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(color: isDark ? const Color(0xFF17212B) : Colors.white, borderRadius: BorderRadius.circular(20)),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text('Chat wallpaper', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
              const SizedBox(height: 12),
              SizedBox(
                height: 150,
                child: GridView.count(
                  crossAxisCount: 6,
                  mainAxisSpacing: 8,
                  crossAxisSpacing: 8,
                  physics: const NeverScrollableScrollPhysics(),
                  children: _kWallpaperPresets.map(_wallpaperSwatch).toList(),
                ),
              ),
              const SizedBox(height: 8),
              ListTile(
                dense: true,
                leading: const Icon(Icons.photo_library_outlined),
                title: const Text('Choose from gallery'),
                onTap: () {
                  Navigator.pop(ctx);
                  _pickWallpaperFromGallery();
                },
              ),
              if (_wallpaper != null)
                ListTile(
                  dense: true,
                  leading: const Icon(Icons.hide_image_outlined, color: Colors.red),
                  title: const Text('Remove wallpaper', style: TextStyle(color: Colors.red)),
                  onTap: () {
                    Navigator.pop(ctx);
                    _setWallpaper(null);
                  },
                ),
            ],
          ),
        ),
      ),
    );
  }

  // ═══════════════════════════════════════════════════════════════════════
  // BOTTOM AREA (reply/edit bars, format bar, composer, panel)
  // ═══════════════════════════════════════════════════════════════════════
  Widget _buildBottomArea(ThemeData theme, bool isDark) {
    final hardBlock = _hardBlockReason();
    Widget main;
    if (_multiSelectMode) {
      main = _buildMultiSelectBar(theme, isDark);
    } else if (hardBlock != null) {
      main = _buildBlockedBar(hardBlock, isDark);
    } else {
      main = _buildComposer(theme, isDark);
    }
    final showBars = !_multiSelectMode && hardBlock == null;

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (showBars && _replyingTo != null) _buildReplyBar(theme, isDark),
        if (showBars && _editingId != null) _buildEditBar(theme, isDark),
        if (showBars && _hasSelection) _buildFormatBar(theme, isDark),
        if (showBars && _autoDeleteSeconds > 0) _buildAutoDeleteBanner(),
        if (_liveUntil != null) _buildLiveBar(theme),
        SafeArea(
          top: false,
          bottom: _activePanel == null,
          child: Padding(padding: const EdgeInsets.fromLTRB(8, 4, 8, 8), child: main),
        ),
        if (_activePanel != null) _buildPanel(theme, isDark),
      ],
    );
  }

  Widget _barShell(bool isDark, Widget child) {
    return Container(
      margin: const EdgeInsets.fromLTRB(8, 0, 8, 4),
      padding: const EdgeInsets.fromLTRB(12, 6, 4, 6),
      decoration: _headerDecoration(isDark, radius: 16),
      child: child,
    );
  }

  Widget _buildReplyBar(ThemeData theme, bool isDark) {
    final msg = _findMessage(_replyingTo);
    final name = msg != null ? _nameOf(msg['sender_id']?.toString()) : 'Message';
    return _barShell(
      isDark,
      Row(children: [
        const Icon(Icons.reply, size: 20, color: _kAccent),
        const SizedBox(width: 10),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text('Reply to $name', style: const TextStyle(color: _kAccent, fontSize: 12, fontWeight: FontWeight.w700)),
            Text(msg != null ? _stripFormatting(_previewOf(msg)) : 'Message', maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 13)),
          ]),
        ),
        IconButton(icon: const Icon(Icons.close, size: 18), onPressed: () => setState(() => _replyingTo = null)),
      ]),
    );
  }

  Widget _buildEditBar(ThemeData theme, bool isDark) {
    final msg = _findMessage(_editingId);
    return _barShell(
      isDark,
      Row(children: [
        const Icon(Icons.edit, size: 20, color: _kAccent),
        const SizedBox(width: 10),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            const Text('Edit message', style: TextStyle(color: _kAccent, fontSize: 12, fontWeight: FontWeight.w700)),
            Text(msg != null ? _stripFormatting((msg['text'] ?? '').toString()) : '', maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 13)),
          ]),
        ),
        IconButton(icon: const Icon(Icons.close, size: 18), onPressed: _cancelEdit),
      ]),
    );
  }

  Widget _buildFormatBar(ThemeData theme, bool isDark) {
    Widget btn(String label, VoidCallback onTap, {TextStyle? style}) {
      return Expanded(
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(10),
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 8),
            child: Center(child: Text(label, style: style ?? const TextStyle(fontSize: 15))),
          ),
        ),
      );
    }

    return Container(
      margin: const EdgeInsets.fromLTRB(8, 0, 8, 4),
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: _headerDecoration(isDark, radius: 16),
      child: Row(children: [
        btn('B', () => _wrapSelection('**'), style: const TextStyle(fontWeight: FontWeight.w900, fontSize: 16)),
        btn('I', () => _wrapSelection('__'), style: const TextStyle(fontStyle: FontStyle.italic, fontSize: 16)),
        btn('Mono', () => _wrapSelection('`'), style: const TextStyle(fontFamily: 'monospace', fontSize: 14)),
        btn('Spoiler', () => _wrapSelection('||'), style: const TextStyle(fontSize: 14)),
      ]),
    );
  }

  Widget _buildAutoDeleteBanner() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 4),
      child: Row(children: [
        const Icon(Icons.timer_outlined, size: 14, color: _kAccent),
        const SizedBox(width: 6),
        Text('Messages auto-delete after ${_durLabel(_autoDeleteSeconds)}',
            style: const TextStyle(fontSize: 12, color: _kAccent, fontWeight: FontWeight.w600)),
      ]),
    );
  }

  Widget _buildLiveBar(ThemeData theme) {
    return Container(
      margin: const EdgeInsets.fromLTRB(10, 0, 10, 4),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
      decoration: BoxDecoration(color: Colors.green.withOpacity(0.15), borderRadius: BorderRadius.circular(20)),
      child: Row(children: [
        const Icon(Icons.location_searching, size: 18, color: Colors.green),
        const SizedBox(width: 8),
        Expanded(child: Text('Sharing live location until ${DateFormat('HH:mm').format(_liveUntil!)}', style: const TextStyle(fontSize: 13))),
        TextButton(onPressed: () => _stopLiveLocation(), child: const Text('Stop', style: TextStyle(color: Colors.red))),
      ]),
    );
  }

  Widget _buildBlockedBar(String reason, bool isDark) {
    return Container(
      height: 48,
      padding: const EdgeInsets.symmetric(horizontal: 16),
      decoration: _headerDecoration(isDark, radius: 26),
      child: Row(mainAxisAlignment: MainAxisAlignment.center, children: [
        Icon(Icons.lock_outline, size: 18, color: Colors.grey[500]),
        const SizedBox(width: 8),
        Flexible(child: Text(reason, overflow: TextOverflow.ellipsis, style: TextStyle(color: Colors.grey[500], fontSize: 14))),
        if (_iBlockedOther)
          TextButton(onPressed: _toggleBlock, child: const Text('Unblock')),
      ]),
    );
  }

  Widget _buildMultiSelectBar(ThemeData theme, bool isDark) {
    final selected = _visible.where((m) => _selectedIds.contains(m['id'])).toList();
    final allMine = selected.isNotEmpty && selected.every((m) => m['sender_id'] == _currentUserId);
    return Container(
      height: 52,
      padding: const EdgeInsets.symmetric(horizontal: 8),
      decoration: _headerDecoration(isDark, radius: 26),
      child: Row(children: [
        IconButton(
          icon: const Icon(Icons.close),
          onPressed: () => setState(() {
            _multiSelectMode = false;
            _selectedIds.clear();
          }),
        ),
        Text('${_selectedIds.length} selected', style: const TextStyle(fontWeight: FontWeight.bold)),
        const Spacer(),
        IconButton(
          icon: const Icon(Icons.copy),
          onPressed: selected.isEmpty
              ? null
              : () {
                  final list = [...selected]..sort((a, b) => _msgTime(a).compareTo(_msgTime(b)));
                  final txt = list
                      .where((m) => (m['text'] ?? '').toString().isNotEmpty && m['type'] == 'text')
                      .map((m) => '${_nameOf(m['sender_id']?.toString())}: ${m['text']}')
                      .join('\n');
                  if (txt.isEmpty) {
                    _showSnack('Nothing to copy');
                    return;
                  }
                  Clipboard.setData(ClipboardData(text: txt));
                  _showSnack('Copied');
                },
        ),
        IconButton(
          icon: const Icon(Icons.forward),
          onPressed: selected.isEmpty ? null : () => _forwardMessages(selected),
        ),
        IconButton(
          icon: const Icon(Icons.delete, color: Colors.red),
          onPressed: selected.isEmpty
              ? null
              : () async {
                  final ok = await _confirm(
                    'Delete ${selected.length} message${selected.length == 1 ? '' : 's'}?',
                    allMine ? 'They will be removed for both of you.' : 'Messages from ${_otherName()} are removed only for you.',
                  );
                  if (!ok) return;
                  for (final m in selected) {
                    final id = m['id'].toString();
                    if (m['sender_id'] == _currentUserId) {
                      await _deleteForEveryone(id);
                    } else {
                      await _deleteForMe(id);
                    }
                  }
                  if (mounted) {
                    setState(() {
                      _multiSelectMode = false;
                      _selectedIds.clear();
                    });
                  }
                },
        ),
      ]),
    );
  }

  // ─── Composer ───
  Widget _buildComposer(ThemeData theme, bool isDark) {
    final iconColor = theme.colorScheme.onSurface.withOpacity(0.55);
    final surface = isDark ? const Color(0xFF1F2C34) : Colors.white;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.end,
      children: [
        Expanded(
          child: Container(
            constraints: const BoxConstraints(minHeight: 48),
            decoration: BoxDecoration(
              color: surface,
              borderRadius: BorderRadius.circular(26),
              boxShadow: [BoxShadow(color: Colors.black.withOpacity(0.10), blurRadius: 6, offset: const Offset(0, 2))],
            ),
            child: _isRecording
                ? _buildRecordingInner(theme)
                : Row(
                    crossAxisAlignment: CrossAxisAlignment.end,
                    children: [
                      SizedBox(
                        width: 46,
                        height: 48,
                        child: IconButton(
                          padding: EdgeInsets.zero,
                          icon: Icon(_activePanel != null ? Icons.keyboard : Icons.emoji_emotions_outlined, color: iconColor),
                          onPressed: () {
                            if (_activePanel != null) {
                              setState(() => _activePanel = null);
                              _messageFocus.requestFocus();
                              SystemChannels.textInput.invokeMethod('TextInput.show');
                            } else {
                              FocusScope.of(context).unfocus();
                              setState(() => _activePanel = 'emoji');
                            }
                          },
                        ),
                      ),
                      Expanded(
                        child: TextField(
                          controller: _messageController,
                          focusNode: _messageFocus,
                          minLines: 1,
                          maxLines: 5,
                          textCapitalization: TextCapitalization.sentences,
                          onChanged: _onTyping,
                          onTap: () {
                            if (_activePanel != null) setState(() => _activePanel = null);
                          },
                          decoration: InputDecoration(
                            hintText: 'Message',
                            hintStyle: TextStyle(color: Colors.grey[500], fontSize: 16),
                            border: InputBorder.none,
                            enabledBorder: InputBorder.none,
                            focusedBorder: InputBorder.none,
                            isDense: true,
                            filled: false,
                            contentPadding: const EdgeInsets.symmetric(horizontal: 2, vertical: 14),
                          ),
                        ),
                      ),
                      SizedBox(
                        width: 44,
                        height: 48,
                        child: IconButton(
                          padding: EdgeInsets.zero,
                          icon: Icon(Icons.attach_file, color: iconColor),
                          onPressed: _showAttachmentSheet,
                        ),
                      ),
                      if (!_hasText && _editingId == null)
                        SizedBox(
                          width: 44,
                          height: 48,
                          child: IconButton(
                            padding: EdgeInsets.zero,
                            icon: Icon(Icons.camera_alt_outlined, color: iconColor),
                            onPressed: _pickFromCamera,
                          ),
                        ),
                    ],
                  ),
          ),
        ),
        const SizedBox(width: 8),
        _buildSendButton(theme),
      ],
    );
  }

  Widget _buildSendButton(ThemeData theme) {
    final showSend = _hasText || _editingId != null;
    Widget icon;
    if (_editingId != null) {
      icon = const Icon(Icons.check, color: Colors.white, size: 24);
    } else if (_hasText) {
      icon = const Icon(Icons.send, color: Colors.white, size: 22);
    } else {
      icon = const Icon(Icons.mic, color: Colors.white, size: 24);
    }
    final size = _isRecording ? 60.0 : 48.0;
    final circle = AnimatedContainer(
      duration: const Duration(milliseconds: 150),
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: _recCancel ? Colors.red : _kAccent,
        shape: BoxShape.circle,
        boxShadow: [BoxShadow(color: Colors.black.withOpacity(0.15), blurRadius: 6, offset: const Offset(0, 2))],
      ),
      child: Center(child: icon),
    );
    if (showSend) {
      return GestureDetector(onTap: _sendText, child: circle);
    }
    return GestureDetector(
      onTap: () => _showSnack('Hold to record, release to send'),
      onLongPressStart: (_) => _startRecording(),
      onLongPressMoveUpdate: (d) {
        final cancel = d.offsetFromOrigin.dx < -90;
        if (cancel != _recCancel) setState(() => _recCancel = cancel);
      },
      onLongPressEnd: (_) => _finishRecording(cancel: _recCancel),
      child: circle,
    );
  }

  Widget _buildRecordingInner(ThemeData theme) {
    final bars = _ampSamples.length > 40 ? _ampSamples.sublist(_ampSamples.length - 40) : _ampSamples;
    return SizedBox(
      height: 48,
      child: Row(
        children: [
          const SizedBox(width: 14),
          const Icon(Icons.circle, size: 10, color: Colors.red),
          const SizedBox(width: 8),
          Text(_fmtDur(_recSeconds), style: const TextStyle(fontWeight: FontWeight.w600)),
          const SizedBox(width: 12),
          Expanded(
            child: _recCancel
                ? const Text('Release to cancel', style: TextStyle(color: Colors.red, fontWeight: FontWeight.w600))
                : (_ampSupported && bars.isNotEmpty
                    ? SizedBox(
                        height: 26,
                        child: CustomPaint(
                          painter: _WavePainter(bars: bars, progress: 1.0, active: Colors.red, inactive: Colors.red),
                          size: Size.infinite,
                        ),
                      )
                    : Text('Recording…', style: TextStyle(color: theme.colorScheme.onSurface.withOpacity(0.6)))),
          ),
          Padding(
            padding: const EdgeInsets.only(right: 14, left: 8),
            child: Text('◀ slide to cancel', style: TextStyle(fontSize: 11, color: theme.colorScheme.onSurface.withOpacity(0.45))),
          ),
        ],
      ),
    );
  }

  // ═══════════════════════════════════════════════════════════════════════
  // EMOJI / GIFs / STICKERS PANEL
  // ═══════════════════════════════════════════════════════════════════════
  Widget _buildPanel(ThemeData theme, bool isDark) {
    final bg = isDark ? const Color(0xFF17212B) : Colors.white;
    Widget content;
    if (_activePanel == 'sticker') {
      content = _GiphyPanel(key: const ValueKey('giphy_stickers'), isSticker: true, apiKey: _kGiphyApiKey, onSelected: _sendSticker);
    } else if (_activePanel == 'gif') {
      content = _GiphyPanel(key: const ValueKey('giphy_gifs'), isSticker: false, apiKey: _kGiphyApiKey, onSelected: _sendGif);
    } else {
      content = EmojiPicker(
        textEditingController: _messageController,
        config: Config(
          height: 272,
          emojiViewConfig: EmojiViewConfig(backgroundColor: bg, columns: 8, emojiSizeMax: 28),
          categoryViewConfig: CategoryViewConfig(
            backgroundColor: bg,
            indicatorColor: _kAccent,
            iconColorSelected: _kAccent,
            iconColor: theme.colorScheme.onSurface.withOpacity(0.55),
          ),
          bottomActionBarConfig: BottomActionBarConfig(
            backgroundColor: bg,
            buttonColor: Colors.transparent,
            buttonIconColor: theme.colorScheme.onSurface.withOpacity(0.7),
          ),
          searchViewConfig: SearchViewConfig(backgroundColor: bg),
        ),
      );
    }

    return Container(
      height: 340,
      color: bg,
      child: Column(
        children: [
          Expanded(child: content),
          _buildPanelTabs(theme, isDark),
        ],
      ),
    );
  }

  Widget _buildPanelTabs(ThemeData theme, bool isDark) {
    Widget tab(String label, String key) {
      final selected = _activePanel == key;
      return GestureDetector(
        onTap: () => setState(() => _activePanel = key),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 22, vertical: 9),
          decoration: BoxDecoration(
            color: selected ? (isDark ? const Color(0xFF2B394A) : const Color(0xFFE9E9EC)) : Colors.transparent,
            borderRadius: BorderRadius.circular(22),
          ),
          child: Text(label,
              style: TextStyle(
                fontSize: 15,
                fontWeight: FontWeight.w600,
                color: selected ? theme.colorScheme.onSurface : theme.colorScheme.onSurface.withOpacity(0.55),
              )),
        ),
      );
    }

    return Container(
      padding: const EdgeInsets.only(top: 4, bottom: 8),
      child: SafeArea(
        top: false,
        child: Center(
          child: Container(
            padding: const EdgeInsets.all(3),
            decoration: BoxDecoration(
              color: isDark ? const Color(0xFF1F2C34) : Colors.white,
              borderRadius: BorderRadius.circular(26),
              boxShadow: [BoxShadow(color: Colors.black.withOpacity(0.15), blurRadius: 8, offset: const Offset(0, 2))],
            ),
            child: Row(mainAxisSize: MainAxisSize.min, children: [tab('Emoji', 'emoji'), tab('GIFs', 'gif'), tab('Stickers', 'sticker')]),
          ),
        ),
      ),
    );
  }

  // ═══════════════════════════════════════════════════════════════════════
  // ATTACHMENT BOTTOM SHEET
  // ═══════════════════════════════════════════════════════════════════════
  void _showAttachmentSheet() {
    final reason = _blockReason();
    if (reason != null) {
      _showSnack(reason);
      return;
    }
    _selectedBottomTab = 0;
    _selectedAssets.clear();
    _assetsFuture = _loadAssets(RequestType.common);
    _contactsFuture = null;
    _audioFuture = null;
    _contactSearch.clear();
    _musicSearch.clear();
    FocusScope.of(context).unfocus();
    if (_activePanel != null) setState(() => _activePanel = null);

    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      isScrollControlled: true,
      builder: (sheetContext) {
        return StatefulBuilder(
          builder: (BuildContext ctx, StateSetter setModalState) {
            final isDark = Theme.of(ctx).brightness == Brightness.dark;
            final bg = isDark ? const Color(0xFF17212B) : Colors.white;
            return Padding(
              padding: EdgeInsets.only(bottom: MediaQuery.of(ctx).viewInsets.bottom),
              child: Container(
                height: MediaQuery.of(ctx).size.height * 0.85,
                decoration: BoxDecoration(color: bg, borderRadius: const BorderRadius.vertical(top: Radius.circular(24))),
                child: ClipRRect(
                  borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
                  child: Stack(
                    children: [
                      Column(
                        children: [
                          Container(
                            margin: const EdgeInsets.only(top: 10, bottom: 10),
                            height: 4,
                            width: 40,
                            decoration: BoxDecoration(color: Colors.grey[400], borderRadius: BorderRadius.circular(2)),
                          ),
                          Expanded(child: _buildBottomSheetContent(_selectedBottomTab, setModalState)),
                        ],
                      ),
                      if (_selectedBottomTab == 0 && _selectedAssets.isNotEmpty)
                        Positioned(
                          right: 16,
                          bottom: 96 + MediaQuery.of(ctx).padding.bottom,
                          child: ElevatedButton.icon(
                            style: ElevatedButton.styleFrom(
                              backgroundColor: _kAccent,
                              foregroundColor: Colors.white,
                              shape: const StadiumBorder(),
                              padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
                            ),
                            icon: const Icon(Icons.send, size: 18),
                            label: Text('Send ${_selectedAssets.length}'),
                            onPressed: () {
                              final list = List<AssetEntity>.from(_selectedAssets);
                              _selectedAssets.clear();
                              Navigator.pop(ctx);
                              _sendAssets(list);
                            },
                          ),
                        ),
                      Positioned(
                        left: 12,
                        right: 12,
                        bottom: 12 + MediaQuery.of(ctx).padding.bottom,
                        child: _buildBottomTabBar(setModalState),
                      ),
                    ],
                  ),
                ),
              ),
            );
          },
        );
      },
    );
  }

  Widget _buildBottomSheetContent(int index, StateSetter setModalState) {
    switch (index) {
      case 0:
        return _buildCustomImagePicker(setModalState);
      case 1:
        return _buildFilePicker();
      case 2:
        return _LocationTab(onSendCurrent: _sendCurrentLocation, onShareLive: _startLiveLocation);
      case 3:
        return _buildContactsPicker(setModalState);
      case 4:
        return _buildMusicPicker(setModalState);
      default:
        return const Center(child: Text('Select an option'));
    }
  }

  Widget _buildCustomImagePicker(StateSetter setModalState) {
    return FutureBuilder<List<AssetEntity>>(
      future: _assetsFuture,
      builder: (context, snap) {
        if (snap.connectionState == ConnectionState.waiting) return const Center(child: CircularProgressIndicator());
        if (snap.hasError) {
          return Center(
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              const Icon(Icons.photo_library_outlined, size: 48, color: Colors.grey),
              const SizedBox(height: 8),
              const Text('Allow access to your photos'),
              const SizedBox(height: 8),
              TextButton(onPressed: () async => await PhotoManager.openSetting(), child: const Text('Open settings')),
              TextButton(onPressed: () => setModalState(() => _assetsFuture = _loadAssets(RequestType.common)), child: const Text('Retry')),
            ]),
          );
        }
        final assets = snap.data ?? [];
        return GridView.builder(
          padding: const EdgeInsets.fromLTRB(2, 2, 2, 110),
          gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(crossAxisCount: 3, crossAxisSpacing: 2, mainAxisSpacing: 2),
          itemCount: assets.length + 1,
          itemBuilder: (context, i) {
            if (i == 0) return _CameraPreviewTile(onTap: () => _pickFromCamera(closeSheet: true));
            final a = assets[i - 1];
            final selIndex = _selectedAssets.indexWhere((e) => e.id == a.id);
            return _AssetThumb(
              key: ValueKey(a.id),
              entity: a,
              selectedIndex: selIndex,
              onTap: () => setModalState(() {
                if (selIndex >= 0) {
                  _selectedAssets.removeAt(selIndex);
                } else {
                  _selectedAssets.add(a);
                }
              }),
            );
          },
        );
      },
    );
  }

  Future<void> _uploadAndSendFile(File file, String name) async {
    _showSnack('Uploading file...');
    final url = await CloudinaryService.uploadFile(file, 'luma/files');
    if (url != null) {
      if (mounted) ScaffoldMessenger.of(context).hideCurrentSnackBar();
      await _postMessage({'type': 'file', 'media_type': 'file', 'media_url': url, 'file_name': name});
    } else {
      _showSnack('Upload failed');
    }
  }

  Future<void> _pickFromAppFolder() async {
    final dir = await getApplicationDocumentsDirectory();
    final files = dir.listSync().whereType<File>().toList()
      ..sort((a, b) => b.statSync().modified.compareTo(a.statSync().modified));
    if (!mounted) return;
    if (files.isEmpty) {
      _showSnack('No files in the Luma Chat folder yet');
      return;
    }
    final picked = await showDialog<File>(
      context: context,
      builder: (_) => SimpleDialog(
        title: const Text('Luma Chat'),
        children: files.take(30).map((f) {
          final name = f.path.split('/').last;
          return ListTile(
            leading: const Icon(Icons.insert_drive_file),
            title: Text(name, maxLines: 1, overflow: TextOverflow.ellipsis),
            onTap: () => Navigator.pop(context, f),
          );
        }).toList(),
      ),
    );
    if (picked == null || !mounted) return;
    Navigator.pop(context);
    await _uploadAndSendFile(picked, picked.path.split('/').last);
  }

  Widget _buildFilePicker() {
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 110),
      children: [
        _buildListTile(Icons.storage, Colors.green, 'Internal Storage', 'Browse your file system', onTap: () async {
          FilePickerResult? result = await FilePicker.platform.pickFiles();
          if (result != null && result.files.single.path != null) {
            if (!mounted) return;
            Navigator.pop(context);
            await _uploadAndSendFile(File(result.files.single.path!), result.files.single.name);
          }
        }),
        _buildListTile(Icons.folder, Colors.blue, 'Luma Chat', "Browse the app's folder", onTap: _pickFromAppFolder),
        _buildListTile(Icons.photo_library, Colors.orange, 'Gallery', 'To send images without compression', onTap: () => _pickAndSendMedia('image')),
      ],
    );
  }

  Widget _buildContactsPicker(StateSetter setModalState) {
    _contactsFuture ??= _loadLumaContacts();
    return FutureBuilder<List<_LumaContact>>(
      future: _contactsFuture,
      builder: (context, snapshot) {
        if (snapshot.connectionState == ConnectionState.waiting) return const Center(child: CircularProgressIndicator());
        if (snapshot.hasError) {
          return Center(
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              const Icon(Icons.contacts_outlined, size: 48, color: Colors.grey),
              const SizedBox(height: 8),
              const Text('Allow access to your contacts'),
              TextButton(onPressed: () async => await openAppSettings(), child: const Text('Open settings')),
              TextButton(onPressed: () => setModalState(() => _contactsFuture = _loadLumaContacts()), child: const Text('Retry')),
            ]),
          );
        }
        final all = snapshot.data ?? [];
        final q = _contactSearch.text.trim().toLowerCase();
        final contacts = q.isEmpty ? all : all.where((c) => c.name.toLowerCase().contains(q) || c.phone.contains(q)).toList();
        return Column(
          children: [
            Padding(
              padding: const EdgeInsets.all(12.0),
              child: TextField(
                controller: _contactSearch,
                onChanged: (_) => setModalState(() {}),
                decoration: InputDecoration(
                  hintText: 'Search contacts',
                  prefixIcon: const Icon(Icons.search),
                  filled: true,
                  fillColor: Colors.grey.withOpacity(0.15),
                  border: OutlineInputBorder(borderRadius: BorderRadius.circular(30), borderSide: BorderSide.none),
                ),
              ),
            ),
            Expanded(
              child: contacts.isEmpty
                  ? const Center(child: Text('None of your contacts are on Luma Chat yet'))
                  : ListView.builder(
                      padding: const EdgeInsets.only(bottom: 110),
                      itemCount: contacts.length,
                      itemBuilder: (context, index) {
                        final c = contacts[index];
                        return ListTile(
                          leading: CircleAvatar(
                            backgroundColor: Colors.blue,
                            backgroundImage: (c.avatar != null && c.avatar!.isNotEmpty) ? CachedNetworkImageProvider(c.avatar!) : null,
                            child: (c.avatar == null || c.avatar!.isEmpty)
                                ? Text(c.name.isNotEmpty ? c.name[0].toUpperCase() : '?', style: const TextStyle(color: Colors.white))
                                : null,
                          ),
                          title: Text(c.name, style: const TextStyle(fontWeight: FontWeight.bold)),
                          subtitle: Text(c.phone, style: TextStyle(color: Colors.grey[600])),
                          onTap: () async {
                            Navigator.pop(context);
                            await _postMessage({
                              'type': 'contact',
                              'media_type': 'contact',
                              'text': '${c.name}\n${c.phone}',
                              'contact_name': c.name,
                              'contact_phone': c.phone,
                              'contact_uid': c.uid,
                              'contact_avatar': c.avatar,
                            });
                          },
                        );
                      },
                    ),
            ),
          ],
        );
      },
    );
  }

  Widget _buildMusicPicker(StateSetter setModalState) {
    _audioFuture ??= _loadAssets(RequestType.audio, size: 200);
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.all(12.0),
          child: TextField(
            controller: _musicSearch,
            onChanged: (_) => setModalState(() {}),
            decoration: InputDecoration(
              hintText: 'Search music',
              prefixIcon: const Icon(Icons.search),
              filled: true,
              fillColor: Colors.grey.withOpacity(0.15),
              border: OutlineInputBorder(borderRadius: BorderRadius.circular(30), borderSide: BorderSide.none),
            ),
          ),
        ),
        ListTile(
          leading: const CircleAvatar(backgroundColor: Colors.blue, child: Icon(Icons.audio_file, color: Colors.white)),
          title: const Text('Pick Audio File from Device'),
          subtitle: const Text('Select an MP3 or M4A'),
          onTap: () async {
            FilePickerResult? result = await FilePicker.platform.pickFiles(type: FileType.audio);
            if (result != null && result.files.single.path != null) {
              if (!mounted) return;
              Navigator.pop(context);
              _showSnack('Uploading audio...');
              final file = File(result.files.single.path!);
              final url = await CloudinaryService.uploadAudio(file, 'luma/music');
              if (url != null) {
                if (mounted) ScaffoldMessenger.of(context).hideCurrentSnackBar();
                await _postMessage({'type': 'audio', 'media_type': 'audio', 'media_url': url, 'file_name': result.files.single.name});
              } else {
                _showSnack('Upload failed');
              }
            }
          },
        ),
        Expanded(
          child: FutureBuilder<List<AssetEntity>>(
            future: _audioFuture,
            builder: (context, snap) {
              if (snap.connectionState == ConnectionState.waiting) return const Center(child: CircularProgressIndicator());
              if (snap.hasError) {
                return Center(
                  child: Column(mainAxisSize: MainAxisSize.min, children: [
                    const Text('Allow access to your music'),
                    TextButton(onPressed: () async => await PhotoManager.openSetting(), child: const Text('Open settings')),
                    TextButton(onPressed: () => setModalState(() => _audioFuture = _loadAssets(RequestType.audio, size: 200)), child: const Text('Retry')),
                  ]),
                );
              }
              final q = _musicSearch.text.trim().toLowerCase();
              final items = (snap.data ?? []).where((a) => q.isEmpty || (a.title ?? '').toLowerCase().contains(q)).toList();
              if (items.isEmpty) return const Center(child: Text('No music found'));
              return ListView.builder(
                padding: const EdgeInsets.only(bottom: 110),
                itemCount: items.length,
                itemBuilder: (context, i) {
                  final a = items[i];
                  final title = (a.title == null || a.title!.isEmpty) ? 'Audio' : a.title!;
                  return ListTile(
                    leading: const CircleAvatar(backgroundColor: _kAccent, child: Icon(Icons.music_note, color: Colors.white)),
                    title: Text(title, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontWeight: FontWeight.bold)),
                    subtitle: Text(_fmtDur(a.duration), style: TextStyle(color: Colors.grey[600])),
                    onTap: () async {
                      final file = await a.file;
                      if (file == null) {
                        _showSnack('Could not read this file');
                        return;
                      }
                      if (!mounted) return;
                      Navigator.pop(context);
                      _showSnack('Uploading audio...');
                      final url = await CloudinaryService.uploadAudio(file, 'luma/music');
                      if (url != null) {
                        if (mounted) ScaffoldMessenger.of(context).hideCurrentSnackBar();
                        await _postMessage({'type': 'audio', 'media_type': 'audio', 'media_url': url, 'file_name': title, 'duration': a.duration});
                      } else {
                        _showSnack('Upload failed');
                      }
                    },
                  );
                },
              );
            },
          ),
        ),
      ],
    );
  }

  Widget _buildListTile(IconData icon, Color color, String title, String subtitle, {required VoidCallback onTap}) {
    return ListTile(
      leading: CircleAvatar(backgroundColor: color, child: Icon(icon, color: Colors.white)),
      title: Text(title, style: const TextStyle(fontWeight: FontWeight.bold)),
      subtitle: Text(subtitle, style: TextStyle(color: Colors.grey[600])),
      onTap: onTap,
    );
  }

  Widget _buildBottomTabBar(StateSetter setModalState) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 6),
      decoration: BoxDecoration(
        color: isDark ? const Color(0xFF1F2C34) : Colors.white,
        borderRadius: BorderRadius.circular(32),
        boxShadow: [BoxShadow(color: Colors.black.withOpacity(0.18), blurRadius: 12, offset: const Offset(0, 3))],
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceEvenly,
        children: [
          _buildTabIcon(Icons.photo_library_outlined, 'Gallery', 0, setModalState),
          _buildTabIcon(Icons.insert_drive_file_outlined, 'File', 1, setModalState),
          _buildTabIcon(Icons.location_on_outlined, 'Location', 2, setModalState),
          _buildTabIcon(Icons.account_circle_outlined, 'Contact', 3, setModalState),
          _buildTabIcon(Icons.play_circle_outline, 'Music', 4, setModalState),
        ],
      ),
    );
  }

  Widget _buildTabIcon(IconData icon, String label, int index, StateSetter setModalState) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final base = isDark ? Colors.white70 : Colors.black87;
    final isSelected = _selectedBottomTab == index;
    return GestureDetector(
      onTap: () => setModalState(() => _selectedBottomTab = index),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
        decoration: BoxDecoration(
          color: isSelected ? _kAccent.withOpacity(0.12) : Colors.transparent,
          borderRadius: BorderRadius.circular(24),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, color: isSelected ? _kAccent : base, size: 24),
            const SizedBox(height: 4),
            Text(
              label,
              style: TextStyle(
                color: isSelected ? _kAccent : base,
                fontSize: 11,
                fontWeight: isSelected ? FontWeight.bold : FontWeight.normal,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ═══════════════════════════════════════════════════════════════════════════
// IN-CHAT SEARCH (Messages / Media / Links / Files)
// ═══════════════════════════════════════════════════════════════════════════
class _ChatSearchScreen extends StatefulWidget {
  final int initialTab;
  final List<Map<String, dynamic>> Function() getMessages;
  final Future<bool> Function() loadOlder;
  final bool Function() hasMore;
  final String Function(String? uid) nameOf;
  final String? Function(String? uid) avatarOf;

  const _ChatSearchScreen({
    required this.initialTab,
    required this.getMessages,
    required this.loadOlder,
    required this.hasMore,
    required this.nameOf,
    required this.avatarOf,
  });

  @override
  State<_ChatSearchScreen> createState() => _ChatSearchScreenState();
}

class _ChatSearchScreenState extends State<_ChatSearchScreen> with SingleTickerProviderStateMixin {
  late final TabController _tabs = TabController(length: 4, vsync: this, initialIndex: widget.initialTab.clamp(0, 3));
  final _ctrl = TextEditingController();
  bool _loadingMore = false;

  @override
  void dispose() {
    _tabs.dispose();
    _ctrl.dispose();
    super.dispose();
  }

  String get _q => _ctrl.text.trim().toLowerCase();

  Future<void> _more() async {
    if (_loadingMore) return;
    setState(() => _loadingMore = true);
    await widget.loadOlder();
    if (mounted) setState(() => _loadingMore = false);
  }

  Widget _loadMoreTile() {
    if (!widget.hasMore()) return const SizedBox(height: 24);
    return Padding(
      padding: const EdgeInsets.all(12),
      child: Center(
        child: _loadingMore
            ? const SizedBox(width: 22, height: 22, child: CircularProgressIndicator(strokeWidth: 2))
            : TextButton(onPressed: _more, child: const Text('Load older messages')),
      ),
    );
  }

  Widget _hint(String t) => Center(child: Text(t, style: TextStyle(color: Colors.grey[500])));

  Widget _avatar(String? uid, {double r = 18}) {
    final a = widget.avatarOf(uid);
    final name = widget.nameOf(uid);
    return CircleAvatar(
      radius: r,
      backgroundColor: _colorForUid(uid).withOpacity(0.25),
      backgroundImage: (a != null && a.isNotEmpty) ? CachedNetworkImageProvider(a) : null,
      child: (a == null || a.isEmpty) ? Text(name.isNotEmpty ? name[0].toUpperCase() : '?', style: TextStyle(color: _colorForUid(uid))) : null,
    );
  }

  Widget _messagesTab() {
    final q = _q;
    if (q.isEmpty) return _hint('Type to search messages');
    final res = widget
        .getMessages()
        .where((m) => (m['type'] ?? 'text') == 'text' && _stripFormatting((m['text'] ?? '').toString()).toLowerCase().contains(q))
        .toList();
    return ListView(
      children: [
        if (res.isEmpty) Padding(padding: const EdgeInsets.all(24), child: _hint('No results in loaded messages')),
        ...res.map((m) => ListTile(
              leading: _avatar(m['sender_id']?.toString()),
              title: Text(widget.nameOf(m['sender_id']?.toString()), style: const TextStyle(fontWeight: FontWeight.w600)),
              subtitle: Text(_stripFormatting((m['text'] ?? '').toString()), maxLines: 2, overflow: TextOverflow.ellipsis),
              trailing: Text(DateFormat('d MMM').format(_msgTime(m)), style: const TextStyle(fontSize: 12)),
              onTap: () => Navigator.pop(context, m['id'].toString()),
            )),
        _loadMoreTile(),
      ],
    );
  }

  Widget _mediaTab() {
    final items = widget.getMessages().where((m) {
      final t = (m['type'] ?? '').toString();
      return (t == 'image' || t == 'video' || t == 'gif') && m['media_url'] != null;
    }).toList();
    return CustomScrollView(
      slivers: [
        if (items.isEmpty)
          SliverToBoxAdapter(child: Padding(padding: const EdgeInsets.all(32), child: _hint('No media in loaded messages')))
        else
          SliverGrid(
            gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(crossAxisCount: 3, crossAxisSpacing: 2, mainAxisSpacing: 2),
            delegate: SliverChildBuilderDelegate((context, i) {
              final m = items[i];
              final isVideo = m['type'] == 'video';
              return GestureDetector(
                onTap: () => Navigator.pop(context, m['id'].toString()),
                child: isVideo
                    ? Container(color: Colors.black87, child: const Center(child: Icon(Icons.play_circle_fill, color: Colors.white, size: 36)))
                    : CachedNetworkImage(
                        imageUrl: m['media_url'].toString(),
                        fit: BoxFit.cover,
                        errorWidget: (_, __, ___) => Container(color: Colors.black12, child: const Icon(Icons.broken_image)),
                      ),
              );
            }, childCount: items.length),
          ),
        SliverToBoxAdapter(child: _loadMoreTile()),
      ],
    );
  }

  Widget _linksTab() {
    final q = _q;
    final entries = <MapEntry<String, Map<String, dynamic>>>[];
    for (final m in widget.getMessages()) {
      if ((m['type'] ?? 'text') != 'text') continue;
      final text = (m['text'] ?? '').toString();
      for (final match in RegExp(r'https?://[^\s]+').allMatches(text)) {
        var u = match.group(0)!;
        while (u.isNotEmpty && '.,;:!?)'.contains(u[u.length - 1])) {
          u = u.substring(0, u.length - 1);
        }
        if (u.isEmpty) continue;
        if (q.isEmpty || u.toLowerCase().contains(q) || text.toLowerCase().contains(q)) entries.add(MapEntry(u, m));
      }
    }
    return ListView(
      children: [
        if (entries.isEmpty) Padding(padding: const EdgeInsets.all(32), child: _hint('No links in loaded messages')),
        ...entries.map((e) => ListTile(
              leading: const CircleAvatar(backgroundColor: _kAccent, child: Icon(Icons.link, color: Colors.white)),
              title: Text(e.key, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(color: _kAccent)),
              subtitle: Text('${widget.nameOf(e.value['sender_id']?.toString())} · ${DateFormat('d MMM').format(_msgTime(e.value))}'),
              trailing: IconButton(icon: const Icon(Icons.open_in_new, size: 20), onPressed: () => _openUrl(e.key)),
              onTap: () => Navigator.pop(context, e.value['id'].toString()),
            )),
        _loadMoreTile(),
      ],
    );
  }

  Widget _filesTab() {
    final q = _q;
    final items = widget.getMessages().where((m) {
      final t = (m['type'] ?? '').toString();
      if (!(t == 'file' || (t == 'audio' && m['file_name'] != null))) return false;
      return q.isEmpty || (m['file_name'] ?? '').toString().toLowerCase().contains(q);
    }).toList();
    return ListView(
      children: [
        if (items.isEmpty) Padding(padding: const EdgeInsets.all(32), child: _hint('No files in loaded messages')),
        ...items.map((m) => ListTile(
              leading: CircleAvatar(
                backgroundColor: _kAccent,
                child: Icon(m['type'] == 'audio' ? Icons.music_note : Icons.insert_drive_file, color: Colors.white),
              ),
              title: Text((m['file_name'] ?? 'File').toString(), maxLines: 1, overflow: TextOverflow.ellipsis),
              subtitle: Text('${widget.nameOf(m['sender_id']?.toString())} · ${DateFormat('d MMM').format(_msgTime(m))}'),
              onTap: () => Navigator.pop(context, m['id'].toString()),
            )),
        _loadMoreTile(),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        titleSpacing: 0,
        title: TextField(
          controller: _ctrl,
          autofocus: widget.initialTab == 0,
          onChanged: (_) => setState(() {}),
          decoration: const InputDecoration(hintText: 'Search', border: InputBorder.none, enabledBorder: InputBorder.none, focusedBorder: InputBorder.none, filled: false),
        ),
        actions: [
          if (_ctrl.text.isNotEmpty)
            IconButton(
              icon: const Icon(Icons.close),
              onPressed: () {
                _ctrl.clear();
                setState(() {});
              },
            ),
        ],
        bottom: TabBar(
          controller: _tabs,
          tabs: const [Tab(text: 'Messages'), Tab(text: 'Media'), Tab(text: 'Links'), Tab(text: 'Files')],
        ),
      ),
      body: TabBarView(
        controller: _tabs,
        children: [_messagesTab(), _mediaTab(), _linksTab(), _filesTab()],
      ),
    );
  }
}


// ═══════════════════════════════════════════════════════════════════════════
// RICH TEXT (bold / italic / mono / spoiler / links / @mentions)
// ═══════════════════════════════════════════════════════════════════════════
class _RichMessageText extends StatefulWidget {
  final String text;
  final TextStyle style;
  final List<String> mentionNames;
  final Color mentionColor;
  final Color linkColor;

  const _RichMessageText({
    required this.text,
    required this.style,
    required this.mentionNames,
    required this.mentionColor,
    required this.linkColor,
  });

  @override
  State<_RichMessageText> createState() => _RichMessageTextState();
}

class _RichMessageTextState extends State<_RichMessageText> {
  final List<TapGestureRecognizer> _recs = [];
  final Set<int> _revealed = {};

  @override
  void dispose() {
    for (final r in _recs) {
      r.dispose();
    }
    super.dispose();
  }

  List<InlineSpan> _mentionSpans(String s, TextStyle base) {
    if (widget.mentionNames.isEmpty || s.isEmpty) return [TextSpan(text: s, style: base)];
    final names = [...widget.mentionNames]..sort((a, b) => b.length.compareTo(a.length));
    final re = RegExp('@(${names.map(RegExp.escape).join('|')})(?=\\s|\$|[.,!?;:])');
    final out = <InlineSpan>[];
    var last = 0;
    for (final m in re.allMatches(s)) {
      if (m.start > last) out.add(TextSpan(text: s.substring(last, m.start), style: base));
      out.add(TextSpan(text: m.group(0), style: base.copyWith(color: widget.mentionColor, fontWeight: FontWeight.w700)));
      last = m.end;
    }
    if (last < s.length) out.add(TextSpan(text: s.substring(last), style: base));
    return out;
  }

  List<InlineSpan> _parse(String text, TextStyle base) {
    final spans = <InlineSpan>[];
    final re = RegExp(r'\*\*(.+?)\*\*|__(.+?)__|`(.+?)`|\|\|(.+?)\|\||(https?://[^\s]+)', dotAll: true);
    var last = 0;
    var spoilerIdx = 0;
    for (final m in re.allMatches(text)) {
      if (m.start > last) spans.addAll(_mentionSpans(text.substring(last, m.start), base));
      if (m.group(1) != null) {
        spans.addAll(_mentionSpans(m.group(1)!, base.copyWith(fontWeight: FontWeight.w700)));
      } else if (m.group(2) != null) {
        spans.addAll(_mentionSpans(m.group(2)!, base.copyWith(fontStyle: FontStyle.italic)));
      } else if (m.group(3) != null) {
        spans.add(TextSpan(
          text: m.group(3),
          style: base.copyWith(fontFamily: 'monospace', backgroundColor: (base.color ?? Colors.black).withOpacity(0.12)),
        ));
      } else if (m.group(4) != null) {
        final idx = spoilerIdx++;
        final revealed = _revealed.contains(idx);
        final rec = TapGestureRecognizer()..onTap = () => setState(() => _revealed.add(idx));
        _recs.add(rec);
        spans.add(TextSpan(
          text: m.group(4),
          style: revealed
              ? base
              : base.copyWith(color: Colors.transparent, backgroundColor: (base.color ?? Colors.black).withOpacity(0.5)),
          recognizer: revealed ? null : rec,
        ));
      } else if (m.group(5) != null) {
        var url = m.group(5)!;
        var trail = '';
        while (url.isNotEmpty && '.,;:!?)'.contains(url[url.length - 1])) {
          trail = url[url.length - 1] + trail;
          url = url.substring(0, url.length - 1);
        }
        final target = url;
        final rec = TapGestureRecognizer()..onTap = () => _openUrl(target);
        _recs.add(rec);
        spans.add(TextSpan(
          text: url,
          style: base.copyWith(color: widget.linkColor, decoration: TextDecoration.underline),
          recognizer: rec,
        ));
        if (trail.isNotEmpty) spans.add(TextSpan(text: trail, style: base));
      }
      last = m.end;
    }
    if (last < text.length) spans.addAll(_mentionSpans(text.substring(last), base));
    return spans;
  }

  @override
  Widget build(BuildContext context) {
    for (final r in _recs) {
      r.dispose();
    }
    _recs.clear();
    return Text.rich(TextSpan(children: _parse(widget.text, widget.style)));
  }
}

// ═══════════════════════════════════════════════════════════════════════════
// SWIPE TO REPLY
// ═══════════════════════════════════════════════════════════════════════════
class _SwipeToReply extends StatefulWidget {
  final Widget child;
  final VoidCallback onReply;
  final bool enabled;
  const _SwipeToReply({required this.child, required this.onReply, required this.enabled});

  @override
  State<_SwipeToReply> createState() => _SwipeToReplyState();
}

class _SwipeToReplyState extends State<_SwipeToReply> with SingleTickerProviderStateMixin {
  double _dx = 0;
  bool _fired = false;
  late final AnimationController _c = AnimationController(vsync: this, duration: const Duration(milliseconds: 200));
  Animation<double>? _a;

  @override
  void initState() {
    super.initState();
    _c.addListener(() {
      final a = _a;
      if (a != null) setState(() => _dx = a.value);
    });
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  void _update(DragUpdateDetails d) {
    if (!widget.enabled) return;
    setState(() => _dx = (_dx + d.delta.dx).clamp(-90.0, 0.0).toDouble());
    if (!_fired && _dx <= -60) {
      _fired = true;
      HapticFeedback.lightImpact();
    }
  }

  void _end(DragEndDetails d) {
    if (_fired) widget.onReply();
    _fired = false;
    _a = Tween<double>(begin: _dx, end: 0).animate(CurvedAnimation(parent: _c, curve: Curves.easeOut));
    _c.forward(from: 0);
  }

  @override
  Widget build(BuildContext context) {
    if (!widget.enabled) return widget.child;
    final p = _c01(-_dx / 60);
    return GestureDetector(
      behavior: HitTestBehavior.translucent,
      onHorizontalDragUpdate: _update,
      onHorizontalDragEnd: _end,
      child: Stack(
        alignment: Alignment.centerRight,
        children: [
          Positioned(
            right: 10,
            child: Opacity(
              opacity: p,
              child: Container(
                width: 30,
                height: 30,
                decoration: BoxDecoration(color: Colors.black.withOpacity(0.25), shape: BoxShape.circle),
                child: const Icon(Icons.reply, size: 18, color: Colors.white),
              ),
            ),
          ),
          Transform.translate(offset: Offset(_dx, 0), child: widget.child),
        ],
      ),
    );
  }
}

// ═══════════════════════════════════════════════════════════════════════════
// VIDEO BUBBLE (loads only when tapped)
// ═══════════════════════════════════════════════════════════════════════════
class _VideoBubble extends StatefulWidget {
  final String url;
  const _VideoBubble({super.key, required this.url});

  @override
  State<_VideoBubble> createState() => _VideoBubbleState();
}

class _VideoBubbleState extends State<_VideoBubble> {
  VideoPlayerController? _c;
  bool _loading = false;
  bool _error = false;

  void _tick() {
    if (mounted) setState(() {});
  }

  Future<void> _start() async {
    final existing = _c;
    if (existing != null) {
      if (existing.value.isPlaying) {
        existing.pause();
      } else {
        existing.play();
      }
      setState(() {});
      return;
    }
    setState(() {
      _loading = true;
      _error = false;
    });
    try {
      final c = VideoPlayerController.networkUrl(Uri.parse(widget.url));
      await c.initialize();
      if (!mounted) {
        c.dispose();
        return;
      }
      c.addListener(_tick);
      await c.play();
      setState(() {
        _c = c;
        _loading = false;
      });
    } catch (_) {
      if (mounted) {
        setState(() {
          _loading = false;
          _error = true;
        });
      }
    }
  }

  @override
  void dispose() {
    _c?.removeListener(_tick);
    _c?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final c = _c;
    return ClipRRect(
      borderRadius: BorderRadius.circular(10),
      child: GestureDetector(
        onTap: _loading ? null : _start,
        child: SizedBox(
          width: 230,
          child: (c != null && c.value.isInitialized)
              ? AspectRatio(
                  aspectRatio: c.value.aspectRatio == 0 ? 16 / 9 : c.value.aspectRatio,
                  child: Stack(
                    alignment: Alignment.center,
                    children: [
                      VideoPlayer(c),
                      if (!c.value.isPlaying)
                        Container(
                          padding: const EdgeInsets.all(10),
                          decoration: const BoxDecoration(color: Colors.black54, shape: BoxShape.circle),
                          child: const Icon(Icons.play_arrow, color: Colors.white, size: 32),
                        ),
                      Positioned(left: 0, right: 0, bottom: 0, child: VideoProgressIndicator(c, allowScrubbing: true, padding: const EdgeInsets.only(top: 6))),
                    ],
                  ),
                )
              : Container(
                  height: 150,
                  color: Colors.black,
                  alignment: Alignment.center,
                  child: _loading
                      ? const SizedBox(width: 28, height: 28, child: CircularProgressIndicator(strokeWidth: 2.5, color: Colors.white))
                      : _error
                          ? const Column(mainAxisSize: MainAxisSize.min, children: [
                              Icon(Icons.error_outline, color: Colors.white70),
                              SizedBox(height: 4),
                              Text('Could not play. Tap to retry', style: TextStyle(color: Colors.white70, fontSize: 12)),
                            ])
                          : Container(
                              padding: const EdgeInsets.all(12),
                              decoration: const BoxDecoration(color: Colors.white24, shape: BoxShape.circle),
                              child: const Icon(Icons.play_arrow, color: Colors.white, size: 34),
                            ),
                ),
        ),
      ),
    );
  }
}

// ═══════════════════════════════════════════════════════════════════════════
// LINK PREVIEW (real Open Graph fetch, cached)
// ═══════════════════════════════════════════════════════════════════════════
class _LinkPreviewData {
  final String url;
  final String host;
  final String? title;
  final String? description;
  final String? image;
  const _LinkPreviewData({required this.url, required this.host, this.title, this.description, this.image});
}

final Map<String, Future<_LinkPreviewData>> _linkPreviewCache = {};

String _unescapeHtml(String s) => s
    .replaceAll('&amp;', '&')
    .replaceAll('&quot;', '"')
    .replaceAll('&#39;', "'")
    .replaceAll('&#x27;', "'")
    .replaceAll('&lt;', '<')
    .replaceAll('&gt;', '>')
    .trim();

Future<_LinkPreviewData> _loadLinkPreview(String url) {
  return _linkPreviewCache.putIfAbsent(url, () async {
    final uri = Uri.tryParse(url);
    final host = uri?.host ?? url;
    try {
      final res = await http.get(uri!, headers: {'User-Agent': 'Mozilla/5.0 (compatible; LumaChatBot/1.0)'}).timeout(const Duration(seconds: 8));
      if (res.statusCode != 200) return _LinkPreviewData(url: url, host: host);
      final body = res.body.length > 200000 ? res.body.substring(0, 200000) : res.body;

      String? meta(String prop) {
        final r1 = RegExp('''<meta[^>]+(?:property|name)=["']$prop["'][^>]*content=["']([^"']*)["']''', caseSensitive: false).firstMatch(body);
        if (r1 != null) return r1.group(1);
        final r2 = RegExp('''<meta[^>]+content=["']([^"']*)["'][^>]*(?:property|name)=["']$prop["']''', caseSensitive: false).firstMatch(body);
        return r2?.group(1);
      }

      var title = meta('og:title') ?? meta('twitter:title');
      title ??= RegExp(r'<title[^>]*>([^<]*)</title>', caseSensitive: false).firstMatch(body)?.group(1);
      final desc = meta('og:description') ?? meta('description') ?? meta('twitter:description');
      var image = meta('og:image') ?? meta('twitter:image');
      if (image != null && image.isNotEmpty) {
        image = uri.resolve(_unescapeHtml(image)).toString();
      }
      return _LinkPreviewData(
        url: url,
        host: host,
        title: (title == null || title.trim().isEmpty) ? null : _unescapeHtml(title),
        description: (desc == null || desc.trim().isEmpty) ? null : _unescapeHtml(desc),
        image: (image == null || image.isEmpty) ? null : image,
      );
    } catch (_) {
      return _LinkPreviewData(url: url, host: host);
    }
  });
}

class _LinkPreviewCard extends StatefulWidget {
  final String url;
  const _LinkPreviewCard({required this.url});

  @override
  State<_LinkPreviewCard> createState() => _LinkPreviewCardState();
}

class _LinkPreviewCardState extends State<_LinkPreviewCard> {
  late Future<_LinkPreviewData> _f;

  @override
  void initState() {
    super.initState();
    _f = _loadLinkPreview(widget.url);
  }

  @override
  void didUpdateWidget(covariant _LinkPreviewCard old) {
    super.didUpdateWidget(old);
    if (old.url != widget.url) _f = _loadLinkPreview(widget.url);
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<_LinkPreviewData>(
      future: _f,
      builder: (context, snap) {
        final d = snap.data;
        if (d == null || (d.title == null && d.description == null && d.image == null)) return const SizedBox.shrink();
        return GestureDetector(
          onTap: () => _openUrl(d.url),
          child: Container(
            width: 230,
            padding: const EdgeInsets.fromLTRB(8, 6, 8, 8),
            decoration: BoxDecoration(
              color: _kAccent.withOpacity(0.08),
              border: const Border(left: BorderSide(color: _kAccent, width: 3)),
              borderRadius: BorderRadius.circular(6),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(d.host, style: const TextStyle(color: _kAccent, fontSize: 12, fontWeight: FontWeight.w700)),
                if (d.title != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 2),
                    child: Text(d.title!, maxLines: 2, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 13.5, fontWeight: FontWeight.w700)),
                  ),
                if (d.description != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 2),
                    child: Text(d.description!, maxLines: 3, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 12.5)),
                  ),
                if (d.image != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 6),
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(6),
                      child: CachedNetworkImage(
                        imageUrl: d.image!,
                        width: 214,
                        height: 110,
                        fit: BoxFit.cover,
                        errorWidget: (_, __, ___) => const SizedBox.shrink(),
                      ),
                    ),
                  ),
              ],
            ),
          ),
        );
      },
    );
  }
}

// ═══════════════════════════════════════════════════════════════════════════
// WAVEFORM PAINTER
// ═══════════════════════════════════════════════════════════════════════════
class _WavePainter extends CustomPainter {
  final List<double>? bars;
  final double progress;
  final Color active;
  final Color inactive;

  _WavePainter({required this.bars, required this.progress, required this.active, required this.inactive});

  @override
  void paint(Canvas canvas, Size size) {
    final b = bars;
    final pr = _c01(progress);
    if (b == null || b.isEmpty) {
      final track = Paint()
        ..color = inactive
        ..strokeWidth = 3
        ..strokeCap = StrokeCap.round;
      final done = Paint()
        ..color = active
        ..strokeWidth = 3
        ..strokeCap = StrokeCap.round;
      final y = size.height / 2;
      canvas.drawLine(Offset(0, y), Offset(size.width, y), track);
      canvas.drawLine(Offset(0, y), Offset(size.width * pr, y), done);
      canvas.drawCircle(Offset(size.width * pr, y), 5, Paint()..color = active);
      return;
    }
    final n = b.length;
    const gap = 2.0;
    final w = math.max(1.0, (size.width - gap * (n - 1)) / n);
    for (var i = 0; i < n; i++) {
      final h = math.max(3.0, _c01(b[i]) * size.height);
      final x = i * (w + gap);
      final played = (i + 0.5) / n <= pr;
      canvas.drawRRect(
        RRect.fromRectAndRadius(Rect.fromLTWH(x, (size.height - h) / 2, w, h), Radius.circular(w / 2)),
        Paint()..color = played ? active : inactive,
      );
    }
  }

  @override
  bool shouldRepaint(covariant _WavePainter o) =>
      o.progress != progress || o.bars != bars || o.active != active || o.inactive != inactive;
}

// ═══════════════════════════════════════════════════════════════════════════
// FORWARD PICKER
// ═══════════════════════════════════════════════════════════════════════════
class _ForwardPicker extends StatefulWidget {
  final Future<List<_ChatChoice>> Function() loader;
  const _ForwardPicker({required this.loader});

  @override
  State<_ForwardPicker> createState() => _ForwardPickerState();
}

class _ForwardPickerState extends State<_ForwardPicker> {
  late final Future<List<_ChatChoice>> _f = widget.loader();
  final Set<String> _sel = {};

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Container(
      height: MediaQuery.of(context).size.height * 0.7,
      decoration: BoxDecoration(
        color: isDark ? const Color(0xFF17212B) : Colors.white,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
      ),
      child: FutureBuilder<List<_ChatChoice>>(
        future: _f,
        builder: (context, snap) {
          final list = snap.data ?? [];
          return Column(
            children: [
              Container(
                margin: const EdgeInsets.only(top: 10, bottom: 8),
                height: 4,
                width: 40,
                decoration: BoxDecoration(color: Colors.grey[400], borderRadius: BorderRadius.circular(2)),
              ),
              const Padding(
                padding: EdgeInsets.fromLTRB(16, 4, 16, 8),
                child: Align(alignment: Alignment.centerLeft, child: Text('Forward to…', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700))),
              ),
              Expanded(
                child: snap.connectionState == ConnectionState.waiting
                    ? const Center(child: CircularProgressIndicator())
                    : snap.hasError
                        ? const Center(child: Text('Could not load your chats'))
                        : list.isEmpty
                            ? const Center(child: Text('No chats found'))
                            : ListView.builder(
                                itemCount: list.length,
                                itemBuilder: (context, i) {
                                  final c = list[i];
                                  final on = _sel.contains(c.id);
                                  return ListTile(
                                    leading: CircleAvatar(
                                      backgroundImage: (c.avatar != null && c.avatar!.isNotEmpty) ? CachedNetworkImageProvider(c.avatar!) : null,
                                      child: (c.avatar == null || c.avatar!.isEmpty) ? Text(c.title.isNotEmpty ? c.title[0].toUpperCase() : '?') : null,
                                    ),
                                    title: Text(c.title, maxLines: 1, overflow: TextOverflow.ellipsis),
                                    trailing: Icon(on ? Icons.check_circle : Icons.radio_button_unchecked, color: on ? _kAccent : Colors.grey),
                                    onTap: () => setState(() => on ? _sel.remove(c.id) : _sel.add(c.id)),
                                  );
                                },
                              ),
              ),
              SafeArea(
                top: false,
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
                  child: SizedBox(
                    width: double.infinity,
                    height: 48,
                    child: ElevatedButton(
                      style: ElevatedButton.styleFrom(backgroundColor: _kAccent, foregroundColor: Colors.white, shape: const StadiumBorder()),
                      onPressed: _sel.isEmpty ? null : () => Navigator.pop(context, list.where((c) => _sel.contains(c.id)).toList()),
                      child: Text(_sel.isEmpty ? 'Select chats' : 'Forward (${_sel.length})'),
                    ),
                  ),
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}

// ═══════════════════════════════════════════════════════════════════════════
// IMAGE VIEWER
// ═══════════════════════════════════════════════════════════════════════════
class _ImageViewerScreen extends StatelessWidget {
  final String imagePath;
  const _ImageViewerScreen({required this.imagePath});

  @override
  Widget build(BuildContext context) => Scaffold(
        backgroundColor: Colors.black,
        appBar: AppBar(
          backgroundColor: Colors.black,
          leading: IconButton(icon: const Icon(Icons.close, color: Colors.white), onPressed: () => Navigator.pop(context)),
          actions: [
            IconButton(
              icon: const Icon(Icons.open_in_new, color: Colors.white),
              tooltip: 'Open with…',
              onPressed: () => OpenFilex.open(imagePath),
            ),
          ],
        ),
        body: Center(child: InteractiveViewer(maxScale: 5, child: Image.file(File(imagePath)))),
      );
}

// ═══════════════════════════════════════════════════════════════════════════
// ATTACHMENT SHEET WIDGETS
// ═══════════════════════════════════════════════════════════════════════════
class _CameraPreviewTile extends StatefulWidget {
  final VoidCallback onTap;
  const _CameraPreviewTile({required this.onTap});

  @override
  State<_CameraPreviewTile> createState() => _CameraPreviewTileState();
}

class _CameraPreviewTileState extends State<_CameraPreviewTile> {
  CameraController? _controller;

  @override
  void initState() {
    super.initState();
    _initCamera();
  }

  Future<void> _initCamera() async {
    try {
      final cams = await availableCameras();
      if (cams.isEmpty) return;
      final back = cams.firstWhere((c) => c.lensDirection == CameraLensDirection.back, orElse: () => cams.first);
      final c = CameraController(back, ResolutionPreset.low, enableAudio: false);
      await c.initialize();
      if (!mounted) {
        c.dispose();
        return;
      }
      setState(() => _controller = c);
    } catch (_) {}
  }

  @override
  void dispose() {
    _controller?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final c = _controller;
    return GestureDetector(
      onTap: widget.onTap,
      child: Stack(
        fit: StackFit.expand,
        children: [
          Container(color: Colors.black87),
          if (c != null && c.value.isInitialized && c.value.previewSize != null)
            ClipRect(
              child: FittedBox(
                fit: BoxFit.cover,
                child: SizedBox(width: c.value.previewSize!.height, height: c.value.previewSize!.width, child: CameraPreview(c)),
              ),
            ),
          const Center(child: Icon(Icons.camera_alt, color: Colors.white, size: 28)),
        ],
      ),
    );
  }
}

class _AssetThumb extends StatefulWidget {
  final AssetEntity entity;
  final int selectedIndex;
  final VoidCallback onTap;
  const _AssetThumb({super.key, required this.entity, required this.selectedIndex, required this.onTap});

  @override
  State<_AssetThumb> createState() => _AssetThumbState();
}

class _AssetThumbState extends State<_AssetThumb> {
  late final Future<Uint8List?> _thumb = widget.entity.thumbnailDataWithSize(const ThumbnailSize(300, 300));

  @override
  Widget build(BuildContext context) {
    final selected = widget.selectedIndex >= 0;
    return GestureDetector(
      onTap: widget.onTap,
      child: Stack(
        fit: StackFit.expand,
        children: [
          FutureBuilder<Uint8List?>(
            future: _thumb,
            builder: (context, snap) {
              if (snap.data == null) return Container(color: Colors.grey.withOpacity(0.25));
              return Image.memory(snap.data!, fit: BoxFit.cover, gaplessPlayback: true);
            },
          ),
          if (selected) Container(color: Colors.black26),
          if (widget.entity.type == AssetType.video)
            Positioned(
              left: 6,
              bottom: 6,
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 2),
                decoration: BoxDecoration(color: Colors.black54, borderRadius: BorderRadius.circular(8)),
                child: Text(_fmtDur(widget.entity.duration), style: const TextStyle(color: Colors.white, fontSize: 11)),
              ),
            ),
          Positioned(
            top: 6,
            right: 6,
            child: Container(
              width: 24,
              height: 24,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: selected ? _kAccent : Colors.black26,
                border: Border.all(color: Colors.white, width: 2),
              ),
              child: selected
                  ? Text('${widget.selectedIndex + 1}', style: const TextStyle(color: Colors.white, fontSize: 12, fontWeight: FontWeight.bold))
                  : null,
            ),
          ),
        ],
      ),
    );
  }
}

class _LocationTab extends StatefulWidget {
  final void Function(Position) onSendCurrent;
  final void Function(Position, Duration) onShareLive;
  const _LocationTab({required this.onSendCurrent, required this.onShareLive});

  @override
  State<_LocationTab> createState() => _LocationTabState();
}

class _LocationTabState extends State<_LocationTab> {
  Position? _pos;
  String? _error;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _locate();
  }

  Future<void> _locate() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      if (!await Geolocator.isLocationServiceEnabled()) throw 'Turn on location services';
      var perm = await Geolocator.checkPermission();
      if (perm == LocationPermission.denied) perm = await Geolocator.requestPermission();
      if (perm == LocationPermission.denied || perm == LocationPermission.deniedForever) throw 'Location permission denied';
      final p = await Geolocator.getCurrentPosition().timeout(const Duration(seconds: 15));
      if (!mounted) return;
      setState(() {
        _pos = p;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e is TimeoutException ? 'Could not get your location. Try again.' : e.toString();
        _loading = false;
      });
    }
  }

  Future<void> _chooseDuration() async {
    final d = await showDialog<Duration>(
      context: context,
      builder: (_) => SimpleDialog(
        title: const Text('Share live location for...'),
        children: [
          SimpleDialogOption(onPressed: () => Navigator.pop(context, const Duration(minutes: 15)), child: const Padding(padding: EdgeInsets.symmetric(vertical: 8), child: Text('15 minutes'))),
          SimpleDialogOption(onPressed: () => Navigator.pop(context, const Duration(hours: 1)), child: const Padding(padding: EdgeInsets.symmetric(vertical: 8), child: Text('1 hour'))),
          SimpleDialogOption(onPressed: () => Navigator.pop(context, const Duration(hours: 8)), child: const Padding(padding: EdgeInsets.symmetric(vertical: 8), child: Text('8 hours'))),
        ],
      ),
    );
    if (d != null && _pos != null) widget.onShareLive(_pos!, d);
  }

  @override
  Widget build(BuildContext context) {
    final p = _pos;
    return Column(
      children: [
        Expanded(
          child: Container(
            width: double.infinity,
            color: Colors.grey.withOpacity(0.15),
            child: _loading
                ? const Center(child: CircularProgressIndicator())
                : _error != null
                    ? Center(
                        child: Column(mainAxisSize: MainAxisSize.min, children: [
                          const Icon(Icons.location_off, size: 48, color: Colors.grey),
                          Padding(padding: const EdgeInsets.all(12), child: Text(_error!, textAlign: TextAlign.center)),
                          TextButton(onPressed: _locate, child: const Text('Retry')),
                          TextButton(onPressed: () async => await Geolocator.openAppSettings(), child: const Text('Open settings')),
                        ]),
                      )
                    : FlutterMap(
                        options: MapOptions(initialCenter: LatLng(p!.latitude, p.longitude), initialZoom: 16),
                        children: [
                          TileLayer(urlTemplate: 'https://tile.openstreetmap.org/{z}/{x}/{y}.png', userAgentPackageName: 'com.lumachat.app'),
                          CircleLayer(circles: [
                            CircleMarker(
                              point: LatLng(p.latitude, p.longitude),
                              radius: math.max(p.accuracy, 3),
                              useRadiusInMeter: true,
                              color: Colors.blue.withOpacity(0.12),
                              borderColor: Colors.blue.withOpacity(0.4),
                              borderStrokeWidth: 1,
                            ),
                          ]),
                          MarkerLayer(markers: [Marker(point: LatLng(p.latitude, p.longitude), width: 40, height: 40, child: const Icon(Icons.location_on, color: Colors.red, size: 40))]),
                          const SimpleAttributionWidget(source: Text('OpenStreetMap contributors')),
                        ],
                      ),
          ),
        ),
        Container(
          padding: const EdgeInsets.fromLTRB(8, 8, 8, 110),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              ListTile(
                enabled: p != null,
                leading: const CircleAvatar(backgroundColor: _kAccent, child: Icon(Icons.location_on, color: Colors.white)),
                title: const Text('Send My Current Location', style: TextStyle(color: _kAccent, fontWeight: FontWeight.bold)),
                subtitle: Text(p == null ? 'Locating...' : 'Accurate to ${p.accuracy.round()} meters'),
                onTap: p == null ? null : () => widget.onSendCurrent(p),
              ),
              ListTile(
                enabled: p != null,
                leading: const CircleAvatar(backgroundColor: Colors.green, child: Icon(Icons.location_searching, color: Colors.white)),
                title: const Text('Share My Live Location for...', style: TextStyle(color: Colors.green, fontWeight: FontWeight.bold)),
                subtitle: const Text('Updated in real time as you move'),
                onTap: p == null ? null : _chooseDuration,
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _LocationViewerScreen extends StatefulWidget {
  final String chatId;
  final String msgId;
  final double lat;
  final double lng;
  final bool live;
  const _LocationViewerScreen({required this.chatId, required this.msgId, required this.lat, required this.lng, required this.live});

  @override
  State<_LocationViewerScreen> createState() => _LocationViewerScreenState();
}

class _LocationViewerScreenState extends State<_LocationViewerScreen> {
  final MapController _map = MapController();

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(widget.live ? 'Live location' : 'Location')),
      body: StreamBuilder<DocumentSnapshot<Map<String, dynamic>>>(
        stream: FirebaseFirestore.instance.collection('chats').doc(widget.chatId).collection('messages').doc(widget.msgId).snapshots(),
        builder: (context, snap) {
          final data = snap.data?.data();
          final lat = (data?['latitude'] as num?)?.toDouble() ?? widget.lat;
          final lng = (data?['longitude'] as num?)?.toDouble() ?? widget.lng;
          final pos = LatLng(lat, lng);
          WidgetsBinding.instance.addPostFrameCallback((_) {
            try {
              _map.move(pos, 16);
            } catch (_) {}
          });
          return FlutterMap(
            mapController: _map,
            options: MapOptions(initialCenter: pos, initialZoom: 16),
            children: [
              TileLayer(urlTemplate: 'https://tile.openstreetmap.org/{z}/{x}/{y}.png', userAgentPackageName: 'com.lumachat.app'),
              MarkerLayer(markers: [Marker(point: pos, width: 40, height: 40, child: const Icon(Icons.location_on, color: Colors.red, size: 40))]),
              const SimpleAttributionWidget(source: Text('OpenStreetMap contributors')),
            ],
          );
        },
      ),
    );
  }
}

// ═══════════════════════════════════════════════════════════════════════════
// GIPHY PANEL (stickers + GIFs)
// ═══════════════════════════════════════════════════════════════════════════
class _GiphyItem {
  final String preview;
  final String full;
  _GiphyItem(this.preview, this.full);
}

class _GiphyPanel extends StatefulWidget {
  final bool isSticker;
  final String apiKey;
  final void Function(String url) onSelected;
  const _GiphyPanel({super.key, required this.isSticker, required this.apiKey, required this.onSelected});

  @override
  State<_GiphyPanel> createState() => _GiphyPanelState();
}

class _GiphyPanelState extends State<_GiphyPanel> {
  final _ctrl = TextEditingController();
  Timer? _debounce;
  List<_GiphyItem> _items = [];
  bool _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _ctrl.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    if (widget.apiKey.isEmpty) {
      setState(() {
        _loading = false;
        _error = 'GIPHY API key is missing';
      });
      return;
    }
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final kind = widget.isSticker ? 'stickers' : 'gifs';
      final q = _ctrl.text.trim();
      final uri = q.isEmpty
          ? Uri.https('api.giphy.com', '/v1/$kind/trending', {'api_key': widget.apiKey, 'limit': '36'})
          : Uri.https('api.giphy.com', '/v1/$kind/search', {'api_key': widget.apiKey, 'q': q, 'limit': '36'});
      final res = await http.get(uri).timeout(const Duration(seconds: 10));
      if (res.statusCode != 200) throw Exception('GIPHY error ${res.statusCode}');
      final list = (jsonDecode(res.body)['data'] as List?) ?? [];
      final items = <_GiphyItem>[];
      for (final g in list) {
        final images = g['images'] as Map<String, dynamic>?;
        if (images == null) continue;
        final preview = images['fixed_width']?['url'] ?? images['fixed_height']?['url'];
        final full = images['fixed_height']?['url'] ?? images['original']?['url'];
        if (preview != null && full != null) items.add(_GiphyItem(preview.toString(), full.toString()));
      }
      if (!mounted) return;
      setState(() {
        _items = items;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = 'Could not load ${widget.isSticker ? 'stickers' : 'GIFs'}';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final label = widget.isSticker ? 'Stickers' : 'GIFs';
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 10, 12, 4),
          child: TextField(
            controller: _ctrl,
            onChanged: (_) {
              _debounce?.cancel();
              _debounce = Timer(const Duration(milliseconds: 450), _load);
            },
            decoration: InputDecoration(
              hintText: 'Search $label',
              prefixIcon: const Icon(Icons.search),
              isDense: true,
              filled: true,
              fillColor: Colors.grey.withOpacity(0.15),
              border: OutlineInputBorder(borderRadius: BorderRadius.circular(24), borderSide: BorderSide.none),
            ),
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 4, 16, 4),
          child: Row(children: [
            Text(_ctrl.text.trim().isEmpty ? 'Trending $label' : 'Results',
                style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: theme.colorScheme.onSurface.withOpacity(0.6))),
            const Spacer(),
            Text('Powered by GIPHY', style: TextStyle(fontSize: 10, color: theme.colorScheme.onSurface.withOpacity(0.4))),
          ]),
        ),
        Expanded(
          child: _loading
              ? const Center(child: CircularProgressIndicator())
              : _error != null
                  ? Center(child: Column(mainAxisSize: MainAxisSize.min, children: [Text(_error!), TextButton(onPressed: _load, child: const Text('Retry'))]))
                  : _items.isEmpty
                      ? Center(child: Text('Nothing found', style: TextStyle(color: theme.colorScheme.onSurface.withOpacity(0.6))))
                      : GridView.builder(
                          padding: const EdgeInsets.fromLTRB(8, 4, 8, 8),
                          gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(crossAxisCount: 3, crossAxisSpacing: 6, mainAxisSpacing: 6),
                          itemCount: _items.length,
                          itemBuilder: (context, i) {
                            final it = _items[i];
                            return GestureDetector(
                              onTap: () => widget.onSelected(it.full),
                              child: ClipRRect(
                                borderRadius: BorderRadius.circular(8),
                                child: CachedNetworkImage(
                                  imageUrl: it.preview,
                                  fit: widget.isSticker ? BoxFit.contain : BoxFit.cover,
                                  placeholder: (_, __) => Container(color: Colors.grey.withOpacity(0.2)),
                                  errorWidget: (_, __, ___) => Container(color: Colors.grey.withOpacity(0.2), child: const Icon(Icons.broken_image, color: Colors.grey)),
                                ),
                              ),
                            );
                          },
                        ),
        ),
      ],
    );
  }
}

