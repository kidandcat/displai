/// Video playback (video_player, AVPlayer on macOS) for direct video files.
library;

import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:video_player/video_player.dart';

import 'theme.dart';

/// True for page URLs that video_player cannot play (YouTube, Vimeo, ...).
bool isUnsupportedVideoPage(String url) {
  final Uri? uri = Uri.tryParse(url.trim());
  if (uri == null) return true;
  final String host = uri.host.toLowerCase();
  const pageHosts = [
    'youtube.com',
    'youtu.be',
    'vimeo.com',
    'tiktok.com',
    'instagram.com',
    'twitch.tv',
    'dailymotion.com',
    'facebook.com',
    'x.com',
    'twitter.com',
  ];
  return pageHosts.any((h) => host == h || host.endsWith('.$h'));
}

/// True if [url] has a scheme video_player can open.
bool isPlayableVideoUrl(String url) {
  final String u = url.trim();
  return u.startsWith('https://') ||
      u.startsWith('http://') ||
      u.startsWith('file://') ||
      u.startsWith('/');
}

class DisplayVideo extends StatefulWidget {
  const DisplayVideo({
    super.key,
    required this.componentId,
    required this.url,
    this.caption,
    this.loop = false,
    this.full = false,
  });

  final String componentId;
  final String url;
  final String? caption;
  final bool loop;
  final bool full;

  @override
  State<DisplayVideo> createState() => _DisplayVideoState();
}

class _DisplayVideoState extends State<DisplayVideo> {
  VideoPlayerController? _controller;
  String? _error;
  DisplayRuntime? _runtime;
  int _lastCommand = -1;
  bool _wasPlaying = false;
  DateTime _lastReport = DateTime(0);

  @override
  void initState() {
    super.initState();
    _open();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final DisplayRuntime? runtime = DisplayScope.maybeOf(context);
    if (runtime != _runtime) {
      _runtime?.videoCommands.removeListener(_onCommand);
      _runtime = runtime;
      _lastCommand = runtime?.videoCommands.value?.seq ?? -1;
      runtime?.videoCommands.addListener(_onCommand);
    }
  }

  @override
  void didUpdateWidget(DisplayVideo oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.url != widget.url) {
      _close();
      _open();
    } else if (oldWidget.loop != widget.loop) {
      _controller?.setLooping(widget.loop);
    }
  }

  @override
  void dispose() {
    _runtime?.videoCommands.removeListener(_onCommand);
    _close();
    super.dispose();
  }

  void _open() {
    final String url = widget.url.trim();
    if (!isPlayableVideoUrl(url) || isUnsupportedVideoPage(url)) {
      _error = DisplayStrings.videoError;
      return;
    }
    final VideoPlayerController c;
    try {
      c = url.startsWith('http')
          ? VideoPlayerController.networkUrl(Uri.parse(url))
          : VideoPlayerController.file(
              File(
                url.startsWith('file://') ? Uri.parse(url).toFilePath() : url,
              ),
            );
    } catch (e) {
      _error = '$e';
      return;
    }
    _controller = c;
    _error = null;
    c.addListener(_onValue);
    unawaited(_init(c));
  }

  Future<void> _init(VideoPlayerController c) async {
    try {
      await c.initialize();
      await c.setLooping(widget.loop);
      if (!mounted || _controller != c) return;
      await c.play();
      if (mounted) setState(() {});
    } catch (e) {
      if (!mounted || _controller != c) return;
      setState(() => _error = DisplayStrings.videoError);
      _report(force: true, error: '$e');
    }
  }

  void _close() {
    final VideoPlayerController? c = _controller;
    _controller = null;
    if (c != null) {
      c.removeListener(_onValue);
      unawaited(c.dispose().catchError((Object _) {}));
    }
  }

  void _onValue() {
    final VideoPlayerController? c = _controller;
    if (c == null) return;
    final bool playing = c.value.isPlaying;
    if (playing != _wasPlaying) {
      _wasPlaying = playing;
      if (mounted) setState(() {});
      _report(force: true);
    } else {
      _report();
    }
  }

  void _report({bool force = false, String? error}) {
    final DateTime now = DateTime.now();
    if (!force && now.difference(_lastReport).inMilliseconds < 500) return;
    _lastReport = now;
    final VideoPlayerValue? v = _controller?.value;
    _runtime?.reportVideo(
      widget.componentId,
      VideoStatus(
        playing: v?.isPlaying ?? false,
        position: v?.position ?? Duration.zero,
        duration: v?.duration ?? Duration.zero,
        error: error ?? v?.errorDescription,
      ),
    );
  }

  void _onCommand() {
    final VideoCommand? cmd = _runtime?.videoCommands.value;
    final VideoPlayerController? c = _controller;
    if (cmd == null || cmd.seq == _lastCommand) return;
    _lastCommand = cmd.seq;
    if (c == null || !c.value.isInitialized) return;
    if (cmd.seekSeconds != null) {
      c.seekTo(Duration(milliseconds: (cmd.seekSeconds! * 1000).round()));
    }
    if (cmd.play == true) c.play();
    if (cmd.play == false) c.pause();
  }

  void _toggle() {
    final VideoPlayerController? c = _controller;
    if (c == null || !c.value.isInitialized) return;
    c.value.isPlaying ? c.pause() : c.play();
  }

  @override
  Widget build(BuildContext context) {
    final double s = DisplayScale.of(context);
    final VideoPlayerController? c = _controller;
    final bool ready = c != null && c.value.isInitialized;
    final double aspect = ready && c.value.aspectRatio > 0
        ? c.value.aspectRatio
        : 16 / 9;

    Widget stage;
    if (_error != null) {
      stage = _ErrorPane(message: _error!, url: widget.url);
    } else if (!ready) {
      stage = const Center(
        child: CircularProgressIndicator(color: DisplayColors.accent),
      );
    } else {
      stage = GestureDetector(
        onTap: _toggle,
        child: Stack(
          fit: StackFit.expand,
          children: [
            Center(
              child: AspectRatio(aspectRatio: aspect, child: VideoPlayer(c)),
            ),
            if (!c.value.isPlaying)
              Center(
                child: Icon(
                  Icons.play_circle_outline_rounded,
                  size: 110 * s,
                  color: DisplayColors.accent.withValues(alpha: 0.85),
                ),
              ),
            Positioned(
              left: 24 * s,
              right: 24 * s,
              bottom: 18 * s,
              child: _Controls(controller: c, onToggle: _toggle),
            ),
          ],
        ),
      );
    }

    if (widget.full) {
      return Container(
        color: Colors.black,
        child: Stack(
          fit: StackFit.expand,
          children: [
            stage,
            if (widget.caption != null)
              Positioned(
                left: 32 * s,
                top: 24 * s,
                child: Text(
                  widget.caption!,
                  style: DisplayText(s).subtitle.copyWith(
                    color: DisplayColors.text,
                    shadows: const [Shadow(blurRadius: 12)],
                  ),
                ),
              ),
          ],
        ),
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        ClipRRect(
          borderRadius: BorderRadius.circular(18 * s),
          child: ColoredBox(
            color: Colors.black,
            child: AspectRatio(aspectRatio: aspect, child: stage),
          ),
        ),
        if (widget.caption != null) ...[
          SizedBox(height: 10 * s),
          Text(widget.caption!, style: DisplayText(s).bodyMuted),
        ],
      ],
    );
  }
}

