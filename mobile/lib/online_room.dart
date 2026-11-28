import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import 'room_time.dart';
import 'transport_codes.dart';

const _onlineInk = Color(0xFF252D2B);
const _onlineGreen = Color(0xFF3E6B60);
const _onlineLime = Color(0xFFD9F17B);
const _onlinePaper = Color(0xFFF5F6F3);
const _onlineMuted = Color(0xFF77827B);
const _defaultApiBase = 'http://192.168.1.10:8000/api/v0.1';

class RoomApiException implements Exception {
  const RoomApiException({
    required this.statusCode,
    required this.code,
    required this.message,
    this.details = const {},
  });

  final int statusCode;
  final String code;
  final String message;
  final Map<String, dynamic> details;

  String get displayMessage {
    if (statusCode == 0) return '暂时连不上服务，请检查地址、网络和服务状态后重试。';
    switch (code) {
      case 'MEMBER_TOKEN_INVALID':
        return '本机成员凭证已失效。请联系房间发起人确认服务数据后再恢复。';
      case 'FORBIDDEN':
        return '当前身份无权执行此操作。';
      case 'ROOM_FULL':
        return '房间已满，无法加入。';
      case 'INVALID_PHASE':
        return '房间当前阶段不接受此操作，请刷新房间状态。';
      case 'IDEMPOTENCY_CONFLICT':
        return '重试请求与原操作不一致，请刷新后重新发起操作。';
      case 'INVALID_INPUT':
        final fields = details['fields'];
        if (fields is List && fields.isNotEmpty) {
          final messages = fields
              .whereType<Map>()
              .map((field) => field['message']?.toString())
              .whereType<String>()
              .where((message) => message.isNotEmpty)
              .toSet()
              .toList();
          if (messages.isNotEmpty) return messages.join('；');
        }
        return message;
      default:
        return message;
    }
  }

  @override
  String toString() => displayMessage;
}

class RoomApiClient {
  RoomApiClient({required http.Client client, required this.baseUrl})
    : _client = client;

  final http.Client _client;
  final String baseUrl;

  String get normalizedBaseUrl => normalizeBaseUrl(baseUrl);

  static String normalizeBaseUrl(String value) {
    final uri = Uri.tryParse(value.trim());
    if (uri == null ||
        !uri.hasScheme ||
        !const {'http', 'https'}.contains(uri.scheme) ||
        uri.host.isEmpty ||
        uri.userInfo.isNotEmpty ||
        uri.hasQuery ||
        uri.hasFragment) {
      throw const FormatException('请输入有效的 http 或 https 服务地址。');
    }
    var path = uri.path.replaceFirst(RegExp(r'/+$'), '');
    if (!path.endsWith('/api/v0.1')) path = '$path/api/v0.1';
    return uri.replace(path: path, query: null, fragment: null).toString();
  }

  Future<Map<String, dynamic>> createRoom(
    Map<String, dynamic> payload,
    String idempotencyKey,
  ) => _request(
    'POST',
    '/rooms',
    payload: payload,
    idempotencyKey: idempotencyKey,
  );

  Future<Map<String, dynamic>> joinRoom(
    Map<String, dynamic> payload,
    String idempotencyKey,
  ) => _request(
    'POST',
    '/rooms/join',
    payload: payload,
    idempotencyKey: idempotencyKey,
  );

  Future<Map<String, dynamic>> savePreferences(
    String roomId,
    String token,
    Map<String, dynamic> payload,
  ) => _request(
    'PUT',
    '/rooms/${Uri.encodeComponent(roomId)}/preferences/me',
    payload: payload,
    token: token,
  );

  Future<RoomSnapshot> getSnapshot(String roomId, String token) async =>
      RoomSnapshot.fromJson(
        await _request(
          'GET',
          '/rooms/${Uri.encodeComponent(roomId)}',
          token: token,
        ),
      );

  Future<Map<String, dynamic>> _request(
    String method,
    String path, {
    Map<String, dynamic>? payload,
    String? token,
    String? idempotencyKey,
  }) async {
    final normalized = normalizeBaseUrl(baseUrl);
    final request = http.Request(
      method,
      Uri.parse('$normalized${path.startsWith('/') ? path : '/$path'}'),
    )..headers['Accept'] = 'application/json';
    if (payload != null) {
      request.headers['Content-Type'] = 'application/json';
      request.body = jsonEncode(payload);
    }
    if (token != null) request.headers['Authorization'] = 'Bearer $token';
    if (idempotencyKey != null) {
      request.headers['Idempotency-Key'] = idempotencyKey;
    }

    try {
      final streamed = await _client
          .send(request)
          .timeout(const Duration(seconds: 15));
      final response = await http.Response.fromStream(
        streamed,
      ).timeout(const Duration(seconds: 15));
      dynamic decoded;
      try {
        decoded = response.body.isEmpty
            ? <String, dynamic>{}
            : jsonDecode(response.body);
      } on FormatException {
        throw RoomApiException(
          statusCode: response.statusCode,
          code: 'INVALID_RESPONSE',
          message: '服务返回的数据无法读取。',
        );
      }
      if (decoded is! Map) {
        throw RoomApiException(
          statusCode: response.statusCode,
          code: 'INVALID_RESPONSE',
          message: '服务返回了不符合契约的数据。',
        );
      }
      final body = Map<String, dynamic>.from(decoded);
      if (response.statusCode < 200 || response.statusCode >= 300) {
        final error = body['error'];
        final errorMap = error is Map
            ? Map<String, dynamic>.from(error)
            : const {};
        final rawDetails = errorMap['details'];
        throw RoomApiException(
          statusCode: response.statusCode,
          code: errorMap['code']?.toString() ?? 'HTTP_ERROR',
          message: errorMap['message']?.toString() ?? '请求未完成。',
          details: rawDetails is Map
              ? Map<String, dynamic>.from(rawDetails)
              : const {},
        );
      }
      return body;
    } on TimeoutException {
      throw const RoomApiException(
        statusCode: 0,
        code: 'TIMEOUT',
        message: '请求超时。',
      );
    } on http.ClientException {
      throw const RoomApiException(
        statusCode: 0,
        code: 'NETWORK_ERROR',
        message: '网络连接失败。',
      );
    }
  }
}

class RoomIdentity {
  const RoomIdentity({
    required this.roomId,
    required this.memberId,
    required this.displayName,
    required this.role,
    required this.memberToken,
    this.inviteCode,
    this.tripDate,
  });

  final String roomId;
  final String memberId;
  final String displayName;
  final String role;
  final String memberToken;
  final String? inviteCode;
  final String? tripDate;

