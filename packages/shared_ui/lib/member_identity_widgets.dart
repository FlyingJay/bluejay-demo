import 'package:flutter/material.dart';
import 'package:shared_services/group_member_directory.dart';
import 'package:shared_services/member_identity.dart';

/// Builds with a group member's [MemberIdentity]: their display name and
/// picture from the group member directory.
///
/// Give it what the document stored about the person: their [uid] when it
/// has one, their [email] when that's all it has (older chat, album and
/// recipe docs), and any [name] it copied in at write time as the fallback.
/// The first frame uses the directory's cache (or the fallback), then it
/// rebuilds once the lookup finishes. [groupId] defaults to the active group;
/// pass the document's own group when it has one.
class MemberIdentityBuilder extends StatefulWidget {
  const MemberIdentityBuilder({
    super.key,
    this.uid,
    this.email,
    this.name,
    this.groupId,
    this.unknown = 'Unknown',
    this.directory,
    required this.builder,
  });

  final String? uid;
  final String? email;
  final String? name;
  final String? groupId;

  /// Shown when nothing at all is known about the person.
  final String unknown;

  /// Defaults to [GroupMemberDirectory.instance].
  final GroupMemberDirectory? directory;

  final Widget Function(BuildContext context, MemberIdentity identity) builder;

  @override
  State<MemberIdentityBuilder> createState() => _MemberIdentityBuilderState();
}

class _MemberIdentityBuilderState extends State<MemberIdentityBuilder> {
  late MemberIdentity _identity;
  int _generation = 0;

  GroupMemberDirectory get _dir => widget.directory ?? GroupMemberDirectory.instance;

  @override
  void initState() {
    super.initState();
    _lookup();
  }

  @override
  void didUpdateWidget(MemberIdentityBuilder old) {
    super.didUpdateWidget(old);
    if (old.uid != widget.uid ||
        old.email != widget.email ||
        old.name != widget.name ||
        old.groupId != widget.groupId ||
        old.unknown != widget.unknown ||
        old.directory != widget.directory) {
      _lookup();
    }
  }

  void _lookup() {
    final generation = ++_generation;
    _identity = _dir.peekIdentity(
      uid: widget.uid,
      email: widget.email,
      name: widget.name,
      groupId: widget.groupId,
      unknown: widget.unknown,
    );
    if (_identity.isResolved) return;
    _dir
        .identify(
      uid: widget.uid,
      email: widget.email,
      name: widget.name,
      groupId: widget.groupId,
      unknown: widget.unknown,
    )
        .then((found) {
      if (!mounted || generation != _generation || found == _identity) return;
      setState(() => _identity = found);
    });
  }

  @override
  Widget build(BuildContext context) => widget.builder(context, _identity);
}

/// A group member's display name as text. See [MemberIdentityBuilder] for
/// how the person is looked up.
class MemberName extends StatelessWidget {
  const MemberName({
    super.key,
    this.uid,
    this.email,
    this.name,
    this.groupId,
    this.unknown = 'Unknown',
    this.format,
    this.style,
    this.maxLines,
    this.overflow,
    this.textAlign,
    this.directory,
  });

  final String? uid;
  final String? email;
  final String? name;
  final String? groupId;
  final String unknown;

  /// Turns the label into the shown text, e.g. `(n) => 'by $n'`.
  final String Function(String label)? format;
  final TextStyle? style;
  final int? maxLines;
  final TextOverflow? overflow;
  final TextAlign? textAlign;
  final GroupMemberDirectory? directory;

  @override
  Widget build(BuildContext context) => MemberIdentityBuilder(
        uid: uid,
        email: email,
        name: name,
        groupId: groupId,
        unknown: unknown,
        directory: directory,
        builder: (context, id) => Text(
          format == null ? id.label : format!(id.label),
          style: style,
          maxLines: maxLines,
          overflow: overflow,
          textAlign: textAlign,
        ),
      );
}

/// A group member's picture, or their initials when they have none (or it
/// fails to load). See [MemberIdentityBuilder] for how the person is looked
/// up; [MemberAvatar.identity] draws one that's already resolved.
class MemberAvatar extends StatelessWidget {
  const MemberAvatar({
    super.key,
    this.uid,
    this.email,
    this.name,
    this.groupId,
    this.radius = 20,
    this.backgroundColor,
    this.foregroundColor,
    this.textStyle,
    this.directory,
  }) : identity = null;

  const MemberAvatar.identity(
    MemberIdentity this.identity, {
    super.key,
    this.radius = 20,
    this.backgroundColor,
    this.foregroundColor,
    this.textStyle,
  })  : uid = null,
        email = null,
        name = null,
        groupId = null,
        directory = null;

  final MemberIdentity? identity;
  final String? uid;
  final String? email;
  final String? name;
  final String? groupId;
  final double radius;
  final Color? backgroundColor;
  final Color? foregroundColor;

  /// Style for the initials; sized to the avatar by default.
  final TextStyle? textStyle;
  final GroupMemberDirectory? directory;

  @override
  Widget build(BuildContext context) {
    final known = identity;
    if (known != null) return _avatar(context, known);
    return MemberIdentityBuilder(
      uid: uid,
      email: email,
      name: name,
      groupId: groupId,
      unknown: '?',
      directory: directory,
      builder: _avatar,
    );
  }

  Widget _avatar(BuildContext context, MemberIdentity id) {
    final scheme = Theme.of(context).colorScheme;
    final fg = foregroundColor ?? scheme.onPrimaryContainer;
    return CircleAvatar(
      radius: radius,
      backgroundColor: backgroundColor ?? scheme.primaryContainer,
      foregroundColor: fg,
      // The initials sit under the picture, so they show while it loads and
      // when it fails.
      foregroundImage: id.hasPhoto ? NetworkImage(id.photoUrl) : null,
      onForegroundImageError: id.hasPhoto ? (_, __) {} : null,
      child: Text(
        id.initials,
        style: textStyle ??
            // design-ok: initials scale with the avatar's radius
            TextStyle(
              fontSize: radius * 0.8,
              fontWeight: FontWeight.w700,
              color: fg,
            ),
      ),
    );
  }
}