class _Controls extends StatelessWidget {
  const _Controls({required this.controller, required this.onToggle});

  final VideoPlayerController controller;
  final VoidCallback onToggle;

  static String _fmt(Duration d) {
    final int m = d.inMinutes;
    final String sec = (d.inSeconds % 60).toString().padLeft(2, '0');
    return '$m:$sec';
  }

  @override
  Widget build(BuildContext context) {
    final double s = DisplayScale.of(context);
    final VideoPlayerValue v = controller.value;
    return Row(
      children: [
        IconButton(
          onPressed: onToggle,
          iconSize: 34 * s,
          color: DisplayColors.text,
          icon: Icon(
            v.isPlaying ? Icons.pause_rounded : Icons.play_arrow_rounded,
          ),
        ),
        SizedBox(width: 8 * s),
        Expanded(
          child: ClipRRect(
            borderRadius: BorderRadius.circular(4 * s),
            child: VideoProgressIndicator(
              controller,
              allowScrubbing: true,
              padding: EdgeInsets.symmetric(vertical: 8 * s),
              colors: const VideoProgressColors(
                playedColor: DisplayColors.accent,
                bufferedColor: Color(0x55A78BFA),
                backgroundColor: Color(0x33FFFFFF),
              ),
            ),
          ),
        ),
        SizedBox(width: 16 * s),
        Text(
          '${_fmt(v.position)} / ${_fmt(v.duration)}',
          style: TextStyle(
            color: DisplayColors.text,
            fontSize: 16 * s,
            fontFeatures: const [FontFeature.tabularFigures()],
          ),
        ),
      ],
    );
  }
}

class _ErrorPane extends StatelessWidget {
  const _ErrorPane({required this.message, required this.url});

  final String message;
  final String url;

  @override
  Widget build(BuildContext context) {
    final t = DisplayText.of(context);
    return Center(
      child: Padding(
        padding: EdgeInsets.all(24 * t.s),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.videocam_off_outlined,
              size: 56 * t.s,
              color: DisplayColors.textFaint,
            ),
            SizedBox(height: 12 * t.s),
            Text(message, style: t.body, textAlign: TextAlign.center),
            SizedBox(height: 6 * t.s),
            Text(
              url,
              style: t.bodyMuted.copyWith(fontSize: 15 * t.s),
              textAlign: TextAlign.center,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
          ],
        ),
      ),
    );
  }
}