  factory RoomIdentity.fromResponse(
    Map<String, dynamic> json, {
    String? tripDate,
  }) {
    final member = Map<String, dynamic>.from(json['member'] as Map);
    return RoomIdentity(
      roomId: json['room_id'] as String,
      memberId: member['member_id'] as String,
      displayName: member['display_name'] as String,
      role: member['role'] as String,
      memberToken: json['member_token'] as String,
      inviteCode: json['invite_code'] as String?,
      tripDate: tripDate,
    );
  }

  factory RoomIdentity.fromJson(Map<String, dynamic> json) => RoomIdentity(
    roomId: json['room_id'] as String,
    memberId: json['member_id'] as String,
    displayName: json['display_name'] as String,
    role: json['role'] as String,
    memberToken: json['member_token'] as String,
    inviteCode: json['invite_code'] as String?,
    tripDate: json['trip_date'] as String?,
  );

  Map<String, dynamic> toJson() => {
    'room_id': roomId,
    'member_id': memberId,
    'display_name': displayName,
    'role': role,
    'member_token': memberToken,
    'invite_code': inviteCode,
    'trip_date': tripDate,
  };
}

class PendingRoomOperation {
  const PendingRoomOperation({
    required this.kind,
    required this.key,
    required this.payload,
  });

  final String kind;
  final String key;
  final Map<String, dynamic> payload;

  factory PendingRoomOperation.fromJson(Map<String, dynamic> json) =>
      PendingRoomOperation(
        kind: json['kind'] as String,
        key: json['key'] as String,
        payload: Map<String, dynamic>.from(json['payload'] as Map),
      );

  Map<String, dynamic> toJson() => {
    'kind': kind,
    'key': key,
    'payload': payload,
  };

  bool matches(String requestedKind, Map<String, dynamic> requestedPayload) =>
      kind == requestedKind &&
      jsonEncode(payload) == jsonEncode(requestedPayload);
}

abstract interface class RoomIdentityStore {
  Future<RoomIdentity?> loadIdentity();
  Future<void> saveIdentity(RoomIdentity identity);
  Future<void> clearIdentity();
  Future<PendingRoomOperation?> loadPendingOperation();
  Future<void> savePendingOperation(PendingRoomOperation operation);
  Future<void> clearPendingOperation();
  Future<String?> loadBaseUrl();
  Future<void> saveBaseUrl(String value);
  Future<Map<String, dynamic>?> loadPreferenceDraft(RoomIdentity identity);
  Future<void> savePreferenceDraft(
    RoomIdentity identity,
    Map<String, dynamic> payload,
  );
}

class SharedPreferencesRoomIdentityStore implements RoomIdentityStore {
  SharedPreferencesRoomIdentityStore(this._preferences);

  static const _identityKey = 'room.identity.v1';
  static const _pendingKey = 'room.pending-operation.v1';
  static const _baseUrlKey = 'room.api-base-url.v1';
  final SharedPreferences _preferences;

  static Future<SharedPreferencesRoomIdentityStore> create() async =>
      SharedPreferencesRoomIdentityStore(await SharedPreferences.getInstance());

  @override
  Future<RoomIdentity?> loadIdentity() async {
    final raw = _preferences.getString(_identityKey);
    if (raw == null) return null;
    try {
      return RoomIdentity.fromJson(
        Map<String, dynamic>.from(jsonDecode(raw) as Map),
      );
    } on Object {
      await clearIdentity();
      return null;
    }
  }

  @override
  Future<void> saveIdentity(RoomIdentity identity) async {
    await _preferences.setString(_identityKey, jsonEncode(identity.toJson()));
  }

  @override
  Future<void> clearIdentity() async {
    await _preferences.remove(_identityKey);
  }

  @override
  Future<PendingRoomOperation?> loadPendingOperation() async {
    final raw = _preferences.getString(_pendingKey);
    if (raw == null) return null;
    try {
      return PendingRoomOperation.fromJson(
        Map<String, dynamic>.from(jsonDecode(raw) as Map),
      );
    } on Object {
      await clearPendingOperation();
      return null;
    }
  }

  @override
  Future<void> savePendingOperation(PendingRoomOperation operation) async {
    await _preferences.setString(_pendingKey, jsonEncode(operation.toJson()));
  }

  @override
  Future<void> clearPendingOperation() async {
    await _preferences.remove(_pendingKey);
  }

  @override
  Future<String?> loadBaseUrl() async => _preferences.getString(_baseUrlKey);

  @override
  Future<void> saveBaseUrl(String value) async {
    await _preferences.setString(_baseUrlKey, value);
  }

  String _draftKey(RoomIdentity identity) =>
      'room.preferences.v1.${identity.roomId}.${identity.memberId}';

  @override
  Future<Map<String, dynamic>?> loadPreferenceDraft(
    RoomIdentity identity,
  ) async {
    final raw = _preferences.getString(_draftKey(identity));
    if (raw == null) return null;
    try {
      return Map<String, dynamic>.from(jsonDecode(raw) as Map);
    } on FormatException {
      return null;
    }
  }

  @override
  Future<void> savePreferenceDraft(
    RoomIdentity identity,
    Map<String, dynamic> payload,
  ) async {
    await _preferences.setString(_draftKey(identity), jsonEncode(payload));
  }
}

class RoomRepository {
  RoomRepository({required this.api, required this.store});

  final RoomApiClient api;
  final RoomIdentityStore store;

  Future<RoomIdentity> createRoom(Map<String, dynamic> payload) async =>
      _beginOrResume('create', payload);

  Future<RoomIdentity> joinRoom(Map<String, dynamic> payload) async =>
      _beginOrResume('join', payload);

  Future<RoomIdentity> retryPendingOperation() async {
    final pending = await store.loadPendingOperation();
    if (pending == null) throw StateError('没有待重试的建房或加入操作。');
    return _sendPending(pending);
  }

  Future<RoomIdentity> _beginOrResume(
    String kind,
    Map<String, dynamic> payload,
  ) async {
    await _checkServiceBinding();
    final pending = await store.loadPendingOperation();
    if (pending != null && !pending.matches(kind, payload)) {
      throw StateError('上次建房或加入尚未确认结果，请先用原请求重试。');
    }
    final operation =
        pending ??
        PendingRoomOperation(
          kind: kind,
          key: _newIdempotencyKey(),
          payload: Map<String, dynamic>.from(payload),
        );
    if (pending == null) {
      await store.saveBaseUrl(api.normalizedBaseUrl);
      await store.savePendingOperation(operation);
    }
    return _sendPending(operation);
  }

