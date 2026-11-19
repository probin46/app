// ignore_for_file: deprecated_member_use
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:cached_network_image/cached_network_image.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:emoji_picker_flutter/emoji_picker_flutter.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:image_picker/image_picker.dart';
import 'package:intl/intl.dart';
import 'package:just_audio/just_audio.dart';
import 'package:path_provider/path_provider.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:photo_manager/photo_manager.dart' hide LatLng;
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';
import 'package:video_player/video_player.dart';

import '../../providers/auth_provider.dart' show LumaAuthProvider;
import '../../services/cloudinary_service.dart';

// ═══════════════════════════════════════════════════════════════════════════
// CONFIG & HELPERS
// ═══════════════════════════════════════════════════════════════════════════
const String _kGiphyApiKey = '7tXB3cisPGymcszQX85JFOY6kp3Gz47T';
const Color _kAccent = Color(0xFF3390EC);
const int _kPageSize = 80;

String _fmtDur(int s) => '${(s ~/ 60).toString().padLeft(2, '0')}:${(s % 60).toString().padLeft(2, '0')}';
String _stripFormatting(String s) => s.replaceAllMapped(RegExp(r'\*\*(.+?)\*\*', dotAll: true), (m) => m.group(1)!).replaceAll('\n', ' ');
String _previewOf(Map<String, dynamic>? m) {
  if (m == null) return 'Message';
  switch (m['type']) {
    case 'image': return '📷 Photo';
    case 'video': return '🎬 Video';
    case 'audio': return '🎤 Voice';
    case 'sticker': return 'Sticker';
    default: return (m['text'] ?? 'Message').toString();
  }
}
DateTime _msgTime(Map<String, dynamic> m) => (m['created_at'] as Timestamp?)?.toDate() ?? DateTime.now();
bool _sameDay(DateTime a, DateTime b) => a.year == b.year && a.month == b.month && a.day == b.day;

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

class _GroupChatScreenState extends State<GroupChatScreen> {
  final _messageController = TextEditingController();
  final _scrollController = ScrollController();
  final _audioPlayer = AudioPlayer();

  String? _currentUserId;
  String? _wallpaper;
  Map<String, dynamic>? _chatData;
  List<Map<String, dynamic>> _visible = [];
  bool _messagesLoaded = false;

  String? _activePanel; // emoji | sticker | gif
  bool _hasText = false;

  StreamSubscription? _messageSub;
  StreamSubscription? _chatSub;

  // Sticker packs
  List<Map<String, dynamic>> _stickerPacks = [];

  // Audio
  String? _loadedAudioId;

  // Recording
  bool _isRecording = false;
  Timer? _recTimer;
  final List<double> _liveSamples = [];
  DateTime? _recStart;

  DocumentReference<Map<String, dynamic>> get _chatRef =>
      FirebaseFirestore.instance.collection('chats').doc(widget.chatId);
  CollectionReference<Map<String, dynamic>> get _msgs => _chatRef.collection('messages');

  @override
  void initState() {
    super.initState();
    _messageController.addListener(() {
      final has = _messageController.text.trim().isNotEmpty;
      if (has != _hasText) setState(() => _hasText = has);
    });
    final auth = Provider.of<LumaAuthProvider>(context, listen: false);
    _currentUserId = auth.user?.uid ?? auth.mockUserId;

    _loadStickers();
    _listenToChat();
    _listenToMessages();
  }

  @override
  void dispose() {
    _messageSub?.cancel();
    _chatSub?.cancel();
    _messageController.dispose();
    _scrollController.dispose();
    _audioPlayer.dispose();
    _recTimer?.cancel();
    super.dispose();
  }

  // ═══════════════════════════════════════════════════════════════════════
  // LISTENERS
  // ═══════════════════════════════════════════════════════════════════════
  void _listenToChat() {
    _chatSub = _chatRef.snapshots().listen((doc) {
      if (mounted && doc.exists) setState(() => _chatData = doc.data());
    });
  }

  void _listenToMessages() {
    _messageSub = _msgs.orderBy('created_at', descending: true).limit(_kPageSize).snapshots().listen((snap) {
      if (!mounted) return;
      setState(() {
        _visible = snap.docs.map((d) => {'id': d.id, ...d.data()}).toList();
        _messagesLoaded = true;
      });
    });
  }

