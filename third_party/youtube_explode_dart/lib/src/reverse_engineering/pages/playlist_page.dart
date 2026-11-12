import 'package:collection/collection.dart';
import 'package:html/parser.dart' as parser;

import '../../../youtube_explode_dart.dart';
import '../../extensions/helpers_extension.dart';
import '../../retry.dart';
import '../models/initial_data.dart';
import '../models/youtube_page.dart';

class PlaylistPage extends YoutubePage<_InitialData> {
  final String playlistId;
  final String? _visitorData;

  late final List<_Video> videos = initialData.playlistVideos;
  late final String? title = initialData.title;
  late final String? description = initialData.description;
  late final String? author = initialData.author;
  late final int? viewCount = initialData.viewCount;
  late final int? videoCount = initialData.videoCount;

  PlaylistPage.id(this.playlistId, _InitialData initialData,
      [this._visitorData])
      : super.fromInitialData(initialData);

  PlaylistPage.parse(String raw, this.playlistId)
      : _visitorData = null,
        super(parser.parse(raw), (root) => _InitialData(root));

  Future<PlaylistPage?> nextPage(YoutubeHttpClient httpClient) async {
    final token = initialData.continuationToken;
    if (token == null || token.isEmpty) return null;

    final data = await httpClient.sendContinuation('browse', token, headers: {
      'x-youtube-client-name': '1',
      'x-goog-visitor-id': _visitorData ?? '',
    });

    final newInitialData = _InitialData(data);
    // Guard against infinite loops with a stuck token.
    if (newInitialData.continuationToken == token) return null;

    return PlaylistPage.id(playlistId, newInitialData, _visitorData);
  }

  static Future<PlaylistPage> get(YoutubeHttpClient httpClient, String id) {
    final url = 'https://www.youtube.com/playlist?list=$id&hl=en&persist_hl=1';
    return retry(httpClient, () async {
      final raw = await httpClient.getString(url);
      final page = PlaylistPage.parse(raw, id);
      if (page.initialData.exists && page.videos.isNotEmpty) return page;

      // Fallback: fetch via the browse API. Needed for Mixes and YT Music playlists
      // whose initial HTML page doesn't embed the video list.
      try {
        final data = await httpClient.sendPost('browse', {
          'browseId': page.initialData.browseId ?? id,
        }, headers: {
          'x-youtube-client-name': '1',
          'x-goog-visitor-id': page.initialData.visitorData ?? '',
        });
        final browsePage = PlaylistPage.id(
            id, _InitialData(data), page.initialData.visitorData);
        if (browsePage.videos.isNotEmpty) return browsePage;
      } catch (_) {
        // Browse failed — fall through and return what we have.
      }
      return page;
    });
  }
}

class _InitialData extends InitialData {
  _InitialData(super.root);

  String? get visitorData => root.getJson<String>(
      'responseContext/webResponseContextExtensionData/ytConfigData/visitorData');

  String? get browseId {
    final params =
        root.getJson<List<dynamic>>('responseContext/serviceTrackingParams');
    final gfeedback = params
        ?.firstWhereOrNull((e) => e['service'] == 'GFEEDBACK') as JsonMap?;
    final paramList = gfeedback?.getJson<List<dynamic>>('params');
    return (paramList?.firstWhereOrNull((e) => e['key'] == 'browse_id')
            as JsonMap?)
        ?.getT<String>('value');
  }

  bool get exists =>
      root.getJson<String>('alerts/0/alertRenderer/type') != 'ERROR';

  late final String? title =
      root.getJson<String>('metadata/playlistMetadataRenderer/title');

  late final String? description =
      root.getJson<String>('metadata/playlistMetadataRenderer/description');

  late final String? author = (root
          .getJson<List<dynamic>>('sidebar/playlistSidebarRenderer/items')
          ?.elementAtSafe(1) as JsonMap?)
      ?.getJson<List<dynamic>>(
        'playlistSidebarSecondaryInfoRenderer/videoOwner/videoOwnerRenderer/title/runs',
      )
      ?.cast<Map<dynamic, dynamic>>()
      .parseRuns();

