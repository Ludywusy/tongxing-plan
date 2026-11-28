import 'package:flutter/material.dart';

import 'online_room.dart';
import 'room_time.dart';
import 'transport_codes.dart';
import 'trip_session.dart';

const _ink = Color(0xFF252D2B);
const _inkSoft = Color(0xFF3E6B60);
const _lime = Color(0xFFD9F17B);
const _coral = Color(0xFFE87D65);
const _paper = Color(0xFFF5F6F3);
const _muted = Color(0xFF77827B);
const _line = Color(0xFFE4E8DE);

void main() => runApp(const TongxingApp());

class TongxingApp extends StatelessWidget {
  const TongxingApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: '同行计划',
      theme: ThemeData(
        useMaterial3: true,
        scaffoldBackgroundColor: _paper,
        colorScheme: ColorScheme.fromSeed(
          seedColor: _ink,
          primary: _ink,
          secondary: _lime,
          surface: Colors.white,
          error: _coral,
        ),
        appBarTheme: const AppBarTheme(
          backgroundColor: _paper,
          foregroundColor: _ink,
          surfaceTintColor: Colors.transparent,
          elevation: 0,
        ),
        dividerColor: _line,
        snackBarTheme: SnackBarThemeData(
          backgroundColor: _ink,
          contentTextStyle: const TextStyle(color: Colors.white),
          behavior: SnackBarBehavior.floating,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
          ),
        ),
      ),
      home: const AppLoader(),
    );
  }
}

class AppLoader extends StatefulWidget {
  const AppLoader({super.key});

  @override
  State<AppLoader> createState() => _AppLoaderState();
}

class _AppLoaderState extends State<AppLoader> {
  late final Future<TripSession> _session = TripSession.fromAsset();

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<TripSession>(
      future: _session,
      builder: (context, snapshot) {
        if (snapshot.hasError) {
          return Scaffold(
            body: Center(
              child: Padding(
                padding: const EdgeInsets.all(28),
                child: Text('离线样例载入失败：${snapshot.error}'),
              ),
            ),
          );
        }
        if (!snapshot.hasData) {
          return const Scaffold(
            body: Center(child: CircularProgressIndicator(color: _ink)),
          );
        }
        return HomeScreen(session: snapshot.data!);
      },
    );
  }
}

class HomeScreen extends StatefulWidget {
  const HomeScreen({required this.session, super.key});

  final TripSession session;

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  bool _offline = false;
  int _tab = 0;

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: widget.session,
      builder: (context, _) {
        if (!_offline) {
          return LandingPage(
            onOffline: () => setState(() {
              _offline = true;
              _tab = 0;
            }),
            onOnline: () => Navigator.of(context).push(
              MaterialPageRoute<void>(builder: (_) => const OnlineRoomPage()),
            ),
          );
        }
        return OfflineShell(
          session: widget.session,
          selectedTab: _tab,
          onTabChanged: (value) => setState(() => _tab = value),
          onExit: () => setState(() => _offline = false),
        );
      },
    );
  }
}

class LandingPage extends StatelessWidget {
  const LandingPage({
    required this.onOffline,
    required this.onOnline,
    super.key,
  });

  final VoidCallback onOffline;
  final VoidCallback onOnline;

