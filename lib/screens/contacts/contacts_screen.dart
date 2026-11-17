import 'dart:async';

import 'package:flutter/material.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:provider/provider.dart';
import 'package:flutter_contacts/flutter_contacts.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:country_picker/country_picker.dart';

import '../../providers/auth_provider.dart' show LumaAuthProvider;

class ContactsScreen extends StatefulWidget {
  const ContactsScreen({super.key});

  @override
  State<ContactsScreen> createState() => _ContactsScreenState();
}

class _ContactsScreenState extends State<ContactsScreen> {
  String? _currentUserId;
  bool _isLoading = true;
  bool _permissionDenied = false;
  List<Map<String, dynamic>> _lumaContacts = [];
  List<Map<String, dynamic>> _inviteContacts = [];
  String _searchQuery = '';
  final TextEditingController _searchController = TextEditingController();

  @override
  void initState() {
    super.initState();
    final auth = Provider.of<LumaAuthProvider>(context, listen: false);
    _currentUserId = auth.user?.uid ?? auth.mockUserId;
    _loadContacts();
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  // ═══════════════════════════════════════════════════════════════════════
  // PHONE NORMALIZATION (last 10 digits, ignores +, spaces, leading 0)
  // ═══════════════════════════════════════════════════════════════════════
  String _normalizePhone(String raw) {
    final digits = raw.replaceAll(RegExp(r'[^\d]'), '');
    if (digits.length > 10) return digits.substring(digits.length - 10);
    return digits;
  }

  // ═══════════════════════════════════════════════════════════════════════
  // LOAD CONTACTS
  // ═══════════════════════════════════════════════════════════════════════
  Future<void> _loadContacts() async {
    setState(() => _isLoading = true);

    try {
      final status = await Permission.contacts.request();
      if (status.isDenied || status.isPermanentlyDenied) {
        setState(() {
          _permissionDenied = true;
          _isLoading = false;
        });
        return;
      }

      final contacts = await FlutterContacts.getContacts(withProperties: true);

      final lumaUsersSnap =
          await FirebaseFirestore.instance.collection('users').get();

      // Build a lookup: normalized phone -> user data.
      // PhoneEntryScreen stores the number in "phone" (older docs may use
      // "phone_number"), so we check both.
      final Map<String, Map<String, dynamic>> lumaByPhone = {};
      for (final doc in lumaUsersSnap.docs) {
        if (doc.id == _currentUserId) continue; // skip yourself
        final data = doc.data();
        final rawUserPhone =
            (data['phone'] ?? data['phone_number'] ?? '').toString();
        final key = _normalizePhone(rawUserPhone);
        if (key.isNotEmpty) {
          lumaByPhone[key] = {'id': doc.id, ...data};
        }
      }

      final matched = <Map<String, dynamic>>[];
      final invites = <Map<String, dynamic>>[];
      final Set<String> processedNumbers = {};

      for (final c in contacts) {
        if (c.phones.isEmpty) continue;

        final rawPhone = c.phones.first.number;
        final phone = _normalizePhone(rawPhone);
        if (phone.isEmpty || processedNumbers.contains(phone)) continue;
        processedNumbers.add(phone);

        final displayName = c.displayName.isNotEmpty ? c.displayName : rawPhone;
        final lumaUser = lumaByPhone[phone];

        if (lumaUser != null) {
          matched.add({
            'id': lumaUser['id'],
            'name': lumaUser['display_name'] ?? displayName,
            'phone': rawPhone,
            'avatar_url': lumaUser['avatar_url'],
            'is_on_luma': true,
          });
        } else {
          invites.add({
            'id': rawPhone,
            'name': displayName,
            'phone': rawPhone,
            'is_on_luma': false,
          });
        }
      }

      matched.sort((a, b) => (a['name'] as String)
          .toLowerCase()
          .compareTo((b['name'] as String).toLowerCase()));
      invites.sort((a, b) => (a['name'] as String)
          .toLowerCase()
          .compareTo((b['name'] as String).toLowerCase()));

      if (mounted) {
        setState(() {
          _lumaContacts = matched;
          _inviteContacts = invites;
          _isLoading = false;
          _permissionDenied = false;
        });
      }
    } catch (e) {
      debugPrint('Contact load error: $e');
      if (mounted) setState(() => _isLoading = false);
    }
  }

  // ═══════════════════════════════════════════════════════════════════════
  // CHECK IF PHONE IS ON LUMA (direct query on the "phone" field)
  // ═══════════════════════════════════════════════════════════════════════
  Future<bool> _isPhoneOnLuma(String countryCode, String input) async {
    try {
      final digits = input.replaceAll(RegExp(r'\D'), '');
      if (digits.isEmpty) return false;
      final noZero = digits.replaceFirst(RegExp(r'^0+'), '');
      if (noZero.isEmpty) return false;

      // Match both "+234801..." and "+2340801..." in case of older saved data
      final candidates = {
        '+$countryCode$noZero',
        '+${countryCode}0$noZero',
        '+$countryCode$digits',
      }.toList();

      final snap = await FirebaseFirestore.instance
          .collection('users')
          .where('phone', whereIn: candidates)
          .limit(1)
          .get();
      return snap.docs.isNotEmpty;
    } catch (e) {
      debugPrint('Luma check error: $e');
      return false;
    }
  }

  // ═══════════════════════════════════════════════════════════════════════
  // NEW CONTACT MODAL
  // ═══════════════════════════════════════════════════════════════════════
  void _showNewContactSheet() {
    final nameCtrl = TextEditingController();
    final phoneCtrl = TextEditingController();
    Country? selectedCountry;
    bool isSaving = false;
    bool? isOnLuma;
    bool isChecking = false;
    Timer? debounce;

    Future<void> runCheck(StateSetter setModalState) async {
      final raw = phoneCtrl.text.trim();
      if (raw.isEmpty || selectedCountry == null) {
        setModalState(() {
          isOnLuma = null;
          isChecking = false;
        });
        return;
      }
      setModalState(() => isChecking = true);
      final result = await _isPhoneOnLuma(selectedCountry!.phoneCode, raw);
      if (!mounted) return;
      setModalState(() {
        isOnLuma = result;
        isChecking = false;
      });
    }

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (ctx) {
        final theme = Theme.of(ctx);
        final isDark = theme.brightness == Brightness.dark;

        return StatefulBuilder(
          builder: (context, setModalState) {
            return Padding(
              padding: EdgeInsets.only(
                  bottom: MediaQuery.of(ctx).viewInsets.bottom),
              child: Container(
                decoration: BoxDecoration(
                  color: isDark ? const Color(0xFF17212B) : Colors.white,
                  borderRadius:
                      const BorderRadius.vertical(top: Radius.circular(24)),
                ),
                padding: const EdgeInsets.all(24),
                child: SingleChildScrollView(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Container(
                        width: 40,
                        height: 4,
                        decoration: BoxDecoration(
                          color: Colors.grey.withOpacity(0.3),
                          borderRadius: BorderRadius.circular(2),
                        ),
                      ),
                      const SizedBox(height: 16),
                      Text(
                        'New Contact',
                        style: TextStyle(
                          fontSize: 20,
                          fontWeight: FontWeight.bold,
                          color: theme.colorScheme.onSurface,
                        ),
                      ),
                      const SizedBox(height: 24),

                      // Name field
                      _buildInputField(
                        theme,
                        'Contact Name',
                        nameCtrl,
                        Icons.person_outline,
                      ),
                      const SizedBox(height: 12),

                      // Country Picker + Phone Input Row
                      Container(
                        decoration: BoxDecoration(
                          color: isDark
                              ? const Color(0xFF242F3D)
                              : const Color(0xFFF1F1F1),
                          borderRadius: BorderRadius.circular(12),
                        ),
                        child: Row(
                          children: [
                            // Country Selector Button
                            InkWell(
                              onTap: () {
                                showCountryPicker(
                                  context: context,
                                  showPhoneCode: true,
                                  onSelect: (Country country) {
                                    setModalState(
                                        () => selectedCountry = country);
                                    // Re-check with the newly picked country
                                    debounce?.cancel();
                                    runCheck(setModalState);
                                  },
                                );
                              },
                              child: Container(
                                padding: const EdgeInsets.symmetric(
                                    horizontal: 16, vertical: 16),
                                child: Row(
                                  children: [
                                    Text(
                                      selectedCountry != null
                                          ? '${selectedCountry!.flagEmoji} +${selectedCountry!.phoneCode}'
                                          : 'Select',
                                      style: TextStyle(
                                        color: selectedCountry != null
                                            ? theme.colorScheme.onSurface
                                            : theme.colorScheme.onSurface
                                                .withOpacity(0.5),
                                        fontSize: 16,
                                      ),
                                    ),
                                    const Icon(Icons.arrow_drop_down),
                                  ],
                                ),
                              ),
                            ),
                            // Phone Number Input
                            Expanded(
                              child: TextField(
                                controller: phoneCtrl,
                                keyboardType: TextInputType.phone,
                                onChanged: (val) {
                                  debounce?.cancel();
                                  if (val.trim().isEmpty ||
                                      selectedCountry == null) {
                                    setModalState(() {
                                      isOnLuma = null;
                                      isChecking = false;
                                    });
                                    return;
                                  }
                                  debounce = Timer(
                                    const Duration(milliseconds: 500),
                                    () => runCheck(setModalState),
                                  );
                                },
                                decoration: const InputDecoration(
                                  hintText: 'Phone Number',
                                  border: InputBorder.none,
                                  contentPadding: EdgeInsets.symmetric(
                                      horizontal: 8, vertical: 16),
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),

                      // Status indicator
                      if (isChecking) ...[
                        const SizedBox(height: 12),
                        const Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            SizedBox(
                              width: 14,
                              height: 14,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            ),
                            SizedBox(width: 8),
                            Text('Checking Luma Chat...',
                                style: TextStyle(fontSize: 12)),
                          ],
                        ),
                      ] else if (isOnLuma != null) ...[
                        const SizedBox(height: 12),
                        Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 12, vertical: 8),
                          decoration: BoxDecoration(
                            color: isOnLuma!
                                ? Colors.green.withOpacity(0.1)
                                : Colors.orange.withOpacity(0.1),
                            borderRadius: BorderRadius.circular(8),
                          ),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Icon(
                                isOnLuma!
                                    ? Icons.check_circle
                                    : Icons.info_outline,
                                color:
                                    isOnLuma! ? Colors.green : Colors.orange,
                                size: 16,
                              ),
                              const SizedBox(width: 6),
                              Flexible(
                                child: Text(
                                  isOnLuma!
                                      ? 'On Luma Chat'
                                      : 'Not on Luma — they will receive an invite',
                                  style: TextStyle(
                                    fontSize: 12,
                                    color: isOnLuma!
                                        ? Colors.green
                                        : Colors.orange,
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ],

                      const SizedBox(height: 24),

                      SizedBox(
                        width: double.infinity,
                        height: 50,
                        child: ElevatedButton(
                          onPressed: (isSaving || isChecking)
                              ? null
                              : () async {
                                  if (phoneCtrl.text.trim().isEmpty ||
                                      selectedCountry == null) {
                                    ScaffoldMessenger.of(context).showSnackBar(
                                      const SnackBar(
                                        content: Text(
                                            'Please enter a phone number'),
                                      ),
                                    );
                                    return;
                                  }
                                  debounce?.cancel();
                                  setModalState(() => isSaving = true);

                                  try {
                                    // Store consistently: +<code><digits without leading 0>
                                    final digits = phoneCtrl.text
                                        .replaceAll(RegExp(r'\D'), '')
                                        .replaceFirst(RegExp(r'^0+'), '');
                                    final fullPhone =
                                        '+${selectedCountry!.phoneCode}$digits';
                                    final name = nameCtrl.text.trim().isEmpty
                                        ? fullPhone
                                        : nameCtrl.text.trim();

                                    // Save to phone's native contacts
                                    try {
                                      final newContact = Contact()
                                        ..name.first = name
                                        ..phones = [Phone(fullPhone)];
                                      await newContact.insert();
                                    } catch (e) {
                                      debugPrint(
                                          'Native contact save error: $e');
                                    }

                                    // Save to Firestore
                                    await FirebaseFirestore.instance
                                        .collection('users')
                                        .doc(_currentUserId)
                                        .collection('contacts')
                                        .add({
                                      'display_name': name,
                                      'phone_number': fullPhone,
                                      'created_at':
                                          FieldValue.serverTimestamp(),
                                    });

                                    if (!mounted) return;
                                    Navigator.pop(ctx);

                                    ScaffoldMessenger.of(this.context)
                                        .showSnackBar(
                                      SnackBar(
                                        content: Text(
                                          isOnLuma == true
                                              ? 'Contact saved — they are on Luma Chat!'
                                              : 'Contact saved. Invite them to Luma Chat!',
                                        ),
                                        duration: const Duration(seconds: 5),
                                      ),
                                    );

                                    _loadContacts();
                                  } catch (e) {
                                    debugPrint('Save contact error: $e');
                                    if (mounted) {
                                      ScaffoldMessenger.of(this.context)
                                          .showSnackBar(
                                        SnackBar(
                                          content: Text(
                                              'Failed to save contact: $e'),
                                        ),
                                      );
                                    }
                                  } finally {
                                    if (mounted) {
                                      try {
                                        setModalState(() => isSaving = false);
                                      } catch (_) {}
                                    }
                                  }
                                },
                          style: ElevatedButton.styleFrom(
                            backgroundColor: theme.colorScheme.primary,
                            foregroundColor: Colors.white,
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(14),
                            ),
                          ),
                          child: isSaving
                              ? const SizedBox(
                                  width: 20,
                                  height: 20,
                                  child: CircularProgressIndicator(
                                    color: Colors.white,
                                    strokeWidth: 2,
                                  ),
                                )
                              : const Text('Save Contact'),
                        ),
                      ),
                      const SizedBox(height: 8),
                    ],
                  ),
                ),
              ),
            );
          },
        );
      },
    ).whenComplete(() {
      debounce?.cancel();
      nameCtrl.dispose();
      phoneCtrl.dispose();
    });
  }

  // ═══════════════════════════════════════════════════════════════════════
  // INPUT FIELD HELPER
  // ═══════════════════════════════════════════════════════════════════════
  Widget _buildInputField(
    ThemeData theme,
    String hint,
    TextEditingController ctrl,
    IconData icon, {
    TextInputType? keyboardType,
  }) {
    final isDark = theme.brightness == Brightness.dark;
    return Container(
      decoration: BoxDecoration(
        color: isDark ? const Color(0xFF242F3D) : const Color(0xFFF1F1F1),
        borderRadius: BorderRadius.circular(12),
      ),
      child: TextField(
        controller: ctrl,
        keyboardType: keyboardType,
        decoration: InputDecoration(
          hintText: hint,
          prefixIcon: Icon(
            icon,
            color: theme.colorScheme.onSurface.withOpacity(0.5),
            size: 20,
          ),
          border: InputBorder.none,
          contentPadding:
              const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
        ),
      ),
    );
  }

  // ═══════════════════════════════════════════════════════════════════════
  // NEW GROUP / CHANNEL SHEET
  // ═══════════════════════════════════════════════════════════════════════
  void _showNewGroupSheet() {
    showModalBottomSheet(
      context: context,
      builder: (_) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.group),
              title: const Text('New Group'),
              onTap: () {
                Navigator.pop(context);
                Navigator.pushNamed(context, '/create_group');
              },
            ),
            ListTile(
              leading: const Icon(Icons.campaign),
              title: const Text('New Channel'),
              onTap: () {
                Navigator.pop(context);
                Navigator.pushNamed(context, '/create_channel');
              },
            ),
          ],
        ),
      ),
    );
  }

  // ═══════════════════════════════════════════════════════════════════════
  // OPEN SMS APP WITH INVITE MESSAGE
  // ═══════════════════════════════════════════════════════════════════════
  Future<void> _sendSmsInvite(String rawPhone) async {
    final phone = rawPhone.replaceAll(RegExp(r'[^\d+]'), '');
    const message =
        'DOWNLOAD LUMA CHAT ON PLAY STORE AND LET\'S CHAT TOGETHER';
    final encoded = Uri.encodeComponent(message);

    final androidUri = Uri.parse('sms:$phone?body=$encoded');
    final iosUri = Uri.parse('sms:$phone&body=$encoded');

    try {
      if (await canLaunchUrl(androidUri)) {
        await launchUrl(androidUri);
        return;
      }
      if (await canLaunchUrl(iosUri)) {
        await launchUrl(iosUri);
        return;
      }
      final dialUri = Uri.parse('tel:$phone');
      if (await canLaunchUrl(dialUri)) {
        await launchUrl(dialUri);
      } else if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Could not open SMS app')),
        );
      }
    } catch (e) {
      debugPrint('SMS launch error: $e');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Could not open SMS app: $e')),
        );
      }
    }
  }

  // ═══════════════════════════════════════════════════════════════════════
  // BUILD
  // ═══════════════════════════════════════════════════════════════════════
  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Scaffold(
      backgroundColor: theme.scaffoldBackgroundColor,
      appBar: AppBar(
        title: const Text('Contacts'),
        backgroundColor: theme.scaffoldBackgroundColor,
        actions: [
          IconButton(
            icon: const Icon(Icons.person_add_alt_1),
            onPressed: _showNewContactSheet,
          ),
          PopupMenuButton<String>(
            onSelected: (val) {
              if (val == 'group') _showNewGroupSheet();
              if (val == 'refresh') _loadContacts();
            },
            itemBuilder: (context) => [
              const PopupMenuItem(
                value: 'group',
                child: Text('New Group / Channel'),
              ),
              const PopupMenuItem(
                value: 'refresh',
                child: Text('Refresh'),
              ),
            ],
          ),
        ],
      ),
      body: Column(
        children: [
          // Search Bar
          Padding(
            padding: const EdgeInsets.all(16),
            child: TextField(
              controller: _searchController,
              onChanged: (v) =>
                  setState(() => _searchQuery = v.toLowerCase()),
              decoration: InputDecoration(
                hintText: 'Search contacts...',
                prefixIcon: const Icon(Icons.search),
                filled: true,
                fillColor: theme.colorScheme.onSurface.withOpacity(0.05),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                  borderSide: BorderSide.none,
                ),
              ),
            ),
          ),

          Expanded(
            child: _isLoading
                ? const Center(child: CircularProgressIndicator())
                : _permissionDenied
                    ? Center(
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            const Icon(Icons.lock_outline, size: 48),
                            const SizedBox(height: 12),
                            const Text('Contacts permission is required'),
                            const SizedBox(height: 12),
                            TextButton(
                              onPressed: _loadContacts,
                              child: const Text('Grant Permission'),
                            ),
                          ],
                        ),
                      )
                    : RefreshIndicator(
                        onRefresh: _loadContacts,
                        child: ListView(
                          children: [
                            if (_lumaContacts.isNotEmpty) ...[
                              _sectionHeader(theme, 'ON LUMA CHAT'),
                              ..._lumaContacts
                                  .where((c) => (c['name'] as String)
                                      .toLowerCase()
                                      .contains(_searchQuery))
                                  .map((c) => _contactTile(theme, c, true)),
                            ],
                            if (_inviteContacts.isNotEmpty) ...[
                              _sectionHeader(theme, 'INVITE TO LUMA CHAT'),
                              ..._inviteContacts
                                  .where((c) => (c['name'] as String)
                                      .toLowerCase()
                                      .contains(_searchQuery))
                                  .map((c) => _contactTile(theme, c, false)),
                            ],
                            if (_lumaContacts.isEmpty &&
                                _inviteContacts.isEmpty)
                              Padding(
                                padding: const EdgeInsets.all(32),
                                child: Center(
                                  child: Text(
                                    'No contacts found',
                                    style: TextStyle(
                                      color: theme.colorScheme.onSurface
                                          .withOpacity(0.5),
                                    ),
                                  ),
                                ),
                              ),
                          ],
                        ),
                      ),
          ),
        ],
      ),
    );
  }

  // ═══════════════════════════════════════════════════════════════════════
  // SECTION HEADER
  // ═══════════════════════════════════════════════════════════════════════
  Widget _sectionHeader(ThemeData theme, String title) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
      child: Text(
        title,
        style: TextStyle(
          fontSize: 12,
          fontWeight: FontWeight.bold,
          color: theme.colorScheme.primary,
          letterSpacing: 1.1,
        ),
      ),
    );
  }

  // ═══════════════════════════════════════════════════════════════════════
  // CONTACT TILE
  // ═══════════════════════════════════════════════════════════════════════
  Widget _contactTile(
      ThemeData theme, Map<String, dynamic> contact, bool isOnLuma) {
    return ListTile(
      leading: CircleAvatar(
        backgroundColor: theme.colorScheme.primary.withOpacity(0.1),
        backgroundImage: isOnLuma && contact['avatar_url'] != null
            ? NetworkImage(contact['avatar_url'])
            : null,
        child: !isOnLuma || contact['avatar_url'] == null
            ? Icon(Icons.person, color: theme.colorScheme.primary)
            : null,
      ),
      title: Text(contact['name']),
      subtitle: Text(contact['phone']),
      trailing: isOnLuma
          ? const Icon(Icons.chat_bubble_outline, size: 20)
          : InkWell(
              onTap: () => _sendSmsInvite(contact['phone']),
              child: Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                decoration: BoxDecoration(
                  color: theme.colorScheme.primary,
                  borderRadius: BorderRadius.circular(20),
                ),
                child: const Text(
                  'Invite',
                  style: TextStyle(color: Colors.white, fontSize: 12),
                ),
              ),
            ),
      onTap: () {
        if (isOnLuma) {
          Navigator.pushNamed(context, '/chat', arguments: {
            'chatName': contact['name'],
            'chatAvatar': contact['avatar_url'],
            'isGroup': false,
            'otherUserId': contact['id'],
          });
        } else {
          _sendSmsInvite(contact['phone']);
        }
      },
    );
  }
}
