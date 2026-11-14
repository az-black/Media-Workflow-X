import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../../core/constants/app_colors.dart';

class AiModelScaleDropdown extends StatefulWidget {
  final List<String> models;
  final String selectedModel;
  final Map<String, int> modelScales;
  final ValueChanged<String> onModelSelected;
  final void Function(String model, int scale) onModelScaleChanged;
  final double height;

  const AiModelScaleDropdown({
    super.key,
    required this.models,
    required this.selectedModel,
    required this.modelScales,
    required this.onModelSelected,
    required this.onModelScaleChanged,
    this.height = 44,
  });

  @override
  State<AiModelScaleDropdown> createState() => _AiModelScaleDropdownState();
}

class _AiModelScaleDropdownState extends State<AiModelScaleDropdown> {
  final GlobalKey _triggerKey = GlobalKey();
  final TextEditingController _selectedScaleController = TextEditingController();
  final FocusNode _selectedScaleFocus = FocusNode();

  final Map<String, TextEditingController> _rowControllers = {};
  final Map<String, FocusNode> _rowFocusNodes = {};

  OverlayEntry? _overlayEntry;
  bool _isHovered = false;

  bool get _isMenuOpen => _overlayEntry != null;

  int _scaleFor(String model) => widget.modelScales[model] ?? 4;

  @override
  void initState() {
    super.initState();
    _selectedScaleController.text = _scaleFor(widget.selectedModel).toString();
    _selectedScaleFocus.addListener(_handleSelectedScaleBlur);
    _syncControllersWithWidget();
  }

