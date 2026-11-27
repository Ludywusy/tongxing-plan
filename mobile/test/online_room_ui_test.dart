import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:tongxing_plan/online_room.dart';

void main() {
  testWidgets(
    'retains a failed form, resubmits as self, restores after restart and keeps stale snapshot',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(390, 844));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      SharedPreferences.setMockInitialValues({});
      final store = await SharedPreferencesRoomIdentityStore.create();
      final identity = RoomIdentity.fromResponse({
        'room_id': 'room-one',
        'invite_code': 'ABC123',
        'member': {
          'member_id': 'm01',
          'display_name': '甲',
          'role': 'organizer',
        },
        'member_token': 'unit-test-only',
      }, tripDate: '2026-11-28');
      await store.saveBaseUrl('http://10.0.0.2:8000/api/v0.1');
      await store.saveIdentity(identity);
      var writes = 0;
      var disconnected = false;
      var emptyIntersection = false;
      final client = MockClient((request) async {
        expect(request.headers['Authorization'], 'Bearer unit-test-only');
        if (disconnected) throw http.ClientException('offline');
        if (request.method == 'PUT') {
          writes += 1;
          final body = jsonDecode(request.body) as Map;
          expect(body.containsKey('member_id'), isFalse);
          expect(body.containsKey('actor_id'), isFalse);
          expect(body['budget_cap'], 8050);
          expect(body['allowed_transport'], ['bicycle']);
          expect(body['taboo_tags'], isEmpty);
          expect(
            body['available_windows'][0]['start'],
            '2026-11-28T13:00:00+08:00',
          );
          if (writes == 1) {
            return _response({
              'error': {
                'code': 'INVALID_INPUT',
                'message': '请重试',
                'details': {
                  'fields': [
                    {'field': 'budget_cap', 'message': '预算暂时未保存，请重试。'},
                  ],
                },
              },
            }, 422);
          }
          return _response({
            'room_id': 'room-one',
            'member_id': 'm01',
            'submission_status': 'submitted',
            'submission_progress': {'submitted_count': 4, 'required_count': 4},
          });
        }
        return _response({
          'room_id': 'room-one',
          'room_name': '联调房间',
          'trip_date': '2026-11-28',
          'timezone': 'Asia/Shanghai',
          'phase': 'collecting',
          'capacity': 4,
          'organizer_member_id': 'm01',
          'viewer_member_id': 'm01',
          'members': [
            for (var i = 1; i <= 4; i++)
              {
                'member_id': 'm0$i',
                'display_name': ['甲', '乙', '丙', '丁'][i - 1],
                'role': i == 1 ? 'organizer' : 'member',
                'submission_status': 'submitted',
              },
          ],
          'submission_progress': {'submitted_count': 4, 'required_count': 4},
          'summary': {
            'common_windows': emptyIntersection
                ? []
                : [
                    {
                      'start': '2026-11-28T05:00:00Z',
                      'end': '2026-11-28T09:00:00Z',
                    },
                  ],
            'common_allowed_transport': emptyIntersection ? [] : ['bicycle'],
            'min_budget_cap': 8000,
          },
        });
      });
      Future<void> openPage() async {
        await tester.pumpWidget(
          MaterialApp(
            home: OnlineRoomPage(
              key: UniqueKey(),
              store: store,
              httpClient: client,
            ),
          ),
        );
        await tester.pumpAndSettle();
      }

      Future<void> tap(Finder finder) async {
        await tester.ensureVisible(finder);
        await tester.pumpAndSettle();
        await tester.tap(finder);
        await tester.pumpAndSettle();
      }

      await openPage();
      expect(find.text('4/4 已提交'), findsOneWidget);
      expect(
        tester
            .widget<TextField>(find.byKey(const Key('online-service-url')))
            .enabled,
        isFalse,
      );
      final budget = find.byKey(const Key('online-budget'));
      await tester.ensureVisible(budget);
      await tester.enterText(budget, '80.50');
      tester.testTextInput.hide();
      await tap(find.text('自行车').last);
      await tap(find.text('我明确没有地点禁忌'));
      await tap(find.text('保存修改并刷新'));
      expect(writes, 1);
      expect(tester.widget<TextField>(budget).controller!.text, '80.50');
      expect(find.text('预算暂时未保存，请重试。'), findsOneWidget);
      await tap(find.text('保存修改并刷新'));
      await tap(find.text('保存修改并刷新'));
      expect(writes, 3);
      expect(find.text('4/4 已提交'), findsOneWidget);

      await openPage();
      expect(tester.widget<TextField>(budget).controller!.text, '80.50');
      expect(
        tester
            .widget<FilterChip>(find.widgetWithText(FilterChip, '自行车'))
            .selected,
        isTrue,
      );
      await tap(find.text('保存修改并刷新'));
      expect(writes, 4);
      emptyIntersection = true;
      await tap(find.text('刷新快照'));
      expect(find.textContaining('目前没有共同可用时间'), findsOneWidget);
      expect(find.textContaining('目前没有共同交通方式'), findsOneWidget);
      disconnected = true;
      await tap(find.text('刷新快照'));
      expect(find.textContaining('内容可能已过期'), findsOneWidget);
      expect(tester.widget<TextField>(budget).controller!.text, '80.50');
      expect(await store.loadIdentity(), isNotNull);
      expect(tester.takeException(), isNull);
    },
  );
}

http.Response _response(Map<String, dynamic> json, [int status = 200]) =>
    http.Response(
      jsonEncode(json),
      status,
      headers: {'content-type': 'application/json; charset=utf-8'},
    );