  Future<RoomIdentity> _sendPending(PendingRoomOperation operation) async {
    await _checkServiceBinding();
    try {
      final response = operation.kind == 'create'
          ? await api.createRoom(operation.payload, operation.key)
          : await api.joinRoom(operation.payload, operation.key);
      final identity = RoomIdentity.fromResponse(
        response,
        tripDate: operation.payload['trip_date'] as String?,
      );
      await store.saveIdentity(identity);
      await store.clearPendingOperation();
      return identity;
    } on RoomApiException catch (error) {
      if (error.statusCode >= 400 && error.statusCode < 500) {
        await store.clearPendingOperation();
      }
      rethrow;
    }
  }

  Future<Map<String, dynamic>> savePreferences(
    RoomIdentity identity,
    Map<String, dynamic> payload,
  ) async {
    await _checkServiceBinding();
    await store.savePreferenceDraft(identity, payload);
    return api.savePreferences(identity.roomId, identity.memberToken, payload);
  }

  Future<RoomSnapshot> refresh(RoomIdentity identity) async {
    await _checkServiceBinding();
    return api.getSnapshot(identity.roomId, identity.memberToken);
  }

  Future<void> _checkServiceBinding() async {
    final saved = await store.loadBaseUrl();
    if (saved != null &&
        RoomApiClient.normalizeBaseUrl(saved) != api.normalizedBaseUrl &&
        (await store.loadIdentity() != null ||
            await store.loadPendingOperation() != null)) {
      throw StateError('房间身份与原服务绑定，请先恢复原服务地址。');
    }
  }
}

String _newIdempotencyKey() {
  final random = Random.secure();
  final bytes = List<int>.generate(16, (_) => random.nextInt(256));
  bytes[6] = (bytes[6] & 0x0f) | 0x40;
  bytes[8] = (bytes[8] & 0x3f) | 0x80;
  final hex = bytes
      .map((byte) => byte.toRadixString(16).padLeft(2, '0'))
      .join();
  return '${hex.substring(0, 8)}-${hex.substring(8, 12)}-'
      '${hex.substring(12, 16)}-${hex.substring(16, 20)}-${hex.substring(20)}';
}

class RoomSnapshot {
  const RoomSnapshot({
    required this.roomId,
    required this.roomName,
    required this.tripDate,
    required this.timezone,
    required this.phase,
    required this.capacity,
    required this.organizerMemberId,
    required this.viewerMemberId,
    required this.members,
    required this.submittedCount,
    required this.requiredCount,
    required this.summary,
  });

  final String roomId;
  final String roomName;
  final String tripDate;
  final String timezone;
  final String phase;
  final int capacity;
  final String organizerMemberId;
  final String viewerMemberId;
  final List<RoomMember> members;
  final int submittedCount;
  final int requiredCount;
  final RoomSummary? summary;

  factory RoomSnapshot.fromJson(Map<String, dynamic> json) {
    final progress = Map<String, dynamic>.from(
      json['submission_progress'] as Map,
    );
    final summary = json['summary'];
    return RoomSnapshot(
      roomId: json['room_id'] as String,
      roomName: json['room_name'] as String,
      tripDate: json['trip_date'] as String,
      timezone: json['timezone'] as String,
      phase: json['phase'] as String,
      capacity: json['capacity'] as int,
      organizerMemberId: json['organizer_member_id'] as String,
      viewerMemberId: json['viewer_member_id'] as String,
      members: (json['members'] as List)
          .map(
            (member) =>
                RoomMember.fromJson(Map<String, dynamic>.from(member as Map)),
          )
          .toList(),
      submittedCount: progress['submitted_count'] as int,
      requiredCount: progress['required_count'] as int,
      summary: summary is Map
          ? RoomSummary.fromJson(Map<String, dynamic>.from(summary))
          : null,
    );
  }
}

class RoomMember {
  const RoomMember({
    required this.memberId,
    required this.displayName,
    required this.role,
    required this.submissionStatus,
  });

  final String memberId;
  final String displayName;
  final String role;
  final String submissionStatus;

  factory RoomMember.fromJson(Map<String, dynamic> json) => RoomMember(
    memberId: json['member_id'] as String,
    displayName: json['display_name'] as String,
    role: json['role'] as String,
    submissionStatus: json['submission_status'] as String,
  );
}

class RoomSummary {
  const RoomSummary({
    required this.commonWindows,
    required this.commonTransports,
    required this.minimumBudgetCents,
  });

  final List<RoomTimeWindow> commonWindows;
  final List<String> commonTransports;
  final int minimumBudgetCents;

  factory RoomSummary.fromJson(Map<String, dynamic> json) => RoomSummary(
    commonWindows: (json['common_windows'] as List)
        .map(
          (window) =>
              RoomTimeWindow.fromJson(Map<String, dynamic>.from(window as Map)),
        )
        .toList(),
    commonTransports: TransportCodes.normalizeAll(
      (json['common_allowed_transport'] as List).cast<String>(),
    ),
    minimumBudgetCents: json['min_budget_cap'] as int,
  );
}

class RoomTimeWindow {
  const RoomTimeWindow({required this.start, required this.end});

  final DateTime start;
  final DateTime end;

  factory RoomTimeWindow.fromJson(Map<String, dynamic> json) => RoomTimeWindow(
    start: RoomTime.parse(json['start'] as String),
    end: RoomTime.parse(json['end'] as String),
  );
}

int? parseYuanToCents(String value) {
  final normalized = value.trim();
  final match = RegExp(r'^(\d+)(?:\.(\d{1,2}))?$').firstMatch(normalized);
  if (match == null) return null;
  final yuan = int.tryParse(match.group(1)!);
  if (yuan == null) return null;
  final fraction = (match.group(2) ?? '').padRight(2, '0');
  final cents = int.parse(fraction.isEmpty ? '0' : fraction);
  if (yuan > (0x7fffffff - cents) ~/ 100) return null;
  return yuan * 100 + cents;
}

String transportDisplayName(String code) => switch (code) {
  'metro' => '地铁',
  'bus' => '公交',
  'taxi' => '打车',
  'walk' => '步行',
  'bicycle' => '自行车',
  _ => code,
};

const _preferenceTagAliases = {
  '摄影': 'photo',
  '拍照': 'photo',
  '电影': 'movie',
  '看电影': 'movie',
  '购物': 'shopping',
  '逛街': 'shopping',
  '户外': 'outdoor',
  '展览': 'exhibition',
  '博物馆': 'museum',
  '手作': 'craft',
  '商场': 'mall',
  '黄河': 'yellow_river',
};

List<String> _parseTags(String text) => text
    .split(RegExp(r'[,，、]'))
    .map((value) => value.trim())
    .where((value) => value.isNotEmpty)
    .map((value) => _preferenceTagAliases[value] ?? value)
    .toSet()
    .toList();

