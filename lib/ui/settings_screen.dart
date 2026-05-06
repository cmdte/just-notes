import 'package:flutter/material.dart';

import '../repository/notes_repository.dart';
import '../settings/app_settings.dart';
import '../sync/backend_config.dart';
import '../sync/google_drive_backend.dart';
import 'backend_picker_screen.dart';
import 'unlock_screen.dart';

class SettingsScreen extends StatelessWidget {
  const SettingsScreen({
    super.key,
    required this.repo,
    required this.settings,
  });

  final NotesRepository repo;
  final AppSettings settings;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Settings')),
      body: AnimatedBuilder(
        animation: Listenable.merge([repo, settings]),
        builder: (context, _) {
          return ListView(
            children: [
              const _SectionHeader('Appearance'),
              ListTile(
                leading: const Icon(Icons.brightness_6_outlined),
                title: const Text('Theme'),
                subtitle: Text(_themeLabel(settings.themeMode)),
                onTap: () => _pickTheme(context),
              ),
              const Divider(height: 1),
              const _SectionHeader('Sync'),
              ListTile(
                leading: const Icon(Icons.cloud_outlined),
                title: const Text('Backend'),
                subtitle: Text(repo.backendConfig.label),
                onTap: () => Navigator.of(context).push(
                  MaterialPageRoute<void>(
                    builder: (_) => BackendPickerScreen(repo: repo),
                  ),
                ),
              ),
              ListTile(
                leading: repo.syncing
                    ? const SizedBox(
                        width: 20,
                        height: 20,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.cloud_done_outlined),
                title: const Text('Sync status'),
                subtitle: Text(_syncSubtitle(repo)),
              ),
              const Padding(
                padding: EdgeInsets.fromLTRB(16, 0, 16, 8),
                child: Text(
                  'Pull down on the notes board to sync.',
                  style: TextStyle(fontSize: 12, color: Colors.grey),
                ),
              ),
              if (repo.backendConfig.kind != BackendKind.stub)
                ListTile(
                  leading: const Icon(Icons.logout),
                  title: const Text('Disconnect sync'),
                  subtitle: const Text(
                    'Removes cloud credentials. Notes stay on device.',
                  ),
                  onTap: () => _disconnectBackend(context),
                ),
              const Divider(height: 1),
              const _SectionHeader('Security'),
              ListTile(
                leading: const Icon(Icons.password_outlined),
                title: const Text('Change passphrase'),
                subtitle: const Text(
                  'Re-encrypts your vault with a new passphrase.',
                ),
                onTap: () => _changePassphrase(context),
              ),
              ListTile(
                leading: const Icon(Icons.lock_outline),
                title: const Text('Lock vault'),
                subtitle: const Text(
                  'Forget the saved passphrase on this device. '
                  'You\u2019ll be asked for it the next time you open the app.',
                ),
                onTap: () => _confirmLock(context),
              ),
              const SizedBox(height: 16),
              const Padding(
                padding: EdgeInsets.symmetric(horizontal: 16),
                child: Text(
                  'Notes are encrypted on-device with AES-256-GCM. The '
                  'passphrase never leaves your device; only ciphertext is '
                  'synced.',
                  style: TextStyle(fontSize: 12, color: Colors.grey),
                ),
              ),
            ],
          );
        },
      ),
    );
  }

  static String _themeLabel(ThemeMode m) => switch (m) {
        ThemeMode.system => 'Follow system',
        ThemeMode.light => 'Light',
        ThemeMode.dark => 'Dark',
      };

  static String _syncSubtitle(NotesRepository repo) {
    if (repo.syncing) return 'Syncing…';
    if (repo.lastSyncError != null) {
      return 'Last attempt failed: ${repo.lastSyncError}';
    }
    final last = repo.lastSync;
    if (last == null) return 'Not synced yet on this device.';
    return 'Last synced ${_relative(last)}.';
  }

  static String _relative(DateTime t) {
    final d = DateTime.now().difference(t);
    if (d.inSeconds < 60) return 'just now';
    if (d.inMinutes < 60) return '${d.inMinutes} min ago';
    if (d.inHours < 24) return '${d.inHours} h ago';
    return '${d.inDays} d ago';
  }

  Future<void> _pickTheme(BuildContext context) async {
    final picked = await showDialog<ThemeMode>(
      context: context,
      builder: (ctx) => SimpleDialog(
        title: const Text('Theme'),
        children: [
          for (final m in ThemeMode.values)
            RadioListTile<ThemeMode>(
              value: m,
              groupValue: settings.themeMode,
              onChanged: (v) => Navigator.pop(ctx, v),
              title: Text(_themeLabel(m)),
            ),
        ],
      ),
    );
    if (picked != null) await settings.setThemeMode(picked);
  }

  Future<void> _confirmLock(BuildContext context) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Lock vault?'),
        content: const Text(
          'You will need your passphrase to open the app again. '
          'Your encrypted notes are not deleted.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          FilledButton.tonal(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Lock'),
          ),
        ],
      ),
    );
    if (ok != true || !context.mounted) return;
    await NotesRepository.forgetPassphrase();
    if (!context.mounted) return;
    Navigator.of(context).pushAndRemoveUntil(
      MaterialPageRoute<void>(
        builder: (_) => UnlockScreen(settings: settings),
      ),
      (_) => false,
    );
  }

  Future<void> _changePassphrase(BuildContext context) async {
    final result = await showDialog<({String oldPass, String newPass})>(
      context: context,
      builder: (_) => const _ChangePassphraseDialog(),
    );
    if (result == null || !context.mounted) return;

    // Show a blocking progress dialog while we re-encrypt + push.
    showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (_) => const Center(child: CircularProgressIndicator()),
    );
    final error = await repo.changePassphrase(
      oldPass: result.oldPass,
      newPass: result.newPass,
    );
    if (!context.mounted) return;
    Navigator.of(context).pop(); // dismiss progress

    final messenger = ScaffoldMessenger.of(context);
    messenger.showSnackBar(
      SnackBar(
        content: Text(error ?? 'Passphrase changed.'),
        backgroundColor: error == null ? null : Colors.red,
      ),
    );
  }

  Future<void> _disconnectBackend(BuildContext context) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Disconnect sync?'),
        content: const Text(
          'Cloud credentials will be removed. '
          'Your notes stay encrypted on this device.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          FilledButton.tonal(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Disconnect'),
          ),
        ],
      ),
    );
    if (ok != true || !context.mounted) return;
    if (repo.backendConfig.kind == BackendKind.googleDrive) {
      await GoogleDriveBackend.signOut();
    }
    await repo.setBackend(const BackendConfig(kind: BackendKind.stub));
    if (!context.mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Sync disconnected.')),
    );
  }
}

