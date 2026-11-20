/// Saving bytes the app made (a CSV, a zip) as a file the user keeps: a
/// browser download on web, the platform share sheet on mobile and desktop
/// (Save to Files, AirDrop, email; see file_share_io.dart).
///
/// It writes nothing to Firestore, Storage or the network, so apps whose
/// security tier depends on reaching data only through callables
/// (scripts/security_tier_audit/audited_callables.js READ_ONLY_FACADES) can
/// use it. [PlatformService.downloadBytes] and csv_export.dart's
/// downloadCsv both save through it.
library;

export 'save_bytes_web.dart' if (dart.library.io) 'save_bytes_io.dart';
