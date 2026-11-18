import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:emoji_picker_flutter/emoji_picker_flutter.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:image_picker/image_picker.dart';
import 'package:intl/intl.dart';
import 'package:open_filex/open_filex.dart';
import 'package:path_provider/path_provider.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';
import 'package:video_player/video_player.dart';

import '../../providers/auth_provider.dart' show LumaAuthProvider;
import '../../services/cloudinary_service.dart';

const Color kLumaGold = Color(0xFFD4A73A);
const Color kLumaGoldSoft = Color(0xFFF2D27A);
const Color kTelegramBlue = Color(0xFF3390EC);

// ════════════════════════════════════════════════════════════════════
// Shared small widgets
// ════════════════════════════════════════════════════════════════════
class LumaStarBadge extends StatelessWidget {
  final double size;
  const LumaStarBadge({super.key, this.size = 14});
  @override
  Widget build(BuildContext context) => Container(
        width: size,
        height: size,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          gradient: const LinearGradient(
              colors: [kLumaGoldSoft, kLumaGold],
              begin: Alignment.topLeft,
              end: Alignment.bottomRight),
          boxShadow: [
            BoxShadow(color: kLumaGold.withOpacity(0.5), blurRadius: size * 0.6)
          ],
        ),
        child:
            Icon(Icons.star_rounded, size: size * 0.7, color: Colors.white),
      );
}

class LumaStarRing extends StatefulWidget {
  final Widget child;
  final double size;
  const LumaStarRing({super.key, required this.child, this.size = 40});
  @override
  State<LumaStarRing> createState() => _LumaStarRingState();
}

class _LumaStarRingState extends State<LumaStarRing>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c;
  @override
  void initState() {
    super.initState();
    _c = AnimationController(vsync: this, duration: const Duration(seconds: 3))
      ..repeat();
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
        animation: _c,
        builder: (_, __) => Container(
          width: widget.size,
          height: widget.size,
          padding: const EdgeInsets.all(2),
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            gradient: SweepGradient(
              startAngle: _c.value * 6.283,
              endAngle: _c.value * 6.283 + 6.283,
              colors: const [
                kLumaGold,
                kLumaGoldSoft,
                Colors.transparent,
                kLumaGold
              ],
            ),
          ),
          child: ClipOval(child: widget.child),
        ),
      );
}

// ════════════════════════════════════════════════════════════════════
// Channel Screen
// ════════════════════════════════════════════════════════════════════
class ChannelChatScreen extends StatefulWidget {
  final String channelId;
  final String channelName;
  final String? channelAvatar;

  const ChannelChatScreen({
    super.key,
    required this.channelId,
    required this.channelName,
    this.channelAvatar,
  });

  @override
  State<ChannelChatScreen> createState() => _ChannelChatScreenState();
}

class _ChannelChatScreenState extends State<ChannelChatScreen> {
  final _messageController = TextEditingController();
  final _scrollController = ScrollController();
  final _picker = ImagePicker();

  String? _currentUserId;
  String? _myRole = 'subscriber'; // subscriber | admin | owner
  bool _isMePremium = false;
  bool _isMeStar = false;
  String? _channelWallpaper;
  bool _isSearching = false;
  bool _isLoading = true;

  Map<String, dynamic>? _channelData;
  bool _signaturesEnabled = false;
  bool _commentsEnabled = true;
  bool _reactionsEnabled = true;
  String _mySignature = '';
  int _subscriberCount = 0;
  bool _isMuted = false;

  List<Map<String, dynamic>> _messages = [];
  List<Map<String, dynamic>> _pinnedMessages = [];
  StreamSubscription? _messageSub;
  StreamSubscription? _channelSub;

  // View tracking
  final Set<String> _viewedMessages = {};
  final Map<String, Timer> _viewTimers = {};

  String? _activePanel;
  bool _multiSelectMode = false;
  final Set<String> _selectedIds = {};

  final Map<String, dynamic> _userCache = {};
  final Map<String, VideoPlayerController> _videoControllers = {};

  // Batched view counter — Firestore
  final Map<String, int> _pendingViewIncrements = {};
  Timer? _viewBatchTimer;

  @override
  void initState() {
    super.initState();
    _init();
  }

  Future<void> _init() async {
    final auth = Provider.of<LumaAuthProvider>(context, listen: false);
    _currentUserId = auth.user?.uid ?? auth.mockUserId;
    _mySignature = auth.displayName ?? 'Admin';
    if (_currentUserId == null) return;

    // Restore locally-cached viewed IDs to prevent re-counts
    final prefs = await SharedPreferences.getInstance();
    final cachedViews =
        prefs.getStringList('channel_${widget.channelId}_viewed') ?? [];
    _viewedMessages.addAll(cachedViews);

    _loadLocalCache();
    _listenToChannel();
    _listenToMessages();
    _listenToUserDoc();

    // Batch view counter flush every 2s
    _viewBatchTimer =
        Timer.periodic(const Duration(seconds: 2), (_) => _flushViews());
  }

  Future<void> _loadLocalCache() async {
    final prefs = await SharedPreferences.getInstance();
    final cached = prefs.getString('channel_${widget.channelId}_messages');
    if (cached != null && mounted) {
      final decoded = List<Map<String, dynamic>>.from(jsonDecode(cached));
      setState(() {
        _messages = decoded;
        _isLoading = false;
      });
    }
  }

