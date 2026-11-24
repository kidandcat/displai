/// Form rendering. Field values live in the surface's genui [DataModel]
/// under `/forms/<formId>/<field>`, so the model can read them (get_state)
/// and fill them (update values) while the user edits.
library;

import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:genui/genui.dart';

import '../vault/vault_strings.dart';
import 'theme.dart';
import 'view_model.dart';

/// While above zero, secret fields are drawn obscured even if the user revealed them (the
/// display is being captured for the brain).
final ValueNotifier<int> secretsHidden = ValueNotifier(0);

/// Returns the names of required fields that have no value.
List<String> missingRequired(List<Map> fields, Map values) => [
  for (final f in fields)
    if (f['required'] == true && _isEmptyValue(values[f['name']], f['type']))
      f['name'] as String,
];

bool _isEmptyValue(Object? v, Object? type) {
  if (v == null) return true;
  if (v is String) return v.trim().isEmpty;
  if (type == 'checkbox') return v != true;
  return false;
}

String formatFieldValue(Object? v) {
  if (v == null) return '';
  if (v is double && v == v.roundToDouble()) return v.toInt().toString();
  return v.toString();
}

class DisplayForm extends StatefulWidget {
  const DisplayForm({
    super.key,
    required this.formId,
    required this.data,
    required this.dataContext,
    required this.onSubmit,
    this.onCancel,
  });

  final String formId;
  final Map<String, Object?> data;
  final DataContext dataContext;
  final VoidCallback onSubmit;

  /// Shown as a second button when the form has a `cancel` label.
  final VoidCallback? onCancel;

  @override
  State<DisplayForm> createState() => _DisplayFormState();
}

class _DisplayFormState extends State<DisplayForm> {
  late final ValueNotifier<Object?> _values;
  final Map<String, TextEditingController> _text = {};
  final Map<String, FocusNode> _focus = {};
  Set<String> _errors = {};

  String get _path => '/forms/${widget.formId}';

  @override
  void initState() {
    super.initState();
    _values = widget.dataContext.dataModel.subscribe<Object>(DataPath(_path));
    _values.addListener(_onValues);
  }

  @override
  void dispose() {
    _values.removeListener(_onValues);
    _values.dispose();
    for (final c in _text.values) {
      c.dispose();
    }
    for (final f in _focus.values) {
      f.dispose();
    }
    super.dispose();
  }

  void _onValues() {
    if (mounted) setState(() {});
  }

  Map<String, Object?> get _current {
    final Object? v = _values.value;
    return v is Map ? Map<String, Object?>.from(v) : <String, Object?>{};
  }

  void _set(String name, Object? value) {
    widget.dataContext.update(DataPath('$_path/$name'), value);
    if (_errors.contains(name)) setState(() => _errors.remove(name));
  }

  List<Map<String, Object?>> get _fields => [
    for (final f in listOf(widget.data['fields']))
      if (f is Map) f.cast<String, Object?>(),
  ];

  void _submit() {
    final List<String> missing = missingRequired(_fields, _current);
    if (missing.isNotEmpty) {
      setState(() => _errors = missing.toSet());
      return;
    }
    FocusScope.of(context).unfocus();
    widget.onSubmit();
  }

