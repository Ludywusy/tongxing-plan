import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'room_time.dart';
import 'transport_codes.dart';

enum TripPhase { collecting, confirming, executing }

enum CandidateStatus { feasible, infeasible, incomplete }

class MemberPreferences {
  MemberPreferences({
    required this.budgetCap,
    required this.startAt,
    required this.endAt,
    required this.transport,
    required this.interests,
    required this.taboos,
    this.customTransport = '',
  });

  int budgetCap;
  DateTime startAt;
  DateTime endAt;
  final Set<String> transport;
  final Set<String> interests;
  final Set<String> taboos;
  String customTransport;

  int get startMinute {
    final wall = RoomTime.toWallTime(startAt);
    return wall.hour * 60 + wall.minute;
  }

  int get endMinute {
    final wall = RoomTime.toWallTime(endAt);
    return wall.hour * 60 + wall.minute;
  }

  set startMinute(int value) {
    final wall = RoomTime.toWallTime(startAt);
    startAt = RoomTime.fromWallTime(
      DateTime.utc(wall.year, wall.month, wall.day, value ~/ 60, value % 60),
    );
  }

  set endMinute(int value) {
    final wall = RoomTime.toWallTime(endAt);
    endAt = RoomTime.fromWallTime(
      DateTime.utc(wall.year, wall.month, wall.day, value ~/ 60, value % 60),
    );
  }

  factory MemberPreferences.fromJson(Map<String, dynamic> member) {
    final window = (member['available_windows'] as List).first as Map;
    return MemberPreferences(
      budgetCap: member['budget_cap'] as int,
      startAt: RoomTime.parse(window['start'] as String),
      endAt: RoomTime.parse(window['end'] as String),
      transport: TransportCodes.normalizeAll(
        (member['allowed_transport'] as List).cast<String>(),
      ).toSet(),
      interests: Set<String>.from(member['interest_tags'] as List? ?? const []),
      taboos: Set<String>.from(member['taboo_tags'] as List? ?? const []),
      customTransport: member['custom_transport'] as String? ?? '',
    );
  }
}

class CandidateCheck {
  const CandidateCheck(this.status, this.message, {this.memberId, this.ruleId});

  final CandidateStatus status;
  final String message;
  final String? memberId;
  final String? ruleId;
}

class RainPreview {
  const RainPreview({
    required this.previewId,
    required this.baseVersion,
    required this.createdAt,
    required this.affectedNodeId,
    required this.replacementId,
    required this.replacement,
    required this.costPerMember,
    required this.reason,
  });

  final String previewId;
  final String baseVersion;
  final DateTime createdAt;
  final String affectedNodeId;
  final String replacementId;
  final Map<String, dynamic> replacement;
  final Map<String, int> costPerMember;
  final String reason;
}

class PlanConfirmation {
  const PlanConfirmation({
    required this.memberId,
    required this.version,
    required this.confirmedAt,
  });

  final String memberId;
  final String version;
  final DateTime confirmedAt;
}

class ChangeApplication {
  const ChangeApplication({
    required this.actorMemberId,
    required this.baseVersion,
    required this.version,
    required this.previewId,
    required this.confirmedAt,
  });

  final String actorMemberId;
  final String baseVersion;
  final String version;
  final String previewId;
  final DateTime confirmedAt;
}

class TripSession extends ChangeNotifier {
  TripSession._(this.fixture) {
    members = _maps(fixture['members']);
    candidates = _maps(fixture['candidates']);
    activeMemberId = members.first['member_id'] as String;
    for (final member in members) {
      final id = member['member_id'] as String;
      preferences[id] = MemberPreferences.fromJson(member);
    }
    final selected = candidates.firstWhere(
      (candidate) => candidate['candidate_id'] == 'c02',
      orElse: () => candidates.first,
    );
    final rain = selected['nodes'] as List;
    final outdoor = rain.firstWhere(
      (node) => node['kind'] == 'activity' && node['indoor'] == false,
      orElse: () => <String, dynamic>{},
    );
    rainTargetNodeId = outdoor['node_id'] as String?;
  }

