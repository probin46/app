import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data'; // ✅ FIXED: Added for Uint8List
import 'package:cached_network_image/cached_network_image.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:emoji_picker_flutter/emoji_picker_flutter.dart';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:intl/intl.dart';
import 'package:photo_manager/photo_manager.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';

import '../../providers/auth_provider.dart' show LumaAuthProvider;
import '../../services/cloudinary_service.dart';

const String _kGiphyApiKey = '7tXB3cisPGymcszQX85JFOY6kp3Gz47T';

class ChannelScreen extends StatefulWidget {
  final String channelId;
  final String channelName;
  final String? channelAvatar;

  const ChannelScreen({
    super.key,
    required this.channelId,
    required this.channelName,
    this.channelAvatar,
  });

  @override
  State<ChannelScreen> createState() => _ChannelScreenState();
}

class _ChannelScreenState extends State<ChannelScreen> {
  final _messageController = TextEditingController();
  final _scrollController = ScrollController();
  final _gifSearchController = TextEditingController();
  
  bool _hasText = false;
  int _activePanel = 0; 
  
  String? _currentUserId;

  List<String> _gifResults = [];
  bool _isLoadingGifs = false;

  List<String> _customStickers = [];
  final List<String> _defaultStickers = [
    'https://cdn-icons-png.flaticon.com/512/11254/11254647.png',
    'https://cdn-icons-png.flaticon.com/512/11254/11254638.png',
    'https://cdn-icons-png.flaticon.com/512/11254/11254642.png',
    'https://cdn-icons-png.flaticon.com/512/11254/11254653.png',
    'https://cdn-icons-png.flaticon.com/512/11254/11254644.png',
    'https://cdn-icons-png.flaticon.com/512/11254/11254651.png',
  ];

  CollectionReference<Map<String, dynamic>> get _msgsRef => 
      FirebaseFirestore.instance.collection('chats').doc(widget.channelId).collection('messages');

  @override
  void initState() {
    super.initState();
    _messageController.addListener(() {
      final has = _messageController.text.trim().isNotEmpty;
      if (has != _hasText) setState(() => _hasText = has);
    });
    final auth = Provider.of<LumaAuthProvider>(context, listen: false);
    _currentUserId = auth.user?.uid ?? auth.mockUserId;
    _loadCustomStickers();
  }

  @override
  void dispose() {
    _messageController.dispose();
    _scrollController.dispose();
    _gifSearchController.dispose();
    super.dispose();
  }

  Future<List<AssetEntity>> _loadCustomGalleryAssets() async {
    final ps = await PhotoManager.requestPermissionExtend();
    if (!ps.hasAccess) throw Exception('Permission denied');
    final paths = await PhotoManager.getAssetPathList(type: RequestType.image, onlyAll: true);
    if (paths.isEmpty) return [];
    return paths.first.getAssetListPaged(page: 0, size: 100);
  }