  Future<void> _saveLocalCache(List<Map<String, dynamic>> msgs) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
        'channel_${widget.channelId}_messages', jsonEncode(msgs));
  }

  void _listenToChannel() {
    _channelSub = FirebaseFirestore.instance
        .collection('chats')
        .doc(widget.channelId)
        .snapshots()
        .listen((doc) {
      if (mounted && doc.exists) {
        final data = doc.data()!;
        setState(() {
          _channelData = data;
          _myRole = data['participants_data']?[_currentUserId]?['role'] ??
              'subscriber';
          _signaturesEnabled =
              data['settings']?['signatures_enabled'] == true;
          _commentsEnabled = data['settings']?['comments_enabled'] != false;
          _reactionsEnabled =
              data['settings']?['reactions_enabled'] != false;
          _channelWallpaper = data['wallpaper_url'];
          _subscriberCount = (data['participants'] as List?)?.length ?? 0;
          _isMuted =
              (data['muted_by'] as List?)?.contains(_currentUserId) == true;
          _isLoading = false;
        });
        _loadPinnedMessages();
      }
    });
  }

  void _listenToMessages() {
    _messageSub = FirebaseFirestore.instance
        .collection('chats')
        .doc(widget.channelId)
        .collection('messages')
        .orderBy('created_at', descending: true)
        .limit(50)
        .snapshots()
        .listen((snap) {
      if (!mounted) return;
      final loaded = snap.docs
          .map((d) => {'id': d.id, ...d.data()})
          .where((m) => m['deleted_for_everyone'] != true)
          .toList();

      for (var m in loaded) {
        final sid = m['sender_id'];
        if (sid != null && !_userCache.containsKey(sid)) _fetchUser(sid);
      }

      setState(() {
        _messages = loaded;
        _isLoading = false;
      });
      _saveLocalCache(loaded);
    });
  }

  Future<void> _fetchUser(String uid) async {
    final doc =
        await FirebaseFirestore.instance.collection('users').doc(uid).get();
    if (doc.exists && mounted) {
      setState(() => _userCache[uid] = doc.data());
    }
  }

  void _listenToUserDoc() {
    FirebaseFirestore.instance
        .collection('users')
        .doc(_currentUserId)
        .snapshots()
        .listen((doc) {
      if (mounted && doc.exists) {
        final data = doc.data()!;
        setState(() {
          _isMePremium = data['is_premium'] == true;
          _isMeStar = data['luma_star_active'] == true;
        });
      }
    });
  }

  Future<void> _loadPinnedMessages() async {
    final snap = await FirebaseFirestore.instance
        .collection('chats')
        .doc(widget.channelId)
        .collection('pinned_messages')
        .orderBy('pinned_at', descending: true)
        .limit(1)
        .get();
    if (mounted) {
      setState(() => _pinnedMessages =
          snap.docs.map((d) => {'id': d.id, ...d.data()}).toList());
    }
  }

  // ══════════════════════════════════════════════════════════════════
  // VIEW COUNTING — batch + debounced
  // ══════════════════════════════════════════════════════════════════
  void _trackView(String msgId) {
    if (_viewedMessages.contains(msgId)) return;

    _viewTimers[msgId]?.cancel();
    _viewTimers[msgId] = Timer(const Duration(seconds: 1), () async {
      if (!mounted) return;
      _viewedMessages.add(msgId);
      _pendingViewIncrements[msgId] =
          (_pendingViewIncrements[msgId] ?? 0) + 1;

      // Persist locally so we don't recount after restart
      final prefs = await SharedPreferences.getInstance();
      await prefs.setStringList('channel_${widget.channelId}_viewed',
          _viewedMessages.toList());
    });
  }

  Future<void> _flushViews() async {
    if (_pendingViewIncrements.isEmpty) return;
    final batch =
        FirebaseFirestore.instance.batch();
    _pendingViewIncrements.forEach((msgId, inc) {
      batch.update(
          FirebaseFirestore.instance
              .collection('chats')
              .doc(widget.channelId)
              .collection('messages')
              .doc(msgId),
          {'views': FieldValue.increment(inc)});
    });
    _pendingViewIncrements.clear();
    try {
      await batch.commit();
    } catch (_) {}
  }

  String _formatViews(int views) {
    if (views >= 1000000) return '${(views / 1000000).toStringAsFixed(1)}M';
    if (views >= 1000) return '${(views / 1000).toStringAsFixed(1)}K';
    return views.toString();
  }

  bool _isSenderStar(String? uid) {
    if (uid == null) return false;
    if (uid == _currentUserId) return _isMeStar;
    return _userCache[uid]?['luma_star_active'] == true;
  }

  // ══════════════════════════════════════════════════════════════════
  // SENDING
  // ══════════════════════════════════════════════════════════════════
  Future<void> _sendPost({bool silent = false, DateTime? scheduleAt}) async {
    final text = _messageController.text.trim();
    if (text.isEmpty) return;
    if (!_isAdmin) {
      _showSnack('Only admins can post');
      return;
    }

    _messageController.clear();
    final msgId = const Uuid().v4();

    await FirebaseFirestore.instance
        .collection('chats')
        .doc(widget.channelId)
        .collection('messages')
        .doc(msgId)
        .set({
      'id': msgId,
      'sender_id': _currentUserId,
      'text': text,
      'type': 'text',
      'media_type': 'text',
      'created_at': scheduleAt != null
          ? Timestamp.fromDate(scheduleAt)
          : FieldValue.serverTimestamp(),
      'is_silent': silent,
      'signature': _signaturesEnabled ? _mySignature : null,
      'signature_uid': _currentUserId,
      'views': 0,
      'is_read': true,
    });

    if (scheduleAt != null) {
      _showSnack(
          'Post scheduled for ${DateFormat('MMM d, HH:mm').format(scheduleAt)}');
    }
  }

  Future<void> _pickAndSendMedia(String type) async {
    if (!_isAdmin) return;
    final x = type == 'image'
        ? await _picker.pickImage(
            source: ImageSource.gallery, imageQuality: 90)
        : await _picker.pickVideo(source: ImageSource.gallery);
    if (x == null) return;

    final file = File(x.path);
    final size = await file.length();
    final double limitGb =
        _isMeStar ? 10 : _isMePremium ? 5 : 0.2;
    final limit = limitGb * 1024 * 1024 * 1024;
    if (size > limit) {
      _showSnack(_isMeStar
          ? 'Max 10GB for Luma Star'
          : _isMePremium
              ? 'Max 5GB for Premium'
              : 'Upgrade for larger uploads');
      return;
    }

    _showSnack('Uploading...');
    final url = type == 'image'
        ? await CloudinaryService.uploadImage(file, 'luma/channels')
        : await CloudinaryService.uploadVideo(file, 'luma/channels');
    if (url == null) return;
    if (mounted) ScaffoldMessenger.of(context).hideCurrentSnackBar();

    final msgId = const Uuid().v4();
    await FirebaseFirestore.instance
        .collection('chats')
        .doc(widget.channelId)
        .collection('messages')
        .doc(msgId)
        .set({
      'id': msgId,
      'sender_id': _currentUserId,
      'type': type,
      'media_type': type,
      'media_url': url,
      'created_at': FieldValue.serverTimestamp(),
      'signature': _signaturesEnabled ? _mySignature : null,
      'signature_uid': _currentUserId,
      'views': 0,
    });
  }

  Future<void> _downloadAndOpen(String url, String type) async {
    showDialog(
        context: context,
        barrierDismissible: false,
        builder: (_) => const Center(child: CircularProgressIndicator()));
    try {
      final response = await http.get(Uri.parse(url));
      final dir = await getApplicationDocumentsDirectory();
      final file = File(
          '${dir.path}/channel_${DateTime.now().millisecondsSinceEpoch}.${type == 'image' ? 'jpg' : 'mp4'}');
      await file.writeAsBytes(response.bodyBytes);
      if (mounted) {
        Navigator.pop(context);
        if (type == 'image') {
          Navigator.push(
              context,
              MaterialPageRoute(
                  builder: (_) => _ImageViewerScreen(imagePath: file.path)));
        } else {
          await OpenFilex.open(file.path);
        }
      }
    } catch (e) {
      if (mounted) {
        Navigator.pop(context);
        _showSnack('Download failed: $e');
      }
    }
  }

  void _showSnack(String s) =>
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(s)));

  bool get _isAdmin => _myRole == 'owner' || _myRole == 'admin';
  bool get _isOwner => _myRole == 'owner';

  @override
  void dispose() {
    _messageSub?.cancel();
    _channelSub?.cancel();
    _messageController.dispose();
    _scrollController.dispose();
    for (final t in _viewTimers.values) {
      t.cancel();
    }
    for (final v in _videoControllers.values) {
      v.dispose();
    }
    _viewBatchTimer?.cancel();
    _flushViews();
    super.dispose();
  }

  // ══════════════════════════════════════════════════════════════════
  // BUILD
  // ══════════════════════════════════════════════════════════════════
  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;

    if (_isLoading) {
      return Scaffold(
          body: Center(
              child: CircularProgressIndicator(
                  color: theme.colorScheme.primary)));
    }

    return Scaffold(
      backgroundColor: theme.scaffoldBackgroundColor,
      appBar: PreferredSize(
        preferredSize: const Size.fromHeight(60),
        child: Container(
          color: isDark ? const Color(0xFF17212B) : const Color(0xFF527DA3),
          child: SafeArea(
            child: _isSearching
                ? _buildSearchBar(theme)
                : _buildHeader(theme),
          ),
        ),
      ),
      body: Stack(
        children: [
          if (_channelWallpaper != null)
            Positioned.fill(
              child: Image.network(_channelWallpaper!,
                  fit: BoxFit.cover,
                  opacity: const AlwaysStoppedAnimation(0.2)),
            ),
          Column(
            children: [
              if (_pinnedMessages.isNotEmpty) _buildPinnedBanner(theme),
              Expanded(
                child: ListView.builder(
                  controller: _scrollController,
                  reverse: true,
                  padding: const EdgeInsets.all(8),
                  itemCount: _messages.length,
                  itemBuilder: (context, i) =>
                      _buildPost(_messages[i], theme, isDark),
                ),
              ),
              if (_multiSelectMode) _buildMultiSelectBar(theme),
              if (_isAdmin)
                _buildAdminComposer(theme, isDark)
              else
                _buildReadOnlyFooter(theme),
              if (_activePanel != null) _buildPanel(theme, isDark),
            ],
          ),
        ],
      ),
    );
  }

  // ── HEADER ────────────────────────────────────────────────────────
  Widget _buildHeader(ThemeData theme) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 8),
      child: Row(
        children: [
          // Circular back button (separate)
          Material(
            color: Colors.black12,
            shape: const CircleBorder(),
            child: InkWell(
              customBorder: const CircleBorder(),
              onTap: () => Navigator.pop(context),
              child: const SizedBox(
                  width: 40,
                  height: 40,
                  child: Icon(Icons.arrow_back,
                      color: Colors.white, size: 20)),
            ),
          ),
          const SizedBox(width: 8),
          // Centered pill: avatar + name + subs
          Expanded(
            child: GestureDetector(
              onTap: () => Navigator.pushNamed(context, '/channel_info',
                  arguments: {'channelId': widget.channelId}),
              child: Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                decoration: BoxDecoration(
                    color: Colors.black12,
                    borderRadius: BorderRadius.circular(22)),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    CircleAvatar(
                      radius: 16,
                      backgroundImage: widget.channelAvatar != null
                          ? NetworkImage(widget.channelAvatar!)
                          : null,
                      child: widget.channelAvatar == null
                          ? const Icon(Icons.campaign,
                              color: Colors.white, size: 18)
                          : null,
                    ),
                    const SizedBox(width: 10),
                    Flexible(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Flexible(
                                child: Text(widget.channelName,
                                    style: const TextStyle(
                                        color: Colors.white,
                                        fontSize: 15,
                                        fontWeight: FontWeight.w600),
                                    overflow: TextOverflow.ellipsis),
                              ),
                              const SizedBox(width: 4),
                              const Icon(Icons.verified,
                                  color: Color(0xFF6FB9F3), size: 14),
                              if (_isMeStar) ...[
                                const SizedBox(width: 6),
                                const LumaStarBadge(size: 14),
                              ],
                            ],
                          ),
                          Text('$_subscriberCount subscribers',
                              style: const TextStyle(
                                  color: Colors.white70, fontSize: 12)),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
          const SizedBox(width: 8),
          // Search icon
          Material(
            color: Colors.black12,
            shape: const CircleBorder(),
            child: InkWell(
              customBorder: const CircleBorder(),
              onTap: () => setState(() => _isSearching = true),
              child: const SizedBox(
                  width: 40,
                  height: 40,
                  child: Icon(Icons.search,
                      color: Colors.white, size: 20)),
            ),
          ),
          const SizedBox(width: 6),
          // Circular 3-dot
          Material(
            color: Colors.black12,
            shape: const CircleBorder(),
            child: InkWell(
              customBorder: const CircleBorder(),
              onTap: _showMoreMenu,
              child: const SizedBox(
                  width: 40,
                  height: 40,
                  child: Icon(Icons.more_vert,
                      color: Colors.white, size: 20)),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildSearchBar(ThemeData theme) {
    return Row(children: [
      Material(
        color: Colors.black12,
        shape: const CircleBorder(),
        child: InkWell(
          customBorder: const CircleBorder(),
          onTap: () => setState(() => _isSearching = false),
          child: const SizedBox(
              width: 40,
              height: 40,
              child: Icon(Icons.arrow_back, color: Colors.white, size: 20)),
        ),
      ),
      const SizedBox(width: 8),
      const Expanded(
        child: TextField(
          autofocus: true,
          style: TextStyle(color: Colors.white),
          decoration: InputDecoration(
              hintText: 'Search posts...',
              hintStyle: TextStyle(color: Colors.white54),
              border: InputBorder.none),
        ),
      ),
    ]);
  }

  // ── READ-ONLY FOOTER for subscribers ──────────────────────────────
  Widget _buildReadOnlyFooter(ThemeData theme) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      color: theme.scaffoldBackgroundColor,
      child: SafeArea(
        top: false,
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.campaign_outlined,
                size: 16,
                color: theme.colorScheme.onSurface.withOpacity(0.4)),
            const SizedBox(width: 8),
            Flexible(
              child: Text(
                _commentsEnabled
                    ? 'Broadcast channel • Comment on posts only'
                    : 'Broadcast channel • Read only',
                style: TextStyle(
                    color: theme.colorScheme.onSurface.withOpacity(0.4),
                    fontSize: 12.5),
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ],
        ),
      ),
    );
  }

  // ── ADMIN COMPOSER ────────────────────────────────────────────────
  Widget _buildAdminComposer(ThemeData theme, bool isDark) {
    return Container(
      padding: const EdgeInsets.fromLTRB(6, 6, 6, 6),
      color: isDark ? const Color(0xFF17212B) : const Color(0xFFF0F0F0),
      child: SafeArea(
        top: false,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (_signaturesEnabled)
              Padding(
                padding: const EdgeInsets.only(left: 12, bottom: 6),
                child: Row(children: [
                  Container(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 8, vertical: 4),
                    decoration: BoxDecoration(
                        color: kTelegramBlue.withOpacity(0.1),
                        borderRadius: BorderRadius.circular(12)),
                    child: Text('Posting as $_mySignature',
                        style: const TextStyle(
                            color: kTelegramBlue,
                            fontSize: 12,
                            fontWeight: FontWeight.bold)),
                  ),
                  if (_isMeStar) ...[
                    const SizedBox(width: 6),
                    Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 8, vertical: 4),
                      decoration: BoxDecoration(
                        color: kLumaGold.withOpacity(0.15),
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(
                            color: kLumaGold.withOpacity(0.4)),
                      ),
                      child: const Row(children: [
                        Icon(Icons.star_rounded,
                            color: kLumaGold, size: 12),
                        SizedBox(width: 4),
                        Text('Star',
                            style: TextStyle(
                                color: kLumaGold,
                                fontSize: 11,
                                fontWeight: FontWeight.w700,
                                letterSpacing: 0.4)),
                      ]),
                    ),
                  ],
                ]),
              ),
            Row(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                IconButton(
                  icon: Icon(
                      _activePanel == 'emoji'
                          ? Icons.keyboard
                          : Icons.emoji_emotions_outlined,
                      color: theme.colorScheme.onSurface.withOpacity(0.6)),
                  onPressed: () {
                    if (_activePanel == 'emoji') {
                      setState(() => _activePanel = null);
                      SystemChannels.textInput
                          .invokeMethod('TextInput.show');
                    } else {
                      FocusScope.of(context).unfocus();
                      setState(() => _activePanel = 'emoji');
                    }
                  },
                ),
                Expanded(
                  child: Container(
                    decoration: BoxDecoration(
                        color: isDark
                            ? const Color(0xFF242F3D)
                            : Colors.white,
                        borderRadius: BorderRadius.circular(24)),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.end,
                      children: [
                        Expanded(
                          child: TextField(
                            controller: _messageController,
                            minLines: 1,
                            maxLines: null,
                            decoration: const InputDecoration(
                                hintText: 'Broadcast a message...',
                                border: InputBorder.none,
                                contentPadding: EdgeInsets.symmetric(
                                    horizontal: 16, vertical: 12)),
                            onTap: () {
                              if (_activePanel != null) {
                                setState(() => _activePanel = null);
                              }
                            },
                          ),
                        ),
                        IconButton(
                            icon: Icon(Icons.attach_file,
                                color: theme.colorScheme.onSurface
                                    .withOpacity(0.6)),
                            onPressed: _showAttachmentSheet),
                        IconButton(
                            icon: Icon(Icons.camera_alt_outlined,
                                color: theme.colorScheme.onSurface
                                    .withOpacity(0.6)),
                            onPressed: () => _pickAndSendMedia('image')),
                      ],
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                GestureDetector(
                  onTap: () => _sendPost(),
                  onLongPress: _showSendOptions,
                  child: CircleAvatar(
                    radius: 24,
                    backgroundColor:
                        _isMeStar ? kLumaGold : kTelegramBlue,
                    child: const Icon(Icons.send,
                        color: Colors.white, size: 22),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  void _showSendOptions() {
    showModalBottomSheet(
        context: context,
        builder: (_) => SafeArea(
              child: Column(mainAxisSize: MainAxisSize.min, children: [
                ListTile(
                    leading: const Icon(Icons.notifications_off),
                    title: const Text('Send Silently'),
                    onTap: () {
                      Navigator.pop(context);
                      _sendPost(silent: true);
                    }),
                ListTile(
                    leading: const Icon(Icons.schedule),
                    title: const Text('Schedule Post'),
                    onTap: () {
                      Navigator.pop(context);
                      _showScheduleDialog();
                    }),
              ]),
            ));
  }

  void _showScheduleDialog() async {
    final date = await showDatePicker(
        context: context,
        firstDate: DateTime.now(),
        lastDate: DateTime.now().add(const Duration(days: 30)));
    if (date == null) return;
    final time = await showTimePicker(
        context: context, initialTime: TimeOfDay.now());
    if (time == null) return;
    final dt = DateTime(
        date.year, date.month, date.day, time.hour, time.minute);
    _sendPost(scheduleAt: dt);
  }

  Widget _buildPanel(ThemeData theme, bool isDark) {
    if (_activePanel == 'emoji') {
      return SizedBox(
          height: 300,
          child: EmojiPicker(
              onEmojiSelected: (category, emoji) =>
                  _messageController.text += emoji.emoji,
              config: Config(
                  height: 300,
                  emojiViewConfig: EmojiViewConfig(
                      backgroundColor: isDark
                          ? const Color(0xFF17212B)
                          : Colors.white,
                      columns: 8,
                      emojiSizeMax: 28))));
    }
    return const SizedBox.shrink();
  }

  void _showAttachmentSheet() {
    showModalBottomSheet(
        context: context,
        builder: (_) => SafeArea(
              child: Column(mainAxisSize: MainAxisSize.min, children: [
                ListTile(
                    leading: const Icon(Icons.image),
                    title: const Text('Photo'),
                    onTap: () {
                      Navigator.pop(context);
                      _pickAndSendMedia('image');
                    }),
                ListTile(
                    leading: const Icon(Icons.videocam),
                    title: const Text('Video'),
                    onTap: () {
                      Navigator.pop(context);
                      _pickAndSendMedia('video');
                    }),
              ]),
            ));
  }

  // ── PINNED BANNER ─────────────────────────────────────────────────
  Widget _buildPinnedBanner(ThemeData theme) {
    final p = _pinnedMessages.first;
    final msg = _messages.firstWhere((m) => m['id'] == p['message_id'],
        orElse: () => {});
    return Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        color: kTelegramBlue.withOpacity(0.1),
        child: Row(children: [
          const Icon(Icons.push_pin, size: 16, color: kTelegramBlue),
          const SizedBox(width: 8),
          Expanded(
              child: Text((msg['text'] ?? 'Pinned').toString(),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 13))),
          if (_isAdmin)
            IconButton(
                icon: const Icon(Icons.close, size: 16),
                onPressed: () async {
                  await FirebaseFirestore.instance
                      .collection('chats')
                      .doc(widget.channelId)
                      .collection('pinned_messages')
                      .doc(p['id'])
                      .delete();
                  _loadPinnedMessages();
                }),
        ]));
  }

  // ── POST BUBBLE ───────────────────────────────────────────────────
  Widget _buildPost(
      Map<String, dynamic> msg, ThemeData theme, bool isDark) {
    final isSelected = _selectedIds.contains(msg['id']);
    final isStarPost = _isSenderStar(msg['sender_id'] as String?);
    _trackView(msg['id']);

    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: GestureDetector(
        onLongPress: () => _showMessageMenu(msg),
        onTap: _multiSelectMode
            ? () => setState(() {
                  isSelected
                      ? _selectedIds.remove(msg['id'])
                      : _selectedIds.add(msg['id']);
                })
            : null,
        child: Container(
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: isSelected
                ? kTelegramBlue.withOpacity(0.3)
                : (isDark ? const Color(0xFF1F2C34) : Colors.white),
            borderRadius: BorderRadius.circular(16),
            border: Border(
                left: BorderSide(
                    color: isStarPost ? kLumaGold : kTelegramBlue,
                    width: isStarPost ? 5 : 4)),
            boxShadow: isStarPost
                ? [
                    BoxShadow(
                        color: kLumaGold.withOpacity(0.12),
                        blurRadius: 10,
                        offset: const Offset(0, 2)),
                  ]
                : null,
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (msg['signature'] != null)
                Padding(
                  padding: const EdgeInsets.only(bottom: 6),
                  child: Row(children: [
                    if (isStarPost) ...[
                      const LumaStarBadge(size: 12),
                      const SizedBox(width: 6),
                    ],
                    Flexible(
                      child: Text(msg['signature'],
                          style: TextStyle(
                              fontSize: 12,
                              fontWeight: FontWeight.bold,
                              color: isStarPost
                                  ? kLumaGold
                                  : kTelegramBlue)),
                    ),
                  ]),
                ),
              if (msg['media_type'] == 'image' && msg['media_url'] != null)
                GestureDetector(
                    onTap: () =>
                        _downloadAndOpen(msg['media_url'], 'image'),
                    child: Stack(alignment: Alignment.center, children: [
                      ClipRRect(
                          borderRadius: BorderRadius.circular(8),
                          child: CachedNetworkImage(
                              imageUrl: msg['media_url'],
                              width: double.infinity,
                              fit: BoxFit.cover)),
                      Container(
                          padding: const EdgeInsets.all(8),
                          decoration: const BoxDecoration(
                              color: Colors.black54, shape: BoxShape.circle),
                          child: const Icon(Icons.download,
                              color: Colors.white)),
                    ])),
              if (msg['media_type'] == 'video' && msg['media_url'] != null)
                _buildVideoBubble(msg['media_url']),
              if ((msg['text'] ?? '').toString().isNotEmpty)
                Padding(
                    padding: const EdgeInsets.symmetric(vertical: 4),
                    child: Text(msg['text'],
                        style: TextStyle(
                            color: theme.colorScheme.onSurface,
                            fontSize: 15))),
              const SizedBox(height: 8),
              Row(children: [
                Icon(Icons.remove_red_eye,
                    size: 14,
                    color: isStarPost ? kLumaGold : Colors.grey),
                const SizedBox(width: 4),
                Text(_formatViews((msg['views'] ?? 0) as int),
                    style: TextStyle(
                        fontSize: 12,
                        color: isStarPost
                            ? kLumaGold.withOpacity(0.85)
                            : Colors.grey)),
                const Spacer(),
                if (_commentsEnabled)
                  GestureDetector(
                    onTap: () => Navigator.pushNamed(context, '/comments',
                        arguments: {'postId': msg['id']}),
                    child: Row(children: [
                      const Icon(Icons.comment,
                          size: 16, color: kTelegramBlue),
                      const SizedBox(width: 4),
                      Text('${msg['comments_count'] ?? 0}',
                          style: const TextStyle(
                              fontSize: 12, color: kTelegramBlue))
                    ]),
                  ),
                const SizedBox(width: 12),
                Text(
                    DateFormat('HH:mm').format(
                        (msg['created_at'] as Timestamp?)?.toDate() ??
                            DateTime.now()),
                    style:
                        const TextStyle(fontSize: 11, color: Colors.grey)),
              ]),
              // Reactions row (only if channel enables it and any exist)
              if (_reactionsEnabled &&
                  msg['reactions'] is Map &&
                  (msg['reactions'] as Map).isNotEmpty)
                Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: _buildReactionsRow(msg),
                ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildReactionsRow(Map<String, dynamic> msg) {
    final reactions = (msg['reactions'] as Map).cast<String, dynamic>();
    return Wrap(
        spacing: 6,
        children: reactions.entries.map((e) {
          final emoji = e.key;
          final users = (e.value is List) ? (e.value as List) : [];
          final mine = users.contains(_currentUserId);
          return GestureDetector(
            onTap: () => _toggleReaction(msg['id'], emoji),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
              decoration: BoxDecoration(
                  color: mine
                      ? kTelegramBlue.withOpacity(0.15)
                      : Colors.black.withOpacity(0.06),
                  borderRadius: BorderRadius.circular(12),
                  border: mine
                      ? Border.all(
                          color: kTelegramBlue.withOpacity(0.4))
                      : null),
              child: Text('$emoji ${users.length}',
                  style: TextStyle(
                      fontSize: 12,
                      color: mine ? kTelegramBlue : Colors.grey[700])),
            ),
          );
        }).toList());
  }

  Future<void> _toggleReaction(String msgId, String emoji) async {
    final ref = FirebaseFirestore.instance
        .collection('chats')
        .doc(widget.channelId)
        .collection('messages')
        .doc(msgId);
    final snap = await ref.get();
    final reactions =
        (snap.data()?['reactions'] as Map?)?.cast<String, dynamic>() ?? {};
    final list = ((reactions[emoji] as List?) ?? []).toList();
    if (list.contains(_currentUserId)) {
      list.remove(_currentUserId);
    } else {
      list.add(_currentUserId);
    }
    if (list.isEmpty) {
      reactions.remove(emoji);
    } else {
      reactions[emoji] = list;
    }
    await ref.update({'reactions': reactions});
  }

  Widget _buildVideoBubble(String url) {
    final controller = _videoControllers.putIfAbsent(url, () {
      final c = VideoPlayerController.networkUrl(Uri.parse(url));
      c.initialize().then((_) => setState(() {}));
      return c;
    });
    return GestureDetector(
        onTap: () {
          if (controller.value.isPlaying) {
            controller.pause();
          } else {
            controller.play();
          }
          setState(() {});
        },
        child: ClipRRect(
            borderRadius: BorderRadius.circular(8),
            child: Container(
                height: 200,
                color: Colors.black,
                child: controller.value.isInitialized
                    ? Stack(alignment: Alignment.center, children: [
                        VideoPlayer(controller),
                        Icon(
                            controller.value.isPlaying
                                ? Icons.pause
                                : Icons.play_arrow,
                            color: Colors.white,
                            size: 40)
                      ])
                    : const Center(child: CircularProgressIndicator()))));
  }

  void _showMessageMenu(Map<String, dynamic> msg) {
    final isStarPost = _isSenderStar(msg['sender_id'] as String?);
    showModalBottomSheet(
        context: context,
        builder: (_) => SafeArea(
              child: Column(mainAxisSize: MainAxisSize.min, children: [
                if (isStarPost)
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.symmetric(
                        horizontal: 16, vertical: 8),
                    color: kLumaGold.withOpacity(0.08),
                    child: const Row(children: [
                      LumaStarBadge(size: 14),
                      SizedBox(width: 8),
                      Text('Star post',
                          style: TextStyle(
                              color: kLumaGold,
                              fontSize: 12,
                              fontWeight: FontWeight.w700,
                              letterSpacing: 0.5)),
                    ]),
                  ),
                ListTile(
                    leading: const Icon(Icons.copy),
                    title: const Text('Copy'),
                    onTap: () {
                      Clipboard.setData(
                          ClipboardData(text: msg['text'] ?? ''));
                      Navigator.pop(context);
                    }),
                if (_reactionsEnabled)
                  ListTile(
                      leading: const Icon(Icons.emoji_emotions_outlined),
                      title: const Text('React'),
                      onTap: () {
                        Navigator.pop(context);
                        _showReactionPicker(msg['id']);
                      }),
                if (_isAdmin) ...[
                  ListTile(
                      leading: const Icon(Icons.push_pin),
                      title: const Text('Pin'),
                      onTap: () async {
                        Navigator.pop(context);
                        await FirebaseFirestore.instance
                            .collection('chats')
                            .doc(widget.channelId)
                            .collection('pinned_messages')
                            .doc(msg['id'])
                            .set({
                          'message_id': msg['id'],
                          'pinned_at': FieldValue.serverTimestamp()
                        });
                        _loadPinnedMessages();
                      }),
                  ListTile(
                      leading:
                          const Icon(Icons.delete, color: Colors.red),
                      title: const Text('Delete',
                          style: TextStyle(color: Colors.red)),
                      onTap: () async {
                        Navigator.pop(context);
                        await FirebaseFirestore.instance
                            .collection('chats')
                            .doc(widget.channelId)
                            .collection('messages')
                            .doc(msg['id'])
                            .update(
                                {'deleted_for_everyone': true, 'text': 'Deleted'});
                      }),
                ],
                ListTile(
                    leading: const Icon(Icons.select_all),
                    title: const Text('Select'),
                    onTap: () {
                      Navigator.pop(context);
                      setState(() {
                        _multiSelectMode = true;
                        _selectedIds.add(msg['id']);
                      });
                    }),
              ]),
            ));
  }

  void _showReactionPicker(String msgId) {
    const emojis = ['👍', '❤️', '🔥', '😂', '😮', '😢', '🎉', '👏'];
    showModalBottomSheet(
        context: context,
        builder: (_) => SafeArea(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Wrap(
                    spacing: 12,
                    runSpacing: 12,
                    children: emojis.map((e) {
                      return GestureDetector(
                        onTap: () {
                          Navigator.pop(context);
                          _toggleReaction(msgId, e);
                        },
                        child: Container(
                          width: 52,
                          height: 52,
                          decoration: BoxDecoration(
                              color: Colors.black.withOpacity(0.06),
                              borderRadius: BorderRadius.circular(14)),
                          alignment: Alignment.center,
                          child: Text(e,
                              style: const TextStyle(fontSize: 26)),
                        ),
                      );
                    }).toList()),
              ),
            ));
  }

  // ── 3-DOT MENU ────────────────────────────────────────────────────
  void _showMoreMenu() {
    showModalBottomSheet(
        context: context,
        builder: (_) => SafeArea(
              child: Column(mainAxisSize: MainAxisSize.min, children: [
                ListTile(
                    leading: const Icon(Icons.info_outline),
                    title: const Text('Channel Info'),
                    onTap: () {
                      Navigator.pop(context);
                      Navigator.pushNamed(context, '/channel_info',
                          arguments: {'channelId': widget.channelId});
                    }),
                ListTile(
                    leading: const Icon(Icons.share_outlined),
                    title: const Text('Share Link'),
                    onTap: () {
                      Navigator.pop(context);
                      _showSnack('Channel link copied');
                    }),
                ListTile(
                    leading: Icon(
                        _isMuted
                            ? Icons.notifications_active_outlined
                            : Icons.notifications_off_outlined),
                    title: Text(_isMuted ? 'Unmute' : 'Mute'),
                    onTap: () async {
                      Navigator.pop(context);
                      await FirebaseFirestore.instance
                          .collection('chats')
                          .doc(widget.channelId)
                          .update({
                        'muted_by': _isMuted
                            ? FieldValue.arrayRemove([_currentUserId])
                            : FieldValue.arrayUnion([_currentUserId])
                      });
                    }),
                if (_isAdmin) ...[
                  ListTile(
                      leading: const Icon(Icons.edit_outlined),
                      title: const Text('Edit Channel'),
                      onTap: () {
                        Navigator.pop(context);
                        Navigator.pushNamed(context, '/edit_channel',
                            arguments: {'channelId': widget.channelId});
                      }),
                  ListTile(
                      leading: const Icon(Icons.forum_outlined),
                      title: Text(
                          _channelData?['discussion_chat_id'] != null
                              ? 'Unlink Discussion'
                              : 'Link Discussion'),
                      onTap: () {
                        Navigator.pop(context);
                        _toggleDiscussionLink();
                      }),
                  if (_subscriberCount >= 500)
                    ListTile(
                        leading: const Icon(Icons.bar_chart),
                        title: const Text('Channel Stats'),
                        onTap: () {
                          Navigator.pop(context);
                          Navigator.pushNamed(context, '/channel_stats',
                              arguments: {'channelId': widget.channelId});
                        }),
                  ListTile(
                      leading: const Icon(Icons.rocket_launch_outlined),
                      title: const Text('Boost Channel'),
                      onTap: () {
                        Navigator.pop(context);
                        _showSnack('Boost coming soon');
                      }),
                  if (_isMePremium || _isMeStar)
                    ListTile(
                        leading: const Icon(Icons.wallpaper_outlined),
                        title: const Text('Set Wallpaper'),
                        onTap: () {
                          Navigator.pop(context);
                          _setWallpaper();
                        }),
                ],
                ListTile(
                    leading: const Icon(Icons.cleaning_services_outlined),
                    title: const Text('Clear History'),
                    onTap: () async {
                      Navigator.pop(context);
                      final prefs = await SharedPreferences.getInstance();
                      await prefs.remove(
                          'channel_${widget.channelId}_messages');
                      setState(() => _messages = []);
                    }),
                if (!_isAdmin)
                  ListTile(
                      leading:
                          const Icon(Icons.exit_to_app, color: Colors.red),
                      title: const Text('Leave Channel',
                          style: TextStyle(color: Colors.red)),
                      onTap: () {
                        Navigator.pop(context);
                        _leaveChannel();
                      }),
                if (_isOwner)
                  ListTile(
                      leading: const Icon(Icons.delete_forever,
                          color: Colors.red),
                      title: const Text('Delete Channel',
                          style: TextStyle(color: Colors.red)),
                      onTap: () {
                        Navigator.pop(context);
                        _deleteChannel();
                      }),
              ]),
            ));
  }

  Future<void> _toggleDiscussionLink() async {
    if (_channelData?['discussion_chat_id'] != null) {
      await FirebaseFirestore.instance
          .collection('chats')
          .doc(widget.channelId)
          .update({'discussion_chat_id': FieldValue.delete()});
      _showSnack('Discussion unlinked');
    } else {
      Navigator.pushNamed(context, '/link_discussion',
          arguments: {'channelId': widget.channelId});
    }
  }

  Future<void> _leaveChannel() async {
    await FirebaseFirestore.instance
        .collection('chats')
        .doc(widget.channelId)
        .update({
      'participants': FieldValue.arrayRemove([_currentUserId]),
    });
    if (mounted) Navigator.pop(context);
  }

  Future<void> _deleteChannel() async {
    final confirm = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
              title: const Text('Delete Channel?'),
              content: const Text(
                  'This will permanently delete the channel and all posts.'),
              actions: [
                TextButton(
                    onPressed: () => Navigator.pop(ctx, false),
                    child: const Text('Cancel')),
                TextButton(
                    onPressed: () => Navigator.pop(ctx, true),
                    child: const Text('Delete',
                        style: TextStyle(color: Colors.red))),
              ],
            ));
    if (confirm != true) return;
    await FirebaseFirestore.instance
        .collection('chats')
        .doc(widget.channelId)
        .delete();
    if (mounted) Navigator.pop(context);
  }

  Future<void> _setWallpaper() async {
    // Admin with premium/star can propose; owner sets immediately.
    final x = await _picker.pickImage(
        source: ImageSource.gallery, imageQuality: 85);
    if (x == null) return;
    _showSnack('Uploading wallpaper...');
    final url = await CloudinaryService.uploadImage(
        File(x.path), 'luma/channel_walls');
    if (url == null) return;

    if (_isOwner) {
      await FirebaseFirestore.instance
          .collection('chats')
          .doc(widget.channelId)
          .update({'wallpaper_url': url});
      _showSnack('Wallpaper set for everyone');
    } else {
      // Admin proposes — owner must approve
      await FirebaseFirestore.instance
          .collection('chats')
          .doc(widget.channelId)
          .collection('wallpaper_requests')
          .add({
        'requested_by': _currentUserId,
        'url': url,
        'created_at': FieldValue.serverTimestamp(),
        'status': 'pending',
      });
      _showSnack('Wallpaper request sent to owner');
    }
  }

  Widget _buildMultiSelectBar(ThemeData theme) {
    return Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        color: theme.colorScheme.surfaceVariant.withOpacity(0.5),
        child: Row(children: [
          IconButton(
              icon: const Icon(Icons.close),
              onPressed: () => setState(() {
                    _multiSelectMode = false;
                    _selectedIds.clear();
                  })),
          Text('${_selectedIds.length} selected',
              style: const TextStyle(fontWeight: FontWeight.bold)),
          const Spacer(),
          if (_isAdmin)
            IconButton(
                icon: const Icon(Icons.delete, color: Colors.red),
                onPressed: () async {
                  for (final id in _selectedIds) {
                    await FirebaseFirestore.instance
                        .collection('chats')
                        .doc(widget.channelId)
                        .collection('messages')
                        .doc(id)
                        .update(
                            {'deleted_for_everyone': true, 'text': 'Deleted'});
                  }
                  setState(() {
                    _multiSelectMode = false;
                    _selectedIds.clear();
                  });
                }),
        ]));
  }
}

class _ImageViewerScreen extends StatelessWidget {
  final String imagePath;
  const _ImageViewerScreen({required this.imagePath});
  @override
  Widget build(BuildContext context) => Scaffold(
        backgroundColor: Colors.black,
        appBar: AppBar(
            backgroundColor: Colors.black,
            leading: IconButton(
                icon: const Icon(Icons.close, color: Colors.white),
                onPressed: () => Navigator.pop(context))),
        body: Center(child: Image.file(File(imagePath))),
      );
}