  @override
  Widget build(BuildContext context) {
    final width = MediaQuery.sizeOf(context).width;
    return Scaffold(
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 760),
            child: ListView(
              padding: const EdgeInsets.only(bottom: 24),
              children: [
                _TripIllustration(),
                Padding(
                  padding: EdgeInsets.fromLTRB(
                    width < 400 ? 20 : 28,
                    20,
                    width < 400 ? 20 : 28,
                    0,
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      ModeOption(
                        icon: Icons.group_add_outlined,
                        title: '和朋友一起计划',
                        detail: '创建房间或输入邀请码',
                        badge: '联机',
                        enabled: true,
                        onTap: onOnline,
                      ),
                      const SizedBox(height: 12),
                      ModeOption(
                        icon: Icons.explore_outlined,
                        title: '离线体验完整流程',
                        detail: '一台设备 · 四个模拟身份 · 样例 1.2',
                        badge: '无需网络',
                        enabled: true,
                        onTap: onOffline,
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
}

class _TripIllustration extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return Container(
      height: MediaQuery.sizeOf(context).width < 600 ? 252 : 305,
      width: double.infinity,
      clipBehavior: Clip.antiAlias,
      decoration: const BoxDecoration(color: Color(0xFF104439)),
      child: Stack(
        children: [
          Positioned.fill(
            child: Image.asset(
              'assets/lanzhou-weekend.png',
              fit: BoxFit.cover,
              alignment: const Alignment(.43, 0),
            ),
          ),
          Positioned(
            left: 20,
            top: 19,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 7),
              decoration: BoxDecoration(
                color: Colors.white.withValues(alpha: .92),
                borderRadius: BorderRadius.circular(20),
              ),
              child: const Row(
                children: [
                  Icon(Icons.place_outlined, color: _ink, size: 15),
                  SizedBox(width: 5),
                  Text(
                    '兰州 · 城关',
                    style: TextStyle(
                      fontSize: 12,
                      color: _ink,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ],
              ),
            ),
          ),
          const Positioned(
            left: 22,
            right: 22,
            bottom: 24,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '同行计划',
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: 44,
                    height: 1.12,
                    fontWeight: FontWeight.w800,
                    shadows: [Shadow(color: Color(0xDD082C24), blurRadius: 14)],
                  ),
                ),
                SizedBox(height: 8),
                Text(
                  '把周末，交给一起出发的人。',
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: 15,
                    fontWeight: FontWeight.w600,
                    shadows: [Shadow(color: Color(0xEE082C24), blurRadius: 8)],
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

class BrandMark extends StatelessWidget {
  const BrandMark({this.size = 36, super.key});

  final double size;

  @override
  Widget build(BuildContext context) => Container(
    width: size,
    height: size,
    decoration: BoxDecoration(
      color: _lime,
      borderRadius: BorderRadius.circular(12),
    ),
    child: Icon(Icons.route_rounded, color: _ink, size: size * .58),
  );
}

class ModeOption extends StatelessWidget {
  const ModeOption({
    required this.icon,
    required this.title,
    required this.detail,
    required this.badge,
    required this.enabled,
    required this.onTap,
    super.key,
  });

  final IconData icon;
  final String title;
  final String detail;
  final String badge;
  final bool enabled;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: enabled ? _ink : Colors.white,
      borderRadius: BorderRadius.circular(8),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(8),
        child: Container(
          constraints: const BoxConstraints(minHeight: 84),
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: enabled ? _ink : _line),
          ),
          child: Row(
            children: [
              Container(
                width: 44,
                height: 44,
                decoration: BoxDecoration(
                  color: enabled ? _lime : _paper,
                  borderRadius: BorderRadius.circular(13),
                ),
                child: Icon(icon, color: _ink, size: 22),
              ),
              const SizedBox(width: 13),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      title,
                      style: TextStyle(
                        color: enabled ? Colors.white : _ink,
                        fontSize: 15,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      detail,
                      style: TextStyle(
                        color: enabled ? Colors.white70 : _muted,
                        fontSize: 12,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 6),
              Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  Text(
                    badge,
                    style: TextStyle(
                      color: enabled ? _lime : _inkSoft,
                      fontSize: 11,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const SizedBox(height: 5),
                  Icon(
                    enabled ? Icons.arrow_forward_rounded : Icons.lock_outline,
                    color: enabled ? Colors.white : _muted,
                    size: 18,
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class OfflineShell extends StatelessWidget {
  const OfflineShell({
    required this.session,
    required this.selectedTab,
    required this.onTabChanged,
    required this.onExit,
    super.key,
  });

  final TripSession session;
  final int selectedTab;
  final ValueChanged<int> onTabChanged;
  final VoidCallback onExit;

  @override
  Widget build(BuildContext context) {
    final pages = [
      GroupPage(session: session, onOpenTab: onTabChanged),
      PreferencesPage(session: session),
      CandidatePage(session: session, onOpenTab: onTabChanged),
      ChangesPage(session: session),
    ];
    final member = session.activeMember;
    final name = member['display_name'] as String;
    return Scaffold(
      appBar: AppBar(
        titleSpacing: 18,
        title: Row(
          children: [
            const BrandMark(size: 34),
            const SizedBox(width: 10),
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: const [
                Text(
                  '同行计划',
                  style: TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.w800,
                    height: 1.15,
                  ),
                ),
                Text(
                  '离线 · 1.2 · 模拟',
                  style: TextStyle(
                    fontSize: 10,
                    color: _muted,
                    fontWeight: FontWeight.w500,
                  ),
                ),
              ],
            ),
          ],
        ),
        actions: [
          PopupMenuButton<String>(
            tooltip: '切换模拟成员',
            initialValue: session.activeMemberId,
            onSelected: session.setActiveMember,
            itemBuilder: (context) => session.members.map((person) {
              final id = person['member_id'] as String;
              return PopupMenuItem(
                value: id,
                child: Row(
                  children: [
                    Avatar(
                      name: person['display_name'] as String,
                      color: avatarColor(id),
                      size: 30,
                    ),
                    const SizedBox(width: 9),
                    Text(
                      '${person['display_name']} · ${id == 'm01' ? '发起人' : '成员'}',
                    ),
                    const Spacer(),
                    if (id == session.activeMemberId)
                      const Icon(Icons.check, size: 18, color: _ink),
                  ],
                ),
              );
            }).toList(),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12),
              child: Row(
                children: [
                  Avatar(
                    name: name,
                    color: avatarColor(session.activeMemberId),
                    size: 30,
                  ),
                  const SizedBox(width: 7),
                  Text(
                    name,
                    style: const TextStyle(
                      fontSize: 13,
                      color: _ink,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const Icon(Icons.expand_more, size: 18, color: _inkSoft),
                ],
              ),
            ),
          ),
          IconButton(
            tooltip: '返回首页',
            onPressed: onExit,
            icon: const Icon(Icons.close_rounded, size: 20),
          ),
          const SizedBox(width: 4),
        ],
      ),
      body: SafeArea(
        child: IndexedStack(index: selectedTab, children: pages),
      ),
      bottomNavigationBar: NavigationBar(
        selectedIndex: selectedTab,
        onDestinationSelected: onTabChanged,
        backgroundColor: Colors.white,
        indicatorColor: _lime,
        height: 68,
        destinations: const [
          NavigationDestination(
            icon: Icon(Icons.group_outlined),
            selectedIcon: Icon(Icons.group),
            label: '群组',
          ),
          NavigationDestination(
            icon: Icon(Icons.tune_outlined),
            selectedIcon: Icon(Icons.tune),
            label: '偏好',
          ),
          NavigationDestination(
            icon: Icon(Icons.map_outlined),
            selectedIcon: Icon(Icons.map),
            label: '候选',
          ),
          NavigationDestination(
            icon: Icon(Icons.cloud_outlined),
            selectedIcon: Icon(Icons.cloud),
            label: '变更',
          ),
        ],
      ),
    );
  }
}

class GroupPage extends StatelessWidget {
  const GroupPage({required this.session, required this.onOpenTab, super.key});

  final TripSession session;
  final ValueChanged<int> onOpenTab;

  @override
  Widget build(BuildContext context) {
    final submitted = session.submittedMembers.length;
    return _PageFrame(
      children: [
        const _Eyebrow(
          label: '周六 · 11 月 21 日',
          icon: Icons.calendar_today_outlined,
        ),
        const SizedBox(height: 11),
        const Text('兰州半日游', style: _pageTitle),
        const SizedBox(height: 7),
        const Text('兰州大学城关校区出发 · 4 位同行者', style: _bodyMuted),
        const SizedBox(height: 22),
        TripSummaryCard(),
        const SizedBox(height: 24),
        Row(
          children: [
            const Text('同行成员', style: _sectionTitle),
            const Spacer(),
            Text(
              '$submitted / 4 已提交',
              style: const TextStyle(
                color: _inkSoft,
                fontSize: 12,
                fontWeight: FontWeight.w700,
              ),
            ),
          ],
        ),
        const SizedBox(height: 11),
        ...session.members.map((member) {
          final id = member['member_id'] as String;
          final current = session.activeMemberId == id;
          final sent = session.submittedMembers.contains(id);
          return Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Material(
              color: Colors.white,
              borderRadius: BorderRadius.circular(8),
              child: InkWell(
                onTap: () => session.setActiveMember(id),
                borderRadius: BorderRadius.circular(8),
                child: Container(
                  padding: const EdgeInsets.all(13),
                  decoration: BoxDecoration(
                    border: Border.all(
                      color: current ? _inkSoft : _line,
                      width: current ? 1.4 : 1,
                    ),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Row(
                    children: [
                      Avatar(
                        name: member['display_name'] as String,
                        color: avatarColor(id),
                      ),
                      const SizedBox(width: 11),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              '${member['display_name']}  ${id == 'm01' ? '发起人' : ''}',
                              style: const TextStyle(
                                color: _ink,
                                fontWeight: FontWeight.w700,
                                fontSize: 14,
                              ),
                            ),
                            const SizedBox(height: 3),
                            Text(
                              _preferenceSummary(session, id),
                              style: const TextStyle(
                                color: _muted,
                                fontSize: 11,
                              ),
                            ),
                          ],
                        ),
                      ),
                      Icon(
                        sent ? Icons.check_circle : Icons.circle_outlined,
                        size: 18,
                        color: sent ? _inkSoft : const Color(0xFFC8CDC6),
                      ),
                      const SizedBox(width: 5),
                      Text(
                        sent ? '已提交' : '待提交',
                        style: TextStyle(
                          color: sent ? _inkSoft : _muted,
                          fontSize: 11,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          );
        }),
        const SizedBox(height: 13),
        PrimaryButton(
          label: session.submittedMembers.contains(session.activeMemberId)
              ? '修改我的偏好'
              : '填写我的偏好',
          icon: Icons.tune_rounded,
          onPressed: () => onOpenTab(1),
        ),
        const SizedBox(height: 23),
        SectionHeading(
          title: '今天的计划',
          action: '查看候选',
          onAction: () => onOpenTab(2),
        ),
        const SizedBox(height: 11),
        const Row(
          children: [
            _PlanMetric(
              value: '13:30',
              label: '集合出发',
              icon: Icons.near_me_outlined,
            ),
            SizedBox(width: 9),
            _PlanMetric(
              value: '3 条',
              label: '路线候选',
              icon: Icons.alt_route_rounded,
            ),
            SizedBox(width: 9),
            _PlanMetric(
              value: '¥64 起',
              label: '人均预算',
              icon: Icons.payments_outlined,
            ),
          ],
        ),
      ],
    );
  }
}

class TripSummaryCard extends StatelessWidget {
  const TripSummaryCard({super.key});

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.all(18),
    decoration: BoxDecoration(
      color: _ink,
      borderRadius: BorderRadius.circular(8),
    ),
    child: Row(
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: const [
              Text(
                '周末，一起去看看',
                style: TextStyle(
                  color: Colors.white,
                  fontSize: 16,
                  fontWeight: FontWeight.w700,
                ),
              ),
              SizedBox(height: 8),
              Row(
                children: [
                  Icon(Icons.location_on_outlined, size: 15, color: _lime),
                  SizedBox(width: 4),
                  Flexible(
                    child: Text(
                      '兰大城关校区 · 集合点',
                      style: TextStyle(color: Colors.white70, fontSize: 12),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
        const SizedBox(width: 12),
        SizedBox(
          width: 74,
          height: 74,
          child: CustomPaint(painter: _CompassPainter()),
        ),
      ],
    ),
  );
}

class _CompassPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2);
    final ring = Paint()
      ..color = Colors.white.withValues(alpha: .12)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1;
    canvas.drawCircle(center, 32, ring);
    canvas.drawCircle(center, 23, ring);
    final accent = Paint()..color = _lime;
    final path = Path()
      ..moveTo(center.dx, 10)
      ..lineTo(center.dx + 11, center.dy + 10)
      ..lineTo(center.dx, center.dy + 3)
      ..lineTo(center.dx - 11, center.dy + 10)
      ..close();
    canvas.drawPath(path, accent);
    canvas.drawCircle(center, 3, Paint()..color = Colors.white);
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}

class PreferencesPage extends StatelessWidget {
  const PreferencesPage({required this.session, super.key});

  final TripSession session;

  @override
  Widget build(BuildContext context) {
    final id = session.activeMemberId;
    final member = session.member(id);
    final pref = session.preference(id);
    final submitted = session.submittedMembers.contains(id);
    if (session.phase != TripPhase.collecting) {
      return _PageFrame(
        children: [
          Text('${member['display_name']}，你的偏好', style: _pageTitle),
          const SizedBox(height: 16),
          _InfoBanner(
            icon: Icons.lock_outline,
            title: '偏好已锁定',
            detail: _preferenceSummary(session, id),
          ),
          if (session.isOrganizer && session.phase == TripPhase.confirming) ...[
            const SizedBox(height: 16),
            PrimaryButton(
              label: '退回修改偏好',
              icon: Icons.edit_outlined,
              onPressed: session.reopenPreferences,
            ),
          ],
        ],
      );
    }
    return _PageFrame(
      children: [
        const _Eyebrow(label: '第二步 · 每个人的节奏', icon: Icons.tune_rounded),
        const SizedBox(height: 11),
        Text('${member['display_name']}，你的偏好', style: _pageTitle),
        const SizedBox(height: 7),
        const Text('这些信息只在本机离线体验中使用。', style: _bodyMuted),
        const SizedBox(height: 22),
        FieldSection(
          icon: Icons.schedule_rounded,
          title: '可出行时间',
          subtitle: '包含出发与返程 · 支持跨天 · Asia/Shanghai',
          child: Row(
            children: [
              Expanded(
                child: _DateTimeTile(
                  label: '最早出发',
                  value: pref.startAt,
                  onTap: () => _chooseDateTime(context, session, id, true),
                ),
              ),
              const Padding(
                padding: EdgeInsets.symmetric(horizontal: 9),
                child: Icon(Icons.arrow_forward, size: 17, color: _muted),
              ),
              Expanded(
                child: _DateTimeTile(
                  label: '最晚返程',
                  value: pref.endAt,
                  onTap: () => _chooseDateTime(context, session, id, false),
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 12),
        FieldSection(
          icon: Icons.account_balance_wallet_outlined,
          title: '个人预算上限',
          subtitle: '含往返交通 · 每人',
          trailing: Text(
            '¥${pref.budgetCap ~/ 100}',
            style: const TextStyle(
              color: _ink,
              fontSize: 20,
              fontWeight: FontWeight.w800,
            ),
          ),
          child: Slider(
            value: pref.budgetCap.clamp(3000, 20000).toDouble(),
            min: 3000,
            max: 20000,
            divisions: 34,
            activeColor: _ink,
            inactiveColor: _line,
            label: '¥${pref.budgetCap ~/ 100}',
            onChanged: (value) => session.updateBudget(id, value.round()),
          ),
        ),
        const SizedBox(height: 12),
        FieldSection(
          icon: Icons.directions_transit_outlined,
          title: '可接受的交通',
          subtitle: '至少选择一种',
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Wrap(
                spacing: 8,
                runSpacing: 3,
                children: [
                  _ChoiceChip(
                    label: '地铁',
                    selected: pref.transport.contains('metro'),
                    onTap: () => session.toggleTransport(id, 'metro'),
                  ),
                  _ChoiceChip(
                    label: '步行',
                    selected: pref.transport.contains('walk'),
                    onTap: () => session.toggleTransport(id, 'walk'),
                  ),
                  _ChoiceChip(
                    label: '公交',
                    selected: pref.transport.contains('bus'),
                    onTap: () => session.toggleTransport(id, 'bus'),
                  ),
                  _ChoiceChip(
                    label: '打车',
                    selected: pref.transport.contains('taxi'),
                    onTap: () => session.toggleTransport(id, 'taxi'),
                  ),
                  _ChoiceChip(
                    label: '自行车',
                    selected: pref.transport.contains('bicycle'),
                    onTap: () => session.toggleTransport(id, 'bicycle'),
                  ),
                  _ChoiceChip(
                    label: '其他',
                    selected: pref.transport.contains('other'),
                    onTap: () => session.toggleTransport(id, 'other'),
                  ),
                ],
              ),
              if (pref.transport.contains('other')) ...[
                const SizedBox(height: 8),
                TextFormField(
                  initialValue: pref.customTransport,
                  onChanged: (value) {
                    pref.customTransport = value;
                    session.submittedMembers.remove(id);
                  },
                  decoration: const InputDecoration(
                    labelText: '填写其他交通方式',
                    hintText: '例如：共享电动车',
                    isDense: true,
                  ),
                ),
              ],
            ],
          ),
        ),
        const SizedBox(height: 12),
        FieldSection(
          icon: Icons.favorite_border_rounded,
          title: '想做的事',
          subtitle: '用于比较路线，不作为硬性门槛',
          child: Wrap(
            spacing: 8,
            runSpacing: 3,
            children: [
              for (final entry in const {
                'movie': '看电影',
                'shopping': '逛街',
                'photo': '摄影',
                'outdoor': '户外',
                'exhibition': '展览',
                'museum': '逛博物馆',
                'craft': '手作',
              }.entries)
                _ChoiceChip(
                  label: entry.value,
                  selected: pref.interests.contains(entry.key),
                  onTap: () => session.toggleInterest(id, entry.key),
                ),
            ],
          ),
        ),
        const SizedBox(height: 12),
        FieldSection(
          icon: Icons.do_not_disturb_alt_outlined,
          title: '不想去的地点',
          subtitle: '命中时会拦住对应路线',
          child: Wrap(
            spacing: 8,
            runSpacing: 3,
            children: [
              for (final entry in const {
                'photo_studio': '摄影体验馆',
                'plaza': '户外广场',
                'gallery': '展览馆',
                'workshop': '手作工坊',
                'mall': '商场',
                'yellow_river': '黄河边',
                'museum': '博物馆',
              }.entries)
                _ChoiceChip(
                  label: entry.value,
                  selected: pref.taboos.contains(entry.key),
                  onTap: () => session.toggleTaboo(id, entry.key),
                  danger: true,
                ),
            ],
          ),
        ),
        const SizedBox(height: 17),
        PrimaryButton(
          label: submitted ? '已保存 · 再次提交' : '保存我的偏好',
          icon: Icons.check_rounded,
          onPressed: () {
            if (!pref.endAt.isAfter(pref.startAt)) {
              _notice(context, '最晚返程要晚于最早出发。');
              return;
            }
            if (pref.transport.isEmpty) {
              _notice(context, '请至少选择一种可接受的交通方式。');
              return;
            }
            if (pref.transport.contains('other') &&
                pref.customTransport.trim().isEmpty) {
              _notice(context, '请填写“其他”交通方式。');
              return;
            }
            session.submitPreferences();
            _notice(context, '${member['display_name']}的偏好已保存在本机。');
          },
        ),
        const SizedBox(height: 13),
        Center(
          child: Text(
            '预算口径：个人承担 · 包含往返交通',
            style: const TextStyle(color: _muted, fontSize: 11),
          ),
        ),
      ],
    );
  }

  Future<void> _chooseDateTime(
    BuildContext context,
    TripSession session,
    String id,
    bool start,
  ) async {
    final pref = session.preference(id);
    final initial = RoomTime.toWallTime(start ? pref.startAt : pref.endAt);
    final date = await showDatePicker(
      context: context,
      initialDate: DateTime(initial.year, initial.month, initial.day),
      firstDate: DateTime(2026, 1, 1),
      lastDate: DateTime(2035, 12, 31),
      helpText: start ? '选择最早出发日期' : '选择最晚返程日期',
    );
    if (date == null) return;
    if (!context.mounted) return;
    final chosen = await showTimePicker(
      context: context,
      initialTime: TimeOfDay(hour: initial.hour, minute: initial.minute),
      helpText: start ? '选择最早出发时间' : '选择最晚返程时间',
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(context).copyWith(alwaysUse24HourFormat: true),
        child: child!,
      ),
    );
    if (chosen == null) return;
    final value = RoomTime.fromWallTime(
      DateTime.utc(date.year, date.month, date.day, chosen.hour, chosen.minute),
    );
    session.updateWindow(
      id,
      startAt: start ? value : null,
      endAt: start ? null : value,
    );
  }
}

class _DateTimeTile extends StatelessWidget {
  const _DateTimeTile({
    required this.label,
    required this.value,
    required this.onTap,
  });

  final String label;
  final DateTime value;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => Material(
    color: _paper,
    borderRadius: BorderRadius.circular(10),
    child: InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(10),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 10),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(label, style: const TextStyle(color: _muted, fontSize: 10)),
            const SizedBox(height: 4),
            Row(
              children: [
                Expanded(
                  child: Text(
                    _dateTimeLabel(value),
                    style: const TextStyle(
                      color: _ink,
                      fontWeight: FontWeight.w700,
                      fontSize: 16,
                    ),
                  ),
                ),
                const Icon(Icons.edit_outlined, size: 14, color: _muted),
              ],
            ),
          ],
        ),
      ),
    ),
  );
}

class CandidatePage extends StatelessWidget {
  const CandidatePage({
    required this.session,
    required this.onOpenTab,
    super.key,
  });

  final TripSession session;
  final ValueChanged<int> onOpenTab;

  @override
  Widget build(BuildContext context) {
    final allSubmitted = session.allSubmitted;
    final selectedId = session.selectedCandidateId;
    return _PageFrame(
      children: [
        const _Eyebrow(label: '第三步 · 一起挑一条', icon: Icons.alt_route_rounded),
        const SizedBox(height: 11),
        const Text('周末路线提案', style: _pageTitle),
        const SizedBox(height: 7),
        const Text('固定演示数据 · 费用含往返交通', style: _bodyMuted),
        const SizedBox(height: 17),
        _VoteProgress(session: session),
        const SizedBox(height: 13),
        if (!allSubmitted)
          _InfoBanner(
            icon: Icons.people_outline,
            title: '等大家先填好偏好',
            detail: '目前 ${session.submittedMembers.length}/4 人已提交，切换身份完成剩下的资料。',
            action: '去偏好',
            onAction: () => onOpenTab(1),
          ),
        const SizedBox(height: 13),
        ...session.candidates.map((candidate) {
          final id = candidate['candidate_id'] as String;
          final check = session.checkCandidate(candidate);
          final feasible = check.status == CandidateStatus.feasible;
          final selected = selectedId == id;
          final costs = Map<String, dynamic>.from(
            candidate['cost_per_member'] as Map,
          );
          final nodes = (candidate['nodes'] as List).cast<Map>();
          final activities = nodes
              .where((node) => node['kind'] == 'activity')
              .map((node) => _placeName(node['place_tag'] as String))
              .join(' · ');
          final interestHits = session.interestMatches(candidate);
          return Padding(
            padding: const EdgeInsets.only(bottom: 12),
            child: Container(
              clipBehavior: Clip.antiAlias,
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(8),
                border: Border.all(
                  color: selected ? _ink : _line,
                  width: selected ? 1.7 : 1,
                ),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Container(
                    height: 5,
                    color: !feasible
                        ? _coral
                        : id == 'c02'
                        ? _lime
                        : const Color(0xFFB8D6CB),
                  ),
                  Padding(
                    padding: const EdgeInsets.fromLTRB(15, 14, 15, 14),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            Expanded(
                              child: Text(
                                candidate['display_name'] as String,
                                style: const TextStyle(
                                  color: _ink,
                                  fontSize: 16,
                                  fontWeight: FontWeight.w800,
                                ),
                              ),
                            ),
                            _StatusPill(
                              label: feasible ? '可行' : '有冲突',
                              good: feasible,
                            ),
                          ],
                        ),
                        const SizedBox(height: 9),
                        Row(
                          children: [
                            const Icon(Icons.schedule, size: 14, color: _muted),
                            const SizedBox(width: 5),
                            Text(
                              '${_timeFrom(candidate, 'start')}–${_timeFrom(candidate, 'end')}',
                              style: const TextStyle(
                                color: _inkSoft,
                                fontSize: 12,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                            const SizedBox(width: 11),
                            const Icon(
                              Icons.directions_transit_outlined,
                              size: 14,
                              color: _muted,
                            ),
                            const SizedBox(width: 4),
                            Text(
                              _candidateTransports(candidate),
                              style: const TextStyle(
                                color: _muted,
                                fontSize: 12,
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 7),
                        Text(
                          activities,
                          style: const TextStyle(color: _muted, fontSize: 12),
                        ),
                        const SizedBox(height: 7),
                        Wrap(
                          spacing: 5,
                          runSpacing: 4,
                          children: [
                            const Icon(
                              Icons.auto_awesome_outlined,
                              size: 14,
                              color: Color(0xFFAD7143),
                            ),
                            Text(
                              interestHits.isEmpty
                                  ? '偏好匹配待大家提交'
                                  : '偏好命中 · ${interestHits.join('、')}',
                              style: const TextStyle(
                                color: Color(0xFF966039),
                                fontSize: 11,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 6),
                        Text(
                          '来源：固定模拟数据 · 更新于 ${(Map<String, dynamic>.from(candidate['source'] as Map)['retrieved_at'] as String).substring(5, 10).replaceAll('-', '/')}',
                          style: const TextStyle(color: _muted, fontSize: 10),
                        ),
                        const SizedBox(height: 11),
                        Wrap(
                          spacing: 7,
                          runSpacing: 5,
                          children: [
                            for (final member in session.members)
                              _CostLabel(
                                name: member['display_name'] as String,
                                cost: costs[member['member_id']] as int,
                              ),
                          ],
                        ),
                        if (!feasible) ...[
                          const SizedBox(height: 11),
                          Container(
                            width: double.infinity,
                            padding: const EdgeInsets.all(10),
                            decoration: BoxDecoration(
                              color: const Color(0xFFFFF2ED),
                              borderRadius: BorderRadius.circular(9),
                            ),
                            child: Row(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                const Icon(
                                  Icons.info_outline,
                                  color: Color(0xFFB64F3D),
                                  size: 16,
                                ),
                                const SizedBox(width: 7),
                                Expanded(
                                  child: Text(
                                    allSubmitted
                                        ? '${check.ruleId ?? ''} · ${check.message}'
                                        : '完成全部成员偏好后会校验这条路线。',
                                    style: const TextStyle(
                                      color: Color(0xFF914331),
                                      fontSize: 12,
                                      height: 1.4,
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ],
                        if (feasible) ...[
                          const SizedBox(height: 12),
                          Row(
                            children: [
                              ...session.members.map((member) {
                                final memberId = member['member_id'] as String;
                                final voted = session.votes[memberId] == id;
                                return Padding(
                                  padding: const EdgeInsets.only(right: 5),
                                  child: Tooltip(
                                    message:
                                        '${member['display_name']}${voted ? '已投票' : '未投票'}',
                                    child: Avatar(
                                      name: member['display_name'] as String,
                                      color: voted
                                          ? avatarColor(memberId)
                                          : const Color(0xFFE6E9E2),
                                      size: 26,
                                    ),
                                  ),
                                );
                              }),
                              const SizedBox(width: 5),
                              Text(
                                '${session.voteCount(id)} 人倾向',
                                style: const TextStyle(
                                  color: _muted,
                                  fontSize: 11,
                                ),
                              ),
                              const Spacer(),
                              TextButton.icon(
                                onPressed:
                                    !allSubmitted ||
                                        session.phase != TripPhase.collecting
                                    ? null
                                    : () => session.toggleVote(id),
                                icon: Icon(
                                  session.hasVotedFor(id)
                                      ? Icons.favorite
                                      : Icons.favorite_border,
                                  size: 16,
                                ),
                                label: Text(
                                  session.hasVotedFor(id) ? '已投' : '投一票',
                                ),
                                style: TextButton.styleFrom(
                                  foregroundColor: _ink,
                                  visualDensity: VisualDensity.compact,
                                ),
                              ),
                            ],
                          ),
                        ],
                        if (session.phase == TripPhase.confirming &&
                            selected) ...[
                          const Divider(height: 19),
                          Row(
                            children: [
                              const Icon(
                                Icons.verified_outlined,
                                size: 17,
                                color: _inkSoft,
                              ),
                              const SizedBox(width: 7),
                              Text(
                                '同一版本 ${session.currentVersion} · ${session.confirmedMembers.length}/4 已确认',
                                style: const TextStyle(
                                  color: _inkSoft,
                                  fontSize: 12,
                                  fontWeight: FontWeight.w700,
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 9),
                          ...session.members.map((member) {
                            final memberId = member['member_id'] as String;
                            final confirmed = session.confirmedMembers.contains(
                              memberId,
                            );
                            final records = session.confirmationHistory.where(
                              (item) =>
                                  item.memberId == memberId &&
                                  item.version == session.currentVersion,
                            );
                            return Padding(
                              padding: const EdgeInsets.only(bottom: 5),
                              child: Row(
                                children: [
                                  Avatar(
                                    name: member['display_name'] as String,
                                    color: avatarColor(memberId),
                                    size: 23,
                                  ),
                                  const SizedBox(width: 7),
                                  Text(
                                    member['display_name'] as String,
                                    style: const TextStyle(
                                      color: _ink,
                                      fontSize: 12,
                                    ),
                                  ),
                                  const Spacer(),
                                  Text(
                                    confirmed && records.isNotEmpty
                                        ? RoomTime.format(
                                            records.last.confirmedAt,
                                          )
                                        : '待确认',
                                    style: TextStyle(
                                      color: confirmed ? _inkSoft : _muted,
                                      fontSize: 11,
                                      fontWeight: FontWeight.w600,
                                    ),
                                  ),
                                  const SizedBox(width: 4),
                                  Icon(
                                    confirmed
                                        ? Icons.check_circle
                                        : Icons.circle_outlined,
                                    size: 15,
                                    color: confirmed ? _inkSoft : _line,
                                  ),
                                ],
                              ),
                            );
                          }),
                          if (session.confirmedMembers.contains(
                            session.activeMemberId,
                          ))
                            const _InfoBanner(
                              icon: Icons.check_circle_outline,
                              title: '你已确认这个版本',
                              detail: '切换到其他成员继续确认，四人都确认后可开始行程。',
                            ),
                          if (!session.confirmedMembers.contains(
                            session.activeMemberId,
                          ))
                            PrimaryButton(
                              label: '确认 ${session.currentVersion}',
                              icon: Icons.check_rounded,
                              onPressed: () => session.confirmSelection(),
                            ),
                          if (session.allConfirmed && session.isOrganizer) ...[
                            const SizedBox(height: 8),
                            PrimaryButton(
                              label: '四人已确认 · 开始行程',
                              icon: Icons.play_arrow_rounded,
                              onPressed: () {
                                session.startTrip();
                                onOpenTab(3);
                              },
                            ),
                          ],
                        ] else if (allSubmitted &&
                            session.isOrganizer &&
                            session.phase != TripPhase.executing &&
                            feasible) ...[
                          const SizedBox(height: 11),
                          PrimaryButton(
                            label: selected ? '当前选择' : '选择此路线',
                            icon: selected
                                ? Icons.check_rounded
                                : Icons.arrow_forward_rounded,
                            onPressed: selected
                                ? null
                                : () {
                                    if (session.selectCandidate(id)) {
                                      _notice(
                                        context,
                                        '已选择「${candidate['display_name']}」，切换成员逐一确认。',
                                      );
                                    }
                                  },
                            compact: true,
                          ),
                        ],
                      ],
                    ),
                  ),
                ],
              ),
            ),
          );
        }),
        const SizedBox(height: 4),
        const Row(
          children: [
            Icon(Icons.info_outline, size: 14, color: _muted),
            SizedBox(width: 6),
            Expanded(
              child: Text(
                '时间、费用与天气均为固定模拟数据；兴趣用于比较，预算和时间为硬约束。',
                style: TextStyle(color: _muted, fontSize: 11, height: 1.4),
              ),
            ),
          ],
        ),
      ],
    );
  }
}

class _VoteProgress extends StatelessWidget {
  const _VoteProgress({required this.session});

  final TripSession session;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.all(13),
    decoration: BoxDecoration(
      color: const Color(0xFFEAF0E6),
      borderRadius: BorderRadius.circular(12),
    ),
    child: Row(
      children: [
        const Icon(Icons.how_to_vote_outlined, color: _ink, size: 19),
        const SizedBox(width: 8),
        Expanded(
          child: Text(
            session.phase == TripPhase.confirming
                ? '路线已选 · 等待成员确认'
                : '每人先投一票，再由发起人选择',
            style: const TextStyle(
              color: _ink,
              fontSize: 12,
              fontWeight: FontWeight.w700,
            ),
          ),
        ),
        Text(
          '${session.votes.length}/4',
          style: const TextStyle(
            color: _inkSoft,
            fontWeight: FontWeight.w800,
            fontSize: 12,
          ),
        ),
      ],
    ),
  );
}

class _CostLabel extends StatelessWidget {
  const _CostLabel({required this.name, required this.cost});

  final String name;
  final int cost;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 5),
    decoration: BoxDecoration(
      color: _paper,
      borderRadius: BorderRadius.circular(8),
    ),
    child: Text(
      '$name ¥${cost ~/ 100}',
      style: const TextStyle(
        color: _ink,
        fontSize: 10,
        fontWeight: FontWeight.w700,
      ),
    ),
  );
}

class ChangesPage extends StatelessWidget {
  const ChangesPage({required this.session, super.key});

  final TripSession session;

  @override
  Widget build(BuildContext context) {
    if (session.phase != TripPhase.executing) {
      return _PageFrame(
        children: [
          const _Eyebrow(label: '第四步 · 天气与计划变更', icon: Icons.cloud_outlined),
          const SizedBox(height: 11),
          const Text('给计划留一点弹性', style: _pageTitle),
          const SizedBox(height: 7),
          const Text('选定路线并完成四人确认后，可以演示天气变化。', style: _bodyMuted),
          const SizedBox(height: 25),
          Container(
            height: 190,
            decoration: BoxDecoration(
              color: _ink,
              borderRadius: BorderRadius.circular(17),
            ),
            child: Stack(
              children: [
                Positioned(
                  right: 22,
                  top: 20,
                  child: Icon(
                    Icons.cloud_queue_rounded,
                    size: 100,
                    color: Colors.white.withValues(alpha: .08),
                  ),
                ),
                Positioned(
                  left: 22,
                  top: 25,
                  child: const Icon(
                    Icons.wb_cloudy_outlined,
                    color: _lime,
                    size: 27,
                  ),
                ),
                Positioned(
                  left: 22,
                  bottom: 25,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: const [
                      Text(
                        '一场雨，也有备选。',
                        style: TextStyle(
                          color: Colors.white,
                          fontWeight: FontWeight.w800,
                          fontSize: 19,
                        ),
                      ),
                      SizedBox(height: 6),
                      Text(
                        '先选路线、再由四人确认',
                        style: TextStyle(color: Colors.white70, fontSize: 12),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 16),
          _InfoBanner(
            icon: Icons.lock_outline,
            title: '变更预览尚未开放',
            detail: session.phase == TripPhase.collecting
                ? '先在候选页选一条可行路线，并让四位成员确认。'
                : '四位成员已确认后，由发起人开始行程。',
          ),
        ],
      );
    }

    final preview = session.pendingRain;
    final updated = session.rainApplied;
    final change = session.changeApplications.isEmpty
        ? null
        : session.changeApplications.last;
    return _PageFrame(
      children: [
        const _Eyebrow(label: '第四步 · 天气与计划变更', icon: Icons.cloud_outlined),
        const SizedBox(height: 11),
        Text(updated ? '雨天预案已更新' : '如果下午下雨', style: _pageTitle),
        const SizedBox(height: 7),
        Text(
          '当前行程 ${session.currentVersion} · ${session.selectedCandidateName}',
          style: _bodyMuted,
        ),
        const SizedBox(height: 19),
        Container(
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: const Color(0xFFE6EFEE),
            borderRadius: BorderRadius.circular(14),
          ),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Icon(Icons.cloudy_snowing, color: _ink, size: 23),
              const SizedBox(width: 11),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      '模拟降雨 · ${session.rainWindowLabel}',
                      style: const TextStyle(
                        color: _ink,
                        fontWeight: FontWeight.w800,
                        fontSize: 14,
                      ),
                    ),
                    const SizedBox(height: 4),
                    const Text(
                      '来源：固定演示脚本 · 兰州当地时间',
                      style: TextStyle(color: _muted, fontSize: 11),
                    ),
                  ],
                ),
              ),
              _StatusPill(label: '模拟', good: true),
            ],
          ),
        ),
        const SizedBox(height: 19),
        const SectionHeading(title: '行程节点', action: null),
        const SizedBox(height: 12),
        ..._timelineNodes().map((node) {
          final replaced = node['node_id'] == preview?.affectedNodeId;
          final visible = replaced ? preview!.replacement : node;
          final isTarget =
              node['node_id'] == session.rainTargetNodeId ||
              node['node_id'] == '${session.rainTargetNodeId}-r1';
          return _TimelineRow(
            time:
                '${_clock(_minute(node['start'] as String))}–${_clock(_minute(node['end'] as String))}',
            title: visible['kind'] == 'transit'
                ? (node['node_id'] == _timelineNodes().first['node_id']
                      ? '校园出发至活动区'
                      : '活动区返校')
                : (visible['display_name'] as String?) ??
                      _placeName(visible['place_tag'] as String? ?? ''),
            detail: replaced
                ? '室内替代 · 预览中'
                : isTarget
                ? (updated ? '室外活动已替换' : '室外活动 · 雨窗命中')
                : visible['kind'] == 'transit'
                ? '地铁出行'
                : '室内活动',
            active: replaced || (!updated && isTarget),
            done: updated && isTarget,
            last: node['node_id'] == _timelineNodes().last['node_id'],
          );
        }),
        const SizedBox(height: 13),
        if (preview != null)
          Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const Text(
                '选择雨天替代活动',
                style: TextStyle(
                  color: _ink,
                  fontSize: 13,
                  fontWeight: FontWeight.w800,
                ),
              ),
              const SizedBox(height: 8),
              Wrap(
                spacing: 8,
                runSpacing: 6,
                children: session.rainReplacementOptions.map((option) {
                  final id =
                      option['replacement_id'] as String? ?? 'rain-default';
                  final name =
                      option['display_name'] as String? ??
                      _placeName(
                        option['node'] is Map
                            ? (option['node'] as Map)['place_tag'] as String? ??
                                  ''
                            : '室内活动',
                      );
                  return _ChoiceChip(
                    label: name,
                    selected: session.selectedRainReplacementId == id,
                    onTap: () {
                      if (session.previewRain(replacementId: id) == null) {
                        _notice(
                          context,
                          session.rainFeedback ?? '该替代活动暂时无法满足四人约束。',
                        );
                      }
                    },
                  );
                }).toList(),
              ),
              const SizedBox(height: 12),
              _InfoBanner(
                icon: Icons.swap_horiz_rounded,
                title: '只替换受影响的户外活动',
                detail:
                    '${preview.reason}\n预览 ${preview.previewId} · 基线 ${preview.baseVersion}',
              ),
              const SizedBox(height: 11),
              Text(
                '${session.members.map((member) => '${member['display_name']} ¥${(preview.costPerMember[member['member_id']]! / 100).toStringAsFixed(2)}').join(' · ')}\n当前行程仍是 ${session.currentVersion}',
                style: const TextStyle(
                  color: _inkSoft,
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                ),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 13),
              if (!session.isOrganizer)
                const _InfoBanner(
                  icon: Icons.lock_outline,
                  title: '等待发起人确认',
                  detail: '预览期间仍执行原行程。只有发起人可以应用这次变更。',
                ),
              if (session.isOrganizer) ...[
                PrimaryButton(
                  label: '确认并更新计划',
                  icon: Icons.check_circle_outline,
                  onPressed: () => session.applyRain(),
                ),
                const SizedBox(height: 8),
                OutlinedButton.icon(
                  onPressed: session.cancelRain,
                  icon: const Icon(Icons.close, size: 17),
                  label: const Text('取消，保留原计划'),
                  style: OutlinedButton.styleFrom(
                    foregroundColor: _ink,
                    minimumSize: const Size.fromHeight(46),
                    side: const BorderSide(color: _line),
                  ),
                ),
              ],
            ],
          )
        else if (!updated) ...[
          if (session.selectedCandidateId == 'c02')
            const _InfoBanner(
              icon: Icons.check_circle_outline,
              title: '降雨只影响一个户外节点',
              detail: '路线中其余三个节点与费用不会改变。',
            )
          else
            const _InfoBanner(
              icon: Icons.check_circle_outline,
              title: '当前路线不受模拟降雨影响',
              detail: '所有行程节点均可按原计划执行。',
            ),
          const SizedBox(height: 13),
          if (!session.isOrganizer)
            const _InfoBanner(
              icon: Icons.lock_outline,
              title: '仅发起人可触发模拟天气',
              detail: '可切换到甲的身份查看并发起变更预览。',
            ),
          if (session.isOrganizer && session.selectedCandidateId == 'c02')
            PrimaryButton(
              label: '查看室内替代方案',
              icon: Icons.umbrella_outlined,
              onPressed: () {
                if (session.previewRain() == null) {
                  _notice(context, session.rainFeedback ?? '当前方案没有可替换的户外活动。');
                }
              },
            ),
        ] else ...[
          _InfoBanner(
            icon: Icons.verified_outlined,
            title: '已由发起人确认更新',
            detail: change == null
                ? '只替换了雨窗内的户外活动，其他行程节点与费用保持不变。'
                : '仅替换雨窗内的户外活动；${change.baseVersion} 成员确认留在历史记录。',
          ),
          const SizedBox(height: 13),
          Row(
            children: [
              Avatar(
                name: change == null
                    ? '甲'
                    : session.member(change.actorMemberId)['display_name']
                          as String,
                color: avatarColor(change?.actorMemberId ?? 'm01'),
                size: 27,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  change == null
                      ? '甲 · 发起人已确认'
                      : '${session.member(change.actorMemberId)['display_name']} · '
                            '${RoomTime.format(change.confirmedAt)} · ${change.previewId}',
                  style: const TextStyle(
                    color: _inkSoft,
                    fontSize: 11,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
              const SizedBox(width: 8),
              Text(
                session.currentVersion,
                style: const TextStyle(
                  color: _ink,
                  fontSize: 13,
                  fontWeight: FontWeight.w800,
                ),
              ),
            ],
          ),
        ],
        if (session.confirmationHistory.isNotEmpty) ...[
          const SizedBox(height: 18),
          const Text('成员确认记录', style: _bodyMuted),
          const SizedBox(height: 7),
          ...session.confirmationHistory.map(
            (record) => Padding(
              padding: const EdgeInsets.only(bottom: 5),
              child: Text(
                '${session.member(record.memberId)['display_name']} · ${record.version} · ${RoomTime.format(record.confirmedAt)}',
                style: const TextStyle(color: _muted, fontSize: 11),
              ),
            ),
          ),
        ],
      ],
    );
  }

  List<Map<String, dynamic>> _timelineNodes() {
    if (session.activeNodes.isNotEmpty) return session.activeNodes;
    return (session.candidate('c02')['nodes'] as List)
        .map((item) => Map<String, dynamic>.from(item as Map))
        .toList();
  }
}

class _TimelineRow extends StatelessWidget {
  const _TimelineRow({
    required this.time,
    required this.title,
    required this.detail,
    required this.active,
    required this.done,
    required this.last,
  });

  final String time;
  final String title;
  final String detail;
  final bool active;
  final bool done;
  final bool last;

  @override
  Widget build(BuildContext context) => SizedBox(
    height: 67,
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          width: 46,
          child: Padding(
            padding: const EdgeInsets.only(top: 2),
            child: Text(
              time.substring(0, 5),
              style: const TextStyle(
                color: _muted,
                fontSize: 11,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        ),
        SizedBox(
          width: 24,
          child: Column(
            children: [
              Container(
                width: 12,
                height: 12,
                decoration: BoxDecoration(
                  color: done
                      ? _inkSoft
                      : active
                      ? _coral
                      : _lime,
                  shape: BoxShape.circle,
                  border: Border.all(
                    color: active && !done ? const Color(0xFFF1CABF) : _paper,
                    width: 2,
                  ),
                ),
              ),
              if (!last) Expanded(child: Container(width: 1.5, color: _line)),
            ],
          ),
        ),
        const SizedBox(width: 6),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                title,
                style: TextStyle(
                  color: active ? _ink : _inkSoft,
                  fontSize: 13,
                  fontWeight: FontWeight.w700,
                ),
              ),
              const SizedBox(height: 3),
              Text(
                detail,
                style: TextStyle(
                  color: active ? const Color(0xFFB35C4B) : _muted,
                  fontSize: 11,
                ),
              ),
            ],
          ),
        ),
      ],
    ),
  );
}

class FieldSection extends StatelessWidget {
  const FieldSection({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.child,
    this.trailing,
    super.key,
  });

  final IconData icon;
  final String title;
  final String subtitle;
  final Widget child;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.fromLTRB(14, 13, 14, 12),
    decoration: BoxDecoration(
      color: Colors.white,
      border: Border.all(color: _line),
      borderRadius: BorderRadius.circular(8),
    ),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Icon(icon, color: _inkSoft, size: 18),
            const SizedBox(width: 8),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: const TextStyle(
                      color: _ink,
                      fontSize: 13,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const SizedBox(height: 3),
                  Text(
                    subtitle,
                    style: const TextStyle(color: _muted, fontSize: 10),
                  ),
                ],
              ),
            ),
            if (trailing != null) trailing!,
          ],
        ),
        const SizedBox(height: 12),
        child,
      ],
    ),
  );
}

class _ChoiceChip extends StatelessWidget {
  const _ChoiceChip({
    required this.label,
    required this.selected,
    required this.onTap,
    this.danger = false,
  });

  final String label;
  final bool selected;
  final VoidCallback onTap;
  final bool danger;

  @override
  Widget build(BuildContext context) {
    final active = danger ? const Color(0xFFFFECE6) : _lime;
    return FilterChip(
      label: Text(label),
      selected: selected,
      onSelected: (_) => onTap(),
      showCheckmark: selected,
      checkmarkColor: danger ? const Color(0xFFA4513E) : _ink,
      selectedColor: active,
      backgroundColor: _paper,
      side: BorderSide(
        color: selected ? (danger ? const Color(0xFFEAC2B8) : _lime) : _line,
      ),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
      labelStyle: TextStyle(
        color: selected && danger ? const Color(0xFFA4513E) : _ink,
        fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
        fontSize: 12,
      ),
      visualDensity: VisualDensity.compact,
      padding: const EdgeInsets.symmetric(horizontal: 4),
    );
  }
}

class SectionHeading extends StatelessWidget {
  const SectionHeading({
    required this.title,
    required this.action,
    this.onAction,
    super.key,
  });

  final String title;
  final String? action;
  final VoidCallback? onAction;

  @override
  Widget build(BuildContext context) => Row(
    children: [
      Text(title, style: _sectionTitle),
      const Spacer(),
      if (action != null)
        TextButton(
          onPressed: onAction,
          style: TextButton.styleFrom(
            foregroundColor: _inkSoft,
            visualDensity: VisualDensity.compact,
          ),
          child: Row(
            children: [
              Text(action!, style: const TextStyle(fontSize: 11)),
              const SizedBox(width: 3),
              const Icon(Icons.arrow_forward, size: 13),
            ],
          ),
        ),
    ],
  );
}

class _PlanMetric extends StatelessWidget {
  const _PlanMetric({
    required this.value,
    required this.label,
    required this.icon,
  });

  final String value;
  final String label;
  final IconData icon;

  @override
  Widget build(BuildContext context) => Expanded(
    child: Container(
      height: 84,
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: _line),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 16, color: _inkSoft),
          const Spacer(),
          Text(
            value,
            style: const TextStyle(
              color: _ink,
              fontWeight: FontWeight.w800,
              fontSize: 13,
            ),
          ),
          const SizedBox(height: 2),
          Text(
            label,
            style: const TextStyle(color: _muted, fontSize: 10),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        ],
      ),
    ),
  );
}

class _Eyebrow extends StatelessWidget {
  const _Eyebrow({required this.label, required this.icon});

  final String label;
  final IconData icon;

  @override
  Widget build(BuildContext context) => Row(
    children: [
      Icon(icon, color: _inkSoft, size: 15),
      const SizedBox(width: 6),
      Text(
        label,
        style: const TextStyle(
          color: _inkSoft,
          fontWeight: FontWeight.w700,
          fontSize: 11,
        ),
      ),
    ],
  );
}

class _InfoBanner extends StatelessWidget {
  const _InfoBanner({
    required this.icon,
    required this.title,
    required this.detail,
    this.action,
    this.onAction,
  });

  final IconData icon;
  final String title;
  final String detail;
  final String? action;
  final VoidCallback? onAction;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.all(12),
    decoration: BoxDecoration(
      color: const Color(0xFFEAF0E6),
      borderRadius: BorderRadius.circular(11),
    ),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(icon, color: _inkSoft, size: 18),
        const SizedBox(width: 9),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                title,
                style: const TextStyle(
                  color: _ink,
                  fontSize: 12,
                  fontWeight: FontWeight.w700,
                ),
              ),
              const SizedBox(height: 3),
              Text(
                detail,
                style: const TextStyle(
                  color: _inkSoft,
                  fontSize: 11,
                  height: 1.4,
                ),
              ),
            ],
          ),
        ),
        if (action != null)
          TextButton(
            onPressed: onAction,
            style: TextButton.styleFrom(
              foregroundColor: _ink,
              visualDensity: VisualDensity.compact,
            ),
            child: Text(action!, style: const TextStyle(fontSize: 11)),
          ),
      ],
    ),
  );
}