  final Map<String, dynamic> fixture;
  late final List<Map<String, dynamic>> members;
  late final List<Map<String, dynamic>> candidates;
  final Map<String, MemberPreferences> preferences = {};
  final Set<String> submittedMembers = {};
  final Map<String, String> votes = {};
  final Set<String> confirmedMembers = {};
  final List<PlanConfirmation> confirmationHistory = [];
  final List<ChangeApplication> changeApplications = [];
  String activeMemberId = '';
  String? selectedCandidateId;
  String? rainTargetNodeId;
  TripPhase phase = TripPhase.collecting;
  int planVersion = 0;
  bool rainApplied = false;
  String? rainFeedback;
  RainPreview? pendingRain;
  String? selectedRainReplacementId;
  List<Map<String, dynamic>> activeNodes = [];
  Map<String, int> activeCosts = {};
  int _previewSequence = 0;

  static Future<TripSession> fromAsset({
    String assetPath = 'assets/demo-trip.json',
  }) async {
    final json = await rootBundle.loadString(assetPath);
    return TripSession._(Map<String, dynamic>.from(jsonDecode(json) as Map));
  }

  static TripSession fromJson(Map<String, dynamic> fixture) =>
      TripSession._(Map<String, dynamic>.from(fixture));

  Map<String, dynamic> get activeMember => member(activeMemberId);
  bool get isOrganizer => activeMemberId == 'm01';
  bool get allSubmitted => submittedMembers.length == members.length;
  bool get allConfirmed => confirmedMembers.length == members.length;
  String get currentVersion => 'v$planVersion';
  String? get selectedCandidateName {
    if (selectedCandidateId == null) return null;
    return candidate(selectedCandidateId!)['display_name'] as String;
  }

  Map<String, dynamic> get rainEvent =>
      Map<String, dynamic>.from(fixture['rain_event'] as Map);
  Map<String, dynamic> get rainReplacement =>
      Map<String, dynamic>.from(fixture['rain_replacement'] as Map);
  List<Map<String, dynamic>> get rainReplacementOptions {
    final options = fixture['rain_replacement_options'];
    if (options is List && options.isNotEmpty) {
      return options
          .map((item) => Map<String, dynamic>.from(item as Map))
          .toList();
    }
    return [rainReplacement];
  }

  String get rainWindowLabel {
    final window = Map<String, dynamic>.from(rainEvent['window'] as Map);
    return '${_roomClock(window['start'] as String)}–${_roomClock(window['end'] as String)}';
  }

  Map<String, dynamic> member(String id) =>
      members.firstWhere((item) => item['member_id'] == id);

  Map<String, dynamic> candidate(String id) =>
      candidates.firstWhere((item) => item['candidate_id'] == id);

  MemberPreferences preference(String id) => preferences[id]!;

  void setActiveMember(String id) {
    activeMemberId = id;
    notifyListeners();
  }

  void updateBudget(String memberId, int value) {
    if (phase != TripPhase.collecting) return;
    preferences[memberId]!.budgetCap = value;
    _markDraft(memberId);
  }

  void updateWindow(
    String memberId, {
    DateTime? startAt,
    DateTime? endAt,
    int? start,
    int? end,
  }) {
    if (phase != TripPhase.collecting) return;
    final pref = preference(memberId);
    if (startAt != null) {
      pref.startAt = startAt;
    } else if (start != null) {
      pref.startMinute = start;
    }
    if (endAt != null) {
      pref.endAt = endAt;
    } else if (end != null) {
      pref.endMinute = end;
    }
    _markDraft(memberId);
  }

  void updateCustomTransport(String memberId, String value) {
    if (phase != TripPhase.collecting) return;
    preference(memberId).customTransport = value;
    _markDraft(memberId);
  }

  void toggleTransport(String memberId, String value) {
    if (phase != TripPhase.collecting) return;
    final choices = preference(memberId).transport;
    if (!choices.add(value)) choices.remove(value);
    _markDraft(memberId);
  }