String _displayTags(Iterable<String> tags) => tags
    .map((tag) {
      for (final alias in _preferenceTagAliases.entries) {
        if (alias.value == tag) return alias.key;
      }
      return tag;
    })
    .join('、');

class OnlineRoomPage extends StatefulWidget {
  const OnlineRoomPage({this.store, this.httpClient, super.key});

  final RoomIdentityStore? store;
  final http.Client? httpClient;

  @override
  State<OnlineRoomPage> createState() => _OnlineRoomPageState();
}

class _OnlineRoomPageState extends State<OnlineRoomPage> {
  late final http.Client _httpClient = widget.httpClient ?? http.Client();
  late final bool _ownsHttpClient = widget.httpClient == null;
  RoomIdentityStore? _store;
  RoomIdentity? _identity;
  PendingRoomOperation? _pendingOperation;
  RoomSnapshot? _snapshot;
  String _baseUrl = _defaultApiBase;
  bool _initializing = true;
  bool _busy = false;
  bool _refreshing = false;
  bool _snapshotStale = false;
  bool _draftTouched = false;
  Map<String, dynamic> _restoredPreferencePayload = {};
  String? _error;
  String? _notice;

  final _baseUrlController = TextEditingController(text: _defaultApiBase);
  final _roomNameController = TextEditingController(text: '兰州半日游');
  final _displayNameController = TextEditingController();
  final _inviteController = TextEditingController();
  final _budgetController = TextEditingController(text: '80');
  final _tabooController = TextEditingController();
  final _interestController = TextEditingController();
  DateTime _tripDate = RoomTime.toWallTime(DateTime.now());
  DateTime? _startAt;
  DateTime? _endAt;
  final Set<String> _selectedTransport = {};
  bool _noTaboosConfirmed = false;

  RoomRepository get _repository => RoomRepository(
    api: RoomApiClient(client: _httpClient, baseUrl: _baseUrl),
    store: _store!,
  );

  @override
  void initState() {
    super.initState();
    _initialize();
  }

  Future<void> _initialize() async {
    try {
      _store =
          widget.store ?? await SharedPreferencesRoomIdentityStore.create();
      _baseUrl = await _store!.loadBaseUrl() ?? _defaultApiBase;
      _baseUrlController.text = _baseUrl;
      _identity = await _store!.loadIdentity();
      _pendingOperation = await _store!.loadPendingOperation();
      if (_identity?.tripDate != null) {
        final date = DateTime.tryParse(_identity!.tripDate!);
        if (date != null) _tripDate = date;
      }
      _resetPreferenceDraft();
      if (_identity != null) {
        final draft = await _store!.loadPreferenceDraft(_identity!);
        if (draft != null) _restorePreferenceDraft(draft);
      }
    } on Object catch (error) {
      _error = _friendlyError(error);
    } finally {
      if (mounted) setState(() => _initializing = false);
    }
    if (_identity != null) await _refresh(showSpinner: false);
  }

  @override
  void dispose() {
    _baseUrlController.dispose();
    _roomNameController.dispose();
    _displayNameController.dispose();
    _inviteController.dispose();
    _budgetController.dispose();
    _tabooController.dispose();
    _interestController.dispose();
    if (_ownsHttpClient) _httpClient.close();
    super.dispose();
  }

  void _resetPreferenceDraft() {
    final date = _identity?.tripDate != null
        ? DateTime.tryParse(_identity!.tripDate!) ??
              RoomTime.toWallTime(DateTime.now())
        : _tripDate;
    _tripDate = date;
    _startAt = RoomTime.fromWallTime(
      DateTime.utc(date.year, date.month, date.day, 13),
    );
    _endAt = RoomTime.fromWallTime(
      DateTime.utc(date.year, date.month, date.day, 17, 30),
    );
    _selectedTransport.clear();
    _noTaboosConfirmed = false;
    _tabooController.clear();
    _interestController.clear();
    _budgetController.text = '80';
    _draftTouched = false;
    _restoredPreferencePayload = {};
  }

  void _restorePreferenceDraft(Map<String, dynamic> payload) {
    final windows = payload['available_windows'] as List;
    final first = windows.first as Map;
    _startAt = RoomTime.parse(first['start'] as String);
    _endAt = RoomTime.parse(first['end'] as String);
    _budgetController.text = _formatCents(payload['budget_cap'] as int);
    _selectedTransport.addAll(
      TransportCodes.normalizeAll(
        (payload['allowed_transport'] as List).cast<String>(),
      ),
    );
    final taboos = (payload['taboo_tags'] as List).cast<String>();
    _noTaboosConfirmed = taboos.isEmpty;
    _tabooController.text = _displayTags(taboos);
    _interestController.text = _displayTags(
      (payload['interest_tags'] as List? ?? []).cast<String>(),
    );
    _restoredPreferencePayload = payload;
    _draftTouched = true;
  }

  Future<void> _saveBaseUrl() async {
    try {
      await _syncBaseUrl();
      setState(() {
        _error = null;
        _notice = '服务地址已保存。';
      });
      if (_identity != null) await _refresh(showSpinner: false);
    } on Object catch (error) {
      setState(() => _error = _friendlyError(error));
    }
  }

  Future<void> _syncBaseUrl() async {
    final normalized = RoomApiClient.normalizeBaseUrl(_baseUrlController.text);
    if ((_identity != null || _pendingOperation != null) &&
        normalized != RoomApiClient.normalizeBaseUrl(_baseUrl)) {
      throw StateError('当前房间与原服务地址绑定，请先清除本机凭证后切换服务。');
    }
    await _store?.saveBaseUrl(normalized);
    _baseUrl = normalized;
    _baseUrlController.text = normalized;
  }

  Future<void> _chooseTripDate() async {
    final date = await showDatePicker(
      context: context,
      initialDate: DateTime(_tripDate.year, _tripDate.month, _tripDate.day),
      firstDate: DateTime(2020),
      lastDate: DateTime(2035, 12, 31),
      helpText: '选择出行日期',
    );
    if (date != null && mounted) {
      setState(() {
        _draftTouched = true;
        _tripDate = date;
      });
    }
  }

