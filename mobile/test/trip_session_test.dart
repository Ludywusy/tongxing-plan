import 'package:flutter_test/flutter_test.dart';
import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:tongxing_plan/trip_session.dart';
import 'package:tongxing_plan/room_time.dart';
import 'package:tongxing_plan/transport_codes.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('fixed route checks', () {
    test(
      'shows the budget conflict and accepts the two feasible routes',
      () async {
        final session = await TripSession.fromAsset();

        expect(session.fixture['fixture_version'], '1.2');
        expect(
          session.checkCandidate(session.candidate('c01')).status,
          CandidateStatus.infeasible,
        );
        expect(
          session.checkCandidate(session.candidate('c01')).memberId,
          'm01',
        );
        expect(
          session.checkCandidate(session.candidate('c01')).ruleId,
          'R-BUD-01',
        );
        expect(
          session.checkCandidate(session.candidate('c02')).status,
          CandidateStatus.feasible,
        );
        expect(session.interestMatches(session.candidate('c01')), ['甲']);
        expect(session.interestMatches(session.candidate('c02')), [
          '甲',
          '乙',
          '丙',
        ]);
        expect(session.interestMatches(session.candidate('c03')), ['丁']);
        expect(
          session.checkCandidate(session.candidate('c03')).status,
          CandidateStatus.feasible,
        );
      },
    );

    test(
      'supports cross-day return, expanded transport, interests and taboos',
      () async {
        final session = await TripSession.fromAsset();
        session.updateWindow(
          'm01',
          endAt: RoomTime.fromWallTime(DateTime.utc(2026, 11, 22, 9, 30)),
        );
        expect(
          RoomTime.toWallTime(session.preference('m01').endAt),
          DateTime.utc(2026, 11, 22, 9, 30),
        );

        session.toggleTransport('m01', 'taxi');
        session.toggleTransport('m01', 'bicycle');
        session.toggleTransport('m01', 'other');
        expect(
          session.submitPreferences(),
          isFalse,
          reason: 'other requires a user-entered transport name',
        );
        session.preference('m01').customTransport = '共享电动车';
        expect(session.submitPreferences(), isTrue);

        session.toggleInterest('m01', 'movie');
        final movieCandidate = <String, dynamic>{
          ...session.candidate('c02'),
          'nodes': [
            {
              'node_id': 'c02-movie',
              'start': '2026-11-21T14:00:00+08:00',
              'end': '2026-11-21T15:00:00+08:00',
              'kind': 'activity',
              'place_tag': 'cinema',
              'indoor': true,
            },
          ],
        };
        expect(session.interestMatches(movieCandidate), contains('甲'));

        session.toggleTaboo('m01', 'museum');
        final museumCandidate = <String, dynamic>{
          ...session.candidate('c02'),
          'nodes': [
            {
              'node_id': 'c02-museum',
              'start': '2026-11-21T14:00:00+08:00',
              'end': '2026-11-21T15:00:00+08:00',
              'kind': 'activity',
              'place_tag': 'museum',
              'indoor': true,
            },
          ],
        };
        expect(session.checkCandidate(museumCandidate).ruleId, 'R-TABOO-01');
      },
    );

    test(
      'preference edits affect feasibility and incomplete fields are surfaced',
      () async {
        final session = await TripSession.fromAsset();

        session.updateBudget('m01', 8500);
        expect(
          session.checkCandidate(session.candidate('c01')).status,
          CandidateStatus.feasible,
        );

        session.toggleTransport('m02', 'metro');
        session.toggleTransport('m02', 'walk');
        expect(
          session.checkCandidate(session.candidate('c02')).status,
          CandidateStatus.incomplete,
        );

        session.toggleTransport('m02', 'walk');
        session.updateWindow('m03', end: 16 * 60);
        expect(
          session.checkCandidate(session.candidate('c02')).status,
          CandidateStatus.infeasible,
        );
        expect(
          session.checkCandidate(session.candidate('c02')).memberId,
          'm03',
        );
      },
    );
  });

  group('offline four-person flow', () {
    test(
      'requires every member before selection, confirmation, and start',
      () async {
        final session = await TripSession.fromAsset();

        expect(session.selectCandidate('c02'), isFalse);
        for (final member in session.members) {
          final id = member['member_id'] as String;
          session.setActiveMember(id);
          session.submitPreferences();
        }
        for (final member in session.members) {
          session.setActiveMember(member['member_id'] as String);
          session.toggleVote('c02');
        }
        expect(session.allSubmitted, isTrue);
        expect(session.voteCount('c02'), 4);

        session.setActiveMember('m02');
        expect(session.selectCandidate('c02'), isFalse);
        session.setActiveMember('m01');
        expect(session.selectCandidate('c02'), isTrue);
        expect(session.startTrip(), isFalse);

        for (final member in session.members) {
          session.setActiveMember(member['member_id'] as String);
          expect(session.confirmSelection(), isTrue);
        }
        expect(session.allConfirmed, isTrue);
        expect(session.confirmationHistory, hasLength(4));
        expect(
          session.confirmationHistory.map((item) => item.version).toSet(),
          {'v1'},
        );
        expect(session.startTrip(), isFalse);
        session.setActiveMember('m01');
        expect(session.startTrip(), isTrue);
        expect(session.currentVersion, 'v1');
      },
    );

    test(
      'cancel keeps v1 and applying rain changes only the affected node',
      () async {
        final session = await TripSession.fromAsset();
        for (final member in session.members) {
          session.setActiveMember(member['member_id'] as String);
          session.submitPreferences();
        }
        session.setActiveMember('m01');
        expect(session.selectCandidate('c02'), isTrue);
        for (final member in session.members) {
          session.setActiveMember(member['member_id'] as String);
          session.confirmSelection();
        }
        session.setActiveMember('m01');
        expect(session.startTrip(), isTrue);

        final originalIds = session.activeNodes
            .map((node) => node['node_id'] as String)
            .toList();
        final affectedId = session.rainTargetNodeId!;

        expect(session.previewRain(), isNotNull);
        session.cancelRain();
        expect(session.currentVersion, 'v1');
        expect(session.activeNodes.map((node) => node['node_id']), originalIds);

        expect(session.previewRain(), isNotNull);
        expect(session.applyRain(), isTrue);
        expect(session.currentVersion, 'v2');
        expect(session.pendingRain, isNull);
        expect(session.confirmedMembers, isEmpty);
        expect(session.changeApplications, hasLength(1));
        expect(session.changeApplications.single.actorMemberId, 'm01');
        expect(session.changeApplications.single.baseVersion, 'v1');
        expect(session.changeApplications.single.version, 'v2');
        expect(session.changeApplications.single.previewId, isNotEmpty);
        expect(
          session.confirmationHistory.map((item) => item.version).toSet(),
          {'v1'},
        );

        final updatedIds = session.activeNodes
            .map((node) => node['node_id'] as String)
            .toList();
        expect(updatedIds, contains('c02-n02-r1'));
        expect(updatedIds, isNot(contains(affectedId)));
        expect(
          updatedIds.where((id) => id != 'c02-n02-r1').toList(),
          originalIds.where((id) => id != affectedId).toList(),
        );
      },
    );

    test(
      'lets the organizer choose a different rain replacement before apply',
      () async {
        final session = await TripSession.fromAsset();
        for (final member in session.members) {
          session.setActiveMember(member['member_id'] as String);
          session.submitPreferences();
        }
        session.setActiveMember('m01');
        session.selectCandidate('c02');
        for (final member in session.members) {
          session.setActiveMember(member['member_id'] as String);
          session.confirmSelection();
        }
        session.setActiveMember('m01');
        session.startTrip();

        expect(session.previewRain(), isNotNull);
        expect(session.previewRain(replacementId: 'rain-craft'), isNotNull);
        expect(session.pendingRain!.replacementId, 'rain-craft');
        expect(
          session.activeNodes.map((node) => node['node_id']),
          contains('c02-n02'),
        );
        expect(session.applyRain(), isTrue);
        expect(
          session.activeNodes.map((node) => node['node_id']),
          contains('c02-n02-r4'),
        );
      },
    );
  });

  test(
    'normalizes legacy bike only and keeps the 1.1 fixture as regression',
    () async {
      expect(TransportCodes.normalize('bike'), 'bicycle');
      expect(TransportCodes.normalize('Metro'), 'Metro');
      expect(TransportCodes.normalizeAll(['bike', 'bicycle']), ['bicycle']);

      final session = await TripSession.fromAsset(
        assetPath: 'assets/demo-trip-1.1.json',
      );
      expect(session.fixture['fixture_version'], '1.1');
      expect(
        session.checkCandidate(session.candidate('c01')).status,
        CandidateStatus.infeasible,
      );
      expect(
        session.checkCandidate(session.candidate('c02')).status,
        CandidateStatus.feasible,
      );
      expect(
        session.checkCandidate(session.candidate('c03')).status,
        CandidateStatus.feasible,
      );

      final source = await rootBundle.loadString('assets/demo-trip-1.1.json');
      final fixture = Map<String, dynamic>.from(jsonDecode(source) as Map);
      for (final member in fixture['members'] as List) {
        (member as Map)['allowed_transport'] = ['bike', 'metro', 'walk'];
      }
      final candidate = (fixture['candidates'] as List).cast<Map>().firstWhere(
        (item) => item['candidate_id'] == 'c02',
      );
      final transit = (candidate['nodes'] as List).cast<Map>().firstWhere(
        (node) => node['kind'] == 'transit',
      );
      transit['transport'] = 'bicycle';
      final aliasSession = TripSession.fromJson(fixture);
      expect(aliasSession.preference('m01').transport, contains('bicycle'));
      expect(aliasSession.preference('m01').transport, isNot(contains('bike')));
      expect(
        aliasSession.checkCandidate(aliasSession.candidate('c02')).status,
        CandidateStatus.feasible,
      );
    },
  );

  test('room wall clock keeps equivalent offset timestamps at 13:00', () {
    final shanghai = RoomTime.parse('2026-11-21T13:00:00+08:00');
    final utc = RoomTime.parse('2026-11-21T05:00:00Z');
    expect(shanghai, utc);
    expect(RoomTime.format(shanghai), '11月21日 13:00');
    expect(RoomTime.format(utc), '11月21日 13:00');
    expect(RoomTime.toIso8601(utc), '2026-11-21T13:00:00+08:00');
    expect(() => RoomTime.parse('2026-11-21T13:00:00'), throwsFormatException);
  });

  test(
    'rejects a stale rain preview without changing active nodes or history',
    () async {
      final session = await TripSession.fromAsset();
      for (final member in session.members) {
        session.setActiveMember(member['member_id'] as String);
        session.submitPreferences();
      }
      session.setActiveMember('m01');
      session.selectCandidate('c02');
      for (final member in session.members) {
        session.setActiveMember(member['member_id'] as String);
        session.confirmSelection();
      }
      session.setActiveMember('m01');
      session.startTrip();
      final original = jsonEncode(session.activeNodes);
      final first = session.previewRain()!;
      final second = session.previewRain(replacementId: 'rain-cinema')!;
      expect(first.previewId, isNot(second.previewId));
      session.planVersion += 1; // A newer version arrived after this preview.
      expect(session.applyRain(), isFalse);
      expect(session.currentVersion, 'v2');
      expect(jsonEncode(session.activeNodes), original);
      expect(session.pendingRain, isNull);
      expect(session.changeApplications, isEmpty);
      expect(session.confirmationHistory, hasLength(4));
    },
  );
}
