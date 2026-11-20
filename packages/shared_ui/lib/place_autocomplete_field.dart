import 'dart:async';

import 'package:bluejay_design/bluejay_design.dart';
import 'package:flutter/material.dart';
import 'package:shared_services/places/google_places_client.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:uuid/uuid.dart';
import 'readable_selectable_text.dart';

export 'package:shared_services/places/google_places_client.dart' show PlaceDetails, PlaceSearchKind;

/// A location field backed by Google Places.
///
/// Typing shows suggestions under the field; picking one fetches the full
/// place and shows its address in a confirmation block below, so people can
/// see they picked the right spot. Editing the text afterwards drops the
/// pick. If Places is unavailable the field still accepts free text.
///
/// [onChanged] reports the text (the place's name or address after a pick)
/// and the picked place, or null when the text is free-form.
class PlaceAutocompleteField extends StatefulWidget {
  const PlaceAutocompleteField({
    super.key,
    this.initialText = '',
    this.initialPlace,
    required this.onChanged,
    this.decoration = const InputDecoration(labelText: 'Location'),
    this.kind = PlaceSearchKind.anyPlace,
    this.countryCodes = const [],
    this.enabled = true,
    this.client,
  });

  final String initialText;
  final PlaceDetails? initialPlace;
  final void Function(String text, PlaceDetails? place) onChanged;
  final InputDecoration decoration;
  final PlaceSearchKind kind;

  /// ISO country codes to restrict results to; empty searches everywhere.
  final List<String> countryCodes;
  final bool enabled;

  /// Injected for tests.
  final GooglePlacesClient? client;

  /// The text a picked place puts in the field.
  static String fieldTextFor(PlaceDetails place) =>
      place.hasDistinctName ? place.name : (place.formattedAddress.isNotEmpty ? place.formattedAddress : place.name);

  @override
  State<PlaceAutocompleteField> createState() => _PlaceAutocompleteFieldState();
}

class _PlaceAutocompleteFieldState extends State<PlaceAutocompleteField> {
  late final GooglePlacesClient _client = widget.client ?? GooglePlacesClient();
  late final TextEditingController _controller;
  final FocusNode _focusNode = FocusNode();
  Timer? _debounce;
  int _requestSeq = 0;
  String _sessionToken = const Uuid().v4();