  void toggleInterest(String memberId, String value) {
    if (phase != TripPhase.collecting) return;
    final choices = preference(memberId).interests;
    if (!choices.add(value)) choices.remove(value);
    _markDraft(memberId);
  }

  void toggleTaboo(String memberId, String value) {
    if (phase != TripPhase.collecting) return;
    final choices = preference(memberId).taboos;
    if (!choices.add(value)) choices.remove(value);
    _markDraft(memberId);
  }

  void _markDraft(String memberId) {
    submittedMembers.remove(memberId);
    votes.clear();
    notifyListeners();
  }

  bool submitPreferences() {
    final pref = preference(activeMemberId);
    if (phase != TripPhase.collecting ||
        !pref.endAt.isAfter(pref.startAt) ||
        pref.transport.isEmpty ||
        (pref.transport.contains('other') &&
            pref.customTransport.trim().isEmpty)) {
      return false;
    }
    submittedMembers.add(activeMemberId);
    notifyListeners();
    return true;
  }

  void reopenPreferences() {
    if (!isOrganizer || phase != TripPhase.confirming) return;
    phase = TripPhase.collecting;
    selectedCandidateId = null;
    confirmedMembers.clear();
    votes.clear();
    notifyListeners();
  }

  int voteCount(String candidateId) =>
      votes.values.where((vote) => vote == candidateId).length;

  bool hasVotedFor(String candidateId) => votes[activeMemberId] == candidateId;

  List<String> interestMatches(Map<String, dynamic> item) {
    const tagsByInterest = <String, Set<String>>{
      'movie': {'movie', 'cinema'},
      'shopping': {'shopping', 'mall'},
      'photo': {'photo_studio', 'plaza'},
      'outdoor': {'plaza'},
      'exhibition': {'gallery', 'gallery_indoor'},
      'museum': {'museum'},
      'craft': {'workshop'},
    };
    final placeTags = _maps(item['nodes'])
        .where((node) => node['kind'] == 'activity')
        .map((node) => node['place_tag'] as String?)
        .whereType<String>()
        .toSet();
    return members
        .where((person) {
          final pref = preference(person['member_id'] as String);
          return pref.interests.any(
            (interest) => (tagsByInterest[interest] ?? const <String>{}).any(
              placeTags.contains,
            ),
          );
        })
        .map((person) => person['display_name'] as String)
        .toList();
  }

  void toggleVote(String candidateId) {
    if (!allSubmitted ||
        phase != TripPhase.collecting ||
        checkCandidate(candidate(candidateId)).status !=
            CandidateStatus.feasible) {
      return;
    }
    if (votes[activeMemberId] == candidateId) {
      votes.remove(activeMemberId);
    } else {
      votes[activeMemberId] = candidateId;
    }
    notifyListeners();
  }

