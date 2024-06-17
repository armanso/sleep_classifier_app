import 'dart:convert';

class SensorData {
  final int id;
  final int timestamp;
  final double x;
  final double y;
  final double z;

  SensorData({
    required this.id,
    required this.timestamp,
    required this.x,
    required this.y,
    required this.z,
  });

  factory SensorData.fromJson(Map<String, dynamic> json) {
    return SensorData(
      id: json['id'],
      timestamp: json['timestamp'],
      x: json['x'],
      y: json['y'],
      z: json['z'],
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'timestamp': timestamp,
      'x': x,
      'y': y,
      'z': z,
    };
  }

  String toCsvRow() {
    return '$timestamp,$x,$y,$z';
  }

  static List<SensorData> fromJsonList(String jsonString) {
    List<dynamic> jsonData = jsonDecode(jsonString);
    return jsonData.map((json) => SensorData.fromJson(json)).toList();
  }
}
