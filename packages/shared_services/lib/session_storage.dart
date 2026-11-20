/// Small string values that should outlive a page reload but not the
/// browser tab: `window.sessionStorage` on web, process memory elsewhere.
library;

export 'src/session_storage_stub.dart'
    if (dart.library.html) 'src/session_storage_web.dart';