  CandidateCheck checkCandidate(Map<String, dynamic> item) {
    for (final person in members) {
      final id = person['member_id'] as String;
      final pref = preference(id);
      if (!pref.endAt.isAfter(pref.startAt) ||
          pref.transport.isEmpty ||
          (pref.transport.contains('other') &&
              pref.customTransport.trim().isEmpty)) {
        return CandidateCheck(
          CandidateStatus.incomplete,
          '请先补全${person['display_name']}的可用时间和交通方式。',
          memberId: id,
          ruleId: 'R-DATA-01',
        );
      }
    }

    final window = Map<String, dynamic>.from(item['window'] as Map);
    final start = RoomTime.parse(window['start'] as String);
    final end = RoomTime.parse(window['end'] as String);
    for (final person in members) {
      final id = person['member_id'] as String;
      final pref = preference(id);
      if (pref.startAt.isAfter(start) || pref.endAt.isBefore(end)) {
        return CandidateCheck(
          CandidateStatus.infeasible,
          '${person['display_name']}的可用时间无法覆盖整段行程。',
          memberId: id,
          ruleId: 'R-TIME-01',
        );
      }
    }

    final costs = Map<String, dynamic>.from(item['cost_per_member'] as Map);
    for (final person in members) {
      final id = person['member_id'] as String;
      final cost = costs[id] as int;
      final cap = preference(id).budgetCap;
      if (cost > cap) {
        final over = (cost - cap) ~/ 100;
        return CandidateCheck(
          CandidateStatus.infeasible,
          '${person['display_name']}承担 ¥${cost ~/ 100}，超过预算上限 ¥${cap ~/ 100}${over > 0 ? ' ¥$over' : ''}。',
          memberId: id,
          ruleId: 'R-BUD-01',
        );
      }
    }

    final nodes = _maps(item['nodes']);
    for (final person in members) {
      final id = person['member_id'] as String;
      final pref = preference(id);
      for (final node in nodes) {
        if (node['kind'] == 'transit' &&
            !pref.transport.contains(
              TransportCodes.normalize(node['transport'] as String),
            )) {
          return CandidateCheck(
            CandidateStatus.infeasible,
            '${person['display_name']}不接受${_transportName(node['transport'] as String, pref)}。',
            memberId: id,
            ruleId: 'R-TRANS-01',
          );
        }
        if (node['kind'] == 'activity' &&
            pref.taboos.contains(node['place_tag'])) {
          return CandidateCheck(
            CandidateStatus.infeasible,
            '${person['display_name']}的地点禁忌与「${node['place_tag']}」冲突。',
            memberId: id,
            ruleId: 'R-TABOO-01',
          );
        }
      }
    }

    return const CandidateCheck(CandidateStatus.feasible, '四人约束均满足。');
  }

  bool selectCandidate(String id) {
    if (!isOrganizer ||
        !allSubmitted ||
        phase == TripPhase.executing ||
        checkCandidate(candidate(id)).status != CandidateStatus.feasible) {
      return false;
    }
    if (selectedCandidateId == id) return true;
    selectedCandidateId = id;
    planVersion++;
    confirmedMembers.clear();
    phase = TripPhase.confirming;
    notifyListeners();
    return true;
  }

  bool confirmSelection() {
    if (phase != TripPhase.confirming || selectedCandidateId == null) {
      return false;
    }
    if (confirmedMembers.add(activeMemberId)) {
      confirmationHistory.add(
        PlanConfirmation(
          memberId: activeMemberId,
          version: currentVersion,
          confirmedAt: DateTime.now().toUtc(),
        ),
      );
    }
    notifyListeners();
    return true;
  }

  bool startTrip() {
    if (!isOrganizer ||
        phase != TripPhase.confirming ||
        !allConfirmed ||
        selectedCandidateId == null) {
      return false;
    }
    activeNodes = _maps(candidate(selectedCandidateId!)['nodes']);
    activeCosts = Map<String, int>.from(
      candidate(selectedCandidateId!)['cost_per_member'] as Map,
    );
    phase = TripPhase.executing;
    notifyListeners();
    return true;
  }