  @override
  Widget build(BuildContext context) {
    final t = DisplayText.of(context);
    final double s = t.s;
    final Map<String, Object?> values = _current;
    final String? intro = widget.data['intro'] as String?;
    final bool submitted = widget.data['submitted'] == true;
    final String submitLabel =
        (widget.data['submit'] as String?) ?? DisplayStrings.submit;
    final String? cancelLabel = widget.data['cancel'] as String?;
    final String submittedLabel = widget.data['vault'] != null
        ? VaultStrings.saved
        : DisplayStrings.submitted;

    final List<Map<String, Object?>> fields = _fields;
    final double pad = 28 * s;
    final double colGap = 32 * s;
    final double rowGap = 20 * s;

    return LayoutBuilder(
      builder: (context, constraints) {
        // Wide screens lay the fields out in two columns.
        final bool twoCols =
            constraints.maxWidth >= 900 * s && fields.length > 2;
        final double panelW = math.min(
          constraints.maxWidth,
          (twoCols ? 1300 : 980) * s,
        );
        // The panel's border also takes room, so the field width comes from the inner width.
        final Widget fieldsView = LayoutBuilder(
          builder: (context, inner) {
            final double fieldW = twoCols
                ? ((inner.maxWidth - colGap) / 2).floorToDouble()
                : inner.maxWidth;
            return Wrap(
              spacing: colGap,
              runSpacing: rowGap,
              children: [
                for (final f in fields)
                  SizedBox(
                    width: fieldW,
                    child: _FieldShell(
                      label: (f['label'] as String?) ?? (f['name'] as String),
                      required: f['required'] == true,
                      error: _errors.contains(f['name']),
                      child: _field(f, values[f['name']], t),
                    ),
                  ),
              ],
            );
          },
        );
        // With a bounded height (a form view) the fields scroll and the submit button stays
        // visible; inside a show body the form takes its natural height.
        final bool bounded = constraints.hasBoundedHeight;
        return Align(
          alignment: Alignment.topLeft,
          child: Container(
            width: panelW,
            padding: EdgeInsets.all(pad),
            decoration: panelDecoration(s),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              mainAxisSize: MainAxisSize.min,
              children: [
                if (intro != null) ...[
                  RichDisplayText(intro, style: t.bodyMuted),
                  SizedBox(height: rowGap),
                ],
                if (bounded)
                  Flexible(
                    // The bottom padding is where the fade goes, so it only covers fields
                    // when they do not fit (and hints that they scroll).
                    child: ShaderMask(
                      blendMode: BlendMode.dstIn,
                      shaderCallback: (rect) => LinearGradient(
                        begin: Alignment.topCenter,
                        end: Alignment.bottomCenter,
                        colors: const [
                          Colors.white,
                          Colors.white,
                          Colors.transparent,
                        ],
                        stops: [
                          0,
                          1 - 18 * s / rect.height.clamp(1, double.infinity),
                          1,
                        ],
                      ).createShader(rect),
                      child: SingleChildScrollView(
                        padding: EdgeInsets.only(bottom: 18 * s),
                        child: fieldsView,
                      ),
                    ),
                  )
                else
                  fieldsView,
                SizedBox(height: 26 * s),
                Row(
                  children: [
                    Flexible(
                      child: _SubmitButton(
                        label: submitted
                            ? '$submitLabel  ·  $submittedLabel ✓'
                            : submitLabel,
                        onTap: _submit,
                      ),
                    ),
                    if (cancelLabel != null && widget.onCancel != null && !submitted) ...[
                      SizedBox(width: 16 * s),
                      Flexible(
                        child: _CancelButton(
                          label: cancelLabel,
                          onTap: () {
                            FocusScope.of(context).unfocus();
                            widget.onCancel!();
                          },
                        ),
                      ),
                    ],
                  ],
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  TextEditingController _controllerFor(String name, String text) {
    final TextEditingController c = _text.putIfAbsent(
      name,
      () => TextEditingController(text: text),
    );
    final FocusNode focus = _focus.putIfAbsent(name, FocusNode.new);
    // External updates (the model filling the field) win unless the user is
    // typing in it right now.
    if (!focus.hasFocus && c.text != text) c.text = text;
    return c;
  }

  Widget _field(Map<String, Object?> f, Object? value, DisplayText t) {
    final String name = f['name'] as String;
    final double s = t.s;
    switch (f['type']) {
      case 'number':
      case 'text':
        final bool number = f['type'] == 'number';
        return TextField(
          key: ValueKey('field-$name'),
          controller: _controllerFor(name, formatFieldValue(value)),
          focusNode: _focus[name],
          style: t.body,
          cursorColor: DisplayColors.accent,
          keyboardType: number
              ? const TextInputType.numberWithOptions(decimal: true)
              : TextInputType.text,
          inputFormatters: number
              ? [FilteringTextInputFormatter.allow(RegExp(r'[-0-9.,]'))]
              : null,
          decoration: _inputDecoration(s, f['placeholder'] as String?),
          onChanged: (text) {
            if (!number) {
              _set(name, text);
            } else {
              _set(name, num.tryParse(text.replaceAll(',', '.')));
            }
          },
          onSubmitted: (_) => _submit(),
        );
      case 'secret':
        return _SecretField(
          key: ValueKey('field-$name'),
          name: name,
          controller: _controllerFor(name, formatFieldValue(value)),
          focusNode: _focus[name]!,
          decoration: _inputDecoration(s, f['placeholder'] as String?),
          onChanged: (text) => _set(name, text),
          onSubmitted: _submit,
        );
      case 'date':
        final String? v = value as String?;
        return _DateField(
          key: ValueKey('field-$name'),
          value: v,
          onPick: (d) => _set(name, d),
        );
      case 'select':
        final List<String> options = [
          for (final o in listOf(f['options'])) cellText(o),
        ];
        final int ord = (f['_o'] as num?)?.toInt() ?? 0;
        return Wrap(
          spacing: 12 * s,
          runSpacing: 12 * s,
          children: [
            for (var i = 0; i < options.length; i++)
              _Choice(
                key: ValueKey('choice-$name-$i'),
                label: options[i],
                number: ord > 0 ? ord + i : null,
                selected: value == options[i],
                onTap: () => _set(name, options[i]),
              ),
          ],
        );
      case 'checkbox':
        final bool on = value == true;
        return Align(
          alignment: Alignment.centerLeft,
          child: GestureDetector(
            key: ValueKey('field-$name'),
            onTap: () => _set(name, !on),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                // Scaled with the display, taking the room it is drawn in.
                SizedBox(
                  width: 60 * s,
                  height: 38 * s,
                  child: FittedBox(
                    child: Switch(
                      materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                      value: on,
                      onChanged: (v) => _set(name, v),
                      activeThumbColor: DisplayColors.background,
                      activeTrackColor: DisplayColors.accent,
                    ),
                  ),
                ),
                SizedBox(width: 14 * s),
                Text(
                  on ? DisplayStrings.yes : DisplayStrings.no,
                  style: t.body,
                ),
              ],
            ),
          ),
        );
      case 'slider':
        final double min = (f['min'] as num?)?.toDouble() ?? 0;
        double max = (f['max'] as num?)?.toDouble() ?? 100;
        if (max <= min) max = min + 1;
        final double? step = (f['step'] as num?)?.toDouble();
        final double v = ((value as num?)?.toDouble() ?? min).clamp(min, max);
        final int? divisions = step != null && step > 0
            ? ((max - min) / step).round().clamp(1, 1000)
            : null;
        return Row(
          children: [
            Expanded(
              child: Slider(
                key: ValueKey('field-$name'),
                value: v,
                min: min,
                max: max,
                divisions: divisions,
                onChanged: (x) {
                  final num out = (step == null || step % 1 == 0)
                      ? x.round()
                      : double.parse(x.toStringAsFixed(2));
                  _set(name, out);
                },
              ),
            ),
            SizedBox(
              width: 90 * s,
              child: Text(
                formatFieldValue(value ?? min),
                style: t.value,
                textAlign: TextAlign.right,
              ),
            ),
          ],
        );
    }
    return const SizedBox.shrink();
  }
}

InputDecoration _inputDecoration(double s, String? hint) {
  OutlineInputBorder border(Color c, [double w = 1.2]) => OutlineInputBorder(
    borderRadius: BorderRadius.circular(12 * s),
    borderSide: BorderSide(color: c, width: w),
  );
  return InputDecoration(
    hintText: hint,
    hintStyle: TextStyle(color: DisplayColors.textFaint, fontSize: 20 * s),
    filled: true,
    fillColor: DisplayColors.background,
    isDense: true,
    contentPadding: EdgeInsets.symmetric(horizontal: 18 * s, vertical: 16 * s),
    enabledBorder: border(DisplayColors.border),
    focusedBorder: border(DisplayColors.accent, 1.6),
    border: border(DisplayColors.border),
  );
}

class _FieldShell extends StatelessWidget {
  const _FieldShell({
    required this.label,
    required this.required,
    required this.error,
    required this.child,
  });

  final String label;
  final bool required;
  final bool error;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final t = DisplayText.of(context);
    final double s = t.s;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text.rich(
          TextSpan(
            text: label,
            children: [
              if (required)
                const TextSpan(
                  text: ' *',
                  style: TextStyle(color: DisplayColors.accent),
                ),
            ],
          ),
          style: t.bodyMuted.copyWith(
            fontSize: 19 * s,
            fontWeight: FontWeight.w600,
          ),
        ),
        SizedBox(height: 8 * s),
        child,
        if (error) ...[
          SizedBox(height: 6 * s),
          Text(
            DisplayStrings.required,
            style: TextStyle(color: DisplayColors.negative, fontSize: 16 * s),
          ),
        ],
      ],
    );
  }
}

class _Choice extends StatelessWidget {
  const _Choice({
    super.key,
    required this.label,
    required this.number,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final int? number;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final t = DisplayText.of(context);
    final double s = t.s;
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        onTap: onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 140),
          padding: EdgeInsets.fromLTRB(
            number != null ? 7 * s : 20 * s,
            7 * s,
            20 * s,
            7 * s,
          ),
          decoration: BoxDecoration(
            color: selected
                ? const Color(0x33A78BFA)
                : DisplayColors.background,
            borderRadius: BorderRadius.circular(40 * s),
            border: Border.all(
              color: selected ? DisplayColors.accent : DisplayColors.border,
              width: selected ? 1.6 : 1.2,
            ),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (number != null) ...[
                OrdinalBadge(number!, filled: selected),
                SizedBox(width: 12 * s),
              ],
              Text(
                label,
                style: t.body.copyWith(
                  fontSize: 20 * s,
                  color: selected
                      ? DisplayColors.text
                      : DisplayColors.textMuted,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _DateField extends StatelessWidget {
  const _DateField({super.key, required this.value, required this.onPick});

  final String? value;
  final ValueChanged<String> onPick;

  Future<void> _pick(BuildContext context) async {
    final DateTime now = DateTime.now();
    final DateTime initial = DateTime.tryParse(value ?? '') ?? now;
    final DateTime? picked = await showDatePicker(
      context: context,
      initialDate: initial,
      firstDate: DateTime(now.year - 100),
      lastDate: DateTime(now.year + 20),
      builder: (context, child) =>
          Theme(data: displayThemeData(), child: child!),
    );
    if (picked == null) return;
    final String iso =
        '${picked.year.toString().padLeft(4, '0')}-'
        '${picked.month.toString().padLeft(2, '0')}-'
        '${picked.day.toString().padLeft(2, '0')}';
    onPick(iso);
  }

  @override
  Widget build(BuildContext context) {
    final t = DisplayText.of(context);
    final double s = t.s;
    return Align(
      alignment: Alignment.centerLeft,
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        child: GestureDetector(
          onTap: () => _pick(context),
          child: Container(
            padding: EdgeInsets.symmetric(horizontal: 18 * s, vertical: 14 * s),
            decoration: BoxDecoration(
              color: DisplayColors.background,
              borderRadius: BorderRadius.circular(12 * s),
              border: Border.all(color: DisplayColors.border, width: 1.2),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  Icons.calendar_today_outlined,
                  color: DisplayColors.accent,
                  size: 22 * s,
                ),
                SizedBox(width: 14 * s),
                Text(
                  value ?? DisplayStrings.pickDate,
                  style: t.body.copyWith(
                    color: value == null
                        ? DisplayColors.textFaint
                        : DisplayColors.text,
                    fontFeatures: const [FontFeature.tabularFigures()],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// A text field drawn obscured, with a show/hide toggle. Never revealed while the display is
/// captured ([secretsHidden]).
class _SecretField extends StatefulWidget {
  const _SecretField({
    super.key,
    required this.name,
    required this.controller,
    required this.focusNode,
    required this.decoration,
    required this.onChanged,
    required this.onSubmitted,
  });

  final String name;
  final TextEditingController controller;
  final FocusNode focusNode;
  final InputDecoration decoration;
  final ValueChanged<String> onChanged;
  final VoidCallback onSubmitted;

  @override
  State<_SecretField> createState() => _SecretFieldState();
}

class _SecretFieldState extends State<_SecretField> {
  bool _revealed = false;

  @override
  Widget build(BuildContext context) {
    final t = DisplayText.of(context);
    final double s = t.s;
    return ValueListenableBuilder<int>(
      valueListenable: secretsHidden,
      builder: (context, hidden, _) {
        final bool show = _revealed && hidden == 0;
        return TextField(
          controller: widget.controller,
          focusNode: widget.focusNode,
          style: t.body,
          cursorColor: DisplayColors.accent,
          obscureText: !show,
          obscuringCharacter: '•',
          autocorrect: false,
          enableSuggestions: false,
          enableIMEPersonalizedLearning: false,
          keyboardType: TextInputType.visiblePassword,
          decoration: widget.decoration.copyWith(
            suffixIcon: Padding(
              padding: EdgeInsets.only(right: 6 * s),
              child: IconButton(
                key: ValueKey('reveal-${widget.name}'),
                tooltip: show ? VaultStrings.hide : VaultStrings.show,
                iconSize: 24 * s,
                color: DisplayColors.textMuted,
                icon: Icon(show ? Icons.visibility_off_outlined : Icons.visibility_outlined),
                onPressed: () => setState(() => _revealed = !_revealed),
              ),
            ),
          ),
          onChanged: widget.onChanged,
          onSubmitted: (_) => widget.onSubmitted(),
        );
      },
    );
  }
}

class _CancelButton extends StatelessWidget {
  const _CancelButton({required this.label, required this.onTap});

  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final double s = DisplayScale.of(context);
    return Selectable(
      onTap: onTap,
      builder: (context, hover) => AnimatedContainer(
        key: const ValueKey('form-cancel'),
        duration: const Duration(milliseconds: 140),
        padding: EdgeInsets.symmetric(horizontal: 30 * s, vertical: 16 * s),
        decoration: BoxDecoration(
          color: hover ? DisplayColors.border : Colors.transparent,
          borderRadius: BorderRadius.circular(14 * s),
          border: Border.all(color: DisplayColors.border, width: 1.2),
        ),
        child: Text(
          label,
          style: TextStyle(
            fontSize: 21 * s,
            fontWeight: FontWeight.w600,
            color: DisplayColors.textMuted,
          ),
        ),
      ),
    );
  }
}

class _SubmitButton extends StatelessWidget {
  const _SubmitButton({required this.label, required this.onTap});

  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final double s = DisplayScale.of(context);
    return Selectable(
      onTap: onTap,
      builder: (context, hover) => AnimatedContainer(
        key: const ValueKey('form-submit'),
        duration: const Duration(milliseconds: 140),
        padding: EdgeInsets.symmetric(horizontal: 34 * s, vertical: 17 * s),
        decoration: BoxDecoration(
          color: hover ? DisplayColors.accentSecondary : DisplayColors.accent,
          borderRadius: BorderRadius.circular(14 * s),
        ),
        child: Text(
          label,
          style: TextStyle(
            fontSize: 21 * s,
            fontWeight: FontWeight.w700,
            color: DisplayColors.background,
          ),
        ),
      ),
    );
  }
}
