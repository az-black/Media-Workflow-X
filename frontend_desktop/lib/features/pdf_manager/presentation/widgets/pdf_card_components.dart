import 'dart:ui';
import 'package:flutter/material.dart';
import '../../../../core/constants/app_colors.dart';
import '../../../../shared/widgets/dashed_container.dart';
import '../../../../core/models/pdf_models.dart';
export '../../../../core/models/pdf_models.dart';

class PoolThumbnailCard extends StatefulWidget {
  final String? label;
  final String? subLabel;
  final bool isAddOnly;
  final bool isSelected;
  final bool isFirstSlot;
  final VoidCallback? onTap;
  final VoidCallback? onTapLabel;
  final VoidCallback? onRemove;
  final String? fileName;
  final String? filePath;
  final bool isInherited;
  final int inheritedCount;
  final List<String> inheritedFileNames;
  final bool isLoading;

  const PoolThumbnailCard({
    super.key,
    this.label,
    this.subLabel,
    this.isAddOnly = false,
    this.isSelected = false,
    this.isFirstSlot = false,
    this.onTap,
    this.onTapLabel,
    this.onRemove,
    this.fileName,
    this.filePath,
    this.isInherited = false,
    this.inheritedCount = 0,
    this.inheritedFileNames = const [],
    this.isLoading = false,
  });

  @override
  State<PoolThumbnailCard> createState() => _PoolThumbnailCardState();
}

class _PoolThumbnailCardState extends State<PoolThumbnailCard> {
  bool _isCardHovered = false;
  bool _isLabelHovered = false;

