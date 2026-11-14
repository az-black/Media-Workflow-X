import 'dart:async';
import 'dart:io' show File;
import 'dart:math' as math;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../../core/constants/app_colors.dart';
import '../../../../core/services/pdf_inspector_service.dart';
import '../../../../core/services/pdf_render_service.dart';
import '../../../../shared/widgets/dashed_container.dart';
import 'pdf_card_components.dart';

class PreviewHeaderButton extends StatelessWidget {
  final String label;
  final IconData? icon;
  final VoidCallback? onPressed;
  final bool isPrimary;
  final String? tooltip;
  final bool canRequestFocus;

  const PreviewHeaderButton({
    super.key,
    required this.label,
    this.icon,
    this.onPressed,
    this.isPrimary = false,
    this.tooltip,
    this.canRequestFocus = true,
  });

  @override
  Widget build(BuildContext context) {
    final enabled = onPressed != null;
    final button = Material(
      color: Colors.transparent,
      child: InkWell(
        canRequestFocus: canRequestFocus,
        onTap: onPressed,
        borderRadius: BorderRadius.circular(6),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 5),
          decoration: BoxDecoration(
            color: !enabled
                ? Colors.white.withValues(alpha: 0.05)
                : (isPrimary
                    ? AppColors.primaryCyan
                    : AppColors.primaryCyan.withValues(alpha: 0.14)),
            borderRadius: BorderRadius.circular(6),
            border: Border.all(
              color: !enabled
                  ? Colors.white12
                  : AppColors.primaryCyan.withValues(alpha: isPrimary ? 1.0 : 0.55),
            ),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (icon != null) ...[
                Icon(
                  icon,
                  size: 13,
                  color: !enabled
                      ? Colors.white38
                      : (isPrimary ? Colors.black : AppColors.primaryCyan),
                ),
                const SizedBox(width: 4),
              ],
              Text(
                label,
                style: TextStyle(
                  color: !enabled
                      ? Colors.white38
                      : (isPrimary ? Colors.black : AppColors.primaryCyan),
                  fontSize: 10.5,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ],
          ),
        ),
      ),
    );

    if (tooltip != null && tooltip!.isNotEmpty) {
      return Tooltip(message: tooltip!, child: button);
    }
    return button;
  }
}

class PreviewRotateGroup extends StatelessWidget {
  final VoidCallback? onRotateLeft;
  final VoidCallback? onRotateRight;
  final VoidCallback? onResetRotation;
  final int rotatedCount;
  final Key? rotateLeftKey;
  final Key? rotateRightKey;
  final Key? resetRotationKey;
  final String leftTooltip;
  final String rightTooltip;
  final String resetTooltip;

  const PreviewRotateGroup({
    super.key,
    this.onRotateLeft,
    this.onRotateRight,
    this.onResetRotation,
    this.rotatedCount = 0,
    this.rotateLeftKey,
    this.rotateRightKey,
    this.resetRotationKey,
    this.leftTooltip = 'Putar semua halaman 90° ke kiri (-90°)',
    this.rightTooltip = 'Putar semua halaman 90° ke kanan (+90°)',
    this.resetTooltip = 'Reset rotasi halaman ke 0°',
  });

  @override
  Widget build(BuildContext context) {
    return Wrap(
      spacing: 4,
      runSpacing: 4,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        _buildRotateButton(
          key: rotateLeftKey,
          icon: Icons.rotate_left_rounded,
          label: '-90°',
          tooltip: leftTooltip,
          onPressed: onRotateLeft,
        ),
        _buildRotateButton(
          key: rotateRightKey,
          icon: Icons.rotate_right_rounded,
          label: '+90°',
          tooltip: rightTooltip,
          onPressed: onRotateRight,
        ),
        if (rotatedCount > 0 && onResetRotation != null)
          Tooltip(
            message: resetTooltip,
            child: Material(
              color: Colors.transparent,
              child: InkWell(
                key: resetRotationKey,
                onTap: onResetRotation,
                borderRadius: BorderRadius.circular(6),
                child: Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 8,
                    vertical: 5,
                  ),
                  decoration: BoxDecoration(
                    color: Colors.amberAccent.withValues(alpha: 0.14),
                    borderRadius: BorderRadius.circular(6),
                    border: Border.all(
                      color: Colors.amberAccent.withValues(alpha: 0.65),
                    ),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Icon(
                        Icons.restart_alt_rounded,
                        size: 13,
                        color: Colors.amberAccent,
                      ),
                      const SizedBox(width: 4),
                      Text(
                        'Reset 0° ($rotatedCount)',
                        style: const TextStyle(
                          color: Colors.amberAccent,
                          fontSize: 10.5,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
      ],
    );
  }

  Widget _buildRotateButton({
    Key? key,
    required IconData icon,
    required String label,
    required String tooltip,
    required VoidCallback? onPressed,
  }) {
    final enabled = onPressed != null;
    return Tooltip(
      message: tooltip,
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          key: key,
          onTap: onPressed,
          borderRadius: BorderRadius.circular(6),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 5),
            decoration: BoxDecoration(
              color: !enabled
                  ? Colors.white.withValues(alpha: 0.05)
                  : AppColors.primaryCyan.withValues(alpha: 0.14),
              borderRadius: BorderRadius.circular(6),
              border: Border.all(
                color: !enabled
                    ? Colors.white12
                    : AppColors.primaryCyan.withValues(alpha: 0.55),
              ),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  icon,
                  size: 13,
                  color: !enabled ? Colors.white38 : AppColors.primaryCyan,
                ),
                const SizedBox(width: 3),
                Text(
                  label,
                  style: TextStyle(
                    color: !enabled ? Colors.white38 : AppColors.primaryCyan,
                    fontSize: 10.5,
                    fontWeight: FontWeight.bold,
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

class PdfSlotInfoHeader extends StatelessWidget {
  final String fileName;
  final int pageCount;
  final String? paperSizeLabel;
  final String? fileSizeLabel;
  final bool isInherited;
  final String? sourcePoolTitle;
  final bool isLoading;
  final VoidCallback? onChangeFile;
  final List<Widget> trailingWidgets;

  const PdfSlotInfoHeader({
    super.key,
    required this.fileName,
    required this.pageCount,
    this.paperSizeLabel,
    this.fileSizeLabel,
    this.isInherited = false,
    this.sourcePoolTitle,
    this.isLoading = false,
    this.onChangeFile,
    this.trailingWidgets = const [],
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: AppColors.cardBackground,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: AppColors.primaryCyan.withValues(alpha: 0.35)),
      ),
      child: SizedBox(
        width: double.infinity,
        child: Wrap(
          alignment: WrapAlignment.spaceBetween,
          crossAxisAlignment: WrapCrossAlignment.center,
          spacing: 8,
          runSpacing: 6,
          children: [
            Wrap(
              spacing: 8,
              runSpacing: 4,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                Icon(
                  isInherited
                      ? Icons.layers_rounded
                      : Icons.picture_as_pdf_rounded,
                  color: AppColors.primaryCyan,
                  size: 17,
                ),
                ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 240),
                  child: Text(
                    fileName,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 12,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ),
                _buildMetaBadge(
                  label: isLoading ? 'Memuat...' : '$pageCount Halaman',
                  accent:
                      isLoading ? AppColors.primaryCyan : const Color(0xFF00E676),
                  showSpinner: isLoading,
                ),
                if (paperSizeLabel != null || fileSizeLabel != null)
                  _buildMetaBadge(
                    label: [
                      ?paperSizeLabel,
                      if (fileSizeLabel != null && fileSizeLabel!.isNotEmpty)
                        fileSizeLabel!,
                    ].join(' • '),
                    accent: AppColors.primaryCyan,
                  ),
                if (isInherited &&
                    sourcePoolTitle != null &&
                    sourcePoolTitle!.isNotEmpty)
                  _buildMetaBadge(
                    label: 'Sumber: $sourcePoolTitle',
                    accent: Colors.amberAccent,
                  ),
              ],
            ),
            if (trailingWidgets.isNotEmpty ||
                (!isInherited && onChangeFile != null))
              Wrap(
                spacing: 6,
                runSpacing: 4,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  ...trailingWidgets,
                  if (!isInherited && onChangeFile != null)
                    PreviewHeaderButton(
                      label: 'Ganti File',
                      icon: Icons.swap_horiz_rounded,
                      tooltip: 'Pilih file PDF lain untuk slot ini',
                      onPressed: onChangeFile,
                    ),
                ],
              ),
          ],
        ),
      ),
    );
  }

  Widget _buildMetaBadge({
    required String label,
    required Color accent,
    bool showSpinner = false,
  }) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: accent.withValues(alpha: 0.14),
        borderRadius: BorderRadius.circular(4),
        border: Border.all(color: accent.withValues(alpha: 0.45)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (showSpinner) ...[
            SizedBox(
              width: 10,
              height: 10,
              child: CircularProgressIndicator(
                strokeWidth: 1.8,
                valueColor: AlwaysStoppedAnimation<Color>(accent),
              ),
            ),
            const SizedBox(width: 5),
          ],
          Text(
            label,
            style: TextStyle(
              color: accent,
              fontSize: 10,
              fontWeight: FontWeight.bold,
            ),
          ),
        ],
      ),
    );
  }
}

class PdfPageSheetCard extends StatelessWidget {
  final PdfPageMeta page;
  final String fileName;
  final String? filePath;
  final int totalPages;
  final String? badgeText;
  final Color badgeColor;
  final String? roleSubtitle;
  final bool isSelected;
  final bool isChecked;
  final bool showCheckmark;
  final VoidCallback? onToggleCheck;
  final bool showReorderHandle;
  final int? displayOrderNumber;
  final bool showDeleteButton;
  final VoidCallback? onDelete;
  final VoidCallback? onRotateRight;
  final VoidCallback? onRotateLeft;
  final VoidCallback? onZoom;
  final VoidCallback? onTap;
  final bool compact;
  final PdfRenderQuality renderQuality;

  const PdfPageSheetCard({
    super.key,
    required this.page,
    required this.fileName,
    this.filePath,
    required this.totalPages,
    this.badgeText,
    this.badgeColor = const Color(0xFF0A2230),
    this.roleSubtitle,
    this.isSelected = false,
    this.isChecked = false,
    this.showCheckmark = false,
    this.onToggleCheck,
    this.showReorderHandle = false,
    this.displayOrderNumber,
    this.showDeleteButton = false,
    this.onDelete,
    this.onRotateRight,
    this.onRotateLeft,
    this.onZoom,
    this.onTap,
    this.compact = false,
    this.renderQuality = PdfRenderQuality.card,
  });

