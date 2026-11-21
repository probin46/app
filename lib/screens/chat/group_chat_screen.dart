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
import 'package:flutter/rendering.dart' show RenderRepaintBoundary;
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
class LocalRecorder {
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
class GroupChatScreen extends StatefulWidget {
  final String chatId;
  final String chatName;
  final String? chatAvatar;

  const GroupChatScreen({super.key, required this.chatId, required this.chatName, this.chatAvatar});

  @override
  State<GroupChatScreen> createState() => _GroupChatScreenState();
}

class _GroupChatScreenState extends State<GroupChatScreen> with WidgetsBindingObserver {
  // Controllers
  final _messageController = TextEditingController();
  final _messageFocus = FocusNode();
  final _scrollController = ScrollController();
  final _picker = ImagePicker();
  final _audioPlayer = AudioPlayer();
  final LocalRecorder _audioRecorder = LocalRecorder();

  // Session
  String? _currentUserId;
  bool _isMePremium = false;
  bool _appResumed = true;
  String? _wallpaper;

  // UI state
  String? _activePanel; // 'emoji' | 'gif' | 'sticker'
  bool _hasText = false;
  bool _hasSelection = false;
  bool _atBottom = true;
  bool _showFab = false;

  // Data
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

  // Unread
  int _unreadCount = 0;
  String? _firstUnreadId;
  String? _dividerAnchorId;
  int _dividerCount = 0;
  final Set<String> _deliveredTried = {};
  final Set<String> _readTried = {};

  // Subscriptions
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

  // Reply / edit / selection
  String? _replyingTo;
  String? _editingId;
  bool _multiSelectMode = false;
  final Set<String> _selectedIds = {};
  String? _highlightId;
  final Map<String, GlobalKey> _msgKeys = {};

  // Users / members
  final Map<String, Map<String, dynamic>> _userCache = {};
  final Map<String, DateTime> _typingUsers = {};
  DateTime? _lastTypingWrite;
  String _membersKey = '';
  final Map<int, int> _onlineByChunk = {};
  int get _onlineCount => _onlineByChunk.values.fold(0, (a, b) => a + b);

  // Mentions
  List<String> _mentionResults = [];

  // Slow mode
  DateTime? _lastSendAt;
  int _lastSlow = 0;
  int _lastTypingCount = 0;

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
  final Map<String, ValueNotifier<double?>> _dlN = {};
  final Map<String, http.Client> _dlClients = {};
  final Set<String> _dlCancelled = {};
  String? _docsPath;
  final ValueNotifier<int> _infoTick = ValueNotifier<int>(0);
  bool _notifMuted = false;
  double _synthPrev = 0.4;
  final math.Random _rnd = math.Random();

  // Attachment sheet state
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
      FirebaseFirestore.instance.collection('chats').doc(widget.chatId);
  CollectionReference<Map<String, dynamic>> get _msgs => _chatRef.collection('messages');
  DocumentReference<Map<String, dynamic>> _msgDoc(String id) => _msgs.doc(id);
  CollectionReference<Map<String, dynamic>> get _pinsRef => _chatRef.collection('pinned_messages');
  DocumentReference<Map<String, dynamic>> get _typingDoc => _chatRef.collection('typing').doc(_currentUserId);

  // ─── Permissions / group settings ───
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
    _loadNotifMuted();
    getApplicationDocumentsDirectory().then((d) {
      if (mounted) setState(() => _docsPath = d.path);
    }).catchError((_) {});
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
    for (final c in _dlClients.values) {
      c.close();
    }
    _infoTick.dispose();
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

  // ═══════════════════════════════════════════════════════════════════════
  // LISTENERS
  // ═══════════════════════════════════════════════════════════════════════
  void _listenToChat() {
    _chatSub = _chatRef.snapshots().listen((doc) {
      if (!mounted) return;
      setState(() {
        if (doc.exists) _chatData = doc.data();
      });
      _infoTick.value++;
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
        _infoTick.value++;
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
        // Messages that fell out of the live window move into the older list so
        // there are never gaps.
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
    _userCache[uid] = {_kUserNameField: 'Member', _kUserAvatarField: null}; // prevents duplicate fetches
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
  // COMPOSER STATE (text / selection / mentions)
  // ═══════════════════════════════════════════════════════════════════════
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

  /// Members whose "@Name" appears in the text.
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
    // Do not await the server ack: the local snapshot already shows the message.
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

  Future<void> _sendSticker(String url, {String? packId}) async {
    final id = await _postMessage({
      'type': 'sticker',
      'media_type': 'sticker',
      'media_url': url,
      if (packId != null) 'sticker_pack_id': packId,
      ...(_takeReplyFields()),
    });
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
      _showSnack(_isMePremium ? 'Max 5GB' : 'Upgrade to Premium for >200MB');
      return;
    }

    _showSnack('Uploading...');
    final url = type == 'image'
        ? await CloudinaryService.uploadImage(file, 'luma/groups')
        : await CloudinaryService.uploadVideo(file, 'luma/groups');
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
          _showSnack(_isMePremium ? 'Max 5GB' : 'Upgrade to Premium for >200MB');
          continue;
        }
        final isVideo = a.type == AssetType.video;
        _showSnack('Uploading ${i + 1}/${assets.length}...');
        final url = isVideo
            ? await CloudinaryService.uploadVideo(file, 'luma/groups')
            : await CloudinaryService.uploadImage(file, 'luma/groups');
        if (url == null) {
          _showSnack('Upload failed');
          continue;
        }
        await _postMessage({
          'type': isVideo ? 'video' : 'image',
          'media_type': isVideo ? 'video' : 'image',
          'media_url': url,
          if (a.orientatedWidth > 0) 'width': a.orientatedWidth,
          if (a.orientatedHeight > 0) 'height': a.orientatedHeight,
          if (isVideo && a.duration > 0) 'duration': a.duration,
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
        final url = await CloudinaryService.uploadImage(File(photo.path), 'luma/groups');
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
        double v;
        if (a == null) {
          // Native amplitude not available: animate a natural-looking wave instead.
          _ampSupported = false;
          _synthPrev = _c01(_synthPrev * 0.45 + _rnd.nextDouble() * 0.75 + 0.05);
          v = math.max(0.12, _synthPrev);
        } else {
          v = math.sqrt(_c01(a / 32767.0));
        }
        _ampSamples.add(v);
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
    if (_ampSamples.length < 8) return _seedWave('rec${DateTime.now().millisecondsSinceEpoch}').map((e) => (e * 31).round()).toList();
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
    final path = '${folder.path}/${_stableHash(url)}_$safe';
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
        'content': '${_nameOf(_currentUserId)} pinned a message',
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
          ? 'Summarize this chat message: "$text"'
          : 'Translate this message to English: "$text"';
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
    if (!_canForward) {
      _showSnack('Forwarding is restricted in this group');
      return;
    }
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
        for (final m in list) {
          final newId = const Uuid().v4();
          batch.set(FirebaseFirestore.instance.collection('chats').doc(t.id).collection('messages').doc(newId), {
            'id': newId,
            'sender_id': me,
            'created_at': FieldValue.serverTimestamp(),
            'is_read': false,
            'read_by': [me],
            'delivered_to': [me],
            ..._forwardPayload(m),
          });
        }
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
    if (id != null) {
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

  // ─── Header (Telegram-style floating circles + pill) ───
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

  String _subtitle() {
    final names = _typingNames();
    if (names.isNotEmpty) {
      if (names.length == 1) return '${names[0]} is typing…';
      if (names.length == 2) return '${names[0]} and ${names[1]} are typing…';
      return '${names.length} people are typing…';
    }
    final p = _chatData?['participants'];
    if (p is! List) return '';
    final n = p.length;
    return '$n member${n == 1 ? '' : 's'}${_onlineCount > 0 ? ', $_onlineCount online' : ''}';
  }

  void _openGroupInfo() => _showGroupInfoSheet();

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
    final avatar = _groupAvatar();
    final name = _groupName();
    final typing = _typingNames().isNotEmpty;
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
                onTap: _openGroupInfo,
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
                            Text(
                              _subtitle(),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                color: typing ? _kAccent : theme.colorScheme.onSurface.withOpacity(0.55),
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
            if (_canPin)
              IconButton(
                visualDensity: VisualDensity.compact,
                icon: const Icon(Icons.close, size: 18),
                onPressed: () => _unpin(mid ?? p['id'].toString()),
              )
            else
              const Padding(padding: EdgeInsets.all(8), child: Icon(Icons.push_pin, size: 16, color: _kAccent)),
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
    } else if (!_messagesLoaded) {
      body = const Center(child: SizedBox(width: 28, height: 28, child: CircularProgressIndicator(strokeWidth: 2.5)));
    } else if (list.isEmpty) {
      body = Center(
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          decoration: _headerDecoration(isDark, radius: 18),
          child: const Text('No messages yet. Say hi 👋'),
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
          _buildMessageRow(m, older, newer, showDate, showDivider, theme, isDark),
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

    final baseColor = isMe
        ? (isDark ? const Color(0xFF005C4B) : const Color(0xFFEFFDDE))
        : (isDark ? const Color(0xFF1F2C34) : Colors.white);
    var bubbleColor = baseColor;
    if (selected) bubbleColor = Color.alphaBlend(_kAccent.withOpacity(0.3), baseColor);
    if (_highlightId == id) bubbleColor = Color.alphaBlend(_kAccent.withOpacity(0.35), baseColor);

    final screenW = MediaQuery.of(context).size.width;
    final maxW = math.min(screenW * 0.70, 320.0);
    final mediaW = math.min(screenW * 0.60, 250.0);
    final nameColor = _colorForUid(senderId);
    final role = senderId != null ? _roleOf(senderId) : 'member';
    final metaColor = theme.colorScheme.onSurface.withOpacity(0.5);

    final reactions = m['reactions'];
    final hasReactions = reactions is Map && reactions.values.any((v) => v is List && v.isNotEmpty);

    final type = (m['type'] ?? m['media_type'] ?? 'text').toString();
    final text = (m['text'] ?? '').toString();
    final isSticker = type == 'sticker';
    final isVisual = type == 'image' || type == 'video' || type == 'gif';
    final hideText = type == 'location' || type == 'live_location' || type == 'contact';
    final hasCaption = text.isNotEmpty && !hideText;
    final bareMedia = isSticker || (isVisual && !hasCaption);
    final hasReply = m['reply_to'] != null;
    final hasLink = type == 'text' && _firstUrl(text) != null;
    final inlineMeta = hasCaption && !hasLink && !isSticker;
    final metaW = (isMe ? 64.0 : 42.0) + (m['edited'] == true ? 40.0 : 0.0);
    final hasForward = m['forwarded_from'] != null;

    Widget metaRow({bool overlay = false}) {
      final c = overlay ? Colors.white : metaColor;
      return Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (m['edited'] == true)
            Padding(
              padding: const EdgeInsets.only(right: 4),
              child: Text('edited', style: TextStyle(fontSize: 11, fontStyle: FontStyle.italic, color: c)),
            ),
          Text(DateFormat('HH:mm').format(_msgTime(m)), style: TextStyle(fontSize: 11, color: c)),
          if (isMe) ...[const SizedBox(width: 3), _tickIcon(m, c)],
        ],
      );
    }

    final overlayMeta = Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(color: Colors.black.withOpacity(0.45), borderRadius: BorderRadius.circular(10)),
      child: metaRow(overlay: true),
    );

    Widget? nameRow;
    if (showName) {
      nameRow = GestureDetector(
        onTap: (senderId == null || _multiSelectMode) ? null : () => _showUserProfile(senderId),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Flexible(
              child: Text(
                _nameOf(senderId),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(fontSize: 13.5, fontWeight: FontWeight.w700, color: nameColor),
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
                  style: TextStyle(fontSize: 10, fontWeight: FontWeight.w700, color: role == 'owner' ? const Color(0xFFB8860B) : _kAccent),
                ),
              ),
            ],
          ],
        ),
      );
    }

    final textTop = (nameRow != null || hasForward || hasReply) ? 4.0 : 7.0;
    final contents = _contentWidgets(
      m,
      isMe,
      theme,
      isDark,
      mediaW: mediaW,
      overlayMeta: overlayMeta,
      inlineMeta: inlineMeta ? metaRow() : null,
      metaW: metaW,
      textTop: textTop,
    );

    Widget bubble;
    if (isSticker) {
      final bits = <Widget>[];
      if (nameRow != null) {
        bits.add(Container(
          margin: const EdgeInsets.only(bottom: 3),
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
          decoration: BoxDecoration(color: Colors.black.withOpacity(0.35), borderRadius: BorderRadius.circular(10)),
          child: Text(_nameOf(senderId), style: const TextStyle(color: Colors.white, fontSize: 12, fontWeight: FontWeight.w700)),
        ));
      }
      if (hasReply) {
        bits.add(Container(
          width: 170,
          margin: const EdgeInsets.only(bottom: 3),
          decoration: BoxDecoration(color: baseColor, borderRadius: BorderRadius.circular(12)),
          clipBehavior: Clip.antiAlias,
          child: _quotedReply(m),
        ));
      }
      bits.addAll(contents);
      if (hasReactions) bits.add(Padding(padding: const EdgeInsets.only(top: 2), child: _reactionsRow(m)));
      bubble = Container(
        decoration: BoxDecoration(
          color: (selected || _highlightId == id) ? _kAccent.withOpacity(0.25) : Colors.transparent,
          borderRadius: BorderRadius.circular(14),
        ),
        child: Column(
          crossAxisAlignment: isMe ? CrossAxisAlignment.end : CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: bits,
        ),
      );
    } else {
      final kids = <Widget>[];
      if (nameRow != null) kids.add(Padding(padding: const EdgeInsets.fromLTRB(10, 6, 10, 2), child: nameRow));
      if (hasForward) {
        kids.add(Padding(
          padding: EdgeInsets.fromLTRB(10, nameRow == null ? 6 : 2, 10, 2),
          child: Text(
            'Forwarded from ${m['forwarded_from']}',
            style: const TextStyle(fontSize: 12, fontStyle: FontStyle.italic, color: _kAccent, fontWeight: FontWeight.w600),
          ),
        ));
      }
      if (hasReply) kids.add(_quotedReply(m, flushTop: nameRow == null && !hasForward));
      kids.addAll(contents);
      if (!bareMedia && !inlineMeta) {
        kids.add(Padding(
          padding: const EdgeInsets.fromLTRB(10, 2, 10, 5),
          child: Align(alignment: Alignment.centerRight, child: metaRow()),
        ));
      }
      if (hasReactions) kids.add(Padding(padding: const EdgeInsets.fromLTRB(10, 0, 10, 6), child: _reactionsRow(m)));

      final intrinsic = hasReply && !isVisual && (type == 'text' || type == 'audio' || type == 'file');
      final stretch = isVisual || intrinsic;
      Widget col = Column(
        crossAxisAlignment: stretch ? CrossAxisAlignment.stretch : CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: kids,
      );
      if (intrinsic) col = IntrinsicWidth(child: col);

      bubble = AnimatedContainer(
        duration: const Duration(milliseconds: 250),
        width: isVisual ? mediaW : null,
        constraints: isVisual ? null : BoxConstraints(maxWidth: maxW),
        clipBehavior: Clip.antiAlias,
        decoration: BoxDecoration(
          color: bubbleColor,
          borderRadius: BorderRadius.only(
            topLeft: const Radius.circular(18),
            topRight: const Radius.circular(18),
            bottomLeft: Radius.circular((!isMe && lastInGroup) ? 5 : 18),
            bottomRight: Radius.circular((isMe && lastInGroup) ? 5 : 18),
          ),
          boxShadow: [BoxShadow(color: Colors.black.withOpacity(0.06), blurRadius: 2, offset: const Offset(0, 1))],
        ),
        child: col,
      );
    }

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
            child: showAvatar
                ? GestureDetector(
                    onTap: (senderId == null || _multiSelectMode) ? null : () => _showUserProfile(senderId),
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
                  child: CustomPaint(painter: _WavePainter(bars: (wf != null && wf.isNotEmpty) ? wf : _seedWave(id), progress: prog, active: _kAccent, inactive: inactive)),
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
        MaterialPageRoute(builder: (_) => _LocationViewerScreen(chatId: widget.chatId, msgId: msg['id'], lat: lat, lng: lng, live: isLive)),
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
  // CONTEXT MENU / REACTIONS / WHO REACTED
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
    final canEdit = isMine && type == 'text' && (_isAdmin || _chatData?['members_can_edit'] != false);
    final canDeleteAll = isMine || _isAdmin;
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
                  if (_canForward)
                    _menuTile(Icons.forward, 'Forward', () {
                      close();
                      _forwardMessages([m]);
                    }),
                  if (_canPin)
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
                  if (canDeleteAll)
                    _menuTile(Icons.delete, 'Delete for everyone', () async {
                      close();
                      if (await _confirm('Delete message?', 'This removes it for everyone in the group.')) {
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
    for (final e in entries) {
      for (final uid in e.value) {
        if (!_userCache.containsKey(uid)) _fetchUser(uid);
      }
    }
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
                      backgroundImage: _avatarOf(uid) != null ? CachedNetworkImageProvider(_avatarOf(uid)!) : null,
                      child: _avatarOf(uid) == null ? const Icon(Icons.person, size: 16) : null,
                    ),
                    title: Text(uid == _currentUserId ? 'You' : _nameOf(uid)),
                  ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  // ═══════════════════════════════════════════════════════════════════════
  // MORE MENU / SEARCH / WALLPAPER / LEAVE / PINS
  // ═══════════════════════════════════════════════════════════════════════
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
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const SizedBox(height: 6),
                _menuTile(Icons.info_outline, 'Group info', () {
                  close();
                  _openGroupInfo();
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
                _menuTile(Icons.check_circle_outline, 'Select messages', () {
                  close();
                  setState(() => _multiSelectMode = true);
                }),
                if (_isMember)
                  _menuTile(Icons.exit_to_app, 'Leave group', () {
                    close();
                    _leaveGroup();
                  }, color: Colors.red),
                const SizedBox(height: 6),
              ],
            ),
          ),
        );
      },
    );
  }

