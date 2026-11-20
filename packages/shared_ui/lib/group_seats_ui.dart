/// Group seats UI shared by the Users app and Group Admin
/// (plans/group-seats/DESIGN.md): the seat bar, the "No seats available"
/// dialog for members, and the plan sheet for group admins.
library;

import 'package:bluejay_design/bluejay_design.dart';
import 'package:flutter/material.dart';
import 'package:shared_services/group_seats.dart';

/// Currency symbols that keep dollars apart (CA$999.00, US$999.00).
const Map<String, String> _currencySymbols = {'CAD': r'CA$', 'USD': r'US$'};

/// [amount] in [currency] with two decimals and thousands separators:
/// `CA$999.00`, `CA$1,250.00`.
String formatSeatPrice(num amount, String currency) {
  final code = currency.trim().isEmpty ? 'CAD' : currency.trim().toUpperCase();
  final symbol = _currencySymbols[code] ?? '$code ';
  final fixed = amount.abs().toStringAsFixed(2);
  final dot = fixed.indexOf('.');
  final whole = fixed.substring(0, dot);
  final grouped = StringBuffer();
  for (var i = 0; i < whole.length; i++) {
    if (i > 0 && (whole.length - i) % 3 == 0) grouped.write(',');
    grouped.write(whole[i]);
  }
  return '${amount < 0 ? '-' : ''}$symbol$grouped${fixed.substring(dot)}';
}

/// `Business — 50 seats, 10 developer agents — CA$999.00/month`.
String describeSeatPlan(SeatPlan plan, String currency) =>
    '${plan.name} — ${_count(plan.seats, 'seat')}, ${devQueuesLabel(plan.devQueues)} — '
    '${formatSeatPrice(plan.priceMonthly, currency)}/month';

String _count(int n, String noun) => '$n ${n == 1 ? noun : '${noun}s'}';

Color _danger(BuildContext context) => context.bj.tone(BjTone.danger).foreground;
Color _warning(BuildContext context) => context.bj.tone(BjTone.warning).foreground;

/// "N of M seats used · K available", with a progress bar that turns amber
/// when the group is nearly full and red when it is full. Pending
/// invitations take seats, so they are counted (and noted).
class SeatUsageBar extends StatelessWidget {
  final SeatStatus status;

  const SeatUsageBar({super.key, required this.status});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final muted = theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant);
    final limit = status.limit ?? 0;
    final full = status.isFull;
    final ratio = status.unlimited || limit <= 0 ? 0.0 : (status.used / limit).clamp(0.0, 1.0);
    final color = full
        ? _danger(context)
        : ratio >= 0.8
            ? _warning(context)
            : theme.colorScheme.primary;

    final planLabel = StringBuffer(status.plan.name.isEmpty ? 'Seats' : '${status.plan.name} plan');
    if (!status.unlimited && status.bonusSeats > 0) {
      planLabel.write(' · ${_count(status.bonusSeats, 'bonus seat')}');
    }

    final String headline;
    if (status.unlimited) {
      headline = 'Unlimited seats · ${_count(status.used, 'seat')} used';
    } else {
      headline = '${status.used} of $limit seats used · ${status.available ?? 0} available';
    }

    return Semantics(
      container: true,
      label: 'Group seats',
      child: Column(
        key: const ValueKey('seat-usage-bar'),
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              Icon(
                status.unlimited ? Icons.all_inclusive_rounded : Icons.event_seat_outlined,
                size: 18,
                color: full ? _danger(context) : theme.colorScheme.primary,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  headline,
                  style: theme.textTheme.bodyMedium?.copyWith(
                    fontWeight: FontWeight.w600,
                    color: full ? _danger(context) : null,
                  ),
                ),
              ),
            ],
          ),
          if (!status.unlimited) ...[
            const SizedBox(height: 8),
            ClipRRect(
              borderRadius: BjRadius.all(BjRadius.pill),
              child: LinearProgressIndicator(
                value: ratio,
                minHeight: 6,
                color: color,
                backgroundColor: color.withValues(alpha: 0.15),
              ),
            ),
          ],
          const SizedBox(height: 6),
          Text(
            [
              planLabel.toString(),
              if (status.pending > 0) 'includes ${_count(status.pending, 'pending invitation')}',
              if (full) 'no seats left',
            ].join(' · '),
            style: full ? muted?.copyWith(color: _danger(context)) : muted,
          ),
        ],
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// No seats (members and editors)
// ─────────────────────────────────────────────────────────────────────────────

