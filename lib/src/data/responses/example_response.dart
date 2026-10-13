import '../shared/types.dart';

/// Example resource model. Replace with real API models.
class ExampleResponse {
  final String id;
  final String title;
  final bool completed;

  ExampleResponse({
    required this.id,
    required this.title,
    required this.completed,
  });

  factory ExampleResponse.fromJson(JsonObject json) {
    return ExampleResponse(
      id: json.as<String>('id', ''),
      title: json.as<String>('title', ''),
      completed: json.as<bool>('completed', false),
    );
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'title': title,
        'completed': completed,
      };
}