  late final int? viewCount = ((root
              .getJson<List<dynamic>>('sidebar/playlistSidebarRenderer/items')
              ?.firstOrNull as JsonMap?)
          ?.getJson<List<dynamic>>('playlistSidebarPrimaryInfoRenderer/stats')
          ?.elementAtSafe(1) as JsonMap?)
      ?.getJson<String>('simpleText')
      .parseInt();

  late final int? videoCount = () {
    final stats = (root
                .getJson<List<dynamic>>('sidebar/playlistSidebarRenderer/items')
                ?.firstWhereOrNull(
                    (e) => e['playlistSidebarPrimaryInfoRenderer'] != null)
            as JsonMap?)
        ?.getJson<List<dynamic>>('playlistSidebarPrimaryInfoRenderer/stats');
    if (stats == null) return null;

    for (final stat in stats.cast<JsonMap>()) {
      final text = stat.getJson<String>('runs/0/text');
      final suffix = stat.getJson<String>('runs/1/text');
      if (text != null && suffix != null && suffix.contains('video')) {
        return text.parseInt();
      }
    }
    // Fallback: use the first stat if none was labelled "video".
    final first = stats.firstOrNull;
    return first is Map
        ? (first as JsonMap).getJson<String>('runs/0/text').parseInt()
        : null;
  }();

  String? get continuationToken {
    final items = _videoItems;
    if (items != null) {
      for (final item in items) {
        if (item.containsKey('continuationItemRenderer')) {
          final endpoint = item.getJson<JsonMap>('continuationItemRenderer/continuationEndpoint');
          final token = endpoint?.getJson<String>('continuationCommand/token') ??
              endpoint?.getJson<List<dynamic>>('commandExecutorCommand/commands')
                  ?.cast<JsonMap>()
                  .map((c) => c.getJson<String>('continuationCommand/token'))
                  .nonNulls
                  .firstOrNull;
          if (token != null && token.isNotEmpty) return token;
        }
        if (item.containsKey('continuationItemViewModel')) {
          final vm = item['continuationItemViewModel'] as JsonMap?;
          final token = vm?.getJson<String>('continuationCommand/innertubeCommand/continuationCommand/token') ??
              vm?.getJson<String>('continuationCommand/continuationCommand/token');
          if (token != null && token.isNotEmpty) return token;
        }
      }
    }

    final tabs = root.getJson<List<dynamic>>('contents/twoColumnBrowseResultsRenderer/tabs');
    if (tabs != null) {
      for (final tab in tabs.cast<JsonMap>()) {
        final sections = tab.getJson<List<dynamic>>('tabRenderer/content/sectionListRenderer/contents');
        if (sections == null) continue;
        for (final section in sections.cast<JsonMap>()) {
          if (section.containsKey('continuationItemViewModel')) {
            final vm = section['continuationItemViewModel'] as JsonMap?;
            final token = vm?.getJson<String>('continuationCommand/innertubeCommand/continuationCommand/token') ??
                vm?.getJson<String>('continuationCommand/continuationCommand/token');
            if (token != null && token.isNotEmpty) return token;
          }
        }
      }
    }

    return null;
  }