/// Tells a member who can't manage seats that [status]'s group is full, and
/// lets them ask its admins for more (`groupSeatsRequestMore`).
Future<void> showNoSeatsDialog(
  BuildContext context, {
  required SeatStatus status,
  required GroupSeatsApi api,
}) =>
    showDialog<void>(context: context, builder: (_) => NoSeatsDialog(status: status, api: api));

class NoSeatsDialog extends StatefulWidget {
  final SeatStatus status;
  final GroupSeatsApi api;

  const NoSeatsDialog({super.key, required this.status, required this.api});

  @override
  State<NoSeatsDialog> createState() => _NoSeatsDialogState();
}

class _NoSeatsDialogState extends State<NoSeatsDialog> {
  final _message = TextEditingController();
  bool _sending = false;
  int? _notified;
  String? _error;

  @override
  void dispose() {
    _message.dispose();
    super.dispose();
  }

  Future<void> _ask() async {
    setState(() {
      _sending = true;
      _error = null;
    });
    try {
      final notified = await widget.api.requestMore(widget.status.groupId, message: _message.text);
      if (mounted) setState(() => _notified = notified);
    } catch (e) {
      if (mounted) setState(() => _error = seatErrorMessage(e));
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final status = widget.status;
    final group = status.groupName.isEmpty ? 'This group' : status.groupName;
    final notified = _notified;

    if (notified != null) {
      return AlertDialog(
        key: const ValueKey('no-seats-dialog'),
        title: Text(notified > 0 ? 'Your admins were notified' : 'No admins to notify'),
        content: Text(
          notified > 0
              ? "We let ${notified == 1 ? "$group's admin" : "$group's $notified admins"} know you want to invite "
                  'someone. Once a seat is free, you can send the invitation.'
              : "$group has no admins we could notify. Ask the person who runs the group to add seats.",
        ),
        actions: [
          FilledButton(onPressed: () => Navigator.of(context).pop(), child: const Text('Done')),
        ],
      );
    }

    final pending = status.pending;
    return AlertDialog(
      key: const ValueKey('no-seats-dialog'),
      title: const Text('No seats available'),
      content: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 420),
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                '$group is full: all ${status.limit ?? status.used} of its seats are taken'
                '${pending > 0 ? ', including ${_count(pending, 'pending invitation')}' : ''}.',
              ),
              const SizedBox(height: 8),
              Text(
                pending > 0
                    ? 'A pending invitation holds a seat until it is accepted. Revoking one frees its seat, '
                        "or the group's admins can add more seats."
                    : "The group's admins can add more seats.",
              ),
              const SizedBox(height: 16),
              TextField(
                key: const ValueKey('no-seats-message'),
                controller: _message,
                enabled: !_sending,
                maxLength: 280,
                maxLines: 3,
                minLines: 1,
                textCapitalization: TextCapitalization.sentences,
                decoration: const InputDecoration(
                  labelText: 'Message to your admins (optional)',
                  hintText: 'Who you want to invite, and why',
                ),
              ),
              if (_error != null) ...[
                const SizedBox(height: 4),
                Text(_error!, style: TextStyle(color: _danger(context))),
              ],
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: _sending ? null : () => Navigator.of(context).pop(),
          child: const Text('Close'),
        ),
        FilledButton.icon(
          key: const ValueKey('ask-admin'),
          onPressed: _sending ? null : _ask,
          icon: _sending
              ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
              : const Icon(Icons.notifications_active_outlined, size: 18),
          label: const Text('Ask an admin'),
        ),
      ],
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Plan sheet (group admins)
// ─────────────────────────────────────────────────────────────────────────────