class _StatusPill extends StatelessWidget {
  const _StatusPill({required this.label, required this.good});

  final String label;
  final bool good;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
    decoration: BoxDecoration(
      color: good ? const Color(0xFFEAF2D6) : const Color(0xFFFFECE6),
      borderRadius: BorderRadius.circular(20),
    ),
    child: Text(
      label,
      style: TextStyle(
        color: good ? _inkSoft : const Color(0xFFA4513E),
        fontSize: 10,
        fontWeight: FontWeight.w700,
      ),
    ),
  );
}

class Avatar extends StatelessWidget {
  const Avatar({
    required this.name,
    required this.color,
    this.size = 36,
    super.key,
  });

  final String name;
  final Color color;
  final double size;

  @override
  Widget build(BuildContext context) => Container(
    width: size,
    height: size,
    decoration: BoxDecoration(color: color, shape: BoxShape.circle),
    child: Center(
      child: Text(
        name.substring(0, 1),
        style: TextStyle(
          color: _ink,
          fontWeight: FontWeight.w800,
          fontSize: size * .36,
        ),
      ),
    ),
  );
}

class PrimaryButton extends StatelessWidget {
  const PrimaryButton({
    required this.label,
    required this.icon,
    required this.onPressed,
    this.compact = false,
    super.key,
  });

