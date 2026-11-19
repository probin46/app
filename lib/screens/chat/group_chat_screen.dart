// ignore_for_file: deprecated_member_use
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;

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
import '../../services/api_config.dart';
import '../../services/cloudinary_service.dart';

// ═══════════════════════════════════════════════════════════════════════════
// CONFIG
// ═══════════════════════════════════════════════════════════════════════════
const String _kGiphyApiKey = '7tXB3cisPGymcszQX85JFOY6kp3Gz47T';
const String _kGeminiModel = 'gemini-2.0-flash';

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

class LocalRecorder {
  static const _channel = MethodChannel('com.lumachat.app/recorder');
  Future<void> start(String path) async => await _channel.invokeMethod('start', {'path': path});
  Future<String?> stop() async => await _channel.invokeMethod<String>('stop');
  Future<void> cancel() async {
    try {
      await _channel.invokeMethod('cancel');
    } catch (_) {}
  }

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


PART 2 — State Fields, Lifecycle & Firestore Listeners
// ═══════════════════════════════════════════════════════════════════════════
// SCREEN
// ═══════════════════════════════════════════════════════════════════════════
class GroupChatScreen extends StatefulWidget {
  final String chatId;
  final String chatName;
  final String? chatAvatar;

  const GroupChatScreen({super.key, required this.chatId, required this.chatName, this.chatAvatar});

  @override
  State<GroupChatScreen> createState() => _GroupChatScreenState();
}

class _GroupChatScreenState extends State<GroupChatScreen> with WidgetsBindingObserver {
  final _messageController = TextEditingController();
  final _messageFocus = FocusNode();
  final _scrollController = ScrollController();
  final _picker = ImagePicker();
  final _audioPlayer = AudioPlayer();
  final LocalRecorder _audioRecorder = LocalRecorder();

  String? _currentUserId;
  bool _isMePremium = false;
  bool _appResumed = true;
  String? _wallpaper;

  String? _activePanel; // 'emoji' | 'gif' | 'sticker'
  bool _hasText = false;
  bool _hasSelection = false;
  bool _atBottom = true;
  bool _showFab = false;

  Map<String, dynamic>? _chatData;
  List<Map<String, dynamic>> _live = [];
  List<Map<String, dynamic>> _older = [];
  List<Map<String, dynamic>> _visible = [];
  List<Map<String, dynamic>> _pins = [];
  int _pinIndex = 0;
  bool _messagesLoaded = false;
  bool _loadingOlder = false;
  bool _noMoreOlder = false;
  bool _firstSnapshotDone = false;

  int _unreadCount = 0;
  String? _firstUnreadId;
  String? _dividerAnchorId;
  int _dividerCount = 0;
  final Set<String> _deliveredTried = {};
  final Set<String> _readTried = {};

  StreamSubscription? _messageSub;
  StreamSubscription? _chatSub;
  StreamSubscription? _typingSub;
  StreamSubscription? _premiumSub;
  StreamSubscription? _pinSub;
  final List<StreamSubscription> _memberSubs = [];
  Timer? _loadingFallback;
  Timer? _ticker;
  Timer? _flashTimer;
  Timer? _typingTimer;

  String? _replyingTo;
  String? _editingId;
  bool _multiSelectMode = false;
  final Set<String> _selectedIds = {};
  String? _highlightId;
  final Map<String, GlobalKey> _msgKeys = {};

  final Map<String, Map<String, dynamic>> _userCache = {};
  final Map<String, DateTime> _typingUsers = {};
  DateTime? _lastTypingWrite;
  String _membersKey = '';
  final Map<int, int> _onlineByChunk = {};
  int get _onlineCount => _onlineByChunk.values.fold(0, (a, b) => a + b);

  List<String> _mentionResults = [];
  DateTime? _lastSendAt;
  int _lastSlow = 0;
  int _lastTypingCount = 0;

  bool _isRecording = false;
  bool _recStarting = false;
  bool _recFinishEarly = false;
  bool _recCancel = false;
  int _recSeconds = 0;
  DateTime? _recStart;
  Timer? _ampTimer;
  bool _ampSupported = true;
  final List<double> _ampSamples = [];

  String? _loadedAudioId;

  // Downloads & inline image progress tracking (Item 11)
  final Map<String, String> _localCache = {};
  final Map<String, double?> _downloadProgress = {};

  int _selectedBottomTab = 0;
  final List<AssetEntity> _selectedAssets = [];
  Future<List<AssetEntity>>? _assetsFuture;
  Future<List<AssetEntity>>? _audioFuture;
  Future<List<_LumaContact>>? _contactsFuture;
  final _contactSearch = TextEditingController();
  final _musicSearch = TextEditingController();

  StreamSubscription<Position>? _liveSub;
  Timer? _liveTimer;
  String? _liveMsgId;
  DateTime? _liveUntil;

  DocumentReference<Map<String, dynamic>> get _chatRef =>
      FirebaseFirestore.instance.collection('chats').doc(widget.chatId);
  CollectionReference<Map<String, dynamic>> get _msgs => _chatRef.collection('messages');
  DocumentReference<Map<String, dynamic>> _msgDoc(String id) => _msgs.doc(id);
  CollectionReference<Map<String, dynamic>> get _pinsRef => _chatRef.collection('pinned_messages');
  DocumentReference<Map<String, dynamic>> get _typingDoc => _chatRef.collection('typing').doc(_currentUserId);

  String get _myRole => (_chatData?['participants_data']?[_currentUserId]?['role'] ?? 'member').toString();
  bool get _isAdmin => _myRole == 'admin' || _myRole == 'owner';
  bool get _isMember {
    final p = _chatData?['participants'];
    if (p is List) return p.map((e) => e.toString()).contains(_currentUserId);
    return true;
  }

  bool get _isMuted {
    final pd = _chatData?['participants_data']?[_currentUserId];
    if (pd is Map) {
      if (pd['is_muted'] == true) return true;
      final mu = pd['muted_until'];
      if (mu is Timestamp && mu.toDate().isAfter(DateTime.now())) return true;
    }
    return false;
  }

  int get _slowSeconds => (_chatData?['slow_mode_seconds'] as num?)?.toInt() ?? 0;
  bool get _locked => _chatData?['is_locked'] == true;
  bool get _canPin => _isAdmin || _chatData?['members_can_pin'] == true;
  bool get _canForward => _isAdmin || _chatData?['restrict_forwarding'] != true;
  String _roleOf(String uid) => (_chatData?['participants_data']?[uid]?['role'] ?? 'member').toString();

  List<String> _memberIds() {
    final p = _chatData?['participants'];
    if (p is List) return p.map((e) => e.toString()).toList();
    return [];
  }

  String _nameOf(String? uid) => (_userCache[uid]?[_kUserNameField] ?? 'Member').toString();
  String? _avatarOf(String? uid) {
    final a = _userCache[uid]?[_kUserAvatarField];
    return (a is String && a.isNotEmpty) ? a : null;
  }

  String _groupName() {
    final n = _chatData?['name'];
    if (n is String && n.trim().isNotEmpty) return n;
    return widget.chatName;
  }

  String? _groupAvatar() {
    for (final v in [_chatData?['avatar_url'], _chatData?['photo_url'], _chatData?['group_avatar'], widget.chatAvatar]) {
      if (v is String && v.isNotEmpty) return v;
    }
    return null;
  }

  String? _hardBlockReason() {
    if (_currentUserId == null) return 'Sign in to send messages';
    if (!_isMember) return 'You are no longer a member of this group';
    if (_isMuted) return 'You have been muted by an admin';
    if (_locked && !_isAdmin) return 'Only admins can send messages';
    return null;
  }

  int get _slowRemaining {
    final s = _slowSeconds;
    if (s <= 0 || _isAdmin) return 0;
    DateTime? last = _lastSendAt;
    for (final m in _visible) {
      if (m['sender_id'] == _currentUserId) {
        final ts = m['created_at'];
        if (ts is Timestamp) {
          final d = ts.toDate();
          if (last == null || d.isAfter(last)) last = d;
        }
        break;
      }
    }
    if (last == null) return 0;
    final rem = s - DateTime.now().difference(last).inSeconds;
    return rem > 0 ? rem : 0;
  }

