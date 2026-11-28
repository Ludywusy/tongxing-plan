/// Shared transport values used by the API and planner.
class TransportCodes {
  TransportCodes._();

  static const List<String> canonical = [
    'metro',
    'bus',
    'taxi',
    'walk',
    'bicycle',
  ];

  /// The old `bike` spelling is accepted only as a migration alias.
  /// Other values keep their exact spelling so invalid case variants such as
  /// `Metro` are not silently treated as the canonical `metro` code.
  static String normalize(String value) => value == 'bike' ? 'bicycle' : value;

  static List<String> normalizeAll(Iterable<String> values) =>
      values.map(normalize).toSet().toList();
}
