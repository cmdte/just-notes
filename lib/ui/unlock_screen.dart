import 'package:flutter/material.dart';

import '../repository/notes_repository.dart';
import '../settings/app_settings.dart';
import 'board_screen.dart';

class UnlockScreen extends StatefulWidget {
  const UnlockScreen({super.key, required this.settings});

  final AppSettings settings;

  @override
  State<UnlockScreen> createState() => _UnlockScreenState();
}

class _UnlockScreenState extends State<UnlockScreen> {
  final _ctrl = TextEditingController();
  bool _busy = true;
  bool _initializing = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _attemptAutoUnlock();
  }

  Future<void> _attemptAutoUnlock() async {
    final result = await NotesRepository.tryAutoUnlock();
    if (!mounted) return;
    if (result?.repo != null) {
      _goToBoard(result!.repo!);
      return;
    }
    setState(() {
      _busy = false;
      _initializing = false;
    });
  }

  Future<void> _unlock() async {
    if (_ctrl.text.isEmpty) {
      setState(() => _error = 'Enter a passphrase.');
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    final result =
        await NotesRepository.unlock(_ctrl.text, remember: true);
    if (!mounted) return;
    if (result.repo == null) {
      setState(() {
        _busy = false;
        _error = result.error;
      });
      return;
    }
    _goToBoard(result.repo!);
  }

  void _goToBoard(NotesRepository repo) {
    Navigator.of(context).pushReplacement(
      MaterialPageRoute<void>(
        builder: (_) => BoardScreen(repo: repo, settings: widget.settings),
      ),
    );
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 360),
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: _initializing
                ? const CircularProgressIndicator()
                : Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Icon(Icons.lock_outline, size: 56),
                      const SizedBox(height: 16),
                      const Text(
                        'Unlock your notes',
                        style: TextStyle(
                          fontSize: 20,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      const SizedBox(height: 8),
                      const Text(
                        'First time? Pick a strong passphrase — it encrypts '
                        'every note end-to-end. Lose it and your data is '
                        'unrecoverable.',
                        textAlign: TextAlign.center,
                        style: TextStyle(fontSize: 13),
                      ),
                      const SizedBox(height: 24),
                      TextField(
                        controller: _ctrl,
                        obscureText: true,
                        autofocus: true,
                        onSubmitted: (_) => _unlock(),
                        decoration: InputDecoration(
                          labelText: 'Passphrase',
                          border: const OutlineInputBorder(),
                          errorText: _error,
                        ),
                      ),
                      const SizedBox(height: 16),
                      SizedBox(
                        width: double.infinity,
                        child: FilledButton(
                          onPressed: _busy ? null : _unlock,
                          child: _busy
                              ? const SizedBox(
                                  width: 20,
                                  height: 20,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2,
                                  ),
                                )
                              : const Text('Unlock'),
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
