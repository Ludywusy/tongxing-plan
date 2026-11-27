import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:tongxing_plan/online_room.dart';
import 'package:tongxing_plan/room_time.dart';
import 'package:tongxing_plan/transport_codes.dart';

void main() {
  test('mobile transport constants match the shared export table', () {
    final table =
        jsonDecode(File('../schemas/transport-codes.json').readAsStringSync())
            as Map;
    expect(TransportCodes.canonical, table['canonical']);
    for (final entry in (table['aliases'] as Map).entries) {
      expect(TransportCodes.normalize(entry.key as String), entry.value);
    }
    expect(
      () => RoomApiClient.normalizeBaseUrl('http://10.0.0.2/?token=x'),
      throwsFormatException,
    );
  });
  group('room API client', () {
    test(
      'normalizes the API prefix and sends an idempotent create request',
      () async {
        expect(
          RoomApiClient.normalizeBaseUrl('http://10.0.0.2:8000'),
          'http://10.0.0.2:8000/api/v0.1',
        );
        expect(
          RoomApiClient.normalizeBaseUrl('http://10.0.0.2:8000/api/v0.1/'),
          'http://10.0.0.2:8000/api/v0.1',
        );

        final client = RoomApiClient(
          client: MockClient((request) async {
            expect(request.method, 'POST');
            expect(request.url.path, '/api/v0.1/rooms');
            expect(request.headers['Idempotency-Key'], 'stable-key');
            final body = jsonDecode(request.body) as Map<String, dynamic>;
            expect(body['display_name'], '甲');
            expect(body.containsKey('member_id'), isFalse);
            return http.Response(
              jsonEncode({
                'room_id': 'r-123',
                'invite_code': 'ABC123',
                'phase': 'collecting',
                'capacity': 4,
                'member': {
                  'member_id': 'm01',
                  'display_name': '甲',
                  'role': 'organizer',
                },
                'member_token': 'test-token',
              }),
              201,
              headers: {'content-type': 'application/json; charset=utf-8'},
            );
          }),
          baseUrl: 'http://10.0.0.2:8000',
        );
        final response = await client.createRoom({
          'room_name': '周末出游',
          'display_name': '甲',
          'trip_date': '2026-11-28',
          'timezone': 'Asia/Shanghai',
        }, 'stable-key');
        final identity = RoomIdentity.fromResponse(response);
        expect(identity.roomId, 'r-123');
        expect(identity.memberId, 'm01');
        expect(identity.inviteCode, 'ABC123');
      },
    );

    test(
      'attaches only this device token and parses a shared snapshot',
      () async {
        final client = RoomApiClient(
          client: MockClient((request) async {
            expect(request.method, 'GET');
            expect(request.url.path, '/api/v0.1/rooms/r-123');
            expect(request.headers['Authorization'], 'Bearer test-token');
            return http.Response(
              jsonEncode({
                'room_id': 'r-123',
                'room_name': '周末出游',
                'trip_date': '2026-11-28',
                'timezone': 'Asia/Shanghai',
                'phase': 'collecting',
                'capacity': 4,
                'organizer_member_id': 'm01',
                'viewer_member_id': 'm02',
                'members': [
                  {
                    'member_id': 'm01',
                    'display_name': '甲',
                    'role': 'organizer',
                    'submission_status': 'submitted',
                  },
                  {
                    'member_id': 'm02',
                    'display_name': '乙',
                    'role': 'member',
                    'submission_status': 'pending',
                  },
                ],
                'submission_progress': {
                  'submitted_count': 1,
                  'required_count': 4,
                },
                'summary': null,
                'candidates': [],
                'selected_plan': null,
                'locked_plan': null,
                'active_plan': null,
                'confirmation_progress': null,
                'pending_change': null,
              }),
              200,
              headers: {'content-type': 'application/json; charset=utf-8'},
            );
          }),
          baseUrl: 'http://10.0.0.2:8000/api/v0.1/',
        );
        final snapshot = await client.getSnapshot('r-123', 'test-token');
        expect(snapshot.viewerMemberId, 'm02');
        expect(snapshot.submittedCount, 1);
        expect(snapshot.members.map((member) => member.memberId), [
          'm01',
          'm02',
        ]);
        expect(snapshot.summary, isNull);
      },
    );

    test(
      'keeps structured validation details when the service returns 422',
      () async {
        final client = RoomApiClient(
          client: MockClient(
            (_) async => http.Response(
              jsonEncode({
                'error': {
                  'code': 'INVALID_INPUT',
                  'message': '请核对请求字段后重新提交。',
                  'details': {
                    'fields': [
                      {
                        'field': 'allowed_transport',
                        'message': '请至少选择一种可接受的交通方式。',
                      },
                    ],
                  },
                },
              }),
              422,
              headers: {'content-type': 'application/json; charset=utf-8'},
            ),
          ),
          baseUrl: 'http://10.0.0.2:8000',
        );
        await expectLater(
          client.savePreferences('r-123', 'test-token', {}),
          throwsA(
            isA<RoomApiException>().having(
              (error) => error.displayMessage,
              'displayMessage',
              contains('至少选择一种'),
            ),
          ),
        );
      },
    );
  });

  test(
    'retries a timed-out create with the same saved idempotency key',
    () async {
      final store = _MemoryRoomStore();
      final keys = <String>[];
      var requestCount = 0;
      final api = RoomApiClient(
        client: MockClient((request) async {
          requestCount += 1;
          keys.add(request.headers['Idempotency-Key']!);
          if (requestCount == 1) throw http.ClientException('offline');
          return http.Response(
            jsonEncode({
              'room_id': 'r-123',
              'invite_code': 'ABC123',
              'phase': 'collecting',
              'capacity': 4,
              'member': {
                'member_id': 'm01',
                'display_name': '甲',
                'role': 'organizer',
              },
              'member_token': 'test-token',
            }),
            201,
            headers: {'content-type': 'application/json; charset=utf-8'},
          );
        }),
        baseUrl: 'http://10.0.0.2:8000',
      );
      final repository = RoomRepository(api: api, store: store);
      final payload = {
        'room_name': '周末出游',
        'display_name': '甲',
        'trip_date': '2026-11-28',
        'timezone': 'Asia/Shanghai',
      };

      await expectLater(
        repository.createRoom(payload),
        throwsA(isA<RoomApiException>()),
      );
      final pending = await store.loadPendingOperation();
      expect(pending, isNotNull);
      final identity = await repository.retryPendingOperation();
      expect(identity.memberToken, 'test-token');
      expect(keys, hasLength(2));
      expect(keys.first, keys.last);
      expect(await store.loadIdentity(), identity);
      expect(await store.loadPendingOperation(), isNull);
    },
  );

  test('converts yuan to exact integer cents without floating point', () {
    expect(parseYuanToCents('80'), 8000);
    expect(parseYuanToCents('80.5'), 8050);
    expect(parseYuanToCents('80.05'), 8005);
    expect(parseYuanToCents('80.001'), isNull);
    expect(parseYuanToCents('-1'), isNull);
    expect(parseYuanToCents(''), isNull);
  });

  test('serializes wall-clock selections as explicit Shanghai offsets', () {
    final instant = RoomTime.fromWallTime(DateTime.utc(2026, 11, 28, 13));
    expect(RoomTime.toIso8601(instant), '2026-11-28T13:00:00+08:00');
  });
}

class _MemoryRoomStore implements RoomIdentityStore {
  RoomIdentity? identity;
  PendingRoomOperation? pending;
  String? baseUrl;
  final drafts = <String, Map<String, dynamic>>{};

  @override
  Future<Map<String, dynamic>?> loadPreferenceDraft(
    RoomIdentity identity,
  ) async => drafts['${identity.roomId}.${identity.memberId}'];

  @override
  Future<void> savePreferenceDraft(
    RoomIdentity identity,
    Map<String, dynamic> payload,
  ) async {
    drafts['${identity.roomId}.${identity.memberId}'] = payload;
  }

  @override
  Future<void> clearIdentity() async => identity = null;

  @override
  Future<void> clearPendingOperation() async => pending = null;

  @override
  Future<String?> loadBaseUrl() async => baseUrl;

  @override
  Future<RoomIdentity?> loadIdentity() async => identity;

  @override
  Future<PendingRoomOperation?> loadPendingOperation() async => pending;

  @override
  Future<void> saveBaseUrl(String value) async => baseUrl = value;

  @override
  Future<void> saveIdentity(RoomIdentity value) async => identity = value;

  @override
  Future<void> savePendingOperation(PendingRoomOperation value) async =>
      pending = value;
}
