import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';

import '../repository/notes_repository.dart';
import '../sync/backend_config.dart';
import '../sync/folder_backend.dart';
import '../sync/google_drive_backend.dart';
import '../sync/webdav_backend.dart';

class BackendPickerScreen extends StatefulWidget {
  const BackendPickerScreen({super.key, required this.repo});
  final NotesRepository repo;

  @override
  State<BackendPickerScreen> createState() => _BackendPickerScreenState();
}

class _BackendPickerScreenState extends State<BackendPickerScreen> {
  bool _busy = false;
  String? _error;

  @override
  Widget build(BuildContext context) {
    final cfg = widget.repo.backendConfig;
    return Scaffold(
      appBar: AppBar(title: const Text('Sync backend')),
      body: ListView(
        children: [
          if (_error != null)
            Padding(
              padding: const EdgeInsets.all(16),
              child: Text(
                _error!,
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
            ),
          RadioListTile<BackendKind>(
            value: BackendKind.googleDrive,
            groupValue: cfg.kind,
            onChanged: _busy ? null : (_) => _selectGoogleDrive(),
            title: const Text('Google Drive'),
            subtitle: const Text(
              'Encrypted notes are stored in your own Drive\u2019s hidden '
              'app folder. Free, multi-device.',
            ),
          ),
          RadioListTile<BackendKind>(
            value: BackendKind.webdav,
            groupValue: cfg.kind,
            onChanged: _busy ? null : (_) => _selectWebdav(),
            title: const Text('WebDAV'),
            subtitle: const Text(
              'Nextcloud, ownCloud, or any WebDAV server. You provide URL '
              '+ credentials.',
            ),
          ),
          RadioListTile<BackendKind>(
            value: BackendKind.folder,
            groupValue: cfg.kind,
            onChanged: _busy ? null : (_) => _selectFolder(),
            title: const Text('Local folder'),
            subtitle: const Text(
              'Encrypted notes are written to a folder on this device. '
              'Use Syncthing, Dropbox, iCloud Drive or any other tool to '
              'sync that folder between devices.',
            ),
          ),
          if (_busy)
            const Padding(
              padding: EdgeInsets.all(24),
              child: Center(child: CircularProgressIndicator()),
            ),
        ],
      ),
    );
  }

  Future<void> _selectGoogleDrive() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final backend = await GoogleDriveBackend.connect();
      if (backend == null) {
        setState(() {
          _busy = false;
          _error = 'Sign-in cancelled.';
        });
        return;
      }
      final res = await widget.repo
          .setBackend(const BackendConfig(kind: BackendKind.googleDrive));
      if (!mounted) return;
      setState(() {
        _busy = false;
        _error = res.ok ? null : res.error;
      });
    } catch (e) {
      setState(() {
        _busy = false;
        _error = 'Google sign-in failed: $e';
      });
    }
  }

  Future<void> _selectWebdav() async {
    final cfg = widget.repo.backendConfig;
    final result = await showDialog<BackendConfig>(
      context: context,
      builder: (ctx) => _WebdavDialog(
        initialUrl: cfg.webdavUrl,
        initialUser: cfg.webdavUser,
        initialPassword: cfg.webdavPassword,
      ),
    );
    if (result == null || !mounted) return;

    setState(() {
      _busy = true;
      _error = null;
    });
    final test = await WebDavBackend.testConnection(
      url: result.webdavUrl!,
      username: result.webdavUser!,
      password: result.webdavPassword!,
    );
    if (!test.ok) {
      setState(() {
        _busy = false;
        _error = 'Could not reach WebDAV server: ${test.error}';
      });
      return;
    }
    final res = await widget.repo.setBackend(result);
    if (!mounted) return;
    setState(() {
      _busy = false;
      _error = res.ok ? null : res.error;
    });
  }

  Future<void> _selectFolder() async {
    final cfg = widget.repo.backendConfig;
    final suggested = (await getExternalStorageDirectory())?.path;
    if (!mounted) return;
    final result = await showDialog<BackendConfig>(
      context: context,
      builder: (_) => _FolderDialog(
        initialPath: cfg.folderPath ??
            (suggested == null ? null : '$suggested/notes_vault'),
        suggestion: suggested == null ? null : '$suggested/notes_vault',
      ),
    );
    if (result == null || !mounted) return;

    setState(() {
      _busy = true;
      _error = null;
    });
    final probeError = await FolderBackend.probe(result.folderPath!);
    if (probeError != null) {
      setState(() {
        _busy = false;
        _error = 'Cannot write to that folder: $probeError';
      });
      return;
    }
    final res = await widget.repo.setBackend(result);
    if (!mounted) return;
    setState(() {
      _busy = false;
      _error = res.ok ? null : res.error;
    });
  }
}