  /// The flat list of items (videos + continuation marker) for the current page.
  /// Handles both continuation responses and initial page loads.
  List<JsonMap>? get _videoItems {
    // Continuation responses arrive under onResponseReceivedActions/Commands.
    final actions = root.getJson<List<dynamic>>('onResponseReceivedActions') ??
        root.getJson<List<dynamic>>('onResponseReceivedCommands');
    if (actions != null) {
      for (final action in actions.cast<JsonMap>()) {
        final items = action.getJson<List<dynamic>>(
                'appendContinuationItemsAction/continuationItems') ??
            action.getJson<List<dynamic>>(
                'reloadContinuationItemsCommand/continuationItems');
        if (items != null) {
          final result = <JsonMap>[];
          for (final it in items.cast<JsonMap>()) {
            if (it.containsKey('itemSectionRenderer')) {
              final subContents = (it['itemSectionRenderer'] as JsonMap)
                  .getJson<List<dynamic>>('contents');
              if (subContents != null) {
                for (final sub in subContents.cast<JsonMap>()) {
                  if (sub.containsKey('horizontalShelfViewModel')) {
                    final shelfItems = (sub['horizontalShelfViewModel'] as JsonMap)
                        .getJson<List<dynamic>>('items');
                    if (shelfItems != null) {
                      result.addAll(shelfItems.cast<JsonMap>());
                    }
                  } else {
                    result.add(sub);
                  }
                }
              }
            } else {
              result.add(it);
            }
          }
          return result;
        }
      }
    }

    // Initial page: tabs → sectionList → itemSection → (lockupViewModel OR playlistVideoListRenderer).
    final tabs = root
        .getJson<List<dynamic>>('contents/twoColumnBrowseResultsRenderer/tabs');
    if (tabs == null) return null;

    final result = <JsonMap>[];
    for (final tab in tabs.cast<JsonMap>()) {
      final sections = tab.getJson<List<dynamic>>(
          'tabRenderer/content/sectionListRenderer/contents');
      if (sections == null) continue;

      for (final section in sections.cast<JsonMap>()) {
        final itemContents =
            section.getJson<List<dynamic>>('itemSectionRenderer/contents');
        if (itemContents != null) {
          for (final item in itemContents.cast<JsonMap>()) {
            if (item.containsKey('playlistVideoListRenderer')) {
              final contents = item.getJson<List<dynamic>>('playlistVideoListRenderer/contents');
              if (contents != null) {
                result.addAll(contents.cast<JsonMap>());
              }
            } else {
              result.add(item);
            }
          }
        }
      }
    }

    if (result.isNotEmpty) return result;
    return null;
  }

  List<_Video> get playlistVideos {
    final items = _videoItems;
    if (items == null) return const [];

    final list = <_Video>[];
    for (final item in items) {
      final videoMap = item['lockupViewModel'] as JsonMap? ??
          item['playlistVideoRenderer'] as JsonMap? ??
          item['richItemRenderer']?['content']?['playlistVideoRenderer'] as JsonMap? ??
          item['richItemRenderer']?['content']?['lockupViewModel'] as JsonMap? ??
          (item.containsKey('contentId') || item.containsKey('videoId') ? item : null);

      if (videoMap != null) {
        final contentType = videoMap.getJson<String>('contentType');
        if (contentType != null && contentType != 'LOCKUP_CONTENT_TYPE_VIDEO') {
          continue;
        }

        final v = _Video(videoMap);
        if (VideoId.validateVideoId(v.id) &&
            v.title != '[Private video]' &&
            v.title != '[Deleted video]') {
          list.add(v);
        }
      }
    }
    return list;
  }
}

class _Video {
  final JsonMap root;
  _Video(this.root);

  String get id =>
      root.getJson<String>('contentId') ??
      root.getJson<String>('videoId') ??
      root.getJson<String>('rendererContext/commandContext/onTap/innertubeCommand/watchEndpoint/videoId') ??
      '';

  String get author {
    final metadataRows = root.getJson<List<dynamic>>(
      'metadata/lockupMetadataViewModel/metadata/contentMetadataViewModel/metadataRows',
    );
    if (metadataRows != null && metadataRows.isNotEmpty) {
      final parts = (metadataRows.first as JsonMap?)?.getJson<List<dynamic>>('metadataParts');
      final authorText = (parts?.firstOrNull as JsonMap?)?.getJson<String>('text/content');
      if (authorText != null && authorText.isNotEmpty) {
        return authorText;
      }
    }

    return root.getJson<List<dynamic>>('ownerText/runs')?.cast<Map<dynamic, dynamic>>().parseRuns() ??
        root.getJson<List<dynamic>>('shortBylineText/runs')?.cast<Map<dynamic, dynamic>>().parseRuns() ??
        '';
  }

