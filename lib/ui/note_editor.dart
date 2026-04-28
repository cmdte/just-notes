import 'package:flutter/material.dart';

import '../models/note.dart';
import '../repository/notes_repository.dart';

class NoteEditorScreen extends StatefulWidget {
  const NoteEditorScreen({super.key, required this.repo, required this.note});

  final NotesRepository repo;
  final Note note;

  @override
  State<NoteEditorScreen> createState() => _NoteEditorScreenState();
}

class _NoteEditorScreenState extends State<NoteEditorScreen> {
  late final TextEditingController _titleCtrl;
  late final TextEditingController _bodyCtrl;
  late int _color;
  bool _deleted = false;

  @override
  void initState() {
    super.initState();
    _titleCtrl = TextEditingController(text: widget.note.title);
    _bodyCtrl = TextEditingController(text: widget.note.content);
    _color = widget.note.colorValue;
  }

  @override
  void dispose() {
    _titleCtrl.dispose();
    _bodyCtrl.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    if (_deleted) return;
    final title = _titleCtrl.text.trim();
    final body = _bodyCtrl.text.trim();
    // If the note is completely empty, drop it entirely instead of
    // persisting an empty placeholder. This is the natural "cancel" for a
    // freshly-created note that the user backed out of.
    if (title.isEmpty && body.isEmpty) {
      await widget.repo.delete(widget.note.id);
      return;
    }
    widget.note
      ..title = title
      ..content = _bodyCtrl.text
      ..colorValue = _color;
    await widget.repo.update(widget.note);
  }

  Future<void> _confirmDelete() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Delete note?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          FilledButton.tonal(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    _deleted = true;
    await widget.repo.delete(widget.note.id);
    if (mounted) Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final brightness = Theme.of(context).brightness;
    final bg = stickyColorFor(_color, brightness);
    final fg = stickyForegroundFor(bg);
    final hint = fg.withValues(alpha: 0.55);
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) async {
        if (didPop) return;
        await _save();
        if (mounted) Navigator.of(context).pop();
      },
      child: Scaffold(
        backgroundColor: bg,
        appBar: AppBar(
          backgroundColor: bg,
          elevation: 0,
          iconTheme: IconThemeData(color: fg),
          actions: [
            IconButton(
              tooltip: 'Delete',
              icon: Icon(Icons.delete_outline, color: fg),
              onPressed: _confirmDelete,
            ),
          ],
        ),
        body: SafeArea(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                TextField(
                  controller: _titleCtrl,
                  cursorColor: fg,
                  style: TextStyle(
                    fontSize: 20,
                    fontWeight: FontWeight.bold,
                    color: fg,
                  ),
                  decoration: InputDecoration(
                    hintText: 'Title',
                    hintStyle: TextStyle(color: hint),
                    border: InputBorder.none,
                  ),
                ),
                const SizedBox(height: 8),
                Expanded(
                  child: TextField(
                    controller: _bodyCtrl,
                    maxLines: null,
                    expands: true,
                    cursorColor: fg,
                    textAlignVertical: TextAlignVertical.top,
                    style: TextStyle(color: fg),
                    decoration: InputDecoration(
                      hintText: 'Take a note…',
                      hintStyle: TextStyle(color: hint),
                      border: InputBorder.none,
                    ),
                  ),
                ),
                _ColorPicker(
                  selected: _color,
                  brightness: brightness,
                  onChanged: (c) => setState(() => _color = c),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _ColorPicker extends StatelessWidget {
  const _ColorPicker({
    required this.selected,
    required this.brightness,
    required this.onChanged,
  });

  final int selected;
  final Brightness brightness;
  final ValueChanged<int> onChanged;

  @override
  Widget build(BuildContext context) {
    final borderSel = brightness == Brightness.light
        ? Colors.black87
        : Colors.white;
    final borderUnsel = brightness == Brightness.light
        ? Colors.black26
        : Colors.white24;
    return SizedBox(
      height: 48,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        itemCount: stickyPalette.length,
        separatorBuilder: (_, __) => const SizedBox(width: 8),
        itemBuilder: (context, i) {
          final c = stickyPalette[i];
          final isSel = c == selected;
          return GestureDetector(
            onTap: () => onChanged(c),
            child: Container(
              width: 36,
              height: 36,
              decoration: BoxDecoration(
                color: stickyColorFor(c, brightness),
                shape: BoxShape.circle,
                border: Border.all(
                  color: isSel ? borderSel : borderUnsel,
                  width: isSel ? 2.5 : 1,
                ),
              ),
            ),
          );
        },
      ),
    );
  }
}
