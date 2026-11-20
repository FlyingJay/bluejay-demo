import 'package:flutter/widgets.dart';

/// What an app screen builds when `ActiveGroupService` holds no group.
///
/// Apps always open with an active group: the launcher lists and opens no
/// app until one is active (see `ActiveGroupService`). The group is only
/// missing for the moment between sign-out clearing it and the launcher
/// closing the app, so this draws nothing rather than a "pick a group"
/// message nobody can act on. Use it in place of such a state.
class ActiveGroupPending extends StatelessWidget {
  const ActiveGroupPending({super.key});

  @override
  Widget build(BuildContext context) => const SizedBox.shrink();
}
