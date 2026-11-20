import 'package:bluejay_design/bluejay_design.dart';
import 'package:flutter/material.dart';
import 'package:shared_services/portal_clients.dart';

export 'package:shared_services/portal_clients.dart' show PortalAppClient;

/// Opens a sheet listing [load]'s portal clients (usually
/// [listPortalClientsForApp]) and pops the one picked, or null.
Future<PortalAppClient?> showClientPicker(
  BuildContext context, {
  required Future<List<PortalAppClient>> Function() load,
  String title = 'Choose a client',
  String? subtitle,
  Set<String> excludeUids = const {},
}) {
  return showBjSheet<PortalAppClient>(
    context,
    title: title,
    subtitle: subtitle,
    builder: (ctx) => ClientPickerList(
      load: load,
      excludeUids: excludeUids,
      onPick: (client) => Navigator.pop(ctx, client),
    ),
  );
}

/// The clients [load] returns (less [excludeUids]), each a row that calls
/// [onPick].
class ClientPickerList extends StatefulWidget {
  const ClientPickerList({
    super.key,
    required this.load,
    required this.onPick,
    this.excludeUids = const {},
  });

  final Future<List<PortalAppClient>> Function() load;
  final ValueChanged<PortalAppClient> onPick;
  final Set<String> excludeUids;

  @override
  State<ClientPickerList> createState() => _ClientPickerListState();
}

class _ClientPickerListState extends State<ClientPickerList> {
  late final Future<List<PortalAppClient>> _clients = widget.load();

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<List<PortalAppClient>>(
      future: _clients,
      builder: (context, snap) {
        if (snap.hasError) {
          return BjStateView.error(title: 'Couldn\'t load clients', error: snap.error);
        }
        final clients = snap.data;
        if (clients == null) {
          return const Padding(
            padding: EdgeInsets.all(BjSpace.lg),
            child: Center(child: CircularProgressIndicator()),
          );
        }
        final shown = clients.where((c) => !widget.excludeUids.contains(c.uid)).toList();
        if (shown.isEmpty) {
          return const BjStateView.empty(
            icon: Icons.person_search_outlined,
            title: 'No clients to choose',
            message: 'Clients appear here once they join your portal and it gives them this app.',
            compact: true,
          );
        }
        return Column(mainAxisSize: MainAxisSize.min, children: [
          for (final c in shown)
            Padding(
              padding: const EdgeInsets.only(bottom: BjSpace.sm),
              child: BjListRow(
                key: ValueKey('client-${c.uid}'),
                leading: const BjIconWell(icon: Icons.person_outline_rounded),
                title: c.label,
                subtitle: c.name.isNotEmpty && c.email.isNotEmpty ? c.email : null,
                onTap: () => widget.onPick(c),
              ),
            ),
        ]);
      },
    );
  }
}
