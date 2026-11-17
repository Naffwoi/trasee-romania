import 'package:dio/dio.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';
import 'package:wanderer/models/server_instance.dart';
import 'package:wanderer/provider/api_provider.dart';

part 'server_selection_provider.g.dart';

const ServerInstance kDefaultRomaniaServer = ServerInstance(
  name: 'Trasee România',
  url: 'https://trasee.skillfy.ro',
  description: 'Trasee montane și urbane din România cu navigație GPS live',
  region: ['RO'],
  language: ['ro', 'en'],
  category: ['Hiking'],
);

class ServerState {
  List<ServerInstance> availableServers;
  ServerInstance? selectedServer;

  ServerState(this.availableServers, this.selectedServer);
}

@riverpod
class ServerSelectionNotifier extends _$ServerSelectionNotifier {
  @override
  Future<ServerState> build() async {
    final servers = <ServerInstance>[kDefaultRomaniaServer];

    try {
      final dio = Dio(
        BaseOptions(connectTimeout: const Duration(seconds: 5)),
      );
      final response = await dio.get('https://wanderer.to/server/servers.json');
      final List<dynamic> data = response.data;
      for (final json in data) {
        final instance = ServerInstance.fromJson(json);
        if (instance.url != kDefaultRomaniaServer.url) {
          servers.add(instance);
        }
      }
    } catch (_) {
      // Keep Trasee România available even when wanderer.to is unreachable.
    }

    final currentBase = ref.read(apiProvider).options.baseUrl;
    if (currentBase.contains(kUnconfiguredApiHost)) {
      ref.read(apiProvider.notifier).updateBaseUrl(kDefaultRomaniaServer.url);
    }

    return ServerState(servers, kDefaultRomaniaServer);
  }

  void setSelectedServer(ServerInstance server) {
    // A "Last used" entry (quick-260926-ijp) can be tapped while the
    // servers.json fetch is still loading or has failed (e.g. wanderer.to is
    // down but a self-hosted instance is up), so `requireValue` would throw
    // here. Falling back to an empty list on that window is accepted: it is
    // sub-second, and the user simply reselects if the fetch then overwrites
    // this state.
    final newState = ServerState(
      state.value?.availableServers ?? const [],
      server,
    );
    state = AsyncValue.data(newState);
  }
}
