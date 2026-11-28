import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:tongxing_plan/main.dart';
import 'package:tongxing_plan/trip_session.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('offers online rooms and a working offline experience', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    await tester.binding.setSurfaceSize(const Size(390, 844));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final session = (await tester.runAsync(TripSession.fromAsset))!;
    await tester.pumpWidget(MaterialApp(home: HomeScreen(session: session)));

    expect(find.text('和朋友一起计划'), findsOneWidget);
    expect(find.text('离线体验完整流程'), findsOneWidget);

    await tester.tap(find.text('和朋友一起计划'));
    await tester.pumpAndSettle();
    expect(find.text('服务地址'), findsOneWidget);
    expect(find.text('你的显示名'), findsOneWidget);
    await tester.pageBack();
    await tester.pumpAndSettle();

    await tester.tap(find.text('离线体验完整流程'));
    await tester.pumpAndSettle();
    expect(find.text('兰州半日游'), findsOneWidget);
    expect(find.byType(NavigationBar), findsOneWidget);
    expect(find.text('填写我的偏好'), findsOneWidget);
  });

  testWidgets(
    'four identities complete preferences, confirmation and rain on one phone',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(390, 844));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final session = (await tester.runAsync(TripSession.fromAsset))!;
      await tester.pumpWidget(MaterialApp(home: HomeScreen(session: session)));

      Future<void> tap(Finder finder) async {
        await tester.tap(finder);
        await tester.pumpAndSettle();
      }

      Future<void> scrollAndTap(Finder finder) async {
        if (finder.evaluate().isEmpty) {
          await tester.scrollUntilVisible(finder, 200);
        }
        await tester.ensureVisible(finder);
        await tester.pumpAndSettle();
        await tap(finder);
      }

      Future<void> switchTo(String name) async {
        await tap(find.byTooltip('切换模拟成员'));
        await tap(find.text('$name · ${name == '甲' ? '发起人' : '成员'}'));
      }

      await tap(find.text('离线体验完整流程'));
      await tap(find.text('偏好'));
      for (final name in ['甲', '乙', '丙', '丁']) {
        await switchTo(name);
        expect(session.activeMember['display_name'], name);
        await scrollAndTap(find.text('保存我的偏好'));
        await tester.pump(const Duration(seconds: 5));
        await tester.pumpAndSettle();
      }
      expect(session.allSubmitted, isTrue);

      await switchTo('甲');
      await tap(find.text('候选'));
      expect(find.textContaining('超过预算上限'), findsOneWidget);
      await scrollAndTap(find.text('选择此路线').first);
      expect(session.selectedCandidateId, 'c02');
      for (final name in ['甲', '乙', '丙', '丁']) {
        await switchTo(name);
        await scrollAndTap(find.text('确认 v1'));
      }
      await switchTo('甲');
      await scrollAndTap(find.text('四人已确认 · 开始行程'));
      await scrollAndTap(find.text('查看室内替代方案'));
      await scrollAndTap(find.text('电影院'));
      expect(session.pendingRain?.replacementId, 'rain-cinema');
      await scrollAndTap(find.text('取消，保留原计划'));
      expect(session.currentVersion, 'v1');
      await scrollAndTap(find.text('查看室内替代方案'));
      await scrollAndTap(find.text('确认并更新计划'));
      expect(session.currentVersion, 'v2');
      expect(find.text('室内摄影展厅'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );
}
