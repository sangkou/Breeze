import 'package:zephyr/util/json/json_value.dart';

class UnifiedPluginEnvelope {
  const UnifiedPluginEnvelope({
    required this.source,
    required this.scheme,
    required this.data,
    required this.extern,
  });

  final String source;
  final Map<String, dynamic> scheme;
  final Map<String, dynamic> data;
  final Map<String, dynamic> extern;

  factory UnifiedPluginEnvelope.fromMap(
    Map<String, dynamic> map, {
    required String source,
  }) {
    return UnifiedPluginEnvelope(
      source: source.trim(),
      scheme: asJsonMap(map['scheme']),
      data: asJsonMap(map['data']),
      extern: asJsonMap(map['extern']),
    );
  }
}
