import { FlutterPlugin, FlutterPluginBinding } from '@ohos/flutter_ohos/src/main/ets/embedding/engine/plugins/FlutterPlugin';
import MethodChannel, {
  MethodCallHandler,
  MethodResult
} from '@ohos/flutter_ohos/src/main/ets/plugin/common/MethodChannel';
import MethodCall from '@ohos/flutter_ohos/src/main/ets/plugin/common/MethodCall';
import Any from '@ohos/flutter_ohos/src/main/ets/plugin/common/Any';
import EventChannel, {
  EventSink,
  StreamHandler
} from '@ohos/flutter_ohos/src/main/ets/plugin/common/EventChannel';
import common from '@ohos.app.ability.common';
import Want from '@ohos.app.ability.Want';
import wantConstant from '@ohos.app.ability.wantConstant';
import fileUri from '@ohos.file.fileuri';
import fs from '@ohos.file.fs';
import photoAccessHelper from '@ohos.file.photoAccessHelper';
import picker from '@ohos.file.picker';
import notificationManager from '@ohos.notificationManager';
import bundleManager from '@ohos.bundle.bundleManager';
import batteryInfo from '@ohos.batteryInfo';
import dataPreferences from '@ohos.data.preferences';
import deviceInfo from '@ohos.deviceInfo';
import connection from '@ohos.net.connection';
import wantAgent from '@ohos.app.ability.wantAgent';
import inputConsumer from '@ohos.multimodalInput.inputConsumer';
import { KeyEvent } from '@ohos.multimodalInput.keyEvent';
import { getOhosPath, getOhosPaths } from './OhosPathProvider';
import { OhosSharedPreferences } from './OhosSharedPreferences';

const FILE_CHANNEL = 'zephyr/ohos_file';
const VOLUME_METHOD_CHANNEL = 'volume_key_handler';
const VOLUME_EVENT_CHANNEL = 'volume_key_events';
const KEYCODE_VOLUME_UP = 16;
const KEYCODE_VOLUME_DOWN = 17;

export default class BreezeOhosPlugin implements FlutterPlugin {
  private context: common.UIAbilityContext;
  private appContext: common.Context;
  private fileChannel: MethodChannel | null = null;
  private volumeMethodChannel: MethodChannel | null = null;
  private volumeEventChannel: EventChannel | null = null;
  private eventSink: EventSink | null = null;
  private keysSubscribed = false;
  private volumeUpCallback: ((event: KeyEvent) => void) | null = null;
  private volumeDownCallback: ((event: KeyEvent) => void) | null = null;
  private sharedPreferences: OhosSharedPreferences | null = null;

  constructor(context: common.UIAbilityContext) {
    this.context = context;
    this.appContext = context;
  }

  getUniqueClassName(): string {
    return 'BreezeOhosPlugin';
  }

