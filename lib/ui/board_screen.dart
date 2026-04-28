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
                : Padding(
                    padding: const EdgeInsets.all(8),
                    child: MasonryGridView.count(
                      physics: const AlwaysScrollableScrollPhysics(),
                      crossAxisCount: _columnsFor(context),
                      mainAxisSpacing: 8,
                      crossAxisSpacing: 8,
                      itemCount: notes.length,
                      itemBuilder: (context, i) => _DraggableSticky(
                        key: ValueKey(notes[i].id),
                        note: notes[i],
                        repo: repo,
                      ),
                    ),
                  ),
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

class _DraggableSticky extends StatelessWidget {
  const _DraggableSticky({
    super.key,
    required this.note,
    required this.repo,
  });

  final Note note;
  final NotesRepository repo;

  @override
  Widget build(BuildContext context) {
    final card = _StickyCard(note: note, repo: repo);
    return DragTarget<String>(
      onWillAcceptWithDetails: (d) => d.data != note.id,
      onAcceptWithDetails: (d) => repo.reorder(d.data, note.id),
      builder: (context, candidate, _) {
        final highlighted = candidate.isNotEmpty;
        return AnimatedContainer(
          duration: const Duration(milliseconds: 120),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(10),
            border: Border.all(
              color: highlighted
                  ? Theme.of(context).colorScheme.primary
                  : Colors.transparent,
              width: 2,
            ),
          ),
          // LayoutBuilder so the drag feedback matches the card's actual
          // rendered width — otherwise it snaps to a default size mid-drag.
          child: LayoutBuilder(
            builder: (context, constraints) {
              return LongPressDraggable<String>(
                data: note.id,
                feedback: Material(
                  color: Colors.transparent,
                  child: Opacity(
                    opacity: 0.9,
                    child: SizedBox(
                      width: constraints.maxWidth,
                      child: card,
                    ),
                  ),
                ),
                childWhenDragging: Opacity(opacity: 0.3, child: card),
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