  RainPreview? previewRain({String? replacementId}) {
    rainFeedback = null;
    if (!isOrganizer ||
        phase != TripPhase.executing ||
        (pendingRain != null && replacementId == null) ||
        rainApplied ||
        selectedCandidateId != 'c02') {
      return null;
    }
    final targetId = rainTargetNodeId;
    if (targetId == null) return null;
    final node = activeNodes.firstWhere(
      (item) => item['node_id'] == targetId,
      orElse: () => <String, dynamic>{},
    );
    if (node.isEmpty || node['indoor'] == true) return null;

    final spec = rainReplacementOptions.firstWhere(
      (item) =>
          (item['replacement_id'] as String? ?? '') ==
          (replacementId ??
              (pendingRain?.replacementId ??
                  rainReplacementOptions.first['replacement_id'] as String?)),
      orElse: () => rainReplacementOptions.first,
    );
    final chosenId = spec['replacement_id'] as String? ?? 'rain-default';
    final sourceNode = Map<String, dynamic>.from(spec['node'] as Map);
    final replacementWindow = Map<String, dynamic>.from(
      rainEvent['window'] as Map,
    );
    final replacementStart = RoomTime.parse(
      replacementWindow['start'] as String,
    );
    final replacementEnd = RoomTime.parse(replacementWindow['end'] as String);
    final targetStart = RoomTime.parse(node['start'] as String);
    final targetEnd = RoomTime.parse(node['end'] as String);
    if (!replacementEnd.isAfter(replacementStart) ||
        !replacementStart.isBefore(targetEnd) ||
        !replacementEnd.isAfter(targetStart) ||
        spec['replaces'] != targetId) {
      return null;
    }
    final replacement = <String, dynamic>{
      ...sourceNode,
      'display_name':
          spec['display_name'] as String? ??
          _placeName(
            spec['node'] is Map
                ? (spec['node'] as Map)['place_tag'] as String? ?? ''
                : '',
          ),
    };
    final nextNodes = activeNodes
        .map((item) => item['node_id'] == targetId ? replacement : item)
        .toList();
    final check = checkCandidate({
      ...candidate(selectedCandidateId!),
      'nodes': nextNodes,
      'cost_per_member': spec['cost_per_member'],
    });
    if (check.status != CandidateStatus.feasible) {
      rainFeedback = check.message;
      return null;
    }
    pendingRain = RainPreview(
      previewId:
          'rain-preview-${DateTime.now().microsecondsSinceEpoch}-${++_previewSequence}',
      baseVersion: currentVersion,
      createdAt: DateTime.now().toUtc(),
      affectedNodeId: targetId,
      replacementId: chosenId,
      replacement: replacement,
      costPerMember: Map<String, int>.unmodifiable(
        Map<String, int>.from(spec['cost_per_member'] as Map),
      ),
      reason:
          '该户外活动与 $rainWindowLabel 的模拟降雨重叠，已选择「${replacement['display_name']}」，其他节点保留。',
    );
    selectedRainReplacementId = chosenId;
    notifyListeners();
    return pendingRain;
  }

  void cancelRain() {
    if (!isOrganizer) return;
    pendingRain = null;
    selectedRainReplacementId = null;
    notifyListeners();
  }

  bool applyRain() {
    final preview = pendingRain;
    if (!isOrganizer || preview == null || phase != TripPhase.executing) {
      return false;
    }
    if (preview.baseVersion != currentVersion ||
        activeNodes.every(
          (node) => node['node_id'] != preview.affectedNodeId,
        )) {
      rainFeedback = '此预览已过期，请按当前行程重新生成。';
      pendingRain = null;
      selectedRainReplacementId = null;
      notifyListeners();
      return false;
    }
    activeNodes = activeNodes.map((node) {
      if (node['node_id'] == preview.affectedNodeId) return preview.replacement;
      return node;
    }).toList();
    activeCosts = Map<String, int>.from(preview.costPerMember);
    pendingRain = null;
    selectedRainReplacementId = null;
    rainApplied = true;
    planVersion += 1;
    confirmedMembers.clear();
    changeApplications.add(
      ChangeApplication(
        actorMemberId: activeMemberId,
        baseVersion: preview.baseVersion,
        version: currentVersion,
        previewId: preview.previewId,
        confirmedAt: DateTime.now().toUtc(),
      ),
    );
    notifyListeners();
    return true;
  }
}

List<Map<String, dynamic>> _maps(dynamic source) => (source as List)
    .map((item) => Map<String, dynamic>.from(item as Map))
    .toList();

String _placeName(String tag) => switch (tag) {
  'gallery_indoor' => '室内摄影展厅',
  'cinema' => '电影院',
  'museum' => '室内博物馆',
  'workshop' => '手作工坊',
  _ => tag,
};

String _roomClock(String value) {
  final wall = RoomTime.toWallTime(RoomTime.parse(value));
  return '${wall.hour.toString().padLeft(2, '0')}:${wall.minute.toString().padLeft(2, '0')}';
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
            : '其他交通',
      _ => value,
    };