  onAttachedToEngine(binding: FlutterPluginBinding): void {
    // 目录与偏好必须使用应用级 context，否则 PathUtils.getFilesDir 会落到
    // haps/entry/files，导致升级后读不到原有数据库。
    this.appContext = binding.getApplicationContext();
    this.fileChannel = new MethodChannel(binding.getBinaryMessenger(), FILE_CHANNEL);
    const fileHandler: MethodCallHandler = {
      onMethodCall: (call: MethodCall, result: MethodResult): void => {
        if (call.method === 'openFile') {
          this.openFile(call, result);
        } else if (call.method === 'saveImage') {
          this.saveImage(call, result);
        } else if (call.method === 'pickFile') {
          this.pickDocuments(call, result, false);
        } else if (call.method === 'pickFiles') {
          this.pickDocuments(call, result, true);
        } else if (call.method === 'pickSavePath') {
          this.pickSavePath(call, result);
        } else if (call.method === 'saveFile') {
          this.saveFileToPicker(call, result);
        } else if (call.method === 'requestNotificationPermission') {
          this.requestNotificationPermission(result);
        } else if (call.method === 'getPackageInfo') {
          this.getPackageInfo(result);
        } else if (call.method === 'openUrl') {
          this.openUrl(call, result);
        } else if (call.method === 'getDeviceInfo') {
          this.getDeviceInfo(result);
        } else if (call.method === 'getConnectivity') {
          this.getConnectivity(result);
        } else if (call.method === 'getBatteryInfo') {
          this.getBatteryInfo(result);
        } else if (call.method === 'getPath') {
          this.getPath(call, result);
        } else if (call.method === 'getPaths') {
          this.getPaths(call, result);
        } else if (call.method === 'prefs.getAll') {
          this.prefsGetAll(call, result);
        } else if (call.method === 'prefs.set') {
          this.prefsSet(call, result);
        } else if (call.method === 'prefs.remove') {
          this.prefsRemove(call, result);
        } else if (call.method === 'prefs.clear') {
          this.prefsClear(call, result);
        } else if (call.method === 'publishNotification') {
          this.publishNotification(call, result);
        } else if (call.method === 'cancelNotification') {
          this.cancelNotification(call, result);
        } else {
          result.notImplemented();
        }
      }
    };
    this.fileChannel.setMethodCallHandler(fileHandler);

    this.volumeMethodChannel = new MethodChannel(binding.getBinaryMessenger(), VOLUME_METHOD_CHANNEL);
    const volumeHandler: MethodCallHandler = {
      onMethodCall: (call: MethodCall, result: MethodResult): void => {
        if (call.method === 'enableInterception') {
          this.enableVolumeKeys();
          result.success(null);
        } else if (call.method === 'disableInterception') {
          this.disableVolumeKeys();
          result.success(null);
        } else {
          result.notImplemented();
        }
      }
    };
    this.volumeMethodChannel.setMethodCallHandler(volumeHandler);

    this.volumeEventChannel = new EventChannel(binding.getBinaryMessenger(), VOLUME_EVENT_CHANNEL);
    const streamHandler: StreamHandler = {
      onListen: (args: Any, events: EventSink): void => {
        this.eventSink = events;
      },
      onCancel: (args: Any): void => {
        this.eventSink = null;
      }
    };
    this.volumeEventChannel.setStreamHandler(streamHandler);
  }

  onDetachedFromEngine(binding: FlutterPluginBinding): void {
    this.disableVolumeKeys();
    this.eventSink = null;
    this.fileChannel?.setMethodCallHandler(null);
    this.fileChannel = null;
    this.volumeMethodChannel?.setMethodCallHandler(null);
    this.volumeMethodChannel = null;
  }

  private enableVolumeKeys(): void {
    if (this.keysSubscribed) {
      return;
    }
    this.volumeUpCallback = (event: KeyEvent): void => {
      this.eventSink?.success('volume_up');
    };
    this.volumeDownCallback = (event: KeyEvent): void => {
      this.eventSink?.success('volume_down');
    };
    try {
      inputConsumer.on('keyPressed', {
        key: KEYCODE_VOLUME_UP,
        action: 1,
        isRepeat: false
      }, this.volumeUpCallback);
      inputConsumer.on('keyPressed', {
        key: KEYCODE_VOLUME_DOWN,
        action: 1,
        isRepeat: false
      }, this.volumeDownCallback);
      this.keysSubscribed = true;
    } catch (error) {
      console.error(`BREEZE_VOLUME subscribe failed: ${error}`);
    }
  }

  private disableVolumeKeys(): void {
    if (!this.keysSubscribed) {
      return;
    }
    try {
      if (this.volumeUpCallback !== null) {
        inputConsumer.off('keyPressed', this.volumeUpCallback);
      }
      if (this.volumeDownCallback !== null) {
        inputConsumer.off('keyPressed', this.volumeDownCallback);
      }
    } catch (error) {
      console.error(`BREEZE_VOLUME unsubscribe failed: ${error}`);
    }
    this.volumeUpCallback = null;
    this.volumeDownCallback = null;
    this.keysSubscribed = false;
  }

  private uriToPath(uri: string): string {
    try {
      const parsed = new fileUri.FileUri(uri);
      if (parsed.path.length > 0) {
        return parsed.path;
      }
    } catch (error) {
      // 非文件 URI（如 docs）无法直接转路径，保留原值由调用方处理。
    }
    return uri;
  }

  private fileNameFromUri(uri: string): string {
    const clean = uri.split('?')[0];
    const parts = clean.split('/');
    const name = parts[parts.length - 1];
    return name.length > 0 ? name : 'picked_file';
  }

