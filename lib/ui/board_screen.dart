import 'package:flutter/material.dart';
import 'package:flutter_staggered_grid_view/flutter_staggered_grid_view.dart';

import '../models/note.dart';
import '../repository/notes_repository.dart';
import '../settings/app_settings.dart';
import 'note_editor.dart';
import 'settings_screen.dart';

class BoardScreen extends StatelessWidget {
  const BoardScreen({
    super.key,
    required this.repo,
    required this.settings,
  });

  final NotesRepository repo;
  final AppSettings settings;

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: repo,
      builder: (context, _) {
        final notes = repo.notes;
        return Scaffold(
          appBar: AppBar(
            title: const Text('Just Notes'),
            actions: [
              _SyncButton(repo: repo),
              IconButton(
                tooltip: 'Settings',
                icon: const Icon(Icons.settings_outlined),
                onPressed: () => Navigator.of(context).push(
                  MaterialPageRoute<void>(
                    builder: (_) => SettingsScreen(
                      repo: repo,
                      settings: settings,
                    ),
                  ),
                ),
              ),
            ],
          ),
          body: RefreshIndicator(
            onRefresh: repo.sync,
            child: notes.isEmpty
                ? ListView(
                    physics: const AlwaysScrollableScrollPhysics(),
                    children: const [
                      SizedBox(height: 120),
                      _EmptyState(),
                    ],
                  )
                : _ReorderableBoard(repo: repo),
          ),
          floatingActionButton: FloatingActionButton(
            onPressed: () async {
              final note = await repo.create();
              if (!context.mounted) return;
              await Navigator.of(context).push(
                MaterialPageRoute<void>(
                  builder: (_) => NoteEditorScreen(repo: repo, note: note),
                ),
              );
            },
            child: const Icon(Icons.add),
          ),
        );
      },
    );
  }

  static int _columnsFor(BuildContext context) {
    final w = MediaQuery.of(context).size.width;
    if (w >= 1200) return 5;
    if (w >= 900) return 4;
    if (w >= 600) return 3;
    return 2;
  }
}

/// Board widget that supports Google Keep-style drag-to-reorder.
/// Notes smoothly rearrange as you drag, showing the live insertion point.
class _ReorderableBoard extends StatefulWidget {
  const _ReorderableBoard({required this.repo});
  final NotesRepository repo;

  @override
  State<_ReorderableBoard> createState() => _ReorderableBoardState();
}

class _ReorderableBoardState extends State<_ReorderableBoard> {
  /// The note currently being dragged, or null.
  String? _draggedId;

  /// The visual index where the dragged note should appear.
  int? _hoverIndex;

  /// Build order: the list with the dragged note moved to the hover position.
  List<Note> _displayOrder(List<Note> notes) {
    if (_draggedId == null || _hoverIndex == null) return notes;
    final list = notes.toList();
    final fromIdx = list.indexWhere((n) => n.id == _draggedId);
    if (fromIdx < 0) return notes;
    final note = list.removeAt(fromIdx);
    final insertIdx = _hoverIndex!.clamp(0, list.length);
    list.insert(insertIdx, note);
    return list;
  }

  @override
  Widget build(BuildContext context) {
    final notes = widget.repo.notes;
    final displayed = _displayOrder(notes);
    return Padding(
      padding: const EdgeInsets.all(8),
      child: MasonryGridView.count(
        key: ValueKey('${displayed.map((n) => n.id).join(',')}_$_draggedId'),
        physics: const AlwaysScrollableScrollPhysics(),
        crossAxisCount: BoardScreen._columnsFor(context),
        mainAxisSpacing: 8,
        crossAxisSpacing: 8,
        itemCount: displayed.length,
        itemBuilder: (context, i) {
          final note = displayed[i];
          final isDragged = note.id == _draggedId;
          return _DraggableSticky(
            key: ValueKey('${note.id}_$isDragged'),
            note: note,
            repo: widget.repo,
            isDragged: isDragged,
            onDragStarted: () {
              setState(() {
                _draggedId = note.id;
                _hoverIndex = i;
              });
            },
            onDragEnd: () {
              if (_draggedId != null && _hoverIndex != null) {
                final originalIdx =
                    notes.indexWhere((n) => n.id == _draggedId);
                if (originalIdx >= 0 && originalIdx != _hoverIndex) {
                  widget.repo.reorderToIndex(_draggedId!, _hoverIndex!);
                }
              }
              setState(() {
                _draggedId = null;
                _hoverIndex = null;
              });
            },
            onHover: () {
              if (_draggedId != null && _draggedId != note.id) {
                final targetIdx =
                    displayed.indexWhere((n) => n.id == note.id);
                if (targetIdx >= 0 && targetIdx != _hoverIndex) {
                  setState(() => _hoverIndex = targetIdx);
                }
              }
            },
          );
        },
      ),
    );
  }
}