  @override
  Widget build(BuildContext context) {
    final borderColor = widget.isSelected
        ? AppColors.primaryCyan
        : (_isCardHovered ? AppColors.primaryCyan : AppColors.borderCyanMuted);

    final bgColor = widget.isSelected
        ? AppColors.cardHover
        : (_isCardHovered ? AppColors.cardHover : AppColors.cardBackground);

    String tooltipMsg;
    if (widget.isAddOnly) {
      tooltipMsg = 'Tambah slot baru';
    } else if (widget.isInherited) {
      if (widget.inheritedCount > 0) {
        tooltipMsg =
            'Menggabungkan ${widget.inheritedCount} file dari pool diatas — klik untuk menampilkan preview:\n${widget.inheritedFileNames.map((e) => "• $e").join("\n")}';
      } else {
        tooltipMsg = 'Slot terhubung: otomatis menggabungkan file dari pool diatas';
      }
    } else if (widget.isLoading && !widget.isInherited) {
      tooltipMsg =
          'Sedang memindai halaman ${widget.fileName ?? "PDF"}...';
    } else if (widget.fileName != null && widget.fileName!.isNotEmpty) {
      tooltipMsg =
          'File: ${widget.fileName}\nKlik untuk menampilkan preview halaman';
    } else {
      tooltipMsg = 'Klik untuk mengambil file dari folder (${widget.label ?? ""})';
    }

    Widget cardBody;
    if (widget.isAddOnly) {
      cardBody = const Center(
        child: Icon(
          Icons.add,
          color: Colors.white,
          size: 32,
        ),
      );
    } else if (widget.isInherited) {
      if (widget.inheritedCount > 0) {
        cardBody = Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Icon(
              Icons.layers_rounded,
              color: AppColors.primaryCyan,
              size: 22,
            ),
            const SizedBox(height: 1),
            Text(
              '${widget.inheritedCount} File',
              style: const TextStyle(
                color: Colors.white,
                fontSize: 10,
                fontWeight: FontWeight.bold,
              ),
            ),
            const Text(
              'dari Pool Atas',
              style: TextStyle(
                color: AppColors.primaryCyan,
                fontSize: 7.5,
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
        );
      } else {
        cardBody = Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: const [
            Icon(
              Icons.layers_outlined,
              color: Colors.white70,
              size: 22,
            ),
            SizedBox(height: 1),
            Text(
              '+ File',
              style: TextStyle(
                color: Colors.white,
                fontSize: 10,
                fontWeight: FontWeight.bold,
              ),
            ),
            Text(
              '(Pool Atas)',
              style: TextStyle(
                color: Colors.white38,
                fontSize: 7.5,
              ),
            ),
          ],
        );
      }
    } else if (widget.isLoading && !widget.isInherited) {
      cardBody = Center(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 4),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const SizedBox(
                width: 20,
                height: 20,
                child: CircularProgressIndicator(
                  strokeWidth: 2.2,
                  valueColor: AlwaysStoppedAnimation<Color>(
                    AppColors.primaryCyan,
                  ),
                  backgroundColor: Colors.white12,
                ),
              ),
              const SizedBox(height: 4),
              if (widget.fileName != null && widget.fileName!.isNotEmpty)
                Text(
                  widget.fileName!,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 8.5,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              const Text(
                'Memuat...',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color: AppColors.primaryCyan,
                  fontSize: 7.5,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ],
          ),
        ),
      );
    } else if (widget.fileName != null && widget.fileName!.isNotEmpty) {
      cardBody = Center(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 4),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const Icon(
                Icons.picture_as_pdf_rounded,
                color: AppColors.primaryCyan,
                size: 22,
              ),
              const SizedBox(height: 2),
              Text(
                widget.fileName!,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                textAlign: TextAlign.center,
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 9.5,
                  fontWeight: FontWeight.bold,
                ),
              ),
              Text(
                widget.subLabel != null && widget.subLabel!.isNotEmpty
                    ? widget.subLabel!
                    : 'PDF Siap',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                textAlign: TextAlign.center,
                style: TextStyle(
                  color: widget.subLabel != null && widget.subLabel!.isNotEmpty
                      ? AppColors.primaryCyan
                      : const Color(0xFF00E676),
                  fontSize: 7.5,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ],
          ),
        ),
      );
    } else {
      cardBody = Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          const Icon(
            Icons.add,
            color: Colors.white,
            size: 24,
          ),
          const SizedBox(height: 1),
          const Text(
            'File',
            style: TextStyle(
              color: Colors.white,
              fontSize: 10,
              fontWeight: FontWeight.bold,
            ),
          ),
          if (widget.subLabel != null && widget.subLabel!.isNotEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 2.0),
              child: Text(
                widget.subLabel!,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                textAlign: TextAlign.center,
                style: const TextStyle(
                  color: AppColors.primaryCyan,
                  fontSize: 7.5,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ),
        ],
      );
    }

    // Wrap card content with delete badge if deletable or clearable
    final bool hasFile =
        widget.fileName != null && widget.fileName!.isNotEmpty;
    final bool canDelete =
        widget.onRemove != null && !widget.isAddOnly && !widget.isInherited;
    final String removeTooltip = widget.isFirstSlot && hasFile
        ? 'Hapus file dari kotak ini'
        : 'Hapus kotak ini';
    final bool showDeleteBadge = canDelete && (_isCardHovered || hasFile);

    final Widget cardContent = Stack(
      clipBehavior: Clip.none,
      children: [
        Positioned.fill(child: cardBody),
        if (showDeleteBadge)
          Positioned(
            top: 2,
            right: 2,
            child: Tooltip(
              message: removeTooltip,
              waitDuration: const Duration(milliseconds: 200),
              child: MouseRegion(
                cursor: SystemMouseCursors.click,
                child: GestureDetector(
                  onTap: widget.onRemove,
                  child: Container(
                    padding: const EdgeInsets.all(2.5),
                    decoration: BoxDecoration(
                      color: Colors.black.withValues(alpha: 0.9),
                      shape: BoxShape.circle,
                      border: Border.all(
                        color: Colors.redAccent.withValues(alpha: 0.9),
                        width: 1,
                      ),
                      boxShadow: const [
                        BoxShadow(
                          color: Colors.black54,
                          blurRadius: 3,
                        ),
                      ],
                    ),
                    child: const Icon(
                      Icons.close,
                      size: 11,
                      color: Colors.redAccent,
                    ),
                  ),
                ),
              ),
            ),
          ),
      ],
    );

    return Container(
      width: 80,
      margin: const EdgeInsets.symmetric(horizontal: 4),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          // 1. Kotak Atas (Kotak Plus / File Thumbnail)
          Tooltip(
            message: tooltipMsg,
            waitDuration: const Duration(milliseconds: 300),
            child: MouseRegion(
              onEnter: (_) => setState(() => _isCardHovered = true),
              onExit: (_) => setState(() => _isCardHovered = false),
              cursor: SystemMouseCursors.click,
              child: GestureDetector(
                onTap: widget.onTap,
                onSecondaryTap: canDelete ? widget.onRemove : null,
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 150),
                  height: 66,
                  width: 80,
                  decoration: BoxDecoration(
                    color: bgColor,
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(
                      color: borderColor,
                      width: widget.isSelected ? 2 : 1.5,
                    ),
                    boxShadow: widget.isSelected
                        ? AppColors.cyanGlowShadow
                        : (_isCardHovered ? AppColors.cardShadow : null),
                  ),
                  child: cardContent,
                ),
              ),
            ),
          ),
          const SizedBox(height: 5),

          // 2. Kotak Bawah (Kotak di bawah kotak plus - Menuju Pages/Range)
          if (widget.label != null)
            Tooltip(
              message: 'Buka pengaturan halaman (${widget.label})',
              waitDuration: const Duration(milliseconds: 300),
              child: MouseRegion(
                onEnter: (_) => setState(() => _isLabelHovered = true),
                onExit: (_) => setState(() => _isLabelHovered = false),
                cursor: SystemMouseCursors.click,
                child: GestureDetector(
                  onTap: widget.onTapLabel ?? widget.onTap,
                  child: AnimatedContainer(
                    duration: const Duration(milliseconds: 150),
                    width: 80,
                    padding: const EdgeInsets.symmetric(
                      vertical: 2.5,
                      horizontal: 3,
                    ),
                    decoration: BoxDecoration(
                      color: _isLabelHovered
                          ? const Color(0xFF1CE5FF)
                          : (widget.isInherited
                              ? const Color(0xFF00BCD4)
                              : AppColors.primaryCyan),
                      borderRadius: BorderRadius.circular(4),
                      boxShadow: [
                        BoxShadow(
                          color: _isLabelHovered
                              ? AppColors.primaryCyan.withValues(alpha: 0.5)
                              : Colors.black26,
                          blurRadius: _isLabelHovered ? 4 : 2,
                          offset: const Offset(0, 1),
                        ),
                      ],
                    ),
                    alignment: Alignment.center,
                    child: Text(
                      widget.label!,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: Colors.black,
                        fontSize: 9,
                        fontWeight: _isLabelHovered
                            ? FontWeight.w900
                            : FontWeight.bold,
                      ),
                    ),
                  ),
                ),
              ),
            )
          else
            const SizedBox(height: 18),
        ],
      ),
    );
  }
}

class PoolThumbnailRow extends StatefulWidget {
  final int poolIndex;
  final List<String> labels;
  final List<String?>? subLabels;
  final VoidCallback? onAddTap;
  final int selectedIndex;
  final ValueChanged<int>? onSelectCard;
  final ValueChanged<int>? onSelectLabel;
  final List<String?>? fileNames;
  final List<bool>? isInheritedList;
  final List<int>? inheritedCounts;
  final List<List<String>>? inheritedFilesList;
  final List<bool>? isLoadingList;
  final ValueChanged<int>? onRemoveCard;
  final void Function(int oldIndex, int newIndex)? onReorder;
  final void Function(int sourcePool, int sourceSlot, int targetPool, int targetSlot)?
      onTransferSlot;

  const PoolThumbnailRow({
    super.key,
    this.poolIndex = 0,
    required this.labels,
    this.subLabels,
    this.onAddTap,
    this.selectedIndex = -1,
    this.onSelectCard,
    this.onSelectLabel,
    this.fileNames,
    this.isInheritedList,
    this.inheritedCounts,
    this.inheritedFilesList,
    this.isLoadingList,
    this.onRemoveCard,
    this.onReorder,
    this.onTransferSlot,
  });

  @override
  State<PoolThumbnailRow> createState() => _PoolThumbnailRowState();
}