/// What choosing [change] (to [plan]) does, in one line: the charge today,
/// the switch on the 1st, or taking back a scheduled switch.
String describeSeatPlanChange(SeatStatus status, SeatPlan plan, SeatPlanChange change) {
  final currency = status.currency;
  if (change.isKeep) {
    final next = status.nextPlan;
    return 'Keep ${plan.name} (cancel the switch to ${next?.name ?? 'another plan'})';
  }
  if (change.isPeriodEnd) {
    return change.resumes
        ? 'Starts on the 1st — nothing charged now. This resumes your cancelled plan until then.'
        : 'Starts on the 1st — nothing charged now';
  }
  final paid = change.credits > 0 ? ', after ${formatSeatPrice(change.credits, currency)} already paid this month' : '';
  if (change.charge <= 0) return 'Starts today — nothing more to pay this month$paid';
  return '${formatSeatPrice(change.charge, currency)} today for the rest of this month$paid';
}

/// Offers a group admin ([SeatStatus.canManage]) the paid plans they can
/// choose now ([SeatStatus.planChanges]), each with what it costs today, and
/// moves the group onto the one they confirm (`groupSeatsChangePlan`).
/// [upgradesOnly] lists only the plans that add seats today (a full group).
/// Returns the group's new seats, or null when nothing changed.
Future<SeatStatus?> showSeatPlanSheet(
  BuildContext context, {
  required SeatStatus status,
  required GroupSeatsApi api,
  bool upgradesOnly = false,
}) =>
    showModalBottomSheet<SeatStatus>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (_) => SeatPlanSheet(status: status, api: api, upgradesOnly: upgradesOnly),
    );

class SeatPlanSheet extends StatefulWidget {
  final SeatStatus status;
  final GroupSeatsApi api;
  final bool upgradesOnly;

  const SeatPlanSheet({super.key, required this.status, required this.api, this.upgradesOnly = false});

  @override
  State<SeatPlanSheet> createState() => _SeatPlanSheetState();
}

class _SeatPlanSheetState extends State<SeatPlanSheet> {
  late final List<(SeatPlan, SeatPlanChange)> _options =
      widget.upgradesOnly ? widget.status.upgradeOptions : widget.status.planOptions;
  late (SeatPlan, SeatPlanChange)? _selected = _options.isEmpty ? null : _options.first;
  bool _busy = false;
  String? _error;

