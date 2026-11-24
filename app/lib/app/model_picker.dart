import 'package:flutter/material.dart';

import '../brain/models.dart';
import '../l10n/l10n.dart';
import 'main_view.dart';
import 'settings.dart';

/// Status bar button with the conversation's model; opens [ModelPicker].
class ModelButton extends StatelessWidget {
  const ModelButton({super.key, required this.assistant});

  final AssistantSettings assistant;

  @override
  Widget build(BuildContext context) {
    final choice = assistant.brainModel;
    final name = assistant.catalogFor(choice.provider)?.find(choice.model)?.name ?? choice.model;
    return Tooltip(
      message: AppLocalizations.of(context).modelTitle,
      child: TextButton.icon(
        style: TextButton.styleFrom(foregroundColor: Colors.white54),
        onPressed: () => showDialog<void>(
          context: context,
          barrierColor: Colors.black26,
          builder: (_) => ModelPicker(assistant: assistant),
        ),
        icon: const Icon(Icons.memory, size: 18),
        label: Text(name),
      ),
    );
  }
}

/// The name of an effort level, as the pickers show it.
String effortName(AppLocalizations l, String effort) =>
    {
      'low': l.effortLow,
      'medium': l.effortMedium,
      'high': l.effortHigh,
      'xhigh': l.effortXhigh,
      'max': l.effortMax,
    }[effort] ??
    effort;

/// Picks the provider (Claude or Antigravity), model, effort and speed of the conversation and,
/// on its other tab, of the workers. The list comes from the provider's installed agent (Claude
/// Code's newest model of each family, then the previous ones folded away; Antigravity's as it
/// lists them). Above the status bar on the desktop; on a phone, across the screen.
class ModelPicker extends StatefulWidget {
  const ModelPicker({super.key, required this.assistant, this.workers = false});

  final AssistantSettings assistant;

  /// Opens on the workers' tab.
  final bool workers;

  @override
  State<ModelPicker> createState() => _ModelPickerState();
}

class _ModelPickerState extends State<ModelPicker> {
  late bool _workers = widget.workers;
  bool _showPrevious = false;
  String _query = '';

  AssistantSettings get _a => widget.assistant;

  ModelChoice get _choice => _workers ? _a.workerModel : _a.brainModel;

  ModelChoice get _default =>
      defaultModel(_choice.provider, workers: _workers, catalog: _a.catalogFor(_choice.provider));

  bool _narrow(BuildContext context) => MediaQuery.sizeOf(context).width < 600;

  void _set(ModelChoice c) => _workers ? _a.setWorkerModel(c) : _a.setBrainModel(c);

  void _pick(BrainModel m) => _set(_choice.copyWith(model: m.value));

  /// Another provider: its default model, at the same effort.
  void _pickProvider(BrainProvider p) {
    if (p == _choice.provider) return;
    final d = defaultModel(p, workers: _workers, catalog: _a.catalogFor(p));
    _set(d.copyWith(effort: _choice.effort));
    setState(() {
      _query = '';
      _showPrevious = false;
    });
  }

  bool _matches(BrainModel m) {
    final q = _query.trim().toLowerCase();
    return q.isEmpty ||
        m.name.toLowerCase().contains(q) ||
        m.value.toLowerCase().contains(q) ||
        m.description.toLowerCase().contains(q);
  }

