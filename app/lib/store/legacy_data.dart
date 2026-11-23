import 'dart:io';

import 'package:flutter/foundation.dart';

/// One-time move of the data left by the app's former name (DisplAI, bundle id
/// com.kidandcat.displai) into [dataDir]: database, skills, models, brain and worker dirs, and
/// the brain's Claude Code conversations, so memories and the ongoing session survive the rename.
/// Does nothing when [dataDir] already has a database or there is no old data.
Future<void> migrateLegacyData(String dataDir) async {
  try {
    final newDir = Directory(dataDir);
    if (File('$dataDir/minerva.db').existsSync()) return;
    final oldDir = Directory('${newDir.parent.path}/com.kidandcat.displai');
    if (!oldDir.existsSync() || !File('${oldDir.path}/displai.db').existsSync()) return;

    if (newDir.existsSync()) {
      // Empty folder created by an earlier start: move the old contents in one by one.
      for (final e in oldDir.listSync()) {
        final target = '$dataDir/${e.uri.pathSegments.where((s) => s.isNotEmpty).last}';
        if (FileSystemEntity.typeSync(target) == FileSystemEntityType.notFound) e.renameSync(target);
      }
      if (oldDir.listSync().isEmpty) oldDir.deleteSync();
    } else {
      oldDir.renameSync(dataDir);
    }
    for (final suffix in ['', '-wal', '-shm']) {
      final f = File('$dataDir/displai.db$suffix');
      if (f.existsSync()) f.renameSync('$dataDir/minerva.db$suffix');
    }

    // Claude Code keeps each conversation under a folder named after its working directory.
    final projects = '${Platform.environment['HOME']}/.claude/projects';
    for (final sub in ['brain', 'workers']) {
      final from = Directory('$projects/${_projectKey('${oldDir.path}/$sub')}');
      final to = '$projects/${_projectKey('$dataDir/$sub')}';
      if (from.existsSync() && !Directory(to).existsSync()) from.renameSync(to);
    }
    debugPrint('migrated data from ${oldDir.path}');
  } catch (e) {
    debugPrint('legacy data migration failed: $e');
  }
}

/// Claude Code's project folder name for a working directory.
String _projectKey(String path) => path.replaceAll(RegExp(r'[^A-Za-z0-9]'), '-');
