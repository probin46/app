import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../../providers/auth_provider.dart' show LumaAuthProvider;

const Color _gold = Color(0xFFD4A73A);
const Color _goldSoft = Color(0xFFF2D27A);

class LumaStarScreen extends StatefulWidget {
  const LumaStarScreen({super.key});

  @override
  State<LumaStarScreen> createState() => _LumaStarScreenState();
}

class _LumaStarScreenState extends State<LumaStarScreen> {
  int _selectedPlan = 1; // 0 = weekly, 1 = monthly, 2 = yearly (default: monthly)
  bool _isPurchasing = false;
  bool _isStarActive = false;

  @override
  void initState() {
    super.initState();
    _loadStarStatus();
  }

  Future<void> _loadStarStatus() async {
    try {
      final auth = Provider.of<LumaAuthProvider>(context, listen: false);
      final uid = auth.user?.uid ?? auth.mockUserId;
      if (uid == null) return;
      final doc =
          await FirebaseFirestore.instance.collection('users').doc(uid).get();
      final active = doc.data()?['luma_star_active'] as bool? ?? false;
      if (mounted) setState(() => _isStarActive = active);
    } catch (_) {}
  }

  // ─────────────────────────────────────────────────────────────
  // Pricing — dynamic by locale (NGN for NG, USD elsewhere)
  // ─────────────────────────────────────────────────────────────
  List<_StarPlan> _plans() {
    final cc = Localizations.localeOf(context).countryCode;
    final isNG = cc == 'NG';
    return [
      _StarPlan(
        id: 'weekly',
        label: 'Weekly',
        price: isNG ? '₦600' : '\$1.99',
        per: '/week',
        sub: 'Try it short-term',
      ),
      _StarPlan(
        id: 'monthly',
        label: 'Monthly',
        price: isNG ? '₦2,000' : '\$4.99',
        per: '/month',
        sub: 'Most popular',
        badge: 'BEST VALUE',
      ),
      _StarPlan(
        id: 'yearly',
        label: 'Yearly',
        price: isNG ? '₦18,000' : '\$39.99',
        per: '/year',
        sub: 'Save ~33%',
        badge: 'SAVE 33%',
      ),
    ];
  }