  Future<void> _chooseRoomTime(bool isStart) async {
    final current = isStart ? _startAt : _endAt;
    final initial = RoomTime.toWallTime(
      current ??
          RoomTime.fromWallTime(
            DateTime.utc(
              _tripDate.year,
              _tripDate.month,
              _tripDate.day,
              isStart ? 13 : 17,
            ),
          ),
    );
    final date = await showDatePicker(
      context: context,
      initialDate: DateTime(initial.year, initial.month, initial.day),
      firstDate: DateTime(2020),
      lastDate: DateTime(2035, 12, 31),
      helpText: isStart ? '选择最早出发日期' : '选择最晚返程日期',
    );
    if (date == null || !mounted) return;
    final time = await showTimePicker(
      context: context,
      initialTime: TimeOfDay(hour: initial.hour, minute: initial.minute),
      helpText: isStart ? '选择最早出发时间' : '选择最晚返程时间',
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(context).copyWith(alwaysUse24HourFormat: true),
        child: child!,
      ),
    );
    if (time == null || !mounted) return;
    final instant = RoomTime.fromWallTime(
      DateTime.utc(date.year, date.month, date.day, time.hour, time.minute),
    );
    setState(() {
      _draftTouched = true;
      if (isStart) {
        _startAt = instant;
      } else {
        _endAt = instant;
      }
    });
  }

  Future<void> _createRoom() async {
    final displayName = _displayNameController.text.trim();
    final roomName = _roomNameController.text.trim();
    if (roomName.isEmpty || displayName.isEmpty) {
      _reportError(StateError('请填写房间名称和你的显示名。'));
      return;
    }
    await _performMembershipOperation(
      () => _repository.createRoom({
        'room_name': roomName,
        'display_name': displayName,
        'trip_date': _dateOnly(_tripDate),
        'timezone': 'Asia/Shanghai',
      }),
    );
  }

  Future<void> _joinRoom() async {
    final displayName = _displayNameController.text.trim();
    final inviteCode = _inviteController.text.trim();
    if (displayName.isEmpty || inviteCode.isEmpty) {
      _reportError(StateError('请填写显示名和邀请码。'));
      return;
    }
    await _performMembershipOperation(
      () => _repository.joinRoom({
        'invite_code': inviteCode,
        'display_name': displayName,
      }),
    );
  }

  Future<void> _performMembershipOperation(
    Future<RoomIdentity> Function() operation,
  ) async {
    if (_store == null || _busy) return;
    setState(() {
      _busy = true;
      _error = null;
      _notice = null;
    });
    try {
      await _syncBaseUrl();
      final identity = await operation();
      _identity = identity;
      _pendingOperation = null;
      _resetPreferenceDraft();
      if (mounted) setState(() => _notice = '已连接房间，正在读取最新快照。');
      await _refresh(showSpinner: false);
    } on Object catch (error) {
      _pendingOperation = await _store!.loadPendingOperation();
      _reportError(error);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _retryPendingOperation() async {
    if (_store == null || _busy) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      _identity = await _repository.retryPendingOperation();
      _pendingOperation = null;
      _resetPreferenceDraft();
      await _refresh(showSpinner: false);
    } on Object catch (error) {
      _pendingOperation = await _store!.loadPendingOperation();
      _reportError(error);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _refresh({bool showSpinner = true}) async {
    final identity = _identity;
    if (_store == null || identity == null || _refreshing) return;
    if (mounted) {
      setState(() {
        _refreshing = true;
        _error = null;
      });
    }
    try {
      await _syncBaseUrl();
      final snapshot = await _repository.refresh(identity);
      if (!mounted) return;
      final firstSnapshot = _snapshot == null;
      setState(() {
        _snapshot = snapshot;
        _refreshing = false;
        _snapshotStale = false;
        _notice = '已同步 · ${RoomTime.format(DateTime.now().toUtc())}';
        if (firstSnapshot && !_draftTouched) {
          _tripDate = DateTime.parse(snapshot.tripDate);
          _resetPreferenceDraft();
        }
      });
    } on Object catch (error) {
      if (!mounted) return;
      setState(() {
        _refreshing = false;
        _snapshotStale = _snapshot != null;
        _error = _friendlyError(error);
      });
    }
  }

  Future<void> _savePreferences() async {
    final identity = _identity;
    if (identity == null || _store == null || _busy || _refreshing) return;
    final budgetCents = parseYuanToCents(_budgetController.text);
    final start = _startAt;
    final end = _endAt;
    if (start == null || end == null || !end.isAfter(start)) {
      _reportError(StateError('请设置有效时间，结束时间必须晚于开始时间。'));
      return;
    }
    if (budgetCents == null) {
      _reportError(StateError('预算请输入非负金额，最多保留两位小数。'));
      return;
    }
    if (_selectedTransport.isEmpty) {
      _reportError(StateError('请至少选择一种可接受的交通方式。'));
      return;
    }
    final tabooTags = _parseTags(_tabooController.text);
    if (!_noTaboosConfirmed && tabooTags.isEmpty) {
      _reportError(StateError('请明确勾选“没有地点禁忌”，或填写不想去的地点。'));
      return;
    }
    final interestTags = _parseTags(_interestController.text);
    final payload = <String, dynamic>{
      ..._restoredPreferencePayload,
      'available_windows': [
        {'start': RoomTime.toIso8601(start), 'end': RoomTime.toIso8601(end)},
      ],
      'budget_cap': budgetCents,
      'budget_basis': {
        'includes_transport': true,
        'scope': 'per_person',
        'share_rule': null,
      },
      'allowed_transport': TransportCodes.normalizeAll(_selectedTransport),
      'taboo_tags': _noTaboosConfirmed ? <String>[] : tabooTags,
      'must_visit_tags':
          _restoredPreferencePayload['must_visit_tags'] ?? <String>[],
      'interest_tags': interestTags,
      'interest_weight':
          _restoredPreferencePayload['interest_weight'] ?? <String, int>{},
      'walk_tolerance': _restoredPreferencePayload['walk_tolerance'] ?? 0,
      'declared_level':
          _restoredPreferencePayload['declared_level'] ??
          <String, String>{
            'must_return_by': 'must',
            'budget_cap': 'must',
            'transport': 'must',
            'must_visit': 'none',
            'walk': 'prefer',
          },
    };
    setState(() {
      _busy = true;
      _error = null;
      _notice = null;
    });
    try {
      await _syncBaseUrl();
      await _repository.savePreferences(identity, payload);
      if (!mounted) return;
      setState(() => _notice = '偏好已保存，正在刷新房间进度。');
      await _refresh(showSpinner: false);
    } on Object catch (error) {
      _reportError(error);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _forgetIdentity() async {
    final accepted =
        await showDialog<bool>(
          context: context,
          builder: (context) => AlertDialog(
            title: const Text('清除本机房间身份？'),
            content: const Text('这只会清除本机保存的房间凭证，不会从服务器删除成员，也不会释放房间名额。'),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context, false),
                child: const Text('取消'),
              ),
              FilledButton(
                onPressed: () => Navigator.pop(context, true),
                child: const Text('清除本机凭证'),
              ),
            ],
          ),
        ) ??
        false;
    if (!accepted || _store == null || !mounted) return;
    await _store!.clearIdentity();
    await _store!.clearPendingOperation();
    if (!mounted) return;
    setState(() {
      _identity = null;
      _snapshot = null;
      _pendingOperation = null;
      _snapshotStale = false;
      _error = null;
      _notice = '本机凭证已清除。服务器中的成员记录仍保留。';
      _resetPreferenceDraft();
    });
  }

  String _friendlyError(Object error) {
    if (error is RoomApiException) return error.displayMessage;
    if (error is FormatException) return error.message;
    if (error is StateError) return error.message;
    return '操作未完成，请检查填写内容和服务状态后重试。';
  }

  void _reportError(Object error) {
    if (!mounted) return;
    final message = _friendlyError(error);
    setState(() => _error = message);
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: _onlinePaper,
      appBar: AppBar(
        title: const Text('同行房间'),
        backgroundColor: _onlinePaper,
        foregroundColor: _onlineInk,
        actions: [
          if (_identity != null)
            IconButton(
              tooltip: '刷新房间快照',
              onPressed: _busy || _refreshing ? null : () => _refresh(),
              icon: _refreshing
                  ? const SizedBox.square(
                      dimension: 19,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.refresh_rounded),
            ),
        ],
      ),
      body: _initializing
          ? const Center(child: CircularProgressIndicator(color: _onlineInk))
          : SafeArea(
              top: false,
              child: Center(
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 720),
                  child: ListView(
                    padding: const EdgeInsets.fromLTRB(18, 6, 18, 28),
                    children: [
                      _connectionCard(),
                      if (_error != null) ...[
                        const SizedBox(height: 12),
                        _MessageCard(_error!, isError: true),
                      ],
                      if (_notice != null && _error == null) ...[
                        const SizedBox(height: 12),
                        _MessageCard(_notice!),
                      ],
                      if (_identity == null) ...[
                        const SizedBox(height: 16),
                        if (_pendingOperation != null) _pendingCard(),
                        _membershipCard(),
                      ] else ...[
                        const SizedBox(height: 16),
                        _roomCard(),
                        const SizedBox(height: 14),
                        _preferenceCard(),
                      ],
                    ],
                  ),
                ),
              ),
            ),
    );
  }

  Widget _connectionCard() => _Panel(
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text(
          '服务地址',
          style: TextStyle(
            color: _onlineInk,
            fontSize: 15,
            fontWeight: FontWeight.w800,
          ),
        ),
        const SizedBox(height: 5),
        const Text(
          '手机需能访问服务电脑；地址应包含 /api/v0.1。',
          style: TextStyle(color: _onlineMuted, fontSize: 12),
        ),
        const SizedBox(height: 10),
        Row(
          children: [
            Expanded(
              child: TextField(
                key: const Key('online-service-url'),
                controller: _baseUrlController,
                enabled:
                    !_busy &&
                    !_refreshing &&
                    _identity == null &&
                    _pendingOperation == null,
                keyboardType: TextInputType.url,
                decoration: const InputDecoration(
                  hintText: 'http://192.168.x.x:8000/api/v0.1',
                  isDense: true,
                  border: OutlineInputBorder(),
                ),
              ),
            ),
            const SizedBox(width: 8),
            FilledButton.tonal(
              onPressed:
                  _busy ||
                      _refreshing ||
                      _identity != null ||
                      _pendingOperation != null
                  ? null
                  : _saveBaseUrl,
              child: const Text('保存'),
            ),
          ],
        ),
      ],
    ),
  );

  Widget _membershipCard() => _Panel(
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const Text(
          '开始一起计划',
          style: TextStyle(
            color: _onlineInk,
            fontSize: 19,
            fontWeight: FontWeight.w800,
          ),
        ),
        const SizedBox(height: 4),
        const Text(
          '建房后分享邀请码，或加入朋友创建的房间。',
          style: TextStyle(color: _onlineMuted, fontSize: 12),
        ),
        const SizedBox(height: 16),
        TextField(
          controller: _displayNameController,
          textInputAction: TextInputAction.next,
          decoration: const InputDecoration(
            labelText: '你的显示名',
            border: OutlineInputBorder(),
            isDense: true,
          ),
        ),
        const SizedBox(height: 15),
        const _OnlineSectionTitle('创建房间'),
        const SizedBox(height: 8),
        TextField(
          controller: _roomNameController,
          textInputAction: TextInputAction.next,
          decoration: const InputDecoration(
            labelText: '房间名称',
            border: OutlineInputBorder(),
            isDense: true,
          ),
        ),
        const SizedBox(height: 8),
        OutlinedButton.icon(
          onPressed: _busy ? null : _chooseTripDate,
          icon: const Icon(Icons.calendar_month_outlined),
          label: Text('出行日期  ${_dateOnly(_tripDate)} · Asia/Shanghai'),
        ),
        const SizedBox(height: 7),
        FilledButton.icon(
          onPressed: _busy || _pendingOperation != null ? null : _createRoom,
          icon: const Icon(Icons.add_home_work_outlined),
          label: const Text('创建房间'),
        ),
        const Divider(height: 27),
        const _OnlineSectionTitle('加入房间'),
        const SizedBox(height: 8),
        TextField(
          controller: _inviteController,
          textCapitalization: TextCapitalization.characters,
          decoration: const InputDecoration(
            labelText: '邀请码',
            border: OutlineInputBorder(),
            isDense: true,
          ),
        ),
        const SizedBox(height: 9),
        OutlinedButton.icon(
          onPressed: _busy || _pendingOperation != null ? null : _joinRoom,
          icon: const Icon(Icons.group_add_outlined),
          label: const Text('输入邀请码加入'),
        ),
        if (_busy) ...[
          const SizedBox(height: 12),
          const LinearProgressIndicator(color: _onlineGreen),
        ],
      ],
    ),
  );

  Widget _pendingCard() {
    final pending = _pendingOperation!;
    final kind = pending.kind == 'create' ? '建房' : '加入房间';
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: _Panel(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Text(
              '上次请求尚未确认结果',
              style: TextStyle(
                color: _onlineInk,
                fontWeight: FontWeight.w800,
                fontSize: 15,
              ),
            ),
            const SizedBox(height: 5),
            Text(
              '为避免重复创建身份，重试时会沿用原请求和同一个幂等键。',
              style: TextStyle(color: _onlineMuted, fontSize: 12),
            ),
            const SizedBox(height: 10),
            FilledButton.icon(
              onPressed: _busy ? null : _retryPendingOperation,
              icon: const Icon(Icons.replay_rounded),
              label: Text('重试$kind'),
            ),
          ],
        ),
      ),
    );
  }

  Widget _roomCard() {
    final identity = _identity!;
    final snapshot = _snapshot;
    final progress = snapshot == null
        ? null
        : '${snapshot.submittedCount}/${snapshot.requiredCount}';
    return _Panel(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Expanded(
                child: Text(
                  '共享房间',
                  style: TextStyle(
                    color: _onlineInk,
                    fontSize: 19,
                    fontWeight: FontWeight.w800,
                  ),
                ),
              ),
              if (progress != null) _ProgressPill(label: '$progress 已提交'),
            ],
          ),
          const SizedBox(height: 5),
          Text(
            snapshot?.roomName ?? '房间 ${identity.roomId}',
            style: const TextStyle(color: _onlineMuted, fontSize: 13),
          ),
          const SizedBox(height: 12),
          _FactRow(label: '房间编号', value: identity.roomId),
          _FactRow(
            label: '本机身份',
            value:
                '${identity.displayName} · ${identity.memberId}${identity.role == 'organizer' ? ' · 发起人' : ''}',
          ),
          _FactRow(label: '出行时区', value: snapshot?.timezone ?? 'Asia/Shanghai'),
          if (identity.inviteCode != null)
            Row(
              children: [
                const SizedBox(
                  width: 84,
                  child: Text('邀请码', style: _factLabel),
                ),
                Expanded(
                  child: Text(
                    identity.inviteCode!,
                    style: const TextStyle(
                      color: _onlineInk,
                      fontWeight: FontWeight.w800,
                      letterSpacing: 1.2,
                    ),
                  ),
                ),
                IconButton(
                  tooltip: '复制邀请码',
                  visualDensity: VisualDensity.compact,
                  onPressed: () async {
                    await Clipboard.setData(
                      ClipboardData(text: identity.inviteCode!),
                    );
                    if (mounted) setState(() => _notice = '邀请码已复制。');
                  },
                  icon: const Icon(Icons.copy_rounded, size: 17),
                ),
              ],
            ),
          const SizedBox(height: 13),
          if (snapshot == null)
            const Text(
              '尚未取得快照。点击刷新重试。',
              style: TextStyle(color: _onlineMuted, fontSize: 12),
            )
          else ...[
            if (_snapshotStale)
              const Padding(
                padding: EdgeInsets.only(bottom: 8),
                child: Text(
                  '当前显示上次成功读取的快照，内容可能已过期。',
                  style: TextStyle(color: Color(0xFF8D5B1D), fontSize: 11),
                ),
              ),
            ClipRRect(
              borderRadius: BorderRadius.circular(9),
              child: LinearProgressIndicator(
                value: snapshot.requiredCount == 0
                    ? 0
                    : snapshot.submittedCount / snapshot.requiredCount,
                minHeight: 7,
                color: _onlineGreen,
                backgroundColor: const Color(0xFFE7EBE5),
              ),
            ),
            const SizedBox(height: 11),
            ...snapshot.members.map(
              (member) => _MemberStatusRow(
                member: member,
                isViewer: member.memberId == snapshot.viewerMemberId,
              ),
            ),
            const SizedBox(height: 8),
            _summaryPanel(snapshot),
          ],
          const SizedBox(height: 10),
          Wrap(
            spacing: 8,
            runSpacing: 7,
            children: [
              OutlinedButton.icon(
                onPressed: _busy || _refreshing ? null : () => _refresh(),
                icon: const Icon(Icons.refresh_rounded),
                label: Text(_refreshing ? '同步中…' : '刷新快照'),
              ),
              TextButton.icon(
                onPressed: _busy || _refreshing ? null : _forgetIdentity,
                icon: const Icon(Icons.logout_rounded),
                label: const Text('清除本机凭证'),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _summaryPanel(RoomSnapshot snapshot) {
    final summary = snapshot.summary;
    if (summary == null) {
      return const _SummaryTile(
        title: '共同条件汇总',
        text: '四位成员都提交后显示；每个人仍以自己的原始偏好为准。',
      );
    }
    final windows = summary.commonWindows.isEmpty
        ? '目前没有共同可用时间'
        : summary.commonWindows
              .map(
                (window) =>
                    '${RoomTime.format(window.start)}–${RoomTime.format(window.end)}',
              )
              .join('、');
    final transports = summary.commonTransports.isEmpty
        ? '目前没有共同交通方式'
        : summary.commonTransports.map(transportDisplayName).join('、');
    return _SummaryTile(
      title: '四人共同条件 · 仅用于快照展示',
      text:
          '时间：$windows\n交通：$transports\n最低个人预算：¥${_formatCents(summary.minimumBudgetCents)}（含往返）',
    );
  }

  Widget _preferenceCard() {
    final snapshot = _snapshot;
    final alreadySubmitted =
        snapshot?.members.any(
          (member) =>
              member.memberId == _identity!.memberId &&
              member.submissionStatus == 'submitted',
        ) ??
        false;
    return _Panel(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            alreadySubmitted ? '修改我的偏好' : '填写我的偏好',
            style: const TextStyle(
              color: _onlineInk,
              fontSize: 18,
              fontWeight: FontWeight.w800,
            ),
          ),
          const SizedBox(height: 5),
          const Text(
            '提交完整表单只更新本机身份；预算按个人口径并包含往返交通。',
            style: TextStyle(color: _onlineMuted, fontSize: 12),
          ),
          const SizedBox(height: 14),
          const _OnlineSectionTitle('可出行时间 · Asia/Shanghai'),
          const SizedBox(height: 7),
          Row(
            children: [
              Expanded(child: _timeButton('最早出发', _startAt, true)),
              const SizedBox(width: 8),
              Expanded(child: _timeButton('最晚返程', _endAt, false)),
            ],
          ),
          const SizedBox(height: 13),
          TextField(
            key: const Key('online-budget'),
            controller: _budgetController,
            onChanged: (_) => _draftTouched = true,
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            inputFormatters: [
              FilteringTextInputFormatter.allow(RegExp(r'[0-9.]')),
            ],
            decoration: const InputDecoration(
              labelText: '个人预算上限（元）',
              helperText: '含往返交通，每人分别填写；最多两位小数。',
              border: OutlineInputBorder(),
              isDense: true,
            ),
          ),
          const SizedBox(height: 13),
          const _OnlineSectionTitle('可接受的交通方式'),
          const SizedBox(height: 4),
          Wrap(
            spacing: 7,
            runSpacing: 5,
            children: TransportCodes.canonical.map((code) {
              return FilterChip(
                label: Text(transportDisplayName(code)),
                selected: _selectedTransport.contains(code),
                onSelected: (selected) => setState(() {
                  _draftTouched = true;
                  if (selected) {
                    _selectedTransport.add(code);
                  } else {
                    _selectedTransport.remove(code);
                  }
                }),
              );
            }).toList(),
          ),
          const SizedBox(height: 11),
          const _OnlineSectionTitle('不想去的地点'),
          CheckboxListTile(
            contentPadding: EdgeInsets.zero,
            dense: true,
            value: _noTaboosConfirmed,
            title: const Text('我明确没有地点禁忌'),
            controlAffinity: ListTileControlAffinity.leading,
            onChanged: (value) => setState(() {
              _draftTouched = true;
              _noTaboosConfirmed = value ?? false;
              if (_noTaboosConfirmed) _tabooController.clear();
            }),
          ),
          if (!_noTaboosConfirmed)
            TextField(
              controller: _tabooController,
              onChanged: (_) => _draftTouched = true,
              decoration: const InputDecoration(
                labelText: '填写不想去的地点标签',
                hintText: '多个标签用逗号分开',
                border: OutlineInputBorder(),
                isDense: true,
              ),
            ),
          const SizedBox(height: 10),
          TextField(
            controller: _interestController,
            onChanged: (_) => _draftTouched = true,
            decoration: const InputDecoration(
              labelText: '感兴趣的活动（可选）',
              hintText: '例如：摄影、看电影',
              border: OutlineInputBorder(),
              isDense: true,
            ),
          ),
          const SizedBox(height: 13),
          FilledButton.icon(
            onPressed: _busy || _refreshing ? null : _savePreferences,
            icon: const Icon(Icons.cloud_upload_outlined),
            label: Text(alreadySubmitted ? '保存修改并刷新' : '提交我的偏好'),
          ),
          if (_busy) ...[
            const SizedBox(height: 10),
            const LinearProgressIndicator(color: _onlineGreen),
          ],
        ],
      ),
    );
  }

  Widget _timeButton(String label, DateTime? value, bool isStart) =>
      OutlinedButton(
        onPressed: _busy ? null : () => _chooseRoomTime(isStart),
        style: OutlinedButton.styleFrom(
          padding: const EdgeInsets.symmetric(vertical: 11, horizontal: 9),
          alignment: Alignment.centerLeft,
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              label,
              style: const TextStyle(color: _onlineMuted, fontSize: 11),
            ),
            const SizedBox(height: 4),
            Text(
              value == null ? '选择日期与时间' : RoomTime.format(value),
              style: const TextStyle(
                color: _onlineInk,
                fontWeight: FontWeight.w700,
                fontSize: 12,
              ),
            ),
          ],
        ),
      );
}