  private copyUriToCache(uri: string, name: string): string {
    const safe = name.replace(/[^a-zA-Z0-9._-]/g, '_');
    const cachePath =
      `${this.context.cacheDir}/ohos_pick_${Date.now()}_${Math.floor(Math.random() * 100000)}_${safe}`;
    const src = fs.openSync(uri, fs.OpenMode.READ_ONLY);
    const dst = fs.openSync(cachePath, fs.OpenMode.READ_WRITE | fs.OpenMode.CREATE);
    try {
      fs.copyFileSync(src.fd, dst.fd);
    } finally {
      fs.closeSync(src);
      fs.closeSync(dst);
    }
    return cachePath;
  }

  private async pickDocuments(
    call: MethodCall,
    result: MethodResult,
    multiple: boolean
  ): Promise<void> {
    try {
      const suffixes = (call.argument('suffixes') as string[]) ?? [];
      const options = new picker.DocumentSelectOptions();
      options.maxSelectNumber = multiple ? 99 : 1;
      if (suffixes.length > 0) {
        options.fileSuffixFilters = suffixes.map((suffix: string) =>
          suffix.startsWith('.') ? suffix : `.${suffix}`);
      }
      const uris = await new picker.DocumentViewPicker(this.context).select(options);
      if (uris.length === 0) {
        result.success(multiple ? [] : null);
        return;
      }
      const paths: string[] = [];
      for (const uri of uris) {
        paths.push(this.copyUriToCache(uri, this.fileNameFromUri(uri)));
      }
      result.success(multiple ? paths : paths[0]);
    } catch (error) {
      result.error('pick_failed', `${error}`, null);
    }
  }

  private async pickSavePath(call: MethodCall, result: MethodResult): Promise<void> {
    try {
      const name = (call.argument('suggestedName') as string | null) ?? '';
      const options = new picker.DocumentSaveOptions();
      if (name.length > 0) {
        options.newFileNames = [name];
      }
      const uris = await new picker.DocumentViewPicker(this.context).save(options);
      if (uris.length === 0) {
        result.success(null);
        return;
      }
      result.success(this.uriToPath(uris[0]));
    } catch (error) {
      result.error('pick_save_path_failed', `${error}`, null);
    }
  }

  private async saveFileToPicker(call: MethodCall, result: MethodResult): Promise<void> {
    let src: fs.File | null = null;
    let dst: fs.File | null = null;
    try {
      const path = call.argument('path') as string;
      const nameArg = call.argument('suggestedName') as string | null;
      const name = nameArg !== null && nameArg.length > 0 ? nameArg : this.fileNameFromUri(path);
      const options = new picker.DocumentSaveOptions();
      options.newFileNames = [name];
      const uris = await new picker.DocumentViewPicker(this.context).save(options);
      if (uris.length === 0) {
        result.success(false);
        return;
      }
      src = fs.openSync(path, fs.OpenMode.READ_ONLY);
      dst = fs.openSync(uris[0], fs.OpenMode.READ_WRITE);
      fs.copyFileSync(src.fd, dst.fd);
      result.success(true);
    } catch (error) {
      result.error('save_file_failed', `${error}`, null);
    } finally {
      if (src !== null) {
        fs.closeSync(src);
      }
      if (dst !== null) {
        fs.closeSync(dst);
      }
    }
  }

  private async publishNotification(call: MethodCall, result: MethodResult): Promise<void> {
    try {
      const enabled = await notificationManager.isNotificationEnabled();
      if (!enabled) {
        result.success(false);
        return;
      }
      const id = (call.argument('id') as number) ?? 0;
      const title = (call.argument('title') as string) ?? '';
      const body = (call.argument('body') as string) ?? '';
      const agent = await wantAgent.getWantAgent({
        wants: [{
          bundleName: 'com.zephyr.breeze.ohos',
          abilityName: 'EntryAbility'
        }],
        actionType: wantAgent.OperationType.START_ABILITY,
        requestCode: id,
        actionFlags: [wantAgent.WantAgentFlags.UPDATE_PRESENT_FLAG]
      });
      const request: notificationManager.NotificationRequest = {
        id: id,
        notificationSlotType: notificationManager.SlotType.SOCIAL_COMMUNICATION,
        content: {
          notificationContentType:
            notificationManager.ContentType.NOTIFICATION_CONTENT_BASIC_TEXT,
          normal: { title: title, text: body }
        },
        wantAgent: agent
      };
      await notificationManager.publish(request);
      result.success(true);
    } catch (error) {
      result.error('publish_notification_failed', `${error}`, null);
    }
  }