  PlaceDetails? _place;
  List<PlaceSuggestion> _suggestions = const [];
  bool _searching = false;
  bool _resolving = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _place = widget.initialPlace;
    _controller = TextEditingController(
      text: widget.initialText.isNotEmpty || _place == null
          ? widget.initialText
          : PlaceAutocompleteField.fieldTextFor(_place!),
    );
    _focusNode.addListener(() {
      if (!_focusNode.hasFocus) {
        // Let a tap on a suggestion land before the list disappears.
        Future.delayed(const Duration(milliseconds: 200), () {
          if (mounted && !_focusNode.hasFocus) setState(() => _suggestions = const []);
        });
      }
    });
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _controller.dispose();
    _focusNode.dispose();
    super.dispose();
  }

  void _onTextChanged(String text) {
    if (_place != null) {
      setState(() => _place = null);
    }
    widget.onChanged(text.trim(), null);
    _debounce?.cancel();
    if (text.trim().length < 2) {
      _requestSeq++;
      setState(() {
        _suggestions = const [];
        _searching = false;
      });
      return;
    }
    _debounce = Timer(const Duration(milliseconds: 300), () => _search(text));
  }

  Future<void> _search(String text) async {
    final seq = ++_requestSeq;
    setState(() => _searching = true);
    try {
      final results = await _client.autocomplete(
        text,
        sessionToken: _sessionToken,
        kind: widget.kind,
        countryCodes: widget.countryCodes,
      );
      if (!mounted || seq != _requestSeq) return;
      setState(() {
        _suggestions = results;
        _searching = false;
        _error = null;
      });
    } catch (e) {
      if (!mounted || seq != _requestSeq) return;
      setState(() {
        _suggestions = const [];
        _searching = false;
        _error = 'Address lookup isn\'t available right now. What you type will be saved as written.';
      });
    }
  }

  Future<void> _pick(PlaceSuggestion suggestion) async {
    _debounce?.cancel();
    _requestSeq++;
    setState(() {
      _suggestions = const [];
      _resolving = true;
      _error = null;
    });
    PlaceDetails? place;
    try {
      place = await _client.details(suggestion.placeId, sessionToken: _sessionToken);
    } catch (_) {
      place = null;
    }
    // A session ends with a details call, picked or not.
    _sessionToken = const Uuid().v4();
    if (!mounted) return;
    if (place == null) {
      setState(() {
        _resolving = false;
        _error = 'Couldn\'t load that place. Try again, or keep the text as written.';
      });
      _controller.text = suggestion.description;
      widget.onChanged(suggestion.description, null);
      return;
    }
    final text = PlaceAutocompleteField.fieldTextFor(place);
    _controller.value = TextEditingValue(text: text, selection: TextSelection.collapsed(offset: text.length));
    setState(() {
      _place = place;
      _resolving = false;
    });
    _focusNode.unfocus();
    widget.onChanged(text, place);
  }

  void _clear() {
    _debounce?.cancel();
    _requestSeq++;
    _controller.clear();
    setState(() {
      _place = null;
      _suggestions = const [];
      _error = null;
    });
    widget.onChanged('', null);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final busy = _searching || _resolving;
    final decoration = widget.decoration.copyWith(
      helperText: widget.decoration.helperText ?? 'Search for a venue or address',
      suffixIcon: busy
          ? const Padding(
              padding: EdgeInsets.all(14),
              child: SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2)),
            )
          : (_controller.text.isEmpty
              ? const Icon(Icons.search)
              : IconButton(tooltip: 'Clear location', icon: const Icon(Icons.clear), onPressed: widget.enabled ? _clear : null)),
    );

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        TextField(
          controller: _controller,
          focusNode: _focusNode,
          enabled: widget.enabled,
          textInputAction: TextInputAction.search,
          decoration: decoration,
          onChanged: _onTextChanged,
          onSubmitted: (_) {
            if (_suggestions.isNotEmpty) _pick(_suggestions.first);
          },
        ),
        if (_suggestions.isNotEmpty)
          Container(
            margin: const EdgeInsets.only(top: BjSpace.xs),
            clipBehavior: Clip.antiAlias,
            decoration: BoxDecoration(
              color: BjNeutral.surface,
              borderRadius: BjRadius.all(BjRadius.md),
              border: Border.all(color: BjNeutral.border),
              boxShadow: context.bj.shadowMd,
            ),
            child: Material(
              type: MaterialType.transparency,
              child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                for (final s in _suggestions.take(6))
                  ListTile(
                    dense: true,
                    leading: const Icon(Icons.place_outlined),
                    title: Text(s.mainText.isNotEmpty ? s.mainText : s.description,
                        maxLines: 1, overflow: TextOverflow.ellipsis),
                    subtitle: s.secondaryText.isEmpty
                        ? null
                        : Text(s.secondaryText, maxLines: 1, overflow: TextOverflow.ellipsis),
                    onTap: () => _pick(s),
                  ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(BjSpace.lg, BjSpace.xxs, BjSpace.lg, BjSpace.sm),
                  child: Align(
                    alignment: Alignment.centerRight,
                    child: Text('Powered by Google',
                        style: theme.textTheme.labelSmall?.copyWith(color: BjNeutral.inkSubtle)),
                  ),
                ),
              ],
            ),
            ),
          ),
        if (_error != null)
          Padding(
            padding: const EdgeInsets.only(top: BjSpace.xs + 2, left: BjSpace.md),
            child: Text(_error!, style: theme.textTheme.bodySmall?.copyWith(color: context.bj.tone(BjTone.danger).foreground)),
          ),
        if (_place != null) ...[
          const SizedBox(height: BjSpace.sm),
          PlaceSummaryCard(place: _place!),
        ],
      ],
    );
  }
}

/// The picked place's name, full address and a Maps link.
class PlaceSummaryCard extends StatelessWidget {
  const PlaceSummaryCard({super.key, required this.place, this.dense = false});

  final PlaceDetails place;
  final bool dense;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final bj = context.bj;
    return Semantics(
      container: true,
      label: 'Selected location: ${place.displayLabel}',
      child: Container(
        padding: EdgeInsets.all(dense ? BjSpace.sm + 2 : BjSpace.md),
        decoration: BoxDecoration(
          gradient: bj.softGradient,
          borderRadius: BjRadius.all(BjRadius.lg),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(Icons.location_on_rounded, color: bj.accent, size: 22),
            const SizedBox(width: BjSpace.sm + 2),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (place.hasDistinctName)
                    Text(place.name, style: theme.textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w600)),
                  ReadableSelectableText(
                    place.formattedAddress.isNotEmpty ? place.formattedAddress : place.name,
                    style: theme.textTheme.bodyMedium,
                  ),
                  Align(
                    alignment: Alignment.centerLeft,
                    child: TextButton.icon(
                      style: TextButton.styleFrom(
                        padding: EdgeInsets.zero,
                        visualDensity: VisualDensity.compact,
                        tapTargetSize: MaterialTapTargetSize.padded,
                      ),
                      onPressed: () => openPlaceInMaps(place),
                      icon: const Icon(Icons.map_outlined, size: 18),
                      label: const Text('Open in Google Maps'),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

Future<void> openPlaceInMaps(PlaceDetails place) =>
    launchUrl(place.mapsUri, mode: LaunchMode.externalApplication);