class _PoolThumbnailRowState extends State<PoolThumbnailRow> {
  final ScrollController _scrollController = ScrollController();
  bool _canScrollLeft = false;
  bool _canScrollRight = false;
  bool _isScrollable = false;
  double _scrollProgress = 0.0;
  double _thumbRatio = 1.0;
  bool _isIndicatorHovered = false;
  bool _isIndicatorDragging = false;

  @override
  void initState() {
    super.initState();
    _scrollController.addListener(_onScroll);
    WidgetsBinding.instance.addPostFrameCallback((_) => _checkScrollMetrics());
  }

  @override
  void didUpdateWidget(covariant PoolThumbnailRow oldWidget) {
    super.didUpdateWidget(oldWidget);
    WidgetsBinding.instance.addPostFrameCallback((_) => _checkScrollMetrics());
  }

  @override
  void dispose() {
    _scrollController.removeListener(_onScroll);
    _scrollController.dispose();
    super.dispose();
  }

  void _onScroll() {
    _checkScrollMetrics();
  }

  void _checkScrollMetrics() {
    if (!mounted || !_scrollController.hasClients) return;
    final pos = _scrollController.position;
    final max = pos.maxScrollExtent;
    final current = pos.pixels;
    final isScrollable = max > 2.0;
    final canLeft = isScrollable && current > 4.0;
    final canRight = isScrollable && current < max - 4.0;

    double progress = 0.0;
    double ratio = 1.0;
    if (isScrollable) {
      progress = (current / max).clamp(0.0, 1.0);
      final viewport = pos.viewportDimension;
      final total = max + viewport;
      ratio = (viewport / total).clamp(0.15, 1.0);
    }

    if (canLeft != _canScrollLeft ||
        canRight != _canScrollRight ||
        isScrollable != _isScrollable ||
        (_scrollProgress - progress).abs() > 0.005 ||
        (_thumbRatio - ratio).abs() > 0.005) {
      setState(() {
        _canScrollLeft = canLeft;
        _canScrollRight = canRight;
        _isScrollable = isScrollable;
        _scrollProgress = progress;
        _thumbRatio = ratio;
      });
    }
  }

  void _scroll(double delta) {
    if (!_scrollController.hasClients) return;
    final target = (_scrollController.offset + delta).clamp(
      0.0,
      _scrollController.position.maxScrollExtent,
    );
    _scrollController.animateTo(
      target,
      duration: const Duration(milliseconds: 250),
      curve: Curves.easeOutCubic,
    );
  }

  void _onIndicatorDragUpdate(
    DragUpdateDetails details,
    double trackWidth,
    double thumbWidth,
  ) {
    if (!_scrollController.hasClients) return;
    final maxScroll = _scrollController.position.maxScrollExtent;
    if (maxScroll <= 0) return;

    final maxThumbOffset = trackWidth - thumbWidth;
    if (maxThumbOffset <= 0) return;

    final delta = details.primaryDelta != null
        ? details.primaryDelta!
        : details.delta.dx;
    final scrollDelta = delta * (maxScroll / maxThumbOffset);
    final targetScroll =
        (_scrollController.offset + scrollDelta).clamp(0.0, maxScroll);
    _scrollController.jumpTo(targetScroll);
  }