String _dateOnly(DateTime value) =>
    '${value.year.toString().padLeft(4, '0')}-'
    '${value.month.toString().padLeft(2, '0')}-'
    '${value.day.toString().padLeft(2, '0')}';

String _formatCents(int cents) =>
    '${cents ~/ 100}${cents % 100 == 0 ? '' : '.${(cents % 100).toString().padLeft(2, '0')}'}';

class _Panel extends StatelessWidget {
  const _Panel({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.all(16),
    decoration: BoxDecoration(
      color: Colors.white,
      borderRadius: BorderRadius.circular(16),
      border: Border.all(color: const Color(0xFFE4E8DE)),
    ),
    child: child,
  );
}

class _OnlineSectionTitle extends StatelessWidget {
  const _OnlineSectionTitle(this.title);

  final String title;

  @override
  Widget build(BuildContext context) => Text(
    title,
    style: const TextStyle(
      color: _onlineInk,
      fontSize: 13,
      fontWeight: FontWeight.w800,
    ),
  );
}

class _FactRow extends StatelessWidget {
  const _FactRow({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: 6),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(width: 84, child: Text(label, style: _factLabel)),
        Expanded(
          child: Text(
            value,
            style: const TextStyle(
              color: _onlineInk,
              fontSize: 12,
              fontWeight: FontWeight.w600,
            ),
          ),
        ),
      ],
    ),
  );
}

