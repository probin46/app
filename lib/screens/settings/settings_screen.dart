import 'dart:convert';
import 'dart:io';
import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:image_picker/image_picker.dart';
import 'package:provider/provider.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:url_launcher/url_launcher.dart';
import '../../providers/auth_provider.dart' show LumaAuthProvider;
import '../../utils/verified_badge.dart';
import '../../services/cloudinary_service.dart';
import 'luma_premium_screen.dart';
// 👇 Luma Star purchase screen (rename your file to luma_star_screen.dart)
import 'luma_star_screen.dart';

const String _cloudName = 'dn2mwp1lc';
const String _uploadPreset = 'aura_chat';

class AppLocalizations {
  static String currentLanguage = 'en';

  static final Map<String, Map<String, String>> _translations = {
    'en': {
      'settings': 'Settings',
      'account': 'Account',
      'security_change_number': 'Security, change number',
      'privacy': 'Privacy',
      'block_contacts': 'Block contacts, disappearing messages',
      'avatar': 'Avatar',
      'create_edit_photo': 'Create, edit, profile photo',
      'chats': 'Chats',
      'theme_wallpapers': 'Theme, wallpapers, chat history',
      'notifications': 'Notifications',
      'message_group_call_tones': 'Message, group & call tones',
      'storage_and_data': 'Storage and Data',
      'network_usage': 'Network usage, auto-download',
      'app_language': 'App Language',
      'english_default': 'English (device default)',
      'help': 'Help',
      'help_center': 'Help center, contact us, privacy policy',
      'invite_friends': 'Invite Friends',
      'log_out': 'Log Out',
      'version': 'Luma Chat v1.0.0',
      'select_language': 'Select Language',
      'cancel': 'Cancel',
      'preferences': 'Preferences',
      'phone_number': 'Phone Number',
      'phone_hint': 'Add phone number',
      'phone_saved': 'Phone number updated',
      'edit_phone': 'Edit phone number',
      'save': 'Save',
    },
    // Keep your existing es/fr/ha/yo/ig maps unchanged here
  };

  static String get(String key) {
    return _translations[currentLanguage]?[key] ??
        _translations['en']?[key] ??
        key;
  }