  @override
  Widget build(BuildContext context) {
    final highlightColor = (isSelected || (showCheckmark && isChecked))
        ? AppColors.primaryCyan
        : Colors.black12;
    final userDeg = page.normalizedUserRotation;
    final footerMetaText = userDeg == 0
        ? '${page.paperSizeLabel} • Hal ${page.pageNumber} / $totalPages'
        : '${page.paperSizeLabel} • $userDeg° • Hal ${page.pageNumber} / $totalPages';

    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: EdgeInsets.all(compact ? 6 : 8),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(7),
          border: Border.all(
            color: highlightColor,
            width: (isSelected || (showCheckmark && isChecked)) ? 2.0 : 1.0,
          ),
          boxShadow: const [
            BoxShadow(
              color: Colors.black38,
              blurRadius: 4,
              offset: Offset(0, 2),
            ),
          ],
        ),
        child: Column(
          children: [
            // Top bar: Checkmark/Badge + Reorder icon + Rotate + ZoomPill + Delete
            Row(
              children: [
                if (showCheckmark) ...[
                  GestureDetector(
                    onTap: onToggleCheck,
                    child: Container(
                      width: 20,
                      height: 20,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: isChecked
                            ? const Color(0xFF00E676)
                            : Colors.grey.shade300,
                      ),
                      child: Icon(
                        Icons.check,
                        color: isChecked ? Colors.white : Colors.grey.shade600,
                        size: 13,
                      ),
                    ),
                  ),
                  const SizedBox(width: 5),
                ],
                if (showReorderHandle) ...[
                  Icon(
                    Icons.drag_indicator_rounded,
                    size: compact ? 14 : 16,
                    color: Colors.black45,
                  ),
                  const SizedBox(width: 2),
                ],
                Expanded(
                  child: badgeText != null && badgeText!.isNotEmpty
                      ? Align(
                          alignment: Alignment.centerLeft,
                          child: Container(
                            padding: EdgeInsets.symmetric(
                              horizontal: compact ? 5 : 7,
                              vertical: 2,
                            ),
                            decoration: BoxDecoration(
                              color: badgeColor,
                              borderRadius: BorderRadius.circular(4),
                            ),
                            child: Text(
                              badgeText!,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                color: badgeColor == AppColors.primaryCyan
                                    ? Colors.black
                                    : AppColors.primaryCyan,
                                fontSize: compact ? 9 : 10,
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                          ),
                        )
                      : const SizedBox.shrink(),
                ),
                if (compact && (onRotateRight != null || onRotateLeft != null)) ...[
                  const SizedBox(width: 4),
                  _PageRotatePill(
                    icon: Icons.rotate_right_rounded,
                    tooltip:
                        'Putar Hal ${page.pageNumber} (+90°, Klik Kanan -90°)',
                    isRotated: userDeg != 0,
                    onTap: onRotateRight ?? onRotateLeft!,
                    onSecondaryTap: onRotateLeft,
                  ),
                ] else if (!compact &&
                    (onRotateLeft != null || onRotateRight != null)) ...[
                  if (onRotateLeft != null) ...[
                    const SizedBox(width: 4),
                    _PageRotatePill(
                      icon: Icons.rotate_left_rounded,
                      tooltip: 'Putar Kiri Hal ${page.pageNumber} (-90°)',
                      isRotated: userDeg != 0,
                      onTap: onRotateLeft!,
                    ),
                  ],
                  if (onRotateRight != null) ...[
                    const SizedBox(width: 4),
                    _PageRotatePill(
                      icon: Icons.rotate_right_rounded,
                      tooltip: 'Putar Kanan Hal ${page.pageNumber} (+90°)',
                      isRotated: userDeg != 0,
                      onTap: onRotateRight!,
                    ),
                  ],
                ],
                const SizedBox(width: 4),
                ZoomPill(onTap: onZoom),
                if (showDeleteButton && onDelete != null) ...[
                  const SizedBox(width: 4),
                  _PageDeletePill(
                    pageNumber: page.pageNumber,
                    onTap: onDelete!,
                  ),
                ],
              ],
            ),
            SizedBox(height: compact ? 4 : 6),

            // Center real PDF page thumbnail inside neutral studio mat
            Expanded(
              child: Container(
                width: double.infinity,
                padding: EdgeInsets.all(compact ? 4 : 8),
                decoration: BoxDecoration(
                  color: const Color(0xFFEEF3F7),
                  borderRadius: BorderRadius.circular(5),
                  border: Border.all(color: const Color(0xFFDCE4EC)),
                ),
                child: PdfRealPagePreview(
                  filePath: filePath,
                  page: page,
                  quality: compact ? PdfRenderQuality.thumb : renderQuality,
                  compact: compact,
                  displayOrderNumber: displayOrderNumber,
                ),
              ),
            ),

            // Footer metadata
            Container(
              padding: const EdgeInsets.only(top: 4),
              decoration: const BoxDecoration(
                border: Border(
                  top: BorderSide(color: Color(0xFFE0E6EB), width: 1),
                ),
              ),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      roleSubtitle ?? fileName,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: Colors.black54,
                        fontSize: compact ? 8.5 : 9.5,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                  const SizedBox(width: 6),
                  Text(
                    footerMetaText,
                    style: TextStyle(
                      color: userDeg != 0
                          ? const Color(0xFF007B8F)
                          : Colors.black87,
                      fontSize: compact ? 8.5 : 9.5,
                      fontWeight: FontWeight.bold,
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

/// Displays the actual rendered content of a PDF page using [PdfRenderService],
/// falling back cleanly to a structured paper sheet when running headlessly or
/// when a mock file has no readable path on disk.
class PdfRealPagePreview extends StatefulWidget {
  final String? filePath;
  final PdfPageMeta page;
  final PdfRenderQuality quality;
  final double? targetMaxEdgePx;
  final bool compact;
  final int? displayOrderNumber;
  final bool isZoomView;
  final int? totalPages;
  final String? fallbackTitle;

  const PdfRealPagePreview({
    super.key,
    required this.filePath,
    required this.page,
    this.quality = PdfRenderQuality.card,
    this.targetMaxEdgePx,
    this.compact = false,
    this.displayOrderNumber,
    this.isZoomView = false,
    this.totalPages,
    this.fallbackTitle,
  });

  @override
  State<PdfRealPagePreview> createState() => _PdfRealPagePreviewState();
}

class _PdfRealPagePreviewState extends State<PdfRealPagePreview> {
  final PdfRenderService _renderService = PdfRenderService();

  PdfRenderedPageHandle? _handle;
  bool _isRendering = false;
  int _requestSeq = 0;

  String? get _resolvedPath {
    final raw = (widget.page.sourceFilePath ?? widget.filePath)?.trim();
    return (raw != null && raw.isNotEmpty) ? raw : null;
  }

  int get _resolvedPageNumber =>
      widget.page.sourcePageNumber ?? widget.page.pageNumber;

  @override
  void initState() {
    super.initState();
    _syncOrLoadRender();
  }

  @override
  void didUpdateWidget(covariant PdfRealPagePreview oldWidget) {
    super.didUpdateWidget(oldWidget);
    final oldPath = (oldWidget.page.sourceFilePath ?? oldWidget.filePath)?.trim();
    final oldPageNum =
        oldWidget.page.sourcePageNumber ?? oldWidget.page.pageNumber;
    final newPath = _resolvedPath;
    final newPageNum = _resolvedPageNumber;
    final zoomChanged = widget.quality == PdfRenderQuality.zoom &&
        oldWidget.targetMaxEdgePx != widget.targetMaxEdgePx &&
        ((oldWidget.targetMaxEdgePx ?? 0) - (widget.targetMaxEdgePx ?? 0))
                .abs() >=
            120;

    if (oldPath != newPath ||
        oldPageNum != newPageNum ||
        oldWidget.quality != widget.quality ||
        zoomChanged) {
      _syncOrLoadRender();
    }
  }

  @override
  void dispose() {
    _requestSeq++;
    _swapHandle(null);
    super.dispose();
  }

  void _swapHandle(PdfRenderedPageHandle? next) {
    if (identical(_handle, next)) return;
    final prev = _handle;
    next?.retain();
    _handle = next;
    prev?.release();
  }

  Future<void> _syncOrLoadRender() async {
    final seq = ++_requestSeq;
    final path = _resolvedPath;
    final pageNum = _resolvedPageNumber;

    if (path == null || pageNum < 1) {
      _swapHandle(null);
      _isRendering = false;
      return;
    }

    // 1. Check exact tier cache synchronously
    final exactHit = _renderService.getCachedRender(
      path,
      pageNum,
      quality: widget.quality,
      targetMaxEdgePx: widget.targetMaxEdgePx,
    );
    if (exactHit != null) {
      _swapHandle(exactHit);
      _isRendering = false;
      return;
    }

    // 2. If another tier (e.g. thumb/card) is cached, show it immediately while upgrading
    final fallbackHit = _renderService.getBestAvailableCachedRender(
      path,
      pageNum,
    );
    if (fallbackHit != null) {
      _swapHandle(fallbackHit);
    } else {
      _swapHandle(null);
    }

    final canRenderNative =
        _renderService.isNativeRenderSupported && File(path).existsSync();
    if (!canRenderNative) {
      _isRendering = false;
      return;
    }

    _isRendering = true;

    final rendered = await _renderService.renderPage(
      filePath: path,
      pageNumber: pageNum,
      quality: widget.quality,
      targetMaxEdgePx: widget.targetMaxEdgePx,
    );

    if (!mounted || seq != _requestSeq) return;
    setState(() {
      if (rendered != null) {
        _swapHandle(rendered);
      }
      _isRendering = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    final hasValidImage = _handle != null && !_handle!.isDisposed;

    return Center(
      child: AspectRatio(
        aspectRatio: widget.page.aspectRatio,
        child: Container(
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(widget.isZoomView ? 4 : 3),
            border: Border.all(color: const Color(0xFFC9D4DF), width: 0.9),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(
                  alpha: widget.isZoomView
                      ? 0.55
                      : (widget.compact ? 0.16 : 0.22),
                ),
                blurRadius: widget.isZoomView ? 14 : (widget.compact ? 4 : 8),
                offset: Offset(
                  0,
                  widget.isZoomView ? 5 : (widget.compact ? 1.5 : 3),
                ),
              ),
            ],
          ),
          clipBehavior: Clip.antiAlias,
          child: Stack(
            fit: StackFit.expand,
            children: [
              if (hasValidImage)
                RotatedBox(
                  quarterTurns: widget.page.userQuarterTurns,
                  child: RawImage(
                    image: _handle!.image,
                    fit: BoxFit.contain,
                    filterQuality: FilterQuality.medium,
                  ),
                )
              else if (_isRendering)
                _buildLoadingState()
              else
                RotatedBox(
                  quarterTurns: widget.page.userQuarterTurns,
                  child: _buildStructuredFallbackSheet(),
                ),
              if (hasValidImage && _isRendering && widget.isZoomView)
                Positioned(
                  right: 8,
                  bottom: 8,
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 8,
                      vertical: 4,
                    ),
                    decoration: BoxDecoration(
                      color: AppColors.cardBackground.withValues(alpha: 0.88),
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(
                        color: AppColors.primaryCyan.withValues(alpha: 0.6),
                      ),
                    ),
                    child: const Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        SizedBox(
                          width: 10,
                          height: 10,
                          child: CircularProgressIndicator(
                            strokeWidth: 1.8,
                            valueColor: AlwaysStoppedAnimation<Color>(
                              AppColors.primaryCyan,
                            ),
                          ),
                        ),
                        SizedBox(width: 5),
                        Text(
                          'Mempertajam HD...',
                          style: TextStyle(
                            color: AppColors.primaryCyan,
                            fontSize: 9.5,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildLoadingState() {
    return Container(
      color: Colors.white,
      child: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            SizedBox(
              width: widget.compact ? 16 : 24,
              height: widget.compact ? 16 : 24,
              child: const CircularProgressIndicator(
                strokeWidth: 2.2,
                valueColor: AlwaysStoppedAnimation<Color>(
                  AppColors.primaryCyan,
                ),
              ),
            ),
            SizedBox(height: widget.compact ? 4 : 6),
            Text(
              'Hal ${widget.page.pageNumber}',
              style: TextStyle(
                color: Colors.black54,
                fontSize: widget.compact ? 9.5 : 11,
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildStructuredFallbackSheet() {
    final path = _resolvedPath;
    final showRestartNotice = _renderService.hasInitError &&
        path != null &&
        File(path).existsSync();

    return Center(
      child: FittedBox(
        fit: BoxFit.scaleDown,
        child: Padding(
          padding: EdgeInsets.all(widget.compact ? 6 : 14),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    showRestartNotice
                        ? Icons.restart_alt_rounded
                        : Icons.description_outlined,
                    size: widget.compact ? 18 : (widget.isZoomView ? 32 : 26),
                    color: showRestartNotice
                        ? Colors.orangeAccent
                        : const Color(0xFF1565C0),
                  ),
                  if (widget.displayOrderNumber != null) ...[
                    const SizedBox(width: 4),
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 5,
                        vertical: 1.5,
                      ),
                      decoration: BoxDecoration(
                        color: AppColors.primaryCyan.withValues(alpha: 0.2),
                        borderRadius: BorderRadius.circular(4),
                      ),
                      child: Text(
                        '#${widget.displayOrderNumber}',
                        style: const TextStyle(
                          color: Colors.black87,
                          fontSize: 10,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ),
                  ],
                ],
              ),
              SizedBox(height: widget.compact ? 3 : 6),
              Text(
                widget.isZoomView && widget.totalPages != null
                    ? 'Halaman ${widget.page.pageNumber} dari ${widget.totalPages}'
                    : 'Hal ${widget.page.pageNumber}',
                style: TextStyle(
                  color: Colors.black87,
                  fontSize: widget.compact ? 11 : (widget.isZoomView ? 15 : 13),
                  fontWeight: FontWeight.bold,
                ),
              ),
              if (showRestartNotice && !widget.compact) ...[
                const SizedBox(height: 8),
                Container(
                  constraints: BoxConstraints(
                    maxWidth: widget.isZoomView ? 300 : 185,
                  ),
                  padding: const EdgeInsets.symmetric(
                    horizontal: 10,
                    vertical: 6,
                  ),
                  decoration: BoxDecoration(
                    color: const Color(0xFFFFF3E0),
                    borderRadius: BorderRadius.circular(6),
                    border: Border.all(color: Colors.orange.shade400),
                  ),
                  child: Text(
                    'Plugin PDFium native belum termuat di sesi ini. Tutup aplikasi lalu jalankan ulang (Stop + Start Debugging / flutter run), bukan Hot Reload.',
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      color: Colors.orange.shade900,
                      fontSize: widget.isZoomView ? 10.5 : 8.5,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              ] else ...[
                if (widget.fallbackTitle != null && widget.isZoomView) ...[
                  const SizedBox(height: 2),
                  Text(
                    widget.fallbackTitle!,
                    style: const TextStyle(
                      color: Colors.black54,
                      fontSize: 10,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ],
                if (!widget.compact) ...[
                  const SizedBox(height: 8),
                  _buildWireframeLine(
                    width: widget.isZoomView ? 150 : 100,
                    opacity: 0.18,
                  ),
                  const SizedBox(height: 4),
                  _buildWireframeLine(
                    width: widget.isZoomView ? 180 : 84,
                    opacity: 0.12,
                  ),
                  const SizedBox(height: 4),
                  _buildWireframeLine(
                    width: widget.isZoomView ? 130 : 92,
                    opacity: 0.10,
                  ),
                ],
              ],
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildWireframeLine({required double width, required double opacity}) {
    return Container(
      width: width,
      height: 4,
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: opacity),
        borderRadius: BorderRadius.circular(2),
      ),
    );
  }
}

class _PageDeletePill extends StatefulWidget {
  final int pageNumber;
  final VoidCallback onTap;

  const _PageDeletePill({
    required this.pageNumber,
    required this.onTap,
  });

  @override
  State<_PageDeletePill> createState() => _PageDeletePillState();
}

class _PageDeletePillState extends State<_PageDeletePill> {
  bool _isHovered = false;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: 'Hapus Hal ${widget.pageNumber}',
      waitDuration: const Duration(milliseconds: 250),
      child: MouseRegion(
        onEnter: (_) => setState(() => _isHovered = true),
        onExit: (_) => setState(() => _isHovered = false),
        cursor: SystemMouseCursors.click,
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: widget.onTap,
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 140),
            width: 21,
            height: 21,
            decoration: BoxDecoration(
              color: _isHovered ? Colors.redAccent : const Color(0xFF14181E),
              shape: BoxShape.circle,
              border: Border.all(
                color: _isHovered
                    ? Colors.redAccent
                    : Colors.redAccent.withValues(alpha: 0.75),
                width: 1.2,
              ),
              boxShadow: [
                BoxShadow(
                  color: _isHovered
                      ? Colors.redAccent.withValues(alpha: 0.45)
                      : Colors.black38,
                  blurRadius: _isHovered ? 5 : 2,
                  offset: const Offset(0, 1),
                ),
              ],
            ),
            alignment: Alignment.center,
            child: Icon(
              Icons.close_rounded,
              size: 13,
              color: _isHovered ? Colors.white : Colors.redAccent,
            ),
          ),
        ),
      ),
    );
  }
}

class _PageRotatePill extends StatefulWidget {
  final IconData icon;
  final String tooltip;
  final bool isRotated;
  final VoidCallback onTap;
  final VoidCallback? onSecondaryTap;

  const _PageRotatePill({
    required this.icon,
    required this.tooltip,
    this.isRotated = false,
    required this.onTap,
    this.onSecondaryTap,
  });

  @override
  State<_PageRotatePill> createState() => _PageRotatePillState();
}

class _PageRotatePillState extends State<_PageRotatePill> {
  bool _isHovered = false;

  @override
  Widget build(BuildContext context) {
    final highlighted = _isHovered || widget.isRotated;
    return Tooltip(
      message: widget.tooltip,
      waitDuration: const Duration(milliseconds: 250),
      child: MouseRegion(
        onEnter: (_) => setState(() => _isHovered = true),
        onExit: (_) => setState(() => _isHovered = false),
        cursor: SystemMouseCursors.click,
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: widget.onTap,
          onSecondaryTap: widget.onSecondaryTap,
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 140),
            width: 21,
            height: 21,
            decoration: BoxDecoration(
              color: _isHovered
                  ? AppColors.primaryCyan
                  : (widget.isRotated
                      ? const Color(0xFF0A2A38)
                      : const Color(0xFF14181E)),
              shape: BoxShape.circle,
              border: Border.all(
                color: highlighted
                    ? AppColors.primaryCyan
                    : AppColors.primaryCyan.withValues(alpha: 0.72),
                width: widget.isRotated ? 1.5 : 1.2,
              ),
              boxShadow: [
                BoxShadow(
                  color: _isHovered
                      ? AppColors.primaryCyan.withValues(alpha: 0.45)
                      : Colors.black38,
                  blurRadius: _isHovered ? 5 : 2,
                  offset: const Offset(0, 1),
                ),
              ],
            ),
            alignment: Alignment.center,
            child: Icon(
              widget.icon,
              size: 13,
              color: _isHovered ? Colors.black : AppColors.primaryCyan,
            ),
          ),
        ),
      ),
    );
  }
}

class PdfEmptySlotPreview extends StatelessWidget {
  final String title;
  final String subtitle;
  final bool isInherited;
  final VoidCallback? onPickFile;

  const PdfEmptySlotPreview({
    super.key,
    required this.title,
    required this.subtitle,
    this.isInherited = false,
    this.onPickFile,
  });

  @override
  Widget build(BuildContext context) {
    return DashedContainer(
      borderRadius: 10,
      borderWidth: 1.5,
      borderColor: AppColors.borderCyan.withValues(alpha: 0.6),
      fillColor: AppColors.cardBackground.withValues(alpha: 0.7),
      hoverFillColor: AppColors.cardHover,
      onTap: isInherited ? null : onPickFile,
      child: Center(
        child: FittedBox(
          fit: BoxFit.scaleDown,
          child: Padding(
            padding: const EdgeInsets.all(20.0),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  isInherited
                      ? Icons.layers_outlined
                      : Icons.picture_as_pdf_outlined,
                  color: AppColors.primaryCyan,
                  size: 40,
                ),
                const SizedBox(height: 10),
                Text(
                  title,
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 14,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                const SizedBox(height: 4),
                ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 380),
                  child: Text(
                    subtitle,
                    textAlign: TextAlign.center,
                    style: const TextStyle(
                      color: AppColors.textMuted,
                      fontSize: 11.5,
                    ),
                  ),
                ),
                if (!isInherited && onPickFile != null) ...[
                  const SizedBox(height: 14),
                  PreviewHeaderButton(
                    label: 'Pilih File PDF',
                    icon: Icons.upload_file_rounded,
                    isPrimary: true,
                    onPressed: onPickFile,
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class PdfLoadingPreview extends StatelessWidget {
  final String fileName;
  final String title;
  final String subtitle;

  const PdfLoadingPreview({
    super.key,
    required this.fileName,
    this.title = 'Memuat Halaman PDF...',
    this.subtitle =
        'Membaca struktur & jumlah halaman dokumen agar aplikasi tetap responsif.',
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: AppColors.cardBackground.withValues(alpha: 0.78),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(
          color: AppColors.primaryCyan.withValues(alpha: 0.45),
          width: 1.5,
        ),
        boxShadow: [
          BoxShadow(
            color: AppColors.primaryCyan.withValues(alpha: 0.12),
            blurRadius: 16,
            spreadRadius: 1,
          ),
        ],
      ),
      child: Center(
        child: FittedBox(
          fit: BoxFit.scaleDown,
          child: Padding(
            padding: const EdgeInsets.all(24.0),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Stack(
                  alignment: Alignment.center,
                  children: [
                    Container(
                      width: 64,
                      height: 64,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: AppColors.primaryCyan.withValues(alpha: 0.08),
                      ),
                    ),
                    const SizedBox(
                      width: 60,
                      height: 60,
                      child: CircularProgressIndicator(
                        strokeWidth: 3.5,
                        valueColor: AlwaysStoppedAnimation<Color>(
                          AppColors.primaryCyan,
                        ),
                        backgroundColor: Colors.white12,
                      ),
                    ),
                    const Icon(
                      Icons.picture_as_pdf_rounded,
                      color: AppColors.primaryCyan,
                      size: 24,
                    ),
                  ],
                ),
                const SizedBox(height: 14),
                Text(
                  title,
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 14,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                const SizedBox(height: 6),
                Container(
                  constraints: const BoxConstraints(maxWidth: 360),
                  padding: const EdgeInsets.symmetric(
                    horizontal: 10,
                    vertical: 3,
                  ),
                  decoration: BoxDecoration(
                    color: AppColors.primaryCyan.withValues(alpha: 0.14),
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(
                      color: AppColors.primaryCyan.withValues(alpha: 0.4),
                    ),
                  ),
                  child: Text(
                    fileName,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      color: AppColors.primaryCyan,
                      fontSize: 11,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ),
                const SizedBox(height: 6),
                ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 380),
                  child: Text(
                    subtitle,
                    textAlign: TextAlign.center,
                    style: const TextStyle(
                      color: AppColors.textMuted,
                      fontSize: 11,
                    ),
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

class PdfZoomSplitActions {
  final Set<int> Function() getSelectedPages;
  final ValueChanged<int> onTogglePage;
  final VoidCallback? onSelectAll;
  final VoidCallback? onClearSelection;
  final Listenable? listenable;

  const PdfZoomSplitActions({
    required this.getSelectedPages,
    required this.onTogglePage,
    this.onSelectAll,
    this.onClearSelection,
    this.listenable,
  });
}

class PdfZoomReorderActions {
  final List<PdfPageMeta> Function() getPages;
  final int Function() getOriginalPageCount;
  final bool Function() canUndo;
  final void Function(int currentIndex) onDeleteAt;
  final void Function(int oldIndex, int newIndex) onMovePage;
  final VoidCallback onReverseOrder;
  final VoidCallback onUndo;
  final VoidCallback onResetOrder;
  final Listenable? listenable;

  const PdfZoomReorderActions({
    required this.getPages,
    required this.getOriginalPageCount,
    required this.canUndo,
    required this.onDeleteAt,
    required this.onMovePage,
    required this.onReverseOrder,
    required this.onUndo,
    required this.onResetOrder,
    this.listenable,
  });
}

class PdfZoomRotateActions {
  final int Function(int index, PdfPageMeta page) getPageRotation;
  final void Function(int index, PdfPageMeta page, int deltaDegrees) onRotatePage;
  final void Function(int index, PdfPageMeta page)? onResetPageRotation;
  final Listenable? listenable;

  const PdfZoomRotateActions({
    required this.getPageRotation,
    required this.onRotatePage,
    this.onResetPageRotation,
    this.listenable,
  });
}

class PdfPageZoomDialog extends StatefulWidget {
  final String fileName;
  final String? filePath;
  final List<PdfPageMeta> pages;
  final int initialIndex;
  final String? fileSizeLabel;
  final String? contextTitle;
  final bool showSequencePosition;
  final bool enableRotate;
  final bool isImageMode;
  final String? imageFilePath;
  final ImageProvider? imageProviderOverride;
  final String Function(int index, PdfPageMeta page)? pageSubtitleBuilder;
  final PdfZoomSplitActions? splitActions;
  final PdfZoomReorderActions? reorderActions;
  final PdfZoomRotateActions? rotateActions;
  final VoidCallback? onClose;

  static VoidCallback? _activeDismiss;

  const PdfPageZoomDialog({
    super.key,
    required this.fileName,
    this.filePath,
    required this.pages,
    this.initialIndex = 0,
    this.fileSizeLabel,
    this.contextTitle,
    this.showSequencePosition = false,
    this.enableRotate = true,
    this.isImageMode = false,
    this.imageFilePath,
    this.imageProviderOverride,
    this.pageSubtitleBuilder,
    this.splitActions,
    this.reorderActions,
    this.rotateActions,
    this.onClose,
  });

  /// Dismisses any currently active (expanded or minimized) zoom preview overlay.
  static void dismissActive() {
    final active = _activeDismiss;
    _activeDismiss = null;
    active?.call();
  }

  static Future<void> showImage(
    BuildContext context, {
    required String fileName,
    String? filePath,
    String? fileSizeLabel,
    String? contextTitle,
    ImageProvider? imageProviderOverride,
  }) {
    return show(
      context,
      fileName: fileName,
      filePath: filePath,
      pages: const [PdfPageMeta(pageNumber: 1)],
      initialIndex: 0,
      fileSizeLabel: fileSizeLabel,
      contextTitle: contextTitle,
      enableRotate: false,
      isImageMode: true,
      imageFilePath: filePath,
      imageProviderOverride: imageProviderOverride,
    );
  }

  static Future<void> show(
    BuildContext context, {
    required String fileName,
    String? filePath,
    required List<PdfPageMeta> pages,
    int initialIndex = 0,
    String? fileSizeLabel,
    String? contextTitle,
    bool showSequencePosition = false,
    bool enableRotate = true,
    bool isImageMode = false,
    String? imageFilePath,
    ImageProvider? imageProviderOverride,
    String Function(int index, PdfPageMeta page)? pageSubtitleBuilder,
    PdfZoomSplitActions? splitActions,
    PdfZoomReorderActions? reorderActions,
    PdfZoomRotateActions? rotateActions,
  }) {
    dismissActive();

    final overlay = Overlay.maybeOf(context, rootOverlay: true);
    if (overlay != null) {
      final completer = Completer<void>();
      late OverlayEntry entry;

      void closeOverlay() {
        if (identical(_activeDismiss, closeOverlay)) {
          _activeDismiss = null;
        }
        if (entry.mounted) {
          entry.remove();
        }
        if (!completer.isCompleted) {
          completer.complete();
        }
      }

      _activeDismiss = closeOverlay;
      entry = OverlayEntry(
        builder: (ctx) => PdfPageZoomDialog(
          fileName: fileName,
          filePath: filePath,
          pages: pages,
          initialIndex: initialIndex,
          fileSizeLabel: fileSizeLabel,
          contextTitle: contextTitle,
          showSequencePosition: showSequencePosition,
          enableRotate: enableRotate,
          isImageMode: isImageMode,
          imageFilePath: imageFilePath,
          imageProviderOverride: imageProviderOverride,
          pageSubtitleBuilder: pageSubtitleBuilder,
          splitActions: splitActions,
          reorderActions: reorderActions,
          rotateActions: rotateActions,
          onClose: closeOverlay,
        ),
      );
      overlay.insert(entry);
      return completer.future;
    }

    return showDialog<void>(
      context: context,
      builder: (ctx) => PdfPageZoomDialog(
        fileName: fileName,
        filePath: filePath,
        pages: pages,
        initialIndex: initialIndex,
        fileSizeLabel: fileSizeLabel,
        contextTitle: contextTitle,
        showSequencePosition: showSequencePosition,
        enableRotate: enableRotate,
        isImageMode: isImageMode,
        imageFilePath: imageFilePath,
        imageProviderOverride: imageProviderOverride,
        pageSubtitleBuilder: pageSubtitleBuilder,
        splitActions: splitActions,
        reorderActions: reorderActions,
        rotateActions: rotateActions,
      ),
    );
  }

  @override
  State<PdfPageZoomDialog> createState() => _PdfPageZoomDialogState();
}

class _PdfPageZoomDialogState extends State<PdfPageZoomDialog> {
  static const double _minZoomScale = 0.6;
  static const double _maxZoomScale = 3.0;
  static const double _canvasPadding = 10.0;

  late int _currentIndex;
  double _zoomScale = 1.0;
  bool _isMaximized = false;
  bool _isMinimized = false;
  bool _isDraggingPdf = false;
  bool _showReorderTargetPicker = false;
  bool _showSplitPagePicker = false;
  bool _showStandalonePagePicker = false;
  Offset _freePanOffset = Offset.zero;

  final GlobalKey _canvasViewportKey = GlobalKey();
  final FocusNode _shortcutFocusNode =
      FocusNode(debugLabel: 'pdf_zoom_shortcut_focus');
  final ScrollController _vScrollController = ScrollController();
  final ScrollController _hScrollController = ScrollController();
  final Map<int, int> _localPageRotations = {};
  final Set<Listenable> _attachedListenables = {};

  ImageStream? _imageStream;
  ImageStreamListener? _imageListener;
  ImageInfo? _loadedImageInfo;
  bool _isImageLoading = false;
  String? _imageLoadError;

  List<PdfPageMeta> get _effectivePages {
    final basePages = widget.reorderActions?.getPages() ?? widget.pages;
    final rotate = widget.rotateActions;
    if (rotate == null && _localPageRotations.isEmpty) {
      return basePages;
    }
    return List<PdfPageMeta>.generate(basePages.length, (i) {
      final p = basePages[i];
      final deg = rotate != null
          ? ((rotate.getPageRotation(i, p) % 360) + 360) % 360
          : (((_localPageRotations[p.pageNumber] ?? p.userRotation) % 360) +
                  360) %
              360;
      if (deg == p.normalizedUserRotation) return p;
      return p.copyWith(userRotation: deg);
    });
  }

  @override
  void initState() {
    super.initState();
    final pages = _effectivePages;
    final maxIdx = pages.isEmpty ? 0 : pages.length - 1;
    _currentIndex = widget.initialIndex.clamp(0, maxIdx);
    _syncListeners();
    _resolveImageIfNeeded();
    WidgetsBinding.instance.addPostFrameCallback((_) => _restoreShortcutFocus());
  }

  void _restoreShortcutFocus() {
    if (!mounted || _isMinimized) return;
    if (_shortcutFocusNode.canRequestFocus && !_shortcutFocusNode.hasFocus) {
      _shortcutFocusNode.requestFocus();
    }
  }

  @override
  void didUpdateWidget(covariant PdfPageZoomDialog oldWidget) {
    super.didUpdateWidget(oldWidget);
    _syncListeners();
    if (oldWidget.isImageMode != widget.isImageMode ||
        oldWidget.imageFilePath != widget.imageFilePath ||
        oldWidget.imageProviderOverride != widget.imageProviderOverride) {
      _resolveImageIfNeeded();
    }
  }

  void _disposeImageStream() {
    if (_imageStream != null && _imageListener != null) {
      _imageStream!.removeListener(_imageListener!);
    }
    _imageStream = null;
    _imageListener = null;
  }

  void _resolveImageIfNeeded() {
    _disposeImageStream();
    if (!widget.isImageMode) {
      _loadedImageInfo?.dispose();
      _loadedImageInfo = null;
      _isImageLoading = false;
      _imageLoadError = null;
      return;
    }

    ImageProvider? provider = widget.imageProviderOverride;
    final path = (widget.imageFilePath ?? widget.filePath)?.trim();
    if (provider == null && path != null && path.isNotEmpty) {
      final file = File(path);
      if (file.existsSync()) {
        provider = FileImage(file);
      }
    }

    if (provider == null) {
      _loadedImageInfo?.dispose();
      _loadedImageInfo = null;
      _isImageLoading = false;
      _imageLoadError = 'File gambar tidak ditemukan di disk.';
      return;
    }

    _isImageLoading = true;
    _imageLoadError = null;
    final stream = provider.resolve(ImageConfiguration.empty);
    _imageStream = stream;
    _imageListener = ImageStreamListener(
      (ImageInfo info, bool synchronousCall) {
        final cloned = info.clone();
        if (!mounted) {
          cloned.dispose();
          return;
        }
        final old = _loadedImageInfo;
        if (synchronousCall) {
          _loadedImageInfo = cloned;
          _isImageLoading = false;
          _imageLoadError = null;
          old?.dispose();
        } else {
          setState(() {
            _loadedImageInfo = cloned;
            _isImageLoading = false;
            _imageLoadError = null;
          });
          old?.dispose();
        }
      },
      onError: (Object error, StackTrace? stackTrace) {
        if (!mounted) return;
        setState(() {
          _isImageLoading = false;
          _imageLoadError = 'Gagal memuat pratinjau gambar.';
        });
      },
    );
    stream.addListener(_imageListener!);
  }

  double _currentAspectRatio(List<PdfPageMeta> pages, int safeIdx) {
    if (widget.isImageMode) {
      final img = _loadedImageInfo?.image;
      if (img != null && img.width > 0 && img.height > 0) {
        return img.width / img.height;
      }
      return 4.0 / 3.0;
    }
    return pages[safeIdx].aspectRatio;
  }

  void _syncListeners() {
    final desired = <Listenable>{
      ?widget.splitActions?.listenable,
      ?widget.reorderActions?.listenable,
      ?widget.rotateActions?.listenable,
    };
    for (final listener in _attachedListenables.toList()) {
      if (!desired.contains(listener)) {
        listener.removeListener(_onExternalSyncChanged);
        _attachedListenables.remove(listener);
      }
    }
    for (final listener in desired) {
      if (_attachedListenables.add(listener)) {
        listener.addListener(_onExternalSyncChanged);
      }
    }
  }

  void _onExternalSyncChanged() {
    if (!mounted) return;
    final pages = _effectivePages;
    setState(() {
      if (pages.isNotEmpty) {
        _currentIndex = _currentIndex.clamp(0, pages.length - 1);
      } else {
        _currentIndex = 0;
      }
    });
  }

  @override
  void dispose() {
    for (final listener in _attachedListenables) {
      listener.removeListener(_onExternalSyncChanged);
    }
    _attachedListenables.clear();
    _disposeImageStream();
    _loadedImageInfo?.dispose();
    _loadedImageInfo = null;
    _shortcutFocusNode.dispose();
    _vScrollController.dispose();
    _hScrollController.dispose();
    super.dispose();
  }

  void _stepRotate(int deltaDeg) {
    final pages = _effectivePages;
    if (pages.isEmpty) return;
    final safeIdx = _currentIndex.clamp(0, pages.length - 1);
    final currentPage = pages[safeIdx];
    final rotate = widget.rotateActions;

    setState(() {
      _freePanOffset = Offset.zero;
      _isDraggingPdf = false;
      if (rotate == null) {
        final next =
            ((currentPage.normalizedUserRotation + deltaDeg) % 360 + 360) % 360;
        _localPageRotations[currentPage.pageNumber] = next;
      }
    });
    if (rotate != null) {
      rotate.onRotatePage(safeIdx, currentPage, deltaDeg);
    }
    _restoreShortcutFocus();
    _resetScrollNextFrame();
  }

  void _resetCurrentRotation() {
    final pages = _effectivePages;
    if (pages.isEmpty) return;
    final safeIdx = _currentIndex.clamp(0, pages.length - 1);
    final currentPage = pages[safeIdx];
    if (currentPage.normalizedUserRotation == 0) return;

    final rotate = widget.rotateActions;
    setState(() {
      _freePanOffset = Offset.zero;
      _isDraggingPdf = false;
      if (rotate == null) {
        _localPageRotations[currentPage.pageNumber] = 0;
      }
    });
    if (rotate != null) {
      if (rotate.onResetPageRotation != null) {
        rotate.onResetPageRotation!(safeIdx, currentPage);
      } else {
        rotate.onRotatePage(
          safeIdx,
          currentPage,
          -currentPage.normalizedUserRotation,
        );
      }
    }
    _restoreShortcutFocus();
    _resetScrollNextFrame();
  }

  void _handleClose() {
    if (widget.onClose != null) {
      widget.onClose!();
    } else if (mounted) {
      Navigator.of(context).pop();
    }
  }

  void _resetScrollNextFrame() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      if (_vScrollController.hasClients) _vScrollController.jumpTo(0.0);
      if (_hScrollController.hasClients) _hScrollController.jumpTo(0.0);
    });
  }

  void _stepPage(int delta) {
    final pages = _effectivePages;
    if (pages.isEmpty) return;
    final current = _currentIndex.clamp(0, pages.length - 1);
    final next = current + delta;
    if (next >= 0 && next < pages.length) {
      setState(() {
        _currentIndex = next;
        _freePanOffset = Offset.zero;
        _isDraggingPdf = false;
      });
      _restoreShortcutFocus();
      _resetScrollNextFrame();
    }
  }

  void _moveReorderPage(int fromIdx, int toIdx) {
    final actions = widget.reorderActions;
    if (actions == null) return;
    final pages = _effectivePages;
    if (fromIdx < 0 ||
        fromIdx >= pages.length ||
        toIdx < 0 ||
        toIdx >= pages.length ||
        fromIdx == toIdx) {
      return;
    }
    setState(() {
      _currentIndex = toIdx;
      _freePanOffset = Offset.zero;
      _isDraggingPdf = false;
    });
    actions.onMovePage(fromIdx, toIdx);
    _restoreShortcutFocus();
    _resetScrollNextFrame();
  }

  void _deleteCurrentReorderPage(int currentIdx) {
    final actions = widget.reorderActions;
    if (actions == null) return;
    final prevLen = _effectivePages.length;
    actions.onDeleteAt(currentIdx);
    final updated = _effectivePages;
    if (updated.length != prevLen && updated.isNotEmpty) {
      setState(() {
        _currentIndex = currentIdx.clamp(0, updated.length - 1);
        _freePanOffset = Offset.zero;
        _isDraggingPdf = false;
      });
      _restoreShortcutFocus();
      _resetScrollNextFrame();
    }
  }

  void _runReorderBatchAction(VoidCallback action) {
    final prevPages = List<PdfPageMeta>.from(_effectivePages);
    if (prevPages.isEmpty) return;
    final safePrevIdx = _currentIndex.clamp(0, prevPages.length - 1);
    final prevOrigPageNum = prevPages[safePrevIdx].pageNumber;

    action();

    final updated = _effectivePages;
    if (updated.isEmpty) return;
    int nextIdx = safePrevIdx.clamp(0, updated.length - 1);
    if (updated.length > prevPages.length) {
      for (int i = 0; i < updated.length; i++) {
        if (i >= prevPages.length ||
            updated[i].pageNumber != prevPages[i].pageNumber) {
          nextIdx = i;
          break;
        }
      }
    } else {
      final matched =
          updated.indexWhere((p) => p.pageNumber == prevOrigPageNum);
      if (matched != -1) {
        nextIdx = matched;
      }
    }
    setState(() {
      _currentIndex = nextIdx;
      _freePanOffset = Offset.zero;
      _isDraggingPdf = false;
    });
    _restoreShortcutFocus();
    _resetScrollNextFrame();
  }

  Size _computeBasePaperSize(Size viewportSize, double ratio) {
    final safeRatio =
        (ratio.isFinite && ratio > 0) ? ratio.clamp(0.05, 20.0) : 1.0;
    final availW = math.max(120.0, viewportSize.width - _canvasPadding * 2);
    final availH = math.max(120.0, viewportSize.height - _canvasPadding * 2);
    double baseW = availW;
    double baseH = baseW / safeRatio;
    if (baseH > availH) {
      baseH = availH;
      baseW = baseH * safeRatio;
    }
    return Size(baseW, baseH);
  }

  void _applyPanDelta(Offset delta) {
    final pages = _effectivePages;
    if (delta == Offset.zero || pages.isEmpty) return;

    final safeIdx = _currentIndex.clamp(0, pages.length - 1);
    final ratio = _currentAspectRatio(pages, safeIdx);
    final renderBox =
        _canvasViewportKey.currentContext?.findRenderObject() as RenderBox?;
    final viewportSize =
        renderBox != null && renderBox.hasSize ? renderBox.size : null;

    double slackX = 0.0;
    double slackY = 0.0;
    if (viewportSize != null) {
      final availW = math.max(120.0, viewportSize.width - _canvasPadding * 2);
      final availH = math.max(120.0, viewportSize.height - _canvasPadding * 2);
      final baseSize = _computeBasePaperSize(viewportSize, ratio);
      final paperW = baseSize.width * _zoomScale;
      final paperH = baseSize.height * _zoomScale;
      slackX = math.max(0.0, (availW - paperW) / 2.0);
      slackY = math.max(0.0, (availH - paperH) / 2.0);
    }

    final hasHScroll = _hScrollController.hasClients &&
        _hScrollController.position.hasContentDimensions &&
        _hScrollController.position.maxScrollExtent > 0.5;
    final hasVScroll = _vScrollController.hasClients &&
        _vScrollController.position.hasContentDimensions &&
        _vScrollController.position.maxScrollExtent > 0.5;

    double nextFreeX = _freePanOffset.dx;
    double nextFreeY = _freePanOffset.dy;

    if (hasHScroll) {
      final pos = _hScrollController.position;
      final targetX =
          (pos.pixels - delta.dx).clamp(pos.minScrollExtent, pos.maxScrollExtent);
      if ((targetX - pos.pixels).abs() > 0.01) {
        _hScrollController.jumpTo(targetX);
      }
      nextFreeX = 0.0;
    } else if (slackX > 0.0) {
      nextFreeX = (_freePanOffset.dx + delta.dx).clamp(-slackX, slackX);
    } else {
      nextFreeX = 0.0;
    }

    if (hasVScroll) {
      final pos = _vScrollController.position;
      final targetY =
          (pos.pixels - delta.dy).clamp(pos.minScrollExtent, pos.maxScrollExtent);
      if ((targetY - pos.pixels).abs() > 0.01) {
        _vScrollController.jumpTo(targetY);
      }
      nextFreeY = 0.0;
    } else if (slackY > 0.0) {
      nextFreeY = (_freePanOffset.dy + delta.dy).clamp(-slackY, slackY);
    } else {
      nextFreeY = 0.0;
    }

    final nextFree = Offset(nextFreeX, nextFreeY);
    if ((nextFree - _freePanOffset).distanceSquared > 0.001) {
      setState(() => _freePanOffset = nextFree);
    }
  }

  void _stepZoom(double delta, {Offset? globalFocalPoint}) {
    _setZoomScale(
      _zoomScale + delta,
      globalFocalPoint: globalFocalPoint,
    );
  }

  void _setZoomScale(double targetScale, {Offset? globalFocalPoint}) {
    final nextScale = ((targetScale * 100).round() / 100.0)
        .clamp(_minZoomScale, _maxZoomScale);
    final isExplicitReset =
        (nextScale - 1.0).abs() < 0.001 && globalFocalPoint == null;
    if ((nextScale - _zoomScale).abs() < 0.001 &&
        !(isExplicitReset && _freePanOffset != Offset.zero)) {
      return;
    }

    final pages = _effectivePages;
    if (pages.isEmpty) return;

    final capturedIndex = _currentIndex.clamp(0, pages.length - 1);
    final oldScale = _zoomScale;
    final ratio = _currentAspectRatio(pages, capturedIndex);

    Size? viewportSize;
    double? uX;
    double? uY;
    double? focalX;
    double? focalY;

    final renderBox =
        _canvasViewportKey.currentContext?.findRenderObject() as RenderBox?;
    if (renderBox != null && renderBox.hasSize) {
      viewportSize = renderBox.size;
      final baseSize = _computeBasePaperSize(viewportSize, ratio);
      final oldPaperW = baseSize.width * oldScale;
      final oldPaperH = baseSize.height * oldScale;
      final availWOld = math.max(120.0, viewportSize.width - _canvasPadding * 2);
      final availHOld = math.max(120.0, viewportSize.height - _canvasPadding * 2);
      final slackXOld = math.max(0.0, (availWOld - oldPaperW) / 2.0);
      final slackYOld = math.max(0.0, (availHOld - oldPaperH) / 2.0);
      final clampedFreeX = _freePanOffset.dx.clamp(-slackXOld, slackXOld);
      final clampedFreeY = _freePanOffset.dy.clamp(-slackYOld, slackYOld);

      if (globalFocalPoint != null) {
        final local = renderBox.globalToLocal(globalFocalPoint);
        focalX = local.dx.clamp(0.0, viewportSize.width);
        focalY = local.dy.clamp(0.0, viewportSize.height);
      } else {
        focalX = viewportSize.width / 2;
        focalY = viewportSize.height / 2;
      }

      final oldOffsetX =
          _hScrollController.hasClients ? _hScrollController.offset : 0.0;
      final oldOffsetY =
          _vScrollController.hasClients ? _vScrollController.offset : 0.0;
      final paperLeftOld =
          math.max(_canvasPadding, (viewportSize.width - oldPaperW) / 2) +
              clampedFreeX;
      final paperTopOld =
          math.max(_canvasPadding, (viewportSize.height - oldPaperH) / 2) +
              clampedFreeY;

      uX = oldPaperW > 0
          ? ((oldOffsetX + focalX - paperLeftOld) / oldPaperW).clamp(0.0, 1.0)
          : 0.5;
      uY = oldPaperH > 0
          ? ((oldOffsetY + focalY - paperTopOld) / oldPaperH).clamp(0.0, 1.0)
          : 0.5;
    }

    setState(() {
      _zoomScale = nextScale;
      if (isExplicitReset || nextScale <= 1.01) {
        _freePanOffset = Offset.zero;
      }
    });

    if (viewportSize != null &&
        uX != null &&
        uY != null &&
        focalX != null &&
        focalY != null) {
      final capturedViewport = viewportSize;
      final capturedUX = uX;
      final capturedUY = uY;
      final capturedFocalX = focalX;
      final capturedFocalY = focalY;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted ||
            _currentIndex != capturedIndex ||
            (_zoomScale - nextScale).abs() >= 0.001) {
          return;
        }
        final baseSize = _computeBasePaperSize(capturedViewport, ratio);
        final newPaperW = baseSize.width * nextScale;
        final newPaperH = baseSize.height * nextScale;
        final availWNew =
            math.max(120.0, capturedViewport.width - _canvasPadding * 2);
        final availHNew =
            math.max(120.0, capturedViewport.height - _canvasPadding * 2);
        final slackXNew = math.max(0.0, (availWNew - newPaperW) / 2.0);
        final slackYNew = math.max(0.0, (availHNew - newPaperH) / 2.0);

        if (nextScale > 1.01 && (slackXNew > 0 || slackYNew > 0)) {
          double nextFreeX = 0.0;
          double nextFreeY = 0.0;
          if (slackXNew > 0) {
            final centeredLeft = (capturedViewport.width - newPaperW) / 2;
            nextFreeX = (capturedFocalX - capturedUX * newPaperW - centeredLeft)
                .clamp(-slackXNew, slackXNew);
          }
          if (slackYNew > 0) {
            final centeredTop = (capturedViewport.height - newPaperH) / 2;
            nextFreeY = (capturedFocalY - capturedUY * newPaperH - centeredTop)
                .clamp(-slackYNew, slackYNew);
          }
          final nextFree = Offset(nextFreeX, nextFreeY);
          if ((nextFree - _freePanOffset).distanceSquared > 0.25) {
            setState(() => _freePanOffset = nextFree);
          }
        } else if (_freePanOffset != Offset.zero) {
          setState(() => _freePanOffset = Offset.zero);
        }

        final paperLeftNew =
            math.max(_canvasPadding, (capturedViewport.width - newPaperW) / 2);
        final paperTopNew =
            math.max(_canvasPadding, (capturedViewport.height - newPaperH) / 2);

        if (_hScrollController.hasClients) {
          final targetX = (paperLeftNew + capturedUX * newPaperW - capturedFocalX)
              .clamp(0.0, _hScrollController.position.maxScrollExtent);
          _hScrollController.jumpTo(targetX);
        }
        if (_vScrollController.hasClients) {
          final targetY = (paperTopNew + capturedUY * newPaperH - capturedFocalY)
              .clamp(0.0, _vScrollController.position.maxScrollExtent);
          _vScrollController.jumpTo(targetY);
        }
      });
    }
  }

  double _computeWheelZoomDelta(PointerScrollEvent event) {
    final dy = event.scrollDelta.dy;
    if (dy == 0.0) return 0.0;
    // Putar scroll ke depan (dy negatif) => Zoom In (+),
    // putar scroll ke belakang (dy positif) => Zoom Out (-).
    if (event.kind == PointerDeviceKind.trackpad) {
      return (-dy / 180.0).clamp(-0.25, 0.25);
    }
    if (dy.abs() >= 15.0) {
      return dy < 0 ? 0.2 : -0.2;
    }
    return (-dy / 90.0).clamp(-0.2, 0.2);
  }

  void _handleZoomPointerSignal(PointerSignalEvent event) {
    if (_isMinimized) return;
    if (event is PointerScrollEvent) {
      if (!HardwareKeyboard.instance.isControlPressed) return;
      if (event.scrollDelta.dy == 0.0) return;
      GestureBinding.instance.pointerSignalResolver.register(event, (resolved) {
        final scrollEvent = resolved as PointerScrollEvent;
        scrollEvent.respond(allowPlatformDefault: false);
        final delta = _computeWheelZoomDelta(scrollEvent);
        if (delta != 0.0) {
          _stepZoom(delta, globalFocalPoint: scrollEvent.position);
        }
      });
    } else if (event is PointerScaleEvent) {
      if ((event.scale - 1.0).abs() < 0.001) return;
      GestureBinding.instance.pointerSignalResolver.register(event, (resolved) {
        final scaleEvent = resolved as PointerScaleEvent;
        scaleEvent.respond(allowPlatformDefault: false);
        _setZoomScale(
          _zoomScale * scaleEvent.scale,
          globalFocalPoint: scaleEvent.position,
        );
      });
    }
  }

  void _toggleMaximize() {
    setState(() {
      _isMinimized = false;
      _isMaximized = !_isMaximized;
      _freePanOffset = Offset.zero;
      _isDraggingPdf = false;
    });
  }

  void _minimizeWindow() {
    setState(() => _isMinimized = true);
  }

  void _restoreWindow({bool maximized = false}) {
    setState(() {
      _isMinimized = false;
      if (maximized) {
        _isMaximized = true;
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final pages = _effectivePages;
    if (pages.isEmpty) {
      return const SizedBox.shrink();
    }
    final safeIdx = _currentIndex.clamp(0, pages.length - 1);
    final currentPage = pages[safeIdx];
    final total = pages.length;
    final customSubtitle =
        widget.pageSubtitleBuilder?.call(safeIdx, currentPage);

    if (_isMinimized) {
      final dockedBar = _buildMinimizedDockBar(currentPage, total);
      if (widget.onClose != null) {
        return Positioned(
          right: 20,
          bottom: 16,
          child: Material(
            type: MaterialType.transparency,
            child: dockedBar,
          ),
        );
      }
      return Align(
        alignment: Alignment.bottomRight,
        child: Padding(
          padding: const EdgeInsets.only(right: 20, bottom: 16),
          child: Material(
            type: MaterialType.transparency,
            child: dockedBar,
          ),
        ),
      );
    }

    final expandedContent = FocusScope(
      autofocus: true,
      child: CallbackShortcuts(
        bindings: {
          const SingleActivator(LogicalKeyboardKey.escape): _handleClose,
          const SingleActivator(LogicalKeyboardKey.f11): _toggleMaximize,
          if (!widget.isImageMode)
            const SingleActivator(LogicalKeyboardKey.arrowLeft): () =>
                _stepPage(-1),
          if (!widget.isImageMode)
            const SingleActivator(LogicalKeyboardKey.arrowRight): () =>
                _stepPage(1),
          const SingleActivator(LogicalKeyboardKey.equal): () =>
              _stepZoom(0.2),
          const SingleActivator(LogicalKeyboardKey.equal, control: true): () =>
              _stepZoom(0.2),
          const SingleActivator(LogicalKeyboardKey.numpadAdd, control: true):
              () => _stepZoom(0.2),
          const SingleActivator(LogicalKeyboardKey.minus): () =>
              _stepZoom(-0.2),
          const SingleActivator(LogicalKeyboardKey.minus, control: true): () =>
              _stepZoom(-0.2),
          const SingleActivator(
            LogicalKeyboardKey.numpadSubtract,
            control: true,
          ): () => _stepZoom(-0.2),
          const SingleActivator(LogicalKeyboardKey.digit0, control: true):
              () => _setZoomScale(1.0),
          const SingleActivator(LogicalKeyboardKey.numpad0, control: true):
              () => _setZoomScale(1.0),
          if (widget.enableRotate)
            const SingleActivator(LogicalKeyboardKey.keyR, control: true): () =>
                _stepRotate(90),
          if (widget.enableRotate)
            const SingleActivator(
              LogicalKeyboardKey.keyR,
              control: true,
              shift: true,
            ): () => _stepRotate(-90),
          if (widget.reorderActions != null)
            const SingleActivator(LogicalKeyboardKey.keyZ, control: true): () {
              final reorder = widget.reorderActions!;
              if (reorder.canUndo()) {
                _runReorderBatchAction(reorder.onUndo);
              }
            },
        },
        child: Focus(
          focusNode: _shortcutFocusNode,
          autofocus: true,
          child: Stack(
            children: [
              Positioned.fill(
                child: GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTap: _handleClose,
                  child: const ColoredBox(color: Colors.black54),
                ),
              ),
              Center(
                child: Material(
                  type: MaterialType.transparency,
                  child: _buildExpandedWindow(
                    context,
                    pages,
                    safeIdx,
                    currentPage,
                    total,
                    customSubtitle,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );

    if (widget.onClose != null) {
      return Positioned.fill(child: expandedContent);
    }
    return expandedContent;
  }

  Widget _buildMinimizedDockBar(PdfPageMeta currentPage, int total) {
    final img = _loadedImageInfo?.image;
    final imageMetaPrefix =
        img != null ? '${img.width}×${img.height} px • ' : '';

    return Container(
      constraints: const BoxConstraints(minWidth: 320, maxWidth: 440),
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
      decoration: BoxDecoration(
        color: AppColors.cardBackground,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: AppColors.primaryCyan, width: 1.5),
        boxShadow: const [
          BoxShadow(
            color: Colors.black54,
            blurRadius: 16,
            offset: Offset(0, 6),
          ),
        ],
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            widget.isImageMode
                ? Icons.image_rounded
                : Icons.picture_as_pdf_rounded,
            color: AppColors.primaryCyan,
            size: 18,
          ),
          const SizedBox(width: 8),
          Flexible(
            child: InkWell(
              onTap: () => _restoreWindow(),
              borderRadius: BorderRadius.circular(4),
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 2, horizontal: 2),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      widget.fileName,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 11.5,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    Text(
                      widget.isImageMode
                          ? '$imageMetaPrefix${(_zoomScale * 100).round()}% (Diminimize)'
                          : (currentPage.normalizedUserRotation == 0
                              ? 'Hal ${currentPage.pageNumber}/$total • ${(_zoomScale * 100).round()}% (Diminimize)'
                              : 'Hal ${currentPage.pageNumber}/$total • ${(_zoomScale * 100).round()}% • ${currentPage.normalizedUserRotation}° (Diminimize)'),
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
            ),
          ),
          const SizedBox(width: 8),
          _buildWindowControlButton(
            icon: Icons.open_in_full_rounded,
            tooltip: 'Pulihkan Pratinjau',
            onTap: () => _restoreWindow(),
          ),
          const SizedBox(width: 4),
          _buildWindowControlButton(
            icon: Icons.crop_square_rounded,
            tooltip: 'Maximize Pratinjau',
            onTap: () => _restoreWindow(maximized: true),
          ),
          const SizedBox(width: 4),
          _buildWindowControlButton(
            icon: Icons.close_rounded,
            tooltip: 'Tutup Pratinjau',
            isClose: true,
            onTap: _handleClose,
          ),
        ],
      ),
    );
  }

  Widget _buildExpandedWindow(
    BuildContext context,
    List<PdfPageMeta> pages,
    int safeIdx,
    PdfPageMeta currentPage,
    int total,
    String? customSubtitle,
  ) {
    final screenSize = MediaQuery.sizeOf(context);
    final windowW = _isMaximized
        ? math.max(360.0, screenSize.width - 20)
        : math.min(920.0, math.max(360.0, screenSize.width - 48));
    final windowH = _isMaximized
        ? math.max(300.0, screenSize.height - 20)
        : math.min(660.0, math.max(300.0, screenSize.height - 52));

    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: () {},
      child: Listener(
        onPointerSignal: _handleZoomPointerSignal,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 160),
          curve: Curves.easeOutCubic,
          width: windowW,
          height: windowH,
          decoration: BoxDecoration(
            color: AppColors.cardBackground,
            borderRadius: BorderRadius.circular(_isMaximized ? 8 : 12),
            border: Border.all(color: AppColors.primaryCyan, width: 1.6),
            boxShadow: const [
              BoxShadow(
                color: Colors.black87,
                blurRadius: 24,
                offset: Offset(0, 10),
              ),
            ],
          ),
          clipBehavior: Clip.antiAlias,
          child: Column(
            children: [
              // Window Title Bar + Zoom Controls + Minimize / Maximize / Close
              Container(
                padding: const EdgeInsets.fromLTRB(14, 10, 10, 8),
                decoration: const BoxDecoration(
                  border: Border(
                    bottom: BorderSide(color: Colors.white10, width: 1),
                  ),
                ),
                child: Row(
                  children: [
                    Expanded(
                      child: GestureDetector(
                        behavior: HitTestBehavior.opaque,
                        onDoubleTap: _toggleMaximize,
                        child: Row(
                          children: [
                            Icon(
                              widget.isImageMode
                                  ? Icons.image_rounded
                                  : Icons.picture_as_pdf_rounded,
                              color: AppColors.primaryCyan,
                              size: 20,
                            ),
                            const SizedBox(width: 8),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    widget.fileName,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: const TextStyle(
                                      color: Colors.white,
                                      fontSize: 13.5,
                                      fontWeight: FontWeight.bold,
                                    ),
                                  ),
                                  Text(
                                    [
                                      if (customSubtitle != null &&
                                          customSubtitle.isNotEmpty)
                                        customSubtitle
                                      else if (widget.isImageMode) ...[
                                        if (widget.contextTitle != null)
                                          widget.contextTitle!,
                                        if (_loadedImageInfo != null)
                                          '${_loadedImageInfo!.image.width}×${_loadedImageInfo!.image.height} px',
                                        if (widget.fileSizeLabel != null)
                                          widget.fileSizeLabel!,
                                      ] else ...[
                                        if (widget.contextTitle != null)
                                          widget.contextTitle!,
                                        '${currentPage.paperSizeLabel} (${currentPage.effectiveWidthPt.round()}×${currentPage.effectiveHeightPt.round()} pt)',
                                        if (widget.fileSizeLabel != null)
                                          widget.fileSizeLabel!,
                                      ],
                                      if (!widget.isImageMode &&
                                          currentPage.normalizedUserRotation !=
                                              0)
                                        'Putar ${currentPage.normalizedUserRotation}°',
                                    ].join(' • '),
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: const TextStyle(
                                      color: AppColors.primaryCyan,
                                      fontSize: 10.5,
                                      fontWeight: FontWeight.w500,
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
                    ConstrainedBox(
                      constraints: BoxConstraints(
                        maxWidth: math.max(220.0, windowW * 0.56),
                      ),
                      child: Wrap(
                        spacing: 4,
                        runSpacing: 4,
                        alignment: WrapAlignment.end,
                        crossAxisAlignment: WrapCrossAlignment.center,
                        children: [
                          _buildZoomControlButton(
                            icon: Icons.zoom_out_rounded,
                            tooltip: 'Perkecil (- atau Ctrl + Scroll Belakang)',
                            onTap: _zoomScale > _minZoomScale + 0.05
                                ? () => _stepZoom(-0.2)
                                : null,
                          ),
                          Tooltip(
                            message:
                                'Klik untuk kembali ke 100% (Ctrl + Scroll untuk Zoom)',
                            child: InkWell(
                              canRequestFocus: false,
                              onTap: () => _setZoomScale(1.0),
                              borderRadius: BorderRadius.circular(4),
                              child: Container(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 7,
                                  vertical: 3,
                                ),
                                decoration: BoxDecoration(
                                  color: AppColors.surface,
                                  borderRadius: BorderRadius.circular(4),
                                  border: Border.all(color: Colors.white12),
                                ),
                                child: Text(
                                  '${(_zoomScale * 100).round()}%',
                                  style: const TextStyle(
                                    color: Colors.white,
                                    fontSize: 10,
                                    fontWeight: FontWeight.bold,
                                  ),
                                ),
                              ),
                            ),
                          ),
                          _buildZoomControlButton(
                            icon: Icons.zoom_in_rounded,
                            tooltip: 'Perbesar (+ atau Ctrl + Scroll Depan)',
                            onTap: _zoomScale < _maxZoomScale - 0.05
                                ? () => _stepZoom(0.2)
                                : null,
                          ),
                          if (widget.enableRotate) ...[
                            Container(
                              width: 1,
                              height: 18,
                              margin: const EdgeInsets.symmetric(horizontal: 4),
                              color: Colors.white24,
                            ),
                            _buildZoomControlButton(
                              key: const Key('pdf_zoom_rotate_left_button'),
                              icon: Icons.rotate_left_rounded,
                              tooltip: 'Putar 90° ke Kiri (Ctrl + Shift + R)',
                              onTap: () => _stepRotate(-90),
                            ),
                            Tooltip(
                              message: currentPage.normalizedUserRotation == 0
                                  ? 'Rotasi saat ini 0° (Ctrl + R untuk Putar +90°)'
                                  : 'Klik untuk reset rotasi (${currentPage.normalizedUserRotation}° -> 0°)',
                              child: InkWell(
                                key: const Key('pdf_zoom_rotate_reset_button'),
                                canRequestFocus: false,
                                onTap: currentPage.normalizedUserRotation != 0
                                    ? _resetCurrentRotation
                                    : null,
                                borderRadius: BorderRadius.circular(4),
                                child: Container(
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 7,
                                    vertical: 3,
                                  ),
                                  decoration: BoxDecoration(
                                    color: currentPage.normalizedUserRotation !=
                                            0
                                        ? AppColors.primaryCyan
                                            .withValues(alpha: 0.16)
                                        : AppColors.surface,
                                    borderRadius: BorderRadius.circular(4),
                                    border: Border.all(
                                      color:
                                          currentPage.normalizedUserRotation !=
                                                  0
                                              ? AppColors.primaryCyan
                                                  .withValues(alpha: 0.65)
                                              : Colors.white12,
                                    ),
                                  ),
                                  child: Text(
                                    '${currentPage.normalizedUserRotation}°',
                                    style: TextStyle(
                                      color:
                                          currentPage.normalizedUserRotation !=
                                                  0
                                              ? AppColors.primaryCyan
                                              : Colors.white,
                                      fontSize: 10,
                                      fontWeight: FontWeight.bold,
                                    ),
                                  ),
                                ),
                              ),
                            ),
                            _buildZoomControlButton(
                              key: const Key('pdf_zoom_rotate_right_button'),
                              icon: Icons.rotate_right_rounded,
                              tooltip: 'Putar 90° ke Kanan (Ctrl + R)',
                              onTap: () => _stepRotate(90),
                            ),
                          ],
                          Container(
                            width: 1,
                            height: 18,
                            margin: const EdgeInsets.symmetric(horizontal: 4),
                            color: Colors.white24,
                          ),
                          _buildWindowControlButton(
                            icon: Icons.minimize_rounded,
                            tooltip: 'Minimize Pratinjau',
                            onTap: _minimizeWindow,
                          ),
                          _buildWindowControlButton(
                            icon: _isMaximized
                                ? Icons.filter_none_rounded
                                : Icons.crop_square_rounded,
                            tooltip: _isMaximized
                                ? 'Kembalikan Ukuran'
                                : 'Maximize Pratinjau',
                            onTap: _toggleMaximize,
                          ),
                          _buildWindowControlButton(
                            icon: Icons.close_rounded,
                            tooltip: 'Tutup Pratinjau',
                            isClose: true,
                            onTap: _handleClose,
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),

              if (widget.splitActions != null || widget.reorderActions != null)
                _buildZoomActionBar(pages, safeIdx, currentPage),

              // PDF Real Page Canvas Area (Ctrl + Scroll Zoom & Left-Click Drag to Pan)
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
                  child: Container(
                    key: _canvasViewportKey,
                    decoration: BoxDecoration(
                      color: const Color(0xFF0A141D),
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(color: Colors.white12),
                    ),
                    clipBehavior: Clip.antiAlias,
                    child: LayoutBuilder(
                      builder: (context, constraints) {
                        final baseSize = _computeBasePaperSize(
                          constraints.biggest,
                          _currentAspectRatio(pages, safeIdx),
                        );
                        final paperW = baseSize.width * _zoomScale;
                        final paperH = baseSize.height * _zoomScale;
                        final availW = math.max(
                          120.0,
                          constraints.maxWidth - _canvasPadding * 2,
                        );
                        final availH = math.max(
                          120.0,
                          constraints.maxHeight - _canvasPadding * 2,
                        );
                        final slackX = math.max(0.0, (availW - paperW) / 2.0);
                        final slackY = math.max(0.0, (availH - paperH) / 2.0);
                        final clampedFreeX =
                            _freePanOffset.dx.clamp(-slackX, slackX);
                        final clampedFreeY =
                            _freePanOffset.dy.clamp(-slackY, slackY);

                        final dpr = MediaQuery.devicePixelRatioOf(context);
                        final targetMaxEdgePx =
                            math.max(paperW, paperH) * math.max(1.35, dpr);

                        return Scrollbar(
                          controller: _vScrollController,
                          thumbVisibility: _zoomScale > 1.05,
                          child: SingleChildScrollView(
                            controller: _vScrollController,
                            scrollDirection: Axis.vertical,
                            child: Scrollbar(
                              controller: _hScrollController,
                              thumbVisibility: _zoomScale > 1.05,
                              notificationPredicate: (n) => n.depth == 0,
                              child: SingleChildScrollView(
                                controller: _hScrollController,
                                scrollDirection: Axis.horizontal,
                                child: Listener(
                                  key: const Key('pdf_zoom_canvas_listener'),
                                  behavior: HitTestBehavior.opaque,
                                  onPointerSignal: _handleZoomPointerSignal,
                                  child: RawGestureDetector(
                                    behavior: HitTestBehavior.opaque,
                                    gestures: <Type, GestureRecognizerFactory>{
                                      PanGestureRecognizer:
                                          GestureRecognizerFactoryWithHandlers<
                                              PanGestureRecognizer>(
                                        () => PanGestureRecognizer(
                                          supportedDevices: const {
                                            PointerDeviceKind.mouse,
                                            PointerDeviceKind.touch,
                                            PointerDeviceKind.stylus,
                                            PointerDeviceKind.invertedStylus,
                                            PointerDeviceKind.trackpad,
                                          },
                                        ),
                                        (PanGestureRecognizer instance) {
                                          instance
                                            ..dragStartBehavior =
                                                DragStartBehavior.down
                                            ..gestureSettings =
                                                const DeviceGestureSettings(
                                              touchSlop: 2.0,
                                            )
                                            ..onDown = (_) {
                                              if (mounted && !_isDraggingPdf) {
                                                setState(
                                                  () => _isDraggingPdf = true,
                                                );
                                              }
                                            }
                                            ..onStart = (_) {
                                              if (mounted && !_isDraggingPdf) {
                                                setState(
                                                  () => _isDraggingPdf = true,
                                                );
                                              }
                                            }
                                            ..onUpdate =
                                                (DragUpdateDetails details) {
                                              _applyPanDelta(details.delta);
                                            }
                                            ..onEnd = (_) {
                                              if (mounted && _isDraggingPdf) {
                                                setState(
                                                  () => _isDraggingPdf = false,
                                                );
                                              }
                                            }
                                            ..onCancel = () {
                                              if (mounted && _isDraggingPdf) {
                                                setState(
                                                  () => _isDraggingPdf = false,
                                                );
                                              }
                                            };
                                        },
                                      ),
                                    },
                                    child: MouseRegion(
                                      cursor: _isDraggingPdf
                                          ? SystemMouseCursors.grabbing
                                          : SystemMouseCursors.grab,
                                      child: ConstrainedBox(
                                        constraints: BoxConstraints(
                                          minWidth: constraints.maxWidth,
                                          minHeight: constraints.maxHeight,
                                        ),
                                        child: Center(
                                          child: Transform.translate(
                                            offset: Offset(
                                              clampedFreeX,
                                              clampedFreeY,
                                            ),
                                            child: Padding(
                                              padding: const EdgeInsets.all(
                                                _canvasPadding,
                                              ),
                                              child: SizedBox(
                                                width: paperW,
                                                height: paperH,
                                                child: widget.isImageMode
                                                    ? _buildImageZoomStage()
                                                    : PdfRealPagePreview(
                                                        filePath:
                                                            widget.filePath,
                                                        page: currentPage,
                                                        quality:
                                                            PdfRenderQuality
                                                                .zoom,
                                                        targetMaxEdgePx:
                                                            targetMaxEdgePx,
                                                        isZoomView: true,
                                                        totalPages: total,
                                                        fallbackTitle: widget
                                                                .showSequencePosition
                                                            ? 'Posisi #${safeIdx + 1} • Halaman Asli ${currentPage.pageNumber}'
                                                            : widget.fileName,
                                                      ),
                                              ),
                                            ),
                                          ),
                                        ),
                                      ),
                                    ),
                                  ),
                                ),
                              ),
                            ),
                          ),
                        );
                      },
                    ),
                  ),
                ),
              ),

              if (_showStandalonePagePicker &&
                  widget.splitActions == null &&
                  widget.reorderActions == null &&
                  total > 1)
                Container(
                  margin: const EdgeInsets.fromLTRB(14, 0, 14, 8),
                  padding: const EdgeInsets.symmetric(
                    horizontal: 10,
                    vertical: 6,
                  ),
                  decoration: BoxDecoration(
                    color: AppColors.surface,
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(
                      color: AppColors.primaryCyan.withValues(alpha: 0.35),
                    ),
                  ),
                  child: SizedBox(
                    height: 28,
                    child: ListView.separated(
                      scrollDirection: Axis.horizontal,
                      itemCount: pages.length,
                      separatorBuilder: (_, _) => const SizedBox(width: 5),
                      itemBuilder: (context, idx) {
                        final page = pages[idx];
                        final isCurrent = idx == safeIdx;
                        return GestureDetector(
                          onTap: () {
                            setState(() {
                              _currentIndex = idx;
                              _freePanOffset = Offset.zero;
                              _isDraggingPdf = false;
                            });
                            _resetScrollNextFrame();
                            _restoreShortcutFocus();
                          },
                          child: Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 9,
                              vertical: 4,
                            ),
                            decoration: BoxDecoration(
                              color: isCurrent
                                  ? AppColors.primaryCyan
                                  : AppColors.cardBackground,
                              borderRadius: BorderRadius.circular(14),
                              border: Border.all(
                                color: isCurrent
                                    ? AppColors.primaryCyan
                                    : Colors.white24,
                              ),
                            ),
                            alignment: Alignment.center,
                            child: Text(
                              'Hal ${page.pageNumber}',
                              style: TextStyle(
                                color: isCurrent
                                    ? Colors.black
                                    : Colors.white70,
                                fontSize: 10,
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                          ),
                        );
                      },
                    ),
                  ),
                ),

              // Footer Navigation Bar
              Padding(
                padding: const EdgeInsets.fromLTRB(14, 0, 14, 12),
                child: Row(
                  children: [
                    if (!widget.isImageMode) ...[
                      PreviewHeaderButton(
                        label: 'Sebelumnya',
                        icon: Icons.chevron_left_rounded,
                        canRequestFocus: false,
                        onPressed: safeIdx > 0 ? () => _stepPage(-1) : null,
                      ),
                      const SizedBox(width: 8),
                    ],
                    Expanded(
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          if (widget.isImageMode)
                            Text(
                              _loadedImageInfo != null
                                  ? 'Pratinjau Gambar • ${_loadedImageInfo!.image.width}×${_loadedImageInfo!.image.height} px'
                                  : 'Pratinjau Gambar',
                              textAlign: TextAlign.center,
                              style: const TextStyle(
                                color: Colors.white70,
                                fontSize: 11.5,
                                fontWeight: FontWeight.w600,
                              ),
                            )
                          else if (widget.splitActions == null &&
                              widget.reorderActions == null &&
                              !widget.showSequencePosition &&
                              total > 1)
                            Tooltip(
                              message:
                                  'Klik untuk memilih langsung halaman 1–$total',
                              child: InkWell(
                                key: const Key(
                                  'pdf_zoom_standalone_page_picker_button',
                                ),
                                canRequestFocus: false,
                                onTap: () {
                                  setState(
                                    () => _showStandalonePagePicker =
                                        !_showStandalonePagePicker,
                                  );
                                  _restoreShortcutFocus();
                                },
                                borderRadius: BorderRadius.circular(4),
                                child: Padding(
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 8,
                                    vertical: 1,
                                  ),
                                  child: Row(
                                    mainAxisSize: MainAxisSize.min,
                                    mainAxisAlignment: MainAxisAlignment.center,
                                    children: [
                                      Text(
                                        'Halaman ${currentPage.pageNumber} dari $total',
                                        textAlign: TextAlign.center,
                                        style: const TextStyle(
                                          color: Colors.white70,
                                          fontSize: 11.5,
                                          fontWeight: FontWeight.w600,
                                        ),
                                      ),
                                      const SizedBox(width: 4),
                                      Icon(
                                        _showStandalonePagePicker
                                            ? Icons.expand_less_rounded
                                            : Icons.expand_more_rounded,
                                        size: 15,
                                        color: AppColors.primaryCyan,
                                      ),
                                    ],
                                  ),
                                ),
                              ),
                            )
                          else
                            Text(
                              widget.showSequencePosition
                                  ? 'Posisi ${safeIdx + 1} / $total (Hal ${currentPage.pageNumber})'
                                  : 'Halaman ${currentPage.pageNumber} dari $total',
                              textAlign: TextAlign.center,
                              style: const TextStyle(
                                color: Colors.white70,
                                fontSize: 11.5,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          Text(
                            widget.enableRotate
                                ? 'Ctrl + Scroll Mouse untuk Zoom • Tahan Klik Kiri & Geser untuk Drag • Ctrl + R untuk Putar'
                                : 'Ctrl + Scroll Mouse untuk Zoom • Tahan Klik Kiri & Geser untuk Drag',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            textAlign: TextAlign.center,
                            style: const TextStyle(
                              color: Colors.white38,
                              fontSize: 9.5,
                            ),
                          ),
                        ],
                      ),
                    ),
                    if (!widget.isImageMode) ...[
                      const SizedBox(width: 8),
                      PreviewHeaderButton(
                        label: 'Berikutnya',
                        icon: Icons.chevron_right_rounded,
                        canRequestFocus: false,
                        onPressed:
                            safeIdx < total - 1 ? () => _stepPage(1) : null,
                      ),
                    ],
                    const SizedBox(width: 12),
                    ElevatedButton(
                      style: ElevatedButton.styleFrom(
                        backgroundColor: AppColors.primaryCyan,
                        foregroundColor: Colors.black,
                        padding: const EdgeInsets.symmetric(
                          horizontal: 14,
                          vertical: 8,
                        ),
                      ),
                      onPressed: _handleClose,
                      child: const Text(
                        'Tutup',
                        style: TextStyle(
                          fontWeight: FontWeight.bold,
                          fontSize: 11.5,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildZoomActionBar(
    List<PdfPageMeta> pages,
    int safeIdx,
    PdfPageMeta currentPage,
  ) {
    final split = widget.splitActions;
    if (split != null) {
      final selectedSet = split.getSelectedPages();
      final isChecked = selectedSet.contains(currentPage.pageNumber);
      final compacted =
          PdfInspectorService.formatCompactPageRanges(selectedSet.toList());
      const accentGreen = Color(0xFF00E676);

      return Container(
        margin: const EdgeInsets.fromLTRB(12, 8, 12, 0),
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        decoration: BoxDecoration(
          color: AppColors.surface,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(
            color: isChecked
                ? accentGreen.withValues(alpha: 0.55)
                : Colors.white12,
          ),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            SizedBox(
              width: double.infinity,
              child: Wrap(
                alignment: WrapAlignment.spaceBetween,
                crossAxisAlignment: WrapCrossAlignment.center,
                spacing: 8,
                runSpacing: 6,
                children: [
                  Wrap(
                    spacing: 8,
                    runSpacing: 4,
                    crossAxisAlignment: WrapCrossAlignment.center,
                    children: [
                      Material(
                        color: Colors.transparent,
                        child: InkWell(
                          key: const Key('pdf_zoom_split_check_button'),
                          canRequestFocus: false,
                          onTap: () {
                            split.onTogglePage(currentPage.pageNumber);
                            _restoreShortcutFocus();
                          },
                          borderRadius: BorderRadius.circular(6),
                          child: Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 10,
                              vertical: 5,
                            ),
                            decoration: BoxDecoration(
                              color: isChecked
                                  ? accentGreen.withValues(alpha: 0.16)
                                  : Colors.white.withValues(alpha: 0.05),
                              borderRadius: BorderRadius.circular(6),
                              border: Border.all(
                                color:
                                    isChecked ? accentGreen : Colors.white24,
                              ),
                            ),
                            child: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Container(
                                  width: 20,
                                  height: 20,
                                  decoration: BoxDecoration(
                                    shape: BoxShape.circle,
                                    color: isChecked
                                        ? accentGreen
                                        : Colors.grey.shade700,
                                  ),
                                  child: Icon(
                                    Icons.check,
                                    color: isChecked
                                        ? Colors.black
                                        : Colors.white70,
                                    size: 13,
                                  ),
                                ),
                                const SizedBox(width: 7),
                                Text(
                                  isChecked
                                      ? 'Hal ${currentPage.pageNumber} Dipilih (Split)'
                                      : 'Pilih Hal ${currentPage.pageNumber} untuk Split',
                                  style: TextStyle(
                                    color:
                                        isChecked ? accentGreen : Colors.white,
                                    fontSize: 11,
                                    fontWeight: FontWeight.bold,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                      ),
                      if (pages.length > 1)
                        Tooltip(
                          message: 'Klik untuk lompat ke halaman tertentu',
                          child: Material(
                            color: Colors.transparent,
                            child: InkWell(
                              key: const Key('pdf_zoom_split_page_picker_button'),
                              canRequestFocus: false,
                              onTap: () {
                                setState(
                                  () => _showSplitPagePicker =
                                      !_showSplitPagePicker,
                                );
                                _restoreShortcutFocus();
                              },
                              borderRadius: BorderRadius.circular(6),
                              child: Container(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 9,
                                  vertical: 5,
                                ),
                                decoration: BoxDecoration(
                                  color: AppColors.primaryCyan
                                      .withValues(alpha: 0.14),
                                  borderRadius: BorderRadius.circular(6),
                                  border: Border.all(
                                    color: AppColors.primaryCyan
                                        .withValues(alpha: 0.55),
                                  ),
                                ),
                                child: Row(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    Text(
                                      'Hal ${currentPage.pageNumber} / ${pages.length}',
                                      style: const TextStyle(
                                        color: AppColors.primaryCyan,
                                        fontSize: 10.5,
                                        fontWeight: FontWeight.bold,
                                      ),
                                    ),
                                    const SizedBox(width: 3),
                                    Icon(
                                      _showSplitPagePicker
                                          ? Icons.expand_less_rounded
                                          : Icons.expand_more_rounded,
                                      size: 14,
                                      color: AppColors.primaryCyan,
                                    ),
                                  ],
                                ),
                              ),
                            ),
                          ),
                        ),
                      Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 9,
                          vertical: 5,
                        ),
                        decoration: BoxDecoration(
                          color: selectedSet.isEmpty
                              ? Colors.white.withValues(alpha: 0.05)
                              : accentGreen.withValues(alpha: 0.14),
                          borderRadius: BorderRadius.circular(6),
                          border: Border.all(
                            color: selectedSet.isEmpty
                                ? Colors.white12
                                : accentGreen.withValues(alpha: 0.45),
                          ),
                        ),
                        child: Text(
                          selectedSet.isEmpty
                              ? 'Dipilih: 0'
                              : 'Dipilih (${selectedSet.length}): $compacted',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            color: selectedSet.isEmpty
                                ? Colors.white60
                                : accentGreen,
                            fontSize: 10.5,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ),
                    ],
                  ),
                  Wrap(
                    spacing: 6,
                    runSpacing: 4,
                    children: [
                      if (split.onSelectAll != null)
                        PreviewHeaderButton(
                          label: 'Pilih Semua',
                          icon: Icons.done_all_rounded,
                          canRequestFocus: false,
                          onPressed: selectedSet.length < pages.length
                              ? split.onSelectAll
                              : null,
                        ),
                      if (split.onClearSelection != null)
                        PreviewHeaderButton(
                          label: 'Hapus Pilihan',
                          icon: Icons.deselect_rounded,
                          canRequestFocus: false,
                          onPressed: selectedSet.isNotEmpty
                              ? split.onClearSelection
                              : null,
                        ),
                    ],
                  ),
                ],
              ),
            ),
            if (_showSplitPagePicker && pages.length > 1) ...[
              const SizedBox(height: 6),
              SizedBox(
                height: 28,
                child: ListView.separated(
                  scrollDirection: Axis.horizontal,
                  itemCount: pages.length,
                  separatorBuilder: (_, _) => const SizedBox(width: 5),
                  itemBuilder: (context, idx) {
                    final page = pages[idx];
                    final isCurrent = idx == safeIdx;
                    final pageChecked = selectedSet.contains(page.pageNumber);
                    return GestureDetector(
                      onTap: () {
                        setState(() {
                          _currentIndex = idx;
                          _freePanOffset = Offset.zero;
                          _isDraggingPdf = false;
                        });
                        _resetScrollNextFrame();
                      },
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 8,
                          vertical: 4,
                        ),
                        decoration: BoxDecoration(
                          color: isCurrent
                              ? AppColors.primaryCyan
                              : (pageChecked
                                  ? accentGreen.withValues(alpha: 0.16)
                                  : AppColors.cardBackground),
                          borderRadius: BorderRadius.circular(14),
                          border: Border.all(
                            color: isCurrent
                                ? AppColors.primaryCyan
                                : (pageChecked ? accentGreen : Colors.white24),
                          ),
                        ),
                        alignment: Alignment.center,
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            if (pageChecked) ...[
                              Icon(
                                Icons.check_circle,
                                size: 12,
                                color: isCurrent ? Colors.black : accentGreen,
                              ),
                              const SizedBox(width: 4),
                            ],
                            Text(
                              'Hal ${page.pageNumber}',
                              style: TextStyle(
                                color: isCurrent
                                    ? Colors.black
                                    : (pageChecked
                                        ? accentGreen
                                        : Colors.white70),
                                fontSize: 10,
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                          ],
                        ),
                      ),
                    );
                  },
                ),
              ),
            ],
          ],
        ),
      );
    }

    final reorder = widget.reorderActions!;
    final total = pages.length;
    final origCount = reorder.getOriginalPageCount();
    final canUndo = reorder.canUndo();

    return Container(
      margin: const EdgeInsets.fromLTRB(12, 8, 12, 0),
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(
          color: AppColors.primaryCyan.withValues(alpha: 0.35),
        ),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          SizedBox(
            width: double.infinity,
            child: Wrap(
              alignment: WrapAlignment.spaceBetween,
              crossAxisAlignment: WrapCrossAlignment.center,
              spacing: 8,
              runSpacing: 6,
              children: [
                Wrap(
                  spacing: 6,
                  runSpacing: 4,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    PreviewHeaderButton(
                      key: const Key('pdf_zoom_reorder_move_left_button'),
                      label: 'Geser Kiri',
                      icon: Icons.arrow_back_rounded,
                      canRequestFocus: false,
                      tooltip: safeIdx > 0
                          ? 'Pindahkan Hal ${currentPage.pageNumber} ke Pos #$safeIdx'
                          : 'Sudah berada di posisi paling awal',
                      onPressed: safeIdx > 0
                          ? () => _moveReorderPage(safeIdx, safeIdx - 1)
                          : null,
                    ),
                    Tooltip(
                      message: 'Klik untuk pindah langsung ke posisi tertentu',
                      child: Material(
                        color: Colors.transparent,
                        child: InkWell(
                          key: const Key('pdf_zoom_reorder_pos_picker_button'),
                          canRequestFocus: false,
                          onTap: total > 1
                              ? () {
                                  setState(
                                    () => _showReorderTargetPicker =
                                        !_showReorderTargetPicker,
                                  );
                                  _restoreShortcutFocus();
                                }
                              : null,
                          borderRadius: BorderRadius.circular(6),
                          child: Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 9,
                              vertical: 5,
                            ),
                            decoration: BoxDecoration(
                              color: AppColors.primaryCyan
                                  .withValues(alpha: 0.16),
                              borderRadius: BorderRadius.circular(6),
                              border: Border.all(
                                color: AppColors.primaryCyan
                                    .withValues(alpha: 0.65),
                              ),
                            ),
                            child: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Text(
                                  'Pos #${safeIdx + 1} / $total',
                                  style: const TextStyle(
                                    color: AppColors.primaryCyan,
                                    fontSize: 10.5,
                                    fontWeight: FontWeight.bold,
                                  ),
                                ),
                                if (total > 1) ...[
                                  const SizedBox(width: 3),
                                  Icon(
                                    _showReorderTargetPicker
                                        ? Icons.expand_less_rounded
                                        : Icons.expand_more_rounded,
                                    size: 14,
                                    color: AppColors.primaryCyan,
                                  ),
                                ],
                              ],
                            ),
                          ),
                        ),
                      ),
                    ),
                    PreviewHeaderButton(
                      key: const Key('pdf_zoom_reorder_move_right_button'),
                      label: 'Geser Kanan',
                      icon: Icons.arrow_forward_rounded,
                      canRequestFocus: false,
                      tooltip: safeIdx < total - 1
                          ? 'Pindahkan Hal ${currentPage.pageNumber} ke Pos #${safeIdx + 2}'
                          : 'Sudah berada di posisi paling akhir',
                      onPressed: safeIdx < total - 1
                          ? () => _moveReorderPage(safeIdx, safeIdx + 1)
                          : null,
                    ),
                    if (total < origCount)
                      Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 8,
                          vertical: 4,
                        ),
                        decoration: BoxDecoration(
                          color: Colors.orangeAccent.withValues(alpha: 0.14),
                          borderRadius: BorderRadius.circular(6),
                          border: Border.all(
                            color: Colors.orangeAccent.withValues(alpha: 0.55),
                          ),
                        ),
                        child: Text(
                          'Aktif: $total/$origCount Hal',
                          style: const TextStyle(
                            color: Colors.orangeAccent,
                            fontSize: 10,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ),
                  ],
                ),
                Wrap(
                  spacing: 6,
                  runSpacing: 4,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    PreviewHeaderButton(
                      key: const Key('pdf_zoom_reorder_reverse_button'),
                      label: 'Balik Urutan',
                      icon: Icons.swap_vert_rounded,
                      canRequestFocus: false,
                      tooltip: 'Balik urutan seluruh halaman (N..1)',
                      onPressed: total > 1
                          ? () => _runReorderBatchAction(reorder.onReverseOrder)
                          : null,
                    ),
                    PreviewHeaderButton(
                      key: const Key('pdf_zoom_reorder_undo_button'),
                      label: 'Undo 1x',
                      icon: Icons.undo_rounded,
                      canRequestFocus: false,
                      tooltip: 'Kembalikan 1 langkah sebelumnya (Ctrl + Z)',
                      onPressed: canUndo
                          ? () => _runReorderBatchAction(reorder.onUndo)
                          : null,
                    ),
                    PreviewHeaderButton(
                      key: const Key('pdf_zoom_reorder_reset_button'),
                      label: 'Reset 1..N',
                      icon: Icons.restart_alt_rounded,
                      canRequestFocus: false,
                      tooltip: 'Kembalikan urutan halaman asli (1..N)',
                      onPressed: () =>
                          _runReorderBatchAction(reorder.onResetOrder),
                    ),
                    Tooltip(
                      message: 'Hapus Hal ${currentPage.pageNumber} dari Reorder',
                      child: Material(
                        color: Colors.transparent,
                        child: InkWell(
                          key: const Key('pdf_zoom_reorder_delete_button'),
                          canRequestFocus: false,
                          onTap: () => _deleteCurrentReorderPage(safeIdx),
                          borderRadius: BorderRadius.circular(6),
                          child: Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 9,
                              vertical: 4,
                            ),
                            decoration: BoxDecoration(
                              color: Colors.redAccent.withValues(
                                alpha: total > 1 ? 0.16 : 0.06,
                              ),
                              borderRadius: BorderRadius.circular(6),
                              border: Border.all(
                                color: Colors.redAccent.withValues(
                                  alpha: total > 1 ? 0.75 : 0.35,
                                ),
                              ),
                            ),
                            child: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Container(
                                  width: 17,
                                  height: 17,
                                  decoration: BoxDecoration(
                                    shape: BoxShape.circle,
                                    color: Colors.redAccent.withValues(
                                      alpha: total > 1 ? 0.9 : 0.45,
                                    ),
                                  ),
                                  child: const Icon(
                                    Icons.close_rounded,
                                    size: 12,
                                    color: Colors.white,
                                  ),
                                ),
                                const SizedBox(width: 5),
                                Text(
                                  'Hapus',
                                  style: TextStyle(
                                    color: total > 1
                                        ? Colors.redAccent
                                        : Colors.redAccent.withValues(alpha: 0.5),
                                    fontSize: 10.5,
                                    fontWeight: FontWeight.bold,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
          if (_showReorderTargetPicker && total > 1) ...[
            const SizedBox(height: 6),
            SizedBox(
              height: 28,
              child: ListView.separated(
                scrollDirection: Axis.horizontal,
                itemCount: total,
                separatorBuilder: (_, _) => const SizedBox(width: 5),
                itemBuilder: (context, targetIdx) {
                  final isCurrent = targetIdx == safeIdx;
                  final targetPage = pages[targetIdx];
                  return GestureDetector(
                    onTap: isCurrent
                        ? () =>
                            setState(() => _showReorderTargetPicker = false)
                        : () {
                            setState(() => _showReorderTargetPicker = false);
                            _moveReorderPage(safeIdx, targetIdx);
                          },
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 8,
                        vertical: 4,
                      ),
                      decoration: BoxDecoration(
                        color: isCurrent
                            ? AppColors.primaryCyan
                            : AppColors.cardBackground,
                        borderRadius: BorderRadius.circular(14),
                        border: Border.all(
                          color: isCurrent
                              ? AppColors.primaryCyan
                              : Colors.white24,
                        ),
                      ),
                      alignment: Alignment.center,
                      child: Text(
                        isCurrent
                            ? 'Pos #${targetIdx + 1} (Sekarang)'
                            : 'Pindah ke #${targetIdx + 1} (Hal ${targetPage.pageNumber})',
                        style: TextStyle(
                          color: isCurrent ? Colors.black : Colors.white70,
                          fontSize: 10,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ),
                  );
                },
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildImageZoomStage() {
    final loadedImage = _loadedImageInfo?.image;

    return Center(
      child: AspectRatio(
        aspectRatio: _currentAspectRatio(_effectivePages, 0),
        child: Container(
          decoration: BoxDecoration(
            color: const Color(0xFF101C26),
            borderRadius: BorderRadius.circular(4),
            border: Border.all(color: Colors.white24, width: 1),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: 0.55),
                blurRadius: 14,
                offset: const Offset(0, 5),
              ),
            ],
          ),
          clipBehavior: Clip.antiAlias,
          child: loadedImage != null
              ? RawImage(
                  key: const Key('image_zoom_raw_image'),
                  image: loadedImage,
                  fit: BoxFit.contain,
                  filterQuality: FilterQuality.medium,
                )
              : (_isImageLoading
                  ? const Center(
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          SizedBox(
                            width: 26,
                            height: 26,
                            child: CircularProgressIndicator(
                              strokeWidth: 2.2,
                              valueColor: AlwaysStoppedAnimation<Color>(
                                AppColors.primaryCyan,
                              ),
                            ),
                          ),
                          SizedBox(height: 8),
                          Text(
                            'Memuat gambar...',
                            style: TextStyle(
                              color: Colors.white70,
                              fontSize: 11.5,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ],
                      ),
                    )
                  : Center(
                      child: Padding(
                        padding: const EdgeInsets.all(16),
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            const Icon(
                              Icons.broken_image_outlined,
                              color: Colors.orangeAccent,
                              size: 36,
                            ),
                            const SizedBox(height: 8),
                            Text(
                              _imageLoadError ??
                                  'Gagal memuat pratinjau gambar.',
                              textAlign: TextAlign.center,
                              style: const TextStyle(
                                color: Colors.white70,
                                fontSize: 12,
                              ),
                            ),
                          ],
                        ),
                      ),
                    )),
        ),
      ),
    );
  }

  Widget _buildZoomControlButton({
    Key? key,
    required IconData icon,
    required String tooltip,
    required VoidCallback? onTap,
  }) {
    return Tooltip(
      message: tooltip,
      child: InkWell(
        key: key,
        canRequestFocus: false,
        onTap: onTap,
        borderRadius: BorderRadius.circular(4),
        child: Container(
          padding: const EdgeInsets.all(4),
          decoration: BoxDecoration(
            color: AppColors.surface,
            borderRadius: BorderRadius.circular(4),
            border: Border.all(color: Colors.white12),
          ),
          child: Icon(
            icon,
            size: 15,
            color: onTap != null ? AppColors.primaryCyan : Colors.white30,
          ),
        ),
      ),
    );
  }

  Widget _buildWindowControlButton({
    required IconData icon,
    required String tooltip,
    required VoidCallback onTap,
    bool isClose = false,
  }) {
    return Tooltip(
      message: tooltip,
      child: InkWell(
        canRequestFocus: false,
        onTap: onTap,
        borderRadius: BorderRadius.circular(4),
        child: Container(
          width: 24,
          height: 24,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: isClose
                ? Colors.redAccent.withValues(alpha: 0.14)
                : AppColors.surface,
            borderRadius: BorderRadius.circular(4),
            border: Border.all(
              color: isClose
                  ? Colors.redAccent.withValues(alpha: 0.55)
                  : Colors.white24,
            ),
          ),
          child: Icon(
            icon,
            size: 14,
            color: isClose ? Colors.redAccent : Colors.white,
          ),
        ),
      ),
    );
  }
}