class _SyncButton extends StatefulWidget {
  const _SyncButton({required this.repo});
  final NotesRepository repo;

  @override
  State<_SyncButton> createState() => _SyncButtonState();
}

class _SyncButtonState extends State<_SyncButton>
    with SingleTickerProviderStateMixin {
  late final AnimationController _spin = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 800),
  );

  @override
  void initState() {
    super.initState();
    widget.repo.addListener(_update);
    if (widget.repo.syncing) _spin.repeat();
  }

  void _update() {
    if (widget.repo.syncing) {
      if (!_spin.isAnimating) _spin.repeat();
    } else {
      _spin.stop();
      _spin.reset();
    }
  }

  @override
  void dispose() {
    widget.repo.removeListener(_update);
    _spin.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return RotationTransition(
      turns: _spin,
      child: IconButton(
        tooltip: 'Sync now',
        icon: const Icon(Icons.sync),
        onPressed: widget.repo.syncing ? null : widget.repo.sync,
      ),
    );
  }
}

class _DraggableSticky extends StatelessWidget {
  const _DraggableSticky({
    super.key,
    required this.note,
    required this.repo,
    required this.isDragged,
    required this.onDragStarted,
    required this.onDragEnd,
    required this.onHover,
  });

  final Note note;
  final NotesRepository repo;
  final bool isDragged;
  final VoidCallback onDragStarted;
  final VoidCallback onDragEnd;
  final VoidCallback onHover;

  @override
  Widget build(BuildContext context) {
    final card = _StickyCard(note: note, repo: repo);
    return DragTarget<String>(
      onWillAcceptWithDetails: (d) => d.data != note.id,
      onAcceptWithDetails: (_) {},
      onMove: (details) {
        final box = context.findRenderObject() as RenderBox?;
        if (box == null) return;
        
        // This is the top-left of the dragged widget
        final globalOffset = details.offset;
        final w = box.size.width;
        final h = box.size.height;
        
        // Center of the dragged widget conservatively (assuming it's roughly same size as target)
        final centerOffset = box.globalToLocal(globalOffset + Offset(w/2, h/2));
        
        // We only trigger reorder if the dragged card's center has entered the central 50% area of the target
        if (centerOffset.dx > w * 0.25 && centerOffset.dx < w * 0.75 &&
            centerOffset.dy > h * 0.25 && centerOffset.dy < h * 0.75) {
          onHover();
        }
      },
      builder: (context, candidate, _) {
        return AnimatedOpacity(
          opacity: isDragged ? 0.3 : 1.0,
          duration: const Duration(milliseconds: 200),
          child: LayoutBuilder(
            builder: (context, constraints) {
              return LongPressDraggable<String>(
                data: note.id,
                onDragStarted: onDragStarted,
                onDragEnd: (_) => onDragEnd(),
                onDraggableCanceled: (_, __) => onDragEnd(),
                onDragCompleted: onDragEnd,
                feedback: Material(
                  color: Colors.transparent,
                  child: Opacity(
                    opacity: 0.9,
                    child: SizedBox(
                      width: constraints.maxWidth,
                      child: Transform.scale(
                        scale: 1.05,
                        child: card,
                      ),
                    ),
                  ),
                ),
                childWhenDragging: const SizedBox.shrink(),
                child: card,
              );
            },
          ),
        );
      },
    );
  }
}

class _StickyCard extends StatelessWidget {
  const _StickyCard({required this.note, required this.repo});

  final Note note;
  final NotesRepository repo;

  @override
  Widget build(BuildContext context) {
    final brightness = Theme.of(context).brightness;
    final bg = stickyColorFor(note.colorValue, brightness);
    final fg = stickyForegroundFor(bg);
    final fgMuted = fg.withValues(alpha: 0.55);
    return Material(
      color: bg,
      elevation: 1.5,
      borderRadius: BorderRadius.circular(8),
      child: InkWell(
        borderRadius: BorderRadius.circular(8),
        onTap: () => Navigator.of(context).push(
          MaterialPageRoute<void>(
            builder: (_) => NoteEditorScreen(repo: repo, note: note),
          ),
        ),
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              if (note.title.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.only(bottom: 6),
                  child: Text(
                    note.title,
                    style: TextStyle(
                      fontWeight: FontWeight.bold,
                      fontSize: 15,
                      color: fg,
                    ),
                  ),
                ),
              Text(
                note.content.isEmpty ? '(empty note)' : note.content,
                style: TextStyle(
                  color: note.content.isEmpty ? fgMuted : fg,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _EmptyState extends StatelessWidget {
  const _EmptyState();
  @override
  Widget build(BuildContext context) => const Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.sticky_note_2_outlined, size: 64, color: Colors.black38),
            SizedBox(height: 12),
            Text('No notes yet — tap + to add one.'),
          ],
        ),
      );
}