  final String label;
  final IconData icon;
  final VoidCallback? onPressed;
  final bool compact;

  @override
  Widget build(BuildContext context) => SizedBox(
    width: double.infinity,
    height: compact ? 42 : 49,
    child: FilledButton.icon(
      onPressed: onPressed,
      icon: Icon(icon, size: compact ? 17 : 19),
      label: Text(
        label,
        style: TextStyle(
          fontSize: compact ? 12 : 14,
          fontWeight: FontWeight.w700,
        ),
      ),
      style: FilledButton.styleFrom(
        backgroundColor: _ink,
        foregroundColor: Colors.white,
        disabledBackgroundColor: const Color(0xFFBBC4BE),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(11)),
      ),
    ),
  );
}

class _PageFrame extends StatelessWidget {
  const _PageFrame({required this.children});

  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    final width = MediaQuery.sizeOf(context).width;
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 640),
        child: ListView(
          padding: EdgeInsets.fromLTRB(
            width < 400 ? 18 : 24,
            14,
            width < 400 ? 18 : 24,
            28,
          ),
          children: children,
        ),
      ),
    );
  }
}

const _pageTitle = TextStyle(
  color: _ink,
  fontWeight: FontWeight.w800,
  fontSize: 25,
  height: 1.2,
);
const _sectionTitle = TextStyle(
  color: _ink,
  fontWeight: FontWeight.w800,
  fontSize: 15,
);
const _bodyMuted = TextStyle(color: _muted, fontSize: 13, height: 1.45);

