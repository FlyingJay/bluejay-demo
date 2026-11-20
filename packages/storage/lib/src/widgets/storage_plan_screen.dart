import 'package:bluejay_design/bluejay_design.dart';
import 'package:cloud_functions/cloud_functions.dart';
import 'package:flutter/material.dart';
import 'package:shared_ui/member_identity_widgets.dart';

import '../format.dart';
import '../storage_plan.dart';

/// The group's Storage plan: usage against the free tier, the price per GB
/// and how it's worked out, and (for group admins) switching between the
/// free tier and pay as you go. Data access is passed in, so it renders in
/// tests without Firebase.
class StoragePlanScreen extends StatefulWidget {
  const StoragePlanScreen({
    super.key,
    required this.load,
    required this.setPlan,
  });

  final Future<StoragePlanStatus> Function() load;
  final Future<StoragePlanStatus> Function(String plan, double? acceptedPrice)
      setPlan;

  @override
  State<StoragePlanScreen> createState() => _StoragePlanScreenState();
}

class _StoragePlanScreenState extends State<StoragePlanScreen> {
  late Future<StoragePlanStatus> _status = widget.load();
  bool _saving = false;

  void _reload() => setState(() => _status = widget.load());

  Future<void> _choose(StoragePlanStatus status, String plan) async {
    if (plan == status.plan || _saving) return;
    final price = formatPrice(status.currentPricePerGbMonth, status.currency);
    final free = formatGb(status.freeTierGb);
    final confirmed = plan == StoragePlanStatus.payAsYouGo
        ? await showBjConfirm(
            context,
            title: 'Turn on pay as you go?',
            icon: Icons.cloud_sync_rounded,
            message: 'Everyone in the group can store as much as they need. '
                'Each month, storage above the free $free is billed to you '
                'at $price per GB, averaged over the month.',
            consequences: [
              'Billed to your default card in Wallet',
              'You can switch back once the group is under $free',
            ],
            confirmLabel: 'Turn on',
          )
        : await showBjConfirm(
            context,
            title: 'Switch to the free tier?',
            icon: Icons.cloud_outlined,
            message: 'The group can store up to $free. Uploads that would '
                'take it past that are refused. Storage used while on pay as '
                'you go this month is still billed.',
            confirmLabel: 'Switch',
          );
    if (!confirmed || !mounted) return;
    setState(() => _saving = true);
    try {
      final next = await widget.setPlan(
        plan,
        plan == StoragePlanStatus.payAsYouGo
            ? status.currentPricePerGbMonth
            : null,
      );
      if (!mounted) return;
      setState(() => _status = Future.value(next));
      BjSnack.success(
          context,
          next.isPayAsYouGo
              ? 'Pay as you go is on'
              : 'The group is on the free tier');
    } on FirebaseFunctionsException catch (e) {
      if (mounted) BjSnack.error(context, e.message ?? 'Could not change plan');
    } catch (e) {
      if (mounted) BjSnack.error(context, 'Could not change plan: $e');
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return BjPage(
      title: 'Storage plan',
      actions: [
        IconButton(
          icon: const Icon(Icons.refresh_rounded),
          tooltip: 'Refresh',
          onPressed: _reload,
        ),
      ],
      body: FutureBuilder<StoragePlanStatus>(
        future: _status,
        builder: (context, snapshot) {
          if (snapshot.hasError) {
            return BjStateView.error(
              message: 'Could not load the storage plan.',
              onRetry: _reload,
            );
          }
          final status = snapshot.data;
          if (status == null) return const BjSkeletonList();
          return BjScrollBody(
            maxWidth: BjBreakpoint.formWidth,
            children: [
              _UsageHero(status: status),
              if (status.isUnlimited)
                const BjInlineNote(
                  'Bluejay gives this group unlimited storage at no charge.',
                  icon: Icons.all_inclusive_rounded,
                  tone: BjTone.success,
                )
              else
                _PlanChooser(
                  status: status,
                  saving: _saving,
                  onChoose: (plan) => _choose(status, plan),
                ),
              _PriceSection(status: status),
              if (status.isPayAsYouGo) _BillingSection(status: status),
            ],
          );
        },
      ),
    );
  }
}

class _UsageHero extends StatelessWidget {
  const _UsageHero({required this.status});

  final StoragePlanStatus status;