  String? _blockReason() {
    final h = _hardBlockReason();
    if (h != null) return h;
    final r = _slowRemaining;
    if (r > 0) return 'Slow mode is on. Wait ${r}s';
    return null;
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _messageController.addListener(_onComposerChanged);
    _scrollController.addListener(_onScroll);
    _loadingFallback = Timer(const Duration(seconds: 5), () {
      if (mounted && !_messagesLoaded) setState(() => _messagesLoaded = true);
    });
    _ticker = Timer.periodic(const Duration(seconds: 1), (_) => _onTick());
    _init();
  }

  void _init() {
    final auth = Provider.of<LumaAuthProvider>(context, listen: false);
    _currentUserId = auth.user?.uid ?? auth.mockUserId;
    if (_currentUserId == null) {
      setState(() => _messagesLoaded = true);
      return;
    }
    _listenToChat();
    _listenToMessages();
    _listenToPins();
    _listenToPremium();
    _listenToTyping();
    _loadWallpaper();
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
    _messageSub?.cancel();
    _chatSub?.cancel();
    _typingSub?.cancel();
    _premiumSub?.cancel();
    _pinSub?.cancel();
    for (final s in _memberSubs) {
      s.cancel();
    }
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
    final r = _slowRemaining;
    if (r != _lastSlow) {
      _lastSlow = r;
      changed = true;
    }
    final tc = _typingNames().length;
    if (tc != _lastTypingCount) {
      _lastTypingCount = tc;
      changed = true;
    }
    if (_isRecording && _recStart != null) {
      final s = DateTime.now().difference(_recStart!).inSeconds;
      if (s != _recSeconds) {
        _recSeconds = s;
        changed = true;
      }
    }
    if (changed) setState(() {});
  }

  void _listenToChat() {
    _chatSub = _chatRef.snapshots().listen((doc) {
      if (!mounted) return;
      setState(() {
        if (doc.exists) _chatData = doc.data();
      });
      if (doc.exists) {
        final parts = _chatData?['participants'];
        if (parts is List) _listenToMembers(parts.map((e) => e.toString()).toList());
      }
    }, onError: (_) {});
  }

  void _listenToMembers(List<String> ids) {
    final key = ids.join(',');
    if (key == _membersKey) return;
    _membersKey = key;
    for (final s in _memberSubs) {
      s.cancel();
    }
    _memberSubs.clear();
    _onlineByChunk.clear();
    for (var i = 0; i < ids.length; i += 10) {
      final chunk = ids.sublist(i, math.min(i + 10, ids.length));
      final idx = i;
      _memberSubs.add(FirebaseFirestore.instance
          .collection('users')
          .where(FieldPath.documentId, whereIn: chunk)
          .snapshots()
          .listen((snap) {
        if (!mounted) return;
        setState(() {
          for (final d in snap.docs) {
            _userCache[d.id] = d.data();
          }
          _onlineByChunk[idx] = snap.docs.where((d) => d.data()[_kUserOnlineField] == true).length;
        });
      }, onError: (_) {}));
    }
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

      for (final m in loaded) {
        final sid = m['sender_id']?.toString();
        if (sid != null && !_userCache.containsKey(sid)) _fetchUser(sid);
      }

      setState(() {
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
    }, onError: (_) {
      if (mounted) setState(() => _messagesLoaded = true);
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
      setState(() {
        _typingUsers.clear();
        for (final doc in snap.docs) {
          if (doc.id == _currentUserId) continue;
          final data = doc.data();
          if (data['is_typing'] != true) continue;
          final at = data['at'];
          _typingUsers[doc.id] = at is Timestamp ? at.toDate() : DateTime.now();
        }
      });
    }, onError: (_) {});
  }

  void _listenToPremium() {
    _premiumSub = FirebaseFirestore.instance.collection('users').doc(_currentUserId).snapshots().listen((doc) {
      if (mounted && doc.exists) setState(() => _isMePremium = doc.data()?['is_premium'] == true);
    }, onError: (_) {});
  }

  Future<void> _fetchUser(String uid) async {
    _userCache[uid] = {_kUserNameField: 'Member', _kUserAvatarField: null};
    try {
      final doc = await FirebaseFirestore.instance.collection('users').doc(uid).get();
      final data = doc.data();
      if (doc.exists && data != null && mounted) setState(() => _userCache[uid] = data);
    } catch (_) {}
  }

  Future<void> _loadWallpaper() async {
    try {
      final doc = await FirebaseFirestore.instance.collection('user_settings').doc(_currentUserId).get();
      if (doc.exists && mounted) {
        final walls = doc.data()?['chat_wallpapers'];
        if (walls is Map) {
          final v = walls[widget.chatId];
          if (v is String && v.isNotEmpty) setState(() => _wallpaper = v);
        }
      }
    } catch (_) {}
  }

  List<String> _typingNames() {
    final now = DateTime.now();
    return _typingUsers.entries
        .where((e) => now.difference(e.value).inSeconds < 20)
        .map((e) => _nameOf(e.key))
        .toList();
  }


PART 3 — Receipts, Pagination, Composer & Message Actions
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
    for (final m in [..._live, ..._older]) {
      final id = m['id']?.toString();
      if (id == null || !seen.add(id)) continue;
      if (m['deleted_for_everyone'] == true) continue;
      final df = m['deleted_for'];
      if (df is List && df.contains(me)) continue;
      out.add(m);
    }
    _visible = out;

    var c = 0;
    String? first;
    for (final m in _live) {
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
    if (me == null || !_appResumed) return;
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
    if (_loadingOlder || _noMoreOlder || _currentUserId == null) return false;
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
      for (final m in more) {
        final sid = m['sender_id']?.toString();
        if (sid != null && !_userCache.containsKey(sid)) _fetchUser(sid);
      }
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

  void _onComposerChanged() {
    final text = _messageController.text;
    final sel = _messageController.selection;
    final has = text.trim().isNotEmpty;
    final hasSel = sel.isValid && !sel.isCollapsed;

    var results = <String>[];
    if (sel.isValid && sel.isCollapsed && sel.baseOffset <= text.length && sel.baseOffset >= 0) {
      final before = text.substring(0, sel.baseOffset);
      final mt = RegExp(r'(?:^|\s)@([^\s@]{0,30})$').firstMatch(before);
      if (mt != null) {
        final q = (mt.group(1) ?? '').toLowerCase();
        results = _memberIds().where((uid) {
          if (uid == _currentUserId) return false;
          final n = _nameOf(uid).toLowerCase();
          return n != 'member' && (q.isEmpty || n.contains(q));
        }).take(6).toList();
      }
    }

    final sameMentions = results.length == _mentionResults.length &&
        results.asMap().entries.every((e) => _mentionResults[e.key] == e.value);
    if (has != _hasText || hasSel != _hasSelection || !sameMentions) {
      setState(() {
        _hasText = has;
        _hasSelection = hasSel;
        _mentionResults = results;
      });
    }
  }

  void _insertMention(String uid) {
    final name = _nameOf(uid);
    final text = _messageController.text;
    final sel = _messageController.selection;
    if (!sel.isValid) return;
    final before = text.substring(0, sel.baseOffset);
    final after = text.substring(sel.baseOffset);
    final m = RegExp(r'@([^\s@]{0,30})$').firstMatch(before);
    if (m == null) return;
    final newBefore = '${before.substring(0, m.start)}@$name ';
    _messageController.value = TextEditingValue(
      text: newBefore + after,
      selection: TextSelection.collapsed(offset: newBefore.length),
    );
  }

  void _insertMentionAtEnd(String uid) {
    final name = _nameOf(uid);
    final t = _messageController.text;
    final sep = (t.isEmpty || t.endsWith(' ')) ? '' : ' ';
    final nt = '$t$sep@$name ';
    _messageController.value = TextEditingValue(text: nt, selection: TextSelection.collapsed(offset: nt.length));
    _messageFocus.requestFocus();
  }

  Map<String, String> _collectMentions(String text) {
    final out = <String, String>{};
    for (final uid in _memberIds()) {
      if (uid == _currentUserId) continue;
      final n = _nameOf(uid);
      if (n.isEmpty || n == 'Member') continue;
      final re = RegExp('@${RegExp.escape(n)}(?=\\s|\$|[.,!?;:])');
      if (re.hasMatch(text)) out[uid] = n;
    }
    return out;
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
    final now = DateTime.now();
    if (_lastTypingWrite == null || now.difference(_lastTypingWrite!).inSeconds >= 3) {
      _lastTypingWrite = now;
      if (_currentUserId != null) {
        _typingDoc.set({'is_typing': true, 'at': FieldValue.serverTimestamp()}).catchError((_) {});
      }
    }
    _typingTimer?.cancel();
    _typingTimer = Timer(const Duration(seconds: 4), _stopTyping);
  }

  void _stopTyping() {
    _typingTimer?.cancel();
    if (_lastTypingWrite != null && _currentUserId != null) {
      _lastTypingWrite = null;
      _typingDoc.delete().catchError((_) {});
    }
  }

  Future<String?> _postMessage(Map<String, dynamic> data, {bool system = false}) async {
    final me = _currentUserId;
    if (me == null) return null;
    if (!system) {
      final reason = _blockReason();
      if (reason != null) {
        _showSnack(reason);
        return null;
      }
      _lastSendAt = DateTime.now();
    }
    final msgId = const Uuid().v4();
    final payload = <String, dynamic>{
      'id': msgId,
      'sender_id': me,
      'created_at': FieldValue.serverTimestamp(),
      'is_read': false,
      'read_by': [me],
      'delivered_to': [me],
      ...data,
    };
    _msgs.doc(msgId).set(payload).catchError((e) {
      _showSnack('Send failed: $e');
    });
    if (!_atBottom) {
      Future.delayed(const Duration(milliseconds: 200), _scrollToBottom);
    }
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
    final mentions = _collectMentions(text);
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
      if (mentions.isNotEmpty) 'mentions': mentions.keys.toList(),
      if (mentions.isNotEmpty) 'mention_names': mentions.values.toList(),
    });
  }