const _factLabel = TextStyle(color: _onlineMuted, fontSize: 12);

class _ProgressPill extends StatelessWidget {
  const _ProgressPill({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
    decoration: BoxDecoration(
      color: _onlineLime.withValues(alpha: .55),
      borderRadius: BorderRadius.circular(20),
    ),
    child: Text(
      label,
      style: const TextStyle(
        color: _onlineInk,
        fontWeight: FontWeight.w800,
        fontSize: 11,
      ),
    ),
  );
}

class _MemberStatusRow extends StatelessWidget {
  const _MemberStatusRow({required this.member, required this.isViewer});

  final RoomMember member;
  final bool isViewer;

  @override
  Widget build(BuildContext context) {
    final submitted = member.submissionStatus == 'submitted';
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        children: [
          Icon(
            submitted ? Icons.check_circle : Icons.radio_button_unchecked,
            size: 17,
            color: submitted ? _onlineGreen : const Color(0xFFB9C1B8),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              '${member.displayName} · ${member.memberId}${member.role == 'organizer' ? ' · 发起人' : ''}${isViewer ? ' · 本机' : ''}',
              style: const TextStyle(color: _onlineInk, fontSize: 12),
            ),
          ),
          Text(
            submitted ? '已提交' : '待提交',
            style: TextStyle(
              color: submitted ? _onlineGreen : _onlineMuted,
              fontSize: 11,
              fontWeight: FontWeight.w700,
            ),
          ),
        ],
      ),
    );
  }
}

class _SummaryTile extends StatelessWidget {
  const _SummaryTile({required this.title, required this.text});

  final String title;
  final String text;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.all(13),
    decoration: BoxDecoration(
      color: const Color(0xFFE6EFEE),
      borderRadius: BorderRadius.circular(12),
    ),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          title,
          style: const TextStyle(
            color: _onlineInk,
            fontSize: 12,
            fontWeight: FontWeight.w800,
          ),
        ),
        const SizedBox(height: 5),
        Text(
          text,
          style: const TextStyle(color: _onlineInk, fontSize: 12, height: 1.55),
        ),
      ],
    ),
  );
}

class _MessageCard extends StatelessWidget {
  const _MessageCard(this.message, {this.isError = false});

  final String message;
  final bool isError;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.all(13),
    decoration: BoxDecoration(
      color: isError ? const Color(0xFFFFECE8) : const Color(0xFFE6EFEE),
      borderRadius: BorderRadius.circular(12),
    ),
    child: Text(
      message,
      style: TextStyle(
        color: isError ? const Color(0xFF8D3425) : _onlineGreen,
        fontSize: 12,
        height: 1.4,
      ),
    ),
  );
}
