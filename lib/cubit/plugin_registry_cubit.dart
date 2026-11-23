import 'dart:async';

import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:zephyr/plugin/plugin_registry_service.dart';

/// 全局插件状态：runtime 列表 + getInfo 缓存。
///
/// getInfo 由 service 广播（fetch 成功 / 缓存失效），这里只收快照。
/// 各页订阅本 cubit 做热切换，不再各自 fetch + 本地缓存。
class PluginRegistryState {
  const PluginRegistryState({
    this.plugins = const {},
    this.infos = const {},
    this.infoErrors = const {},
  });

  final Map<String, PluginRuntimeState> plugins;
  final Map<String, Map<String, dynamic>> infos;

  /// 最近一次 getInfo 失败的错误文案（成功即清除）。
  final Map<String, String> infoErrors;

  String pluginName(String uuid) {
    final name = infos[uuid]?['name']?.toString().trim() ?? '';
    return name.isNotEmpty ? name : uuid;
  }

  String? pluginIconUrl(String uuid) =>
      infos[uuid]?['iconUrl']?.toString().trim();

  bool hasCapability(String uuid, String flag) => infos[uuid]?[flag] == true;

  List<String> capablePlugins(String flag) {
    return PluginRegistryService.I
        .sortPlugins(
          plugins.values.where(
            (p) => p.isActive && hasCapability(p.uuid, flag),
          ),
        )
        .map((p) => p.uuid)
        .toList();
  }
}

class PluginRegistryCubit extends Cubit<PluginRegistryState> {
  PluginRegistryCubit({PluginRegistryService? service})
    : _service = service ?? PluginRegistryService.I,
      super(
        PluginRegistryState(
          plugins: (service ?? PluginRegistryService.I).snapshot,
          infos: (service ?? PluginRegistryService.I).infoSnapshot,
          infoErrors: (service ?? PluginRegistryService.I).infoErrorSnapshot,
        ),
      ) {
    _pluginSubscription = _service.stream.listen((plugins) {
      if (isClosed) {
        return;
      }
      emit(
        PluginRegistryState(
          plugins: plugins,
          infos: state.infos,
          infoErrors: state.infoErrors,
        ),
      );
    });
    _infoSubscription = _service.infoStream.listen((infos) {
      if (isClosed) {
        return;
      }
      emit(
        PluginRegistryState(
          plugins: state.plugins,
          infos: infos,
          infoErrors: state.infoErrors,
        ),
      );
    });
    _infoErrorSubscription = _service.infoErrorStream.listen((errors) {
      if (isClosed) {
        return;
      }
      emit(
        PluginRegistryState(
          plugins: state.plugins,
          infos: state.infos,
          infoErrors: errors,
        ),
      );
    });
    // info 由 PluginRegistryService.init() 从 DB 水合后经 infoStream 广播；
    // 这里不再触发全量 getInfo（安装/更新/启用路径会主动刷新单个插件）。
  }

  final PluginRegistryService _service;
  late final StreamSubscription<Map<String, PluginRuntimeState>>
  _pluginSubscription;
  late final StreamSubscription<Map<String, Map<String, dynamic>>>
  _infoSubscription;
  late final StreamSubscription<Map<String, String>> _infoErrorSubscription;

  Future<void> refresh() => _service.refreshFromDb();

  @override
  Future<void> close() async {
    await _pluginSubscription.cancel();
    await _infoSubscription.cancel();
    await _infoErrorSubscription.cancel();
    return super.close();
  }
}