  Future<void> _commitEdit(String text) async {
    final id = _editingId;
    if (id == null) return;
    final mentions = _collectMentions(text);
    _messageController.clear();
    setState(() => _editingId = null);
    try {
      await _msgDoc(id).update({
        'text': text,
        'edited': true,
        'edited_at': FieldValue.serverTimestamp(),
        'mentions': mentions.keys.toList(),
        'mention_names': mentions.values.toList(),
      });
      _syncOlder(id);
    } catch (e) {
      _showSnack('Edit failed: $e');
    }
  }

  Future<void> _sendSticker(String url, {String? packId, String? packTitle}) async {
    final id = await _postMessage({
      'type': 'sticker',
      'media_type': 'sticker',
      'media_url': url,
      if (packId != null) 'pack_id': packId,
      if (packTitle != null) 'pack_title': packTitle,
    });
    if (id != null && mounted) setState(() => _activePanel = null);
  }

  Future<void> _sendGif(String url) async {
    final id = await _postMessage({'type': 'gif', 'media_type': 'gif', 'media_url': url});
    if (id != null && mounted) setState(() => _activePanel = null);
  }


PART 4 — Compact Message Bubbles, Full-Width Reply Quotes, Voice Waves & Blurred Image Download
// ─── Bubble Rendering (Items 1, 2, 4, 5, 6, 9, 10, 11, 12) ───
  Widget _buildMessageRow(
    Map<String, dynamic> m,
    Map<String, dynamic>? older,
    Map<String, dynamic>? newer,
    bool showDate,
    bool showDivider,
    ThemeData theme,
    bool isDark,
  ) {
    if (m['type'] == 'system') return _systemRow(m, theme, isDark);

    final id = m['id'].toString();
    final senderId = m['sender_id']?.toString();
    final isMe = senderId == _currentUserId;
    final type = (m['type'] ?? m['media_type'] ?? 'text').toString();
    final isMediaType = const ['image', 'video', 'sticker', 'gif'].contains(type);
    final isSticker = type == 'sticker';

    final newerSame = newer != null &&
        newer['type'] != 'system' &&
        newer['sender_id'] == m['sender_id'] &&
        _sameDay(_msgTime(m), _msgTime(newer)) &&
        newer['id'] != _dividerAnchorId;
    final olderSame = older != null &&
        older['type'] != 'system' &&
        older['sender_id'] == m['sender_id'] &&
        !showDate &&
        !showDivider;
    final showName = !isMe && !olderSame;
    final showAvatar = !isMe && !newerSame;
    final lastInGroup = !newerSame;
    final selected = _selectedIds.contains(id);

    final baseColor = isSticker
        ? Colors.transparent
        : (isMe
            ? (isDark ? const Color(0xFF005C4B) : const Color(0xFFEFFDDE))
            : (isDark ? const Color(0xFF1F2C34) : Colors.white));
    var bubbleColor = baseColor;
    if (selected) bubbleColor = Color.alphaBlend(_kAccent.withOpacity(0.3), baseColor);
    if (_highlightId == id) bubbleColor = Color.alphaBlend(_kAccent.withOpacity(0.35), baseColor);

    // Item 1 & 12: Compact Telegram bubble proportions & portrait media cap
    final maxW = math.min(
      MediaQuery.of(context).size.width * 0.72,
      isMediaType ? 232.0 : 302.0,
    );
    final nameColor = _colorForUid(senderId);
    final role = senderId != null ? _roleOf(senderId) : 'member';
    final metaColor = theme.colorScheme.onSurface.withOpacity(0.5);

    final reactions = m['reactions'];
    final hasReactions = reactions is Map && reactions.values.any((v) => v is List && v.isNotEmpty);

    final bubble = AnimatedContainer(
      duration: const Duration(milliseconds: 250),
      constraints: BoxConstraints(maxWidth: maxW),
      padding: isSticker ? const EdgeInsets.all(2) : const EdgeInsets.fromLTRB(9, 6, 9, 5),
      decoration: BoxDecoration(
        color: bubbleColor,
        borderRadius: BorderRadius.only(
          topLeft: const Radius.circular(16),
          topRight: const Radius.circular(16),
          bottomLeft: Radius.circular((!isMe && lastInGroup) ? 4 : 16),
          bottomRight: Radius.circular((isMe && lastInGroup) ? 4 : 16),
        ),
        boxShadow: isSticker
            ? null
            : [BoxShadow(color: Colors.black.withOpacity(0.06), blurRadius: 2, offset: const Offset(0, 1))],
      ),
      child: IntrinsicWidth(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: [
            if (showName && senderId != null)
              GestureDetector(
                onTap: () => _showMemberProfileModal(senderId),
                child: Padding(
                  padding: const EdgeInsets.only(bottom: 3),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Flexible(
                        child: Text(
                          _nameOf(senderId),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(fontSize: 13, fontWeight: FontWeight.w700, color: nameColor),
                        ),
                      ),
                      if (role == 'owner' || role == 'admin') ...[
                        const SizedBox(width: 6),
                        Container(
                          padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
                          decoration: BoxDecoration(
                            color: (role == 'owner' ? const Color(0xFFE5B35C) : _kAccent).withOpacity(0.18),
                            borderRadius: BorderRadius.circular(6),
                          ),
                          child: Text(
                            role == 'owner' ? 'owner' : 'admin',
                            style: TextStyle(
                              fontSize: 10,
                              fontWeight: FontWeight.w700,
                              color: role == 'owner' ? const Color(0xFFB8860B) : _kAccent,
                            ),
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
              ),
            if (m['forwarded_from'] != null)
              Padding(
                padding: const EdgeInsets.only(bottom: 4),
                child: Text(
                  'Forwarded from ${m['forwarded_from']}',
                  style: const TextStyle(fontSize: 12, fontStyle: FontStyle.italic, color: _kAccent, fontWeight: FontWeight.w600),
                ),
              ),
            // Item 2: Full-width Telegram reply quote across the entire top of the bubble
            if (m['reply_to'] != null) _quotedReply(m, isMe: isMe, isDark: isDark),
            ..._contentWidgets(m, isMe, theme, isDark),
            const SizedBox(height: 2),
            Align(
              alignment: Alignment.centerRight,
              child: Container(
                padding: isSticker ? const EdgeInsets.symmetric(horizontal: 6, vertical: 2) : EdgeInsets.zero,
                decoration: isSticker
                    ? BoxDecoration(color: Colors.black45, borderRadius: BorderRadius.circular(10))
                    : null,
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (m['edited'] == true)
                      Padding(
                        padding: const EdgeInsets.only(right: 4),
                        child: Text('edited', style: TextStyle(fontSize: 10, fontStyle: FontStyle.italic, color: isSticker ? Colors.white : metaColor)),
                      ),
                    Text(
                      DateFormat('HH:mm').format(_msgTime(m)),
                      style: TextStyle(fontSize: 10, color: isSticker ? Colors.white : metaColor),
                    ),
                    if (isMe) ...[const SizedBox(width: 3), _tickIcon(m, isSticker ? Colors.white : metaColor)],
                  ],
                ),
              ),
            ),
            if (hasReactions) _reactionsRow(m),
          ],
        ),
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
        if (!isMe)
          SizedBox(
            width: 32,
            child: (showAvatar && senderId != null)
                ? GestureDetector(
                    onTap: () => _showMemberProfileModal(senderId),
                    child: CircleAvatar(
                      radius: 16,
                      backgroundColor: nameColor.withOpacity(0.25),
                      backgroundImage: _avatarOf(senderId) != null ? CachedNetworkImageProvider(_avatarOf(senderId)!) : null,
                      child: _avatarOf(senderId) == null
                          ? Text(_nameOf(senderId).isNotEmpty ? _nameOf(senderId)[0].toUpperCase() : '?',
                              style: TextStyle(color: nameColor, fontWeight: FontWeight.bold, fontSize: 13))
                          : null,
                    ),
                  )
                : null,
          ),
        if (!isMe) const SizedBox(width: 6),
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

  Widget _quotedReply(Map<String, dynamic> m, {required bool isMe, required bool isDark}) {
    final rid = m['reply_to']?.toString();
    final orig = _findMessage(rid);
    final name = (m['reply_to_sender'] ?? (orig != null ? _nameOf(orig['sender_id']?.toString()) : 'Message')).toString();
    final preview = orig != null
        ? _stripFormatting(_previewOf(orig))
        : _stripFormatting((m['reply_to_content'] ?? 'Message').toString());
    final color = orig != null ? _colorForUid(orig['sender_id']?.toString()) : _kAccent;
    final fill = isMe
        ? (isDark ? Colors.white.withOpacity(0.08) : const Color(0xFF4FAE4E).withOpacity(0.14))
        : color.withOpacity(0.12);

    return GestureDetector(
      onTap: () => _jumpToMessage(rid),
      child: Container(
        width: double.infinity,
        margin: const EdgeInsets.only(bottom: 6),
        padding: const EdgeInsets.fromLTRB(9, 5, 10, 5),
        decoration: BoxDecoration(
          color: fill,
          border: Border(left: BorderSide(color: color, width: 3.5)),
          borderRadius: BorderRadius.circular(8),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(name, maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(color: color, fontSize: 12.5, fontWeight: FontWeight.w700)),
            Text(preview, maxLines: 2, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 12.5)),
          ],
        ),
      ),
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
        if (url != null) out.add(_videoBubble(m, url));
        break;
      case 'audio':
        if (url != null) out.add(_buildAudioBubble(m, isMe, theme));
        break;
      case 'sticker':
        if (url != null) {
          out.add(GestureDetector(
            onTap: () => _showStickerPackModal(m),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(8),
              child: CachedNetworkImage(imageUrl: url, width: 120, height: 120, fit: BoxFit.contain),
            ),
          ));
        }
        break;
      case 'gif':
        if (url != null) {
          out.add(ClipRRect(
            borderRadius: BorderRadius.circular(10),
            child: ConstrainedBox(
              constraints: const BoxConstraints(minWidth: 140, maxWidth: 214, minHeight: 155, maxHeight: 275),
              child: CachedNetworkImage(imageUrl: url, fit: BoxFit.cover),
            ),
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
      final names = (m['mention_names'] is List) ? (m['mention_names'] as List).map((e) => e.toString()).toList() : <String>[];
      out.add(Padding(
        padding: EdgeInsets.only(top: out.isEmpty ? 0 : 4),
        child: _RichMessageText(
          text: text,
          style: TextStyle(color: textColor, fontSize: 15, height: 1.25),
          mentionNames: names,
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

  // Item 11 & 9: Blurred pre-download image with circular progress ring -> Telegram Image Viewer
  Future<void> _downloadImageInline(String url) async {
    if (_downloadProgress.containsKey(url)) return;
    setState(() => _downloadProgress[url] = null);
    final client = http.Client();
    try {
      final dir = await getApplicationDocumentsDirectory();
      final folder = Directory('${dir.path}/luma_downloads');
      if (!folder.existsSync()) folder.createSync(recursive: true);
      final path = '${folder.path}/${url.hashCode.abs()}_img.jpg';
      final f = File(path);

      final res = await client.send(http.Request('GET', Uri.parse(url))).timeout(const Duration(seconds: 30));
      if (res.statusCode != 200) throw Exception('HTTP ${res.statusCode}');
      final total = res.contentLength ?? 0;
      final sink = f.openWrite();
      var got = 0;
      await for (final chunk in res.stream) {
        sink.add(chunk);
        got += chunk.length;
        if (total > 0 && mounted) {
          setState(() => _downloadProgress[url] = (got / total).clamp(0.0, 1.0));
        }
      }
      await sink.close();
      if (mounted) {
        setState(() {
          _localCache[url] = path;
          _downloadProgress.remove(url);
        });
      }
    } catch (_) {
      if (mounted) {
        setState(() => _downloadProgress.remove(url));
        _showSnack('Download failed');
      }
    } finally {
      client.close();
    }
  }

  Widget _imageBubble(Map<String, dynamic> m, String url) {
    final cachedPath = _localCache[url];
    final isDownloaded = cachedPath != null && File(cachedPath).existsSync();
    final isDownloading = _downloadProgress.containsKey(url);
    final progress = _downloadProgress[url];

    return GestureDetector(
      onTap: () {
        if (isDownloaded) {
          Navigator.push(
            context,
            MaterialPageRoute(
              builder: (_) => _ImageViewerScreen(
                imagePath: cachedPath,
                senderName: _nameOf(m['sender_id']?.toString()),
                timestamp: DateFormat('dd MMM, HH:mm').format(_msgTime(m)),
                caption: (m['text'] ?? '').toString(),
                onForward: _canForward ? () => _forwardMessages([m]) : null,
              ),
            ),
          );
        } else if (!isDownloading) {
          _downloadImageInline(url);
        }
      },
      child: ClipRRect(
        borderRadius: BorderRadius.circular(10),
        child: ConstrainedBox(
          constraints: const BoxConstraints(minWidth: 145, maxWidth: 214, minHeight: 165, maxHeight: 285),
          child: Stack(
            alignment: Alignment.center,
            children: [
              ImageFiltered(
                imageFilter: ui.ImageFilter.blur(
                  sigmaX: isDownloaded ? 0 : 15,
                  sigmaY: isDownloaded ? 0 : 15,
                ),
                child: isDownloaded
                    ? Image.file(File(cachedPath), fit: BoxFit.cover)
                    : CachedNetworkImage(
                        imageUrl: url,
                        fit: BoxFit.cover,
                        placeholder: (_, __) => Container(width: 195, height: 220, color: Colors.black26),
                        errorWidget: (_, __, ___) => Container(
                          width: 195,
                          height: 160,
                          color: Colors.black12,
                          child: const Icon(Icons.broken_image, color: Colors.grey),
                        ),
                      ),
              ),
              if (!isDownloaded)
                SizedBox(
                  width: 54,
                  height: 54,
                  child: Stack(
                    alignment: Alignment.center,
                    children: [
                      Container(
                        width: 46,
                        height: 46,
                        decoration: BoxDecoration(color: Colors.black.withOpacity(0.55), shape: BoxShape.circle),
                        child: Icon(
                          isDownloading ? Icons.downloading : Icons.arrow_downward_rounded,
                          color: Colors.white,
                          size: 24,
                        ),
                      ),
                      if (isDownloading)
                        SizedBox(
                          width: 54,
                          height: 54,
                          child: CircularProgressIndicator(
                            value: progress,
                            strokeWidth: 3,
                            color: Colors.white,
                            backgroundColor: Colors.white24,
                          ),
                        ),
                    ],
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }

  // Item 10 & 12: Portrait video bubble opening Telegram Video Viewer
  Widget _videoBubble(Map<String, dynamic> m, String url) {
    return GestureDetector(
      onTap: () => Navigator.push(
        context,
        MaterialPageRoute(
          builder: (_) => _VideoViewerScreen(
            url: url,
            senderName: _nameOf(m['sender_id']?.toString()),
            timestamp: DateFormat('dd MMM, HH:mm').format(_msgTime(m)),
            caption: (m['text'] ?? '').toString(),
            onDownload: () => _openMedia(m),
            onForward: _canForward ? () => _forwardMessages([m]) : null,
          ),
        ),
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(10),
        child: Container(
          width: 214,
          height: 260,
          color: Colors.black87,
          alignment: Alignment.center,
          child: Stack(
            alignment: Alignment.center,
            children: [
              const Icon(Icons.movie_outlined, size: 64, color: Colors.white24),
              Container(
                padding: const EdgeInsets.all(14),
                decoration: const BoxDecoration(color: Colors.black54, shape: BoxShape.circle),
                child: const Icon(Icons.play_arrow_rounded, color: Colors.white, size: 36),
              ),
              Positioned(
                left: 8,
                top: 8,
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
                  decoration: BoxDecoration(color: Colors.black54, borderRadius: BorderRadius.circular(8)),
                  child: const Text('VIDEO', style: TextStyle(color: Colors.white, fontSize: 10, fontWeight: FontWeight.w700)),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  // Item 6: Voice message waves (always rendered, never bald)
  List<double> _normalizedVoiceBars(Map<String, dynamic> m) {
    final raw = m['waveform'];
    if (raw is List && raw.isNotEmpty) {
      final parsed = raw.map((e) => _c01((e is num ? e.toDouble() : 0.0) / 31.0)).toList();
      final avg = parsed.reduce((a, b) => a + b) / parsed.length;
      if (avg > 0.04) return parsed;
    }
    final seed = m['id'].toString().codeUnits.fold<int>(17, (a, b) => (a * 37 + b) & 0x7fffffff);
    final rng = math.Random(seed);
    return List.generate(42, (i) {
      final envelope = 0.35 + 0.65 * math.sin((i / 41.0) * math.pi);
      final syllable = 0.42 + 0.58 * rng.nextDouble();
      return _c01(envelope * syllable);
    });
  }

  Widget _buildAudioBubble(Map<String, dynamic> m, bool isMe, ThemeData theme) {
    final id = m['id'].toString();
    final isVoice = m['file_name'] == null;
    final wf = _normalizedVoiceBars(m);
    final total = Duration(seconds: (m['duration'] as num?)?.toInt() ?? 0);
    final loaded = _loadedAudioId == id;
    final inactive = theme.colorScheme.onSurface.withOpacity(0.28);

    Widget body(bool playing, Duration pos, Duration dur) {
      final d = dur > Duration.zero ? dur : total;
      final prog = d.inMilliseconds > 0 ? _c01(pos.inMilliseconds / d.inMilliseconds) : 0.0;
      return Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          GestureDetector(
            onTap: () => _togglePlay(m),
            child: Container(
              width: 40,
              height: 40,
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
                  width: 145,
                  child: Text(m['file_name'].toString(), maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
                ),
              GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTapDown: (det) => _seekAudio(m, det.localPosition.dx / 145, d),
                child: SizedBox(
                  width: 145,
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


PART 5 — Member Profile Modal, Group Info Settings Modal, Wallpaper Gallery & Sticker Pack Modal
// ─── Item 5: Member Profile Modal ───
  void _showMemberProfileModal(String uid) {
    if (!_userCache.containsKey(uid)) _fetchUser(uid);
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (ctx) {
        final isDark = Theme.of(ctx).brightness == Brightness.dark;
        final u = _userCache[uid] ?? {};
        final name = _nameOf(uid);
        final avatar = _avatarOf(uid);
        final bio = (u['bio'] ?? u['about'] ?? 'Hey there! I am using Luma Chat.').toString();
        final phone = (u[_kUserPhoneField] ?? u[_kUserPhoneLegacyField] ?? '').toString();
        final role = _roleOf(uid);
        final online = u[_kUserOnlineField] == true;

        return Container(
          margin: const EdgeInsets.only(top: 70),
          decoration: BoxDecoration(
            color: isDark ? const Color(0xFF17212B) : Colors.white,
            borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
          ),
          child: SafeArea(
            top: false,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const SizedBox(height: 10),
                Container(width: 38, height: 4, decoration: BoxDecoration(color: Colors.grey[400], borderRadius: BorderRadius.circular(2))),
                const SizedBox(height: 18),
                CircleAvatar(
                  radius: 46,
                  backgroundColor: _colorForUid(uid).withOpacity(0.25),
                  backgroundImage: avatar != null ? CachedNetworkImageProvider(avatar) : null,
                  child: avatar == null
                      ? Text(name.isNotEmpty ? name[0].toUpperCase() : '?',
                          style: TextStyle(fontSize: 32, color: _colorForUid(uid), fontWeight: FontWeight.bold))
                      : null,
                ),
                const SizedBox(height: 12),
                Text(name, style: const TextStyle(fontSize: 21, fontWeight: FontWeight.w700)),
                const SizedBox(height: 4),
                Text(
                  '${online ? "online" : "last seen recently"} • $role',
                  style: TextStyle(color: online ? Colors.green : Colors.grey, fontSize: 13, fontWeight: FontWeight.w500),
                ),
                const SizedBox(height: 16),
                const Divider(height: 1),
                if (phone.isNotEmpty)
                  ListTile(
                    leading: const Icon(Icons.phone_outlined, color: _kAccent),
                    title: Text(phone),
                    subtitle: const Text('Mobile'),
                    onTap: () {
                      Clipboard.setData(ClipboardData(text: phone));
                      Navigator.pop(ctx);
                      _showSnack('Phone number copied');
                    },
                  ),
                ListTile(
                  leading: const Icon(Icons.info_outline, color: _kAccent),
                  title: Text(bio),
                  subtitle: const Text('Bio'),
                ),
                if (uid != _currentUserId)
                  ListTile(
                    leading: const Icon(Icons.alternate_email, color: _kAccent),
                    title: const Text('Mention in group'),
                    onTap: () {
                      Navigator.pop(ctx);
                      if (_hardBlockReason() == null) _insertMentionAtEnd(uid);
                    },
                  ),
                if (_isAdmin && uid != _currentUserId && role != 'owner')
                  ListTile(
                    leading: Icon(role == 'admin' ? Icons.remove_moderator : Icons.admin_panel_settings, color: Colors.orange),
                    title: Text(role == 'admin' ? 'Dismiss admin' : 'Promote to admin'),
                    onTap: () async {
                      Navigator.pop(ctx);
                      final nextRole = role == 'admin' ? 'member' : 'admin';
                      await _chatRef.update(<Object, Object?>{
                        FieldPath(['participants_data', uid, 'role']): nextRole,
                      });
                      _showSnack('Updated role to $nextRole');
                    },
                  ),
                const SizedBox(height: 10),
              ],
            ),
          ),
        );
      },
    );
  }

  // ─── Item 7: Working Group Info & Settings Modal ───
  void _openGroupInfo() {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (ctx) {
        final isDark = Theme.of(ctx).brightness == Brightness.dark;
        return Container(
          height: MediaQuery.of(ctx).size.height * 0.88,
          decoration: BoxDecoration(
            color: isDark ? const Color(0xFF17212B) : Colors.white,
            borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
          ),
          child: StreamBuilder<DocumentSnapshot<Map<String, dynamic>>>(
            stream: _chatRef.snapshots(),
            builder: (context, snap) {
              final data = snap.data?.data() ?? _chatData ?? {};
              final name = (data['name'] ?? widget.chatName).toString();
              final desc = (data['description'] ?? '').toString();
              final locked = data['is_locked'] == true;
              final canPin = data['members_can_pin'] == true;
              final canEdit = data['members_can_edit'] != false;
              final restrictFwd = data['restrict_forwarding'] == true;
              final slowSec = (data['slow_mode_seconds'] as num?)?.toInt() ?? 0;
              final members = (data['participants'] as List?)?.map((e) => e.toString()).toList() ?? [];

              return ListView(
                padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
                children: [
                  Center(child: Container(width: 40, height: 4, decoration: BoxDecoration(color: Colors.grey[400], borderRadius: BorderRadius.circular(2)))),
                  const SizedBox(height: 16),
                  Center(
                    child: CircleAvatar(
                      radius: 44,
                      backgroundColor: _kAccent.withOpacity(0.18),
                      backgroundImage: _groupAvatar() != null ? CachedNetworkImageProvider(_groupAvatar()!) : null,
                      child: _groupAvatar() == null
                          ? Text(name.isNotEmpty ? name[0].toUpperCase() : 'G', style: const TextStyle(fontSize: 30, color: _kAccent, fontWeight: FontWeight.bold))
                          : null,
                    ),
                  ),
                  const SizedBox(height: 10),
                  Center(child: Text(name, style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w700))),
                  Center(child: Text('${members.length} members, $_onlineCount online', style: TextStyle(color: Colors.grey[500], fontSize: 13))),
                  if (desc.isNotEmpty) ...[
                    const SizedBox(height: 12),
                    ListTile(
                      leading: const Icon(Icons.info_outline, color: _kAccent),
                      title: Text(desc),
                      subtitle: const Text('Description'),
                    ),
                  ],
                  if (_isAdmin)
                    ListTile(
                      leading: const Icon(Icons.edit_outlined, color: _kAccent),
                      title: const Text('Edit group name & description'),
                      onTap: () => _editGroupMetadataDialog(name, desc),
                    ),
                  const Divider(),
                  SwitchListTile(
                    secondary: const Icon(Icons.notifications_off_outlined, color: _kAccent),
                    title: const Text('Mute notifications'),
                    value: _isMuted,
                    onChanged: (v) async {
                      if (_currentUserId == null) return;
                      await _chatRef.update(<Object, Object?>{
                        FieldPath(['participants_data', _currentUserId!, 'is_muted']): v,
                      });
                    },
                  ),
                  if (_isAdmin) ...[
                    const Padding(
                      padding: EdgeInsets.fromLTRB(16, 12, 16, 4),
                      child: Text('Group Permissions', style: TextStyle(color: _kAccent, fontWeight: FontWeight.w700, fontSize: 13)),
                    ),
                    SwitchListTile(
                      title: const Text('Only admins can send messages'),
                      value: locked,
                      onChanged: (v) => _chatRef.update({'is_locked': v}),
                    ),
                    SwitchListTile(
                      title: const Text('Members can pin messages'),
                      value: canPin,
                      onChanged: (v) => _chatRef.update({'members_can_pin': v}),
                    ),
                    SwitchListTile(
                      title: const Text('Members can edit their messages'),
                      value: canEdit,
                      onChanged: (v) => _chatRef.update({'members_can_edit': v}),
                    ),
                    SwitchListTile(
                      title: const Text('Restrict forwarding & saving'),
                      value: restrictFwd,
                      onChanged: (v) => _chatRef.update({'restrict_forwarding': v}),
                    ),
                    ListTile(
                      leading: const Icon(Icons.speed, color: _kAccent),
                      title: const Text('Slow mode'),
                      trailing: DropdownButton<int>(
                        value: [0, 10, 30, 60, 300].contains(slowSec) ? slowSec : 0,
                        underline: const SizedBox.shrink(),
                        items: const [
                          DropdownMenuItem(value: 0, child: Text('Off')),
                          DropdownMenuItem(value: 10, child: Text('10s')),
                          DropdownMenuItem(value: 30, child: Text('30s')),
                          DropdownMenuItem(value: 60, child: Text('1m')),
                          DropdownMenuItem(value: 300, child: Text('5m')),
                        ],
                        onChanged: (v) {
                          if (v != null) _chatRef.update({'slow_mode_seconds': v});
                        },
                      ),
                    ),
                  ],
                  const Divider(),
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
                    child: Text('Members (${members.length})', style: const TextStyle(color: _kAccent, fontWeight: FontWeight.w700, fontSize: 13)),
                  ),
                  for (final uid in members)
                    ListTile(
                      leading: CircleAvatar(
                        backgroundImage: _avatarOf(uid) != null ? CachedNetworkImageProvider(_avatarOf(uid)!) : null,
                        child: _avatarOf(uid) == null ? Text(_nameOf(uid).isNotEmpty ? _nameOf(uid)[0].toUpperCase() : '?') : null,
                      ),
                      title: Text(uid == _currentUserId ? '${_nameOf(uid)} (you)' : _nameOf(uid)),
                      subtitle: Text(_roleOf(uid)),
                      onTap: () {
                        Navigator.pop(ctx);
                        _showMemberProfileModal(uid);
                      },
                    ),
                ],
              );
            },
          ),
        );
      },
    );
  }

  Future<void> _editGroupMetadataDialog(String currentName, String currentDesc) async {
    final nameCtrl = TextEditingController(text: currentName);
    final descCtrl = TextEditingController(text: currentDesc);
    await showDialog(
      context: context,
      builder: (dCtx) => AlertDialog(
        title: const Text('Edit Group Info'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(controller: nameCtrl, decoration: const InputDecoration(labelText: 'Group Name')),
            const SizedBox(height: 10),
            TextField(controller: descCtrl, maxLines: 2, decoration: const InputDecoration(labelText: 'Description')),
          ],
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(dCtx), child: const Text('Cancel')),
          ElevatedButton(
            onPressed: () async {
              final newName = nameCtrl.text.trim();
              if (newName.isNotEmpty) {
                await _chatRef.update({'name': newName, 'description': descCtrl.text.trim()});
              }
              if (dCtx.mounted) Navigator.pop(dCtx);
            },
            child: const Text('Save'),
          ),
        ],
      ),
    );
  }

  // ─── Item 8: Custom Gallery Picker for Wallpaper ───
  Future<void> _pickWallpaperFromGallery() async {
    final photos = await _loadAssets(RequestType.image, size: 120);
    if (!mounted) return;
    final chosen = await showModalBottomSheet<AssetEntity>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (ctx) => Container(
        height: MediaQuery.of(ctx).size.height * 0.8,
        decoration: BoxDecoration(
          color: Theme.of(ctx).brightness == Brightness.dark ? const Color(0xFF17212B) : Colors.white,
          borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
        ),
        child: Column(
          children: [
            const Padding(
              padding: EdgeInsets.all(14),
              child: Text('Choose Wallpaper from Gallery', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
            ),
            Expanded(
              child: GridView.builder(
                padding: const EdgeInsets.all(2),
                gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(crossAxisCount: 3, crossAxisSpacing: 2, mainAxisSpacing: 2),
                itemCount: photos.length,
                itemBuilder: (_, i) => FutureBuilder<Uint8List?>(
                  future: photos[i].thumbnailDataWithSize(const ThumbnailSize(250, 250)),
                  builder: (_, s) => GestureDetector(
                    onTap: () => Navigator.pop(ctx, photos[i]),
                    child: s.data == null ? Container(color: Colors.grey.withOpacity(0.2)) : Image.memory(s.data!, fit: BoxFit.cover),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
    if (chosen == null) return;
    final file = await chosen.file;
    if (file == null) return;
    _showSnack('Applying wallpaper...');
    final url = await CloudinaryService.uploadImage(file, 'luma/wallpapers');
    if (url == null) {
      _showSnack('Upload failed');
      return;
    }
    if (mounted) ScaffoldMessenger.of(context).hideCurrentSnackBar();
    await _setWallpaper(url);
  }

  // ─── Item 4: Custom Sticker Creator & Sticker Pack Modal ───
  Future<void> _openCreateStickerFlow() async {
    final assets = await _loadAssets(RequestType.common, size: 120);
    if (!mounted) return;
    final picked = await showModalBottomSheet<AssetEntity>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (ctx) => Container(
        height: MediaQuery.of(ctx).size.height * 0.82,
        decoration: BoxDecoration(
          color: Theme.of(ctx).brightness == Brightness.dark ? const Color(0xFF17212B) : Colors.white,
          borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
        ),
        child: Column(
          children: [
            const Padding(
              padding: EdgeInsets.all(14),
              child: Text('Pick Photo or Video for Sticker', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
            ),
            Expanded(
              child: GridView.builder(
                padding: const EdgeInsets.all(2),
                gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(crossAxisCount: 3, crossAxisSpacing: 2, mainAxisSpacing: 2),
                itemCount: assets.length,
                itemBuilder: (_, i) {
                  final a = assets[i];
                  return FutureBuilder<Uint8List?>(
                    future: a.thumbnailDataWithSize(const ThumbnailSize(250, 250)),
                    builder: (_, s) => GestureDetector(
                      onTap: () => Navigator.pop(ctx, a),
                      child: s.data == null ? Container(color: Colors.grey.withOpacity(0.2)) : Image.memory(s.data!, fit: BoxFit.cover),
                    ),
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
    if (picked == null || !mounted) return;
    final file = await picked.file;
    if (file == null) return;

    final edited = await Navigator.push<Map<String, dynamic>>(
      context,
      MaterialPageRoute(builder: (_) => _MediaCaptionEditorScreen(asset: picked, initialFile: file)),
    );
    if (edited == null || !mounted) return;

    final isVideo = edited['isVideo'] == true;
    final stickerText = (edited['caption'] ?? '').toString();
    _showSnack('Creating sticker...');
    final url = isVideo
        ? await CloudinaryService.uploadVideo(edited['file'] as File, 'luma/stickers')
        : await CloudinaryService.uploadImage(edited['file'] as File, 'luma/stickers');
    if (url == null || _currentUserId == null) {
      _showSnack('Sticker creation failed');
      return;
    }

    final packId = 'custom_$_currentUserId';
    final packTitle = '${_nameOf(_currentUserId)}\'s Pack';
    await FirebaseFirestore.instance.collection('sticker_packs').doc(packId).set({
      'id': packId,
      'title': packTitle,
      'owner_id': _currentUserId,
      'stickers': FieldValue.arrayUnion([
        {'url': url, 'is_video': isVideo, 'label': stickerText, 'created_at': DateTime.now().toIso8601String()}
      ]),
    }, SetOptions(merge: true));

    if (mounted) ScaffoldMessenger.of(context).hideCurrentSnackBar();
    await _sendSticker(url, packId: packId, packTitle: packTitle);
  }

  void _showStickerPackModal(Map<String, dynamic> m) {
    final packId = (m['pack_id'] ?? 'trending_pack').toString();
    final packTitle = (m['pack_title'] ?? 'Sticker Pack').toString();
    final currentUrl = (m['media_url'] ?? '').toString();

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (ctx) {
        final isDark = Theme.of(ctx).brightness == Brightness.dark;
        return Container(
          height: MediaQuery.of(ctx).size.height * 0.62,
          decoration: BoxDecoration(
            color: isDark ? const Color(0xFF17212B) : Colors.white,
            borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
          ),
          child: StreamBuilder<DocumentSnapshot<Map<String, dynamic>>>(
            stream: FirebaseFirestore.instance.collection('sticker_packs').doc(packId).snapshots(),
            builder: (context, snap) {
              final rawList = (snap.data?.data()?['stickers'] as List?) ?? [];
              final urls = rawList.isNotEmpty
                  ? rawList.map((e) => (e is Map ? e['url'] : e).toString()).toList()
                  : <String>[if (currentUrl.isNotEmpty) currentUrl];

              return Column(
                children: [
                  const SizedBox(height: 10),
                  Container(width: 40, height: 4, decoration: BoxDecoration(color: Colors.grey[400], borderRadius: BorderRadius.circular(2))),
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 14, 16, 8),
                    child: Row(
                      children: [
                        Expanded(child: Text(packTitle, style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w700))),
                        Text('${urls.length} stickers', style: TextStyle(color: Colors.grey[500], fontSize: 13)),
                      ],
                    ),
                  ),
                  Expanded(
                    child: GridView.builder(
                      padding: const EdgeInsets.all(12),
                      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(crossAxisCount: 4, crossAxisSpacing: 10, mainAxisSpacing: 10),
                      itemCount: urls.length,
                      itemBuilder: (_, i) => GestureDetector(
                        onTap: () {
                          Navigator.pop(ctx);
                          _sendSticker(urls[i], packId: packId, packTitle: packTitle);
                        },
                        child: CachedNetworkImage(imageUrl: urls[i], fit: BoxFit.contain),
                      ),
                    ),
                  ),
                  SafeArea(
                    top: false,
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
                      child: SizedBox(
                        width: double.infinity,
                        height: 48,
                        child: ElevatedButton.icon(
                          style: ElevatedButton.styleFrom(backgroundColor: _kAccent, foregroundColor: Colors.white, shape: const StadiumBorder()),
                          icon: const Icon(Icons.add),
                          label: const Text('Add Sticker Pack'),
                          onPressed: () async {
                            if (_currentUserId != null) {
                              await FirebaseFirestore.instance.collection('user_settings').doc(_currentUserId).set({
                                'saved_sticker_packs': FieldValue.arrayUnion([packId]),
                              }, SetOptions(merge: true));
                            }
                            if (ctx.mounted) Navigator.pop(ctx);
                            _showSnack('Added "$packTitle" to your stickers');
                          },
                        ),
                      ),
                    ),
                  ),
                ],
              );
            },
          ),
        );
      },
    );
  }


PART 6 — Media & Caption Editor, Telegram Image Viewer & Video Viewer Classes
// ═══════════════════════════════════════════════════════════════════════════
// ITEM 3: MEDIA & CAPTION EDITOR SCREEN
// ═══════════════════════════════════════════════════════════════════════════
class _MediaCaptionEditorScreen extends StatefulWidget {
  final AssetEntity asset;
  final File initialFile;
  const _MediaCaptionEditorScreen({required this.asset, required this.initialFile});

  @override
  State<_MediaCaptionEditorScreen> createState() => _MediaCaptionEditorScreenState();
}

class _MediaCaptionEditorScreenState extends State<_MediaCaptionEditorScreen> {
  final _captionCtrl = TextEditingController();
  VideoPlayerController? _videoCtrl;
  bool _drawMode = false;
  Color _penColor = const Color(0xFFFF3B30);
  final List<List<Offset>> _strokes = [];
  List<Offset>? _currentStroke;
  int _quarterTurns = 0;

  bool get _isVideo => widget.asset.type == AssetType.video;

  @override
  void initState() {
    super.initState();
    if (_isVideo) {
      _videoCtrl = VideoPlayerController.file(widget.initialFile)
        ..initialize().then((_) {
          if (!mounted) return;
          _videoCtrl!.setLooping(true);
          _videoCtrl!.play();
          setState(() {});
        });
    }
  }

  @override
  void dispose() {
    _captionCtrl.dispose();
    _videoCtrl?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black87,
        foregroundColor: Colors.white,
        leading: IconButton(icon: const Icon(Icons.close), onPressed: () => Navigator.pop(context)),
        actions: [
          if (!_isVideo) ...[
            IconButton(
              icon: const Icon(Icons.rotate_right),
              onPressed: () => setState(() => _quarterTurns = (_quarterTurns + 1) % 4),
            ),
            IconButton(
              icon: Icon(Icons.brush, color: _drawMode ? _kAccent : Colors.white),
              onPressed: () => setState(() => _drawMode = !_drawMode),
            ),
            if (_strokes.isNotEmpty)
              IconButton(
                icon: const Icon(Icons.undo),
                onPressed: () => setState(() => _strokes.removeLast()),
              ),
          ],
        ],
      ),
      body: Column(
        children: [
          Expanded(
            child: Center(
              child: RotatedBox(
                quarterTurns: _quarterTurns,
                child: Stack(
                  alignment: Alignment.center,
                  children: [
                    if (_isVideo)
                      (_videoCtrl?.value.isInitialized ?? false)
                          ? AspectRatio(aspectRatio: _videoCtrl!.value.aspectRatio, child: VideoPlayer(_videoCtrl!))
                          : const CircularProgressIndicator(color: Colors.white)
                    else
                      Image.file(widget.initialFile, fit: BoxFit.contain),
                    if (_drawMode && !_isVideo)
                      Positioned.fill(
                        child: GestureDetector(
                          onPanStart: (d) {
                            _currentStroke = [d.localPosition];
                            setState(() => _strokes.add(_currentStroke!));
                          },
                          onPanUpdate: (d) {
                            _currentStroke?.add(d.localPosition);
                            setState(() {});
                          },
                          onPanEnd: (_) => _currentStroke = null,
                          child: CustomPaint(painter: _StrokePainter(strokes: _strokes, color: _penColor)),
                        ),
                      ),
                  ],
                ),
              ),
            ),
          ),
          if (_drawMode && !_isVideo)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 6),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [Colors.white, const Color(0xFFFF3B30), const Color(0xFFFFCC00), const Color(0xFF34C759), _kAccent]
                    .map((c) => GestureDetector(
                          onTap: () => setState(() => _penColor = c),
                          child: Container(
                            width: 26,
                            height: 26,
                            margin: const EdgeInsets.symmetric(horizontal: 6),
                            decoration: BoxDecoration(
                              color: c,
                              shape: BoxShape.circle,
                              border: Border.all(color: _penColor == c ? Colors.white : Colors.transparent, width: 2.5),
                            ),
                          ),
                        ))
                    .toList(),
              ),
            ),
          SafeArea(
            top: false,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(12, 6, 12, 10),
              child: Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: _captionCtrl,
                      style: const TextStyle(color: Colors.white),
                      decoration: InputDecoration(
                        hintText: 'Add a caption...',
                        hintStyle: const TextStyle(color: Colors.white54),
                        filled: true,
                        fillColor: Colors.white12,
                        contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                        border: OutlineInputBorder(borderRadius: BorderRadius.circular(24), borderSide: BorderSide.none),
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  FloatingActionButton(
                    mini: true,
                    backgroundColor: _kAccent,
                    onPressed: () => Navigator.pop(context, {
                      'file': widget.initialFile,
                      'isVideo': _isVideo,
                      'caption': _captionCtrl.text.trim(),
                    }),
                    child: const Icon(Icons.send, color: Colors.white, size: 20),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _StrokePainter extends CustomPainter {
  final List<List<Offset>> strokes;
  final Color color;
  _StrokePainter({required this.strokes, required this.color});

  @override
  void paint(Canvas canvas, Size size) {
    final p = Paint()
      ..color = color
      ..strokeWidth = 4
      ..strokeCap = StrokeCap.round
      ..style = PaintingStyle.stroke;
    for (final s in strokes) {
      if (s.length < 2) continue;
      final path = Path()..moveTo(s.first.dx, s.first.dy);
      for (var i = 1; i < s.length; i++) {
        path.lineTo(s[i].dx, s[i].dy);
      }
      canvas.drawPath(path, p);
    }
  }

  @override
  bool shouldRepaint(covariant _StrokePainter old) => true;
}

// ═══════════════════════════════════════════════════════════════════════════
// ITEM 9: TELEGRAM IMAGE VIEWER SCREEN
// ═══════════════════════════════════════════════════════════════════════════
class _ImageViewerScreen extends StatefulWidget {
  final String imagePath;
  final String senderName;
  final String timestamp;
  final String caption;
  final VoidCallback? onForward;

  const _ImageViewerScreen({
    required this.imagePath,
    this.senderName = '',
    this.timestamp = '',
    this.caption = '',
    this.onForward,
  });

  @override
  State<_ImageViewerScreen> createState() => _ImageViewerScreenState();
}

class _ImageViewerScreenState extends State<_ImageViewerScreen> {
  bool _showChrome = true;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: GestureDetector(
        onTap: () => setState(() => _showChrome = !_showChrome),
        child: Stack(
          children: [
            Center(
              child: InteractiveViewer(
                minScale: 0.8,
                maxScale: 5.0,
                child: Image.file(File(widget.imagePath)),
              ),
            ),
            if (_showChrome)
              Positioned(
                top: 0,
                left: 0,
                right: 0,
                child: AppBar(
                  backgroundColor: Colors.black54,
                  foregroundColor: Colors.white,
                  title: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(widget.senderName, style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
                      Text(widget.timestamp, style: const TextStyle(fontSize: 12, color: Colors.white70)),
                    ],
                  ),
                  actions: [
                    if (widget.onForward != null)
                      IconButton(
                        icon: const Icon(Icons.forward),
                        tooltip: 'Forward',
                        onPressed: () {
                          Navigator.pop(context);
                          widget.onForward!();
                        },
                      ),
                    IconButton(
                      icon: const Icon(Icons.open_in_new),
                      tooltip: 'Share / Open with',
                      onPressed: () => OpenFilex.open(widget.imagePath),
                    ),
                  ],
                ),
              ),
            if (_showChrome && widget.caption.isNotEmpty)
              Positioned(
                left: 0,
                right: 0,
                bottom: 0,
                child: Container(
                  color: Colors.black54,
                  padding: const EdgeInsets.fromLTRB(16, 12, 16, 28),
                  child: Text(widget.caption, style: const TextStyle(color: Colors.white, fontSize: 15)),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

// ═══════════════════════════════════════════════════════════════════════════
// ITEM 10: TELEGRAM VIDEO VIEWER SCREEN
// ═══════════════════════════════════════════════════════════════════════════
class _VideoViewerScreen extends StatefulWidget {
  final String url;
  final String senderName;
  final String timestamp;
  final String caption;
  final VoidCallback? onDownload;
  final VoidCallback? onForward;

  const _VideoViewerScreen({
    required this.url,
    this.senderName = '',
    this.timestamp = '',
    this.caption = '',
    this.onDownload,
    this.onForward,
  });

  @override
  State<_VideoViewerScreen> createState() => _VideoViewerScreenState();
}

class _VideoViewerScreenState extends State<_VideoViewerScreen> {
  late final VideoPlayerController _ctrl;
  bool _ready = false;
  bool _showOverlay = true;
  double _speed = 1.0;

  @override
  void initState() {
    super.initState();
    _ctrl = VideoPlayerController.networkUrl(Uri.parse(widget.url))
      ..initialize().then((_) {
        if (!mounted) return;
        _ctrl.addListener(() {
          if (mounted) setState(() {});
        });
        _ctrl.play();
        setState(() => _ready = true);
      });
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  void _cycleSpeed() {
    const speeds = [1.0, 1.5, 2.0];
    final next = speeds[(speeds.indexOf(_speed) + 1) % speeds.length];
    _ctrl.setPlaybackSpeed(next);
    setState(() => _speed = next);
  }

  @override
  Widget build(BuildContext context) {
    final pos = _ready ? _ctrl.value.position : Duration.zero;
    final dur = _ready ? _ctrl.value.duration : Duration.zero;
    final maxMs = math.max(1, dur.inMilliseconds).toDouble();

    return Scaffold(
      backgroundColor: Colors.black,
      body: GestureDetector(
        onTap: () => setState(() => _showOverlay = !_showOverlay),
        child: Stack(
          alignment: Alignment.center,
          children: [
            if (_ready)
              AspectRatio(
                aspectRatio: _ctrl.value.aspectRatio == 0 ? 9 / 16 : _ctrl.value.aspectRatio,
                child: VideoPlayer(_ctrl),
              )
            else
              const CircularProgressIndicator(color: Colors.white),
            if (_showOverlay)
              Positioned(
                top: 0,
                left: 0,
                right: 0,
                child: AppBar(
                  backgroundColor: Colors.black54,
                  foregroundColor: Colors.white,
                  title: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(widget.senderName, style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
                      Text(widget.timestamp, style: const TextStyle(fontSize: 12, color: Colors.white70)),
                    ],
                  ),
                  actions: [
                    TextButton(
                      onPressed: _ready ? _cycleSpeed : null,
                      child: Text('${_speed}x', style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
                    ),
                    if (widget.onForward != null)
                      IconButton(icon: const Icon(Icons.forward), onPressed: widget.onForward),
                    if (widget.onDownload != null)
                      IconButton(icon: const Icon(Icons.download), onPressed: widget.onDownload),
                  ],
                ),
              ),
            if (_showOverlay && _ready)
              GestureDetector(
                onTap: () => _ctrl.value.isPlaying ? _ctrl.pause() : _ctrl.play(),
                child: Container(
                  padding: const EdgeInsets.all(14),
                  decoration: const BoxDecoration(color: Colors.black54, shape: BoxShape.circle),
                  child: Icon(_ctrl.value.isPlaying ? Icons.pause : Icons.play_arrow, color: Colors.white, size: 38),
                ),
              ),
            if (_showOverlay && _ready)
              Positioned(
                left: 0,
                right: 0,
                bottom: 0,
                child: Container(
                  color: Colors.black54,
                  padding: const EdgeInsets.fromLTRB(12, 6, 12, 24),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      if (widget.caption.isNotEmpty)
                        Padding(
                          padding: const EdgeInsets.only(bottom: 6, left: 4),
                          child: Text(widget.caption, style: const TextStyle(color: Colors.white, fontSize: 14)),
                        ),
                      Row(
                        children: [
                          Text(_fmtDur(pos.inSeconds), style: const TextStyle(color: Colors.white, fontSize: 12)),
                          Expanded(
                            child: Slider(
                              activeColor: _kAccent,
                              inactiveColor: Colors.white30,
                              value: pos.inMilliseconds.clamp(0, maxMs.toInt()).toDouble(),
                              max: maxMs,
                              onChanged: (v) => _ctrl.seekTo(Duration(milliseconds: v.round())),
                            ),
                          ),
                          Text(_fmtDur(dur.inSeconds), style: const TextStyle(color: Colors.white, fontSize: 12)),
                        ],
                      ),
                    ],
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}