  @override
  Widget build(BuildContext context) {
    final onHero = Theme.of(context).colorScheme.onPrimary;
    final free = formatGb(status.freeTierGb);
    final used = formatBytes(status.usageBytes);
    final subtitle = switch (status.plan) {
      StoragePlanStatus.unlimited => 'Unlimited storage',
      StoragePlanStatus.payAsYouGo => 'Pay as you go · first $free free',
      _ => 'Free tier · up to $free',
    };
    return BjHeroCard(
      icon: Icons.cloud_rounded,
      title: '$used stored by the group',
      subtitle: subtitle,
      footer: status.isUnlimited
          ? null
          : Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                BjProgressBar(
                  value: status.freeTierShare.clamp(0, 1).toDouble(),
                  onDark: true,
                ),
                const SizedBox(height: BjSpace.xs),
                Text(
                  status.isFree && !status.uploadsAllowed
                      ? 'The free tier is full: uploads are paused'
                      : '${(status.freeTierShare * 100).round()}% of the '
                          'free $free',
                  style: Theme.of(context)
                      .textTheme
                      .bodySmall
                      ?.copyWith(color: onHero),
                ),
              ],
            ),
    );
  }
}

class _PlanChooser extends StatelessWidget {
  const _PlanChooser({
    required this.status,
    required this.saving,
    required this.onChoose,
  });

  final StoragePlanStatus status;
  final bool saving;
  final ValueChanged<String> onChoose;

  @override
  Widget build(BuildContext context) {
    final free = formatGb(status.freeTierGb);
    final price = formatPrice(status.currentPricePerGbMonth, status.currency);
    return BjFormSection(
      title: 'Plan',
      description: status.canManage
          ? 'Choose how much the group can store.'
          : 'Only the group\'s admins can change the plan.',
      icon: Icons.tune_rounded,
      children: [
        IgnorePointer(
          ignoring: !status.canManage || saving,
          child: BjOptionCards<String>(
            axis: Axis.vertical,
            value: status.plan,
            onChanged: onChoose,
            options: [
              BjOption(
                value: StoragePlanStatus.free,
                title: 'Free tier',
                description: 'Up to $free for the whole group, at no '
                    'charge. Uploads past it are refused.',
                icon: Icons.cloud_outlined,
              ),
              BjOption(
                value: StoragePlanStatus.payAsYouGo,
                title: 'Pay as you go',
                description: 'No limit. The first $free stays free; the '
                    'rest is billed monthly to the admin who turns this on, '
                    'at $price per GB.',
                icon: Icons.cloud_sync_rounded,
              ),
            ],
          ),
        ),
        if (status.canManage &&
            !status.isPayAsYouGo &&
            status.hasPaymentMethod == false)
          const BjInlineNote(
            'Add a default card in Wallet before turning on pay as you go.',
            icon: Icons.credit_card_rounded,
            tone: BjTone.warning,
          ),
      ],
    );
  }
}

class _PriceSection extends StatelessWidget {
  const _PriceSection({required this.status});

  final StoragePlanStatus status;

  @override
  Widget build(BuildContext context) {
    final price = formatPrice(status.pricePerGbMonth, status.currency);
    final example = formatPrice(status.pricePerGbMonth * 100, status.currency);
    return BjFormSection(
      title: 'Price',
      icon: Icons.sell_outlined,
      children: [
        BjKeyValue(label: 'Per GB, per month', value: price),
        BjKeyValue(label: 'Free for the group', value: formatGb(status.freeTierGb)),
        BjKeyValue(label: 'Per 100 GB, per month', value: example),
        Text(
          'Usage is averaged over the month, so a file kept for a week '
          'costs a quarter as much as one kept all month.',
          style: Theme.of(context).textTheme.bodySmall,
        ),
      ],
    );
  }
}

class _BillingSection extends StatelessWidget {
  const _BillingSection({required this.status});

  final StoragePlanStatus status;

  @override
  Widget build(BuildContext context) {
    final payerEmail = status.payerEmail ?? '';
    return BjFormSection(
      title: 'Billing',
      icon: Icons.receipt_long_outlined,
      children: [
        if (status.payerIsYou)
          const BjKeyValue(label: 'Billed to', value: 'You')
        else if (payerEmail.isEmpty)
          const BjKeyValue(label: 'Billed to', value: 'One of the group\'s admins')
        else
          BjKeyValue(label: 'Billed to', child: MemberName(email: payerEmail)),
        BjKeyValue(
          label: 'This month at today\'s usage',
          value: formatPrice(status.estimatedMonthlyCost, status.currency),
        ),
        Text(
          'Charged at the start of each month for the month before, with '
          'your other Bluejay invoices in Wallet.',
          style: Theme.of(context).textTheme.bodySmall,
        ),
      ],
    );
  }
}