  Future<void> _openSearch({int tab = 0}) async {
    final result = await Navigator.push<String>(
      context,
      MaterialPageRoute(
        builder: (_) => _GroupSearchScreen(
          initialTab: tab,
          getMessages: () => _visible,
          loadOlder: _loadOlder,
          hasMore: () => !_noMoreOlder,
          nameOf: (uid) => _nameOf(uid),
          avatarOf: (uid) => _avatarOf(uid),
          memberIds: _memberIds(),
          roleOf: _roleOf,
          isOnline: (uid) => _userCache[uid]?[_kUserOnlineField] == true,
          meId: _currentUserId,
        ),
      ),
    );
    if (!mounted || result == null) return;
    if (result.startsWith('mention:')) {
      if (_hardBlockReason() == null) _insertMentionAtEnd(result.substring(8));
    } else {
      _jumpToMessage(result);
    }
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
                  trailing: _canPin
                      ? IconButton(
                          icon: const Icon(Icons.close, size: 18),
                          onPressed: () {
                            Navigator.pop(ctx);
                            _unpin(p['message_id']?.toString() ?? p['id'].toString());
                          },
                        )
                      : null,
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

  Future<void> _leaveGroup() async {
    if (_myRole == 'owner') {
      _showSnack('Owners cannot leave. Transfer ownership in Group info first.');
      return;
    }
    final ok = await _confirm('Leave group?', 'You will stop receiving messages from this group.', action: 'Leave');
    if (!ok) return;
    final me = _currentUserId;
    if (me == null) return;
    try {
      await _postMessage({
        'type': 'system',
        'media_type': 'system',
        'content': '${_nameOf(me)} left the group',
        'system_kind': 'leave',
      }, system: true);
      await _chatRef.update(<Object, Object?>{
        'participants': FieldValue.arrayRemove([me]),
        FieldPath(['participants_data', me]): FieldValue.delete(),
      });
      if (mounted) Navigator.pop(context);
    } catch (e) {
      _showSnack('Could not leave: $e');
    }
  }

  Future<void> _setWallpaper(String? value) async {
    final me = _currentUserId;
    if (me == null) return;
    setState(() => _wallpaper = value);
    try {
      await FirebaseFirestore.instance.collection('user_settings').doc(me).set({
        'chat_wallpapers': {widget.chatId: value ?? FieldValue.delete()},
      }, SetOptions(merge: true));
    } catch (e) {
      _showSnack('Could not save wallpaper: $e');
    }
  }

  Future<void> _pickWallpaperFromGallery() async {
    final picked = await _pickFromCustomGallery(type: RequestType.image, title: 'Choose wallpaper');
    if (picked == null || picked.isEmpty || !mounted) return;
    final file = await picked.first.file;
    if (file == null || !mounted) return;
    final ok = await Navigator.push<bool>(
      context,
      MaterialPageRoute(fullscreenDialog: true, builder: (_) => _WallpaperPreviewScreen(file: file)),
    );
    if (ok != true) return;
    _showSnack('Uploading wallpaper...');
    final url = await CloudinaryService.uploadImage(file, 'luma/wallpapers');
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
  // BOTTOM AREA (reply/edit bars, mentions, format bar, composer, panel)
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
        if (showBars && _mentionResults.isNotEmpty) _buildMentionList(theme, isDark),
        if (showBars && _hasSelection) _buildFormatBar(theme, isDark),
        if (showBars && _slowSeconds > 0 && !_isAdmin) _buildSlowBanner(theme, isDark),
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

  Widget _buildMentionList(ThemeData theme, bool isDark) {
    return Container(
      margin: const EdgeInsets.fromLTRB(8, 0, 8, 4),
      constraints: const BoxConstraints(maxHeight: 220),
      decoration: _headerDecoration(isDark, radius: 16),
      child: ListView(
        shrinkWrap: true,
        padding: const EdgeInsets.symmetric(vertical: 4),
        children: _mentionResults.map((uid) {
          final av = _avatarOf(uid);
          return ListTile(
            dense: true,
            leading: CircleAvatar(
              radius: 15,
              backgroundColor: _colorForUid(uid).withOpacity(0.25),
              backgroundImage: av != null ? CachedNetworkImageProvider(av) : null,
              child: av == null
                  ? Text(_nameOf(uid).isNotEmpty ? _nameOf(uid)[0].toUpperCase() : '?', style: TextStyle(color: _colorForUid(uid), fontSize: 12))
                  : null,
            ),
            title: Text(_nameOf(uid)),
            trailing: (_roleOf(uid) == 'owner' || _roleOf(uid) == 'admin')
                ? Text(_roleOf(uid), style: const TextStyle(fontSize: 11, color: _kAccent))
                : null,
            onTap: () => _insertMention(uid),
          );
        }).toList(),
      ),
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

  Widget _buildSlowBanner(ThemeData theme, bool isDark) {
    final r = _slowRemaining;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 4),
      child: Row(children: [
        const Icon(Icons.hourglass_bottom, size: 14, color: Colors.orange),
        const SizedBox(width: 6),
        Text(
          r > 0 ? 'Slow mode: next message in ${r}s' : 'Slow mode: one message every ${_slowSeconds}s',
          style: const TextStyle(fontSize: 12, color: Colors.orange, fontWeight: FontWeight.w600),
        ),
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
      ]),
    );
  }

  Widget _buildMultiSelectBar(ThemeData theme, bool isDark) {
    final selected = _visible.where((m) => _selectedIds.contains(m['id'])).toList();
    final canDeleteAll = selected.isNotEmpty && selected.every((m) => m['sender_id'] == _currentUserId || _isAdmin);
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
        if (_canForward)
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
                    canDeleteAll ? 'They will be removed for everyone.' : 'Messages from others are removed only for you.',
                  );
                  if (!ok) return;
                  for (final m in selected) {
                    final id = m['id'].toString();
                    if (m['sender_id'] == _currentUserId || _isAdmin) {
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
    final slow = _slowRemaining;
    final showSend = _hasText || _editingId != null;
    Widget icon;
    if (_editingId != null) {
      icon = const Icon(Icons.check, color: Colors.white, size: 24);
    } else if (_hasText) {
      icon = slow > 0
          ? Text('$slow', style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 16))
          : const Icon(Icons.send, color: Colors.white, size: 22);
    } else {
      icon = const Icon(Icons.mic, color: Colors.white, size: 24);
    }
    final size = _isRecording ? 60.0 : 48.0;
    final circle = AnimatedContainer(
      duration: const Duration(milliseconds: 150),
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: (_hasText && slow > 0) ? Colors.grey : (_recCancel ? Colors.red : _kAccent),
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
                : (bars.isNotEmpty
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
      content = _StickerPanel(
        key: const ValueKey('sticker_panel'),
        uid: _currentUserId ?? '',
        apiKey: _kGiphyApiKey,
        onSend: (u, p) => _sendSticker(u, packId: p),
        onCreate: _createStickerFlow,
      );
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
  // DOWNLOAD-BEFORE-VIEW (blurred tile -> download icon -> circular progress)
  // ═══════════════════════════════════════════════════════════════════════
  String _dlPath(String url, String ext, {String? fileName}) {
    final safe = (fileName != null && fileName.isNotEmpty) ? fileName.replaceAll(RegExp(r'[^\w\.\- ]'), '_') : 'luma.$ext';
    return '${_docsPath ?? ''}/luma_downloads/${_stableHash(url)}_$safe';
  }

  String? _localPathIfExists(String url, String ext, {String? fileName}) {
    final c = _localCache[url];
    if (c != null && File(c).existsSync()) return c;
    if (_docsPath == null) return null;
    final p = _dlPath(url, ext, fileName: fileName);
    if (File(p).existsSync()) {
      _localCache[url] = p;
      return p;
    }
    return null;
  }

  String? _localForMessage(Map<String, dynamic> m) {
    final url = m['media_url']?.toString();
    if (url == null) return null;
    final isVideo = (m['type'] ?? '').toString() == 'video';
    return _localPathIfExists(url, isVideo ? 'mp4' : 'jpg');
  }

  void _cancelDownload(String url) {
    _dlCancelled.add(url);
    _dlClients[url]?.close();
  }

  Future<String?> _startMediaDownload(Map<String, dynamic> m) async {
    final url = m['media_url']?.toString();
    if (url == null) return null;
    final isVideo = (m['type'] ?? '').toString() == 'video';
    final ext = isVideo ? 'mp4' : 'jpg';
    final existing = _localPathIfExists(url, ext);
    if (existing != null) return existing;
    final n = _dlN.putIfAbsent(url, () => ValueNotifier<double?>(null));
    if (n.value != null) return null;
    n.value = 0.0;
    final client = http.Client();
    _dlClients[url] = client;
    File? part;
    String? result;
    try {
      final dir = await getApplicationDocumentsDirectory();
      _docsPath = dir.path;
      final folder = Directory('${dir.path}/luma_downloads');
      if (!folder.existsSync()) folder.createSync(recursive: true);
      final path = _dlPath(url, ext);
      final tmp = File('$path.part');
      part = tmp;
      final res = await client.send(http.Request('GET', Uri.parse(url))).timeout(const Duration(seconds: 30));
      if (res.statusCode != 200) throw Exception('HTTP ${res.statusCode}');
      final total = res.contentLength ?? 0;
      final sink = tmp.openWrite();
      var got = 0;
      await for (final chunk in res.stream) {
        sink.add(chunk);
        got += chunk.length;
        if (total > 0) n.value = math.max(0.04, _c01(got / total));
      }
      await sink.close();
      await tmp.rename(path);
      _localCache[url] = path;
      result = path;
    } catch (e) {
      final p = part;
      if (p != null && p.existsSync()) {
        try {
          p.deleteSync();
        } catch (_) {}
      }
      if (!_dlCancelled.contains(url)) _showSnack('Download failed');
    } finally {
      client.close();
      _dlClients.remove(url);
      _dlCancelled.remove(url);
      n.value = null;
      if (mounted) setState(() {});
    }
    return result;
  }

  Widget _videoPoster(String url, double w, double h) {
    final poster = _videoPosterUrl(url);
    if (poster == null) return Container(width: w, height: h, color: Colors.black87);
    return CachedNetworkImage(
      imageUrl: poster,
      width: w,
      height: h,
      fit: BoxFit.cover,
      placeholder: (_, __) => Container(width: w, height: h, color: Colors.black87),
      errorWidget: (_, __, ___) => Container(width: w, height: h, color: Colors.black87),
    );
  }

  Widget _mediaTile(Map<String, dynamic> m, String url, bool isVideo, double w, bool isMe, Widget? overlayMeta) {
    final mw = (m['width'] as num?)?.toDouble();
    final mh = (m['height'] as num?)?.toDouble();
    var ratio = (mw != null && mh != null && mw > 0 && mh > 0) ? mw / mh : 0.8;
    ratio = ratio.clamp(0.62, 1.2).toDouble();
    final h = w / ratio;
    final local = _localForMessage(m);
    final unlocked = local != null || isMe;
    final dur = (m['duration'] as num?)?.toInt();
    final notifier = _dlN.putIfAbsent(url, () => ValueNotifier<double?>(null));

    Widget base;
    if (unlocked) {
      if (isVideo) {
        base = _videoPoster(url, w, h);
      } else if (local != null) {
        base = Image.file(File(local), width: w, height: h, fit: BoxFit.cover);
      } else {
        base = CachedNetworkImage(
          imageUrl: url,
          width: w,
          height: h,
          fit: BoxFit.cover,
          placeholder: (_, __) => Container(width: w, height: h, color: Colors.black12),
          errorWidget: (_, __, ___) => Container(width: w, height: h, color: Colors.black12, child: const Icon(Icons.broken_image, color: Colors.grey)),
        );
      }
    } else {
      final blur = _blurThumbUrl(url, isVideo);
      base = ClipRect(
        child: ImageFiltered(
          imageFilter: ui.ImageFilter.blur(sigmaX: 12, sigmaY: 12),
          child: blur != null
              ? CachedNetworkImage(imageUrl: blur, width: w, height: h, fit: BoxFit.cover, errorWidget: (_, __, ___) => Container(width: w, height: h, color: Colors.blueGrey))
              : Container(width: w, height: h, color: Colors.blueGrey.shade700),
        ),
      );
    }

    return GestureDetector(
      onTap: _multiSelectMode
          ? null
          : () {
              if (unlocked) {
                _openViewer(m);
              } else if (notifier.value != null) {
                _cancelDownload(url);
              } else {
                _startMediaDownload(m);
              }
            },
      child: SizedBox(
        width: w,
        height: h,
        child: Stack(
          fit: StackFit.expand,
          children: [
            base,
            if (!unlocked) Center(child: _DownloadBadge(notifier: notifier)),
            if (unlocked && isVideo)
              Center(
                child: Container(
                  width: 48,
                  height: 48,
                  decoration: const BoxDecoration(color: Color(0x99000000), shape: BoxShape.circle),
                  child: const Icon(Icons.play_arrow_rounded, color: Colors.white, size: 32),
                ),
              ),
            if (isVideo && dur != null)
              Positioned(
                left: 6,
                top: 6,
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                  decoration: BoxDecoration(color: Colors.black.withOpacity(0.45), borderRadius: BorderRadius.circular(10)),
                  child: Text(_fmtDur(dur), style: const TextStyle(color: Colors.white, fontSize: 11)),
                ),
              ),
            if (overlayMeta != null) Positioned(right: 6, bottom: 6, child: overlayMeta),
          ],
        ),
      ),
    );
  }

  // ═══════════════════════════════════════════════════════════════════════
  // BUBBLE CONTENT (Telegram-style sizes)
  // ═══════════════════════════════════════════════════════════════════════
  Widget _quotedReply(Map<String, dynamic> m, {bool flushTop = true}) {
    final rid = m['reply_to']?.toString();
    final orig = _findMessage(rid);
    final name = (m['reply_to_sender'] ?? (orig != null ? _nameOf(orig['sender_id']?.toString()) : 'Message')).toString();
    final preview = orig != null ? _stripFormatting(_previewOf(orig)) : _stripFormatting((m['reply_to_content'] ?? 'Message').toString());
    final color = orig != null ? _colorForUid(orig['sender_id']?.toString()) : _kAccent;
    return GestureDetector(
      onTap: () => _jumpToMessage(rid),
      child: Container(
        margin: EdgeInsets.only(top: flushTop ? 0 : 4, bottom: 4),
        padding: const EdgeInsets.fromLTRB(10, 5, 10, 5),
        decoration: BoxDecoration(
          color: color.withOpacity(0.14),
          border: Border(left: BorderSide(color: color, width: 3.5)),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(name, maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(color: color, fontSize: 13, fontWeight: FontWeight.w700)),
            Text(preview, maxLines: 2, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 13)),
          ],
        ),
      ),
    );
  }

  List<Widget> _contentWidgets(
    Map<String, dynamic> m,
    bool isMe,
    ThemeData theme,
    bool isDark, {
    required double mediaW,
    required Widget overlayMeta,
    Widget? inlineMeta,
    double metaW = 0,
    double textTop = 6,
  }) {
    final type = (m['type'] ?? m['media_type'] ?? 'text').toString();
    final url = m['media_url']?.toString();
    final out = <Widget>[];
    final textColor = isMe && isDark ? Colors.white : theme.colorScheme.onSurface;
    final text = (m['text'] ?? '').toString();
    final bare = text.isEmpty;
    Widget padded(Widget w) => Padding(padding: EdgeInsets.fromLTRB(10, textTop, 10, 0), child: w);

    switch (type) {
      case 'image':
        if (url != null) out.add(_mediaTile(m, url, false, mediaW, isMe, bare ? overlayMeta : null));
        break;
      case 'video':
        if (url != null) out.add(_mediaTile(m, url, true, mediaW, isMe, bare ? overlayMeta : null));
        break;
      case 'gif':
        if (url != null) {
          out.add(SizedBox(
            width: mediaW,
            child: ConstrainedBox(
              constraints: BoxConstraints(maxHeight: mediaW * 1.25),
              child: Stack(
                children: [
                  CachedNetworkImage(imageUrl: url, width: mediaW, fit: BoxFit.cover),
                  Positioned(
                    left: 6,
                    top: 6,
                    child: Container(
                      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                      decoration: BoxDecoration(color: Colors.black.withOpacity(0.45), borderRadius: BorderRadius.circular(10)),
                      child: const Text('GIF', style: TextStyle(color: Colors.white, fontSize: 11, fontWeight: FontWeight.w700)),
                    ),
                  ),
                  if (bare) Positioned(right: 6, bottom: 6, child: overlayMeta),
                ],
              ),
            ),
          ));
        }
        break;
      case 'sticker':
        if (url != null) {
          out.add(GestureDetector(
            onTap: _multiSelectMode ? null : () => _showStickerPack(m),
            child: SizedBox(
              width: 150,
              height: 150,
              child: Stack(
                children: [
                  Positioned.fill(child: CachedNetworkImage(imageUrl: url, fit: BoxFit.contain)),
                  Positioned(right: 2, bottom: 2, child: overlayMeta),
                ],
              ),
            ),
          ));
        }
        break;
      case 'audio':
        if (url != null) out.add(padded(_buildAudioBubble(m, isMe, theme)));
        break;
      case 'file':
        if (url != null) out.add(padded(_buildFileBubble(m, theme)));
        break;
      case 'location':
      case 'live_location':
        if (m['latitude'] != null) out.add(padded(_buildLocationBubble(m)));
        break;
      case 'contact':
        out.add(padded(_buildContactBubble(m, theme)));
        break;
      default:
        break;
    }

    final hideText = type == 'location' || type == 'live_location' || type == 'contact';
    if (!hideText && text.isNotEmpty) {
      final names = (m['mention_names'] is List) ? (m['mention_names'] as List).map((e) => e.toString()).toList() : <String>[];
      final rich = _RichMessageText(
        text: text,
        style: TextStyle(color: textColor, fontSize: 15.5, height: 1.25),
        mentionNames: names,
        mentionColor: _kAccent,
        linkColor: _kAccent,
        trailingSpace: inlineMeta != null ? metaW : 0,
      );
      out.add(Padding(
        padding: EdgeInsets.fromLTRB(10, out.isEmpty ? textTop : 5, 10, inlineMeta != null ? 5 : 0),
        child: inlineMeta != null ? Stack(children: [rich, Positioned(right: 0, bottom: 0, child: inlineMeta)]) : rich,
      ));
      final link = type == 'text' ? _firstUrl(text) : null;
      if (link != null) {
        out.add(Padding(padding: const EdgeInsets.fromLTRB(10, 6, 10, 0), child: _LinkPreviewCard(url: link)));
      }
    }
    return out;
  }

  // ═══════════════════════════════════════════════════════════════════════
  // VIEWER ENTRY
  // ═══════════════════════════════════════════════════════════════════════
  Future<void> _openMedia(Map<String, dynamic> m) async {
    final url = m['media_url']?.toString();
    if (url == null) return;
    final type = (m['type'] ?? '').toString();
    if (type == 'image' || type == 'video') {
      if (_localForMessage(m) == null && m['sender_id'] != _currentUserId) {
        await _startMediaDownload(m);
        return;
      }
      _openViewer(m);
      return;
    }
    final ext = type == 'audio' ? 'm4a' : 'bin';
    try {
      final path = await _download(url, ext: ext, fileName: m['file_name']?.toString());
      if (path == null || !mounted) return;
      await OpenFilex.open(path);
    } catch (e) {
      _showSnack('Download failed: $e');
    }
  }

  void _openViewer(Map<String, dynamic> m) {
    final all = _visible.where((x) {
      final t = (x['type'] ?? '').toString();
      return (t == 'image' || t == 'video') && x['media_url'] != null && x['deleted_for_everyone'] != true;
    }).toList().reversed.toList();
    var idx = all.indexWhere((x) => x['id'] == m['id']);
    if (idx < 0) {
      all.add(m);
      idx = all.length - 1;
    }
    Navigator.push(
      context,
      PageRouteBuilder<void>(
        opaque: false,
        barrierColor: Colors.transparent,
        transitionDuration: const Duration(milliseconds: 200),
        pageBuilder: (_, __, ___) => _MediaViewerScreen(
          items: all,
          initialIndex: idx,
          nameOf: _nameOf,
          localPath: _localForMessage,
          ensureLocal: (x) async {
            final p = _localForMessage(x);
            if (p != null) return p;
            return _startMediaDownload(x);
          },
          canForward: _canForward,
          onForward: (x) => _forwardMessages([x]),
          canDelete: (x) => x['sender_id'] == _currentUserId || _isAdmin,
          onDelete: (x) async {
            final ok = await _confirm('Delete message?', 'This removes it for everyone in the group.');
            if (ok) await _deleteForEveryone(x['id'].toString());
            return ok;
          },
          onShowInChat: (x) => _jumpToMessage(x['id']?.toString()),
        ),
        transitionsBuilder: (_, a, __, child) => FadeTransition(opacity: a, child: child),
      ),
    );
  }

  // ═══════════════════════════════════════════════════════════════════════
  // CUSTOM GALLERY + EDITOR FLOWS
  // ═══════════════════════════════════════════════════════════════════════
  Future<List<AssetEntity>?> _pickFromCustomGallery({RequestType type = RequestType.common, bool multi = false, String title = 'Gallery'}) {
    return showModalBottomSheet<List<AssetEntity>>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => _GalleryPickerSheet(type: type, multi: multi, title: title),
    );
  }

  Future<void> _openEditorFromGallery(BuildContext sheetCtx, List<AssetEntity> assets, int start) async {
    final res = await Navigator.push<List<_EditedMedia>>(
      sheetCtx,
      MaterialPageRoute(fullscreenDialog: true, builder: (_) => _MediaEditorScreen(assets: assets, initialIndex: start)),
    );
    if (res == null || res.isEmpty) return;
    _selectedAssets.clear();
    if (sheetCtx.mounted) Navigator.pop(sheetCtx);
    _sendEdited(res);
  }

  Map<String, dynamic> _takeReplyFields() {
    final replyId = _replyingTo;
    if (replyId == null) return {};
    final reply = _findMessage(replyId);
    if (mounted) setState(() => _replyingTo = null);
    return {
      'reply_to': replyId,
      if (reply != null) 'reply_to_content': _stripFormatting(_previewOf(reply)),
      if (reply != null) 'reply_to_sender': _nameOf(reply['sender_id']?.toString()),
    };
  }

  Future<void> _sendEdited(List<_EditedMedia> list) async {
    if (list.isEmpty) return;
    final limit = _isMePremium ? (5 * 1024 * 1024 * 1024) : (200 * 1024 * 1024);
    var first = true;
    for (var i = 0; i < list.length; i++) {
      final e = list[i];
      try {
        final size = await e.file.length();
        if (size > limit) {
          _showSnack(_isMePremium ? 'Max 5GB' : 'Upgrade to Premium for >200MB');
          continue;
        }
        _showSnack('Uploading ${i + 1}/${list.length}...');
        var url = e.isVideo ? await CloudinaryService.uploadVideo(e.file, 'luma/groups') : await CloudinaryService.uploadImage(e.file, 'luma/groups');
        if (url == null) {
          _showSnack('Upload failed');
          continue;
        }
        if (e.isVideo) {
          final t = _videoTransform(e.trimStart, e.trimEnd, e.mute);
          if (t.isNotEmpty) url = _cldInsert(url, t);
        }
        final reply = first ? _takeReplyFields() : <String, dynamic>{};
        first = false;
        await _postMessage({
          'type': e.isVideo ? 'video' : 'image',
          'media_type': e.isVideo ? 'video' : 'image',
          'media_url': url,
          if (e.caption.isNotEmpty) 'text': e.caption,
          if (e.width > 0) 'width': e.width,
          if (e.height > 0) 'height': e.height,
          if (e.isVideo && e.duration > 0) 'duration': e.duration.round(),
          ...reply,
        });
      } catch (err) {
        _showSnack('Send failed: $err');
      }
    }
    if (mounted) ScaffoldMessenger.of(context).hideCurrentSnackBar();
  }

  // ═══════════════════════════════════════════════════════════════════════
  // CUSTOM STICKERS
  // ═══════════════════════════════════════════════════════════════════════
  Future<void> _createStickerFlow() async {
    final me = _currentUserId;
    if (me == null) return;
    final picked = await _pickFromCustomGallery(type: RequestType.common, title: 'New sticker');
    if (picked == null || picked.isEmpty || !mounted) return;
    final res = await Navigator.push<List<_EditedMedia>>(
      context,
      MaterialPageRoute(fullscreenDialog: true, builder: (_) => _MediaEditorScreen(assets: [picked.first], mode: 'sticker')),
    );
    if (res == null || res.isEmpty || !mounted) return;
    final e = res.first;
    _showSnack('Creating sticker…');
    String? url;
    if (e.isVideo) {
      final up = await CloudinaryService.uploadVideo(e.file, 'luma/stickers');
      if (up != null) url = _stickerGifUrl(up, e.trimStart, e.trimEnd > 0 ? e.trimEnd : math.min(3.0, e.duration));
    } else {
      url = await CloudinaryService.uploadImage(e.file, 'luma/stickers');
    }
    if (url == null) {
      _showSnack('Upload failed');
      return;
    }
    try {
      final packId = 'my_$me';
      final fs = FirebaseFirestore.instance;
      await fs.collection('sticker_packs').doc(packId).set({
        'title': 'My Stickers',
        'owner_id': me,
        'owner_name': _nameOf(me),
        'updated_at': FieldValue.serverTimestamp(),
        'stickers': FieldValue.arrayUnion([
          {'url': url, 'emoji': e.emoji, 'animated': e.isVideo},
        ]),
      }, SetOptions(merge: true));
      await fs.collection('user_settings').doc(me).set({'sticker_pack_ids': FieldValue.arrayUnion([packId])}, SetOptions(merge: true));
      if (!mounted) return;
      ScaffoldMessenger.of(context).hideCurrentSnackBar();
      _showSnack('Sticker added to My Stickers');
      setState(() => _activePanel = 'sticker');
    } catch (err) {
      _showSnack('Could not save sticker: $err');
    }
  }

  void _showStickerPack(Map<String, dynamic> m) {
    final url = m['media_url']?.toString();
    final me = _currentUserId;
    if (url == null || me == null) return;
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => _StickerPackSheet(
        packId: m['sticker_pack_id']?.toString(),
        singleUrl: url,
        uid: me,
        onSend: (u, p) => _sendSticker(u, packId: p),
      ),
    );
  }