  private async cancelNotification(call: MethodCall, result: MethodResult): Promise<void> {
    try {
      const id = (call.argument('id') as number) ?? 0;
      await notificationManager.cancel(id);
      result.success(null);
    } catch (error) {
      result.error('cancel_notification_failed', `${error}`, null);
    }
  }

  private getPath(call: MethodCall, result: MethodResult): void {
    try {
      const type = call.argument('type') as string;
      result.success(getOhosPath(this.appContext, type));
    } catch (error) {
      result.error('get_path_failed', `${error}`, null);
    }
  }

  private getPaths(call: MethodCall, result: MethodResult): void {
    try {
      const type = call.argument('type') as string;
      const directory = (call.argument('directory') as string) ?? '';
      result.success(getOhosPaths(this.appContext, type, directory));
    } catch (error) {
      result.error('get_paths_failed', `${error}`, null);
    }
  }

  private prefs(): OhosSharedPreferences {
    if (this.sharedPreferences === null) {
      this.sharedPreferences = new OhosSharedPreferences(this.appContext);
    }
    return this.sharedPreferences;
  }

  private async prefsGetAll(
    call: MethodCall,
    result: MethodResult
  ): Promise<void> {
    try {
      const prefix = (call.argument('prefix') as string) ?? '';
      const allowList = (call.argument('allowList') as string[]) ?? [];
      result.success(await this.prefs().getAll(prefix, allowList));
    } catch (error) {
      result.error('prefs_get_all_failed', `${error}`, null);
    }
  }

  private async prefsSet(call: MethodCall, result: MethodResult): Promise<void> {
    try {
      const key = call.argument('key') as string;
      const value: dataPreferences.ValueType =
        call.argument('value') as dataPreferences.ValueType;
      result.success(await this.prefs().set(key, value));
    } catch (error) {
      result.error('prefs_set_failed', `${error}`, null);
    }
  }

  private async prefsRemove(
    call: MethodCall,
    result: MethodResult
  ): Promise<void> {
    try {
      const key = call.argument('key') as string;
      result.success(await this.prefs().remove(key));
    } catch (error) {
      result.error('prefs_remove_failed', `${error}`, null);
    }
  }

  private async prefsClear(
    call: MethodCall,
    result: MethodResult
  ): Promise<void> {
    try {
      const prefix = (call.argument('prefix') as string) ?? '';
      const allowList = (call.argument('allowList') as string[]) ?? [];
      result.success(await this.prefs().clear(prefix, allowList));
    } catch (error) {
      result.error('prefs_clear_failed', `${error}`, null);
    }
  }

  private async openUrl(call: MethodCall, result: MethodResult): Promise<void> {
    try {
      const uri = call.argument('uri') as string;
      if (!uri) {
        result.error('invalid_url', 'uri is empty', null);
        return;
      }
      const want: Want = {
        action: 'ohos.want.action.viewData',
        uri: uri
      };
      await this.context.startAbility(want);
      result.success(true);
    } catch (error) {
      result.error('open_url_failed', `${error}`, null);
    }
  }

  private getDeviceInfo(result: MethodResult): void {
    try {
      const abis = deviceInfo.abiList
        .split(',')
        .map((item: string) => item.trim())
        .filter((item: string) => item.length > 0);
      result.success({
        'brand': deviceInfo.brand,
        'manufacturer': deviceInfo.manufacture,
        'model': deviceInfo.productModel,
        'osVersion': deviceInfo.osFullName,
        'sdkApiVersion': deviceInfo.sdkApiVersion,
        'abis': abis
      });
    } catch (error) {
      result.error('device_info_failed', `${error}`, null);
    }
  }

  private getConnectivity(result: MethodResult): void {
    try {
      const net = connection.getDefaultNetSync();
      if (!net || net.netId === 0) {
        result.success(['none']);
        return;
      }
      const capabilities = connection.getNetCapabilitiesSync(net);
      const types: string[] = [];
      for (const bearer of capabilities.bearerTypes) {
        if (bearer === connection.NetBearType.BEARER_WIFI) {
          types.push('wifi');
        } else if (bearer === connection.NetBearType.BEARER_CELLULAR) {
          types.push('mobile');
        } else if (bearer === connection.NetBearType.BEARER_ETHERNET) {
          types.push('ethernet');
        } else if (bearer === connection.NetBearType.BEARER_BLUETOOTH) {
          types.push('bluetooth');
        } else if (bearer === connection.NetBearType.BEARER_VPN) {
          types.push('vpn');
        }
      }
      result.success(types.length > 0 ? types : ['other']);
    } catch (error) {
      result.error('connectivity_failed', `${error}`, null);
    }
  }