Color avatarColor(String id) => switch (id) {
  'm01' => const Color(0xFFF1A58E),
  'm02' => _lime,
  'm03' => const Color(0xFF9DD2C1),
  _ => const Color(0xFFF1D290),
};

String _preferenceSummary(TripSession session, String id) {
  final pref = session.preference(id);
  return '${_dateTimeLabel(pref.startAt)} 起 · 预算 ¥${pref.budgetCap ~/ 100} · ${pref.transport.map((value) => _transportName(value, pref)).join('、')}';
}

String _transportName(String value, [MemberPreferences? pref]) =>
    switch (value) {
      'metro' => '地铁',
      'bus' => '公交',
      'walk' => '步行',
      'taxi' => '打车',
      'bicycle' => '自行车',
      'other' =>
        pref != null && pref.customTransport.trim().isNotEmpty
            ? pref.customTransport.trim()
            : '其他',
      _ => value,
    };

String _placeName(String tag) => switch (tag) {
  'photo_studio' => '摄影体验馆',
  'plaza' => '户外广场拍照',
  'gallery' => '室内展览',
  'gallery_indoor' => '室内摄影展厅',
  'cinema' => '电影院',
  'movie' => '电影院',
  'shopping' => '逛街',
  'mall' => '商场',
  'museum' => '博物馆',
  'workshop' => '室内手作工坊',
  'yellow_river' => '黄河边',
  _ => tag,
};

String _timeFrom(Map<String, dynamic> candidate, String key) {
  final window = Map<String, dynamic>.from(candidate['window'] as Map);
  final wall = RoomTime.toWallTime(RoomTime.parse(window[key] as String));
  return _clock(wall.hour * 60 + wall.minute);
}

String _candidateTransports(Map<String, dynamic> candidate) {
  final values = <String>{};
  for (final node in (candidate['nodes'] as List)) {
    if (node is Map && node['kind'] == 'transit') {
      values.add(TransportCodes.normalize(node['transport'] as String));
    }
  }
  return values.map(_transportName).join(' · ');
}

String _dateTimeLabel(DateTime value) => RoomTime.format(value);

int _minute(String iso) {
  final wall = RoomTime.toWallTime(RoomTime.parse(iso));
  return wall.hour * 60 + wall.minute;
}

String _clock(int minute) =>
    '${(minute ~/ 60).toString().padLeft(2, '0')}:${(minute % 60).toString().padLeft(2, '0')}';

void _notice(BuildContext context, String message) {
  ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
}