  Future<void> _purchase() async {
    final plans = _plans();
    final plan = plans[_selectedPlan];

    setState(() => _isPurchasing = true);

    try {
      // ── TODO: Replace with your real billing call ──
      //   • Google Play Billing: launchBillingFlow(...)
      //   • RevenueCat: Purchases.purchasePackage(...)
      //   • Stripe: create checkout session via your backend
      //
      // For now we simulate a successful purchase after 1.2s
      // and write the entitlement to Firestore.
      await Future.delayed(const Duration(milliseconds: 1200));

      final auth = Provider.of<LumaAuthProvider>(context, listen: false);
      final uid = auth.user?.uid ?? auth.mockUserId;
      if (uid != null) {
        final expires = DateTime.now().add(
          plan.id == 'weekly'
              ? const Duration(days: 7)
              : plan.id == 'monthly'
                  ? const Duration(days: 30)
                  : const Duration(days: 365),
        );
        await FirebaseFirestore.instance.collection('users').doc(uid).set({
          'luma_star_active': true,
          'luma_star_plan': plan.id,
          'luma_star_expires_at': Timestamp.fromDate(expires),
          'updated_at': FieldValue.serverTimestamp(),
        }, SetOptions(merge: true));
      }

      // Persist plan locally too, so the UI can show it offline
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('luma_star_plan', plan.id);

      if (!mounted) return;
      setState(() {
        _isPurchasing = false;
        _isStarActive = true;
      });
      _showSuccess(plan.label);
    } catch (e) {
      if (!mounted) return;
      setState(() => _isPurchasing = false);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Purchase failed: $e'),
          behavior: SnackBarBehavior.floating,
        ),
      );
    }
  }

  void _showSuccess(String planLabel) {
    final theme = Theme.of(context);
    showDialog(
      context: context,
      builder: (ctx) => Dialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
        backgroundColor: theme.brightness == Brightness.dark
            ? const Color(0xFF1F2C34)
            : Colors.white,
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                padding: const EdgeInsets.all(18),
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  gradient: const LinearGradient(
                    colors: [_goldSoft, _gold],
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                  ),
                  boxShadow: [
                    BoxShadow(
                      color: _gold.withOpacity(0.5),
                      blurRadius: 24,
                      spreadRadius: 2,
                    ),
                  ],
                ),
                child: const Icon(Icons.auto_awesome,
                    color: Colors.white, size: 34),
              ),
              const SizedBox(height: 18),
              const Text(
                'Welcome to Luma Star ✨',
                style:
                    TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
              ),
              const SizedBox(height: 8),
              Text(
                'Your $planLabel plan is active. Enjoy exclusive perks — gold badges, priority visibility, and animated profile rings.',
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: 13,
                  color: theme.colorScheme.onSurface.withOpacity(0.65),
                  height: 1.4,
                ),
              ),
              const SizedBox(height: 22),
              SizedBox(
                width: double.infinity,
                child: ElevatedButton(
                  onPressed: () => Navigator.pop(ctx),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: _gold,
                    foregroundColor: Colors.white,
                    padding: const EdgeInsets.symmetric(vertical: 14),
                    shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12)),
                  ),
                  child: const Text('Let\'s go',
                      style: TextStyle(fontWeight: FontWeight.w600)),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    final plans = _plans();
    final bgColor = isDark ? const Color(0xFF0E1519) : const Color(0xFFF5F7FA);

    return Scaffold(
      backgroundColor: bgColor,
      body: Stack(
        children: [
          // ── Ambient gold glow in the background (iOS glass depth) ──
          Positioned(
            top: -120,
            right: -80,
            child: _glowOrb(_gold.withOpacity(0.35), 260),
          ),
          Positioned(
            bottom: -140,
            left: -100,
            child: _glowOrb(_goldSoft.withOpacity(0.18), 300),
          ),

          SafeArea(
            bottom: false,
            child: Column(
              children: [
                // ── AppBar (glass) ──
                Padding(
                  padding: const EdgeInsets.fromLTRB(8, 8, 8, 0),
                  child: Row(
                    children: [
                      IconButton(
                        icon: const Icon(Icons.close),
                        onPressed: () => Navigator.pop(context),
                      ),
                      const Expanded(
                        child: Text(
                          'Luma Star',
                          style: TextStyle(
                              fontSize: 17, fontWeight: FontWeight.w600),
                        ),
                      ),
                      const SizedBox(width: 48),
                    ],
                  ),
                ),

                Expanded(
                  child: ListView(
                    padding: const EdgeInsets.fromLTRB(20, 8, 20, 160),
                    children: [
                      // ── Hero ──
                      const SizedBox(height: 12),
                      Center(
                        child: _heroStar(),
                      ),
                      const SizedBox(height: 24),
                      const Center(
                        child: Text(
                          'Luma Star',
                          style: TextStyle(
                            fontSize: 30,
                            fontWeight: FontWeight.w800,
                            letterSpacing: -0.5,
                          ),
                        ),
                      ),
                      const SizedBox(height: 8),
                      Center(
                        child: Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 12),
                          child: Text(
                            'A quiet upgrade that makes you stand out — '
                            'gold badges, priority visibility, and exclusive effects.',
                            textAlign: TextAlign.center,
                            style: TextStyle(
                              fontSize: 14,
                              height: 1.5,
                              color: theme.colorScheme.onSurface
                                  .withOpacity(0.6),
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(height: 32),

                      // ── Perks (glass cards) ──
                      _sectionLabel(theme, 'WHAT YOU GET'),
                      const SizedBox(height: 10),
                      _perkCard(
                        theme,
                        icon: Icons.workspace_premium,
                        title: 'Gold Star Badge',
                        desc:
                            'A shimmering star beside your name in chats and groups.',
                      ),
                      _perkCard(
                        theme,
                        icon: Icons.trending_up,
                        title: 'Priority Visibility',
                        desc:
                            'Your profile appears higher in discovery and searches.',
                      ),
                      _perkCard(
                        theme,
                        icon: Icons.auto_awesome,
                        title: 'Animated Profile Ring',
                        desc:
                            'A soft, animated gold ring around your avatar everywhere.',
                      ),
                      _perkCard(
                        theme,
                        icon: Icons.hd,
                        title: 'HD Media Uploads',
                        desc:
                            'Send full-resolution photos and videos without compression.',
                      ),
                      _perkCard(
                        theme,
                        icon: Icons.bolt,
                        title: 'Early Access',
                        desc:
                            'Be the first to try new Luma features before public rollout.',
                      ),
                      _perkCard(
                        theme,
                        icon: Icons.support_agent,
                        title: 'Priority Support',
                        desc:
                            'Get faster responses from the Luma support team.',
                      ),

                      const SizedBox(height: 28),

                      // ── Plans ──
                      _sectionLabel(theme, 'CHOOSE YOUR PLAN'),
                      const SizedBox(height: 12),
                      ...List.generate(plans.length, (i) {
                        return _planTile(
                          theme,
                          plan: plans[i],
                          selected: _selectedPlan == i,
                          onTap: () => setState(() => _selectedPlan = i),
                        );
                      }),

                      const SizedBox(height: 16),

                      // ── Fine print ──
                      Text(
                        'Subscriptions renew automatically unless cancelled at least 24 hours '
                        'before the end of the current period. You can manage or cancel '
                        'anytime in your device settings.',
                        textAlign: TextAlign.center,
                        style: TextStyle(
                          fontSize: 11.5,
                          height: 1.5,
                          color: theme.colorScheme.onSurface
                              .withOpacity(0.45),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ],
      ),

      // ── Sticky bottom purchase bar (glass) ──
      bottomNavigationBar: SafeArea(
        child: Container(
          padding: const EdgeInsets.fromLTRB(20, 12, 20, 16),
          decoration: BoxDecoration(
            color: (isDark ? const Color(0xFF141C21) : Colors.white)
                .withOpacity(0.85),
            border: Border(
              top: BorderSide(color: theme.dividerColor.withOpacity(0.3)),
            ),
          ),
          child: ClipRRect(
            child: BackdropFilter(
              filter: ImageFilter.blur(sigmaX: 18, sigmaY: 18),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              _isStarActive
                                  ? 'Luma Star is active'
                                  : plans[_selectedPlan].price,
                              style: const TextStyle(
                                fontSize: 22,
                                fontWeight: FontWeight.w800,
                                letterSpacing: -0.4,
                              ),
                            ),
                            Text(
                              _isStarActive
                                  ? 'Manage your subscription'
                                  : 'Billed ${plans[_selectedPlan].per}',
                              style: TextStyle(
                                fontSize: 12,
                                color: theme.colorScheme.onSurface
                                    .withOpacity(0.55),
                              ),
                            ),
                          ],
                        ),
                      ),
                      if (_isStarActive)
                        Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 10, vertical: 6),
                          decoration: BoxDecoration(
                            color: _gold.withOpacity(0.15),
                            borderRadius: BorderRadius.circular(10),
                            border: Border.all(
                                color: _gold.withOpacity(0.45)),
                          ),
                          child: const Row(
                            children: [
                              Icon(Icons.check_circle,
                                  color: _gold, size: 16),
                              SizedBox(width: 6),
                              Text(
                                'ACTIVE',
                                style: TextStyle(
                                  color: _gold,
                                  fontSize: 11,
                                  fontWeight: FontWeight.w700,
                                  letterSpacing: 0.6,
                                ),
                              ),
                            ],
                          ),
                        ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  SizedBox(
                    width: double.infinity,
                    height: 52,
                    child: ElevatedButton(
                      onPressed: _isPurchasing || _isStarActive
                          ? (_isStarActive ? _managePlan : null)
                          : _purchase,
                      style: ElevatedButton.styleFrom(
                        backgroundColor: _gold,
                        foregroundColor: Colors.white,
                        disabledBackgroundColor:
                            _gold.withOpacity(0.4),
                        elevation: 0,
                        shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(14)),
                      ),
                      child: _isPurchasing
                          ? const SizedBox(
                              width: 22,
                              height: 22,
                              child: CircularProgressIndicator(
                                strokeWidth: 2.2,
                                color: Colors.white,
                              ),
                            )
                          : Text(
                              _isStarActive
                                  ? 'Manage Subscription'
                                  : 'Get Luma Star',
                              style: const TextStyle(
                                fontSize: 16,
                                fontWeight: FontWeight.w700,
                                letterSpacing: 0.2,
                              ),
                            ),
                    ),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    'Payment will be charged to your store account at confirmation.',
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      fontSize: 10.5,
                      color:
                          theme.colorScheme.onSurface.withOpacity(0.4),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  void _managePlan() {
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (_) => _manageSheet(),
    );
  }

  Widget _manageSheet() {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    return Container(
      decoration: BoxDecoration(
        color: isDark ? const Color(0xFF1A2228) : Colors.white,
        borderRadius:
            const BorderRadius.vertical(top: Radius.circular(24)),
      ),
      padding: const EdgeInsets.fromLTRB(20, 12, 20, 24),
      child: SafeArea(
        top: false,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 40,
              height: 4,
              margin: const EdgeInsets.only(bottom: 20),
              decoration: BoxDecoration(
                color: theme.dividerColor,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
            const Text(
              'Manage Subscription',
              style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 16),
            ListTile(
              leading: const Icon(Icons.open_in_new),
              title: const Text('Open store subscriptions'),
              trailing: const Icon(Icons.chevron_right, size: 20),
              onTap: () => Navigator.pop(context),
            ),
            ListTile(
              leading: const Icon(Icons.cancel_outlined,
                  color: Colors.red),
              title: const Text(
                'Cancel Luma Star',
                style: TextStyle(color: Colors.red),
              ),
              onTap: () async {
                Navigator.pop(context);
                final auth = Provider.of<LumaAuthProvider>(
                    context,
                    listen: false);
                final uid = auth.user?.uid ?? auth.mockUserId;
                if (uid != null) {
                  await FirebaseFirestore.instance
                      .collection('users')
                      .doc(uid)
                      .set({
                    'luma_star_active': false,
                    'updated_at': FieldValue.serverTimestamp(),
                  }, SetOptions(merge: true));
                }
                if (!mounted) return;
                setState(() => _isStarActive = false);
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(
                    content: Text('Luma Star cancelled'),
                    behavior: SnackBarBehavior.floating,
                  ),
                );
              },
            ),
          ],
        ),
      ),
    );
  }

  // ─────────────────────────────────────────────────────────────
  // Small building blocks
  // ─────────────────────────────────────────────────────────────

  Widget _heroStar() {
    return SizedBox(
      width: 120,
      height: 120,
      child: Stack(
        alignment: Alignment.center,
        children: [
          // outer glow ring
          Container(
            width: 120,
            height: 120,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              gradient: RadialGradient(
                colors: [
                  _gold.withOpacity(0.35),
                  _gold.withOpacity(0),
                ],
              ),
            ),
          ),
          // inner glass disc
          ClipOval(
            child: BackdropFilter(
              filter: ImageFilter.blur(sigmaX: 14, sigmaY: 14),
              child: Container(
                width: 92,
                height: 92,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  gradient: LinearGradient(
                    colors: [
                      _goldSoft.withOpacity(0.35),
                      _gold.withOpacity(0.2),
                    ],
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                  ),
                  border: Border.all(
                      color: _gold.withOpacity(0.45), width: 1),
                ),
                child: const Icon(Icons.auto_awesome,
                    color: _gold, size: 46),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _glowOrb(Color color, double size) {
    return IgnorePointer(
      child: Container(
        width: size,
        height: size,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          gradient: RadialGradient(
            colors: [color, color.withOpacity(0)],
          ),
        ),
      ),
    );
  }

  Widget _sectionLabel(ThemeData theme, String label) {
    return Text(
      label,
      style: TextStyle(
        fontSize: 11.5,
        fontWeight: FontWeight.w700,
        letterSpacing: 1.2,
        color: theme.colorScheme.onSurface.withOpacity(0.5),
      ),
    );
  }

  Widget _perkCard(
    ThemeData theme, {
    required IconData icon,
    required String title,
    required String desc,
  }) {
    final isDark = theme.brightness == Brightness.dark;
    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      decoration: BoxDecoration(
        color: isDark
            ? Colors.white.withOpacity(0.04)
            : Colors.white.withOpacity(0.7),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
            color: theme.dividerColor.withOpacity(0.25)),
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(16),
        child: BackdropFilter(
          filter: ImageFilter.blur(sigmaX: 10, sigmaY: 10),
          child: Padding(
            padding: const EdgeInsets.all(14),
            child: Row(
              children: [
                Container(
                  padding: const EdgeInsets.all(10),
                  decoration: BoxDecoration(
                    color: _gold.withOpacity(0.12),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Icon(icon, color: _gold, size: 20),
                ),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        title,
                        style: const TextStyle(
                          fontSize: 14.5,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        desc,
                        style: TextStyle(
                          fontSize: 12.5,
                          height: 1.4,
                          color: theme.colorScheme.onSurface
                              .withOpacity(0.55),
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
    );
  }

  Widget _planTile(
    ThemeData theme, {
    required _StarPlan plan,
    required bool selected,
    required VoidCallback onTap,
  }) {
    final isDark = theme.brightness == Brightness.dark;
    return GestureDetector(
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 180),
        margin: const EdgeInsets.only(bottom: 10),
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: selected
              ? _gold.withOpacity(isDark ? 0.12 : 0.09)
              : (isDark
                  ? Colors.white.withOpacity(0.03)
                  : Colors.white.withOpacity(0.65)),
          borderRadius: BorderRadius.circular(16),
          border: Border.all(
            color: selected
                ? _gold.withOpacity(0.7)
                : theme.dividerColor.withOpacity(0.25),
            width: selected ? 1.5 : 1,
          ),
          boxShadow: selected
              ? [
                  BoxShadow(
                    color: _gold.withOpacity(0.15),
                    blurRadius: 16,
                    offset: const Offset(0, 4),
                  ),
                ]
              : null,
        ),
        child: Row(
          children: [
            Container(
              width: 22,
              height: 22,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                border: Border.all(
                  color: selected
                      ? _gold
                      : theme.colorScheme.onSurface.withOpacity(0.25),
                  width: 2,
                ),
              ),
              child: selected
                  ? Center(
                      child: Container(
                        width: 10,
                        height: 10,
                        decoration: const BoxDecoration(
                          color: _gold,
                          shape: BoxShape.circle,
                        ),
                      ),
                    )
                  : null,
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Text(
                        plan.label,
                        style: const TextStyle(
                          fontSize: 15,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      if (plan.badge != null) ...[
                        const SizedBox(width: 8),
                        Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 6, vertical: 2),
                          decoration: BoxDecoration(
                            color: _gold.withOpacity(0.15),
                            borderRadius: BorderRadius.circular(6),
                          ),
                          child: Text(
                            plan.badge!,
                            style: const TextStyle(
                              fontSize: 9,
                              fontWeight: FontWeight.w800,
                              letterSpacing: 0.5,
                              color: _gold,
                            ),
                          ),
                        ),
                      ],
                    ],
                  ),
                  const SizedBox(height: 2),
                  Text(
                    plan.sub,
                    style: TextStyle(
                      fontSize: 12,
                      color: theme.colorScheme.onSurface
                          .withOpacity(0.5),
                    ),
                  ),
                ],
              ),
            ),
            Column(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Text(
                  plan.price,
                  style: const TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.w700,
                    letterSpacing: -0.2,
                  ),
                ),
                Text(
                  plan.per,
                  style: TextStyle(
                    fontSize: 11,
                    color:
                        theme.colorScheme.onSurface.withOpacity(0.5),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _StarPlan {
  final String id;
  final String label;
  final String price;
  final String per;
  final String sub;
  final String? badge;

  _StarPlan({
    required this.id,
    required this.label,
    required this.price,
    required this.per,
    required this.sub,
    this.badge,
  });
}