  Future<void> _change() async {
    final selected = _selected;
    if (selected == null) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final updated = await widget.api.changePlan(widget.status.groupId, selected.$1);
      if (mounted) Navigator.of(context).pop(updated);
    } catch (e) {
      if (mounted) {
        setState(() {
          _error = seatErrorMessage(e);
          _busy = false;
        });
      }
    }
  }

  String _confirmLabel((SeatPlan, SeatPlanChange)? selected) {
    if (selected == null) return widget.upgradesOnly ? 'Upgrade' : 'Change plan';
    final (plan, change) = selected;
    if (change.isKeep) return 'Keep ${plan.name}';
    if (change.isPeriodEnd) return 'Switch to ${plan.name} on the 1st';
    return 'Switch to ${plan.name}';
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final status = widget.status;
    final group = status.groupName.isEmpty ? 'this group' : status.groupName;
    final noCard = status.hasPaymentMethod == false;
    final selected = _selected;
    final registration = status.registration;
    final next = status.nextPlan;

    return SafeArea(
      child: SingleChildScrollView(
        padding: EdgeInsets.fromLTRB(24, 0, 24, 24 + MediaQuery.of(context).viewInsets.bottom),
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 520),
            child: Column(
              key: const ValueKey('seat-plan-sheet'),
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(widget.upgradesOnly ? 'Get more seats' : 'Change plan', style: theme.textTheme.titleLarge),
                const SizedBox(height: 4),
                Text(
                  '$group is on the ${status.plan.name} plan '
                  '(${status.unlimited ? 'unlimited seats' : '${status.used} of ${status.limit} seats used'})'
                  '${next == null ? '.' : ' and moves to ${next.name} on the 1st.'}',
                  style: theme.textTheme.bodyMedium,
                ),
                const SizedBox(height: 16),
                if (_options.isEmpty) ...[
                  Text(
                    widget.upgradesOnly
                        ? 'There is no larger plan to move to right now. Contact Bluejay if the group needs more '
                            'seats, or revoke pending invitations to free some.'
                        : 'There is no plan to change to right now. Contact Bluejay if the group needs a '
                            'different one.',
                    key: const ValueKey('no-plan-options'),
                    style: theme.textTheme.bodyMedium,
                  ),
                  const SizedBox(height: 16),
                  Align(
                    alignment: Alignment.centerRight,
                    child: TextButton(onPressed: () => Navigator.of(context).pop(), child: const Text('Close')),
                  ),
                ] else ...[
                  for (final option in _options)
                    _planOption(theme, status, option, selected: option == selected),
                  const SizedBox(height: 8),
                  Text(
                    'Plans are billed on the 1st of each month${status.tax.plusAside} to the default card in your Wallet. '
                    'A plan with more seats starts today, prorated for the rest of this month less what you '
                    'already paid for it; a plan with fewer seats starts on the 1st. You can cancel any time; '
                    'the seats stay until the end of the month you paid for.',
                    style: theme.textTheme.bodySmall,
                  ),
                  if (registration != null && !registration.included) ...[
                    const SizedBox(height: 8),
                    Text(
                      'Paid plans include the ${formatSeatPrice(registration.priceMonthly, status.currency)} '
                      'monthly group fee, so it is no longer billed on its own.',
                      key: const ValueKey('seat-plan-includes-fee'),
                      style: theme.textTheme.bodySmall,
                    ),
                  ],
                  if (noCard) ...[
                    const SizedBox(height: 12),
                    Container(
                      key: const ValueKey('seat-plan-no-card'),
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(
                        color: context.bj.tone(BjTone.warning).background,
                        borderRadius: BjRadius.all(BjRadius.md),
                        border: Border.all(color: context.bj.tone(BjTone.warning).border),
                      ),
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Icon(Icons.credit_card_off_outlined, color: _warning(context), size: 20),
                          const SizedBox(width: BjSpace.sm),
                          const Expanded(
                            child: Text(
                              'You need a default card in Wallet before you can change plans. '
                              'Add one in the Wallet app, then come back.',
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                  if (_error != null) ...[
                    const SizedBox(height: 12),
                    Text(_error!, key: const ValueKey('seat-plan-error'), style: TextStyle(color: _danger(context))),
                  ],
                  const SizedBox(height: 16),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.end,
                    children: [
                      TextButton(
                        onPressed: _busy ? null : () => Navigator.of(context).pop(),
                        child: const Text('Not now'),
                      ),
                      const SizedBox(width: 8),
                      Flexible(
                        child: FilledButton(
                          key: const ValueKey('seat-plan-confirm'),
                          onPressed: (_busy || noCard || selected == null) ? null : _change,
                          child: _busy
                              ? const SizedBox(
                                  width: 18,
                                  height: 18,
                                  child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
                                )
                              : Text(_confirmLabel(selected)),
                        ),
                      ),
                    ],
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _planOption(ThemeData theme, SeatStatus status, (SeatPlan, SeatPlanChange) option, {required bool selected}) {
    final (plan, change) = option;
    final muted = theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant);
    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(
          color: selected ? theme.colorScheme.primary : theme.dividerColor,
          width: selected ? 2 : 1,
        ),
      ),
      child: ListTile(
        key: ValueKey('seat-plan-${plan.id}'),
        onTap: _busy ? null : () => setState(() => _selected = option),
        leading: Icon(
          selected ? Icons.radio_button_checked : Icons.radio_button_unchecked,
          color: selected ? theme.colorScheme.primary : null,
        ),
        title: Text(describeSeatPlan(plan, status.currency)),
        subtitle: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(describeSeatPlanChange(status, plan, change), key: ValueKey('seat-plan-${plan.id}-effect')),
            if (status.bonusSeats > 0 && !change.isKeep)
              Text('Plus your ${_count(status.bonusSeats, 'bonus seat')}', style: muted),
          ],
        ),
      ),
    );
  }
}