class _WebdavDialog extends StatefulWidget {
  const _WebdavDialog({
    this.initialUrl,
    this.initialUser,
    this.initialPassword,
  });
  final String? initialUrl;
  final String? initialUser;
  final String? initialPassword;

  @override
  State<_WebdavDialog> createState() => _WebdavDialogState();
}

class _WebdavDialogState extends State<_WebdavDialog> {
  late final TextEditingController _url;
  late final TextEditingController _user;
  late final TextEditingController _pass;

  @override
  void initState() {
    super.initState();
    _url = TextEditingController(text: widget.initialUrl ?? '');
    _user = TextEditingController(text: widget.initialUser ?? '');
    _pass = TextEditingController(text: widget.initialPassword ?? '');
  }

  @override
  void dispose() {
    _url.dispose();
    _user.dispose();
    _pass.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('WebDAV settings'),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: _url,
              decoration: const InputDecoration(
                labelText: 'URL',
                hintText: 'https://cloud.example.com/remote.php/dav/files/me/Notes',
              ),
              keyboardType: TextInputType.url,
            ),
            const SizedBox(height: 8),
            TextField(
              controller: _user,
              decoration: const InputDecoration(labelText: 'Username'),
            ),
            const SizedBox(height: 8),
            TextField(
              controller: _pass,
              decoration: const InputDecoration(labelText: 'Password'),
              obscureText: true,
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: () {
            if (_url.text.isEmpty ||
                _user.text.isEmpty ||
                _pass.text.isEmpty) {
              return;
            }
            Navigator.pop(
              context,
              BackendConfig(
                kind: BackendKind.webdav,
                webdavUrl: _url.text.trim(),
                webdavUser: _user.text.trim(),
                webdavPassword: _pass.text,
              ),
            );
          },
          child: const Text('Save'),
        ),
      ],
    );
  }
}

class _FolderDialog extends StatefulWidget {
  const _FolderDialog({this.initialPath, this.suggestion});
  final String? initialPath;
  final String? suggestion;

  @override
  State<_FolderDialog> createState() => _FolderDialogState();
}

class _FolderDialogState extends State<_FolderDialog> {
  late final TextEditingController _path;

  @override
  void initState() {
    super.initState();
    _path = TextEditingController(text: widget.initialPath ?? '');
  }

  @override
  void dispose() {
    _path.dispose();
    super.dispose();
  }

  Future<void> _pickFolder() async {
    final picked = await FilePicker.platform.getDirectoryPath(
      dialogTitle: 'Choose vault folder',
      initialDirectory: _path.text.isNotEmpty ? _path.text : null,
    );
    if (picked != null && mounted) {
      setState(() => _path.text = picked);
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Local folder'),
      content: SingleChildScrollView(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: _path,
              decoration: InputDecoration(
                labelText: 'Folder path',
                hintText: '/storage/emulated/0/…/notes_vault',
                suffixIcon: IconButton(
                  tooltip: 'Browse',
                  icon: const Icon(Icons.folder_open),
                  onPressed: _pickFolder,
                ),
              ),
            ),
            if (widget.suggestion != null) ...[
              const SizedBox(height: 8),
              Align(
                alignment: Alignment.centerLeft,
                child: TextButton(
                  onPressed: () =>
                      setState(() => _path.text = widget.suggestion!),
                  child: const Text('Use app external storage'),
                ),
              ),
            ],
            const SizedBox(height: 8),
            const Text(
              'Each note will be saved as an encrypted JSON file in this '
              'folder. Point Syncthing (or any sync tool) at the same path '
              'on every device to keep them in sync.',
              style: TextStyle(fontSize: 12, color: Colors.grey),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: () {
            final p = _path.text.trim();
            if (p.isEmpty) return;
            Navigator.pop(
              context,
              BackendConfig(kind: BackendKind.folder, folderPath: p),
            );
          },
          child: const Text('Save'),
        ),
      ],
    );
  }
}