  // ═══════════════════════════════════════════════════════════════════════
  // PROFILE MODAL (tap a member's avatar or name)
  // ═══════════════════════════════════════════════════════════════════════
  String _statusOf(Map<String, dynamic>? u) {
    if (u == null) return '';
    if (u[_kUserOnlineField] == true) return 'online';
    final ls = u['last_seen'] ?? u['last_active'];
    if (ls is Timestamp) {
      final d = ls.toDate();
      final diff = DateTime.now().difference(d);
      if (diff.inMinutes < 1) return 'last seen just now';
      if (diff.inHours < 1) return 'last seen ${diff.inMinutes} minutes ago';
      if (_sameDay(d, DateTime.now())) return 'last seen today at ${DateFormat('HH:mm').format(d)}';
      return 'last seen ${DateFormat('MMM d').format(d)}';
    }
    return 'last seen recently';
  }

  void _showUserProfile(String uid) {
    if (_multiSelectMode) return;
    FocusScope.of(context).unfocus();
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (ctx) => DraggableScrollableSheet(
        initialChildSize: 0.8,
        minChildSize: 0.45,
        maxChildSize: 0.97,
        expand: false,
        builder: (ctx, sc) => _profileBody(ctx, uid, sc),
      ),
    );
  }

  Future<void> _setMemberField(String uid, String field, Object? value) async {
    try {
      await _chatRef.update(<Object, Object?>{
        FieldPath(['participants_data', uid, field]): value,
      });
    } catch (e) {
      _showSnack('Failed: $e');
    }
  }

  Future<void> _removeMember(String uid) async {
    final ok = await _confirm('Remove from group?', '${_nameOf(uid)} will no longer receive messages from this group.', action: 'Remove');
    if (!ok) return;
    try {
      await _chatRef.update(<Object, Object?>{
        'participants': FieldValue.arrayRemove([uid]),
        FieldPath(['participants_data', uid]): FieldValue.delete(),
      });
      await _postMessage({
        'type': 'system',
        'media_type': 'system',
        'content': '${_nameOf(_currentUserId)} removed ${_nameOf(uid)}',
        'system_kind': 'remove',
      }, system: true);
    } catch (e) {
      _showSnack('Failed: $e');
    }
  }

  Widget _miniMediaTile(Map<String, dynamic> m) {
    final url = m['media_url'].toString();
    final isVideo = (m['type'] ?? '') == 'video';
    final local = _localForMessage(m);
    Widget img;
    if (local != null) {
      img = isVideo ? _videoPoster(url, 200, 200) : Image.file(File(local), fit: BoxFit.cover);
    } else {
      final b = _blurThumbUrl(url, isVideo);
      img = ImageFiltered(
        imageFilter: ui.ImageFilter.blur(sigmaX: 8, sigmaY: 8),
        child: b != null ? CachedNetworkImage(imageUrl: b, fit: BoxFit.cover) : Container(color: Colors.blueGrey),
      );
    }
    return GestureDetector(
      onTap: () => _openMedia(m),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(6),
        child: Stack(
          fit: StackFit.expand,
          children: [
            img,
            Center(
              child: Icon(local == null ? Icons.arrow_downward_rounded : (isVideo ? Icons.play_arrow_rounded : null), color: Colors.white, size: 26),
            ),
          ],
        ),
      ),
    );
  }

  Widget _profileAction(IconData icon, String label, VoidCallback onTap, Color card, {Color? color}) {
    return Expanded(
      child: GestureDetector(
        onTap: onTap,
        child: Container(
          margin: const EdgeInsets.symmetric(horizontal: 4),
          padding: const EdgeInsets.symmetric(vertical: 12),
          decoration: BoxDecoration(color: card, borderRadius: BorderRadius.circular(14)),
          child: Column(
            children: [
              Icon(icon, color: color ?? _kAccent, size: 24),
              const SizedBox(height: 4),
              Text(label, style: TextStyle(color: color ?? _kAccent, fontSize: 12, fontWeight: FontWeight.w600)),
            ],
          ),
        ),
      ),
    );
  }

  Widget _infoRow(String label, String value, {VoidCallback? onTap, Color? valueColor}) {
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(value, style: TextStyle(fontSize: 16, color: valueColor)),
            const SizedBox(height: 2),
            Text(label, style: TextStyle(fontSize: 12.5, color: Theme.of(context).colorScheme.onSurface.withOpacity(0.55))),
          ],
        ),
      ),
    );
  }

  Widget _profileBody(BuildContext ctx, String uid, ScrollController sc) {
    final theme = Theme.of(ctx);
    final isDark = theme.brightness == Brightness.dark;
    final bg = isDark ? const Color(0xFF0E1621) : const Color(0xFFF1F1F4);
    final card = isDark ? const Color(0xFF17212B) : Colors.white;
    return Container(
      decoration: BoxDecoration(color: bg, borderRadius: const BorderRadius.vertical(top: Radius.circular(22))),
      clipBehavior: Clip.antiAlias,
      child: StreamBuilder<DocumentSnapshot<Map<String, dynamic>>>(
        stream: FirebaseFirestore.instance.collection('users').doc(uid).snapshots(),
        builder: (c, snap) {
          return ValueListenableBuilder<int>(
            valueListenable: _infoTick,
            builder: (c2, _, __) {
              final u = snap.data?.data() ?? _userCache[uid] ?? <String, dynamic>{};
              final name = (u[_kUserNameField] ?? _nameOf(uid)).toString();
              final avatar = (u[_kUserAvatarField] is String && (u[_kUserAvatarField] as String).isNotEmpty) ? u[_kUserAvatarField] as String : null;
              final phone = (u[_kUserPhoneField] ?? u[_kUserPhoneLegacyField] ?? '').toString();
              final username = (u['username'] ?? '').toString();
              final bio = (u['bio'] ?? u['about'] ?? '').toString();
              final role = _roleOf(uid);
              final isMe = uid == _currentUserId;
              final targetIsMember = _memberIds().contains(uid);
              final canManage = _isAdmin && !isMe && targetIsMember && role != 'owner' && (role != 'admin' || _myRole == 'owner');
              final pdata = _chatData?['participants_data']?[uid];
              final mutedInGroup = pdata is Map && pdata['is_muted'] == true;
              final color = _colorForUid(uid);
              final media = _visible.where((x) => x['sender_id'] == uid && (x['type'] == 'image' || x['type'] == 'video') && x['media_url'] != null && x['deleted_for_everyone'] != true).toList();

              return ListView(
                controller: sc,
                padding: EdgeInsets.zero,
                children: [
                  GestureDetector(
                    onTap: avatar == null
                        ? null
                        : () => Navigator.push(
                              ctx,
                              MaterialPageRoute(
                                builder: (_) => Scaffold(
                                  backgroundColor: Colors.black,
                                  appBar: AppBar(backgroundColor: Colors.black, foregroundColor: Colors.white, title: Text(name)),
                                  body: Center(child: InteractiveViewer(maxScale: 5, child: CachedNetworkImage(imageUrl: avatar))),
                                ),
                              ),
                            ),
                    child: SizedBox(
                      height: 300,
                      child: Stack(
                        fit: StackFit.expand,
                        children: [
                          avatar != null
                              ? CachedNetworkImage(imageUrl: avatar, fit: BoxFit.cover)
                              : Container(
                                  decoration: BoxDecoration(gradient: LinearGradient(begin: Alignment.topLeft, end: Alignment.bottomRight, colors: [color, color.withOpacity(0.55)])),
                                  alignment: Alignment.center,
                                  child: Text(name.isNotEmpty ? name[0].toUpperCase() : '?', style: const TextStyle(color: Colors.white, fontSize: 96, fontWeight: FontWeight.w800)),
                                ),
                          Container(decoration: const BoxDecoration(gradient: LinearGradient(begin: Alignment.bottomCenter, end: Alignment.topCenter, colors: [Color(0xCC000000), Color(0x00000000)], stops: [0, 0.55]))),
                          Positioned(
                            top: 8,
                            right: 8,
                            child: IconButton(icon: const Icon(Icons.close, color: Colors.white), onPressed: () => Navigator.pop(ctx)),
                          ),
                          Positioned(
                            left: 18,
                            right: 18,
                            bottom: 16,
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Row(children: [
                                  Flexible(child: Text(isMe ? '$name (You)' : name, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(color: Colors.white, fontSize: 24, fontWeight: FontWeight.w800))),
                                  if (role == 'owner' || role == 'admin') ...[
                                    const SizedBox(width: 8),
                                    Container(
                                      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                                      decoration: BoxDecoration(color: Colors.white24, borderRadius: BorderRadius.circular(8)),
                                      child: Text(role == 'owner' ? 'owner' : 'admin', style: const TextStyle(color: Colors.white, fontSize: 11, fontWeight: FontWeight.w700)),
                                    ),
                                  ],
                                ]),
                                const SizedBox(height: 2),
                                Text(_statusOf(u), style: TextStyle(color: u[_kUserOnlineField] == true ? const Color(0xFF8BD0FF) : Colors.white70, fontSize: 14)),
                              ],
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(height: 10),
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 8),
                    child: Row(
                      children: [
                        if (!isMe && _hardBlockReason() == null)
                          _profileAction(Icons.alternate_email, 'Mention', () {
                            Navigator.pop(ctx);
                            _insertMention(uid);
                            _messageFocus.requestFocus();
                          }, card),
                        _profileAction(Icons.photo_library_outlined, 'Media', () {
                          Navigator.pop(ctx);
                          _openSearch(tab: 1);
                        }, card),
                        if (phone.isNotEmpty)
                          _profileAction(Icons.copy, 'Copy', () {
                            Clipboard.setData(ClipboardData(text: phone));
                            _showSnack('Number copied');
                          }, card),
                        if (canManage)
                          _profileAction(mutedInGroup ? Icons.volume_up_outlined : Icons.volume_off_outlined, mutedInGroup ? 'Unmute' : 'Mute', () {
                            _setMemberField(uid, 'is_muted', !mutedInGroup);
                          }, card),
                      ],
                    ),
                  ),
                  const SizedBox(height: 10),
                  if (phone.isNotEmpty || username.isNotEmpty || bio.isNotEmpty)
                    Container(
                      margin: const EdgeInsets.symmetric(horizontal: 10),
                      decoration: BoxDecoration(color: card, borderRadius: BorderRadius.circular(14)),
                      child: Column(
                        children: [
                          if (phone.isNotEmpty) _infoRow('Mobile', phone, onTap: () {
                            Clipboard.setData(ClipboardData(text: phone));
                            _showSnack('Number copied');
                          }),
                          if (username.isNotEmpty) _infoRow('Username', '@${username.replaceAll('@', '')}', valueColor: _kAccent),
                          if (bio.isNotEmpty) _infoRow('Bio', bio),
                        ],
                      ),
                    ),
                  if (canManage) ...[
                    const SizedBox(height: 10),
                    Container(
                      margin: const EdgeInsets.symmetric(horizontal: 10),
                      decoration: BoxDecoration(color: card, borderRadius: BorderRadius.circular(14)),
                      child: Column(
                        children: [
                          if (_myRole == 'owner')
                            ListTile(
                              leading: Icon(role == 'admin' ? Icons.remove_moderator_outlined : Icons.admin_panel_settings_outlined, color: _kAccent),
                              title: Text(role == 'admin' ? 'Dismiss as admin' : 'Promote to admin'),
                              onTap: () {
                                _setMemberField(uid, 'role', role == 'admin' ? 'member' : 'admin');
                                _postMessage({
                                  'type': 'system',
                                  'media_type': 'system',
                                  'content': role == 'admin' ? '${_nameOf(uid)} is no longer an admin' : '${_nameOf(uid)} is now an admin',
                                  'system_kind': 'role',
                                }, system: true);
                              },
                            ),
                          ListTile(
                            leading: const Icon(Icons.person_remove_outlined, color: Colors.red),
                            title: const Text('Remove from group', style: TextStyle(color: Colors.red)),
                            onTap: () {
                              Navigator.pop(ctx);
                              _removeMember(uid);
                            },
                          ),
                        ],
                      ),
                    ),
                  ],
                  const SizedBox(height: 10),
                  Container(
                    margin: const EdgeInsets.symmetric(horizontal: 10),
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(color: card, borderRadius: BorderRadius.circular(14)),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text('Shared media (${media.length})', style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w700)),
                        const SizedBox(height: 8),
                        if (media.isEmpty)
                          Text('Nothing shared in the loaded messages yet', style: TextStyle(color: theme.colorScheme.onSurface.withOpacity(0.55)))
                        else
                          GridView.count(
                            crossAxisCount: 3,
                            shrinkWrap: true,
                            physics: const NeverScrollableScrollPhysics(),
                            mainAxisSpacing: 4,
                            crossAxisSpacing: 4,
                            children: [for (final m in media.take(9)) _miniMediaTile(m)],
                          ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 28),
                ],
              );
            },
          );
        },
      ),
    );
  }

  // ═══════════════════════════════════════════════════════════════════════
  // GROUP INFO MODAL (+ working settings)
  // ═══════════════════════════════════════════════════════════════════════
  Future<void> _loadNotifMuted() async {
    try {
      final doc = await FirebaseFirestore.instance.collection('user_settings').doc(_currentUserId).get();
      final l = doc.data()?['muted_chats'];
      if (l is List && mounted) {
        setState(() => _notifMuted = l.map((e) => e.toString()).contains(widget.chatId));
        _infoTick.value++;
      }
    } catch (_) {}
  }

  Future<void> _toggleNotifMute() async {
    final me = _currentUserId;
    if (me == null) return;
    final next = !_notifMuted;
    setState(() => _notifMuted = next);
    _infoTick.value++;
    try {
      await FirebaseFirestore.instance.collection('user_settings').doc(me).set({
        'muted_chats': next ? FieldValue.arrayUnion([widget.chatId]) : FieldValue.arrayRemove([widget.chatId]),
      }, SetOptions(merge: true));
    } catch (e) {
      _showSnack('Failed: $e');
    }
  }

  Future<void> _chatUpdate(Map<String, Object?> data) async {
    try {
      await _chatRef.update(data);
    } catch (e) {
      _showSnack('Could not update: $e');
    }
  }

  Future<String?> _promptText(String title, String initial, {int maxLines = 1, int maxLength = 100}) async {
    final ctrl = TextEditingController(text: initial);
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(title),
        content: TextField(controller: ctrl, autofocus: true, maxLines: maxLines, minLines: 1, maxLength: maxLength),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          TextButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Save')),
        ],
      ),
    );
    return ok == true ? ctrl.text.trim() : null;
  }

  Future<void> _changeGroupPhoto() async {
    final picked = await _pickFromCustomGallery(type: RequestType.image, title: 'Group photo');
    if (picked == null || picked.isEmpty || !mounted) return;
    final res = await Navigator.push<List<_EditedMedia>>(
      context,
      MaterialPageRoute(fullscreenDialog: true, builder: (_) => _MediaEditorScreen(assets: [picked.first], mode: 'avatar')),
    );
    if (res == null || res.isEmpty) return;
    _showSnack('Uploading photo…');
    final url = await CloudinaryService.uploadImage(res.first.file, 'luma/group_avatars');
    if (url == null) {
      _showSnack('Upload failed');
      return;
    }
    await _chatUpdate({'avatar_url': url});
    await _postMessage({'type': 'system', 'media_type': 'system', 'content': '${_nameOf(_currentUserId)} changed the group photo', 'system_kind': 'photo'}, system: true);
    if (mounted) ScaffoldMessenger.of(context).hideCurrentSnackBar();
  }

  Future<void> _pickSlowMode() async {
    const opts = <int, String>{0: 'Off', 10: '10 seconds', 30: '30 seconds', 60: '1 minute', 300: '5 minutes', 900: '15 minutes', 3600: '1 hour'};
    final v = await showDialog<int>(
      context: context,
      builder: (ctx) => SimpleDialog(
        title: const Text('Slow mode'),
        children: [
          for (final e in opts.entries)
            SimpleDialogOption(
              onPressed: () => Navigator.pop(ctx, e.key),
              child: Row(children: [
                Expanded(child: Text(e.value)),
                if (_slowSeconds == e.key) const Icon(Icons.check, color: _kAccent),
              ]),
            ),
        ],
      ),
    );
    if (v != null) await _chatUpdate({'slow_mode_seconds': v});
  }

  Future<void> _showAddMembers() async {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final selected = <_LumaContact>[];
    final existing = _memberIds().toSet();
    final future = _loadLumaContacts();
    await showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setS) => Container(
          height: MediaQuery.of(ctx).size.height * 0.75,
          decoration: BoxDecoration(color: isDark ? const Color(0xFF17212B) : Colors.white, borderRadius: const BorderRadius.vertical(top: Radius.circular(22))),
          child: Column(
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 14, 8, 6),
                child: Row(
                  children: [
                    const Expanded(child: Text('Add members', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w800))),
                    if (selected.isNotEmpty)
                      TextButton(
                        onPressed: () async {
                          Navigator.pop(ctx);
                          final updates = <Object, Object?>{'participants': FieldValue.arrayUnion(selected.map((c) => c.uid).toList())};
                          for (final c in selected) {
                            updates[FieldPath(['participants_data', c.uid])] = {'role': 'member'};
                          }
                          try {
                            await _chatRef.update(updates);
                            await _postMessage({
                              'type': 'system',
                              'media_type': 'system',
                              'content': '${_nameOf(_currentUserId)} added ${selected.map((c) => c.name).join(', ')}',
                              'system_kind': 'add',
                            }, system: true);
                          } catch (e) {
                            _showSnack('Failed: $e');
                          }
                        },
                        child: Text('Add (${selected.length})'),
                      ),
                  ],
                ),
              ),
              Expanded(
                child: FutureBuilder<List<_LumaContact>>(
                  future: future,
                  builder: (c, snap) {
                    if (snap.connectionState == ConnectionState.waiting) return const Center(child: CircularProgressIndicator());
                    if (snap.hasError) return const Center(child: Padding(padding: EdgeInsets.all(24), child: Text('Allow contacts access to find people on Luma Chat')));
                    final list = (snap.data ?? []).where((x) => !existing.contains(x.uid)).toList();
                    if (list.isEmpty) return const Center(child: Text('No more contacts to add'));
                    return ListView.builder(
                      itemCount: list.length,
                      itemBuilder: (_, i) {
                        final x = list[i];
                        final on = selected.any((e) => e.uid == x.uid);
                        return CheckboxListTile(
                          value: on,
                          onChanged: (v) => setS(() => v == true ? selected.add(x) : selected.removeWhere((e) => e.uid == x.uid)),
                          secondary: CircleAvatar(backgroundImage: x.avatar != null ? CachedNetworkImageProvider(x.avatar!) : null, child: x.avatar == null ? Text(x.name.isNotEmpty ? x.name[0].toUpperCase() : '?') : null),
                          title: Text(x.name),
                          subtitle: Text(x.phone),
                        );
                      },
                    );
                  },
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  void _showGroupInfoSheet() {
    FocusScope.of(context).unfocus();
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (ctx) => DraggableScrollableSheet(
        initialChildSize: 0.93,
        minChildSize: 0.5,
        maxChildSize: 0.98,
        expand: false,
        builder: (ctx, sc) => _groupInfoBody(ctx, sc),
      ),
    );
  }

  Widget _infoSwitch(String title, String sub, bool value, ValueChanged<bool> onChanged) {
    return SwitchListTile(title: Text(title), subtitle: Text(sub, style: const TextStyle(fontSize: 12.5)), value: value, onChanged: onChanged);
  }

  Widget _groupInfoBody(BuildContext ctx, ScrollController sc) {
    final theme = Theme.of(ctx);
    final isDark = theme.brightness == Brightness.dark;
    final bg = isDark ? const Color(0xFF0E1621) : const Color(0xFFF1F1F4);
    final card = isDark ? const Color(0xFF17212B) : Colors.white;
    final dim = theme.colorScheme.onSurface.withOpacity(0.55);

    return ValueListenableBuilder<int>(
      valueListenable: _infoTick,
      builder: (c, _, __) {
        final name = _groupName();
        final avatar = _groupAvatar();
        final desc = (_chatData?['description'] ?? _chatData?['about'] ?? '').toString();
        final ids = _memberIds();
        int rank(String u) => _roleOf(u) == 'owner' ? 0 : (_roleOf(u) == 'admin' ? 1 : 2);
        ids.sort((a, b) {
          final r = rank(a).compareTo(rank(b));
          return r != 0 ? r : _nameOf(a).toLowerCase().compareTo(_nameOf(b).toLowerCase());
        });
        final code = (_chatData?['invite_code'] ?? '').toString();
        final canAdd = _isAdmin || _chatData?['members_can_invite'] == true;

        Widget section(List<Widget> kids) => Container(
              margin: const EdgeInsets.fromLTRB(10, 0, 10, 10),
              decoration: BoxDecoration(color: card, borderRadius: BorderRadius.circular(14)),
              clipBehavior: Clip.antiAlias,
              child: Column(children: kids),
            );

        return Container(
          decoration: BoxDecoration(color: bg, borderRadius: const BorderRadius.vertical(top: Radius.circular(22))),
          clipBehavior: Clip.antiAlias,
          child: ListView(
            controller: sc,
            padding: EdgeInsets.zero,
            children: [
              Container(
                color: card,
                padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
                margin: const EdgeInsets.only(bottom: 10),
                child: Column(
                  children: [
                    Row(
                      children: [
                        IconButton(icon: const Icon(Icons.close), onPressed: () => Navigator.pop(ctx)),
                        const Spacer(),
                        if (_isAdmin)
                          IconButton(
                            icon: const Icon(Icons.edit_outlined),
                            tooltip: 'Edit name',
                            onPressed: () async {
                              final v = await _promptText('Group name', name, maxLength: 60);
                              if (v != null && v.isNotEmpty && v != name) {
                                await _chatUpdate({'name': v});
                                _postMessage({'type': 'system', 'media_type': 'system', 'content': '${_nameOf(_currentUserId)} changed the group name to "$v"', 'system_kind': 'rename'}, system: true);
                              }
                            },
                          ),
                      ],
                    ),
                    GestureDetector(
                      onTap: _isAdmin
                          ? _changeGroupPhoto
                          : (avatar == null
                              ? null
                              : () => Navigator.push(
                                    ctx,
                                    MaterialPageRoute(
                                      builder: (_) => Scaffold(
                                        backgroundColor: Colors.black,
                                        appBar: AppBar(backgroundColor: Colors.black, foregroundColor: Colors.white, title: Text(name)),
                                        body: Center(child: InteractiveViewer(maxScale: 5, child: CachedNetworkImage(imageUrl: avatar))),
                                      ),
                                    ),
                                  )),
                      child: Stack(
                        children: [
                          CircleAvatar(
                            radius: 48,
                            backgroundColor: _kAccent.withOpacity(0.15),
                            backgroundImage: avatar != null ? CachedNetworkImageProvider(avatar) : null,
                            child: avatar == null ? Text(name.isNotEmpty ? name[0].toUpperCase() : '?', style: const TextStyle(color: _kAccent, fontSize: 40, fontWeight: FontWeight.w800)) : null,
                          ),
                          if (_isAdmin)
                            Positioned(
                              right: 0,
                              bottom: 0,
                              child: Container(
                                padding: const EdgeInsets.all(6),
                                decoration: const BoxDecoration(color: _kAccent, shape: BoxShape.circle),
                                child: const Icon(Icons.camera_alt, color: Colors.white, size: 16),
                              ),
                            ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 10),
                    Text(name, textAlign: TextAlign.center, style: const TextStyle(fontSize: 22, fontWeight: FontWeight.w800)),
                    const SizedBox(height: 2),
                    Text('${ids.length} member${ids.length == 1 ? '' : 's'}${_onlineCount > 0 ? ', $_onlineCount online' : ''}', style: TextStyle(color: dim)),
                    const SizedBox(height: 14),
                    Row(
                      children: [
                        _profileAction(_notifMuted ? Icons.notifications_off_outlined : Icons.notifications_none, _notifMuted ? 'Unmute' : 'Mute', _toggleNotifMute, bg),
                        _profileAction(Icons.search, 'Search', () {
                          Navigator.pop(ctx);
                          _openSearch();
                        }, bg),
                        if (canAdd) _profileAction(Icons.person_add_alt_1_outlined, 'Add', _showAddMembers, bg),
                        if (_isMember)
                          _profileAction(Icons.exit_to_app, 'Leave', () {
                            Navigator.pop(ctx);
                            _leaveGroup();
                          }, bg, color: Colors.red),
                      ],
                    ),
                  ],
                ),
              ),
              section([
                ListTile(
                  title: Text(desc.isEmpty ? (_isAdmin ? 'Add description' : 'No description') : desc),
                  subtitle: const Text('Description'),
                  trailing: _isAdmin ? const Icon(Icons.edit_outlined, size: 18) : null,
                  onTap: _isAdmin
                      ? () async {
                          final v = await _promptText('Description', desc, maxLines: 5, maxLength: 255);
                          if (v != null) await _chatUpdate({'description': v});
                        }
                      : null,
                ),
                if (code.isNotEmpty || _isAdmin)
                  ListTile(
                    leading: const Icon(Icons.link, color: _kAccent),
                    title: Text(code.isEmpty ? 'Create invite code' : code),
                    subtitle: Text(code.isEmpty ? 'Let people join with a code' : 'Invite code · tap to copy'),
                    trailing: (_isAdmin && code.isNotEmpty)
                        ? IconButton(
                            icon: const Icon(Icons.refresh),
                            tooltip: 'Revoke and create a new code',
                            onPressed: () => _chatUpdate({'invite_code': const Uuid().v4().replaceAll('-', '').substring(0, 10)}),
                          )
                        : null,
                    onTap: () {
                      if (code.isEmpty) {
                        if (_isAdmin) _chatUpdate({'invite_code': const Uuid().v4().replaceAll('-', '').substring(0, 10)});
                      } else {
                        Clipboard.setData(ClipboardData(text: code));
                        _showSnack('Invite code copied');
                      }
                    },
                  ),
              ]),
              section([
                ListTile(leading: const Icon(Icons.photo_library_outlined, color: _kAccent), title: const Text('Media'), trailing: const Icon(Icons.chevron_right), onTap: () { Navigator.pop(ctx); _openSearch(tab: 1); }),
                ListTile(leading: const Icon(Icons.link, color: _kAccent), title: const Text('Links'), trailing: const Icon(Icons.chevron_right), onTap: () { Navigator.pop(ctx); _openSearch(tab: 2); }),
                ListTile(leading: const Icon(Icons.insert_drive_file_outlined, color: _kAccent), title: const Text('Files'), trailing: const Icon(Icons.chevron_right), onTap: () { Navigator.pop(ctx); _openSearch(tab: 3); }),
                ListTile(leading: const Icon(Icons.wallpaper, color: _kAccent), title: const Text('Chat wallpaper'), trailing: const Icon(Icons.chevron_right), onTap: () { Navigator.pop(ctx); _showWallpaperSheet(); }),
              ]),
              if (_isAdmin)
                section([
                  const Padding(padding: EdgeInsets.fromLTRB(16, 12, 16, 0), child: Align(alignment: Alignment.centerLeft, child: Text('Group settings', style: TextStyle(color: _kAccent, fontWeight: FontWeight.w800)))),
                  _infoSwitch('Only admins can send', 'Members can read but not write', _locked, (v) => _chatUpdate({'is_locked': v})),
                  ListTile(
                    title: const Text('Slow mode'),
                    subtitle: Text(_slowSeconds == 0 ? 'Off' : '${_slowSeconds >= 60 ? '${_slowSeconds ~/ 60} min' : '$_slowSeconds s'} between messages'),
                    trailing: const Icon(Icons.chevron_right),
                    onTap: _pickSlowMode,
                  ),
                  _infoSwitch('Members can pin messages', 'Otherwise only admins can pin', _chatData?['members_can_pin'] == true, (v) => _chatUpdate({'members_can_pin': v})),
                  _infoSwitch('Members can edit messages', 'Allow editing own text messages', _chatData?['members_can_edit'] != false, (v) => _chatUpdate({'members_can_edit': v})),
                  _infoSwitch('Members can add people', 'Allow members to add contacts', _chatData?['members_can_invite'] == true, (v) => _chatUpdate({'members_can_invite': v})),
                  _infoSwitch('Restrict forwarding', 'Only admins can forward messages', _chatData?['restrict_forwarding'] == true, (v) => _chatUpdate({'restrict_forwarding': v})),
                ]),
              Padding(
                padding: const EdgeInsets.fromLTRB(18, 4, 18, 6),
                child: Text('${ids.length} MEMBERS', style: TextStyle(color: dim, fontSize: 12.5, fontWeight: FontWeight.w700)),
              ),
              section([
                if (canAdd) ListTile(leading: const CircleAvatar(backgroundColor: _kAccent, child: Icon(Icons.person_add, color: Colors.white)), title: const Text('Add members', style: TextStyle(color: _kAccent, fontWeight: FontWeight.w700)), onTap: _showAddMembers),
                for (final uid in ids)
                  ListTile(
                    leading: Stack(
                      children: [
                        CircleAvatar(
                          backgroundColor: _colorForUid(uid).withOpacity(0.25),
                          backgroundImage: _avatarOf(uid) != null ? CachedNetworkImageProvider(_avatarOf(uid)!) : null,
                          child: _avatarOf(uid) == null ? Text(_nameOf(uid).isNotEmpty ? _nameOf(uid)[0].toUpperCase() : '?', style: TextStyle(color: _colorForUid(uid), fontWeight: FontWeight.w800)) : null,
                        ),
                        if (_userCache[uid]?[_kUserOnlineField] == true)
                          Positioned(right: 0, bottom: 0, child: Container(width: 12, height: 12, decoration: BoxDecoration(color: const Color(0xFF34C759), shape: BoxShape.circle, border: Border.all(color: card, width: 2)))),
                      ],
                    ),
                    title: Text(uid == _currentUserId ? '${_nameOf(uid)} (You)' : _nameOf(uid)),
                    subtitle: Text(_statusOf(_userCache[uid]), style: TextStyle(color: _userCache[uid]?[_kUserOnlineField] == true ? _kAccent : dim, fontSize: 12.5)),
                    trailing: _roleOf(uid) == 'member' ? null : Text(_roleOf(uid) == 'owner' ? 'owner' : 'admin', style: const TextStyle(color: _kAccent, fontSize: 12, fontWeight: FontWeight.w700)),
                    onTap: () => _showUserProfile(uid),
                  ),
              ]),
              const SizedBox(height: 24),
            ],
          ),
        );
      },
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
              onSelect: () => setModalState(() {
                if (selIndex >= 0) {
                  _selectedAssets.removeAt(selIndex);
                } else {
                  _selectedAssets.add(a);
                }
              }),
              onTap: () {
                // Tapping the picture (not the circle) opens the editor.
                final list = List<AssetEntity>.from(_selectedAssets);
                var start = list.indexWhere((e) => e.id == a.id);
                if (start < 0) {
                  list.add(a);
                  start = list.length - 1;
                }
                _openEditorFromGallery(context, list, start);
              },
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
// RICH TEXT (bold / italic / mono / spoiler / links / @mentions)
// ═══════════════════════════════════════════════════════════════════════════
class _RichMessageText extends StatefulWidget {
  final String text;
  final TextStyle style;
  final List<String> mentionNames;
  final Color mentionColor;
  final Color linkColor;
  final double trailingSpace;

  const _RichMessageText({
    this.trailingSpace = 0,
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
    return Text.rich(TextSpan(children: [
      ..._parse(widget.text, widget.style),
      if (widget.trailingSpace > 0) WidgetSpan(child: SizedBox(width: widget.trailingSpace, height: 1)),
    ]));
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
    final w = math.max(1.5, (size.width - gap * (n - 1)) / n);
    for (var i = 0; i < n; i++) {
      final h = math.max(4.0, _c01(b[i]) * size.height);
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
// IN-CHAT SEARCH (Messages / Media / Links / Files / Members)
// ═══════════════════════════════════════════════════════════════════════════
class _GroupSearchScreen extends StatefulWidget {
  final int initialTab;
  final List<Map<String, dynamic>> Function() getMessages;
  final Future<bool> Function() loadOlder;
  final bool Function() hasMore;
  final String Function(String? uid) nameOf;
  final String? Function(String? uid) avatarOf;
  final List<String> memberIds;
  final String Function(String uid) roleOf;
  final bool Function(String uid) isOnline;
  final String? meId;

  const _GroupSearchScreen({
    required this.initialTab,
    required this.getMessages,
    required this.loadOlder,
    required this.hasMore,
    required this.nameOf,
    required this.avatarOf,
    required this.memberIds,
    required this.roleOf,
    required this.isOnline,
    required this.meId,
  });

  @override
  State<_GroupSearchScreen> createState() => _GroupSearchScreenState();
}

class _GroupSearchScreenState extends State<_GroupSearchScreen> with SingleTickerProviderStateMixin {
  late final TabController _tabs = TabController(length: 5, vsync: this, initialIndex: widget.initialTab.clamp(0, 4));
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
      backgroundImage: a != null ? CachedNetworkImageProvider(a) : null,
      child: a == null ? Text(name.isNotEmpty ? name[0].toUpperCase() : '?', style: TextStyle(color: _colorForUid(uid))) : null,
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

  Widget _membersTab() {
    final q = _q;
    final ids = widget.memberIds.where((uid) => q.isEmpty || widget.nameOf(uid).toLowerCase().contains(q)).toList();
    return ListView(
      children: [
        if (ids.isEmpty) Padding(padding: const EdgeInsets.all(32), child: _hint('No members found')),
        ...ids.map((uid) {
          final role = widget.roleOf(uid);
          return ListTile(
            leading: Stack(children: [
              _avatar(uid),
              if (widget.isOnline(uid))
                Positioned(
                  right: 0,
                  bottom: 0,
                  child: Container(
                    width: 10,
                    height: 10,
                    decoration: BoxDecoration(color: Colors.green, shape: BoxShape.circle, border: Border.all(color: Colors.white, width: 1.5)),
                  ),
                ),
            ]),
            title: Text(uid == widget.meId ? '${widget.nameOf(uid)} (you)' : widget.nameOf(uid)),
            subtitle: widget.isOnline(uid) ? const Text('online', style: TextStyle(color: Colors.green, fontSize: 12)) : null,
            trailing: (role == 'owner' || role == 'admin')
                ? Container(
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                    decoration: BoxDecoration(color: _kAccent.withOpacity(0.15), borderRadius: BorderRadius.circular(8)),
                    child: Text(role, style: const TextStyle(color: _kAccent, fontSize: 11, fontWeight: FontWeight.w700)),
                  )
                : null,
            onTap: uid == widget.meId ? null : () => Navigator.pop(context, 'mention:$uid'),
          );
        }),
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
          isScrollable: true,
          tabs: const [Tab(text: 'Messages'), Tab(text: 'Media'), Tab(text: 'Links'), Tab(text: 'Files'), Tab(text: 'Members')],
        ),
      ),
      body: TabBarView(
        controller: _tabs,
        children: [_messagesTab(), _mediaTab(), _linksTab(), _filesTab(), _membersTab()],
      ),
    );
  }
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
  final VoidCallback? onSelect;
  final bool showCircle;
  const _AssetThumb({super.key, required this.entity, required this.selectedIndex, required this.onTap, this.onSelect, this.showCircle = true});

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
          if (widget.showCircle)
            Positioned(
              top: 0,
              right: 0,
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: widget.onSelect ?? widget.onTap,
                child: Padding(
                  padding: const EdgeInsets.all(6),
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

// ═══════════════════════════════════════════════════════════════════════════
// FIX PACK HELPERS (stable hashing, Cloudinary URL transforms, waveforms)
// ═══════════════════════════════════════════════════════════════════════════
int _stableHash(String s) {
  var h = 0x811C9DC5;
  for (final c in s.codeUnits) {
    h ^= c;
    h = (h * 0x01000193) & 0xFFFFFFFF;
  }
  return h;
}

bool _isCloudinary(String url) => url.contains('res.cloudinary.com') && url.contains('/upload/');

String _cldInsert(String url, String transform) {
  const k = '/upload/';
  if (!_isCloudinary(url) || transform.isEmpty) return url;
  final i = url.indexOf(k);
  return '${url.substring(0, i + k.length)}$transform/${url.substring(i + k.length)}';
}

String _swapExt(String url, String ext) {
  final dot = url.lastIndexOf('.');
  if (dot > url.lastIndexOf('/')) return '${url.substring(0, dot)}.$ext';
  return '$url.$ext';
}

/// Tiny, already-blurred preview used by the "download before view" tile.
String? _blurThumbUrl(String url, bool isVideo) {
  if (!_isCloudinary(url)) return null;
  final u = _cldInsert(url, isVideo ? 'so_0,w_48,q_20,e_blur:900' : 'w_48,q_20,e_blur:900');
  return isVideo ? _swapExt(u, 'jpg') : u;
}

String? _videoPosterUrl(String url) {
  if (!_isCloudinary(url)) return null;
  return _swapExt(_cldInsert(url, 'so_0,w_480'), 'jpg');
}

String _videoTransform(double start, double end, bool mute) {
  final parts = <String>[];
  if (start > 0.05) parts.add('so_${start.toStringAsFixed(1)}');
  if (end > 0.05) parts.add('eo_${end.toStringAsFixed(1)}');
  if (mute) parts.add('ac_none');
  return parts.join(',');
}

String _stickerGifUrl(String url, double start, double end) {
  final t = 'so_${start.toStringAsFixed(1)},eo_${end.toStringAsFixed(1)},w_512,h_512,c_fill,fps_15';
  return _swapExt(_cldInsert(url, t), 'gif');
}

/// Natural-looking pseudo waveform (used whenever a voice note has no stored one).
List<double> _seedWave(String seed, {int n = 40}) {
  final r = math.Random(_stableHash(seed));
  final out = <double>[];
  var prev = 0.5;
  for (var i = 0; i < n; i++) {
    prev = _c01(prev * 0.45 + r.nextDouble() * 0.75 + 0.06);
    out.add(math.max(0.14, prev));
  }
  return out;
}

// ═══════════════════════════════════════════════════════════════════════════
// DOWNLOAD BADGE (blur tile centre: download icon -> circular progress)
// ═══════════════════════════════════════════════════════════════════════════
class _DownloadBadge extends StatelessWidget {
  final ValueNotifier<double?> notifier;
  const _DownloadBadge({required this.notifier});

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<double?>(
      valueListenable: notifier,
      builder: (_, v, __) {
        final busy = v != null;
        return Container(
          width: 52,
          height: 52,
          decoration: const BoxDecoration(color: Color(0x99000000), shape: BoxShape.circle),
          child: Stack(
            alignment: Alignment.center,
            children: [
              if (busy)
                SizedBox(
                  width: 46,
                  height: 46,
                  child: CircularProgressIndicator(
                    value: v! <= 0.03 ? null : v,
                    strokeWidth: 2.6,
                    color: Colors.white,
                    backgroundColor: Colors.white24,
                  ),
                ),
              Icon(busy ? Icons.close_rounded : Icons.arrow_downward_rounded, color: Colors.white, size: 26),
            ],
          ),
        );
      },
    );
  }
}

// ═══════════════════════════════════════════════════════════════════════════
// CUSTOM GALLERY PICKER (used for stickers, wallpaper, group photo)
// ═══════════════════════════════════════════════════════════════════════════
class _GalleryPickerSheet extends StatefulWidget {
  final RequestType type;
  final bool multi;
  final String title;
  const _GalleryPickerSheet({required this.type, required this.multi, required this.title});

  @override
  State<_GalleryPickerSheet> createState() => _GalleryPickerSheetState();
}

class _GalleryPickerSheetState extends State<_GalleryPickerSheet> {
  List<AssetPathEntity> _albums = [];
  AssetPathEntity? _album;
  final List<AssetEntity> _assets = [];
  final List<AssetEntity> _sel = [];
  final _sc = ScrollController();
  bool _loading = true;
  bool _loadingMore = false;
  bool _more = true;
  int _page = 0;
  String? _error;

  @override
  void initState() {
    super.initState();
    _sc.addListener(() {
      if (_sc.hasClients && _sc.position.pixels > _sc.position.maxScrollExtent - 700) _loadPage();
    });
    _init();
  }

  @override
  void dispose() {
    _sc.dispose();
    super.dispose();
  }

  Future<void> _init() async {
    try {
      final ps = await PhotoManager.requestPermissionExtend().timeout(const Duration(seconds: 45));
      if (!ps.hasAccess) throw Exception('denied');
      final paths = await PhotoManager.getAssetPathList(type: widget.type).timeout(const Duration(seconds: 20));
      if (!mounted) return;
      if (paths.isEmpty) {
        setState(() => _loading = false);
        return;
      }
      _albums = paths;
      _album = paths.first;
      await _loadPage(reset: true);
    } catch (_) {
      if (mounted) {
        setState(() {
          _loading = false;
          _error = 'Allow access to your photos and videos';
        });
      }
    }
  }

  Future<void> _loadPage({bool reset = false}) async {
    final a = _album;
    if (a == null || _loadingMore) return;
    if (reset) {
      _page = 0;
      _more = true;
      _assets.clear();
    }
    if (!_more) return;
    _loadingMore = true;
    try {
      final list = await a.getAssetListPaged(page: _page, size: 90);
      _page++;
      if (list.length < 90) _more = false;
      if (mounted) {
        setState(() {
          _assets.addAll(list);
          _loading = false;
        });
      }
    } catch (_) {
      if (mounted) setState(() => _loading = false);
    }
    _loadingMore = false;
  }

  void _toggle(AssetEntity a) {
    if (!widget.multi) {
      Navigator.pop(context, <AssetEntity>[a]);
      return;
    }
    setState(() {
      final i = _sel.indexWhere((e) => e.id == a.id);
      if (i >= 0) {
        _sel.removeAt(i);
      } else {
        _sel.add(a);
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final bg = isDark ? const Color(0xFF17212B) : Colors.white;
    return Container(
      height: MediaQuery.of(context).size.height * 0.88,
      decoration: BoxDecoration(color: bg, borderRadius: const BorderRadius.vertical(top: Radius.circular(24))),
      clipBehavior: Clip.antiAlias,
      child: Column(
        children: [
          Container(
            margin: const EdgeInsets.only(top: 10, bottom: 4),
            height: 4,
            width: 40,
            decoration: BoxDecoration(color: Colors.grey[400], borderRadius: BorderRadius.circular(2)),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(4, 0, 8, 0),
            child: Row(
              children: [
                IconButton(icon: const Icon(Icons.close), onPressed: () => Navigator.pop(context)),
                Expanded(
                  child: _albums.length > 1 && _album != null
                      ? DropdownButtonHideUnderline(
                          child: DropdownButton<AssetPathEntity>(
                            value: _album,
                            isExpanded: true,
                            items: [
                              for (final a in _albums)
                                DropdownMenuItem(value: a, child: Text(a.isAll ? widget.title : a.name, maxLines: 1, overflow: TextOverflow.ellipsis)),
                            ],
                            onChanged: (a) {
                              if (a == null) return;
                              setState(() {
                                _album = a;
                                _loading = true;
                              });
                              _loadPage(reset: true);
                            },
                          ),
                        )
                      : Text(widget.title, style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w700)),
                ),
                if (widget.multi && _sel.isNotEmpty)
                  TextButton(
                    onPressed: () => Navigator.pop(context, List<AssetEntity>.from(_sel)),
                    child: Text('Next (${_sel.length})', style: const TextStyle(fontWeight: FontWeight.w700)),
                  ),
              ],
            ),
          ),
          Expanded(
            child: _loading
                ? const Center(child: CircularProgressIndicator())
                : _error != null
                    ? Center(
                        child: Column(mainAxisSize: MainAxisSize.min, children: [
                          const Icon(Icons.photo_library_outlined, size: 48, color: Colors.grey),
                          const SizedBox(height: 8),
                          Text(_error!),
                          TextButton(onPressed: () async => await PhotoManager.openSetting(), child: const Text('Open settings')),
                        ]),
                      )
                    : _assets.isEmpty
                        ? const Center(child: Text('Nothing here yet'))
                        : GridView.builder(
                            controller: _sc,
                            padding: const EdgeInsets.all(2),
                            gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(crossAxisCount: 3, crossAxisSpacing: 2, mainAxisSpacing: 2),
                            itemCount: _assets.length,
                            itemBuilder: (_, i) {
                              final a = _assets[i];
                              final idx = _sel.indexWhere((e) => e.id == a.id);
                              return _AssetThumb(
                                key: ValueKey(a.id),
                                entity: a,
                                selectedIndex: idx,
                                showCircle: widget.multi,
                                onTap: () => _toggle(a),
                              );
                            },
                          ),
          ),
        ],
      ),
    );
  }
}

// ═══════════════════════════════════════════════════════════════════════════
// MEDIA VIEWER  (swipe between photos/videos, zoom, swipe-down to close,
//                forward / save / open-with / delete / show in chat)
// ═══════════════════════════════════════════════════════════════════════════
class _MediaViewerScreen extends StatefulWidget {
  final List<Map<String, dynamic>> items;
  final int initialIndex;
  final String Function(String? uid) nameOf;
  final String? Function(Map<String, dynamic> m) localPath;
  final Future<String?> Function(Map<String, dynamic> m) ensureLocal;
  final bool canForward;
  final void Function(Map<String, dynamic> m) onForward;
  final bool Function(Map<String, dynamic> m) canDelete;
  final Future<bool> Function(Map<String, dynamic> m) onDelete;
  final void Function(Map<String, dynamic> m) onShowInChat;

  const _MediaViewerScreen({
    required this.items,
    required this.initialIndex,
    required this.nameOf,
    required this.localPath,
    required this.ensureLocal,
    required this.canForward,
    required this.onForward,
    required this.canDelete,
    required this.onDelete,
    required this.onShowInChat,
  });

  @override
  State<_MediaViewerScreen> createState() => _MediaViewerScreenState();
}

class _MediaViewerScreenState extends State<_MediaViewerScreen> {
  late final PageController _pc;
  late List<Map<String, dynamic>> _list;
  int _cur = 0;
  bool _ui = true;
  bool _zoomed = false;
  double _dy = 0;

  @override
  void initState() {
    super.initState();
    _list = List<Map<String, dynamic>>.from(widget.items);
    _cur = widget.initialIndex.clamp(0, math.max(0, _list.length - 1)).toInt();
    _pc = PageController(initialPage: _cur);
  }

  @override
  void dispose() {
    _pc.dispose();
    super.dispose();
  }

  Map<String, dynamic> get _m => _list[_cur];
  bool _isVideo(Map<String, dynamic> m) => (m['type'] ?? '').toString() == 'video';

  void _snack(String s) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(s), duration: const Duration(seconds: 2)));
  }

  Future<void> _save() async {
    final m = _m;
    final video = _isVideo(m);
    _snack('Saving…');
    final path = await widget.ensureLocal(m);
    if (path == null) {
      _snack('Could not download this file');
      return;
    }
    try {
      final ps = await PhotoManager.requestPermissionExtend();
      if (!ps.hasAccess) {
        _snack('Gallery permission is needed to save');
        return;
      }
      final title = 'luma_${DateTime.now().millisecondsSinceEpoch}.${video ? 'mp4' : 'jpg'}';
      if (video) {
        await PhotoManager.editor.saveVideo(File(path), title: title);
      } else {
        await PhotoManager.editor.saveImageWithPath(path, title: title);
      }
      _snack('Saved to gallery');
    } catch (e) {
      _snack('Could not save: $e');
    }
  }

  Future<void> _openWith() async {
    final path = await widget.ensureLocal(_m);
    if (path == null) {
      _snack('Could not download this file');
      return;
    }
    await OpenFilex.open(path);
  }

  Future<void> _delete() async {
    final m = _m;
    final ok = await widget.onDelete(m);
    if (!ok || !mounted) return;
    setState(() {
      _list.removeAt(_cur);
      if (_list.isEmpty) return;
      if (_cur >= _list.length) _cur = _list.length - 1;
    });
    if (_list.isEmpty) {
      Navigator.pop(context);
    } else {
      _pc.jumpToPage(_cur);
    }
  }

  Widget _imagePage(Map<String, dynamic> m) {
    final url = m['media_url'].toString();
    final lp = widget.localPath(m);
    final ImageProvider provider = lp != null ? FileImage(File(lp)) : CachedNetworkImageProvider(url) as ImageProvider;
    return _ViewerImage(
      provider: provider,
      onTap: () => setState(() => _ui = !_ui),
      onZoom: (z) {
        if (z != _zoomed) setState(() => _zoomed = z);
      },
    );
  }

  Widget _page(int i) {
    final m = _list[i];
    if (_isVideo(m)) {
      final hasCap = (m['text'] ?? '').toString().isNotEmpty;
      return _ViewerVideo(
        key: ValueKey('v_${m['id']}'),
        url: m['media_url'].toString(),
        localPath: widget.localPath(m),
        active: i == _cur,
        uiVisible: _ui,
        controlsBottom: 80 + (hasCap ? 52 : 0) + MediaQuery.of(context).padding.bottom,
        onTap: () => setState(() => _ui = !_ui),
      );
    }
    return _imagePage(m);
  }

  @override
  Widget build(BuildContext context) {
    if (_list.isEmpty) return const Scaffold(backgroundColor: Colors.black);
    final m = _m;
    final t = _msgTime(m);
    final cap = (m['text'] ?? '').toString();
    final double fade = (1.0 - (_dy.abs() / 320.0)).clamp(0.0, 1.0).toDouble();
    final top = MediaQuery.of(context).padding.top;
    final bottom = MediaQuery.of(context).padding.bottom;

    return Scaffold(
      backgroundColor: Colors.transparent,
      body: Stack(
        children: [
          Positioned.fill(child: ColoredBox(color: Colors.black.withOpacity(fade))),
          GestureDetector(
            onVerticalDragUpdate: _zoomed ? null : (d) => setState(() => _dy += d.delta.dy),
            onVerticalDragEnd: _zoomed
                ? null
                : (d) {
                    if (_dy.abs() > 120 || (d.primaryVelocity ?? 0).abs() > 900) {
                      Navigator.pop(context);
                    } else {
                      setState(() => _dy = 0);
                    }
                  },
            child: Transform.translate(
              offset: Offset(0, _dy),
              child: PageView.builder(
                controller: _pc,
                itemCount: _list.length,
                physics: _zoomed ? const NeverScrollableScrollPhysics() : const BouncingScrollPhysics(),
                onPageChanged: (i) => setState(() {
                  _cur = i;
                  _zoomed = false;
                }),
                itemBuilder: (_, i) => _page(i),
              ),
            ),
          ),
          // top bar
          Positioned(
            top: 0,
            left: 0,
            right: 0,
            child: IgnorePointer(
              ignoring: !_ui,
              child: AnimatedOpacity(
                opacity: (_ui && _dy == 0) ? 1 : 0,
                duration: const Duration(milliseconds: 180),
                child: Container(
                  padding: EdgeInsets.only(top: top, left: 4, right: 4, bottom: 8),
                  decoration: const BoxDecoration(
                    gradient: LinearGradient(begin: Alignment.topCenter, end: Alignment.bottomCenter, colors: [Color(0xCC000000), Color(0x00000000)]),
                  ),
                  child: Row(
                    children: [
                      IconButton(icon: const Icon(Icons.arrow_back, color: Colors.white), onPressed: () => Navigator.pop(context)),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(widget.nameOf(m['sender_id']?.toString()), maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.w700)),
                            Text('${_dayLabel(t)} at ${DateFormat('HH:mm').format(t)}${_list.length > 1 ? '  •  ${_cur + 1} of ${_list.length}' : ''}',
                                style: const TextStyle(color: Colors.white70, fontSize: 12.5)),
                          ],
                        ),
                      ),
                      PopupMenuButton<String>(
                        icon: const Icon(Icons.more_vert, color: Colors.white),
                        color: const Color(0xFF1F2C34),
                        onSelected: (v) {
                          switch (v) {
                            case 'chat':
                              Navigator.pop(context);
                              widget.onShowInChat(m);
                              break;
                            case 'fwd':
                              widget.onForward(m);
                              break;
                            case 'save':
                              _save();
                              break;
                            case 'open':
                              _openWith();
                              break;
                            case 'del':
                              _delete();
                              break;
                          }
                        },
                        itemBuilder: (_) => [
                          const PopupMenuItem(value: 'chat', child: Text('Show in chat', style: TextStyle(color: Colors.white))),
                          if (widget.canForward) const PopupMenuItem(value: 'fwd', child: Text('Forward', style: TextStyle(color: Colors.white))),
                          const PopupMenuItem(value: 'save', child: Text('Save to gallery', style: TextStyle(color: Colors.white))),
                          const PopupMenuItem(value: 'open', child: Text('Open with…', style: TextStyle(color: Colors.white))),
                          if (widget.canDelete(m)) const PopupMenuItem(value: 'del', child: Text('Delete', style: TextStyle(color: Colors.redAccent))),
                        ],
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
          // bottom bar
          Positioned(
            bottom: 0,
            left: 0,
            right: 0,
            child: IgnorePointer(
              ignoring: !_ui,
              child: AnimatedOpacity(
                opacity: (_ui && _dy == 0) ? 1 : 0,
                duration: const Duration(milliseconds: 180),
                child: Container(
                  padding: EdgeInsets.only(bottom: bottom + 4, top: 10),
                  decoration: const BoxDecoration(
                    gradient: LinearGradient(begin: Alignment.bottomCenter, end: Alignment.topCenter, colors: [Color(0xCC000000), Color(0x00000000)]),
                  ),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      if (cap.isNotEmpty)
                        Container(
                          width: double.infinity,
                          constraints: const BoxConstraints(maxHeight: 110),
                          padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
                          child: SingleChildScrollView(child: Text(cap, style: const TextStyle(color: Colors.white, fontSize: 15))),
                        ),
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceAround,
                        children: [
                          IconButton(icon: const Icon(Icons.ios_share, color: Colors.white), tooltip: 'Open with…', onPressed: _openWith),
                          if (widget.canForward) IconButton(icon: const Icon(Icons.forward, color: Colors.white), tooltip: 'Forward', onPressed: () => widget.onForward(m)),
                          IconButton(icon: const Icon(Icons.download_rounded, color: Colors.white), tooltip: 'Save to gallery', onPressed: _save),
                          if (widget.canDelete(m)) IconButton(icon: const Icon(Icons.delete_outline, color: Colors.white), tooltip: 'Delete', onPressed: _delete),
                        ],
                      ),
                    ],
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

class _ViewerImage extends StatefulWidget {
  final ImageProvider provider;
  final VoidCallback onTap;
  final ValueChanged<bool> onZoom;
  const _ViewerImage({required this.provider, required this.onTap, required this.onZoom});

  @override
  State<_ViewerImage> createState() => _ViewerImageState();
}

class _ViewerImageState extends State<_ViewerImage> {
  final TransformationController _tc = TransformationController();
  Offset _dt = Offset.zero;
  bool _z = false;

  @override
  void initState() {
    super.initState();
    _tc.addListener(() {
      final z = _tc.value.getMaxScaleOnAxis() > 1.02;
      if (z != _z) {
        setState(() => _z = z);
        widget.onZoom(z);
      }
    });
  }

  @override
  void dispose() {
    _tc.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: widget.onTap,
      onDoubleTapDown: (d) => _dt = d.localPosition,
      onDoubleTap: () {
        if (_z) {
          _tc.value = Matrix4.identity();
        } else {
          _tc.value = Matrix4.identity()
            ..translate(-_dt.dx * 1.5, -_dt.dy * 1.5)
            ..scale(2.5);
        }
      },
      child: InteractiveViewer(
        transformationController: _tc,
        minScale: 1,
        maxScale: 6,
        panEnabled: _z,
        child: SizedBox.expand(
          child: Image(
            image: widget.provider,
            fit: BoxFit.contain,
            loadingBuilder: (c, child, p) => p == null ? child : const Center(child: CircularProgressIndicator(color: Colors.white)),
            errorBuilder: (_, __, ___) => const Center(child: Icon(Icons.broken_image, color: Colors.white54, size: 48)),
          ),
        ),
      ),
    );
  }
}

class _ViewerVideo extends StatefulWidget {
  final String url;
  final String? localPath;
  final bool active;
  final bool uiVisible;
  final double controlsBottom;
  final VoidCallback onTap;
  const _ViewerVideo({
    super.key,
    required this.url,
    required this.localPath,
    required this.active,
    required this.uiVisible,
    required this.controlsBottom,
    required this.onTap,
  });

  @override
  State<_ViewerVideo> createState() => _ViewerVideoState();
}

class _ViewerVideoState extends State<_ViewerVideo> {
  VideoPlayerController? _c;
  bool _err = false;
  bool _initing = false;
  double _speed = 1;
  bool _muted = false;
  bool _land = false;
  String? _hint;
  Timer? _hintTimer;
  double _tapX = 0;

  @override
  void initState() {
    super.initState();
    if (widget.active) _init();
  }

  @override
  void didUpdateWidget(covariant _ViewerVideo old) {
    super.didUpdateWidget(old);
    if (widget.active && !old.active) {
      if (_c == null) {
        _init();
      } else {
        _c!.play();
      }
    } else if (!widget.active && old.active) {
      _c?.pause();
    }
  }

  Future<void> _init() async {
    if (_initing) return;
    _initing = true;
    try {
      final lp = widget.localPath;
      final c = lp != null ? VideoPlayerController.file(File(lp)) : VideoPlayerController.networkUrl(Uri.parse(widget.url));
      await c.initialize();
      if (!mounted) {
        c.dispose();
        return;
      }
      c.addListener(_tick);
      await c.play();
      setState(() => _c = c);
    } catch (_) {
      if (mounted) setState(() => _err = true);
    }
    _initing = false;
  }

  void _tick() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    _hintTimer?.cancel();
    _c?.removeListener(_tick);
    _c?.dispose();
    if (_land) {
      SystemChrome.setPreferredOrientations([DeviceOrientation.portraitUp, DeviceOrientation.portraitDown]);
      SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    }
    super.dispose();
  }

  void _showHint(String s) {
    _hintTimer?.cancel();
    setState(() => _hint = s);
    _hintTimer = Timer(const Duration(milliseconds: 700), () {
      if (mounted) setState(() => _hint = null);
    });
  }

  void _seekBy(int sec) {
    final c = _c;
    if (c == null) return;
    final target = c.value.position + Duration(seconds: sec);
    final max = c.value.duration;
    c.seekTo(target < Duration.zero ? Duration.zero : (target > max ? max : target));
    _showHint(sec > 0 ? '+${sec}s' : '${sec}s');
  }

  void _toggleLandscape() {
    _land = !_land;
    if (_land) {
      SystemChrome.setPreferredOrientations([DeviceOrientation.landscapeLeft, DeviceOrientation.landscapeRight]);
      SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
    } else {
      SystemChrome.setPreferredOrientations([DeviceOrientation.portraitUp, DeviceOrientation.portraitDown]);
      SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    }
    setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final c = _c;
    if (_err) {
      return const Center(child: Column(mainAxisSize: MainAxisSize.min, children: [Icon(Icons.error_outline, color: Colors.white70, size: 40), SizedBox(height: 8), Text('Could not play this video', style: TextStyle(color: Colors.white70))]));
    }
    if (c == null || !c.value.isInitialized) return const Center(child: CircularProgressIndicator(color: Colors.white));
    final pos = c.value.position.inMilliseconds.toDouble();
    final dur = math.max(1.0, c.value.duration.inMilliseconds.toDouble());
    final playing = c.value.isPlaying;
    final w = MediaQuery.of(context).size.width;

    return Stack(
      fit: StackFit.expand,
      children: [
        GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: widget.onTap,
          onDoubleTapDown: (d) => _tapX = d.localPosition.dx,
          onDoubleTap: () => _seekBy(_tapX < w / 2 ? -10 : 10),
          child: Center(
            child: AspectRatio(
              aspectRatio: c.value.aspectRatio == 0 ? 16 / 9 : c.value.aspectRatio,
              child: VideoPlayer(c),
            ),
          ),
        ),
        if (_hint != null)
          Center(
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
              decoration: BoxDecoration(color: Colors.black54, borderRadius: BorderRadius.circular(24)),
              child: Text(_hint!, style: const TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.w700)),
            ),
          ),
        if (c.value.isBuffering) const Center(child: CircularProgressIndicator(color: Colors.white)),
        // centre play / pause
        Center(
          child: IgnorePointer(
            ignoring: !(widget.uiVisible || !playing),
            child: AnimatedOpacity(
              opacity: (widget.uiVisible || !playing) ? 1 : 0,
              duration: const Duration(milliseconds: 160),
              child: GestureDetector(
                onTap: () => playing ? c.pause() : c.play(),
                child: Container(
                  width: 68,
                  height: 68,
                  decoration: const BoxDecoration(color: Color(0x99000000), shape: BoxShape.circle),
                  child: Icon(playing ? Icons.pause : Icons.play_arrow, color: Colors.white, size: 40),
                ),
              ),
            ),
          ),
        ),
        // bottom controls
        Positioned(
          left: 0,
          right: 0,
          bottom: widget.controlsBottom,
          child: IgnorePointer(
            ignoring: !widget.uiVisible,
            child: AnimatedOpacity(
              opacity: widget.uiVisible ? 1 : 0,
              duration: const Duration(milliseconds: 160),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Row(
                    children: [
                      const SizedBox(width: 14),
                      Text(_fmtDur((pos / 1000).round()), style: const TextStyle(color: Colors.white, fontSize: 12)),
                      Expanded(
                        child: SliderTheme(
                          data: SliderTheme.of(context).copyWith(trackHeight: 3, thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 6), overlayShape: const RoundSliderOverlayShape(overlayRadius: 14)),
                          child: Slider(
                            value: pos.clamp(0.0, dur).toDouble(),
                            max: dur,
                            activeColor: Colors.white,
                            inactiveColor: Colors.white24,
                            onChanged: (v) => c.seekTo(Duration(milliseconds: v.round())),
                          ),
                        ),
                      ),
                      Text(_fmtDur((dur / 1000).round()), style: const TextStyle(color: Colors.white, fontSize: 12)),
                      const SizedBox(width: 14),
                    ],
                  ),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      TextButton(
                        onPressed: () {
                          const speeds = [0.5, 1.0, 1.5, 2.0];
                          final i = speeds.indexOf(_speed);
                          _speed = speeds[(i + 1) % speeds.length];
                          c.setPlaybackSpeed(_speed);
                          setState(() {});
                        },
                        child: Text('${_speed == _speed.roundToDouble() ? _speed.toInt() : _speed}x', style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w700)),
                      ),
                      IconButton(
                        icon: Icon(_muted ? Icons.volume_off : Icons.volume_up, color: Colors.white),
                        onPressed: () {
                          _muted = !_muted;
                          c.setVolume(_muted ? 0 : 1);
                          setState(() {});
                        },
                      ),
                      IconButton(icon: const Icon(Icons.replay_10, color: Colors.white), onPressed: () => _seekBy(-10)),
                      IconButton(icon: const Icon(Icons.forward_10, color: Colors.white), onPressed: () => _seekBy(10)),
                      IconButton(icon: Icon(_land ? Icons.fullscreen_exit : Icons.fullscreen, color: Colors.white), onPressed: _toggleLandscape),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ),
      ],
    );
  }
}

// ═══════════════════════════════════════════════════════════════════════════
// STICKERS: panel with packs + custom stickers, and the pack sheet
// Firestore:  sticker_packs/{packId} { title, owner_id, stickers:[{url,emoji,animated}] }
//             user_settings/{uid}.sticker_pack_ids : [packId]
// ═══════════════════════════════════════════════════════════════════════════
class _StickerPanel extends StatefulWidget {
  final String uid;
  final String apiKey;
  final void Function(String url, String? packId) onSend;
  final VoidCallback onCreate;
  const _StickerPanel({super.key, required this.uid, required this.apiKey, required this.onSend, required this.onCreate});

  @override
  State<_StickerPanel> createState() => _StickerPanelState();
}

class _StickerPanelState extends State<_StickerPanel> {
  int _tab = 0; // 0 = trending (GIPHY), 1.. = packs
  List<String> _ids = [];
  final Map<String, Map<String, dynamic>> _packs = {};
  final Map<String, StreamSubscription> _packSubs = {};
  StreamSubscription? _idsSub;

  String get _myPackId => 'my_${widget.uid}';
  List<String> get _tabs => [_myPackId, ..._ids.where((e) => e != _myPackId)];

  @override
  void initState() {
    super.initState();
    if (widget.uid.isEmpty) return;
    _idsSub = FirebaseFirestore.instance.collection('user_settings').doc(widget.uid).snapshots().listen((doc) {
      final raw = doc.data()?['sticker_pack_ids'];
      final ids = raw is List ? raw.map((e) => e.toString()).toList() : <String>[];
      _sync(ids);
    }, onError: (_) {});
    _sync(const []);
  }

  void _sync(List<String> ids) {
    final all = <String>{_myPackId, ...ids};
    for (final id in all) {
      if (_packSubs.containsKey(id)) continue;
      _packSubs[id] = FirebaseFirestore.instance.collection('sticker_packs').doc(id).snapshots().listen((d) {
        if (!mounted) return;
        setState(() {
          if (d.exists && d.data() != null) {
            _packs[id] = d.data()!;
          } else {
            _packs.remove(id);
          }
        });
      }, onError: (_) {});
    }
    for (final id in _packSubs.keys.toList()) {
      if (!all.contains(id)) {
        _packSubs.remove(id)?.cancel();
        _packs.remove(id);
      }
    }
    if (mounted) setState(() => _ids = ids);
  }

  @override
  void dispose() {
    _idsSub?.cancel();
    for (final s in _packSubs.values) {
      s.cancel();
    }
    super.dispose();
  }

  List<Map<String, dynamic>> _stickersOf(String id) {
    final raw = _packs[id]?['stickers'];
    if (raw is! List) return [];
    return raw.whereType<Map>().map((e) => Map<String, dynamic>.from(e)).toList();
  }

  Widget _tabBtn(Widget child, bool on, VoidCallback onTap) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        width: 40,
        height: 40,
        margin: const EdgeInsets.only(right: 6),
        decoration: BoxDecoration(color: on ? Colors.grey.withOpacity(0.25) : Colors.transparent, borderRadius: BorderRadius.circular(10)),
        alignment: Alignment.center,
        child: child,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final tabs = _tabs;
    final onSurface = theme.colorScheme.onSurface;
    Widget body;
    if (_tab == 0) {
      body = _GiphyPanel(key: const ValueKey('giphy_stickers'), isSticker: true, apiKey: widget.apiKey, onSelected: (u) => widget.onSend(u, null));
    } else {
      final id = tabs[(_tab - 1).clamp(0, tabs.length - 1).toInt()];
      final list = _stickersOf(id);
      final mine = id == _myPackId;
      final title = (_packs[id]?['title'] ?? (mine ? 'My Stickers' : 'Stickers')).toString();
      body = Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 10, 16, 4),
            child: Text('$title · ${list.length}', style: TextStyle(fontSize: 13, fontWeight: FontWeight.w700, color: onSurface.withOpacity(0.6))),
          ),
          Expanded(
            child: GridView.builder(
              padding: const EdgeInsets.fromLTRB(8, 4, 8, 8),
              gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(crossAxisCount: 4, crossAxisSpacing: 6, mainAxisSpacing: 6),
              itemCount: list.length + (mine ? 1 : 0),
              itemBuilder: (_, i) {
                if (mine && i == 0) {
                  return GestureDetector(
                    onTap: widget.onCreate,
                    child: Container(
                      decoration: BoxDecoration(color: _kAccent.withOpacity(0.12), borderRadius: BorderRadius.circular(12), border: Border.all(color: _kAccent.withOpacity(0.5))),
                      child: const Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [Icon(Icons.add_photo_alternate_outlined, color: _kAccent), SizedBox(height: 4), Text('Create', style: TextStyle(color: _kAccent, fontSize: 12, fontWeight: FontWeight.w700))],
                      ),
                    ),
                  );
                }
                final s = list[i - (mine ? 1 : 0)];
                final url = (s['url'] ?? '').toString();
                return GestureDetector(
                  onTap: () => widget.onSend(url, id),
                  onLongPress: mine
                      ? () async {
                          final ok = await showDialog<bool>(
                            context: context,
                            builder: (ctx) => AlertDialog(
                              title: const Text('Delete sticker?'),
                              content: const Text('It will be removed from your pack.'),
                              actions: [
                                TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
                                TextButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Delete', style: TextStyle(color: Colors.red))),
                              ],
                            ),
                          );
                          if (ok == true) {
                            await FirebaseFirestore.instance.collection('sticker_packs').doc(id).update({'stickers': FieldValue.arrayRemove([s])});
                          }
                        }
                      : null,
                  child: CachedNetworkImage(imageUrl: url, fit: BoxFit.contain, placeholder: (_, __) => Container(color: Colors.grey.withOpacity(0.15)), errorWidget: (_, __, ___) => const Icon(Icons.broken_image, color: Colors.grey)),
                );
              },
            ),
          ),
        ],
      );
    }

    return Column(
      children: [
        SizedBox(
          height: 48,
          child: ListView(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.fromLTRB(10, 6, 10, 2),
            children: [
              _tabBtn(Icon(Icons.local_fire_department_outlined, color: _tab == 0 ? _kAccent : onSurface.withOpacity(0.6)), _tab == 0, () => setState(() => _tab = 0)),
              for (var i = 0; i < tabs.length; i++)
                _tabBtn(
                  () {
                    final list = _stickersOf(tabs[i]);
                    if (list.isEmpty) return Icon(i == 0 ? Icons.person_outline : Icons.emoji_emotions_outlined, color: _tab == i + 1 ? _kAccent : onSurface.withOpacity(0.6));
                    return Padding(padding: const EdgeInsets.all(4), child: CachedNetworkImage(imageUrl: (list.first['url'] ?? '').toString(), fit: BoxFit.contain, errorWidget: (_, __, ___) => const SizedBox.shrink()));
                  }(),
                  _tab == i + 1,
                  () => setState(() => _tab = i + 1),
                ),
              _tabBtn(const Icon(Icons.add_circle_outline, color: _kAccent), false, widget.onCreate),
            ],
          ),
        ),
        Expanded(child: body),
      ],
    );
  }
}

/// Bottom sheet shown when a sticker in the chat is tapped.
class _StickerPackSheet extends StatefulWidget {
  final String? packId;
  final String singleUrl;
  final String uid;
  final void Function(String url, String? packId) onSend;
  const _StickerPackSheet({required this.packId, required this.singleUrl, required this.uid, required this.onSend});

  @override
  State<_StickerPackSheet> createState() => _StickerPackSheetState();
}

class _StickerPackSheetState extends State<_StickerPackSheet> {
  Map<String, dynamic>? _pack;
  List<String> _myIds = [];
  bool _loading = true;
  bool _busy = false;

  String get _myPackId => 'my_${widget.uid}';
  bool get _hasPack => _pack != null;
  bool get _isMinePack => widget.packId == _myPackId;
  bool get _added => widget.packId != null && _myIds.contains(widget.packId);

  List<Map<String, dynamic>> get _stickers {
    if (_pack == null) return [{'url': widget.singleUrl}];
    final raw = _pack!['stickers'];
    if (raw is! List) return [];
    return raw.whereType<Map>().map((e) => Map<String, dynamic>.from(e)).toList();
  }

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final fs = FirebaseFirestore.instance;
      final sd = await fs.collection('user_settings').doc(widget.uid).get();
      final raw = sd.data()?['sticker_pack_ids'];
      _myIds = raw is List ? raw.map((e) => e.toString()).toList() : <String>[];
      if (widget.packId != null) {
        final pd = await fs.collection('sticker_packs').doc(widget.packId).get();
        if (pd.exists) _pack = pd.data();
      }
    } catch (_) {}
    if (mounted) setState(() => _loading = false);
  }

  Future<void> _togglePack() async {
    final id = widget.packId;
    if (id == null || _busy) return;
    setState(() => _busy = true);
    try {
      await FirebaseFirestore.instance.collection('user_settings').doc(widget.uid).set({
        'sticker_pack_ids': _added ? FieldValue.arrayRemove([id]) : FieldValue.arrayUnion([id]),
      }, SetOptions(merge: true));
      if (_added) {
        _myIds.remove(id);
      } else {
        _myIds.add(id);
      }
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Failed: $e')));
    }
    if (mounted) setState(() => _busy = false);
  }

  Future<void> _copyToMine(Map<String, dynamic> s) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      final fs = FirebaseFirestore.instance;
      await fs.collection('sticker_packs').doc(_myPackId).set({
        'title': 'My Stickers',
        'owner_id': widget.uid,
        'updated_at': FieldValue.serverTimestamp(),
        'stickers': FieldValue.arrayUnion([
          {'url': (s['url'] ?? widget.singleUrl).toString(), 'emoji': (s['emoji'] ?? '').toString(), 'animated': s['animated'] == true},
        ]),
      }, SetOptions(merge: true));
      await fs.collection('user_settings').doc(widget.uid).set({'sticker_pack_ids': FieldValue.arrayUnion([_myPackId])}, SetOptions(merge: true));
      if (mounted) {
        Navigator.pop(context);
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Added to My Stickers')));
      }
    } catch (e) {
      if (mounted) {
        setState(() => _busy = false);
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Failed: $e')));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final bg = isDark ? const Color(0xFF17212B) : Colors.white;
    final list = _stickers;
    final title = _hasPack ? (_pack!['title'] ?? 'Sticker pack').toString() : 'Sticker';
    return Container(
      constraints: BoxConstraints(maxHeight: MediaQuery.of(context).size.height * 0.78),
      decoration: BoxDecoration(color: bg, borderRadius: const BorderRadius.vertical(top: Radius.circular(22))),
      child: SafeArea(
        top: false,
        child: _loading
            ? const SizedBox(height: 220, child: Center(child: CircularProgressIndicator()))
            : Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Container(margin: const EdgeInsets.only(top: 10), height: 4, width: 40, decoration: BoxDecoration(color: Colors.grey[400], borderRadius: BorderRadius.circular(2))),
                  Padding(
                    padding: const EdgeInsets.fromLTRB(18, 14, 18, 6),
                    child: Row(
                      children: [
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(title, style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w800)),
                              Text('${list.length} sticker${list.length == 1 ? '' : 's'}', style: TextStyle(fontSize: 13, color: Theme.of(context).colorScheme.onSurface.withOpacity(0.55))),
                            ],
                          ),
                        ),
                        IconButton(icon: const Icon(Icons.close), onPressed: () => Navigator.pop(context)),
                      ],
                    ),
                  ),
                  Flexible(
                    child: GridView.builder(
                      shrinkWrap: true,
                      padding: const EdgeInsets.fromLTRB(10, 4, 10, 10),
                      gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(crossAxisCount: list.length == 1 ? 2 : 4, crossAxisSpacing: 8, mainAxisSpacing: 8),
                      itemCount: list.length,
                      itemBuilder: (_, i) {
                        final url = (list[i]['url'] ?? '').toString();
                        return GestureDetector(
                          onTap: () {
                            widget.onSend(url, widget.packId);
                            Navigator.pop(context);
                          },
                          child: CachedNetworkImage(imageUrl: url, fit: BoxFit.contain, errorWidget: (_, __, ___) => const Icon(Icons.broken_image, color: Colors.grey)),
                        );
                      },
                    ),
                  ),
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 4, 16, 12),
                    child: Column(
                      children: [
                        if (_hasPack && !_isMinePack)
                          SizedBox(
                            width: double.infinity,
                            child: ElevatedButton(
                              style: ElevatedButton.styleFrom(
                                backgroundColor: _added ? Colors.red.withOpacity(0.12) : _kAccent,
                                foregroundColor: _added ? Colors.red : Colors.white,
                                elevation: 0,
                                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                                padding: const EdgeInsets.symmetric(vertical: 14),
                              ),
                              onPressed: _busy ? null : _togglePack,
                              child: Text(_added ? 'Remove ${list.length} Stickers' : 'Add ${list.length} Stickers', style: const TextStyle(fontWeight: FontWeight.w800)),
                            ),
                          ),
                        if (_isMinePack) const Text('This is your own sticker pack', style: TextStyle(color: Colors.grey)),
                        if (!_isMinePack)
                          TextButton(
                            onPressed: _busy ? null : () => _copyToMine(list.length == 1 ? list.first : {'url': widget.singleUrl, ...list.firstWhere((e) => e['url'] == widget.singleUrl, orElse: () => <String, dynamic>{})}),
                            child: const Text('Add this sticker to My Stickers'),
                          ),
                      ],
                    ),
                  ),
                ],
              ),
      ),
    );
  }
}