  void _onIndicatorTapDown(
    TapDownDetails details,
    double trackWidth,
    double thumbWidth,
  ) {
    if (!_scrollController.hasClients) return;
    final maxScroll = _scrollController.position.maxScrollExtent;
    if (maxScroll <= 0) return;

    final maxThumbOffset = trackWidth - thumbWidth;
    if (maxThumbOffset <= 0) return;

    final tapX = details.localPosition.dx;
    final targetThumbLeft = (tapX - thumbWidth / 2).clamp(0.0, maxThumbOffset);
    final targetRatio = (targetThumbLeft / maxThumbOffset).clamp(0.0, 1.0);
    final targetScroll = targetRatio * maxScroll;

    _scrollController.animateTo(
      targetScroll,
      duration: const Duration(milliseconds: 200),
      curve: Curves.easeOutCubic,
    );
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        SizedBox(
          height: 94,
          child: Stack(
            alignment: Alignment.center,
            children: [
              // 1. Scrollable cards row with mouse drag and touch support
              ScrollConfiguration(
                behavior: ScrollConfiguration.of(context).copyWith(
                  dragDevices: {
                    PointerDeviceKind.touch,
                    PointerDeviceKind.trackpad,
                    PointerDeviceKind.stylus,
                  },
                ),
                child: SingleChildScrollView(
                  controller: _scrollController,
                  scrollDirection: Axis.horizontal,
                  physics: const BouncingScrollPhysics(
                    parent: AlwaysScrollableScrollPhysics(),
                  ),
                  child: Center(
                    child: Padding(
                      padding: EdgeInsets.symmetric(
                        horizontal: _isScrollable ? 32.0 : 4.0,
                      ),
                      child: Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          ...() {
                            int firstNormalSlotIndex = -1;
                            for (int i = 0; i < widget.labels.length; i++) {
                              final isInherited =
                                  (widget.isInheritedList != null &&
                                          i < widget.isInheritedList!.length)
                                      ? widget.isInheritedList![i]
                                      : false;
                              if (!isInherited) {
                                firstNormalSlotIndex = i;
                                break;
                              }
                            }

                            return List.generate(widget.labels.length, (index) {
                              final fileName = (widget.fileNames != null &&
                                      index < widget.fileNames!.length)
                                  ? widget.fileNames![index]
                                  : null;
                              final isInherited = (widget.isInheritedList !=
                                          null &&
                                      index < widget.isInheritedList!.length)
                                  ? widget.isInheritedList![index]
                                  : false;
                              final inheritedCount =
                                  (widget.inheritedCounts != null &&
                                          index < widget.inheritedCounts!.length)
                                      ? widget.inheritedCounts![index]
                                      : 0;
                              final inheritedFiles =
                                  (widget.inheritedFilesList != null &&
                                          index <
                                              widget.inheritedFilesList!.length)
                                      ? widget.inheritedFilesList![index]
                                      : const <String>[];

                              final bool hasFile =
                                  fileName != null && fileName.isNotEmpty;
                              final bool isFirstNormalSlot =
                                  index == firstNormalSlotIndex;
                              // Kotak ke-1: jika ada file, bisa dihilangkan filenya (kotak tetap ada).
                              // Kotak ke-2 dan seterusnya: bisa dihapus kotaknya.
                              final bool isDeletable = !isInherited &&
                                  (index > firstNormalSlotIndex || hasFile);
                              final subLabel = (widget.subLabels != null &&
                                      index < widget.subLabels!.length)
                                  ? widget.subLabels![index]
                                  : null;
                              final isLoading = (widget.isLoadingList != null &&
                                      index < widget.isLoadingList!.length)
                                  ? widget.isLoadingList![index]
                                  : false;

                              final cardWidget = PoolThumbnailCard(
                                label: widget.labels[index],
                                subLabel: subLabel,
                                isSelected: widget.selectedIndex == index,
                                isFirstSlot: isFirstNormalSlot,
                                fileName: fileName,
                                isInherited: isInherited,
                                inheritedCount: inheritedCount,
                                inheritedFileNames: inheritedFiles,
                                isLoading: isLoading,
                                onTap: () => widget.onSelectCard?.call(index),
                                onTapLabel: () =>
                                    widget.onSelectLabel?.call(index),
                                onRemove: (widget.onRemoveCard != null &&
                                        isDeletable)
                                    ? () => widget.onRemoveCard!(index)
                                    : null,
                              );

                              if (widget.onReorder == null) {
                                return cardWidget;
                              }

                              return DragTarget<SlotDragData>(
                                hitTestBehavior: HitTestBehavior.opaque,
                                onWillAcceptWithDetails: (details) {
                                  if (details.data.poolIndex == widget.poolIndex) {
                                    return details.data.slotIndex != index;
                                  }
                                  return widget.onTransferSlot != null;
                                },
                                onAcceptWithDetails: (details) {
                                  if (details.data.poolIndex == widget.poolIndex) {
                                    widget.onReorder
                                        ?.call(details.data.slotIndex, index);
                                  } else {
                                    widget.onTransferSlot?.call(
                                      details.data.poolIndex,
                                      details.data.slotIndex,
                                      widget.poolIndex,
                                      index,
                                    );
                                  }
                                },
                                builder:
                                    (context, candidateData, rejectedData) {
                                  final isHoveredTarget =
                                      candidateData.isNotEmpty;

                                  return AnimatedContainer(
                                    duration:
                                        const Duration(milliseconds: 150),
                                    decoration: BoxDecoration(
                                      borderRadius:
                                          BorderRadius.circular(10),
                                      border: isHoveredTarget
                                          ? Border.all(
                                              color: AppColors.primaryCyan,
                                              width: 2.5,
                                            )
                                          : null,
                                      boxShadow: isHoveredTarget
                                          ? [
                                              BoxShadow(
                                                color: AppColors.primaryCyan
                                                    .withValues(alpha: 0.6),
                                                blurRadius: 12,
                                                spreadRadius: 2,
                                              ),
                                            ]
                                          : null,
                                    ),
                                    child: Draggable<SlotDragData>(
                                      data: SlotDragData(
                                        poolIndex: widget.poolIndex,
                                        slotIndex: index,
                                      ),
                                      dragAnchorStrategy:
                                          childDragAnchorStrategy,
                                      feedback: IgnorePointer(
                                        child: Material(
                                          color: Colors.transparent,
                                          child: Opacity(
                                            opacity: 0.92,
                                            child: Transform.scale(
                                              scale: 1.06,
                                              child: Container(
                                                decoration: BoxDecoration(
                                                  borderRadius:
                                                      BorderRadius.circular(10),
                                                  boxShadow: [
                                                    BoxShadow(
                                                      color: AppColors
                                                          .primaryCyan
                                                          .withValues(
                                                              alpha: 0.5),
                                                      blurRadius: 16,
                                                      spreadRadius: 2,
                                                    ),
                                                  ],
                                                ),
                                                child: PoolThumbnailCard(
                                                  label:
                                                      widget.labels[index],
                                                  subLabel: subLabel,
                                                  isSelected: true,
                                                  fileName: fileName,
                                                  isInherited: isInherited,
                                                  inheritedCount:
                                                      inheritedCount,
                                                  inheritedFileNames:
                                                      inheritedFiles,
                                                ),
                                              ),
                                            ),
                                          ),
                                        ),
                                      ),
                                      childWhenDragging: Opacity(
                                        opacity: 0.35,
                                        child: DashedContainer(
                                          height: 90,
                                          width: 80,
                                          borderRadius: 8,
                                          borderColor:
                                              AppColors.primaryCyan,
                                          borderWidth: 1.5,
                                          fillColor: Colors.transparent,
                                          child: Center(
                                            child: Icon(
                                              Icons.swap_horiz_rounded,
                                              color: AppColors.primaryCyan
                                                  .withValues(alpha: 0.6),
                                              size: 24,
                                            ),
                                          ),
                                        ),
                                      ),
                                      child: MouseRegion(
                                        cursor: SystemMouseCursors.grab,
                                        child: cardWidget,
                                      ),
                                    ),
                                  );
                                },
                              );
                            });
                          }(),
                          PoolThumbnailCard(
                            isAddOnly: true,
                            onTap: widget.onAddTap,
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),

              // 2. Left Chevron Scroll Button (appears when scrollable)
              if (_isScrollable)
                Positioned(
                  left: 2,
                  child: AnimatedOpacity(
                    duration: const Duration(milliseconds: 150),
                    opacity: _canScrollLeft ? 1.0 : 0.25,
                    child: _buildArrowButton(
                      icon: Icons.chevron_left_rounded,
                      tooltip: 'Geser ke kiri',
                      onTap: _canScrollLeft ? () => _scroll(-240) : null,
                    ),
                  ),
                ),

              // 3. Right Chevron Scroll Button (appears when scrollable)
              if (_isScrollable)
                Positioned(
                  right: 2,
                  child: AnimatedOpacity(
                    duration: const Duration(milliseconds: 150),
                    opacity: _canScrollRight ? 1.0 : 0.25,
                    child: _buildArrowButton(
                      icon: Icons.chevron_right_rounded,
                      tooltip: 'Geser ke kanan',
                      onTap: _canScrollRight ? () => _scroll(240) : null,
                    ),
                  ),
                ),
            ],
          ),
        ),
        const SizedBox(height: 4),

        // Dynamic Underline Indicator Bar (tracks scroll position when scrollable)
        _buildDynamicIndicator(),
      ],
    );
  }

  Widget _buildArrowButton({
    required IconData icon,
    required String tooltip,
    required VoidCallback? onTap,
  }) {
    return Tooltip(
      message: tooltip,
      child: MouseRegion(
        cursor: onTap != null
            ? SystemMouseCursors.click
            : SystemMouseCursors.basic,
        child: GestureDetector(
          onTap: onTap,
          child: Container(
            width: 26,
            height: 38,
            decoration: BoxDecoration(
              color: AppColors.cardBackground.withValues(alpha: 0.9),
              borderRadius: BorderRadius.circular(6),
              border: Border.all(
                color: onTap != null
                    ? AppColors.primaryCyan
                    : Colors.white24,
                width: 1.2,
              ),
              boxShadow: onTap != null ? AppColors.cyanGlowShadow : null,
            ),
            alignment: Alignment.center,
            child: Icon(
              icon,
              color: onTap != null ? AppColors.primaryCyan : Colors.white38,
              size: 20,
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildDynamicIndicator() {
    const trackWidth = 360.0;
    final isExpanded = _isIndicatorHovered || _isIndicatorDragging;
    final trackHeight = isExpanded ? 6.0 : 4.0;

    if (!_isScrollable) {
      return Container(
        margin: const EdgeInsets.symmetric(vertical: 4),
        width: trackWidth,
        height: 3.0,
        decoration: BoxDecoration(
          color: AppColors.primaryCyan,
          borderRadius: BorderRadius.circular(2),
          boxShadow: [
            BoxShadow(
              color: AppColors.primaryCyan.withValues(alpha: 0.5),
              blurRadius: 4,
            ),
          ],
        ),
      );
    }

    // When scrollable: interactive slider line that the user can drag & click
    final thumbWidth = (trackWidth * _thumbRatio).clamp(48.0, trackWidth);
    final maxThumbOffset = trackWidth - thumbWidth;
    final thumbOffset = _scrollProgress * maxThumbOffset;

    return MouseRegion(
      cursor: _isIndicatorDragging
          ? SystemMouseCursors.grabbing
          : SystemMouseCursors.grab,
      onEnter: (_) => setState(() => _isIndicatorHovered = true),
      onExit: (_) => setState(() => _isIndicatorHovered = false),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onHorizontalDragStart: (_) =>
            setState(() => _isIndicatorDragging = true),
        onHorizontalDragUpdate: (details) =>
            _onIndicatorDragUpdate(details, trackWidth, thumbWidth),
        onHorizontalDragEnd: (_) =>
            setState(() => _isIndicatorDragging = false),
        onHorizontalDragCancel: () =>
            setState(() => _isIndicatorDragging = false),
        onTapDown: (details) =>
            _onIndicatorTapDown(details, trackWidth, thumbWidth),
        child: Tooltip(
          message: 'Geser garis ini untuk menggulir file pool',
          waitDuration: const Duration(milliseconds: 300),
          child: Container(
            padding: const EdgeInsets.symmetric(vertical: 6),
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 150),
              width: trackWidth,
              height: trackHeight,
              decoration: BoxDecoration(
                color: Colors.white.withValues(alpha: 0.15),
                borderRadius: BorderRadius.circular(trackHeight / 2),
                border: Border.all(
                  color: isExpanded
                      ? AppColors.primaryCyan.withValues(alpha: 0.5)
                      : Colors.transparent,
                  width: 0.8,
                ),
              ),
              child: Stack(
                clipBehavior: Clip.none,
                children: [
                  Positioned(
                    left: thumbOffset,
                    top: 0,
                    bottom: 0,
                    width: thumbWidth,
                    child: AnimatedContainer(
                      duration: const Duration(milliseconds: 60),
                      decoration: BoxDecoration(
                        color: _isIndicatorDragging
                            ? const Color(0xFF1CE5FF)
                            : AppColors.primaryCyan,
                        borderRadius: BorderRadius.circular(trackHeight / 2),
                        boxShadow: [
                          BoxShadow(
                            color: _isIndicatorDragging
                                ? AppColors.primaryCyan
                                : AppColors.primaryCyan.withValues(alpha: 0.85),
                            blurRadius: isExpanded ? 8 : 4,
                            spreadRadius: isExpanded ? 1 : 0,
                          ),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class ZoomPill extends StatefulWidget {
  final VoidCallback? onTap;

  const ZoomPill({super.key, this.onTap});

  @override
  State<ZoomPill> createState() => _ZoomPillState();
}

class _ZoomPillState extends State<ZoomPill> {
  bool _isHovered = false;

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      onEnter: (_) => setState(() => _isHovered = true),
      onExit: (_) => setState(() => _isHovered = false),
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        onTap: widget.onTap ??
            () {
              showDialog(
                context: context,
                builder: (ctx) => AlertDialog(
                  backgroundColor: AppColors.cardBackground,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12),
                    side: const BorderSide(color: AppColors.primaryCyan),
                  ),
                  title: const Text(
                    'Pratinjau Halaman PDF',
                    style: TextStyle(
                      color: AppColors.textWhite,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  content: Container(
                    width: 320,
                    height: 440,
                    decoration: BoxDecoration(
                      color: Colors.white,
                      borderRadius: BorderRadius.circular(6),
                    ),
                    child: const Center(
                      child: Text(
                        'Pratinjau Halaman Skala Penuh',
                        style: TextStyle(
                          color: Colors.black87,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ),
                  ),
                  actions: [
                    TextButton(
                      onPressed: () => Navigator.pop(ctx),
                      child: const Text(
                        'Tutup',
                        style: TextStyle(color: AppColors.primaryCyan),
                      ),
                    ),
                  ],
                ),
              );
            },
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 150),
          padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
          decoration: BoxDecoration(
            color: _isHovered ? AppColors.primaryCyan : Colors.black,
            borderRadius: BorderRadius.circular(12),
            boxShadow: const [
              BoxShadow(
                color: Colors.black38,
                blurRadius: 3,
                offset: Offset(0, 1),
              ),
            ],
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                'Zoom',
                style: TextStyle(
                  color: _isHovered ? Colors.black : Colors.white,
                  fontSize: 10,
                  fontWeight: FontWeight.bold,
                ),
              ),
              const SizedBox(width: 3),
              Icon(
                Icons.search,
                color: _isHovered ? Colors.black : Colors.white,
                size: 12,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class PoolHeaderDropdown extends StatefulWidget {
  final String title;
  final ValueChanged<String>? onSelected;

  const PoolHeaderDropdown({
    super.key,
    required this.title,
    this.onSelected,
  });

  @override
  State<PoolHeaderDropdown> createState() => _PoolHeaderDropdownState();
}

class _PoolHeaderDropdownState extends State<PoolHeaderDropdown> {
  bool _isHovered = false;

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      onEnter: (_) => setState(() => _isHovered = true),
      onExit: (_) => setState(() => _isHovered = false),
      cursor: SystemMouseCursors.click,
      child: PopupMenuButton<String>(
        tooltip: 'Pilih Pool',
        color: AppColors.surface,
        position: PopupMenuPosition.under,
        elevation: 6,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(8),
          side: const BorderSide(color: AppColors.borderCyan, width: 1.5),
        ),
        onSelected: widget.onSelected,
        itemBuilder: (context) => const [
          PopupMenuItem(
            value: 'Split Pool',
            child: Text(
              'Split Pool',
              style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold),
            ),
          ),
          PopupMenuItem(
            value: 'Split Separate Pool',
            child: Text(
              'Split Separate Pool',
              style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold),
            ),
          ),
          PopupMenuItem(
            value: 'Reorder Pool',
            child: Text(
              'Reorder Pool',
              style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold),
            ),
          ),
          PopupMenuItem(
            value: 'Merge Pool',
            child: Text(
              'Merge Pool',
              style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold),
            ),
          ),
        ],
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 150),
          height: 38,
          width: double.infinity,
          decoration: BoxDecoration(
            color: _isHovered ? const Color(0xFF1CE5FF) : AppColors.primaryCyan,
            borderRadius: BorderRadius.circular(6),
            boxShadow: _isHovered
                ? [
                    BoxShadow(
                      color: AppColors.primaryCyan.withValues(alpha: 0.4),
                      blurRadius: 8,
                    ),
                  ]
                : null,
          ),
          alignment: Alignment.center,
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Text(
                widget.title,
                style: const TextStyle(
                  color: Colors.black,
                  fontWeight: FontWeight.bold,
                  fontSize: 15,
                  letterSpacing: 0.6,
                ),
              ),
              const SizedBox(width: 6),
              const Icon(
                Icons.arrow_drop_down,
                color: Colors.black,
                size: 24,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class PoolBottomControls extends StatefulWidget {
  final String prefix;
  final String hintText;
  final String? addButtonLabel;
  final List<TextEditingController> controllers;
  final VoidCallback onAddItem;
  final ValueChanged<int> onRemoveItem;
  final String actionLabel;
  final VoidCallback onAction;
  final VoidCallback onGoToPool;
  final bool isFilePicker;
  final ValueChanged<int>? onPickFileForRow;
  final void Function(int index, String value)? onTextChanged;
  final void Function(int oldIndex, int newIndex)? onReorderItem;

  const PoolBottomControls({
    super.key,
    required this.prefix,
    this.hintText = 'Pages to Split',
    this.addButtonLabel,
    required this.controllers,
    required this.onAddItem,
    required this.onRemoveItem,
    required this.actionLabel,
    required this.onAction,
    required this.onGoToPool,
    this.isFilePicker = false,
    this.onPickFileForRow,
    this.onTextChanged,
    this.onReorderItem,
  });

  @override
  State<PoolBottomControls> createState() => _PoolBottomControlsState();
}

class _PoolBottomControlsState extends State<PoolBottomControls> {
  final ScrollController _rowsScrollController = ScrollController();

  @override
  void didUpdateWidget(covariant PoolBottomControls oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.controllers.length > oldWidget.controllers.length) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted || !_rowsScrollController.hasClients) return;
        final maxExtent = _rowsScrollController.position.maxScrollExtent;
        if (maxExtent > 0) {
          _rowsScrollController.animateTo(
            maxExtent,
            duration: const Duration(milliseconds: 180),
            curve: Curves.easeOutCubic,
          );
        }
      });
    }
  }

  @override
  void dispose() {
    _rowsScrollController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final rawAddText = widget.addButtonLabel ?? '+ Add ${widget.prefix}';
    final screenHeight = MediaQuery.sizeOf(context).height;
    final double maxRowsHeight = screenHeight < 680
        ? 78.0
        : (screenHeight < 760 ? 117.0 : 156.0);
    final bool isRowsScrollable =
        widget.controllers.length * 39.0 > maxRowsHeight;

    return Row(
      crossAxisAlignment: CrossAxisAlignment.end,
      children: [
        // Left Column: List of input rows (scrollable when exceeding maxRowsHeight) & "+ Add [Prefix]" button
        Expanded(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              ConstrainedBox(
                constraints: BoxConstraints(maxHeight: maxRowsHeight),
                child: Scrollbar(
                  controller: _rowsScrollController,
                  thumbVisibility: isRowsScrollable,
                  child: SingleChildScrollView(
                    controller: _rowsScrollController,
                    padding: EdgeInsets.only(right: isRowsScrollable ? 10.0 : 0.0),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: List.generate(widget.controllers.length, (index) {
                        final rowContent = Row(
                          children: [
                            if (widget.onReorderItem != null) ...[
                              Draggable<RowDragData>(
                                data: RowDragData(rowIndex: index),
                                dragAnchorStrategy: childDragAnchorStrategy,
                                feedback: IgnorePointer(
                                  child: Material(
                                    color: Colors.transparent,
                                    child: Container(
                                      padding: const EdgeInsets.symmetric(
                                        horizontal: 14,
                                        vertical: 6,
                                      ),
                                      decoration: BoxDecoration(
                                        color: AppColors.cardBackground,
                                        borderRadius: BorderRadius.circular(8),
                                        border: Border.all(
                                          color: AppColors.primaryCyan,
                                          width: 1.5,
                                        ),
                                        boxShadow: AppColors.cyanGlowShadow,
                                      ),
                                      child: Text(
                                        '${widget.prefix} ${index + 1}',
                                        style: const TextStyle(
                                          color: AppColors.primaryCyan,
                                          fontWeight: FontWeight.bold,
                                          fontSize: 12,
                                        ),
                                      ),
                                    ),
                                  ),
                                ),
                                childWhenDragging: Opacity(
                                  opacity: 0.3,
                                  child: MouseRegion(
                                    cursor: SystemMouseCursors.grab,
                                    child: Container(
                                      height: 32,
                                      padding: const EdgeInsets.symmetric(horizontal: 4),
                                      alignment: Alignment.center,
                                      child: const Icon(
                                        Icons.drag_indicator,
                                        color: Colors.white54,
                                        size: 18,
                                      ),
                                    ),
                                  ),
                                ),
                                child: Tooltip(
                                  message: 'Tahan dan geser untuk mengubah urutan',
                                  child: MouseRegion(
                                    cursor: SystemMouseCursors.grab,
                                    child: Container(
                                      height: 32,
                                      padding: const EdgeInsets.symmetric(horizontal: 4),
                                      alignment: Alignment.center,
                                      child: const Icon(
                                        Icons.drag_indicator,
                                        color: Colors.white54,
                                        size: 18,
                                      ),
                                    ),
                                  ),
                                ),
                              ),
                              const SizedBox(width: 4),
                            ],

                            // Badge: e.g. "Split Number 1", "Order Number 1", "Merge File 1"
                            MouseRegion(
                              cursor: widget.isFilePicker
                                  ? SystemMouseCursors.click
                                  : SystemMouseCursors.basic,
                              child: GestureDetector(
                                onTap: widget.isFilePicker
                                    ? () => widget.onPickFileForRow?.call(index)
                                    : null,
                                child: Tooltip(
                                  message: widget.isFilePicker
                                      ? 'Klik untuk memilih file PDF dari folder (${widget.prefix} ${index + 1})'
                                      : '',
                                  child: Container(
                                    height: 32,
                                    padding: const EdgeInsets.symmetric(horizontal: 14),
                                    decoration: BoxDecoration(
                                      color: AppColors.primaryCyan,
                                      borderRadius: BorderRadius.circular(6),
                                      boxShadow: [
                                        BoxShadow(
                                          color: AppColors.primaryCyan.withValues(alpha: 0.2),
                                          blurRadius: 3,
                                          offset: const Offset(0, 1),
                                        ),
                                      ],
                                    ),
                                    alignment: Alignment.center,
                                    child: Text(
                                      '${widget.prefix} ${index + 1}',
                                      style: const TextStyle(
                                        color: Colors.black,
                                        fontWeight: FontWeight.bold,
                                        fontSize: 12,
                                      ),
                                    ),
                                  ),
                                ),
                              ),
                            ),
                            const SizedBox(width: 8),

                            // Box: TextField if isFilePicker is false, clickable File Picker if isFilePicker is true
                            Expanded(
                              child: widget.isFilePicker
                                  ? MouseRegion(
                                      cursor: SystemMouseCursors.click,
                                      child: GestureDetector(
                                        onTap: () =>
                                            widget.onPickFileForRow?.call(index),
                                        child: Tooltip(
                                          message:
                                              'Klik untuk memilih file PDF dari folder',
                                          child: Container(
                                            height: 32,
                                            padding: const EdgeInsets.symmetric(
                                              horizontal: 12,
                                            ),
                                            decoration: BoxDecoration(
                                              color: Colors.white,
                                              borderRadius: BorderRadius.circular(6),
                                              boxShadow: const [
                                                BoxShadow(
                                                  color: Colors.black26,
                                                  blurRadius: 3,
                                                  offset: Offset(0, 1),
                                                ),
                                              ],
                                            ),
                                            alignment: Alignment.centerLeft,
                                            child: Row(
                                              children: [
                                                if (widget.controllers[index]
                                                    .text.isNotEmpty) ...[
                                                  const Icon(
                                                    Icons.picture_as_pdf_rounded,
                                                    color: Color(0xFFE53935),
                                                    size: 16,
                                                  ),
                                                  const SizedBox(width: 8),
                                                  Expanded(
                                                    child: Text(
                                                      widget.controllers[index].text,
                                                      style: const TextStyle(
                                                        color: Colors.black87,
                                                        fontSize: 12,
                                                        fontWeight: FontWeight.bold,
                                                      ),
                                                      overflow: TextOverflow.ellipsis,
                                                    ),
                                                  ),
                                                ] else ...[
                                                  Expanded(
                                                    child: Text(
                                                      widget.hintText,
                                                      style: const TextStyle(
                                                        color: Colors.black38,
                                                        fontSize: 12,
                                                        fontWeight: FontWeight.normal,
                                                      ),
                                                    ),
                                                  ),
                                                  const Icon(
                                                    Icons.folder_open_rounded,
                                                    color: Colors.black45,
                                                    size: 16,
                                                  ),
                                                ],
                                              ],
                                            ),
                                          ),
                                        ),
                                      ),
                                    )
                                  : Container(
                                      height: 32,
                                      padding: const EdgeInsets.symmetric(
                                        horizontal: 12,
                                      ),
                                      decoration: BoxDecoration(
                                        color: Colors.white,
                                        borderRadius: BorderRadius.circular(6),
                                        boxShadow: const [
                                          BoxShadow(
                                            color: Colors.black26,
                                            blurRadius: 3,
                                            offset: Offset(0, 1),
                                          ),
                                        ],
                                      ),
                                      alignment: Alignment.centerLeft,
                                      child: TextField(
                                        controller: widget.controllers[index],
                                        onChanged: (val) =>
                                            widget.onTextChanged?.call(index, val),
                                        style: const TextStyle(
                                          color: Colors.black,
                                          fontSize: 12,
                                          fontWeight: FontWeight.w600,
                                        ),
                                        decoration: InputDecoration(
                                          hintText: widget.hintText,
                                          hintStyle: const TextStyle(
                                            color: Colors.black38,
                                            fontSize: 12,
                                            fontWeight: FontWeight.normal,
                                          ),
                                          border: InputBorder.none,
                                          isDense: true,
                                          contentPadding: EdgeInsets.zero,
                                        ),
                                      ),
                                    ),
                            ),
                            const SizedBox(width: 8),

                            // Cyan Close Button (X)
                            MouseRegion(
                              cursor: SystemMouseCursors.click,
                              child: GestureDetector(
                                onTap: () => widget.onRemoveItem(index),
                                child: Tooltip(
                                  message: 'Hapus baris ini',
                                  child: Container(
                                    width: 32,
                                    height: 32,
                                    decoration: BoxDecoration(
                                      color: AppColors.primaryCyan,
                                      borderRadius: BorderRadius.circular(6),
                                      boxShadow: [
                                        BoxShadow(
                                          color: AppColors.primaryCyan
                                              .withValues(alpha: 0.25),
                                          blurRadius: 3,
                                          offset: const Offset(0, 1),
                                        ),
                                      ],
                                    ),
                                    alignment: Alignment.center,
                                    child: const Icon(
                                      Icons.close_rounded,
                                      color: Colors.black,
                                      size: 18,
                                    ),
                                  ),
                                ),
                              ),
                            ),
                          ],
                        );

                        if (widget.onReorderItem == null) {
                          return Padding(
                            padding: const EdgeInsets.only(bottom: 7.0),
                            child: rowContent,
                          );
                        }

                        return DragTarget<RowDragData>(
                          hitTestBehavior: HitTestBehavior.opaque,
                          onWillAcceptWithDetails: (details) =>
                              details.data.rowIndex != index,
                          onAcceptWithDetails: (details) => widget.onReorderItem
                              ?.call(details.data.rowIndex, index),
                          builder: (context, candidateData, rejectedData) {
                            final isHovered = candidateData.isNotEmpty;
                            return AnimatedContainer(
                              duration: const Duration(milliseconds: 150),
                              margin: const EdgeInsets.only(bottom: 7.0),
                              decoration: BoxDecoration(
                                borderRadius: BorderRadius.circular(6),
                                border: isHovered
                                    ? Border.all(
                                        color: AppColors.primaryCyan,
                                        width: 1.5,
                                      )
                                    : null,
                                color: isHovered
                                    ? AppColors.primaryCyan
                                        .withValues(alpha: 0.1)
                                    : Colors.transparent,
                              ),
                              child: rowContent,
                            );
                          },
                        );
                      }),
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 3),

              // Add Button (Centered under rows)
              MouseRegion(
                cursor: SystemMouseCursors.click,
                child: GestureDetector(
                  onTap: widget.onAddItem,
                  child: Tooltip(
                    message: rawAddText,
                    child: Container(
                      height: 32,
                      width: double.infinity,
                      decoration: BoxDecoration(
                        color: AppColors.primaryCyan,
                        borderRadius: BorderRadius.circular(16),
                        boxShadow: [
                          BoxShadow(
                            color: AppColors.primaryCyan.withValues(alpha: 0.35),
                            blurRadius: 4,
                            offset: const Offset(0, 1),
                          ),
                        ],
                      ),
                      alignment: Alignment.center,
                      child: Text(
                        rawAddText,
                        style: const TextStyle(
                          color: Colors.black,
                          fontWeight: FontWeight.bold,
                          fontSize: 12.5,
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),

        const SizedBox(width: 24),

        // Right Column: Stacked Action Buttons
        Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            // Action Button: "Split PDF >" / "Reorder PDF >" / "Merge PDF >"
            MouseRegion(
              cursor: SystemMouseCursors.click,
              child: GestureDetector(
                onTap: widget.onAction,
                child: Container(
                  width: 160,
                  height: 38,
                  padding: const EdgeInsets.symmetric(horizontal: 12),
                  decoration: BoxDecoration(
                    color: AppColors.primaryCyan,
                    borderRadius: BorderRadius.circular(20),
                    boxShadow: [
                      BoxShadow(
                        color: AppColors.primaryCyan.withValues(alpha: 0.4),
                        blurRadius: 6,
                        offset: const Offset(0, 2),
                      ),
                    ],
                  ),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Flexible(
                        child: Text(
                          widget.actionLabel,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            color: Colors.black,
                            fontWeight: FontWeight.bold,
                            fontSize: 13,
                          ),
                        ),
                      ),
                      const SizedBox(width: 6),
                      Container(
                        width: 20,
                        height: 20,
                        decoration: const BoxDecoration(
                          color: Colors.black,
                          shape: BoxShape.circle,
                        ),
                        alignment: Alignment.center,
                        child: const Icon(
                          Icons.chevron_right_rounded,
                          color: Colors.white,
                          size: 15,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
            const SizedBox(height: 10),

            // "Go to Pool" Button (< Go to Pool)
            MouseRegion(
              cursor: SystemMouseCursors.click,
              child: GestureDetector(
                onTap: widget.onGoToPool,
                child: Container(
                  width: 160,
                  height: 38,
                  padding: const EdgeInsets.symmetric(horizontal: 12),
                  decoration: BoxDecoration(
                    color: AppColors.primaryCyan,
                    borderRadius: BorderRadius.circular(20),
                    boxShadow: [
                      BoxShadow(
                        color: AppColors.primaryCyan.withValues(alpha: 0.4),
                        blurRadius: 6,
                        offset: const Offset(0, 2),
                      ),
                    ],
                  ),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: const [
                      Icon(
                        Icons.chevron_left_rounded,
                        color: Colors.black,
                        size: 22,
                      ),
                      SizedBox(width: 4),
                      Flexible(
                        child: Text(
                          'Go to Pool',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            color: Colors.black,
                            fontWeight: FontWeight.bold,
                            fontSize: 13,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ],
        ),
      ],
    );
  }
}