class _ChangePassphraseDialog extends StatefulWidget {
  const _ChangePassphraseDialog();

  @override
  State<_ChangePassphraseDialog> createState() =>
      _ChangePassphraseDialogState();
}

class _ChangePassphraseDialogState extends State<_ChangePassphraseDialog> {
  final _oldCtrl = TextEditingController();
  final _newCtrl = TextEditingController();
  final _confirmCtrl = TextEditingController();
  bool _obscure = true;
  String? _error;

  @override
  void dispose() {
    _oldCtrl.dispose();
    _newCtrl.dispose();
    _confirmCtrl.dispose();
    super.dispose();
  }

  void _submit() {
    final oldPass = _oldCtrl.text;
    final newPass = _newCtrl.text;
    final confirm = _confirmCtrl.text;
    if (oldPass.isEmpty) {
      setState(() => _error = 'Enter your current passphrase.');
      return;
    }
    if (newPass.length < 8) {
      setState(() => _error = 'New passphrase must be at least 8 characters.');
      return;
    }
    if (newPass != confirm) {
      setState(() => _error = 'New passphrases do not match.');
      return;
    }
    if (newPass == oldPass) {
      setState(() => _error = 'New passphrase must be different.');
      return;
    }
    Navigator.pop(context, (oldPass: oldPass, newPass: newPass));
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Change passphrase'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          TextField(
            controller: _oldCtrl,
            obscureText: _obscure,
            decoration: const InputDecoration(
              labelText: 'Current passphrase',
            ),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _newCtrl,
            obscureText: _obscure,
            decoration: const InputDecoration(labelText: 'New passphrase'),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _confirmCtrl,
            obscureText: _obscure,
            onSubmitted: (_) => _submit(),
            decoration: const InputDecoration(
              labelText: 'Confirm new passphrase',
            ),
          ),
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton.icon(
              onPressed: () => setState(() => _obscure = !_obscure),
              icon: Icon(
                _obscure ? Icons.visibility_outlined : Icons.visibility_off_outlined,
              ),
              label: Text(_obscure ? 'Show' : 'Hide'),
            ),
          ),
          if (_error != null)
            Text(
              _error!,
              style: const TextStyle(color: Colors.red, fontSize: 12),
            ),
          const SizedBox(height: 8),
          const Text(
            'All notes will be re-encrypted and pushed to the cloud. Other '
            'devices will pick up the new passphrase on their next sync.',
            style: TextStyle(fontSize: 12, color: Colors.grey),
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        FilledButton(onPressed: _submit, child: const Text('Change')),
      ],
    );
  }
}

class _SectionHeader extends StatelessWidget {
  const _SectionHeader(this.text);
  final String text;
  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
      child: Text(
        text,
        style: TextStyle(
          fontSize: 12,
          fontWeight: FontWeight.w600,
          color: Theme.of(context).colorScheme.primary,
          letterSpacing: 0.5,
        ),
      ),
    );
  }
}