// ═══════════════════════════════════════════════════════════════════════════
// WALLPAPER PREVIEW (shown after picking from the custom gallery)
// ═══════════════════════════════════════════════════════════════════════════
class _WallpaperPreviewScreen extends StatelessWidget {
  final File file;
  const _WallpaperPreviewScreen({required this.file});

  Widget _bubble(String text, bool me) {
    return Align(
      alignment: me ? Alignment.centerRight : Alignment.centerLeft,
      child: Container(
        margin: const EdgeInsets.symmetric(vertical: 4, horizontal: 12),
        padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
        decoration: BoxDecoration(
          color: me ? const Color(0xFFEFFDDE) : Colors.white,
          borderRadius: BorderRadius.only(topLeft: const Radius.circular(18), topRight: const Radius.circular(18), bottomLeft: Radius.circular(me ? 18 : 5), bottomRight: Radius.circular(me ? 5 : 18)),
        ),
        child: Text(text, style: const TextStyle(color: Colors.black87, fontSize: 15)),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
        fit: StackFit.expand,
        children: [
          Image.file(file, fit: BoxFit.cover),
          SafeArea(
            child: Column(
              children: [
                Align(alignment: Alignment.centerLeft, child: IconButton(icon: const Icon(Icons.close, color: Colors.white), onPressed: () => Navigator.pop(context, false))),
                const Spacer(),
                _bubble('This is how your chat will look', false),
                _bubble('Pinch-free, tap Set Wallpaper to apply it', true),
                _bubble('Looks great! 👍', false),
                const SizedBox(height: 24),
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
                  child: SizedBox(
                    width: double.infinity,
                    child: ElevatedButton(
                      style: ElevatedButton.styleFrom(backgroundColor: _kAccent, foregroundColor: Colors.white, shape: const StadiumBorder(), padding: const EdgeInsets.symmetric(vertical: 14)),
                      onPressed: () => Navigator.pop(context, true),
                      child: const Text('Set Wallpaper', style: TextStyle(fontWeight: FontWeight.w800)),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

// ═══════════════════════════════════════════════════════════════════════════
// MEDIA EDITOR  (photos: crop/rotate/flip, filters, adjust, draw, text, emoji;
//                videos: trim + mute; sticker mode; avatar mode)
// ═══════════════════════════════════════════════════════════════════════════
const List<Color> _kEdColors = [
  Colors.white,
  Colors.black,
  Color(0xFFFF3B30),
  Color(0xFFFF9500),
  Color(0xFFFFCC00),
  Color(0xFF34C759),
  Color(0xFF32ADE6),
  Color(0xFF3390EC),
  Color(0xFFAF52DE),
  Color(0xFFFF2D92),
];
const List<String> _kStickerEmojis = ['😀', '😂', '😍', '😎', '🥳', '😢', '😡', '👍', '❤️', '🔥'];
const List<String> _kFilterNames = ['Original', 'Vivid', 'Warm', 'Cool', 'B&W', 'Sepia', 'Fade', 'Noir', 'Vintage'];
const List<double> _kIdentityCm = [1, 0, 0, 0, 0, 0, 1, 0, 0, 0, 0, 0, 1, 0, 0, 0, 0, 0, 1, 0];

/// Result handed back by the editor.
class _EditedMedia {
  final File file;
  final bool isVideo;
  final String caption;
  final int width;
  final int height;
  final double trimStart;
  final double trimEnd; // 0 = not trimmed
  final double duration;
  final bool mute;
  final String emoji;
  _EditedMedia({
    required this.file,
    required this.isVideo,
    this.caption = '',
    this.width = 0,
    this.height = 0,
    this.trimStart = 0,
    this.trimEnd = 0,
    this.duration = 0,
    this.mute = false,
    this.emoji = '',
  });
}

class _EdStroke {
  final Color color;
  final double width;
  final bool erase;
  final List<Offset> pts = [];
  _EdStroke(this.color, this.width, this.erase);
}

class _EdOverlay {
  String text;
  Color color;
  double fontSize;
  bool bg;
  bool emoji;
  Offset pos;
  double scale;
  double rot;
  _EdOverlay({
    required this.text,
    required this.color,
    this.fontSize = 34,
    this.bg = false,
    this.emoji = false,
    this.pos = const Offset(0.5, 0.5),
    this.scale = 1,
    this.rot = 0,
  });
}

class _EdItem {
  final AssetEntity asset;
  final bool isVideo;
  File? file;
  ui.Image? img;
  VideoPlayerController? vc;
  bool failed = false;
  String caption = '';
  double aspect = 0; // 0 = original
  int turns = 0;
  bool flipX = false;
  double zoom = 1;
  Offset pan = Offset.zero;
  int filter = 0;
  double bright = 0;
  double contrast = 0;
  double sat = 0;
  final List<_EdStroke> strokes = [];
  final List<_EdOverlay> overlays = [];
  double trimStart = 0;
  double trimEnd = 0;
  double duration = 0;
  bool mute = false;

  _EdItem(this.asset) : isVideo = asset.type == AssetType.video;

  double get imgAspect {
    final i = img;
    if (i != null) {
      return turns.isOdd ? i.height / i.width : i.width / i.height;
    }
    final c = vc;
    if (c != null && c.value.isInitialized && c.value.aspectRatio > 0) return c.value.aspectRatio;
    return 1;
  }

  bool get edited =>
      aspect != 0 ||
      turns != 0 ||
      flipX ||
      zoom != 1 ||
      filter != 0 ||
      bright != 0 ||
      contrast != 0 ||
      sat != 0 ||
      strokes.isNotEmpty ||
      overlays.isNotEmpty;
}

List<double> _cmMul(List<double> a, List<double> b) {
  // result = b applied after a (4x5 colour matrices)
  final r = List<double>.filled(20, 0);
  for (var i = 0; i < 4; i++) {
    for (var j = 0; j < 5; j++) {
      var v = 0.0;
      for (var k = 0; k < 4; k++) {
        v += b[i * 5 + k] * a[k * 5 + j];
      }
      if (j == 4) v += b[i * 5 + 4];
      r[i * 5 + j] = v;
    }
  }
  return r;
}

List<double> _satCm(double s) {
  const lr = 0.3086, lg = 0.6094, lb = 0.0820;
  final i = 1 - s;
  return <double>[
    i * lr + s, i * lg, i * lb, 0, 0, //
    i * lr, i * lg + s, i * lb, 0, 0, //
    i * lr, i * lg, i * lb + s, 0, 0, //
    0, 0, 0, 1, 0,
  ];
}

List<double> _contrastCm(double c) {
  final o = 128.0 * (1 - c);
  return <double>[c, 0, 0, 0, o, 0, c, 0, 0, o, 0, 0, c, 0, o, 0, 0, 0, 1, 0];
}

List<double> _brightCm(double b) => <double>[1, 0, 0, 0, b, 0, 1, 0, 0, b, 0, 0, 1, 0, b, 0, 0, 0, 1, 0];

List<double> _filterCm(int i) {
  switch (i) {
    case 1:
      return _cmMul(_satCm(1.5), _contrastCm(1.1));
    case 2:
      return <double>[1.1, 0, 0, 0, 10, 0, 1.0, 0, 0, 0, 0, 0, 0.88, 0, -8, 0, 0, 0, 1, 0];
    case 3:
      return <double>[0.9, 0, 0, 0, -6, 0, 1.0, 0, 0, 0, 0, 0, 1.12, 0, 12, 0, 0, 0, 1, 0];
    case 4:
      return _satCm(0);
    case 5:
      return <double>[0.393, 0.769, 0.189, 0, 0, 0.349, 0.686, 0.168, 0, 0, 0.272, 0.534, 0.131, 0, 0, 0, 0, 0, 1, 0];
    case 6:
      return _cmMul(_cmMul(_satCm(0.8), _contrastCm(0.85)), _brightCm(22));
    case 7:
      return _cmMul(_satCm(0), _contrastCm(1.35));
    case 8:
      return <double>[0.9, 0.1, 0, 0, 10, 0.05, 0.85, 0.05, 0, 5, 0, 0.1, 0.75, 0, 10, 0, 0, 0, 1, 0];
    default:
      return List<double>.from(_kIdentityCm);
  }
}

List<double> _itemCm(_EdItem it) {
  var m = _filterCm(it.filter);
  if (it.bright != 0) m = _cmMul(m, _brightCm(it.bright * 90));
  if (it.contrast != 0) m = _cmMul(m, _contrastCm(1 + it.contrast * 0.6));
  if (it.sat != 0) m = _cmMul(m, _satCm(1 + it.sat));
  return m;
}

class _StrokePainter extends CustomPainter {
  final List<_EdStroke> strokes;
  final _EdStroke? live;
  _StrokePainter(this.strokes, this.live);

  @override
  void paint(Canvas canvas, Size size) {
    canvas.saveLayer(Offset.zero & size, Paint());
    final all = <_EdStroke>[...strokes];
    if (live != null) all.add(live!);
    for (final s in all) {
      if (s.pts.isEmpty) continue;
      final paint = Paint()
        ..color = s.color
        ..strokeWidth = s.width
        ..strokeCap = StrokeCap.round
        ..strokeJoin = StrokeJoin.round
        ..style = PaintingStyle.stroke
        ..isAntiAlias = true;
      if (s.erase) paint.blendMode = BlendMode.clear;
      Offset pt(int i) => Offset(s.pts[i].dx * size.width, s.pts[i].dy * size.height);
      if (s.pts.length == 1) {
        canvas.drawCircle(pt(0), s.width / 2, paint..style = PaintingStyle.fill);
        continue;
      }
      final path = ui.Path()..moveTo(pt(0).dx, pt(0).dy);
      for (var i = 1; i < s.pts.length; i++) {
        final p = pt(i);
        final prev = pt(i - 1);
        path.quadraticBezierTo(prev.dx, prev.dy, (prev.dx + p.dx) / 2, (prev.dy + p.dy) / 2);
      }
      path.lineTo(pt(s.pts.length - 1).dx, pt(s.pts.length - 1).dy);
      canvas.drawPath(path, paint);
    }
    canvas.restore();
  }

  @override
  bool shouldRepaint(covariant _StrokePainter old) => true;
}

class _MediaEditorScreen extends StatefulWidget {
  final List<AssetEntity> assets;
  final int initialIndex;
  final String mode; // 'media' | 'sticker' | 'avatar'
  const _MediaEditorScreen({required this.assets, this.initialIndex = 0, this.mode = 'media'});

  @override
  State<_MediaEditorScreen> createState() => _MediaEditorScreenState();
}

class _MediaEditorScreenState extends State<_MediaEditorScreen> {
  final List<_EdItem> _items = [];
  int _cur = 0;
  String _tool = ''; // '' | crop | filter | adjust | draw
  final GlobalKey _boundaryKey = GlobalKey();
  final TextEditingController _caption = TextEditingController();
  Size _canvas = const Size(300, 300);
  bool _busy = false;

  Color _drawColor = Colors.white;
  double _drawW = 6;
  bool _erase = false;
  _EdStroke? _live;

  _EdOverlay? _drag;
  Offset _dragOff = Offset.zero;
  double _baseScale = 1;
  double _baseRot = 0;
  bool _overTrash = false;
  Offset _focalStart = Offset.zero;
  Offset _panStart = Offset.zero;
  double _zoomStart = 1;
  String _emoji = '😀';

  bool get _isMedia => widget.mode == 'media';
  bool get _isSticker => widget.mode == 'sticker';
  _EdItem get _it => _items[_cur];

  @override
  void initState() {
    super.initState();
    for (final a in widget.assets) {
      _items.add(_EdItem(a));
    }
    _cur = widget.initialIndex.clamp(0, math.max(0, _items.length - 1)).toInt();
    for (final it in _items) {
      _loadItem(it);
    }
  }

  @override
  void dispose() {
    for (final it in _items) {
      it.vc?.dispose();
    }
    _caption.dispose();
    super.dispose();
  }

  Future<void> _loadItem(_EdItem it) async {
    try {
      final f = await it.asset.file;
      if (f == null) throw Exception('no file');
      it.file = f;
      if (it.isVideo) {
        final c = VideoPlayerController.file(f);
        await c.initialize();
        it.vc = c;
        it.duration = c.value.duration.inMilliseconds / 1000.0;
        it.trimStart = 0;
        it.trimEnd = _isSticker ? math.min(3.0, it.duration) : it.duration;
        await c.setLooping(true);
        c.addListener(() {
          if (it.trimEnd > 0 && c.value.isInitialized && c.value.position.inMilliseconds / 1000.0 >= it.trimEnd) {
            c.seekTo(Duration(milliseconds: (it.trimStart * 1000).round()));
          }
        });
        if (_items.indexOf(it) == _cur) await c.play();
      } else {
        final provider = ResizeImage(FileImage(f), width: 2048, policy: ResizeImagePolicy.fit);
        final completer = Completer<ui.Image>();
        final stream = provider.resolve(ImageConfiguration.empty);
        late ImageStreamListener l;
        l = ImageStreamListener((info, _) {
          if (!completer.isCompleted) completer.complete(info.clone().image);
          stream.removeListener(l);
        }, onError: (e, s) {
          if (!completer.isCompleted) completer.completeError(e);
          stream.removeListener(l);
        });
        stream.addListener(l);
        it.img = await completer.future;
      }
    } catch (_) {
      it.failed = true;
    }
    if (mounted) setState(() {});
  }

  void _switchTo(int i) {
    if (i == _cur || i < 0 || i >= _items.length) return;
    _it.caption = _caption.text;
    _it.vc?.pause();
    setState(() {
      _cur = i;
      _tool = '';
      _caption.text = _it.caption;
    });
    _it.vc?.play();
  }

  // ───────── geometry helpers ─────────
  Size _fit(_EdItem it, double cw, double ch) {
    final ia = it.imgAspect;
    if (ia > cw / ch) return Size(ch * ia, ch);
    return Size(cw, cw / ia);
  }

  Offset _clampPan(_EdItem it, Offset p, double cw, double ch) {
    final s = _fit(it, cw, ch);
    final mx = math.max(0.0, (s.width * it.zoom - cw) / 2) / cw;
    final my = math.max(0.0, (s.height * it.zoom - ch) / 2) / ch;
    return Offset(p.dx.clamp(-mx, mx).toDouble(), p.dy.clamp(-my, my).toDouble());
  }

  _EdOverlay? _hitOverlay(_EdItem it, Offset p, double cw, double ch) {
    for (final o in it.overlays.reversed) {
      final c = Offset(o.pos.dx * cw, o.pos.dy * ch);
      final lines = o.text.split('\n');
      final longest = lines.fold<int>(1, (a, b) => math.max(a, b.length));
      final w = (o.emoji ? o.fontSize * 1.3 : longest * o.fontSize * 0.6 + 16) * o.scale;
      final h = o.fontSize * 1.5 * lines.length * o.scale;
      if ((p.dx - c.dx).abs() < w / 2 + 12 && (p.dy - c.dy).abs() < h / 2 + 12) return o;
    }
    return null;
  }

  // ───────── gestures ─────────
  void _onScaleStart(ScaleStartDetails d, _EdItem it, double cw, double ch) {
    final p = d.localFocalPoint;
    if (_tool == 'draw') {
      final s = _EdStroke(_erase ? Colors.black : _drawColor, _drawW, _erase)..pts.add(Offset(_c01(p.dx / cw), _c01(p.dy / ch)));
      setState(() => _live = s);
      return;
    }
    if (_tool == 'crop') {
      _focalStart = p;
      _panStart = it.pan;
      _zoomStart = it.zoom;
      return;
    }
    final o = _hitOverlay(it, p, cw, ch);
    if (o != null) {
      it.overlays.remove(o);
      it.overlays.add(o);
      _drag = o;
      _dragOff = Offset(o.pos.dx * cw, o.pos.dy * ch) - p;
      _baseScale = o.scale;
      _baseRot = o.rot;
      setState(() {});
    }
  }

  void _onScaleUpdate(ScaleUpdateDetails d, _EdItem it, double cw, double ch) {
    final p = d.localFocalPoint;
    if (_tool == 'draw') {
      final s = _live;
      if (s == null) return;
      setState(() => s.pts.add(Offset(_c01(p.dx / cw), _c01(p.dy / ch))));
      return;
    }
    if (_tool == 'crop') {
      setState(() {
        it.zoom = (_zoomStart * d.scale).clamp(1.0, 6.0).toDouble();
        final dx = (p.dx - _focalStart.dx) / cw;
        final dy = (p.dy - _focalStart.dy) / ch;
        it.pan = _clampPan(it, Offset(_panStart.dx + dx, _panStart.dy + dy), cw, ch);
      });
      return;
    }
    final o = _drag;
    if (o == null) return;
    setState(() {
      o.pos = Offset((p.dx + _dragOff.dx) / cw, (p.dy + _dragOff.dy) / ch);
      o.scale = (_baseScale * d.scale).clamp(0.3, 6.0).toDouble();
      o.rot = _baseRot + d.rotation;
      _overTrash = p.dy > ch - 56;
    });
  }

  void _onScaleEnd(_EdItem it) {
    if (_live != null) {
      it.strokes.add(_live!);
      setState(() => _live = null);
      return;
    }
    final o = _drag;
    if (o != null) {
      setState(() {
        if (_overTrash) it.overlays.remove(o);
        _drag = null;
        _overTrash = false;
      });
    }
  }

  void _onTapCanvas(Offset p, _EdItem it, double cw, double ch) {
    if (_tool == 'draw' || _tool == 'crop') return;
    final o = _hitOverlay(it, p, cw, ch);
    if (o != null && !o.emoji) _editText(existing: o);
  }

  // ───────── text / emoji ─────────
  Future<void> _editText({_EdOverlay? existing}) async {
    final ctrl = TextEditingController(text: existing?.text ?? '');
    var color = existing?.color ?? Colors.white;
    var bg = existing?.bg ?? false;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setD) => AlertDialog(
          backgroundColor: const Color(0xFF1C1C1E),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: ctrl,
                autofocus: true,
                maxLines: 4,
                minLines: 1,
                style: TextStyle(color: color, fontSize: 22, fontWeight: FontWeight.w700),
                decoration: const InputDecoration(border: InputBorder.none, hintText: 'Enter text', hintStyle: TextStyle(color: Colors.white38)),
              ),
              const SizedBox(height: 10),
              SizedBox(
                height: 34,
                child: ListView(
                  scrollDirection: Axis.horizontal,
                  children: [
                    for (final c in _kEdColors)
                      GestureDetector(
                        onTap: () => setD(() => color = c),
                        child: Container(
                          width: 28,
                          height: 28,
                          margin: const EdgeInsets.only(right: 8),
                          decoration: BoxDecoration(
                            color: c,
                            shape: BoxShape.circle,
                            border: Border.all(color: color == c ? _kAccent : Colors.white24, width: color == c ? 3 : 1),
                          ),
                        ),
                      ),
                  ],
                ),
              ),
              Row(children: [
                const Text('Background', style: TextStyle(color: Colors.white70)),
                const Spacer(),
                Switch(value: bg, onChanged: (v) => setD(() => bg = v)),
              ]),
            ],
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
            TextButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Done')),
          ],
        ),
      ),
    );
    final t = ctrl.text.trim();
    if (ok != true || t.isEmpty || !mounted) return;
    setState(() {
      if (existing != null) {
        existing.text = t;
        existing.color = color;
        existing.bg = bg;
      } else {
        _it.overlays.add(_EdOverlay(text: t, color: color, bg: bg));
      }
    });
  }

  void _addEmoji() {
    showModalBottomSheet(
      context: context,
      backgroundColor: const Color(0xFF17212B),
      builder: (ctx) => SizedBox(
        height: 330,
        child: EmojiPicker(
          onEmojiSelected: (cat, emoji) {
            Navigator.pop(ctx);
            setState(() => _it.overlays.add(_EdOverlay(text: emoji.emoji, color: Colors.white, fontSize: 64, emoji: true)));
          },
          config: Config(height: 330, emojiViewConfig: EmojiViewConfig(columns: 8, emojiSizeMax: 28, backgroundColor: const Color(0xFF17212B))),
        ),
      ),
    );
  }

  // ───────── render + finish ─────────
  Future<_EditedMedia?> _render(_EdItem it) async {
    final ctx = _boundaryKey.currentContext;
    if (ctx == null) return null;
    final boundary = ctx.findRenderObject() as RenderRepaintBoundary;
    final maxSide = _isSticker ? 512.0 : (widget.mode == 'avatar' ? 800.0 : 1600.0);
    final pr = math.max(0.5, maxSide / math.max(_canvas.width, _canvas.height));
    final image = await boundary.toImage(pixelRatio: pr);
    final bd = await image.toByteData(format: ui.ImageByteFormat.png);
    if (bd == null) return null;
    final dir = await getTemporaryDirectory();
    final f = File('${dir.path}/edit_${DateTime.now().microsecondsSinceEpoch}.png');
    await f.writeAsBytes(bd.buffer.asUint8List());
    return _EditedMedia(file: f, isVideo: false, caption: it.caption, width: image.width, height: image.height, emoji: _emoji);
  }

  Future<void> _finish() async {
    if (_busy) return;
    FocusScope.of(context).unfocus();
    _it.caption = _caption.text.trim();
    setState(() {
      _busy = true;
      _tool = '';
    });
    final out = <_EditedMedia>[];
    try {
      for (var i = 0; i < _items.length; i++) {
        final it = _items[i];
        final f = it.file;
        if (f == null || it.failed) continue;
        it.vc?.pause();
        if (it.isVideo) {
          final trimmed = it.trimStart > 0.05 || (it.duration > 0 && it.trimEnd < it.duration - 0.05);
          out.add(_EditedMedia(
            file: f,
            isVideo: true,
            caption: it.caption,
            width: it.asset.orientatedWidth,
            height: it.asset.orientatedHeight,
            trimStart: trimmed ? it.trimStart : 0,
            trimEnd: trimmed ? it.trimEnd : 0,
            duration: it.duration,
            mute: it.mute,
            emoji: _emoji,
          ));
          continue;
        }
        if (_isMedia && !it.edited) {
          out.add(_EditedMedia(file: f, isVideo: false, caption: it.caption, width: it.asset.orientatedWidth, height: it.asset.orientatedHeight));
          continue;
        }
        if (i != _cur) {
          setState(() => _cur = i);
          await WidgetsBinding.instance.endOfFrame;
          await Future.delayed(const Duration(milliseconds: 80));
        }
        final r = await _render(it);
        if (r != null) out.add(r);
      }
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Could not export: $e')));
    }
    if (mounted) Navigator.pop(context, out);
  }

  // ───────── build ─────────
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      resizeToAvoidBottomInset: true,
      body: SafeArea(
        child: Stack(
          children: [
            Column(
              children: [
                _topBar(),
                Expanded(child: _items.isEmpty ? const SizedBox.shrink() : _stage()),
                if (_items.isNotEmpty) _bottomPanel(),
              ],
            ),
            if (_busy)
              Positioned.fill(
                child: Container(
                  color: Colors.black54,
                  alignment: Alignment.center,
                  child: const CircularProgressIndicator(color: Colors.white),
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _topBar() {
    final inTool = _tool.isNotEmpty;
    return SizedBox(
      height: 52,
      child: Row(
        children: [
          IconButton(
            icon: Icon(inTool ? Icons.check : Icons.close, color: Colors.white),
            onPressed: () {
              if (inTool) {
                setState(() => _tool = '');
              } else {
                Navigator.pop(context);
              }
            },
          ),
          Expanded(
            child: Text(
              _isSticker ? 'New sticker' : (widget.mode == 'avatar' ? 'Group photo' : (_items.length > 1 ? '${_cur + 1} of ${_items.length}' : 'Edit')),
              style: const TextStyle(color: Colors.white, fontSize: 17, fontWeight: FontWeight.w700),
            ),
          ),
          if (_items.length > 1)
            IconButton(
              icon: const Icon(Icons.delete_outline, color: Colors.white),
              onPressed: () {
                setState(() {
                  _items[_cur].vc?.dispose();
                  _items.removeAt(_cur);
                  if (_cur >= _items.length) _cur = _items.length - 1;
                  _caption.text = _it.caption;
                });
              },
            ),
        ],
      ),
    );
  }

  Widget _stage() {
    final it = _it;
    if (it.failed) return const Center(child: Text('Could not open this file', style: TextStyle(color: Colors.white70)));
    if (it.isVideo) return _videoStage(it);
    if (it.img == null) return const Center(child: CircularProgressIndicator(color: Colors.white));
    return LayoutBuilder(builder: (ctx, bc) {
      final a = (!_isMedia) ? 1.0 : (it.aspect > 0 ? it.aspect : it.imgAspect);
      final aw = bc.maxWidth - 16;
      final ah = bc.maxHeight - 12;
      double cw, ch;
      if (a > aw / ah) {
        cw = aw;
        ch = aw / a;
      } else {
        ch = ah;
        cw = ah * a;
      }
      _canvas = Size(cw, ch);
      return Center(
        child: SizedBox(
          width: cw,
          height: ch,
          child: Stack(
            clipBehavior: Clip.none,
            children: [
              Positioned.fill(child: _canvasWidget(it, cw, ch)),
              if (_drag != null)
                Positioned(
                  bottom: 8,
                  left: 0,
                  right: 0,
                  child: Center(
                    child: AnimatedContainer(
                      duration: const Duration(milliseconds: 120),
                      width: _overTrash ? 58 : 46,
                      height: _overTrash ? 58 : 46,
                      decoration: BoxDecoration(color: _overTrash ? Colors.red : Colors.black54, shape: BoxShape.circle),
                      child: const Icon(Icons.delete, color: Colors.white),
                    ),
                  ),
                ),
            ],
          ),
        ),
      );
    });
  }

  Widget _canvasWidget(_EdItem it, double cw, double ch) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onScaleStart: (d) => _onScaleStart(d, it, cw, ch),
      onScaleUpdate: (d) => _onScaleUpdate(d, it, cw, ch),
      onScaleEnd: (_) => _onScaleEnd(it),
      onTapUp: (d) => _onTapCanvas(d.localPosition, it, cw, ch),
      child: RepaintBoundary(
        key: _boundaryKey,
        child: ClipRect(
          child: Stack(
            children: [
              if (_isMedia) const Positioned.fill(child: ColoredBox(color: Colors.black)),
              Positioned.fill(child: _imageLayer(it, cw, ch)),
              Positioned.fill(child: CustomPaint(painter: _StrokePainter(it.strokes, _live))),
              for (final o in it.overlays) _overlayWidget(o, cw, ch),
            ],
          ),
        ),
      ),
    );
  }

  Widget _imageLayer(_EdItem it, double cw, double ch) {
    final img = it.img!;
    final s = _fit(it, cw, ch);
    Widget raw = RawImage(image: img, fit: BoxFit.fill, filterQuality: FilterQuality.medium);
    raw = RotatedBox(quarterTurns: it.turns, child: raw);
    raw = Transform(
      alignment: Alignment.center,
      transform: Matrix4.diagonal3Values(it.flipX ? -it.zoom : it.zoom, it.zoom, 1),
      child: raw,
    );
    final cm = _itemCm(it);
    final hasCm = it.filter != 0 || it.bright != 0 || it.contrast != 0 || it.sat != 0;
    if (hasCm) raw = ColorFiltered(colorFilter: ColorFilter.matrix(cm), child: raw);
    return Stack(
      children: [
        Positioned(
          left: (cw - s.width) / 2 + it.pan.dx * cw,
          top: (ch - s.height) / 2 + it.pan.dy * ch,
          width: s.width,
          height: s.height,
          child: raw,
        ),
      ],
    );
  }

  Widget _overlayWidget(_EdOverlay o, double cw, double ch) {
    final lum = o.color.computeLuminance();
    final child = o.emoji
        ? Text(o.text, style: TextStyle(fontSize: o.fontSize))
        : Container(
            padding: o.bg ? const EdgeInsets.symmetric(horizontal: 10, vertical: 4) : EdgeInsets.zero,
            decoration: o.bg ? BoxDecoration(color: o.color, borderRadius: BorderRadius.circular(8)) : null,
            child: Text(
              o.text,
              textAlign: TextAlign.center,
              style: TextStyle(
                color: o.bg ? (lum > 0.5 ? Colors.black : Colors.white) : o.color,
                fontSize: o.fontSize,
                fontWeight: FontWeight.w700,
                shadows: o.bg ? null : const [Shadow(blurRadius: 4, color: Colors.black54)],
              ),
            ),
          );
    return Positioned(
      left: o.pos.dx * cw - 600,
      top: o.pos.dy * ch - 300,
      width: 1200,
      height: 600,
      child: IgnorePointer(
        child: Center(
          child: Transform.rotate(angle: o.rot, child: Transform.scale(scale: o.scale, child: child)),
        ),
      ),
    );
  }

  Widget _videoStage(_EdItem it) {
    final c = it.vc;
    if (c == null || !c.value.isInitialized) return const Center(child: CircularProgressIndicator(color: Colors.white));
    return GestureDetector(
      onTap: () => setState(() => c.value.isPlaying ? c.pause() : c.play()),
      child: Center(
        child: AspectRatio(
          aspectRatio: c.value.aspectRatio == 0 ? 1 : c.value.aspectRatio,
          child: Stack(
            alignment: Alignment.center,
            children: [
              VideoPlayer(c),
              if (!c.value.isPlaying)
                Container(
                  padding: const EdgeInsets.all(12),
                  decoration: const BoxDecoration(color: Colors.black54, shape: BoxShape.circle),
                  child: const Icon(Icons.play_arrow, color: Colors.white, size: 36),
                ),
            ],
          ),
        ),
      ),
    );
  }

  // ───────── bottom panels ─────────
  Widget _bottomPanel() {
    final it = _it;
    return Container(
      color: const Color(0xFF111111),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (_items.length > 1) _thumbStrip(),
          if (!it.isVideo && _tool == 'crop') _cropPanel(it),
          if (!it.isVideo && _tool == 'filter') _filterPanel(it),
          if (!it.isVideo && _tool == 'adjust') _adjustPanel(it),
          if (!it.isVideo && _tool == 'draw') _drawPanel(it),
          if (it.isVideo) _videoPanel(it),
          if (!it.isVideo && _tool.isEmpty) _toolRow(),
          _footer(),
        ],
      ),
    );
  }

  Widget _thumbStrip() {
    return SizedBox(
      height: 56,
      child: ListView.builder(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        itemCount: _items.length,
        itemBuilder: (_, i) {
          final sel = i == _cur;
          return GestureDetector(
            onTap: () => _switchTo(i),
            child: Container(
              width: 48,
              height: 48,
              margin: const EdgeInsets.only(right: 6),
              decoration: BoxDecoration(border: Border.all(color: sel ? _kAccent : Colors.transparent, width: 2), borderRadius: BorderRadius.circular(6)),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(4),
                child: _AssetThumb(entity: _items[i].asset, selectedIndex: -1, showCircle: false, onTap: () => _switchTo(i)),
              ),
            ),
          );
        },
      ),
    );
  }

  Widget _toolBtn(IconData icon, String label, String tool, {VoidCallback? onTap}) {
    final on = tool.isNotEmpty && _tool == tool;
    return Expanded(
      child: InkWell(
        onTap: onTap ?? () => setState(() => _tool = on ? '' : tool),
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 8),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, color: on ? _kAccent : Colors.white, size: 24),
              const SizedBox(height: 2),
              Text(label, style: TextStyle(color: on ? _kAccent : Colors.white70, fontSize: 10.5)),
            ],
          ),
        ),
      ),
    );
  }

  Widget _toolRow() {
    return Row(
      children: [
        _toolBtn(Icons.crop_rotate, 'Crop', 'crop'),
        _toolBtn(Icons.auto_awesome, 'Filters', 'filter'),
        _toolBtn(Icons.tune, 'Adjust', 'adjust'),
        _toolBtn(Icons.brush, 'Draw', 'draw'),
        _toolBtn(Icons.title, 'Text', '', onTap: () => _editText()),
        _toolBtn(Icons.emoji_emotions_outlined, 'Emoji', '', onTap: _addEmoji),
      ],
    );
  }

  Widget _chip(String label, bool on, VoidCallback onTap) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        margin: const EdgeInsets.only(right: 8),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 7),
        decoration: BoxDecoration(color: on ? _kAccent : const Color(0xFF2A2A2C), borderRadius: BorderRadius.circular(18)),
        child: Text(label, style: const TextStyle(color: Colors.white, fontSize: 13, fontWeight: FontWeight.w600)),
      ),
    );
  }

  Widget _cropPanel(_EdItem it) {
    const presets = <String, double>{
      'Original': 0,
      'Square': 1,
      '3:4': 3 / 4,
      '4:3': 4 / 3,
      '9:16': 9 / 16,
      '16:9': 16 / 9,
      '2:3': 2 / 3,
      '3:2': 3 / 2,
    };
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Text('Pinch and drag the picture to crop', style: TextStyle(color: Colors.white54, fontSize: 12)),
          const SizedBox(height: 6),
          if (_isMedia)
            SizedBox(
              height: 36,
              child: ListView(
                scrollDirection: Axis.horizontal,
                padding: const EdgeInsets.symmetric(horizontal: 10),
                children: [
                  for (final e in presets.entries)
                    _chip(e.key, (it.aspect - e.value).abs() < 0.001, () {
                      setState(() {
                        it.aspect = e.value;
                        it.zoom = 1;
                        it.pan = Offset.zero;
                      });
                    }),
                ],
              ),
            ),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceEvenly,
            children: [
              IconButton(
                icon: const Icon(Icons.rotate_left, color: Colors.white),
                onPressed: () => setState(() {
                  it.turns = (it.turns + 3) % 4;
                  it.zoom = 1;
                  it.pan = Offset.zero;
                }),
              ),
              IconButton(
                icon: const Icon(Icons.rotate_right, color: Colors.white),
                onPressed: () => setState(() {
                  it.turns = (it.turns + 1) % 4;
                  it.zoom = 1;
                  it.pan = Offset.zero;
                }),
              ),
              IconButton(icon: const Icon(Icons.flip, color: Colors.white), onPressed: () => setState(() => it.flipX = !it.flipX)),
              TextButton(
                onPressed: () => setState(() {
                  it.aspect = 0;
                  it.turns = 0;
                  it.flipX = false;
                  it.zoom = 1;
                  it.pan = Offset.zero;
                }),
                child: const Text('Reset'),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _filterPanel(_EdItem it) {
    return SizedBox(
      height: 98,
      child: ListView.builder(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.all(8),
        itemCount: _kFilterNames.length,
        itemBuilder: (_, i) {
          final on = it.filter == i;
          return GestureDetector(
            onTap: () => setState(() => it.filter = i),
            child: Container(
              width: 66,
              margin: const EdgeInsets.only(right: 8),
              child: Column(
                children: [
                  Container(
                    width: 62,
                    height: 62,
                    decoration: BoxDecoration(border: Border.all(color: on ? _kAccent : Colors.transparent, width: 2), borderRadius: BorderRadius.circular(8)),
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(6),
                      child: ColorFiltered(
                        colorFilter: ColorFilter.matrix(_filterCm(i)),
                        child: RawImage(image: it.img, fit: BoxFit.cover),
                      ),
                    ),
                  ),
                  const SizedBox(height: 3),
                  Text(_kFilterNames[i], style: TextStyle(color: on ? _kAccent : Colors.white70, fontSize: 11)),
                ],
              ),
            ),
          );
        },
      ),
    );
  }

  Widget _slider(String label, double v, ValueChanged<double> onChanged) {
    return Row(
      children: [
        SizedBox(width: 88, child: Padding(padding: const EdgeInsets.only(left: 16), child: Text(label, style: const TextStyle(color: Colors.white70, fontSize: 13)))),
        Expanded(child: Slider(value: v, min: -1, max: 1, onChanged: onChanged)),
        SizedBox(width: 40, child: Text('${(v * 100).round()}', style: const TextStyle(color: Colors.white54, fontSize: 12))),
      ],
    );
  }

  Widget _adjustPanel(_EdItem it) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        _slider('Brightness', it.bright, (v) => setState(() => it.bright = v)),
        _slider('Contrast', it.contrast, (v) => setState(() => it.contrast = v)),
        _slider('Saturation', it.sat, (v) => setState(() => it.sat = v)),
      ],
    );
  }

  Widget _drawPanel(_EdItem it) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          SizedBox(
            height: 38,
            child: Row(
              children: [
                Expanded(
                  child: ListView(
                    scrollDirection: Axis.horizontal,
                    padding: const EdgeInsets.symmetric(horizontal: 12),
                    children: [
                      for (final c in _kEdColors)
                        GestureDetector(
                          onTap: () => setState(() {
                            _drawColor = c;
                            _erase = false;
                          }),
                          child: Container(
                            width: 30,
                            height: 30,
                            margin: const EdgeInsets.only(right: 10, top: 4),
                            decoration: BoxDecoration(
                              color: c,
                              shape: BoxShape.circle,
                              border: Border.all(color: (!_erase && _drawColor == c) ? _kAccent : Colors.white24, width: (!_erase && _drawColor == c) ? 3 : 1),
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
                IconButton(
                  icon: Icon(Icons.auto_fix_normal, color: _erase ? _kAccent : Colors.white),
                  tooltip: 'Eraser',
                  onPressed: () => setState(() => _erase = !_erase),
                ),
                IconButton(
                  icon: const Icon(Icons.undo, color: Colors.white),
                  tooltip: 'Undo',
                  onPressed: it.strokes.isEmpty ? null : () => setState(() => it.strokes.removeLast()),
                ),
              ],
            ),
          ),
          Row(
            children: [
              const Padding(padding: EdgeInsets.only(left: 16), child: Icon(Icons.circle, size: 8, color: Colors.white54)),
              Expanded(child: Slider(value: _drawW, min: 2, max: 28, onChanged: (v) => setState(() => _drawW = v))),
              const Padding(padding: EdgeInsets.only(right: 16), child: Icon(Icons.circle, size: 20, color: Colors.white54)),
            ],
          ),
        ],
      ),
    );
  }

  Widget _videoPanel(_EdItem it) {
    final c = it.vc;
    if (c == null || it.duration <= 0) return const SizedBox(height: 8);
    final maxLen = _isSticker ? 3.0 : it.duration;
    return Padding(
      padding: const EdgeInsets.fromLTRB(8, 4, 8, 0),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              Text(_fmtDur(it.trimStart.round()), style: const TextStyle(color: Colors.white70, fontSize: 12)),
              Expanded(
                child: RangeSlider(
                  values: RangeValues(it.trimStart.clamp(0.0, it.duration).toDouble(), it.trimEnd.clamp(0.0, it.duration).toDouble()),
                  min: 0,
                  max: it.duration,
                  onChanged: (v) {
                    var s = v.start;
                    var e = v.end;
                    if (e - s < 0.5) return;
                    if (e - s > maxLen) {
                      if (s != it.trimStart) {
                        e = s + maxLen;
                      } else {
                        s = e - maxLen;
                      }
                    }
                    setState(() {
                      final startMoved = s != it.trimStart;
                      it.trimStart = s;
                      it.trimEnd = e;
                      c.seekTo(Duration(milliseconds: ((startMoved ? s : e - 0.3) * 1000).round()));
                    });
                  },
                ),
              ),
              Text(_fmtDur(it.trimEnd.round()), style: const TextStyle(color: Colors.white70, fontSize: 12)),
            ],
          ),
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              TextButton.icon(
                onPressed: () => setState(() => c.value.isPlaying ? c.pause() : c.play()),
                icon: Icon(c.value.isPlaying ? Icons.pause : Icons.play_arrow, color: Colors.white),
                label: Text(c.value.isPlaying ? 'Pause' : 'Play', style: const TextStyle(color: Colors.white)),
              ),
              if (!_isSticker)
                TextButton.icon(
                  onPressed: () => setState(() {
                    it.mute = !it.mute;
                    c.setVolume(it.mute ? 0 : 1);
                  }),
                  icon: Icon(it.mute ? Icons.volume_off : Icons.volume_up, color: it.mute ? _kAccent : Colors.white),
                  label: Text(it.mute ? 'Muted' : 'Sound', style: TextStyle(color: it.mute ? _kAccent : Colors.white)),
                ),
            ],
          ),
          const Text('Drawing and text apply to photos only', style: TextStyle(color: Colors.white30, fontSize: 11)),
          const SizedBox(height: 4),
        ],
      ),
    );
  }

  Widget _footer() {
    if (_isSticker) {
      return Padding(
        padding: const EdgeInsets.fromLTRB(10, 6, 10, 10),
        child: Row(
          children: [
            Expanded(
              child: SizedBox(
                height: 40,
                child: ListView(
                  scrollDirection: Axis.horizontal,
                  children: [
                    for (final e in _kStickerEmojis)
                      GestureDetector(
                        onTap: () => setState(() => _emoji = e),
                        child: Container(
                          width: 38,
                          margin: const EdgeInsets.only(right: 6),
                          alignment: Alignment.center,
                          decoration: BoxDecoration(color: _emoji == e ? _kAccent.withOpacity(0.35) : const Color(0xFF2A2A2C), borderRadius: BorderRadius.circular(10)),
                          child: Text(e, style: const TextStyle(fontSize: 20)),
                        ),
                      ),
                  ],
                ),
              ),
            ),
            const SizedBox(width: 8),
            ElevatedButton(
              style: ElevatedButton.styleFrom(backgroundColor: _kAccent, foregroundColor: Colors.white, shape: const StadiumBorder(), padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 12)),
              onPressed: _finish,
              child: const Text('Add sticker'),
            ),
          ],
        ),
      );
    }
    if (widget.mode == 'avatar') {
      return Padding(
        padding: const EdgeInsets.fromLTRB(10, 6, 10, 10),
        child: SizedBox(
          width: double.infinity,
          child: ElevatedButton(
            style: ElevatedButton.styleFrom(backgroundColor: _kAccent, foregroundColor: Colors.white, shape: const StadiumBorder(), padding: const EdgeInsets.symmetric(vertical: 13)),
            onPressed: _finish,
            child: const Text('Set photo'),
          ),
        ),
      );
    }
    return Padding(
      padding: const EdgeInsets.fromLTRB(8, 4, 8, 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          Expanded(
            child: Container(
              decoration: BoxDecoration(color: const Color(0xFF2A2A2C), borderRadius: BorderRadius.circular(22)),
              child: TextField(
                controller: _caption,
                maxLines: 4,
                minLines: 1,
                textCapitalization: TextCapitalization.sentences,
                style: const TextStyle(color: Colors.white),
                decoration: const InputDecoration(
                  hintText: 'Add a caption...',
                  hintStyle: TextStyle(color: Colors.white38),
                  border: InputBorder.none,
                  contentPadding: EdgeInsets.symmetric(horizontal: 16, vertical: 11),
                ),
              ),
            ),
          ),
          const SizedBox(width: 8),
          GestureDetector(
            onTap: _finish,
            child: Stack(
              clipBehavior: Clip.none,
              children: [
                const CircleAvatar(radius: 24, backgroundColor: _kAccent, child: Icon(Icons.send, color: Colors.white)),
                if (_items.length > 1)
                  Positioned(
                    top: -4,
                    right: -4,
                    child: Container(
                      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                      decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(10)),
                      child: Text('${_items.length}', style: const TextStyle(color: Colors.black, fontSize: 11, fontWeight: FontWeight.w800)),
                    ),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