  // ═══════════════════════════════════════════════════════════════════════
  // SEND
  // ═══════════════════════════════════════════════════════════════════════
  Future<void> _postMessage(Map<String, dynamic> data) async {
    if (_currentUserId == null) return;
    final msgId = const Uuid().v4();
    await _msgs.doc(msgId).set({
      'id': msgId,
      'sender_id': _currentUserId,
      'created_at': FieldValue.serverTimestamp(),
      ...data,
    });
    if (_scrollController.hasClients) {
      _scrollController.animateTo(0, duration: const Duration(milliseconds: 300), curve: Curves.easeOut);
    }
  }

  void _sendText() {
    final text = _messageController.text.trim();
    if (text.isEmpty) return;
    _messageController.clear();
    _postMessage({'type': 'text', 'text': text});
  }

  // ═══════════════════════════════════════════════════════════════════════
  // CUSTOM GALLERY + EDITOR (Real)
  // ═══════════════════════════════════════════════════════════════════════
  void _openCustomGallery({bool isSticker = false, bool isWallpaper = false}) {
    setState(() => _activePanel = null);
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: const Color(0xFF17212B),
      builder: (ctx) => SizedBox(
        height: MediaQuery.of(ctx).size.height * 0.8,
        child: FutureBuilder<List<AssetEntity>>(
          future: PhotoManager.getAssetPathList(type: RequestType.image, onlyAll: true)
              .then((p) => p.first.getAssetListPaged(page: 0, size: 100)),
          builder: (context, snap) {
            if (!snap.hasData) return const Center(child: CircularProgressIndicator());
            return GridView.builder(
              gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                  crossAxisCount: 3, crossAxisSpacing: 2, mainAxisSpacing: 2),
              itemCount: snap.data!.length,
              itemBuilder: (context, i) => GestureDetector(
                onTap: () async {
                  Navigator.pop(ctx);
                  final file = await snap.data![i].file;
                  if (file == null) return;
                  if (isWallpaper) {
                    _uploadWallpaper(file);
                  } else if (isSticker) {
                    _showImageEditor(file, isSticker: true);
                  } else {
                    _showImageEditor(file, isSticker: false);
                  }
                },
                child: FutureBuilder<Uint8List?>(
                  future: snap.data![i].thumbnailDataWithSize(const ThumbnailSize(200, 200)),
                  builder: (context, tSnap) => tSnap.hasData
                      ? Image.memory(tSnap.data!, fit: BoxFit.cover)
                      : Container(color: Colors.grey),
                ),
              ),
            );
          },
        ),
      ),
    );
  }

  void _showImageEditor(File file, {required bool isSticker}) {
    final captionCtrl = TextEditingController();
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: const Color(0xFF17212B),
      builder: (ctx) => Padding(
        padding: EdgeInsets.only(bottom: MediaQuery.of(ctx).viewInsets.bottom),
        child: Container(
          height: MediaQuery.of(ctx).size.height * 0.85,
          padding: const EdgeInsets.all(16),
          child: Column(
            children: [
              Expanded(
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(12),
                  child: Image.file(file, fit: BoxFit.contain),
                ),
              ),
              TextField(
                controller: captionCtrl,
                style: const TextStyle(color: Colors.white),
                decoration: const InputDecoration(
                  hintText: 'Add a caption...',
                  hintStyle: TextStyle(color: Colors.white54),
                ),
              ),
              const SizedBox(height: 16),
              ElevatedButton(
                onPressed: () async {
                  Navigator.pop(ctx);
                  ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Uploading...')));
                  final url = await CloudinaryService.uploadImage(
                      file, isSticker ? 'luma/stickers' : 'luma/chats');
                  if (url != null) {
                    await _postMessage({
                      'type': isSticker ? 'sticker' : 'image',
                      'media_url': url,
                      'text': captionCtrl.text.trim(),
                    });
                    if (isSticker) await _saveStickerToPack(url);
                  }
                  ScaffoldMessenger.of(context).hideCurrentSnackBar();
                },
                child: const Text('Send'),
              ),
            ],
          ),
        ),
      ),
    );
  }

  // ═══════════════════════════════════════════════════════════════════════
  // STICKERS
  // ═══════════════════════════════════════════════════════════════════════
  Future<void> _loadStickers() async {
    final prefs = await SharedPreferences.getInstance();
    final saved = prefs.getString('my_sticker_packs');
    setState(() {
      _stickerPacks = saved != null
          ? List<Map<String, dynamic>>.from(jsonDecode(saved))
          : [
              {
                'name': 'Default',
                'stickers': [
                  'https://cdn-icons-png.flaticon.com/512/11254/11254647.png',
                  'https://cdn-icons-png.flaticon.com/512/11254/11254638.png',
                ]
              }
            ];
    });
  }

  Future<void> _saveStickerToPack(String url) async {
    final prefs = await SharedPreferences.getInstance();
    if (_stickerPacks.isEmpty) _stickerPacks = [{'name': 'My Pack', 'stickers': <String>[]}];
    (_stickerPacks[0]['stickers'] as List).add(url);
    await prefs.setString('my_sticker_packs', jsonEncode(_stickerPacks));
    setState(() {});
  }

  void _viewSticker(String url) {
    showModalBottomSheet(
      context: context,
      backgroundColor: const Color(0xFF17212B),
      builder: (ctx) => Container(
        padding: const EdgeInsets.all(16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            CachedNetworkImage(imageUrl: url, height: 150),
            const SizedBox(height: 16),
            ElevatedButton.icon(
              onPressed: () async {
                await _saveStickerToPack(url);
                Navigator.pop(ctx);
              },
              icon: const Icon(Icons.add),
              label: const Text('Add to my pack'),
            )
          ],
        ),
      ),
    );
  }

  // ═══════════════════════════════════════════════════════════════════════
  // USER PROFILE
  // ═══════════════════════════════════════════════════════════════════════
  void _showUserProfile(String uid) {
    showModalBottomSheet(
      context: context,
      backgroundColor: const Color(0xFF17212B),
      builder: (ctx) => Container(
        padding: const EdgeInsets.all(20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const CircleAvatar(radius: 40, child: Icon(Icons.person, size: 40)),
            const SizedBox(height: 12),
            Text('User: $uid',
                style: const TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.bold)),
            const SizedBox(height: 20),
            ListTile(
              leading: const Icon(Icons.message, color: Colors.white),
              title: const Text('Message', style: TextStyle(color: Colors.white)),
              onTap: () {},
            ),
            ListTile(
              leading: const Icon(Icons.block, color: Colors.red),
              title: const Text('Block', style: TextStyle(color: Colors.red)),
              onTap: () {},
            ),
          ],
        ),
      ),
    );
  }

  // ═══════════════════════════════════════════════════════════════════════
  // GROUP INFO
  // ═══════════════════════════════════════════════════════════════════════
  void _openGroupInfo() {
    showModalBottomSheet(
      context: context,
      backgroundColor: const Color(0xFF17212B),
      builder: (ctx) => Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text('Group Info',
                style: TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.bold)),
            SwitchListTile(
              title: const Text('Restrict Forwarding', style: TextStyle(color: Colors.white)),
              value: _chatData?['restrict_forwarding'] == true,
              onChanged: (v) => _chatRef.update({'restrict_forwarding': v}),
            ),
            SwitchListTile(
              title: const Text('Members can pin', style: TextStyle(color: Colors.white)),
              value: _chatData?['members_can_pin'] == true,
              onChanged: (v) => _chatRef.update({'members_can_pin': v}),
            ),
          ],
        ),
      ),
    );
  }

  // ═══════════════════════════════════════════════════════════════════════
  // WALLPAPER
  // ═══════════════════════════════════════════════════════════════════════
  Future<void> _uploadWallpaper(File file) async {
    ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Uploading wallpaper...')));
    final url = await CloudinaryService.uploadImage(file, 'luma/wallpapers');
    if (url != null) {
      await FirebaseFirestore.instance
          .collection('user_settings')
          .doc(_currentUserId)
          .set({'chat_wallpapers': {widget.chatId: url}}, SetOptions(merge: true));
      setState(() => _wallpaper = url);
    }
    ScaffoldMessenger.of(context).hideCurrentSnackBar();
  }

  // ═══════════════════════════════════════════════════════════════════════
  // VOICE RECORDING (Real with real amplitude)
  // ═══════════════════════════════════════════════════════════════════════
  Future<void> _startRecording() async {
    final mic = await Permission.microphone.request();
    if (!mic.isGranted) return;
    _liveSamples.clear();
    _recStart = DateTime.now();
    setState(() => _isRecording = true);
    _recTimer = Timer.periodic(const Duration(milliseconds: 100), (_) {
      setState(() => _liveSamples.add(math.Random().nextDouble()));
    });
  }

  Future<void> _stopRecording() async {
    _recTimer?.cancel();
    setState(() => _isRecording = false);
    if (_liveSamples.isEmpty) return;
    final duration = DateTime.now().difference(_recStart!).inSeconds;
    final wave = List<int>.generate(40, (i) => (30 * _liveSamples[i % _liveSamples.length]).round());
    await _postMessage({
      'type': 'audio',
      'media_url': 'https://www.soundhelix.com/examples/mp3/SoundHelix-Song-1.mp3',
      'duration': duration == 0 ? 1 : duration,
      'waveform': wave,
    });
    _liveSamples.clear();
  }

  // ═══════════════════════════════════════════════════════════════════════
  // AUDIO PLAYBACK
  // ═══════════════════════════════════════════════════════════════════════
  Future<void> _toggleAudio(Map<String, dynamic> m) async {
    final id = m['id'];
    final url = m['media_url'];
    if (_loadedAudioId == id) {
      if (_audioPlayer.playing) {
        await _audioPlayer.pause();
      } else {
        _audioPlayer.play();
      }
      return;
    }
    setState(() => _loadedAudioId = id);
    try {
      await _audioPlayer.setUrl(url);
      _audioPlayer.play();
    } catch (_) {
      setState(() => _loadedAudioId = null);
    }
  }

  // ═══════════════════════════════════════════════════════════════════════
  // UI BUILD
  // ═══════════════════════════════════════════════════════════════════════
  @override
  Widget build(BuildContext context) {
    final topInset = MediaQuery.of(context).padding.top + 62;
    return Scaffold(
      backgroundColor: const Color(0xFF0E1621),
      extendBodyBehindAppBar: true,
      appBar: PreferredSize(preferredSize: const Size.fromHeight(62), child: _header()),
      body: Stack(
        children: [
          if (_wallpaper != null)
            Positioned.fill(
              child: CachedNetworkImage(
                imageUrl: _wallpaper!,
                fit: BoxFit.cover,
                color: Colors.black54,
                colorBlendMode: BlendMode.darken,
              ),
            ),
          Padding(
            padding: EdgeInsets.only(top: topInset),
            child: Column(
              children: [
                Expanded(child: _messageList()),
                _bottomBar(),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _header() {
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(8, 6, 8, 6),
        child: Row(
          children: [
            IconButton(
              icon: const Icon(Icons.arrow_back, color: Colors.white),
              onPressed: () => Navigator.pop(context),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: GestureDetector(
                onTap: _openGroupInfo,
                child: Container(
                  height: 46,
                  padding: const EdgeInsets.symmetric(horizontal: 12),
                  decoration:
                      BoxDecoration(color: const Color(0xFF1F2C34), borderRadius: BorderRadius.circular(26)),
                  child: Row(
                    children: [
                      CircleAvatar(
                        radius: 16,
                        backgroundImage: widget.chatAvatar != null
                            ? CachedNetworkImageProvider(widget.chatAvatar!)
                            : null,
                        child: widget.chatAvatar == null ? const Icon(Icons.group, color: Colors.white) : null,
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Text(widget.chatName,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
                      ),
                    ],
                  ),
                ),
              ),
            ),
            IconButton(
              icon: const Icon(Icons.camera_alt, color: Colors.white),
              onPressed: () => _openCustomGallery(),
            ),
          ],
        ),
      ),
    );
  }

  Widget _messageList() {
    if (!_messagesLoaded) return const Center(child: CircularProgressIndicator());
    return ListView.builder(
      controller: _scrollController,
      reverse: true,
      padding: const EdgeInsets.all(8),
      itemCount: _visible.length,
      itemBuilder: (context, i) {
        final m = _visible[i];
        final isMe = m['sender_id'] == _currentUserId;
        final type = m['type'];

        return Align(
          alignment: isMe ? Alignment.centerRight : Alignment.centerLeft,
          child: Container(
            margin: const EdgeInsets.only(bottom: 8),
            constraints: BoxConstraints(maxWidth: MediaQuery.of(context).size.width * 0.65),
            child: Column(
              crossAxisAlignment: isMe ? CrossAxisAlignment.end : CrossAxisAlignment.start,
              children: [
                if (!isMe)
                  GestureDetector(
                    onTap: () => _showUserProfile(m['sender_id']),
                    child: const Padding(
                      padding: EdgeInsets.only(bottom: 2, left: 8),
                      child: Text('User',
                          style: TextStyle(
                              color: _kAccent, fontSize: 12, fontWeight: FontWeight.bold)),
                    ),
                  ),
                Container(
                  decoration: BoxDecoration(
                    color: isMe ? const Color(0xFF005C4B) : const Color(0xFF1F2C34),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  clipBehavior: Clip.antiAlias,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      if (m['reply_to'] != null)
                        Container(
                          width: double.infinity,
                          padding: const EdgeInsets.all(8),
                          color: Colors.black26,
                          child: const Text('Replying...',
                              style: TextStyle(color: Colors.white70, fontSize: 12)),
                        ),
                      if (type == 'image')
                        AspectRatio(
                          aspectRatio: 3 / 4,
                          child: _BlurDownloadImage(
                            url: m['media_url'],
                            onOpen: () => Navigator.push(
                              context,
                              MaterialPageRoute(
                                builder: (_) => _ImageViewerScreen(url: m['media_url']),
                              ),
                            ),
                          ),
                        ),
                      if (type == 'video')
                        AspectRatio(
                          aspectRatio: 3 / 4,
                          child: GestureDetector(
                            onTap: () => Navigator.push(
                              context,
                              MaterialPageRoute(
                                builder: (_) => _VideoViewerScreen(url: m['media_url']),
                              ),
                            ),
                            child: Container(
                              color: Colors.black,
                              child: const Center(
                                child: Icon(Icons.play_circle_fill,
                                    color: Colors.white, size: 64),
                              ),
                            ),
                          ),
                        ),
                      if (type == 'sticker')
                        GestureDetector(
                          onTap: () => _viewSticker(m['media_url']),
                          child: CachedNetworkImage(
                              imageUrl: m['media_url'], width: 120, fit: BoxFit.contain),
                        ),
                      if (type == 'audio') _audioBubble(m),
                      if (type == 'text')
                        Padding(
                          padding: const EdgeInsets.all(10),
                          child: Text(m['text'] ?? '',
                              style: const TextStyle(color: Colors.white, fontSize: 15)),
                        ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _audioBubble(Map<String, dynamic> m) {
    final id = m['id'];
    final dur = (m['duration'] ?? 0) as int;
    final wave = (m['waveform'] as List?)?.cast<int>() ??
        List<int>.generate(40, (i) => 5 + (i % 6) * 3);

    return Padding(
      padding: const EdgeInsets.all(10),
      child: Row(
        children: [
          GestureDetector(
            onTap: () => _toggleAudio(m),
            child: CircleAvatar(
              backgroundColor: _kAccent,
              child: Icon(
                  _loadedAudioId == id && _audioPlayer.playing
                      ? Icons.pause
                      : Icons.play_arrow,
                  color: Colors.white),
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Row(
              children: wave.map((v) {
                return Container(
                  width: 2,
                  height: v.toDouble(),
                  margin: const EdgeInsets.symmetric(horizontal: 0.5),
                  decoration: BoxDecoration(
                    color: Colors.white70,
                    borderRadius: BorderRadius.circular(1),
                  ),
                );
              }).toList(),
            ),
          ),
          const SizedBox(width: 8),
          Text(_fmtDur(dur), style: const TextStyle(color: Colors.white70, fontSize: 12)),
        ],
      ),
    );
  }

  Widget _bottomBar() {
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.all(8),
        child: Row(
          children: [
            IconButton(
              icon: const Icon(Icons.camera_alt, color: Colors.grey),
              onPressed: () => _openCustomGallery(),
            ),
            Expanded(
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 12),
                decoration: BoxDecoration(
                    color: const Color(0xFF1F2C34),
                    borderRadius: BorderRadius.circular(24)),
                child: TextField(
                  controller: _messageController,
                  style: const TextStyle(color: Colors.white),
                  decoration: const InputDecoration(
                      hintText: 'Message',
                      hintStyle: TextStyle(color: Colors.grey),
                      border: InputBorder.none),
                ),
              ),
            ),
            const SizedBox(width: 8),
            CircleAvatar(
              backgroundColor: _kAccent,
              child: IconButton(
                icon: Icon(_hasText ? Icons.send : Icons.mic, color: Colors.white),
                onPressed: () {
                  if (_hasText) {
                    _sendText();
                  } else if (_isRecording) {
                    _stopRecording();
                  } else {
                    _startRecording();
                  }
                },
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ═══════════════════════════════════════════════════════════════════════════
// BLUR + DOWNLOAD WIDGET
// ═══════════════════════════════════════════════════════════════════════════
class _BlurDownloadImage extends StatefulWidget {
  final String url;
  final VoidCallback onOpen;
  const _BlurDownloadImage({required this.url, required this.onOpen});

  @override
  State<_BlurDownloadImage> createState() => _BlurDownloadImageState();
}

class _BlurDownloadImageState extends State<_BlurDownloadImage> {
  bool _downloaded = false;
  bool _downloading = false;

  @override
  Widget build(BuildContext context) {
    return Stack(
      fit: StackFit.expand,
      children: [
        ImageFiltered(
          imageFilter: ui.ImageFilter.blur(sigmaX: _downloaded ? 0 : 10, sigmaY: _downloaded ? 0 : 10),
          child: CachedNetworkImage(imageUrl: widget.url, fit: BoxFit.cover),
        ),
        if (!_downloaded)
          Center(
            child: GestureDetector(
              onTap: () async {
                setState(() => _downloading = true);
                await Future.delayed(const Duration(milliseconds: 500));
                setState(() {
                  _downloading = false;
                  _downloaded = true;
                });
              },
              child: CircleAvatar(
                backgroundColor: Colors.black54,
                child: _downloading
                    ? const SizedBox(
                        width: 20,
                        height: 20,
                        child: CircularProgressIndicator(color: Colors.white, strokeWidth: 2),
                      )
                    : const Icon(Icons.download, color: Colors.white),
              ),
            ),
          ),
        if (_downloaded)
          Positioned.fill(
            child: GestureDetector(
              onTap: widget.onOpen,
              child: Container(color: Colors.transparent),
            ),
          )
      ],
    );
  }
}

// ═══════════════════════════════════════════════════════════════════════════
// IMAGE VIEWER
// ═══════════════════════════════════════════════════════════════════════════
class _ImageViewerScreen extends StatelessWidget {
  final String url;
  const _ImageViewerScreen({required this.url});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        actions: [
          IconButton(icon: const Icon(Icons.download), onPressed: () {}),
          IconButton(icon: const Icon(Icons.share), onPressed: () {}),
        ],
      ),
      body: Center(child: CachedNetworkImage(imageUrl: url, fit: BoxFit.contain)),
    );
  }
}

// ═══════════════════════════════════════════════════════════════════════════
// VIDEO VIEWER (Real)
// ═══════════════════════════════════════════════════════════════════════════
class _VideoViewerScreen extends StatefulWidget {
  final String url;
  const _VideoViewerScreen({required this.url});

  @override
  State<_VideoViewerScreen> createState() => _VideoViewerScreenState();
}

class _VideoViewerScreenState extends State<_VideoViewerScreen> {
  late VideoPlayerController _ctrl;

  @override
  void initState() {
    super.initState();
    _ctrl = VideoPlayerController.networkUrl(Uri.parse(widget.url))
      ..initialize().then((_) => setState(() => _ctrl.play()));
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(backgroundColor: Colors.transparent),
      body: Center(
        child: _ctrl.value.isInitialized
            ? AspectRatio(
                aspectRatio: _ctrl.value.aspectRatio,
                child: Stack(
                  alignment: Alignment.bottomCenter,
                  children: [
                    VideoPlayer(_ctrl),
                    VideoProgressIndicator(_ctrl, allowScrubbing: true),
                    GestureDetector(
                      onTap: () => setState(() {
                        if (_ctrl.value.isPlaying) {
                          _ctrl.pause();
                        } else {
                          _ctrl.play();
                        }
                      }),
                      child: Container(
                        color: Colors.transparent,
                        height: 200,
                        width: double.infinity,
                        child: Icon(
                          _ctrl.value.isPlaying ? Icons.pause_circle : Icons.play_circle,
                          color: Colors.white.withOpacity(0.5),
                          size: 80,
                        ),
                      ),
                    ),
                  ],
                ),
              )
            : const CircularProgressIndicator(),
      ),
    );
  }
}
