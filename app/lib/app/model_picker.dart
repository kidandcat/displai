import 'package:flutter/material.dart';

import '../brain/fallback.dart';
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
      'ultra': l.effortUltra,
    }[effort] ??
    effort;

/// Picks the provider (Claude, Antigravity or Codex), model, effort and speed of the conversation
/// and, on its second tab, of the workers, each with its ordered backups (the next one takes over
/// when a provider hits its usage limit). The list comes from the provider's installed agent
/// (Claude Code's newest model of each family, then the previous ones folded away; Antigravity's
/// and Codex's as they list them). The third tab shows each provider's status. Above the status
/// bar on the desktop; on a phone, across the screen.
class ModelPicker extends StatefulWidget {
  const ModelPicker({super.key, required this.assistant, this.workers = false});

  final AssistantSettings assistant;

  /// Opens on the workers' tab.
  final bool workers;

  @override
  State<ModelPicker> createState() => _ModelPickerState();
}

enum _Tab { conversation, workers, providers }

class _ModelPickerState extends State<ModelPicker> {
  late _Tab _tab = widget.workers ? _Tab.workers : _Tab.conversation;
  bool _showPrevious = false;
  bool _showBackups = false;
  String _query = '';

  AssistantSettings get _a => widget.assistant;

  bool get _workers => _tab == _Tab.workers;

  ModelChoice get _choice => _workers ? _a.workerModel : _a.brainModel;

  List<ModelChoice> get _backups => _workers ? _a.workerFallbacks : _a.brainFallbacks;

  void _setBackups(List<ModelChoice> b) => _workers ? _a.setWorkerFallbacks(b) : _a.setBrainFallbacks(b);

  ModelChoice get _default =>
      defaultModel(_choice.provider, workers: _workers, catalog: _a.catalogFor(_choice.provider));

  bool _narrow(BuildContext context) => MediaQuery.sizeOf(context).width < 600;

  void _set(ModelChoice c) => _workers ? _a.setWorkerModel(c) : _a.setBrainModel(c);

  void _pick(BrainModel m) => _set(_choice.copyWith(model: m.value));