  @override
  Widget build(BuildContext context) {
    final narrow = _narrow(context);
    final media = MediaQuery.of(context);
    final padding = narrow
        ? EdgeInsets.fromLTRB(8, media.padding.top + 8, 8, media.viewInsets.bottom + media.padding.bottom + 8)
        : const EdgeInsets.only(right: 12, bottom: 56);
    return Align(
      alignment: narrow ? Alignment.center : Alignment.bottomRight,
      child: Padding(
        padding: padding,
        child: Material(
          color: const Color(0xFF15111C),
          elevation: 12,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(14),
            side: const BorderSide(color: Colors.white12),
          ),
          clipBehavior: Clip.antiAlias,
          child: SizedBox(
            width: narrow ? double.infinity : 380,
            child: ListenableBuilder(listenable: _a, builder: (context, _) => _body(context)),
          ),
        ),
      ),
    );
  }

  Widget _body(BuildContext context) {
    final l = AppLocalizations.of(context);
    final provider = _choice.provider;
    final catalog = _a.catalogFor(provider);
    final theme = Theme.of(context);
    final narrow = _narrow(context);
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: EdgeInsets.fromLTRB(16, narrow ? 6 : 14, narrow ? 4 : 16, 4),
          child: Row(
            children: [
              Text(provider.label, style: theme.textTheme.titleMedium),
              const SizedBox(width: 8),
              if (catalog != null && catalog.version.isNotEmpty)
                Expanded(
                  child: Text('${catalog.version} (${provider.agent})',
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.bodySmall?.copyWith(color: Colors.white38)),
                )
              else
                const Spacer(),
              // A phone has no space bar or click outside to close it.
              if (narrow)
                IconButton(
                  tooltip: l.close,
                  icon: const Icon(Icons.close, color: Colors.white54),
                  onPressed: () => Navigator.pop(context),
                ),
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          child: SegmentedButton<bool>(
            showSelectedIcon: false,
            segments: [
              ButtonSegment(value: false, label: Text(l.modelConversation)),
              ButtonSegment(value: true, label: Text(l.modelWorkers)),
            ],
            selected: {_workers},
            onSelectionChanged: (s) => setState(() => _workers = s.first),
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
          child: SegmentedButton<BrainProvider>(
            showSelectedIcon: false,
            segments: [
              for (final p in BrainProvider.values)
                ButtonSegment(
                  value: p,
                  label: Text(p.label),
                  // An agent that is not there can't be picked (but stays shown when in use).
                  enabled: p == provider || !_a.unavailableProviders.contains(p),
                ),
            ],
            selected: {provider},
            onSelectionChanged: (s) => _pickProvider(s.first),
          ),
        ),
        if (catalog == null && _a.unavailableProviders.contains(provider))
          Padding(
            padding: const EdgeInsets.all(24),
            child: Text(l.modelUnavailable(provider.agent), style: const TextStyle(color: Colors.orangeAccent)),
          )
        else if (catalog == null)
          Padding(
            padding: const EdgeInsets.all(24),
            child: Row(
              children: [
                const SizedBox.square(dimension: 16, child: CircularProgressIndicator(strokeWidth: 2)),
                const SizedBox(width: 12),
                Expanded(
                    child: Text(l.modelLoading(provider.agent), style: const TextStyle(color: Colors.white54))),
              ],
            ),
          )
        else ...[
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12),
            child: TextField(
              // On a phone the keyboard would cover the list.
              autofocus: !narrow,
              decoration: InputDecoration(
                isDense: true,
                prefixIcon: const Icon(Icons.search, size: 18),
                hintText: l.modelSearch,
                border: OutlineInputBorder(borderRadius: BorderRadius.circular(10)),
              ),
              onChanged: (v) => setState(() => _query = v),
            ),
          ),
          // On a phone the list takes what the screen leaves.
          Flexible(
            child: ConstrainedBox(
              constraints: BoxConstraints(maxHeight: narrow ? double.infinity : 340),
              child: ListView(
                shrinkWrap: true,
                padding: const EdgeInsets.symmetric(vertical: 6),
                children: _models(context, catalog),
              ),
            ),
          ),
          const Divider(height: 1, color: Colors.white12),
          ..._settings(context, catalog),
        ],
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 4, 16, 14),
          child: Text(_workers ? l.modelWorkersNote : '${l.modelConversationNote} ${l.modelProviderNote}',
              style: theme.textTheme.bodySmall?.copyWith(color: Colors.white38)),
        ),
      ],
    );
  }

  List<Widget> _models(BuildContext context, ModelCatalog catalog) {
    final l = AppLocalizations.of(context);
    if (_query.trim().isNotEmpty) {
      final found = catalog.all.where(_matches).toList();
      if (found.isEmpty) {
        return [
          Padding(
            padding: const EdgeInsets.all(16),
            child: Text(l.modelNoMatch, style: const TextStyle(color: Colors.white38)),
          ),
        ];
      }
      return [for (final m in found) _tile(context, m)];
    }
    return [
      for (final m in catalog.latest) _tile(context, m),
      if (catalog.previous.isNotEmpty)
        ListTile(
          dense: true,
          title: Text(l.modelPrevious(catalog.previous.length), style: const TextStyle(color: Colors.white54)),
          trailing: Icon(_showPrevious ? Icons.expand_less : Icons.expand_more, color: Colors.white38),
          onTap: () => setState(() => _showPrevious = !_showPrevious),
        ),
      if (_showPrevious)
        for (final m in catalog.previous) _tile(context, m),
    ];
  }

  Widget _tile(BuildContext context, BrainModel m) {
    final l = AppLocalizations.of(context);
    final selected = m.value == _choice.model;
    final isDefault = m.value == _default.model;
    return ListTile(
      dense: true,
      selected: selected,
      selectedColor: kAccent,
      title: Row(
        children: [
          Flexible(child: Text(m.name, overflow: TextOverflow.ellipsis)),
          if (isDefault) ...[
            const SizedBox(width: 8),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(6),
                border: Border.all(color: Colors.white24),
              ),
              child: Text(l.modelDefault, style: const TextStyle(fontSize: 11, color: Colors.white54)),
            ),
          ],
        ],
      ),
      subtitle: m.description.isEmpty
          ? null
          : Text(m.description,
              maxLines: 2, overflow: TextOverflow.ellipsis, style: const TextStyle(color: Colors.white38)),
      trailing: selected ? const Icon(Icons.check, size: 18, color: kAccent) : null,
      onTap: () => _pick(m),
    );
  }

  List<Widget> _settings(BuildContext context, ModelCatalog catalog) {
    final l = AppLocalizations.of(context);
    final model = catalog.find(_choice.model);
    final effort = effortFor(model, _choice.effort);
    final efforts = model?.efforts ?? effortLevels;
    final unavailable = _a.fastUnavailable;
    return [
      if (effort != null)
        _row(
          l.modelEffort,
          DropdownButton<String>(
            value: effort,
            isDense: true,
            underline: const SizedBox(),
            items: [for (final e in efforts) DropdownMenuItem(value: e, child: Text(effortName(l, e)))],
            onChanged: (v) => v == null ? null : _set(_choice.copyWith(effort: v)),
          ),
        ),
      if (model?.fast ?? false) ...[
        _row(
          l.modelSpeed,
          DropdownButton<bool>(
            value: _choice.fast,
            isDense: true,
            underline: const SizedBox(),
            items: [
              DropdownMenuItem(value: false, child: Text(l.speedStandard)),
              DropdownMenuItem(value: true, child: Text(l.speedFast)),
            ],
            onChanged: (v) => v == null ? null : _set(_choice.copyWith(fast: v)),
          ),
        ),
        if (unavailable != null)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 6),
            child: Text(
              l.fastUnavailable(unavailable == 'extra_usage_disabled' ? l.fastExtraUsageDisabled : unavailable),
              style: const TextStyle(fontSize: 12, color: Colors.orangeAccent),
            ),
          ),
      ],
    ];
  }

  Widget _row(String label, Widget control) => Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
        child: Row(
          children: [
            Expanded(child: Text(label, style: const TextStyle(color: Colors.white70))),
            control,
          ],
        ),
      );
}
