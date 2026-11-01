import '../import/import_types.dart';

/// A library entry: the user's imported file plus metadata. Score data lives in its own file.
class Piece {
  final String id;
  String title;
  String? composer;
  final DateTime importedAt;
  DateTime updatedAt;
  DateTime? lastPracticedAt;
  ImportFormat format;

  /// Original file names as stored under the piece folder (one per page for multi-image imports).
  List<String> originals;

  /// Display name of the original file(s), for re-import messaging.
  String sourceName;
  bool favorite;

  /// 0..1 rough progress: best section-accuracy across measures practiced.
  double progress;
  int sessions;
  int practiceSeconds;
  bool needsReview;

  /// Last practice position (measure index) so the user can resume.
  int resumeMeasure;

  Piece({
    required this.id,
    required this.title,
    this.composer,
    required this.importedAt,
    required this.updatedAt,
    this.lastPracticedAt,
    required this.format,
    required this.originals,
    required this.sourceName,
    this.favorite = false,
    this.progress = 0,
    this.sessions = 0,
    this.practiceSeconds = 0,
    this.needsReview = false,
    this.resumeMeasure = 0,
  });

  Map<String, dynamic> toJson() => {
        'id': id,
        'title': title,
        if (composer != null) 'composer': composer,
        'importedAt': importedAt.toIso8601String(),
        'updatedAt': updatedAt.toIso8601String(),
        if (lastPracticedAt != null) 'lastPracticedAt': lastPracticedAt!.toIso8601String(),
        'format': format.name,
        'originals': originals,
        'sourceName': sourceName,
        'favorite': favorite,
        'progress': progress,
        'sessions': sessions,
        'practiceSeconds': practiceSeconds,
        'needsReview': needsReview,
        'resumeMeasure': resumeMeasure,
      };

  factory Piece.fromJson(Map<String, dynamic> j) => Piece(
        id: j['id'] as String,
        title: j['title'] as String? ?? 'Untitled',
        composer: j['composer'] as String?,
        importedAt: DateTime.parse(j['importedAt'] as String),
        updatedAt: DateTime.parse(j['updatedAt'] as String),
        lastPracticedAt: j['lastPracticedAt'] == null ? null : DateTime.parse(j['lastPracticedAt'] as String),
        format: ImportFormat.values.firstWhere((f) => f.name == j['format'], orElse: () => ImportFormat.unknown),
        originals: ((j['originals'] as List?) ?? const []).cast<String>(),
        sourceName: j['sourceName'] as String? ?? '',
        favorite: j['favorite'] as bool? ?? false,
        progress: (j['progress'] as num?)?.toDouble() ?? 0,
        sessions: j['sessions'] as int? ?? 0,
        practiceSeconds: j['practiceSeconds'] as int? ?? 0,
        needsReview: j['needsReview'] as bool? ?? false,
        resumeMeasure: j['resumeMeasure'] as int? ?? 0,
      );
}
