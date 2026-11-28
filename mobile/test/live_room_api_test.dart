// Opt-in cross-stack test. Starts a private local service and temporary database.
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:tongxing_plan/online_room.dart';

const _repo = String.fromEnvironment('ROOM_REPO_ROOT');
const _python = String.fromEnvironment('ROOM_PYTHON');

void main() {
  test(
    'four independent API clients agree before and after a real service restart',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'tongxing-room-live-',
      );
      final socket = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      final port = socket.port;
      await socket.close();
      final client = http.Client();
      final base = 'http://127.0.0.1:$port/api/v0.1';
      Process? process;
      Future<void> stop() async {
        process?.kill();
        await process?.exitCode.timeout(const Duration(seconds: 10));
        process = null;
      }

      Future<void> start() async {
        process = await Process.start(
          _python,
          [
            '-m',
            'uvicorn',
            'backend.main:app',
            '--host',
            '127.0.0.1',
            '--port',
            '$port',
            '--log-level',
            'warning',
          ],
          workingDirectory: _repo,
          environment: {'TONGXING_ROOM_DB': '${directory.path}/rooms.sqlite3'},
        );
        process!.stdout.drain<void>();
        process!.stderr.drain<void>();
        for (var i = 0; i < 100; i++) {
          try {
            final response = await client
                .get(Uri.parse('http://127.0.0.1:$port/docs'))
                .timeout(const Duration(seconds: 1));
            if (response.statusCode == 200) return;
          } on Object {
            /* Service not ready yet. */
          }
          await Future<void>.delayed(const Duration(milliseconds: 100));
        }
        throw StateError('Local test service did not become ready');
      }

      try {
        await start();
        final apis = List.generate(
          4,
          (_) => RoomApiClient(client: client, baseUrl: base),
        );
        final create = {
          'room_name': 'Synthetic API regression',
          'display_name': 'A',
          'trip_date': '2026-11-28',
          'timezone': 'Asia/Shanghai',
        };
        final room = await apis.first.createRoom(create, 'live-create');
        final members = <RoomIdentity>[RoomIdentity.fromResponse(room)];
        final joins = <Map<String, dynamic>>[];
        for (var i = 1; i < 4; i++) {
          final payload = {
            'invite_code': room['invite_code'],
            'display_name': 'client-$i',
          };
          joins.add(payload);
          final joined = await apis[i].joinRoom(payload, 'live-join-$i');
          expect(await apis[i].joinRoom(payload, 'live-join-$i'), joined);
          members.add(RoomIdentity.fromResponse(joined));
        }
        expect(members.map((m) => m.memberId).toSet(), hasLength(4));
        expect(members.map((m) => m.memberToken).toSet(), hasLength(4));
        expect(members.map((m) => m.roomId).toSet(), {members.first.roomId});
        await expectLater(
          apis.first.joinRoom({
            'invite_code': room['invite_code'],
            'display_name': 'fifth',
          }, 'live-fifth'),
          throwsA(
            isA<RoomApiException>().having((e) => e.code, 'code', 'ROOM_FULL'),
          ),
        );
        for (var i = 0; i < 4; i++) {
          final payload = _preferences(
            i.isEven ? 'bike' : 'bicycle',
            8000 + i * 100,
          );
          final saved = await apis[i].savePreferences(
            members[i].roomId,
            members[i].memberToken,
            payload,
          );
          expect(
            (saved['submission_progress'] as Map)['submitted_count'],
            i + 1,
          );
          final snapshot = await apis[(i + 1) % 4].getSnapshot(
            members.first.roomId,
            members[(i + 1) % 4].memberToken,
          );
          expect(snapshot.submittedCount, i + 1);
          if (i < 3) expect(snapshot.summary, isNull);
        }
        final repeat = await apis.first.savePreferences(
          members.first.roomId,
          members.first.memberToken,
          _preferences('bicycle', 8000),
        );
        expect((repeat['submission_progress'] as Map)['submitted_count'], 4);
        Future<List<Map<String, dynamic>>> snapshots() async {
          final values = <Map<String, dynamic>>[];
          for (var i = 0; i < 4; i++) {
            final value = await client.get(
              Uri.parse('$base/rooms/${members[i].roomId}'),
              headers: {'Authorization': 'Bearer ${members[i].memberToken}'},
            );
            final body = jsonDecode(value.body) as Map<String, dynamic>;
            expect(body.remove('viewer_member_id'), members[i].memberId);
            values.add(body);
          }
          return values;
        }

        final before = await snapshots();
        for (final snapshot in before) {
          expect(snapshot, before.first);
          expect((snapshot['summary'] as Map)['common_allowed_transport'], [
            'bicycle',
          ]);
          expect((snapshot['summary'] as Map)['min_budget_cap'], 8000);
        }
        await expectLater(
          apis.first.getSnapshot(members.first.roomId, 'invalid-test-token'),
          throwsA(
            isA<RoomApiException>().having((e) => e.statusCode, 'status', 401),
          ),
        );
        await expectLater(
          apis.first.savePreferences(
            members.first.roomId,
            members.first.memberToken,
            {..._preferences('bicycle', 8000), 'allowed_transport': []},
          ),
          throwsA(
            isA<RoomApiException>().having((e) => e.statusCode, 'status', 422),
          ),
        );
        await stop();
        await start();
        expect(await snapshots(), before);
        expect(await apis.first.createRoom(create, 'live-create'), room);
        for (var i = 1; i < 4; i++) {
          final replay = await apis[i].joinRoom(joins[i - 1], 'live-join-$i');
          expect(replay['member_token'], members[i].memberToken);
        }
      } finally {
        await stop();
        client.close();
        await directory.delete(recursive: true);
      }
    },
    skip: _repo.isEmpty || _python.isEmpty,
    timeout: const Timeout(Duration(minutes: 2)),
  );
}

Map<String, dynamic> _preferences(String transport, int budget) => {
  'available_windows': [
    {'start': '2026-11-28T05:00:00Z', 'end': '2026-11-28T17:00:00+08:00'},
  ],
  'budget_cap': budget,
  'budget_basis': {
    'includes_transport': true,
    'scope': 'per_person',
    'share_rule': null,
  },
  'allowed_transport': [transport],
  'taboo_tags': [],
};
