import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_slidable/flutter_slidable.dart';
import 'package:provider/provider.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:intl/intl.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'dart:convert';

import '../providers/auth_provider.dart' show LumaAuthProvider;
import '../providers/chat_provider.dart';
import 'chat/group_chat_screen.dart';
import 'chat/chat_screen.dart'; // ✅ ADDED: Import ChatScreen
import 'contacts/contacts_screen.dart';
import 'status/status_screen.dart';
import 'settings/settings_screen.dart';
import 'archive/archived_chats_screen.dart';

class MainAppScreen extends StatefulWidget {
  const MainAppScreen({super.key});

  @override
  State<MainAppScreen> createState() => _MainAppScreenState();
}

class _MainAppScreenState extends State<MainAppScreen> {
  int _bottomIndex = 0;
  int _folderIndex = 0;
  final Map<String, Map<String, dynamic>> _userCache = {};
  final Set<String> _inFlight = {};
  List<String> _myBlockedUsers = [];

  // Selection mode (long press on a chat)
  final Set<String> _selectedChats = {};
  bool get _selectionMode => _selectedChats.isNotEmpty;

  // Folder state
  List<Map<String, dynamic>> _folders = [];

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final auth = Provider.of<LumaAuthProvider>(context, listen: false);
      final chat = Provider.of<ChatProvider>(context, listen: false);

      _loadLocalChats(chat);

