/// App Maker request fields as people read them: the review statuses and
/// the audience and importance choices, with their labels. Shared by App
/// Maker (the requester's form and list) and Dev Pipeline (where platform
/// admins moderate requests). functions/_app_request_fields.js mirrors these
/// for the server; functions/app_request_fields.test.js checks they agree.
library;

/// Who the requester expects would use the app, in plain terms.
class AppRequestAudience {
  static const justMe = 'just_me';
  static const myGroup = 'my_group';
  static const specificPeople = 'specific_people';

  static const List<String> values = [justMe, myGroup, specificPeople];

  static String label(String value) {
    switch (value) {
      case justMe:
        return 'Just me';
      case myGroup:
        return 'My whole group';
      case specificPeople:
        return 'Specific people or roles';
      default:
        return 'Not specified';
    }
  }
}

/// How badly the requester wants this app, in plain terms.
class AppRequestImportance {
  static const niceToHave = 'nice_to_have';
  static const wouldHelpALot = 'would_help_a_lot';
  static const reallyNeedIt = 'really_need_it';

  static const List<String> values = [niceToHave, wouldHelpALot, reallyNeedIt];

  static String label(String value) {
    switch (value) {
      case niceToHave:
        return 'Nice to have';
      case wouldHelpALot:
        return 'Would help a lot';
      case reallyNeedIt:
        return 'Really need it';
      default:
        return 'Not specified';
    }
  }
}

/// Lifecycle of a submitted app request. Platform admins set it from Dev
/// Pipeline (appMakerAdminSetRequestStatus); the dev change lifecycle marks
/// it shipped when the built app goes live.
class AppRequestStatus {
  static const newRequest = 'new';
  static const underReview = 'under_review';
  static const planned = 'planned';
  static const building = 'building';
  static const shipped = 'shipped';
  static const declined = 'declined';

  static const List<String> values = [
    newRequest,
    underReview,
    planned,
    building,
    shipped,
    declined,
  ];

  static String label(String value) {
    switch (value) {
      case newRequest:
        return 'New';
      case underReview:
        return 'Under review';
      case planned:
        return 'Planned';
      case building:
        return 'Building';
      case shipped:
        return 'Shipped';
      case declined:
        return 'Declined';
      default:
        return 'Unknown';
    }
  }

  static bool isClosed(String value) =>
      value == shipped || value == declined;
}
