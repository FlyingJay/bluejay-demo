import 'package:bluejay_design/bluejay_design.dart';
import 'package:flutter/material.dart';

/// Something besides a photo the composer can attach, listed in its attach
/// menu.
class ComposerAttachment {
  final IconData icon;
  final String label;
  final VoidCallback onSelected;

  const ComposerAttachment({
    required this.icon,
    required this.label,
    required this.onSelected,
  });
}

/// A reusable message composer widget with a modern, polished design.
///
/// Provides a text input, an image-attach button, and a send button.
/// The parent screen supplies all callbacks and business logic. With
/// [attachments], the image button becomes a menu: a photo, then each of
/// them.
class SharedMessageComposer extends StatefulWidget {
  final TextEditingController controller;
  final VoidCallback onSend;
  final VoidCallback onPickImage;
  final String hintText;
  final List<ComposerAttachment> attachments;

  const SharedMessageComposer({
    Key? key,
    required this.controller,
    required this.onSend,
    required this.onPickImage,
    this.hintText = 'Share your thoughts…',
    this.attachments = const [],
  }) : super(key: key);

  @override
  State<SharedMessageComposer> createState() => _SharedMessageComposerState();
}

class _SharedMessageComposerState extends State<SharedMessageComposer> {
  bool _hasText = false;

  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_onTextChanged);
  }

  @override
  void dispose() {
    widget.controller.removeListener(_onTextChanged);
    super.dispose();
  }

  void _onTextChanged() {
    final hasText = widget.controller.text.trim().isNotEmpty;
    if (hasText != _hasText) {
      setState(() => _hasText = hasText);
    }
  }

  Widget _attachMenu() {
    final items = [
      ComposerAttachment(
        icon: Icons.add_photo_alternate_outlined,
        label: 'Photo',
        onSelected: widget.onPickImage,
      ),
      ...widget.attachments,
    ];
    return PopupMenuButton<int>(
      icon: const Icon(Icons.add_circle_outline_rounded, size: 24),
      color: BjNeutral.surface,
      iconColor: BjNeutral.inkSubtle,
      tooltip: 'Attach',
      onSelected: (i) => items[i].onSelected(),
      itemBuilder: (_) => [
        for (var i = 0; i < items.length; i++)
          PopupMenuItem<int>(
            value: i,
            child: Row(children: [
              Icon(items[i].icon, size: 20, color: BjNeutral.inkMuted),
              const SizedBox(width: BjSpace.sm),
              Flexible(child: Text(items[i].label, overflow: TextOverflow.ellipsis)),
            ]),
          ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final accent = context.bj.accent;
    return Container(
      decoration: const BoxDecoration(
        color: BjNeutral.surface,
        border: Border(top: BorderSide(color: BjNeutral.border)),
      ),
      child: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.symmetric(
              horizontal: BjSpace.sm, vertical: BjSpace.sm),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              if (widget.attachments.isEmpty)
                IconButton(
                  icon: const Icon(Icons.add_photo_alternate_outlined, size: 24),
                  color: BjNeutral.inkSubtle,
                  onPressed: widget.onPickImage,
                  tooltip: 'Attach an image',
                )
              else
                _attachMenu(),
              Expanded(
                child: TextField(
                  controller: widget.controller,
                  decoration: InputDecoration(
                    hintText: widget.hintText,
                    border: OutlineInputBorder(
                      borderRadius: BjRadius.all(BjRadius.xl),
                      borderSide: BorderSide.none,
                    ),
                    enabledBorder: OutlineInputBorder(
                      borderRadius: BjRadius.all(BjRadius.xl),
                      borderSide: BorderSide.none,
                    ),
                    focusedBorder: OutlineInputBorder(
                      borderRadius: BjRadius.all(BjRadius.xl),
                      borderSide: BorderSide(color: accent, width: 1.5),
                    ),
                    contentPadding: const EdgeInsets.symmetric(
                        horizontal: BjSpace.lg, vertical: BjSpace.sm + 2),
                    filled: true,
                    fillColor: BjNeutral.surfaceMuted,
                    isDense: true,
                  ),
                  keyboardType: TextInputType.multiline,
                  maxLines: 5,
                  minLines: 1,
                  textCapitalization: TextCapitalization.sentences,
                  onSubmitted: (_) {
                    if (_hasText) widget.onSend();
                  },
                ),
              ),
              const SizedBox(width: BjSpace.xs),
              // Send fills with the accent once there's something to send.
              AnimatedContainer(
                duration: BjMotion.medium,
                curve: BjMotion.curve,
                width: 44,
                height: 44,
                decoration: BoxDecoration(
                  gradient: _hasText ? context.bj.heroGradient : null,
                  shape: BoxShape.circle,
                ),
                child: IconButton(
                  icon: Icon(
                    Icons.send_rounded,
                    size: 20,
                    color: _hasText ? Colors.white : BjNeutral.inkSubtle,
                  ),
                  onPressed: widget.onSend,
                  tooltip: 'Send message',
                  padding: EdgeInsets.zero,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