  private getBatteryInfo(result: MethodResult): void {
    try {
      const rawLevel = batteryInfo.batterySOC;
      const level = Number.isFinite(rawLevel)
        ? Math.max(0, Math.min(100, Math.round(rawLevel)))
        : 100;
      let state = 'unknown';
      if (batteryInfo.chargingStatus === batteryInfo.BatteryChargeState.ENABLE) {
        state = 'charging';
      } else if (batteryInfo.chargingStatus === batteryInfo.BatteryChargeState.FULL) {
        state = 'full';
      } else if (batteryInfo.chargingStatus === batteryInfo.BatteryChargeState.DISABLE) {
        state = 'discharging';
      }
      result.success({
        'level': level,
        'state': state
      });
    } catch (error) {
      result.error('battery_info_failed', `${error}`, null);
    }
  }

  private getPackageInfo(result: MethodResult): void {
    try {
      const info = bundleManager.getBundleInfoForSelfSync(
        bundleManager.BundleFlag.GET_BUNDLE_INFO_DEFAULT
      );
      result.success({
        'version': info.versionName,
        'buildNumber': `${info.versionCode}`
      });
    } catch (error) {
      result.error('package_info_failed', `${error}`, null);
    }
  }

  private async requestNotificationPermission(result: MethodResult): Promise<void> {
    try {
      let enabled = await notificationManager.isNotificationEnabled();
      if (!enabled) {
        try {
          await notificationManager.requestEnableNotification(this.context);
        } catch (error) {
          // 用户拒绝/系统已关闭时继续读最终状态。
        }
        enabled = await notificationManager.isNotificationEnabled();
      }
      result.success(enabled);
    } catch (error) {
      result.error('notification_permission_failed', `${error}`, null);
    }
  }

  private async saveImage(call: MethodCall, result: MethodResult): Promise<void> {
    const path = call.argument('path') as string;
    let srcFile: fs.File | null = null;
    let destFile: fs.File | null = null;
    try {
      const helper = photoAccessHelper.getPhotoAccessHelper(this.context);
      const name = path.substring(path.lastIndexOf('/') + 1);
      const dot = name.lastIndexOf('.');
      const title = dot > 0 ? name.substring(0, dot) : name;
      const extension = dot > 0 ? name.substring(dot + 1).toLowerCase() : 'jpg';
      const config: photoAccessHelper.PhotoCreationConfig = {
        title: title,
        fileNameExtension: extension,
        photoType: photoAccessHelper.PhotoType.IMAGE,
        subtype: photoAccessHelper.PhotoSubtype.DEFAULT
      };
      const sourceUri = fileUri.getUriFromPath(path);
      const destUris = await helper.showAssetsCreationDialog(
        [sourceUri],
        [config]
      );
      if (destUris.length === 0) {
        result.error('cancelled', 'user cancelled', null);
        return;
      }
      srcFile = fs.openSync(path, fs.OpenMode.READ_ONLY);
      destFile = fs.openSync(destUris[0], fs.OpenMode.READ_WRITE);
      fs.copyFileSync(srcFile.fd, destFile.fd);
      result.success(null);
    } catch (error) {
      result.error('save_image_failed', `${error}`, null);
    } finally {
      if (srcFile !== null) {
        fs.closeSync(srcFile);
      }
      if (destFile !== null) {
        fs.closeSync(destFile);
      }
    }
  }

  private async openFile(call: MethodCall, result: MethodResult): Promise<void> {
    const path = call.argument('path') as string;
    const mimeArg: string | null = call.argument('mime') as string | null;
    const mime = mimeArg !== null && mimeArg.length > 0 ? mimeArg : '*/*';
    try {
      const uri = fileUri.getUriFromPath(path);
      const want: Want = {
        action: 'ohos.want.action.viewData',
        uri: uri,
        type: mime,
        flags: wantConstant.Flags.FLAG_AUTH_READ_URI_PERMISSION
      };
      await this.context.startAbility(want);
      result.success(null);
    } catch (error) {
      result.error('open_file_failed', `${error}`, null);
    }
  }
}