  @override
  void didUpdateWidget(covariant AiModelScaleDropdown oldWidget) {
    super.didUpdateWidget(oldWidget);
    _syncControllersWithWidget();
    if (_overlayEntry != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) {
          _overlayEntry?.markNeedsBuild();
        }
      });
    }
  }

  @override
  void dispose() {
    _removeOverlay();
    _selectedScaleFocus.removeListener(_handleSelectedScaleBlur);
    _selectedScaleFocus.dispose();
    _selectedScaleController.dispose();
    for (final fn in _rowFocusNodes.values) {
      fn.dispose();
    }
    for (final c in _rowControllers.values) {
      c.dispose();
    }
    _rowFocusNodes.clear();
    _rowControllers.clear();
    super.dispose();
  }

  void _handleSelectedScaleBlur() {
    if (!_selectedScaleFocus.hasFocus) {
      _normalizeControllerText(
        _selectedScaleController,
        widget.selectedModel,
      );
    }
  }

  void _normalizeControllerText(TextEditingController controller, String model) {
    final parsed = int.tryParse(controller.text.trim());
    final fallback = _scaleFor(model);
    if (parsed == null || parsed < 1) {
      controller.text = fallback.toString();
      controller.selection = TextSelection.collapsed(
        offset: controller.text.length,
      );
      return;
    }
    final normalized = parsed.clamp(1, 16);
    if (normalized.toString() != controller.text) {
      controller.text = normalized.toString();
      controller.selection = TextSelection.collapsed(
        offset: controller.text.length,
      );
    }
  }

  void _syncControllersWithWidget() {
    final expectedSelected = _scaleFor(widget.selectedModel).toString();
    if (!_selectedScaleFocus.hasFocus &&
        _selectedScaleController.text != expectedSelected) {
      _selectedScaleController.text = expectedSelected;
    }

    final activeModels = widget.models.toSet();
    final staleKeys = _rowControllers.keys
        .where((k) => !activeModels.contains(k))
        .toList();
    for (final k in staleKeys) {
      _rowFocusNodes.remove(k)?.dispose();
      _rowControllers.remove(k)?.dispose();
    }

    for (final model in widget.models) {
      final expected = _scaleFor(model).toString();
      final controller = _rowControllers.putIfAbsent(
        model,
        () => TextEditingController(text: expected),
      );
      final focus = _rowFocusNodes.putIfAbsent(model, () {
        final node = FocusNode();
        node.addListener(() {
          if (!node.hasFocus && mounted) {
            _normalizeControllerText(controller, model);
          }
        });
        return node;
      });
      if (!focus.hasFocus && controller.text != expected) {
        controller.text = expected;
      }
    }
  }

  void _onScaleTextChanged(String model, String rawValue) {
    final parsed = int.tryParse(rawValue.trim());
    if (parsed == null || parsed < 1) {
      return;
    }
    final normalized = parsed.clamp(1, 16);
    widget.onModelScaleChanged(model, normalized);

    if (model == widget.selectedModel && !_selectedScaleFocus.hasFocus) {
      final str = normalized.toString();
      if (_selectedScaleController.text != str) {
        _selectedScaleController.text = str;
      }
    }
    final rowController = _rowControllers[model];
    final rowFocus = _rowFocusNodes[model];
    if (rowController != null && rowFocus != null && !rowFocus.hasFocus) {
      final str = normalized.toString();
      if (rowController.text != str) {
        rowController.text = str;
      }
    }
  }

  void _toggleMenu() {
    if (_isMenuOpen) {
      _closeMenu();
    } else {
      _openMenu();
    }
  }

  void _openMenu() {
    if (_isMenuOpen || widget.models.isEmpty) return;
    _syncControllersWithWidget();
    final overlay = Overlay.of(context);
    final entry = OverlayEntry(builder: _buildOverlay);
    _overlayEntry = entry;
    overlay.insert(entry);
    if (mounted) setState(() {});
  }

  void _closeMenu() {
    if (!_isMenuOpen) return;
    _normalizeControllerText(_selectedScaleController, widget.selectedModel);
    for (final model in widget.models) {
      final c = _rowControllers[model];
      if (c != null) _normalizeControllerText(c, model);
    }
    _removeOverlay();
    if (mounted) setState(() {});
  }

  void _removeOverlay() {
    _overlayEntry?.remove();
    _overlayEntry = null;
  }

  Widget _buildOverlay(BuildContext overlayContext) {
    final triggerBox =
        _triggerKey.currentContext?.findRenderObject() as RenderBox?;
    final mediaSize = MediaQuery.of(overlayContext).size;

    Rect anchorRect = Rect.fromLTWH(
      mediaSize.width * 0.5,
      mediaSize.height - 160,
      320,
      widget.height,
    );
    if (triggerBox != null && triggerBox.attached) {
      final topLeft = triggerBox.localToGlobal(Offset.zero);
      anchorRect = topLeft & triggerBox.size;
    }

    const rowHeight = 40.0;
    const verticalPad = 12.0;
    final desiredHeight = math.min(
      widget.models.length * rowHeight + verticalPad,
      260.0,
    );
    final popupWidth = math.min(
      math.max(anchorRect.width, 320.0),
      math.max(220.0, mediaSize.width - 24.0),
    );
    final left = (anchorRect.right - popupWidth)
        .clamp(12.0, math.max(12.0, mediaSize.width - popupWidth - 12.0))
        .toDouble();

    final spaceBelow = mediaSize.height - anchorRect.bottom - 12.0;
    final spaceAbove = anchorRect.top - 12.0;
    final openBelow = spaceBelow >= desiredHeight || spaceBelow >= spaceAbove;
    final maxAllowedHeight = math.max(
      120.0,
      openBelow ? spaceBelow : spaceAbove,
    );
    final popupHeight = math.min(desiredHeight, maxAllowedHeight);
    final top = openBelow
        ? anchorRect.bottom + 6.0
        : math.max(12.0, anchorRect.top - popupHeight - 6.0);

    return CallbackShortcuts(
      bindings: <ShortcutActivator, VoidCallback>{
        const SingleActivator(LogicalKeyboardKey.escape): _closeMenu,
      },
      child: Stack(
        children: [
          Positioned.fill(
            child: GestureDetector(
              behavior: HitTestBehavior.translucent,
              onTap: _closeMenu,
            ),
          ),
          Positioned(
            left: left,
            top: top,
            width: popupWidth,
            child: Material(
              color: Colors.transparent,
              child: Container(
                key: const Key('ai_model_popup_menu'),
                constraints: BoxConstraints(maxHeight: popupHeight),
                padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 6),
                decoration: BoxDecoration(
                  color: AppColors.surface,
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(color: AppColors.borderCyan, width: 1.5),
                  boxShadow: const [
                    BoxShadow(
                      color: Colors.black54,
                      blurRadius: 14,
                      offset: Offset(0, 6),
                    ),
                  ],
                ),
                child: ListView.builder(
                  padding: EdgeInsets.zero,
                  shrinkWrap: true,
                  itemCount: widget.models.length,
                  itemBuilder: (ctx, index) {
                    final model = widget.models[index];
                    final isSelected = model == widget.selectedModel;
                    final controller = _rowControllers[model]!;
                    final focusNode = _rowFocusNodes[model]!;

                    return Container(
                      key: Key('ai_model_option_$model'),
                      height: rowHeight,
                      padding: const EdgeInsets.symmetric(horizontal: 6),
                      decoration: BoxDecoration(
                        color: isSelected
                            ? AppColors.primaryCyan.withValues(alpha: 0.12)
                            : Colors.transparent,
                        borderRadius: BorderRadius.circular(7),
                      ),
                      child: Row(
                        children: [
                          Expanded(
                            child: InkWell(
                              borderRadius: BorderRadius.circular(6),
                              onTap: () {
                                widget.onModelSelected(model);
                                _closeMenu();
                              },
                              child: Padding(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 4,
                                  vertical: 6,
                                ),
                                child: Row(
                                  children: [
                                    Icon(
                                      isSelected
                                          ? Icons.check
                                          : Icons.circle_outlined,
                                      size: 14,
                                      color: isSelected
                                          ? AppColors.primaryCyan
                                          : Colors.white30,
                                    ),
                                    const SizedBox(width: 8),
                                    Expanded(
                                      child: Text(
                                        model,
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                        style: TextStyle(
                                          color: isSelected
                                              ? AppColors.primaryCyan
                                              : Colors.white,
                                          fontWeight: isSelected
                                              ? FontWeight.bold
                                              : FontWeight.normal,
                                          fontSize: 12,
                                        ),
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            ),
                          ),
                          const SizedBox(width: 8),
                          const Text(
                            'Scale',
                            style: TextStyle(
                              color: AppColors.textMuted,
                              fontSize: 10,
                            ),
                          ),
                          const SizedBox(width: 6),
                          _ScaleIntInputBox(
                            fieldKey: Key('ai_model_scale_input_$model'),
                            controller: controller,
                            focusNode: focusNode,
                            tooltip: 'Scale integer untuk $model',
                            onChanged: (val) => _onScaleTextChanged(model, val),
                            onSubmitted: (_) =>
                                _normalizeControllerText(controller, model),
                          ),
                          const SizedBox(width: 3),
                          const Text(
                            'x',
                            style: TextStyle(
                              color: AppColors.primaryCyan,
                              fontSize: 11,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                        ],
                      ),
                    );
                  },
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      onEnter: (_) => setState(() => _isHovered = true),
      onExit: (_) => setState(() => _isHovered = false),
      child: Container(
        key: _triggerKey,
        height: widget.height,
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 2),
        decoration: BoxDecoration(
          color: (_isHovered || _isMenuOpen)
              ? AppColors.cardHover
              : AppColors.cardBackground,
          borderRadius: BorderRadius.circular(10),
          border: Border.all(
            color: (_isHovered || _isMenuOpen)
                ? AppColors.primaryCyan
                : AppColors.borderCyan,
            width: 1.5,
          ),
          boxShadow: (_isHovered || _isMenuOpen)
              ? AppColors.cyanGlowShadow
              : null,
        ),
        child: Row(
          children: [
            Expanded(
              child: InkWell(
                key: const Key('ai_model_dropdown_trigger'),
                onTap: _toggleMenu,
                borderRadius: BorderRadius.circular(8),
                child: Row(
                  children: [
                    const Icon(
                      Icons.auto_awesome,
                      color: AppColors.primaryCyan,
                      size: 20,
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          const Text(
                            'Model AI',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              color: AppColors.textWhite,
                              fontSize: 11,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                          Text(
                            widget.selectedModel,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              color: AppColors.primaryCyan,
                              fontSize: 9.5,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(width: 8),
            const Text(
              'Scale',
              style: TextStyle(
                color: AppColors.textMuted,
                fontSize: 10,
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(width: 5),
            _ScaleIntInputBox(
              fieldKey: const Key('ai_model_selected_scale_input'),
              controller: _selectedScaleController,
              focusNode: _selectedScaleFocus,
              tooltip: 'Scale integer manual untuk ${widget.selectedModel}',
              onChanged: (val) =>
                  _onScaleTextChanged(widget.selectedModel, val),
              onSubmitted: (_) => _normalizeControllerText(
                _selectedScaleController,
                widget.selectedModel,
              ),
            ),
            const SizedBox(width: 3),
            const Text(
              'x',
              style: TextStyle(
                color: AppColors.primaryCyan,
                fontSize: 11,
                fontWeight: FontWeight.bold,
              ),
            ),
            const SizedBox(width: 4),
            InkWell(
              onTap: _toggleMenu,
              borderRadius: BorderRadius.circular(6),
              child: Icon(
                _isMenuOpen ? Icons.arrow_drop_up : Icons.arrow_drop_down,
                color: AppColors.primaryCyan,
                size: 22,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _ScaleIntInputBox extends StatelessWidget {
  final Key fieldKey;
  final TextEditingController controller;
  final FocusNode focusNode;
  final String tooltip;
  final ValueChanged<String> onChanged;
  final ValueChanged<String> onSubmitted;

  const _ScaleIntInputBox({
    required this.fieldKey,
    required this.controller,
    required this.focusNode,
    required this.tooltip,
    required this.onChanged,
    required this.onSubmitted,
  });

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: tooltip,
      child: SizedBox(
        width: 40,
        height: 28,
        child: TextField(
          key: fieldKey,
          controller: controller,
          focusNode: focusNode,
          keyboardType: TextInputType.number,
          textInputAction: TextInputAction.done,
          textAlign: TextAlign.center,
          style: const TextStyle(
            color: AppColors.textWhite,
            fontSize: 11.5,
            fontWeight: FontWeight.bold,
          ),
          inputFormatters: [
            FilteringTextInputFormatter.digitsOnly,
            LengthLimitingTextInputFormatter(2),
          ],
          decoration: InputDecoration(
            isDense: true,
            filled: true,
            fillColor: AppColors.background,
            contentPadding: const EdgeInsets.symmetric(
              horizontal: 4,
              vertical: 6,
            ),
            enabledBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(6),
              borderSide: const BorderSide(
                color: AppColors.borderCyan,
                width: 1,
              ),
            ),
            focusedBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(6),
              borderSide: const BorderSide(
                color: AppColors.primaryCyan,
                width: 1.5,
              ),
            ),
          ),
          onChanged: onChanged,
          onSubmitted: onSubmitted,
        ),
      ),
    );
  }
}