  void _openCustomGallery({required bool isSticker}) {
    setState(() => _activePanel = 0); 
    
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (ctx) {
        final isDark = Theme.of(ctx).brightness == Brightness.dark;
        return Container(
          height: MediaQuery.of(ctx).size.height * 0.75,
          decoration: BoxDecoration(
            color: isDark ? const Color(0xFF17212B) : Colors.white,
            borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
          ),
          child: Column(
            children: [
              Padding(
                padding: const EdgeInsets.all(16),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Text(
                      isSticker ? 'Choose Sticker Photo' : 'Recent Media', 
                      style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold)
                    ),
                    IconButton(icon: const Icon(Icons.close), onPressed: () => Navigator.pop(ctx)),
                  ],
                ),
              ),
              const Divider(height: 1),
              Expanded(
                child: FutureBuilder<List<AssetEntity>>(
                  future: _loadCustomGalleryAssets(),
                  builder: (context, snapshot) {
                    if (snapshot.connectionState == ConnectionState.waiting) {
                      return const Center(child: CircularProgressIndicator());
                    }
                    if (snapshot.hasError) {
                      return Center(child: Text('Error: ${snapshot.error}'));
                    }
                    final assets = snapshot.data ?? [];
                    if (assets.isEmpty) return const Center(child: Text('No media found'));
                    
                    return GridView.builder(
                      padding: const EdgeInsets.all(4),
                      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                        crossAxisCount: 3, crossAxisSpacing: 4, mainAxisSpacing: 4,
                      ),
                      itemCount: assets.length,
                      itemBuilder: (context, index) {
                        final asset = assets[index];
                        return GestureDetector(
                          onTap: () async {
                            Navigator.pop(ctx); 
                            final file = await asset.file;
                            if (file != null) {
                              if (isSticker) {
                                _uploadAndSendCustomSticker(file);
                              } else {
                                _sendStandardImage(file);
                              }
                            }
                          },
                          child: FutureBuilder<Uint8List?>(
                            future: asset.thumbnailDataWithSize(const ThumbnailSize(200, 200)),
                            builder: (context, thumbSnap) {
                              if (thumbSnap.hasData) return Image.memory(thumbSnap.data!, fit: BoxFit.cover);
                              return Container(color: Colors.grey[300]);
                            },
                          ),
                        );
                      },
                    );
                  },
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  Future<void> _uploadAndSendCustomSticker(File image) async {
    try {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Creating sticker...')));
      final url = await CloudinaryService.uploadImage(image, 'luma/stickers');
      if (url != null) {
        await _saveCustomSticker(url);
        await _sendMessage(type: 'sticker', mediaUrl: url);
      }
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Error: $e')));
    }
  }

  Future<void> _sendStandardImage(File image) async {
    try {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Uploading image...')));
      final url = await CloudinaryService.uploadImage(image, 'luma/chats');
      if (url != null) {
        await _sendMessage(type: 'image', mediaUrl: url);
      }
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Error: $e')));
    }
  }

  Future<void> _loadCustomStickers() async {
    final prefs = await SharedPreferences.getInstance();
    final saved = prefs.getStringList('my_custom_stickers') ?? [];
    if (mounted) setState(() => _customStickers = saved);
  }

  Future<void> _saveCustomSticker(String url) async {
    final prefs = await SharedPreferences.getInstance();
    final saved = prefs.getStringList('my_custom_stickers') ?? [];
    saved.add(url);
    await prefs.setStringList('my_custom_stickers', saved);
    _loadCustomStickers(); 
  }

  Future<void> _searchGifs(String query) async {
    if (query.trim().isEmpty) return;
    setState(() => _isLoadingGifs = true);
    try {
      final url = Uri.parse('https://api.giphy.com/v1/gifs/search?api_key=$_kGiphyApiKey&q=${Uri.encodeComponent(query)}&limit=20&rating=g');
      final res = await http.get(url);
      if (res.statusCode == 200) {
        final data = jsonDecode(res.body);
        final List gifs = data['data'];
        setState(() {
          _gifResults = gifs.map((g) => g['images']['fixed_height']['url'].toString()).toList();
        });
      }
    } catch (e) {
      debugPrint('Giphy error: $e');
    } finally {
      if (mounted) setState(() => _isLoadingGifs = false);
    }
  }

  Future<void> _sendMessage({String type = 'text', String? mediaUrl, String? text}) async {
    if (_currentUserId == null) return;
    
    final msgId = const Uuid().v4();
    final content = text ?? _messageController.text.trim();
    if (type == 'text' && content.isEmpty) return;

    _messageController.clear();
    setState(() => _activePanel = 0);

    final payload = {
      'id': msgId,
      'sender_id': _currentUserId,
      'type': type,
      'media_type': type,
      'text': type == 'text' ? content : null,
      'media_url': mediaUrl,
      'created_at': FieldValue.serverTimestamp(),
      'read_by': [_currentUserId],
    };

    await _msgsRef.doc(msgId).set(payload);
    
    await FirebaseFirestore.instance.collection('chats').doc(widget.channelId).update({
      'last_message': type == 'text' ? content : '📎 $type',
      'last_message_at': FieldValue.serverTimestamp(),
    });
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;

    return Scaffold(
      extendBodyBehindAppBar: true,
      backgroundColor: isDark ? const Color(0xFF0E1621) : const Color(0xFFF0F2F5),
      appBar: PreferredSize(
        preferredSize: const Size.fromHeight(62),
        child: _buildHeader(isDark),
      ),
      body: Column(
        children: [
          SizedBox(height: MediaQuery.of(context).padding.top + 62),
          Expanded(child: _buildMessageList(isDark)),
          if (_activePanel != 0) _buildPanel(isDark),
          _buildBottomComposer(isDark),
        ],
      ),
    );
  }

  Widget _buildHeader(bool isDark) {
    return SafeArea(
      bottom: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(8, 6, 8, 6),
        child: Row(
          children: [
            _circleButton(icon: Icons.arrow_back, onTap: () => Navigator.pop(context), isDark: isDark),
            const SizedBox(width: 8),
            Expanded(
              child: Container(
                height: 46,
                padding: const EdgeInsets.symmetric(horizontal: 8),
                decoration: BoxDecoration(
                  color: isDark ? const Color(0xFF1F2C34) : Colors.white,
                  borderRadius: BorderRadius.circular(26),
                  boxShadow: [BoxShadow(color: Colors.black.withOpacity(0.08), blurRadius: 6, offset: const Offset(0, 2))],
                ),
                child: Row(
                  children: [
                    CircleAvatar(
                      radius: 18,
                      backgroundColor: Colors.blue.withOpacity(0.15),
                      backgroundImage: widget.channelAvatar != null ? CachedNetworkImageProvider(widget.channelAvatar!) : null,
                      child: widget.channelAvatar == null 
                          ? const Icon(Icons.campaign, color: Colors.blue) 
                          : null,
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Row(
                            children: [
                              Flexible(
                                child: Text(
                                  widget.channelName,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(fontSize: 15, fontWeight: FontWeight.w700, color: isDark ? Colors.white : Colors.black),
                                ),
                              ),
                              const SizedBox(width: 4),
                              const Icon(Icons.verified, color: Colors.blue, size: 16),
                            ],
                          ),
                          Text(
                            '2 subscribers',
                            style: TextStyle(fontSize: 12, color: (isDark ? Colors.white : Colors.black).withOpacity(0.55)),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(width: 8),
            _circleButton(icon: Icons.search, onTap: () {}, isDark: isDark),
            const SizedBox(width: 8),
            _circleButton(icon: Icons.more_vert, onTap: () {}, isDark: isDark),
          ],
        ),
      ),
    );
  }

  Widget _circleButton({required IconData icon, required VoidCallback onTap, required bool isDark}) {
    return Container(
      width: 46,
      height: 46,
      decoration: BoxDecoration(
        color: isDark ? const Color(0xFF1F2C34) : Colors.white,
        shape: BoxShape.circle,
        boxShadow: [BoxShadow(color: Colors.black.withOpacity(0.08), blurRadius: 6, offset: const Offset(0, 2))],
      ),
      child: Material(
        color: Colors.transparent,
        shape: const CircleBorder(),
        child: InkWell(
          customBorder: const CircleBorder(),
          onTap: onTap,
          child: Icon(icon, size: 22, color: isDark ? Colors.white : Colors.black),
        ),
      ),
    );
  }

  Widget _buildMessageList(bool isDark) {
    return StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
      stream: _msgsRef.orderBy('created_at', descending: true).limit(100).snapshots(),
      builder: (context, snapshot) {
        if (!snapshot.hasData) return const Center(child: CircularProgressIndicator());
        
        final docs = snapshot.data!.docs;
        if (docs.isEmpty) return const Center(child: Text('No messages yet'));

        return ListView.builder(
          controller: _scrollController,
          reverse: true,
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 16),
          itemCount: docs.length,
          itemBuilder: (context, i) {
            final data = docs[i].data();
            final isMe = data['sender_id'] == _currentUserId;
            final type = data['type'] ?? 'text';
            final text = data['text'] ?? '';
            final mediaUrl = data['media_url'];
            final time = data['created_at'] is Timestamp 
                ? DateFormat('HH:mm').format((data['created_at'] as Timestamp).toDate()) 
                : '';

            return Align(
              alignment: isMe ? Alignment.centerRight : Alignment.centerLeft,
              child: Container(
                margin: const EdgeInsets.only(bottom: 8),
                padding: type == 'sticker' || type == 'gif' || type == 'image'
                    ? EdgeInsets.zero 
                    : const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                decoration: type == 'sticker' || type == 'gif' 
                    ? null 
                    : BoxDecoration(
                        color: isMe 
                            ? const Color(0xFFFFF9E6)
                            : (isDark ? const Color(0xFF1F2C34) : Colors.white),
                        borderRadius: BorderRadius.only(
                          topLeft: const Radius.circular(16),
                          topRight: const Radius.circular(16),
                          bottomLeft: Radius.circular(isMe ? 16 : 4),
                          bottomRight: Radius.circular(isMe ? 4 : 16),
                        ),
                        boxShadow: [BoxShadow(color: Colors.black.withOpacity(0.05), blurRadius: 2, offset: const Offset(0, 1))],
                      ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    if (type == 'text')
                      Text(text, style: const TextStyle(color: Colors.black87, fontSize: 15)),
                    if (type == 'sticker' && mediaUrl != null)
                      CachedNetworkImage(imageUrl: mediaUrl, width: 140, fit: BoxFit.contain),
                    if (type == 'gif' && mediaUrl != null)
                      ClipRRect(
                        borderRadius: BorderRadius.circular(12),
                        child: CachedNetworkImage(imageUrl: mediaUrl, width: 220, fit: BoxFit.cover),
                      ),
                    if (type == 'image' && mediaUrl != null)
                      ClipRRect(
                        borderRadius: BorderRadius.circular(12),
                        child: CachedNetworkImage(imageUrl: mediaUrl, width: 220, fit: BoxFit.cover),
                      ),
                    const SizedBox(height: 4),
                    Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(time, style: TextStyle(fontSize: 10, color: isDark ? Colors.white54 : Colors.grey)),
                        if (isMe) ...[
                          const SizedBox(width: 4),
                          const Icon(Icons.done_all, size: 14, color: Colors.blue),
                        ]
                      ],
                    ),
                  ],
                ),
              ),
            );
          },
        );
      },
    );
  }

  Widget _buildPanel(bool isDark) {
    if (_activePanel == 1) {
      return SizedBox(
        height: 300,
        child: EmojiPicker(
          onEmojiSelected: (category, emoji) {
            _messageController.text += emoji.emoji;
            _messageController.selection = TextSelection.fromPosition(TextPosition(offset: _messageController.text.length));
          },
          config: Config(
            height: 300,
            emojiViewConfig: EmojiViewConfig(backgroundColor: isDark ? const Color(0xFF17212B) : Colors.white),
            bottomActionBarConfig: BottomActionBarConfig(backgroundColor: isDark ? const Color(0xFF17212B) : Colors.white),
          ),
        ),
      );
    } 
    else if (_activePanel == 2) {
      return Container(
        height: 300,
        color: isDark ? const Color(0xFF17212B) : Colors.white,
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.all(8.0),
              child: TextField(
                controller: _gifSearchController,
                decoration: InputDecoration(
                  hintText: 'Search GIPHY...',
                  prefixIcon: const Icon(Icons.search),
                  filled: true,
                  fillColor: isDark ? const Color(0xFF1F2C34) : Colors.grey[200],
                  border: OutlineInputBorder(borderRadius: BorderRadius.circular(20), borderSide: BorderSide.none),
                  isDense: true,
                  contentPadding: const EdgeInsets.symmetric(vertical: 10),
                ),
                onSubmitted: _searchGifs,
              ),
            ),
            Expanded(
              child: _isLoadingGifs 
                  ? const Center(child: CircularProgressIndicator())
                  : _gifResults.isEmpty 
                      ? const Center(child: Text('Search for a GIF'))
                      : GridView.builder(
                          padding: const EdgeInsets.symmetric(horizontal: 8),
                          gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(crossAxisCount: 2, crossAxisSpacing: 8, mainAxisSpacing: 8),
                          itemCount: _gifResults.length,
                          itemBuilder: (context, index) {
                            return GestureDetector(
                              onTap: () => _sendMessage(type: 'gif', mediaUrl: _gifResults[index]),
                              child: ClipRRect(
                                borderRadius: BorderRadius.circular(8),
                                child: CachedNetworkImage(imageUrl: _gifResults[index], fit: BoxFit.cover),
                              ),
                            );
                          },
                        ),
            ),
          ],
        ),
      );
    } 
    else if (_activePanel == 3) {
      return Container(
        height: 300,
        color: isDark ? const Color(0xFF17212B) : Colors.white,
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              child: Row(
                children: [
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed: () => _openCustomGallery(isSticker: true),
                      icon: const Icon(Icons.photo_library, size: 18),
                      label: const Text('Gallery Sticker'),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed: () => _openCustomGallery(isSticker: true),
                      icon: const Icon(Icons.camera_alt, size: 18),
                      label: const Text('Camera Sticker'),
                    ),
                  ),
                ],
              ),
            ),
            const Divider(height: 1),
            Expanded(
              child: GridView.builder(
                padding: const EdgeInsets.all(8),
                gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(crossAxisCount: 4, crossAxisSpacing: 8, mainAxisSpacing: 8),
                itemCount: _customStickers.length + _defaultStickers.length,
                itemBuilder: (context, index) {
                  if (index < _customStickers.length) {
                    return GestureDetector(
                      onTap: () => _sendMessage(type: 'sticker', mediaUrl: _customStickers[index]),
                      child: Stack(
                        children: [
                          Positioned.fill(
                            child: CachedNetworkImage(imageUrl: _customStickers[index], fit: BoxFit.contain),
                          ),
                          Positioned(
                            right: 0,
                            top: 0,
                            child: GestureDetector(
                              onTap: () async {
                                final prefs = await SharedPreferences.getInstance();
                                final saved = prefs.getStringList('my_custom_stickers') ?? [];
                                saved.removeAt(index);
                                await prefs.setStringList('my_custom_stickers', saved);
                                _loadCustomStickers();
                              },
                              child: Container(
                                padding: const EdgeInsets.all(2),
                                decoration: const BoxDecoration(color: Colors.black54, shape: BoxShape.circle),
                                child: const Icon(Icons.close, size: 12, color: Colors.white),
                              ),
                            ),
                          )
                        ],
                      ),
                    );
                  }
                  final defaultIndex = index - _customStickers.length;
                  return GestureDetector(
                    onTap: () => _sendMessage(type: 'sticker', mediaUrl: _defaultStickers[defaultIndex]),
                    child: CachedNetworkImage(imageUrl: _defaultStickers[defaultIndex], fit: BoxFit.contain),
                  );
                },
              ),
            ),
          ],
        ),
      );
    }
    return const SizedBox.shrink();
  }

  Widget _buildBottomComposer(bool isDark) {
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(8, 4, 8, 8),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            Expanded(
              child: Container(
                decoration: BoxDecoration(
                  color: isDark ? const Color(0xFF1F2C34) : Colors.white,
                  borderRadius: BorderRadius.circular(26),
                  boxShadow: [BoxShadow(color: Colors.black.withOpacity(0.06), blurRadius: 6, offset: const Offset(0, 2))],
                ),
                child: Row(
                  children: [
                    IconButton(
                      icon: Icon(
                        _activePanel == 1 ? Icons.keyboard : Icons.emoji_emotions_outlined, 
                        color: Colors.grey
                      ),
                      onPressed: () {
                        FocusScope.of(context).unfocus();
                        setState(() => _activePanel = _activePanel == 1 ? 0 : 1);
                      },
                    ),
                    Expanded(
                      child: TextField(
                        controller: _messageController,
                        focusNode: FocusNode()..addListener(() {
                          if (_activePanel != 0) setState(() => _activePanel = 0);
                        }),
                        decoration: const InputDecoration(
                          hintText: 'Broadcast a mess...',
                          hintStyle: TextStyle(color: Colors.grey),
                          border: InputBorder.none,
                          isDense: true,
                        ),
                        maxLines: null,
                      ),
                    ),
                    IconButton(
                      icon: const Icon(Icons.emoji_emotions, color: Colors.grey),
                      onPressed: () {
                        FocusScope.of(context).unfocus();
                        setState(() => _activePanel = _activePanel == 3 ? 0 : 3);
                      },
                    ),
                    IconButton(
                      icon: const Icon(Icons.gif_box_outlined, color: Colors.grey),
                      onPressed: () {
                        FocusScope.of(context).unfocus();
                        setState(() => _activePanel = _activePanel == 2 ? 0 : 2);
                      },
                    ),
                    IconButton(
                      icon: const Icon(Icons.attach_file, color: Colors.grey),
                      onPressed: () {
                        _openCustomGallery(isSticker: false);
                      },
                    ),
                    IconButton(
                      icon: const Icon(Icons.camera_alt_outlined, color: Colors.grey),
                      onPressed: () {
                        _openCustomGallery(isSticker: false);
                      },
                    ),
                    const SizedBox(width: 4),
                  ],
                ),
              ),
            ),
            
            const SizedBox(width: 8),
            
            GestureDetector(
              onTap: () {
                if (_hasText) {
                  _sendMessage();
                }
              },
              child: Container(
                width: 48,
                height: 48,
                decoration: const BoxDecoration(
                  color: Color(0xFFC9A027),
                  shape: BoxShape.circle,
                ),
                child: const Icon(Icons.send, color: Colors.white, size: 24),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
