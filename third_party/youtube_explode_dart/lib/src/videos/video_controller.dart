import 'dart:convert';

import 'package:meta/meta.dart';

import '../../youtube_explode_dart.dart';
import '../reverse_engineering/pages/watch_page.dart';
import '../reverse_engineering/player/player_response.dart';

@internal
class VideoController {
  @protected
  final YoutubeHttpClient httpClient;

  VideoController(this.httpClient);

  Future<PlayerResponse> getPlayerResponse(
      VideoId videoId, YoutubeApiClient client,
      {WatchPage? watchPage}) async {
    final payload = client.payload;
    assert(payload['context'] != null, 'client must contain a context');
    assert(payload['context']!['client'] != null,
        'client must contain a context.client');

    final userAgent = payload['context']!['client']!['userAgent'] as String?;
    final ytCfg = watchPage?.ytCfg;

    final context = Map<String, dynamic>.from(payload['context'] as Map);
    final clientMap = Map<String, dynamic>.from(context['client'] as Map);
    context['client'] = clientMap;

    final body = {
      ...payload,
      'context': context,
      'videoId': videoId.value,
      if (ytCfg?.containsKey('STS') ?? false)
        'playbackContext': {
          'contentPlaybackContext': {
            'html5Preference': 'HTML5_PREF_WANTS',
            'signatureTimestamp': ytCfg!['STS'].toString()
          }
        }
    };
    final clientName = clientMap['clientName']?.toString().toUpperCase() ?? '';
    const webClients = {
      'WEB',
      'MWEB',
      'TVHTML5',
      'WEB_EMBEDDED_PLAYER',
      'WEB_CREATOR',
      'WEB_REMIX',
      'TVHTML5_SIMPLY',
      'TVHTML5_SIMPLY_EMBEDDED_PLAYER',
    };

    if (webClients.contains(clientName)) {
      final clientVisitorData = httpClient.visitorData;
      if (clientVisitorData != null && clientVisitorData.isNotEmpty) {
        clientMap['visitorData'] = clientVisitorData;
      }
      final pot = httpClient.getPoToken(videoId.value);
      if (pot != null && pot.isNotEmpty) {
        context['serviceIntegrityDimensions'] = {
          'poToken': pot,
        };
      }
    } else if (clientName == 'IOS') {
      clientMap['visitorData'] =
          await _extractVisitorData(httpClient, client);
    }

    final content = await httpClient.postString(
      client.apiUrl,
      body: body,
      headers: {
        if (userAgent != null) 'User-Agent': userAgent,
        'X-Youtube-Client-Name': payload['context']!['client']!['clientName'],
        'X-Youtube-Client-Version':
            payload['context']!['client']!['clientVersion'],
        if (ytCfg != null)
          'X-Goog-Visitor-Id': ytCfg['INNERTUBE_CONTEXT']['client']
              ['visitorData'],
        'Origin': 'https://www.youtube.com',
        'Sec-Fetch-Mode': 'navigate',
        'Content-Type': 'application/json',
        if (watchPage != null)
          'Cookie': watchPage.cookieString
        else if (httpClient.headers['cookie'] != null && webClients.contains(clientName))
          'Cookie': httpClient.headers['cookie']!,
        ...client.headers,
      },
    );
    return PlayerResponse.parse(content);
  }

  String? _visitorData;

  Future<String> _extractVisitorData(
      YoutubeHttpClient http, YoutubeApiClient client) async {
    if (_visitorData != null) {
      return _visitorData!;
    }

    var response =
        await http.getString('https://www.youtube.com/sw.js_data', headers: {
      'User-Agent': client.payload['context']['client']['userAgent']!,
      'Content-Type': 'application/json',
    });

    if (response.startsWith(")]}'")) {
      response = response.substring(4);
    }

    final data = json.decode(response) as List<dynamic>;
    final value = data[0][2][0][0][13];

    return _visitorData = value;
  }
}