      if (auth.mockUserId != null) {
        chat.setMockUser(auth.mockUserId!);
      } else {
        chat.loadChats();
      }
      _listenToMyBlockedUsers();
      _loadFolders();
    });
  }

  // ═══════════════════════════════════════════════════════════════════════
  // OFFLINE MODE & LOCAL STORAGE
  // ═══════════════════════════════════════════════════════════════════════
  Future<void> _loadLocalChats(ChatProvider chat) async {
    final prefs = await SharedPreferences.getInstance();
    final cached = prefs.getString('cached_chats');
    if (cached != null) {
      // You can implement loading cached chats here if ChatProvider supports it
    }
  }

  Future<void> _saveChatsLocally(List<Map<String, dynamic>> chats) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('cached_chats', jsonEncode(chats));
  }

  // ═══════════════════════════════════════════════════════════════════════
  // CUSTOM FOLDERS LOGIC
  // ═══════════════════════════════════════════════════════════════════════
  Future<void> _loadFolders() async {
    final prefs = await SharedPreferences.getInstance();
    final saved = prefs.getString('custom_folders');
    if (saved != null) {
      setState(() {
        _folders = List<Map<String, dynamic>>.from(jsonDecode(saved));
      });
    }
  }

  Future<void> _saveFolders() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('custom_folders', jsonEncode(_folders));
  }

  void _showCreateFolderDialog() {
    final ctrl = TextEditingController();
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('New Folder'),
        content: TextField(
          controller: ctrl,
          decoration: const InputDecoration(hintText: 'Folder name...'),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
          TextButton(
            onPressed: () {
              final name = ctrl.text.trim();
              if (name.isEmpty) return;
              setState(() {
                _folders.add({
                  'id': DateTime.now().millisecondsSinceEpoch.toString(),
                  'name': name,
                  'chatIds': <String>[],
                });
              });
              _saveFolders();
              Navigator.pop(ctx);
            },
            child: const Text('Create'),
          ),
        ],
      ),
    );
  }

  /// Adds the given chats to a folder (or removes them if they are all already in it).
  void _addChatsToFolder(List<String> chatIds) {
    if (chatIds.isEmpty) return;
    if (_folders.isEmpty) {
      _showCreateFolderDialog();
      return;
    }

    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(chatIds.length == 1 ? 'Add to Folder' : 'Add ${chatIds.length} chats to Folder'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: _folders.map((f) {
            final list = f['chatIds'] as List;
            final allIn = chatIds.every((id) => list.contains(id));
            return ListTile(
              title: Text(f['name']),
              trailing: Icon(allIn ? Icons.check_circle : Icons.circle_outlined, color: allIn ? Colors.green : Colors.grey),
              onTap: () {
                setState(() {
                  if (allIn) {
                    list.removeWhere((id) => chatIds.contains(id));
                  } else {
                    for (final id in chatIds) {
                      if (!list.contains(id)) list.add(id);
                    }
                  }
                });
                _saveFolders();
                Navigator.pop(ctx);
                _clearSelection();
              },
            );
          }).toList(),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Done')),
        ],
      ),
    );
  }

  void _addChatToFolder(String chatId) => _addChatsToFolder([chatId]);

  void _editFolder(int index) {
    final ctrl = TextEditingController(text: _folders[index]['name']);
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Edit Folder'),
        content: TextField(controller: ctrl),
        actions: [
          TextButton(
            onPressed: () {
              setState(() {
                _folders.removeAt(index);
                if (_folderIndex > _folders.length) _folderIndex = 0;
              });
              _saveFolders();
              Navigator.pop(ctx);
            },
            child: const Text('Delete', style: TextStyle(color: Colors.red)),
          ),
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
          TextButton(
            onPressed: () {
              setState(() => _folders[index]['name'] = ctrl.text.trim());
              _saveFolders();
              Navigator.pop(ctx);
            },
            child: const Text('Save'),
          ),
        ],
      ),
    );
  }

  // ═══════════════════════════════════════════════════════════════════════
  // BLOCKED USERS & FETCHING
  // ═══════════════════════════════════════════════════════════════════════
  String get _myUid {
    final auth = Provider.of<LumaAuthProvider>(context, listen: false);
    final fromProvider = auth.currentUserId ?? auth.mockUserId;
    if (fromProvider != null && fromProvider.isNotEmpty) return fromProvider;
    return FirebaseAuth.instance.currentUser?.uid ?? '';
  }

  void _listenToMyBlockedUsers() {
    final uid = _myUid;
    if (uid.isEmpty) return;
    FirebaseFirestore.instance.collection('users').doc(uid).snapshots().listen((doc) {
      if (!mounted || !doc.exists) return;
      setState(() {
        _myBlockedUsers = List<String>.from(doc.data()?['blocked_users'] ?? []);
      });
    });
  }

  Future<void> _fetchOtherUser(String uid) async {
    if (uid.isEmpty || _userCache.containsKey(uid) || _inFlight.contains(uid)) return;
    _inFlight.add(uid);
    try {
      final doc = await FirebaseFirestore.instance.collection('users').doc(uid).get();
      if (doc.exists && doc.data() != null) {
        final d = doc.data()!;
        _userCache[uid] = {
          'uid': uid,
          'username': (d['username'] ?? '') as String,
          'display_name': (d['display_name'] ?? d['username'] ?? d['name'] ?? 'Unknown') as String,
          'avatar_url': d['avatar_url'],
          'email': d['email'],
          'is_bot': d['is_bot'] == true,
          'is_premium': d['is_premium'] == true,
        };
      }
    } finally {
      if (mounted) setState(() {});
      _inFlight.remove(uid);
    }
  }

  String _formatChatTime(dynamic lastMessageAt) {
    if (lastMessageAt == null) return '';
    DateTime dt = lastMessageAt is Timestamp ? lastMessageAt.toDate() : DateTime.now();
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final msgDay = DateTime(dt.year, dt.month, dt.day);
    final diffDays = today.difference(msgDay).inDays;
    if (diffDays == 0) return DateFormat('HH:mm').format(dt);
    if (diffDays == 1) return 'Yesterday';
    if (diffDays < 7) return DateFormat('EEE').format(dt);
    return DateFormat('MM/dd/yy').format(dt);
  }

  // ═══════════════════════════════════════════════════════════════════════
  // OPENING CHATS (groups now open GroupChatScreen)
  // ═══════════════════════════════════════════════════════════════════════
  void _openChat({
    required String chatId,
    required String name,
    required String? avatar,
    required bool isGroup,
    required bool isChannel,
    required String? otherUserId,
  }) {
    if (isChannel) {
      Navigator.pushNamed(context, '/channel', arguments: {'channelId': chatId, 'channelName': name});
    } else if (isGroup) {
      Navigator.push(
        context,
        MaterialPageRoute(
          builder: (_) => GroupChatScreen(chatId: chatId, chatName: name, chatAvatar: avatar),
        ),
      );
    } else {
      // ✅ Safety check: Make sure we actually have a user ID to open the DM
      if (otherUserId == null || otherUserId.isEmpty) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Could not determine the other user for this chat.')),
        );
        return;
      }

      // ✅ FIXED: Direct push to ChatScreen so the data is not lost
      Navigator.push(
        context,
        MaterialPageRoute(
          builder: (_) => ChatScreen(
            chatId: chatId,
            chatName: name,
            chatAvatar: avatar,
            otherUserId: otherUserId,
          ),
        ),
      );
    }
  }

  // ═══════════════════════════════════════════════════════════════════════
  // SELECTION MODE
  // ═══════════════════════════════════════════════════════════════════════
  void _toggleSelect(String chatId) {
    setState(() {
      if (!_selectedChats.remove(chatId)) _selectedChats.add(chatId);
    });
  }

  void _clearSelection() {
    if (_selectedChats.isEmpty || !mounted) return;
    setState(() => _selectedChats.clear());
  }

  Map<String, dynamic>? _chatById(String id) {
    for (final c in context.read<ChatProvider>().chats) {
      if (c['id'] == id) return c;
    }
    return null;
  }

  List<Map<String, dynamic>> _selectedChatMaps() =>
      _selectedChats.map(_chatById).whereType<Map<String, dynamic>>().toList();

  bool _isMutedFor(Map<String, dynamic> c) => List<String>.from(c['muted_for'] ?? []).contains(_myUid);

  Future<void> _bulkPin() async {
    final chats = _selectedChatMaps();
    if (chats.isEmpty) return;
    final provider = context.read<ChatProvider>();
    final allPinned = chats.every((c) => c['is_pinned'] == true);
    for (final c in chats) {
      final pinned = c['is_pinned'] == true;
      // togglePinChat flips the state, so only call it for chats that need to change
      if (allPinned ? pinned : !pinned) {
        await provider.togglePinChat(c['id'] as String);
      }
    }
    _clearSelection();
  }

  Future<void> _bulkMute() async {
    final chats = _selectedChatMaps();
    if (chats.isEmpty) return;
    final allMuted = chats.every(_isMutedFor);
    await _setMuted(chats.map((c) => c['id'] as String).toList(), !allMuted);
    _clearSelection();
  }

  Future<void> _setMuted(List<String> ids, bool mute) async {
    final myUid = _myUid;
    try {
      final batch = FirebaseFirestore.instance.batch();
      for (final id in ids) {
        batch.update(FirebaseFirestore.instance.collection('chats').doc(id), {
          'muted_for': mute ? FieldValue.arrayUnion([myUid]) : FieldValue.arrayRemove([myUid]),
        });
      }
      await batch.commit();
      if (mounted) context.read<ChatProvider>().loadChats();
    } catch (_) {}
  }

  Future<void> _bulkArchive() async {
    final ids = _selectedChats.toList();
    if (ids.isEmpty) return;
    final provider = context.read<ChatProvider>();
    for (final id in ids) {
      try {
        await provider.archiveChat(id);
      } catch (_) {}
    }
    _clearSelection();
  }

  Future<void> _bulkDelete() async {
    final ids = _selectedChats.toList();
    if (ids.isEmpty) return;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(ids.length == 1 ? 'Delete chat?' : 'Delete ${ids.length} chats?'),
        content: const Text('This cannot be undone.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          TextButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Delete', style: TextStyle(color: Colors.red))),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    final provider = context.read<ChatProvider>();
    for (final id in ids) {
      try {
        await provider.deleteChat(id);
      } catch (_) {}
    }
    _clearSelection();
  }

  Future<void> _blockSelected(String otherUserId, bool isBlocked) async {
    final provider = context.read<ChatProvider>();
    if (isBlocked) {
      await provider.unblockUser(otherUserId);
    } else {
      await provider.blockUser(otherUserId);
    }
    _clearSelection();
  }

  Future<void> _toggleArchive(String chatId, bool currentlyArchived) async {
    try {
      final provider = context.read<ChatProvider>();
      if (currentlyArchived) {
        await provider.unarchiveChat(chatId);
      } else {
        await provider.archiveChat(chatId);
      }
    } catch (_) {}
  }

  // ═══════════════════════════════════════════════════════════════════════
  // BUILD
  // ═══════════════════════════════════════════════════════════════════════
  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: false,
      onPopInvoked: (didPop) {
        if (didPop) return;
        if (_selectionMode) {
          _clearSelection();
        } else {
          SystemNavigator.pop();
        }
      },
      child: Scaffold(
        backgroundColor: Theme.of(context).scaffoldBackgroundColor,
        body: IndexedStack(
          index: _bottomIndex,
          children: [
            _buildChatsTab(),
            const StatusScreen(),
            const SettingsScreen(),
          ],
        ),
        floatingActionButton: _buildFAB(),
        bottomNavigationBar: _buildBottomNav(),
      ),
    );
  }

  // ═══════════════════════════════════════════════════════════════════════
  // BOTTOM NAV (4 equal tabs, profile avatar properly sized)
  // ═══════════════════════════════════════════════════════════════════════
  Widget _buildBottomNav() {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    final auth = context.watch<LumaAuthProvider>();
    final avatar = auth.userPhotoUrl;
    final hasAvatar = avatar != null && avatar.isNotEmpty;
    final inactive = theme.colorScheme.onSurface.withOpacity(0.5);

    return Container(
      decoration: BoxDecoration(
        color: isDark ? const Color(0xFF000000) : Colors.white,
        border: Border(top: BorderSide(color: isDark ? const Color(0xFF1A1A1A) : const Color(0xFFE4E4E5), width: 0.5)),
      ),
      child: SafeArea(
        top: false,
        child: SizedBox(
          height: 60,
          child: Row(
            children: [
              _bottomNavItem(icon: Icons.chat_bubble, label: 'Chats', index: 0),
              _bottomNavItem(icon: Icons.donut_large, label: 'Status', index: 1),
              _bottomNavItem(icon: Icons.settings, label: 'Settings', index: 2),
              Expanded(
                child: InkWell(
                  onTap: () => Navigator.pushNamed(context, '/profile'),
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Container(
                        padding: const EdgeInsets.all(1.5),
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          border: Border.all(color: theme.colorScheme.primary.withOpacity(0.55), width: 1.5),
                        ),
                        child: CircleAvatar(
                          radius: 10,
                          backgroundColor: theme.colorScheme.primary.withOpacity(0.15),
                          backgroundImage: hasAvatar ? NetworkImage(avatar) : null,
                          child: !hasAvatar ? Icon(Icons.person, size: 13, color: theme.colorScheme.primary) : null,
                        ),
                      ),
                      const SizedBox(height: 3),
                      Text('Profile', maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 11, fontWeight: FontWeight.w500, color: inactive)),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _bottomNavItem({required IconData icon, required String label, required int index}) {
    final theme = Theme.of(context);
    final selected = index == _bottomIndex;
    final color = selected ? theme.colorScheme.primary : theme.colorScheme.onSurface.withOpacity(0.5);

    return Expanded(
      child: InkWell(
        onTap: () => setState(() {
          _bottomIndex = index;
          _selectedChats.clear();
        }),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(icon, size: 24, color: color),
            const SizedBox(height: 3),
            Text(label, maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 11, fontWeight: FontWeight.w500, color: color)),
          ],
        ),
      ),
    );
  }

  // ═══════════════════════════════════════════════════════════════════════
  // FAB (opens contacts screen)
  // ═══════════════════════════════════════════════════════════════════════
  Widget? _buildFAB() {
    if (_bottomIndex != 0 || _selectionMode) return null;
    return Padding(
      padding: const EdgeInsets.only(bottom: 16.0, right: 8.0),
      child: FloatingActionButton(
        backgroundColor: const Color(0xFF3390EC),
        foregroundColor: Colors.white,
        elevation: 3,
        shape: const CircleBorder(),
        onPressed: () {
          Navigator.push(context, MaterialPageRoute(builder: (_) => const ContactsScreen()));
        },
        child: const Icon(Icons.add_comment, size: 26),
      ),
    );
  }

  // ═══════════════════════════════════════════════════════════════════════
  // CHATS TAB & FOLDERS
  // ═══════════════════════════════════════════════════════════════════════
  Widget _buildChatsTab() {
    return SafeArea(
      bottom: false,
      child: Column(
        children: [
          AnimatedSwitcher(
            duration: const Duration(milliseconds: 200),
            transitionBuilder: (child, anim) => FadeTransition(
              opacity: anim,
              child: SlideTransition(
                position: Tween<Offset>(begin: const Offset(0, -0.15), end: Offset.zero).animate(anim),
                child: child,
              ),
            ),
            child: _selectionMode ? _buildSelectionBar() : _buildChatsAppBar(),
          ),
          _buildFolderPills(),
          Expanded(child: _buildChatsList()),
        ],
      ),
    );
  }

  Widget _buildChatsAppBar() {
    final theme = Theme.of(context);
    final auth = context.watch<LumaAuthProvider>();
    final avatar = auth.userPhotoUrl;
    final isDark = theme.brightness == Brightness.dark;

    return Padding(
      key: const ValueKey('normal_bar'),
      padding: const EdgeInsets.fromLTRB(16, 8, 8, 4),
      child: Row(
        children: [
          GestureDetector(
            onTap: () => Navigator.pushNamed(context, '/profile'),
            child: CircleAvatar(
              radius: 18,
              backgroundColor: theme.colorScheme.primary.withOpacity(0.15),
              backgroundImage: (avatar != null && avatar.isNotEmpty) ? NetworkImage(avatar) : null,
              child: (avatar == null || avatar.isEmpty) ? Icon(Icons.person, size: 20, color: theme.colorScheme.primary) : null,
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Text('Luma Chat', style: theme.textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w600, color: theme.colorScheme.onSurface)),
          ),
          IconButton(
            icon: Icon(Icons.search, color: theme.colorScheme.onSurface),
            onPressed: () => Navigator.pushNamed(context, '/global_search'),
          ),
          PopupMenuButton<String>(
            color: isDark ? const Color(0xFF1F2C34) : Colors.white,
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
            icon: Icon(Icons.more_vert, color: theme.colorScheme.onSurface),
            onSelected: (value) {
              if (value == 'new_channel') {
                Navigator.pushNamed(context, '/create_channel');
              } else if (value == 'archive') {
                Navigator.push(context, MaterialPageRoute(builder: (_) => const ArchivedChatsScreen()));
              } else if (value == 'settings') {
                setState(() => _bottomIndex = 2);
              } else if (value == 'starred') {
                Navigator.pushNamed(context, '/saved_messages');
              }
            },
            itemBuilder: (context) => [
              const PopupMenuItem(value: 'new_channel', child: Text('New channel', style: TextStyle(fontSize: 15))),
              const PopupMenuItem(value: 'archive', child: Text('Archived chats', style: TextStyle(fontSize: 15))),
              const PopupMenuItem(value: 'starred', child: Text('Starred messages', style: TextStyle(fontSize: 15))),
              const PopupMenuItem(value: 'settings', child: Text('Settings', style: TextStyle(fontSize: 15))),
            ],
          ),
        ],
      ),
    );
  }

  /// Telegram-style selection bar shown after a long press.
  Widget _buildSelectionBar() {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    final primary = theme.colorScheme.primary;
    final chats = _selectedChatMaps();
    final count = _selectedChats.length;

    final allPinned = chats.isNotEmpty && chats.every((c) => c['is_pinned'] == true);
    final allMuted = chats.isNotEmpty && chats.every(_isMutedFor);

    // Block / unblock is only offered when exactly one direct chat is selected.
    String? blockTarget;
    var blockTargetBlocked = false;
    if (chats.length == 1 && (chats.first['type'] ?? 'direct') == 'direct') {
      final parts = List<String>.from(chats.first['participants'] ?? []);
      final other = parts.firstWhere((id) => id != _myUid, orElse: () => '');
      if (other.isNotEmpty) {
        blockTarget = other;
        blockTargetBlocked = _myBlockedUsers.contains(other);
      }
    }

    Widget action(IconData icon, String tip, VoidCallback onTap, {Color? color}) {
      return IconButton(
        tooltip: tip,
        visualDensity: VisualDensity.compact,
        icon: Icon(icon, color: color ?? theme.colorScheme.onSurface, size: 23),
        onPressed: onTap,
      );
    }

    return Container(
      key: const ValueKey('selection_bar'),
      margin: const EdgeInsets.fromLTRB(10, 8, 10, 4),
      height: 52,
      padding: const EdgeInsets.symmetric(horizontal: 4),
      decoration: BoxDecoration(
        color: isDark ? const Color(0xFF1F2C34) : Colors.white,
        borderRadius: BorderRadius.circular(26),
        border: Border.all(color: primary.withOpacity(0.35)),
        boxShadow: [BoxShadow(color: Colors.black.withOpacity(0.10), blurRadius: 8, offset: const Offset(0, 2))],
      ),
      child: Row(
        children: [
          IconButton(
            icon: Icon(Icons.close, color: theme.colorScheme.onSurface),
            onPressed: _clearSelection,
          ),
          AnimatedSwitcher(
            duration: const Duration(milliseconds: 150),
            transitionBuilder: (child, anim) => FadeTransition(
              opacity: anim,
              child: SlideTransition(
                position: Tween<Offset>(begin: const Offset(0, 0.4), end: Offset.zero).animate(anim),
                child: child,
              ),
            ),
            child: Text(
              '$count',
              key: ValueKey(count),
              style: TextStyle(fontSize: 20, fontWeight: FontWeight.w700, color: primary),
            ),
          ),
          const Spacer(),
          action(allPinned ? Icons.push_pin_outlined : Icons.push_pin, allPinned ? 'Unpin' : 'Pin', _bulkPin),
          action(allMuted ? Icons.notifications_active_outlined : Icons.notifications_off_outlined, allMuted ? 'Unmute' : 'Mute', _bulkMute),
          action(Icons.archive_outlined, 'Archive', _bulkArchive),
          action(Icons.delete_outline, 'Delete', _bulkDelete, color: Colors.red),
          PopupMenuButton<String>(
            color: isDark ? const Color(0xFF1F2C34) : Colors.white,
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
            icon: Icon(Icons.more_vert, color: theme.colorScheme.onSurface),
            onSelected: (v) {
              if (v == 'folder') _addChatsToFolder(_selectedChats.toList());
              if (v == 'block' && blockTarget != null) _blockSelected(blockTarget, blockTargetBlocked);
              if (v == 'all') {
                final visibleIds = _visibleChats().map((c) => c['id'] as String).toList();
                setState(() => _selectedChats.addAll(visibleIds));
              }
            },
            itemBuilder: (_) => [
              const PopupMenuItem(value: 'folder', child: Text('Add to folder')),
              if (blockTarget != null) PopupMenuItem(value: 'block', child: Text(blockTargetBlocked ? 'Unblock' : 'Block')),
              const PopupMenuItem(value: 'all', child: Text('Select all')),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildFolderPills() {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    final chats = context.watch<ChatProvider>().chats;

    return SizedBox(
      height: 44,
      child: ListView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
        children: [
          GestureDetector(
            onTap: () => setState(() => _folderIndex = 0),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 14),
              decoration: BoxDecoration(
                color: _folderIndex == 0 ? (isDark ? const Color(0xFF2A3A52) : const Color(0xFFE8EDF2)) : Colors.transparent,
                borderRadius: BorderRadius.circular(22),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text('All Chats', style: TextStyle(fontSize: 14, fontWeight: FontWeight.w500, color: theme.colorScheme.onSurface)),
                  const SizedBox(width: 8),
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                    decoration: BoxDecoration(color: _folderIndex == 0 ? theme.colorScheme.primary : Colors.grey, borderRadius: BorderRadius.circular(10)),
                    child: Text('${chats.length}', style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: Colors.white)),
                  ),
                ],
              ),
            ),
          ),
          ...List.generate(_folders.length, (i) {
            final folder = _folders[i];
            final selected = _folderIndex == i + 1;
            final count = (folder['chatIds'] as List).length;

            return GestureDetector(
              onTap: () => setState(() => _folderIndex = i + 1),
              onLongPress: () => _editFolder(i),
              child: Container(
                margin: const EdgeInsets.only(left: 8),
                padding: const EdgeInsets.symmetric(horizontal: 14),
                decoration: BoxDecoration(
                  color: selected ? (isDark ? const Color(0xFF2A3A52) : const Color(0xFFE8EDF2)) : Colors.transparent,
                  borderRadius: BorderRadius.circular(22),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(folder['name'], style: TextStyle(fontSize: 14, fontWeight: FontWeight.w500, color: theme.colorScheme.onSurface)),
                    const SizedBox(width: 8),
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                      decoration: BoxDecoration(color: selected ? theme.colorScheme.primary : Colors.grey, borderRadius: BorderRadius.circular(10)),
                      child: Text('$count', style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: Colors.white)),
                    ),
                  ],
                ),
              ),
            );
          }),
          GestureDetector(
            onTap: _showCreateFolderDialog,
            child: Container(
              margin: const EdgeInsets.only(left: 8),
              padding: const EdgeInsets.symmetric(horizontal: 12),
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: isDark ? const Color(0xFF1A1A1A) : const Color(0xFFF1F1F1),
                borderRadius: BorderRadius.circular(22),
              ),
              child: Icon(Icons.add, size: 20, color: theme.colorScheme.onSurface.withOpacity(0.6)),
            ),
          ),
        ],
      ),
    );
  }

  /// Chats shown in the current folder, excluding archived ones.
  List<Map<String, dynamic>> _visibleChats() {
    final all = context.read<ChatProvider>().chats;
    var visible = all;

    if (_folderIndex > 0 && _folderIndex - 1 < _folders.length) {
      final folder = _folders[_folderIndex - 1];
      final allowedIds = List<String>.from(folder['chatIds']);
      visible = visible.where((c) => allowedIds.contains(c['id'])).toList();
    }

    final myUid = _myUid;
    return visible.where((c) {
      final partsData = c['participants_data'] as Map<String, dynamic>? ?? {};
      final myData = partsData[myUid] as Map<String, dynamic>? ?? {};
      return myData['is_archived'] != true;
    }).toList();
  }

  Widget _buildChatsList() {
    final theme = Theme.of(context);
    return Consumer<ChatProvider>(
      builder: (context, chatProvider, _) {
        if (chatProvider.isLoading) return Center(child: CircularProgressIndicator(color: theme.colorScheme.primary));

        _saveChatsLocally(chatProvider.chats);

        final visible = _visibleChats();

        if (visible.isEmpty) return _buildEmptyState();
        return ListView.builder(
          padding: const EdgeInsets.only(top: 4, bottom: 96),
          itemCount: visible.length,
          itemBuilder: (context, i) => _buildChatTile(visible[i]),
        );
      },
    );
  }

  Widget _buildEmptyState() {
    final theme = Theme.of(context);
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.chat_bubble_outline, size: 72, color: theme.colorScheme.onSurface.withOpacity(0.15)),
            const SizedBox(height: 16),
            Text('No chats yet', style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w600)),
            const SizedBox(height: 6),
            Text('Start a conversation by tapping the chat button.', textAlign: TextAlign.center, style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurface.withOpacity(0.5))),
          ],
        ),
      ),
    );
  }

  Widget _buildChatTile(Map<String, dynamic> chat) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;

    final chatId = chat['id'] as String? ?? '';
    final chatType = chat['type'] as String? ?? 'direct';
    final isGroup = chatType == 'group';
    final isChannel = chatType == 'channel';
    final isBot = chatType == 'bot' || chat['is_bot'] == true;
    final isDirect = chatType == 'direct';
    final myUid = _myUid;

    String name;
    String? avatar;
    String? otherUserId;
    bool isPremium = false;

    if (isDirect) {
      final participants = List<String>.from(chat['participants'] ?? []);
      otherUserId = participants.firstWhere((id) => id != myUid, orElse: () => '');
      if (otherUserId.isNotEmpty && !_userCache.containsKey(otherUserId)) {
        WidgetsBinding.instance.addPostFrameCallback((_) => _fetchOtherUser(otherUserId!));
      }
      final cached = otherUserId.isNotEmpty ? _userCache[otherUserId] : null;
      name = cached?['display_name'] ?? 'Loading...';
      avatar = cached?['avatar_url'];
      isPremium = cached?['is_premium'] == true;
    } else {
      name = (chat['name'] ?? chat['title'] ?? 'Unknown') as String;
      avatar = chat['avatar_url'] as String?;
    }

    final lastMessage = chat['last_message'] ?? '';
    final unread = (chat['unread_count'] as num?)?.toInt() ?? 0;
    final isPinned = chat['is_pinned'] == true;
    final participantsData = chat['participants_data'] as Map<String, dynamic>? ?? {};
    final myData = participantsData[myUid] as Map<String, dynamic>? ?? {};
    final isArchived = myData['is_archived'] == true;
    final mutedFor = List<String>.from(chat['muted_for'] ?? []);
    final isMuted = mutedFor.contains(myUid);
    final isBlockedByMe = isDirect && otherUserId != null && otherUserId.isNotEmpty && _myBlockedUsers.contains(otherUserId);
    final isSelected = _selectedChats.contains(chatId);

    final isSticker = lastMessage.toString().toLowerCase().contains('sticker');
    final previewText = isBlockedByMe ? 'Blocked' : isSticker ? '🌟 Sticker' : lastMessage;

    final tile = InkWell(
      onTap: () {
        if (_selectionMode) {
          _toggleSelect(chatId);
        } else {
          _openChat(
            chatId: chatId,
            name: name,
            avatar: avatar,
            isGroup: isGroup,
            isChannel: isChannel,
            otherUserId: otherUserId,
          );
        }
      },
      onLongPress: () {
        HapticFeedback.mediumImpact();
        _toggleSelect(chatId);
      },
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 150),
        color: isSelected ? theme.colorScheme.primary.withOpacity(isDark ? 0.22 : 0.12) : Colors.transparent,
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        child: Row(
          children: [
            Stack(
              children: [
                CircleAvatar(
                  radius: 27,
                  backgroundColor: theme.colorScheme.primary.withOpacity(0.15),
                  backgroundImage: (avatar != null && avatar.isNotEmpty) ? NetworkImage(avatar) : null,
                  child: (avatar == null || avatar.isEmpty) ? Icon(isChannel ? Icons.campaign : isGroup ? Icons.group : isBot ? Icons.smart_toy : Icons.person, color: theme.colorScheme.primary, size: 24) : null,
                ),
                if (isSelected)
                  Positioned(
                    right: -1,
                    bottom: -1,
                    child: Container(
                      width: 22,
                      height: 22,
                      decoration: BoxDecoration(
                        color: theme.colorScheme.primary,
                        shape: BoxShape.circle,
                        border: Border.all(color: isDark ? const Color(0xFF000000) : Colors.white, width: 2),
                      ),
                      child: const Icon(Icons.check, size: 13, color: Colors.white),
                    ),
                  )
                else if (isChannel)
                  Positioned(
                    right: 0,
                    bottom: 0,
                    child: Container(
                      width: 18,
                      height: 18,
                      decoration: BoxDecoration(color: theme.colorScheme.primary, shape: BoxShape.circle, border: Border.all(color: isDark ? const Color(0xFF000000) : Colors.white, width: 2)),
                      child: const Icon(Icons.check, size: 10, color: Colors.white),
                    ),
                  ),
              ],
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Flexible(child: Text(name, maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 16, fontWeight: FontWeight.w500, color: theme.colorScheme.onSurface))),
                      if (isPremium) ...[
                        const SizedBox(width: 4),
                        const Icon(Icons.stars, size: 16, color: Color(0xFFD4A73A)),
                      ],
                      if (isMuted) ...[const SizedBox(width: 4), Icon(Icons.notifications_off, size: 14, color: theme.colorScheme.onSurface.withOpacity(0.4))],
                      if (isPinned) ...[const SizedBox(width: 4), Icon(Icons.push_pin, size: 14, color: theme.colorScheme.onSurface.withOpacity(0.4))],
                    ],
                  ),
                  const SizedBox(height: 2),
                  Text(previewText, maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 14, color: unread > 0 ? theme.colorScheme.onSurface.withOpacity(0.75) : theme.colorScheme.onSurface.withOpacity(0.55))),
                ],
              ),
            ),
            Column(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Text(_formatChatTime(chat['last_message_at']), style: TextStyle(fontSize: 12, color: unread > 0 ? theme.colorScheme.primary : theme.colorScheme.onSurface.withOpacity(0.4))),
                if (unread > 0) ...[
                  const SizedBox(height: 4),
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                    decoration: BoxDecoration(color: theme.colorScheme.primary, borderRadius: BorderRadius.circular(11)),
                    child: Text('$unread', style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: Colors.white)),
                  ),
                ],
              ],
            ),
          ],
        ),
      ),
    );

    return Slidable(
      key: ValueKey(chatId),
      enabled: !_selectionMode,
      endActionPane: ActionPane(
        motion: const DrawerMotion(),
        extentRatio: 0.5,
        children: [
          SlidableAction(
            onPressed: (_) => _addChatToFolder(chatId),
            backgroundColor: const Color(0xFF4FAE4F),
            foregroundColor: Colors.white,
            icon: Icons.folder,
            label: 'Folder',
          ),
          SlidableAction(
            onPressed: (_) => _toggleArchive(chatId, isArchived),
            backgroundColor: theme.colorScheme.primary,
            foregroundColor: Colors.white,
            icon: Icons.archive_outlined,
            label: 'Archive',
          ),
        ],
      ),
      child: tile,
    );
  }
}