  static List<Map<String, String>> get supportedLanguages => [
        {'code': 'en', 'name': 'English'},
        {'code': 'es', 'name': 'Español'},
        {'code': 'fr', 'name': 'Français'},
        {'code': 'ha', 'name': 'Hausa'},
        {'code': 'yo', 'name': 'Yorùbá'},
        {'code': 'ig', 'name': 'Igbo'},
      ];
}

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  File? _newProfileImage;
  bool _isUploading = false;
  String? _phoneNumber;

  @override
  void initState() {
    super.initState();
    _loadLanguage();
    _loadPhoneNumber();
  }

  Future<void> _loadLanguage() async {
    final prefs = await SharedPreferences.getInstance();
    final savedLang = prefs.getString('app_language');
    if (savedLang != null && mounted) {
      setState(() => AppLocalizations.currentLanguage = savedLang);
    }
  }

  Future<void> _loadPhoneNumber() async {
    try {
      final authProvider =
          Provider.of<LumaAuthProvider>(context, listen: false);
      final userId = authProvider.user?.uid ?? authProvider.mockUserId;
      if (userId == null) return;
      final doc = await FirebaseFirestore.instance
          .collection('users')
          .doc(userId)
          .get();
      final phone = doc.data()?['phone_number'] as String?;
      if (mounted) setState(() => _phoneNumber = phone);
    } catch (_) {}
  }

  Future<void> _pickNewProfileImage() async {
    final picker = ImagePicker();
    final picked = await picker.pickImage(
      source: ImageSource.gallery,
      maxWidth: 512,
      maxHeight: 512,
      imageQuality: 85,
    );
    if (picked == null) return;

    setState(() {
      _newProfileImage = File(picked.path);
      _isUploading = true;
    });

    await _uploadProfileImage();
  }

  Future<void> _uploadProfileImage() async {
    if (_newProfileImage == null) return;

    try {
      final authProvider =
          Provider.of<LumaAuthProvider>(context, listen: false);
      final userId = authProvider.user?.uid ?? authProvider.mockUserId;
      if (userId == null) return;

      final userDoc = await FirebaseFirestore.instance
          .collection('users')
          .doc(userId)
          .get();
      final currentAvatarUrl = userDoc.data()?['avatar_url'] as String?;

      if (currentAvatarUrl != null && currentAvatarUrl.isNotEmpty) {
        await CloudinaryService.deleteFile(currentAvatarUrl);
      }

      final fileBytes = await _newProfileImage!.readAsBytes();
      final fileName =
          'profile_${DateTime.now().millisecondsSinceEpoch}.jpg';

      final uri = Uri.parse(
        'https://api.cloudinary.com/v1_1/$_cloudName/image/upload',
      );

      final request = http.MultipartRequest('POST', uri)
        ..fields['upload_preset'] = _uploadPreset
        ..fields['public_id'] = 'luma_profiles/$userId/$fileName'
        ..files.add(
          http.MultipartFile.fromBytes('file', fileBytes,
              filename: fileName),
        );

      final response = await request.send();
      final responseData = await response.stream.bytesToString();
      final jsonData = jsonDecode(responseData);

      if (response.statusCode != 200) {
        throw Exception(
            'Cloudinary error: ${jsonData['error']?['message'] ?? responseData}');
      }

      final publicUrl = jsonData['secure_url'] as String;

      await FirebaseFirestore.instance.collection('users').doc(userId).set({
        'avatar_url': publicUrl,
        'updated_at': FieldValue.serverTimestamp(),
      }, SetOptions(merge: true));

      await authProvider.updateProfile(photoUrl: publicUrl);

      if (!mounted) return;
      setState(() => _isUploading = false);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('${AppLocalizations.get('avatar')} updated!'),
          behavior: SnackBarBehavior.floating,
        ),
      );
    } catch (e) {
      if (!mounted) return;
      setState(() => _isUploading = false);
      debugPrint('Cloudinary upload error: $e');
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Failed to upload: $e'),
          behavior: SnackBarBehavior.floating,
        ),
      );
    }
  }

  // =========================================================================
  // PHONE NUMBER EDIT (glass-style dialog)
  // =========================================================================
  Future<void> _editPhoneNumber() async {
    final theme = Theme.of(context);
    final controller = TextEditingController(text: _phoneNumber ?? '');
    final saved = await showDialog<String>(
      context: context,
      builder: (ctx) => Dialog(
        shape:
            RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        backgroundColor: theme.brightness == Brightness.dark
            ? const Color(0xFF1F2C34).withOpacity(0.92)
            : Colors.white.withOpacity(0.92),
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                AppLocalizations.get('edit_phone'),
                style: const TextStyle(
                    fontSize: 17, fontWeight: FontWeight.w600),
              ),
              const SizedBox(height: 16),
              TextField(
                controller: controller,
                keyboardType: TextInputType.phone,
                inputFormatters: [
                  FilteringTextInputFormatter.allow(RegExp(r'[0-9+\-\s]')),
                ],
                decoration: InputDecoration(
                  prefixIcon: const Icon(Icons.phone_outlined),
                  hintText: '+1 555 123 4567',
                  filled: true,
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(12),
                    borderSide: BorderSide.none,
                  ),
                ),
              ),
              const SizedBox(height: 20),
              Row(
                children: [
                  Expanded(
                    child: TextButton(
                      onPressed: () => Navigator.pop(ctx),
                      child: Text(AppLocalizations.get('cancel')),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: ElevatedButton(
                      onPressed: () =>
                          Navigator.pop(ctx, controller.text.trim()),
                      style: ElevatedButton.styleFrom(
                        shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(12)),
                      ),
                      child: Text(AppLocalizations.get('save')),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );

    if (saved == null) return;

    try {
      final authProvider =
          Provider.of<LumaAuthProvider>(context, listen: false);
      final userId = authProvider.user?.uid ?? authProvider.mockUserId;
      if (userId == null) return;

      await FirebaseFirestore.instance.collection('users').doc(userId).set({
        'phone_number': saved,
        'updated_at': FieldValue.serverTimestamp(),
      }, SetOptions(merge: true));

      if (!mounted) return;
      setState(() => _phoneNumber = saved.isEmpty ? null : saved);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(AppLocalizations.get('phone_saved')),
          behavior: SnackBarBehavior.floating,
        ),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Failed: $e')),
      );
    }
  }

  Future<void> _backupChats() async {
    try {
      final authProvider =
          Provider.of<LumaAuthProvider>(context, listen: false);
      final userId = authProvider.user?.uid ?? authProvider.mockUserId;
      final userEmail = authProvider.user?.email;

      if (userId == null) {
        _showBackupError('Not authenticated');
        return;
      }

      if (mounted) setState(() => _isUploading = true);

      final chatsSnapshot = await FirebaseFirestore.instance
          .collection('chats')
          .where('participants', arrayContains: userId)
          .get();

      final backupData = <Map<String, dynamic>>[];

      for (final chatDoc in chatsSnapshot.docs) {
        final chatId = chatDoc.id;
        final messagesSnapshot = await FirebaseFirestore.instance
            .collection('chats')
            .doc(chatId)
            .collection('messages')
            .orderBy('created_at')
            .get();

        final messages = messagesSnapshot.docs.map((m) {
          final data = m.data();
          final ts = data['created_at'] ?? data['timestamp'];
          return {
            'id': m.id,
            'sender_id': data['sender_id'],
            'text': data['text'],
            'created_at':
                ts is Timestamp ? ts.toDate().toIso8601String() : null,
            'type': data['type'] ?? 'text',
            'media_url': data['media_url'],
          };
        }).toList();

        backupData.add({
          'chat_id': chatId,
          'participants': chatDoc.data()['participants'],
          'messages': messages,
        });
      }

      final jsonString = jsonEncode({
        'exported_at': DateTime.now().toIso8601String(),
        'user_id': userId,
        'chats': backupData,
      });

      final tempDir = Directory.systemTemp;
      final fileName =
          'luma_backup_${DateTime.now().millisecondsSinceEpoch}.json';
      final file = File('${tempDir.path}/$fileName');
      await file.writeAsString(jsonString);

      if (mounted) setState(() => _isUploading = false);

      final emailBody = Uri.encodeComponent(
        'Luma Chat Backup\n\n'
        'Exported: ${DateTime.now().toIso8601String()}\n'
        'Chats backed up: ${backupData.length}\n\n'
        'Please attach the backup file from:\n${file.path}\n\n'
        'To restore: Save this email and use Restore in Luma Chat settings.',
      );

      final emailSubject = Uri.encodeComponent(
          'Luma Chat Backup - ${DateTime.now().toLocal()}');
      final emailUri = Uri.parse(
          'mailto:${userEmail ?? ''}?subject=$emailSubject&body=$emailBody');

      if (await canLaunchUrl(emailUri)) {
        await launchUrl(emailUri);
      } else {
        if (!mounted) return;
        showDialog(
          context: context,
          builder: (context) => AlertDialog(
            title: const Text('Backup Ready'),
            content: Text(
              'Chat backup saved locally.\n\nFile: ${file.path}\n\n'
              '${backupData.length} chats backed up.\n\n'
              'Please manually email this file to yourself for safekeeping.',
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context),
                child: const Text('OK'),
              ),
            ],
          ),
        );
      }
    } catch (e) {
      if (mounted) setState(() => _isUploading = false);
      _showBackupError('Backup failed: $e');
    }
  }

  void _showBackupError(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message),
        behavior: SnackBarBehavior.floating,
      ),
    );
  }

  void _showLanguagePicker() {
    final theme = Theme.of(context);
    showModalBottomSheet(
      context: context,
      backgroundColor: theme.brightness == Brightness.dark
          ? const Color(0xFF1F1F1F)
          : Colors.white,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (_) => SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 8),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 36,
                height: 4,
                margin: const EdgeInsets.only(bottom: 8),
                decoration: BoxDecoration(
                  color: theme.dividerColor,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
              Padding(
                padding:
                    const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: Text(
                    AppLocalizations.get('select_language'),
                    style: theme.textTheme.titleMedium
                        ?.copyWith(fontWeight: FontWeight.w600),
                  ),
                ),
              ),
              ...AppLocalizations.supportedLanguages.map((lang) {
                final isSelected =
                    AppLocalizations.currentLanguage == lang['code'];
                return ListTile(
                  leading: Icon(
                    isSelected
                        ? Icons.radio_button_checked
                        : Icons.radio_button_off,
                    color: isSelected
                        ? theme.colorScheme.primary
                        : theme.colorScheme.onSurface.withOpacity(0.4),
                  ),
                  title: Text(
                    lang['name']!,
                    style: TextStyle(
                      color: isSelected
                          ? theme.colorScheme.primary
                          : theme.colorScheme.onSurface,
                      fontWeight:
                          isSelected ? FontWeight.w600 : FontWeight.w400,
                    ),
                  ),
                  onTap: () async {
                    final prefs = await SharedPreferences.getInstance();
                    await prefs.setString('app_language', lang['code']!);
                    if (!mounted) return;
                    setState(() {
                      AppLocalizations.currentLanguage = lang['code']!;
                    });
                    Navigator.pop(context);
                  },
                );
              }),
            ],
          ),
        ),
      ),
    );
  }

  // =========================================================================
  // FIXED LOGOUT — goes to PHONE ENTRY, not email verification
  // =========================================================================
  Future<void> _logOut() async {
    final authProvider = Provider.of<LumaAuthProvider>(context, listen: false);

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => Dialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        backgroundColor: Theme.of(ctx).brightness == Brightness.dark
            ? const Color(0xFF1F2C34)
            : Colors.white,
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  color: Colors.red.withOpacity(0.1),
                  shape: BoxShape.circle,
                ),
                child: const Icon(Icons.logout, color: Colors.red, size: 32),
              ),
              const SizedBox(height: 16),
              Text(
                AppLocalizations.get('log_out'),
                style: const TextStyle(
                    fontSize: 20, fontWeight: FontWeight.bold),
              ),
              const SizedBox(height: 8),
              Text(
                'Are you sure you want to log out of Luma Chat?',
                textAlign: TextAlign.center,
                style: TextStyle(
                  color: Theme.of(ctx)
                      .colorScheme
                      .onSurface
                      .withOpacity(0.6),
                  fontSize: 14,
                ),
              ),
              const SizedBox(height: 24),
              Row(
                children: [
                  Expanded(
                    child: TextButton(
                      onPressed: () => Navigator.pop(ctx, false),
                      style: TextButton.styleFrom(
                        padding: const EdgeInsets.symmetric(vertical: 14),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(12),
                          side:
                              BorderSide(color: Theme.of(ctx).dividerColor),
                        ),
                      ),
                      child: Text(
                        AppLocalizations.get('cancel'),
                        style: const TextStyle(
                            color: Colors.grey,
                            fontWeight: FontWeight.bold),
                      ),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: ElevatedButton(
                      onPressed: () => Navigator.pop(ctx, true),
                      style: ElevatedButton.styleFrom(
                        backgroundColor: Colors.red,
                        foregroundColor: Colors.white,
                        padding: const EdgeInsets.symmetric(vertical: 14),
                        shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(12)),
                      ),
                      child: const Text('Log Out',
                          style: TextStyle(fontWeight: FontWeight.bold)),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );

    if (confirmed != true) return;

    try {
      await authProvider.signOut();
      if (!mounted) return;

      // ✅ FIX: always land on phone entry, clear the entire stack
      Navigator.pushNamedAndRemoveUntil(
        context,
        '/phone_entry',
        (route) => false,
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Failed to log out. Try again.')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final authProvider = Provider.of<LumaAuthProvider>(context);
    final username = authProvider.userName ?? 'Unknown';
    final displayName = authProvider.displayName ?? username;
    final email = authProvider.email ?? '';
    final avatar = authProvider.userPhotoUrl;
    final userVerified = isVerified(email);

    final currentLang = AppLocalizations.supportedLanguages.firstWhere(
      (l) => l['code'] == AppLocalizations.currentLanguage,
      orElse: () => {'code': 'en', 'name': 'English'},
    );

    final countryCode = Localizations.localeOf(context).countryCode;
    final premiumPriceText = countryCode == 'NG' ? '₦2,000/mo' : '\$4.99/mo';

    return Scaffold(
      backgroundColor: theme.scaffoldBackgroundColor,
      body: SafeArea(
        bottom: false,
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 8, 4),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      AppLocalizations.get('settings'),
                      style: theme.textTheme.titleLarge
                          ?.copyWith(fontWeight: FontWeight.w600),
                    ),
                  ),
                  IconButton(
                    icon: const Icon(Icons.search),
                    onPressed: () {},
                  ),
                ],
              ),
            ),
            Expanded(
              child: ListView(
                padding: const EdgeInsets.only(bottom: 96),
                children: [
                  // ── Profile Header ──
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
                    child: Row(
                      children: [
                        GestureDetector(
                          onTap: _isUploading ? null : _pickNewProfileImage,
                          child: Stack(
                            children: [
                              _buildAvatar(theme, avatar, _newProfileImage),
                              Positioned(
                                bottom: 0,
                                right: 0,
                                child: Container(
                                  padding: const EdgeInsets.all(3),
                                  decoration: BoxDecoration(
                                    color: theme.colorScheme.primary,
                                    shape: BoxShape.circle,
                                    border: Border.all(
                                      color: theme.scaffoldBackgroundColor,
                                      width: 2,
                                    ),
                                  ),
                                  child: _isUploading
                                      ? const SizedBox(
                                          width: 12,
                                          height: 12,
                                          child: CircularProgressIndicator(
                                            strokeWidth: 2,
                                            color: Colors.white,
                                          ),
                                        )
                                      : const Icon(Icons.camera_alt,
                                          size: 12, color: Colors.white),
                                ),
                              ),
                            ],
                          ),
                        ),
                        const SizedBox(width: 16),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Row(
                                children: [
                                  Flexible(
                                    child: Text(
                                      displayName,
                                      style: theme.textTheme.titleMedium
                                          ?.copyWith(
                                        fontWeight: FontWeight.w600,
                                        fontSize: 17,
                                      ),
                                      overflow: TextOverflow.ellipsis,
                                    ),
                                  ),
                                  if (userVerified) ...[
                                    const SizedBox(width: 6),
                                    const VerifiedBadge(
                                        size: 14, showTooltip: false),
                                  ],
                                ],
                              ),
                              const SizedBox(height: 2),
                              Text(
                                '@$username',
                                style: theme.textTheme.bodySmall?.copyWith(
                                  color: theme.colorScheme.onSurface
                                      .withOpacity(0.55),
                                  fontSize: 13,
                                ),
                              ),
                              const SizedBox(height: 2),
                              Text(
                                email,
                                style: theme.textTheme.bodySmall?.copyWith(
                                  color: theme.colorScheme.onSurface
                                      .withOpacity(0.45),
                                  fontSize: 13,
                                ),
                                overflow: TextOverflow.ellipsis,
                              ),
                              // ✅ Phone number under email
                              if (_phoneNumber != null &&
                                  _phoneNumber!.isNotEmpty) ...[
                                const SizedBox(height: 2),
                                Row(
                                  children: [
                                    Icon(
                                      Icons.phone_iphone,
                                      size: 12,
                                      color: theme.colorScheme.onSurface
                                          .withOpacity(0.45),
                                    ),
                                    const SizedBox(width: 4),
                                    Text(
                                      _phoneNumber!,
                                      style: theme.textTheme.bodySmall
                                          ?.copyWith(
                                        color: theme.colorScheme.onSurface
                                            .withOpacity(0.45),
                                        fontSize: 13,
                                      ),
                                    ),
                                  ],
                                ),
                              ],
                            ],
                          ),
                        ),
                        IconButton(
                          icon: Icon(Icons.qr_code,
                              color: theme.colorScheme.onSurface
                                  .withOpacity(0.7)),
                          onPressed: () {},
                        ),
                      ],
                    ),
                  ),

                  // ── LUMA PREMIUM (glass) ──
                  _glassCard(
                    theme: theme,
                    margin: const EdgeInsets.symmetric(
                        horizontal: 16, vertical: 8),
                    padding: const EdgeInsets.all(16),
                    borderRadius: 16,
                    borderColor: const Color(0xFFD4A73A).withOpacity(0.6),
                    gradientColors: const [
                      Color(0xFF2B2B2B),
                      Color(0xFF1A1A1A)
                    ],
                    child: Row(
                      children: [
                        const Icon(Icons.stars,
                            color: Color(0xFFD4A73A), size: 32),
                        const SizedBox(width: 16),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              const Text(
                                'Luma Premium',
                                style: TextStyle(
                                    color: Colors.white,
                                    fontWeight: FontWeight.bold,
                                    fontSize: 16),
                              ),
                              Text(
                                'Get exclusive features • $premiumPriceText',
                                style: const TextStyle(
                                    color: Colors.white70, fontSize: 13),
                              ),
                            ],
                          ),
                        ),
                        const Icon(Icons.chevron_right,
                            color: Colors.white54),
                      ],
                    ),
                    onTap: () => Navigator.push(
                      context,
                      MaterialPageRoute(
                          builder: (_) => const LumaPremiumScreen()),
                    ),
                  ),

                  Divider(height: 0.5, color: theme.dividerColor),

                  // ── ACCOUNT ──
                  _sectionTitle(theme, AppLocalizations.get('account')),
                  _tile(
                    theme,
                    icon: Icons.key_outlined,
                    title: AppLocalizations.get('account'),
                    subtitle: AppLocalizations.get('security_change_number'),
                    onTap: () =>
                        Navigator.pushNamed(context, '/account_settings'),
                  ),
                  _tile(
                    theme,
                    icon: Icons.phone_outlined,
                    title: AppLocalizations.get('phone_number'),
                    subtitle: (_phoneNumber == null ||
                            _phoneNumber!.isEmpty)
                        ? AppLocalizations.get('phone_hint')
                        : _phoneNumber!,
                    onTap: _editPhoneNumber,
                  ),
                  _tile(
                    theme,
                    icon: Icons.lock_outline,
                    title: AppLocalizations.get('privacy'),
                    subtitle: AppLocalizations.get('block_contacts'),
                    onTap: () =>
                        Navigator.pushNamed(context, '/privacy_settings'),
                  ),
                  _tile(
                    theme,
                    icon: Icons.face_outlined,
                    title: AppLocalizations.get('avatar'),
                    subtitle: AppLocalizations.get('create_edit_photo'),
                    onTap: _pickNewProfileImage,
                  ),

                  Divider(height: 0.5, color: theme.dividerColor),

                  // ── PREFERENCES ──
                  _sectionTitle(theme, AppLocalizations.get('preferences')),
                  _tile(
                    theme,
                    icon: Icons.chat_bubble_outline,
                    title: AppLocalizations.get('chats'),
                    subtitle: AppLocalizations.get('theme_wallpapers'),
                    onTap: () => Navigator.pushNamed(context, '/appearance'),
                  ),
                  _tile(
                    theme,
                    icon: Icons.notifications_none,
                    title: AppLocalizations.get('notifications'),
                    subtitle:
                        AppLocalizations.get('message_group_call_tones'),
                    onTap: () => Navigator.pushNamed(
                        context, '/notifications_settings'),
                  ),
                  _tile(
                    theme,
                    icon: Icons.storage_outlined,
                    title: AppLocalizations.get('storage_and_data'),
                    subtitle: AppLocalizations.get('network_usage'),
                    onTap: () =>
                        Navigator.pushNamed(context, '/data_storage'),
                  ),
                  _tile(
                    theme,
                    icon: Icons.language_outlined,
                    title: AppLocalizations.get('app_language'),
                    subtitle: currentLang['name']!,
                    onTap: _showLanguagePicker,
                  ),

                  // ✅ LUMA STAR — subtle, blends in with regular tiles.
                  // No banner, no gold color, just a quiet entry point.
                  _tile(
                    theme,
                    icon: Icons.auto_awesome_outlined,
                    title: 'Luma Star',
                    subtitle: 'Unlock exclusive perks',
                    onTap: () => Navigator.push(
                      context,
                      MaterialPageRoute(
                          builder: (_) => const LumaStarScreen()),
                    ),
                  ),

                  _tile(
                    theme,
                    icon: Icons.backup_outlined,
                    title: 'Backup Chats',
                    subtitle: 'Export chat history to email',
                    onTap: _backupChats,
                  ),
                  _tile(
                    theme,
                    icon: Icons.restore_outlined,
                    title: 'Restore Chats',
                    subtitle: 'Import chat history from backup',
                    onTap: () =>
                        Navigator.pushNamed(context, '/restore_chats'),
                  ),

                  Divider(height: 0.5, color: theme.dividerColor),

                  // ── HELP ──
                  _sectionTitle(theme, AppLocalizations.get('help')),
                  _tile(
                    theme,
                    icon: Icons.help_outline,
                    title: AppLocalizations.get('help'),
                    subtitle: AppLocalizations.get('help_center'),
                    onTap: () {
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(
                            content: Text('Help center coming soon')),
                      );
                    },
                  ),
                  _tile(
                    theme,
                    icon: Icons.people_outline,
                    title: AppLocalizations.get('invite_friends'),
                    onTap: () =>
                        Navigator.pushNamed(context, '/invite_friends'),
                  ),

                  Divider(height: 0.5, color: theme.dividerColor),

                  ListTile(
                    leading:
                        Icon(Icons.logout, color: theme.colorScheme.error),
                    title: Text(
                      AppLocalizations.get('log_out'),
                      style: TextStyle(
                        color: theme.colorScheme.error,
                        fontWeight: FontWeight.w500,
                        fontSize: 15,
                      ),
                    ),
                    onTap: _logOut,
                  ),

                  const SizedBox(height: 32),

                  Center(
                    child: Text(
                      AppLocalizations.get('version'),
                      style: TextStyle(
                        color:
                            theme.colorScheme.onSurface.withOpacity(0.3),
                        fontSize: 12,
                      ),
                    ),
                  ),

                  const SizedBox(height: 16),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  // ── Glass card helper (Telegram + iOS glass style) ──
  Widget _glassCard({
    required ThemeData theme,
    required Widget child,
    EdgeInsets margin = EdgeInsets.zero,
    EdgeInsets padding = const EdgeInsets.all(16),
    double borderRadius = 16,
    Color? borderColor,
    List<Color>? gradientColors,
    VoidCallback? onTap,
  }) {
    final card = Container(
      margin: margin,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(borderRadius),
        border: Border.all(
          color: borderColor ?? theme.dividerColor.withOpacity(0.4),
        ),
        gradient: LinearGradient(
          colors: gradientColors ??
              [
                theme.colorScheme.surface.withOpacity(0.85),
                theme.colorScheme.surface.withOpacity(0.55),
              ],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.12),
            blurRadius: 12,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(borderRadius),
        child: BackdropFilter(
          filter: ImageFilter.blur(sigmaX: 8, sigmaY: 8),
          child: Padding(padding: padding, child: child),
        ),
      ),
    );

    if (onTap == null) return card;
    return InkWell(
      borderRadius: BorderRadius.circular(borderRadius),
      onTap: onTap,
      child: card,
    );
  }

  Widget _buildAvatar(
      ThemeData theme, String? avatarUrl, File? localFile) {
    const size = 72.0;

    if (localFile != null) {
      return ClipOval(
        child: Image.file(localFile,
            width: size, height: size, fit: BoxFit.cover),
      );
    }

    if (avatarUrl == null || avatarUrl.isEmpty) {
      return Container(
        width: size,
        height: size,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: theme.colorScheme.primary.withOpacity(0.15),
        ),
        child: Icon(Icons.person,
            color: theme.colorScheme.primary, size: 34),
      );
    }

    return ClipOval(
      child: Image.network(
        avatarUrl,
        width: size,
        height: size,
        fit: BoxFit.cover,
        loadingBuilder: (context, child, loadingProgress) {
          if (loadingProgress == null) return child;
          return Container(
            width: size,
            height: size,
            color: theme.colorScheme.primary.withOpacity(0.15),
            child: const Center(
              child: SizedBox(
                width: 20,
                height: 20,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
            ),
          );
        },
        errorBuilder: (_, __, ___) => Container(
          width: size,
          height: size,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: theme.colorScheme.primary.withOpacity(0.15),
          ),
          child: Icon(Icons.person,
              color: theme.colorScheme.primary, size: 34),
        ),
      ),
    );
  }

  Widget _sectionTitle(ThemeData theme, String title) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
      child: Text(
        title.toUpperCase(),
        style: TextStyle(
          fontSize: 12,
          fontWeight: FontWeight.w600,
          color: theme.colorScheme.onSurface.withOpacity(0.55),
          letterSpacing: 0.6,
        ),
      ),
    );
  }

  Widget _tile(
    ThemeData theme, {
    required IconData icon,
    required String title,
    String? subtitle,
    required VoidCallback onTap,
  }) {
    return ListTile(
      leading: Icon(icon,
          color: theme.colorScheme.onSurface.withOpacity(0.75)),
      title: Text(
        title,
        style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w500),
      ),
      subtitle: subtitle != null
          ? Padding(
              padding: const EdgeInsets.only(top: 2),
              child: Text(
                subtitle,
                style: TextStyle(
                  fontSize: 13,
                  color: theme.colorScheme.onSurface.withOpacity(0.5),
                ),
              ),
            )
          : null,
      trailing: Icon(
        Icons.chevron_right,
        color: theme.colorScheme.onSurface.withOpacity(0.35),
        size: 20,
      ),
      onTap: onTap,
    );
  }
}
