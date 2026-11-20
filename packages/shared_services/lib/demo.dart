/// The demo predicate, mirrored from functions/_demo.js: whether a group or a
/// user exists only to show bluejay off (the Sunnyside demo group and its
/// demo accounts, plans/add-apps/OVERVIEW.md §5).
///
/// Both docs carry `isDemo: true`, set only by the Admin SDK
/// (scripts/demo/setup.js): `groups` is server-written and `users.isDemo` is
/// a serverField in security/collections.json. Client reports that count or
/// flag real groups (Security Audit's group violations, for one) leave demo
/// groups out through these.
library;

/// The field both group and user docs carry.
const String demoField = 'isDemo';

/// Whether a group doc's data marks it as a demo group.
bool isDemoGroup(Map<String, dynamic>? groupData) =>
    groupData != null && groupData[demoField] == true;

/// Whether a users doc's data marks it as a demo account.
bool isDemoUser(Map<String, dynamic>? userData) =>
    userData != null && userData[demoField] == true;
