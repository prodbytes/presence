import 'dart:io';

/// Recordings are files here: a live recording's file (until it's saved,
/// sealed) and an opened copy of a sealed one (while it plays or is
/// searched) are tracked like the web's in-memory URLs, and deleted once
/// nothing needs them, so no recording stays on disk unsealed.
const bool hasMediaUrls = true;

void revokeMediaUrl(String url) {
  File(url).delete().then<void>((_) {}, onError: (Object _) {});
}