  /// Another provider: its default model, at the same effort. A backup on that provider becomes
  /// the choice, and the choice it replaces takes its place among the backups.
  void _pickProvider(BrainProvider p) {
    if (p == _choice.provider) return;
    final backups = _backups;
    final i = backups.indexWhere((b) => b.provider == p);
    if (i >= 0) {
      _setBackups([...backups]..[i] = _choice);
      _set(backups[i]);
    } else {
      final d = defaultModel(p, workers: _workers, catalog: _a.catalogFor(p));
      _set(d.copyWith(effort: _choice.effort));
    }
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
          child: SegmentedButton<_Tab>(
            showSelectedIcon: false,
            segments: [
              ButtonSegment(value: _Tab.conversation, label: Text(l.modelConversation)),
              ButtonSegment(value: _Tab.workers, label: Text(l.modelWorkers)),
              ButtonSegment(value: _Tab.providers, label: Text(l.modelProviders)),
            ],
            selected: {_tab},
            onSelectionChanged: (s) => setState(() => _tab = s.first),
          ),
        ),
        if (_tab == _Tab.providers) ..._providers(context) else ..._modelTab(context),
      ],
    );
  }

  /// The conversation's or the workers' choice: provider, model, effort and speed, and backups.
  List<Widget> _modelTab(BuildContext context) {
    final l = AppLocalizations.of(context);
    final provider = _choice.provider;
    final catalog = _a.catalogFor(provider);
    final theme = Theme.of(context);
    final narrow = _narrow(context);
    return [
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
      // Open backups scroll on a short screen.
      Flexible(
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (!_workers && _a.activeBrainModel.provider != provider)
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 4, 16, 4),
                  child: Text(l.modelOnBackup(provider.label, _modelName(_a.activeBrainModel)),
                      style: const TextStyle(fontSize: 12, color: Colors.orangeAccent)),
                ),
              const Divider(height: 1, color: Colors.white12),
              ..._backupList(context),
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 4, 16, 14),
                child: Text(_workers ? l.modelWorkersNote : '${l.modelConversationNote} ${l.modelProviderNote}',
                    style: theme.textTheme.bodySmall?.copyWith(color: Colors.white38)),
              ),
            ],
          ),
        ),
      ),
    ];
  }

  String _modelName(ModelChoice c) => _a.catalogFor(c.provider)?.find(c.model)?.name ?? c.model;

  /// When a limit ends: the time, with the day when it is not today.
  String _when(BuildContext context, DateTime t) {
    final m = MaterialLocalizations.of(context);
    final time = m.formatTimeOfDay(TimeOfDay.fromDateTime(t),
        alwaysUse24HourFormat: MediaQuery.of(context).alwaysUse24HourFormat);
    final now = DateTime.now();
    return t.year == now.year && t.month == now.month && t.day == now.day ? time : '${m.formatShortMonthDay(t)} $time';
  }

  /// Each provider, its status and what runs on it.
  List<Widget> _providers(BuildContext context) {
    final l = AppLocalizations.of(context);
    final unavailable = _a.unavailableProviders;
    final workersOn = fallbackChain(_a.workerModel, _a.workerFallbacks)
        .where((c) => !unavailable.contains(c.provider) && _a.providerOut(c.provider) == null)
        .firstOrNull
        ?.provider;
    return [
      for (final p in BrainProvider.values) _providerTile(context, p, workersOn),
      Padding(
        padding: const EdgeInsets.fromLTRB(16, 4, 16, 14),
        child: Text(l.providersNote, style: Theme.of(context).textTheme.bodySmall?.copyWith(color: Colors.white38)),
      ),
    ];
  }

  Widget _providerTile(BuildContext context, BrainProvider p, BrainProvider? workersOn) {
    final l = AppLocalizations.of(context);
    final out = _a.providerOut(p);
    final catalog = _a.catalogFor(p);
    final (status, color) = switch (out?.reason) {
      LimitReason.usage => (l.providerLimited(_when(context, out!.until)), Colors.orangeAccent),
      LimitReason.signIn => (l.providerSignedOut(_when(context, out!.until)), Colors.orangeAccent),
      null when _a.unavailableProviders.contains(p) => (l.providerUnavailable, Colors.white38),
      null when catalog == null => (l.providerChecking, Colors.white38),
      null => (l.providerReady, Colors.greenAccent),
    };
    final uses = [
      if (_a.activeBrainModel.provider == p) l.modelConversation,
      if (workersOn == p) l.modelWorkers,
    ];
    return ListTile(
      dense: true,
      leading: Icon(Icons.circle, size: 10, color: color),
      minLeadingWidth: 10,
      title: Row(
        children: [
          Text(p.label),
          const SizedBox(width: 8),
          Expanded(
            child: Text([p.agent, if (catalog != null && catalog.version.isNotEmpty) catalog.version].join(' '),
                overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 12, color: Colors.white38)),
          ),
        ],
      ),
      subtitle: Text([status, if (uses.isNotEmpty) l.providerUsedBy(uses.join(', '))].join(' · '),
          style: TextStyle(color: color == Colors.greenAccent ? Colors.white54 : color)),
    );
  }

  /// The ordered backups of this tab's choice, folded away.
  List<Widget> _backupList(BuildContext context) {
    final l = AppLocalizations.of(context);
    final backups = _backups;
    final used = {_choice.provider, for (final b in backups) b.provider};
    final addable = [
      for (final p in BrainProvider.values)
        if (!used.contains(p) && !_a.unavailableProviders.contains(p)) p,
    ];
    return [
      ListTile(
        dense: true,
        title: Text('${l.fallbacks} (${backups.length})', style: const TextStyle(color: Colors.white70)),
        subtitle: backups.isEmpty || _showBackups
            ? null
            : Text(backups.map((b) => '${b.provider.label} ${_modelName(b)}').join(' → '),
                maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(color: Colors.white38)),
        trailing: Icon(_showBackups ? Icons.expand_less : Icons.expand_more, color: Colors.white38),
        onTap: () => setState(() => _showBackups = !_showBackups),
      ),
      if (_showBackups) ...[
        if (backups.isEmpty)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 6),
            child: Text(l.fallbacksNone, style: const TextStyle(fontSize: 12, color: Colors.white38)),
          ),
        for (final (i, b) in backups.indexed) _backupRow(context, i, b, backups),
        Align(
          alignment: Alignment.centerLeft,
          child: Padding(
            padding: const EdgeInsets.only(left: 8),
            child: PopupMenuButton<BrainProvider>(
              enabled: addable.isNotEmpty,
              tooltip: l.fallbackAdd,
              itemBuilder: (_) => [for (final p in addable) PopupMenuItem(value: p, child: Text(p.label))],
              onSelected: (p) =>
                  _setBackups([...backups, defaultModel(p, workers: _workers, catalog: _a.catalogFor(p))]),
              child: Padding(
                padding: const EdgeInsets.all(8),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.add, size: 18, color: addable.isEmpty ? Colors.white24 : kAccent),
                    const SizedBox(width: 6),
                    Text(l.fallbackAdd, style: TextStyle(color: addable.isEmpty ? Colors.white24 : kAccent)),
                  ],
                ),
              ),
            ),
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 6),
          child: Text(l.fallbacksNote, style: const TextStyle(fontSize: 12, color: Colors.white38)),
        ),
      ],
    ];
  }

  /// A backup: its provider, a model of it, and buttons to move it up or down or remove it.
  Widget _backupRow(BuildContext context, int i, ModelChoice b, List<ModelChoice> backups) {
    final l = AppLocalizations.of(context);
    final models = _a.catalogFor(b.provider)?.all ?? const <BrainModel>[];
    final out = _a.providerOut(b.provider) != null || _a.unavailableProviders.contains(b.provider);
    void swap(int j) => _setBackups([...backups]
      ..[i] = backups[j]
      ..[j] = b);
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 4, 0),
      child: Row(
        children: [
          SizedBox(width: 22, child: Text('${i + 1}.', style: const TextStyle(color: Colors.white38))),
          SizedBox(
            width: 84,
            child: Text(b.provider.label, style: TextStyle(color: out ? Colors.orangeAccent : Colors.white70)),
          ),
          Expanded(
            child: models.any((m) => m.value == b.model)
                ? DropdownButton<String>(
                    value: b.model,
                    isDense: true,
                    isExpanded: true,
                    underline: const SizedBox(),
                    items: [
                      for (final m in models)
                        DropdownMenuItem(value: m.value, child: Text(m.name, overflow: TextOverflow.ellipsis)),
                    ],
                    onChanged: (v) => v == null ? null : _setBackups([...backups]..[i] = b.copyWith(model: v)),
                  )
                : Text(_modelName(b), overflow: TextOverflow.ellipsis),
          ),
          IconButton(
            tooltip: l.fallbackUp,
            visualDensity: VisualDensity.compact,
            icon: const Icon(Icons.arrow_upward, size: 16),
            onPressed: i == 0 ? null : () => swap(i - 1),
          ),
          IconButton(
            tooltip: l.fallbackDown,
            visualDensity: VisualDensity.compact,
            icon: const Icon(Icons.arrow_downward, size: 16),
            onPressed: i == backups.length - 1 ? null : () => swap(i + 1),
          ),
          IconButton(
            tooltip: l.fallbackRemove,
            visualDensity: VisualDensity.compact,
            icon: const Icon(Icons.close, size: 16),
            onPressed: () => _setBackups([...backups]..removeAt(i)),
          ),
        ],
      ),
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
