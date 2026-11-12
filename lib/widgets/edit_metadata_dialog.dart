import 'package:flutter/material.dart';

import '../constants.dart';
import '../models/track.dart';
import '../state.dart';
import '../strings.dart';
import 'app_snackbar.dart';

Future<void> showEditMetadataDialog(
  BuildContext context, {
  required Track track,
  required AppState app,
}) {
  return showDialog<void>(
    context: context,
    builder: (ctx) => _EditMetadataDialog(track: track, app: app),
  );
}

class _EditMetadataDialog extends StatefulWidget {
  final Track track;
  final AppState app;

  const _EditMetadataDialog({
    required this.track,
    required this.app,
  });

  @override
  State<_EditMetadataDialog> createState() => _EditMetadataDialogState();
}

class _EditMetadataDialogState extends State<_EditMetadataDialog> {
  late final TextEditingController _titleCtrl;
  late final TextEditingController _artistCtrl;
  late final TextEditingController _albumCtrl;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    _titleCtrl = TextEditingController(text: widget.track.tagTitle.isNotEmpty ? widget.track.tagTitle : widget.track.title);
    _artistCtrl = TextEditingController(text: widget.track.tagArtist.isNotEmpty ? widget.track.tagArtist : widget.track.author);
    _albumCtrl = TextEditingController(text: widget.track.album ?? (widget.track.tagAlbum != widget.track.tagTitle ? widget.track.tagAlbum : ''));
  }

  @override
  void dispose() {
    _titleCtrl.dispose();
    _artistCtrl.dispose();
    _albumCtrl.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final title = _titleCtrl.text.trim();
    final artist = _artistCtrl.text.trim();
    final album = _albumCtrl.text.trim();

    if (title.isEmpty) return;

    setState(() => _saving = true);
    try {
      final r = await widget.app.updateTrackMetadata(
        widget.track,
        newTitle: title,
        newArtist: artist.isEmpty ? 'Unknown Artist' : artist,
        newAlbum: album.isEmpty ? null : album,
      );
      if (mounted) {
        Navigator.pop(context);
        showAppSnackBar(
          context,
          r.retagFailed
              ? tr("Saved in the app, but the file's tags couldn't be updated")
              : tr('Metadata updated'),
        );
      }
    } catch (_) {
      if (mounted) showAppSnackBar(context, tr('Could not save changes'));
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      icon: Icon(Icons.edit_note_rounded, size: 36, color: accent(context)),
      title: Text(tr('Edit metadata')),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: _titleCtrl,
              autofocus: true,
              textCapitalization: TextCapitalization.words,
              decoration: InputDecoration(
                labelText: tr('Title'),
                border: const OutlineInputBorder(),
                prefixIcon: const Icon(Icons.title_rounded),
              ),
            ),
            const SizedBox(height: 14),
            TextField(
              controller: _artistCtrl,
              textCapitalization: TextCapitalization.words,
              decoration: InputDecoration(
                labelText: tr('Artist'),
                border: const OutlineInputBorder(),
                prefixIcon: const Icon(Icons.person_rounded),
              ),
            ),
            const SizedBox(height: 14),
            TextField(
              controller: _albumCtrl,
              textCapitalization: TextCapitalization.words,
              decoration: InputDecoration(
                labelText: tr('Album'),
                border: const OutlineInputBorder(),
                prefixIcon: const Icon(Icons.album_rounded),
              ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: _saving ? null : () => Navigator.pop(context),
          child: Text(tr('Cancel')),
        ),
        FilledButton(
          onPressed: _saving ? null : _save,
          child: _saving
              ? const SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
                )
              : Text(tr('Save')),
        ),
      ],
    );
  }
}