  String get channelId {
    final avatarId = root.getJson<String>(
      'metadata/lockupMetadataViewModel/image/decoratedAvatarViewModel/rendererContext/commandContext/onTap/innertubeCommand/browseEndpoint/browseId',
    );
    if (avatarId != null && avatarId.isNotEmpty) return avatarId;

    final stackId = root.getJson<String>(
      'metadata/lockupMetadataViewModel/image/avatarStackViewModel/rendererContext/commandContext/onTap/innertubeCommand/showDialogCommand/panelLoadingStrategy/inlineContent/dialogViewModel/customContent/listViewModel/listItems/0/listItemViewModel/title/commandRuns/0/onTap/innertubeCommand/browseEndpoint/browseId',
    );
    if (stackId != null && stackId.isNotEmpty) return stackId;

    final metadataRows = root.getJson<List<dynamic>>(
      'metadata/lockupMetadataViewModel/metadata/contentMetadataViewModel/metadataRows',
    );
    if (metadataRows != null && metadataRows.isNotEmpty) {
      final parts = (metadataRows.first as JsonMap?)?.getJson<List<dynamic>>('metadataParts');
      final text = parts?.firstOrNull as JsonMap?;
      final runId = text?.getJson<String>(
        'text/commandRuns/0/onTap/innertubeCommand/browseEndpoint/browseId',
      );
      if (runId != null && runId.isNotEmpty) return runId;
    }

    return root.getJson<String>('ownerText/runs/0/navigationEndpoint/browseEndpoint/browseId') ??
        root.getJson<String>('shortBylineText/runs/0/navigationEndpoint/browseEndpoint/browseId') ??
        root.getJson<String>('shortBylineText/runs/0/navigationEndpoint/showDialogCommand/panelLoadingStrategy/inlineContent/dialogViewModel/customContent/listViewModel/listItems/0/listItemViewModel/rendererContext/commandContext/onTap/innertubeCommand/browseEndpoint/browseId') ??
        '';
  }

  String get title =>
      root.getJson<String>('metadata/lockupMetadataViewModel/title/content') ??
      root.getJson<List<dynamic>>('title/runs')?.cast<Map<dynamic, dynamic>>().parseRuns() ??
      root.getJson<String>('title/simpleText') ??
      '';

  String get description =>
      root
          .getJson<List<dynamic>>('descriptionSnippet')
          ?.cast<Map<dynamic, dynamic>>()
          .parseRuns() ??
      '';

  Duration? get duration {
    final legacy = root.getJson<String>('lengthText/simpleText')?.toDuration();
    if (legacy != null) return legacy;

    final overlays = root.getJson<List<dynamic>>('contentImage/thumbnailViewModel/overlays');
    if (overlays != null) {
      for (final overlay in overlays.cast<JsonMap>()) {
        final badges = overlay.getJson<List<dynamic>>('thumbnailBottomOverlayViewModel/badges');
        if (badges != null) {
          for (final badge in badges.cast<JsonMap>()) {
            final text = badge.getJson<String>('thumbnailBadgeViewModel/text');
            if (text != null && text.isNotEmpty) {
              final d = text.toDuration();
              if (d != null) return d;
            }
          }
        }
      }
    }
    return null;
  }

  int get viewCount {
    final simple = root.getJson<String>('viewCountText/simpleText')?.parseInt();
    if (simple != null) return simple;

    final infoCount = _videoInfo?.split('•').elementAtSafe(0)?.stripNonDigits().parseInt();
    if (infoCount != null) return infoCount;

    final metadataRows = root.getJson<List<dynamic>>(
      'metadata/lockupMetadataViewModel/metadata/contentMetadataViewModel/metadataRows',
    );
    if (metadataRows != null && metadataRows.length > 1) {
      final parts = (metadataRows[1] as JsonMap?)?.getJson<List<dynamic>>('metadataParts');
      final viewText = (parts?.firstOrNull as JsonMap?)?.getJson<String>('text/content');
      if (viewText != null) {
        return viewText.stripNonDigits().parseInt() ?? 0;
      }
    }
    return 0;
  }

  String? get uploadDateRaw {
    final infoDate = _videoInfo?.split('•').elementAtSafe(1);
    if (infoDate != null) return infoDate;

    final metadataRows = root.getJson<List<dynamic>>(
      'metadata/lockupMetadataViewModel/metadata/contentMetadataViewModel/metadataRows',
    );
    if (metadataRows != null && metadataRows.length > 1) {
      final parts = (metadataRows[1] as JsonMap?)?.getJson<List<dynamic>>('metadataParts');
      if (parts != null && parts.length > 1) {
        return (parts[1] as JsonMap?)?.getJson<String>('text/content');
      }
    }
    return null;
  }

  String? get _videoInfo => root
      .getJson<List<dynamic>>('videoInfo/runs')
      ?.cast<Map<dynamic, dynamic>>()
      .parseRuns();
}
