import common from '@ohos.app.ability.common';
import PathUtils from '@ohos/flutter_ohos/src/main/ets/util/PathUtils';
import fs from '@ohos.file.fs';

function ensureDir(path: string): string {
  if (!fs.accessSync(path)) {
    fs.mkdirSync(path);
  }
  return path;
}

/// OHOS 目录映射：替代 third_party path_provider_ohos 的独立模块。
export function getOhosPath(context: common.Context, type: string): string {
  switch (type) {
    case 'temporary':
    case 'cache':
      return context.cacheDir;
    case 'support':
      return PathUtils.getFilesDir(context);
    case 'documents':
      return PathUtils.getDataDirectory(context) ?? '';
    case 'externalStorage':
      return context.filesDir;
    case 'downloads':
      return ensureDir(`${context.filesDir}/downloads`);
    default:
      throw new Error(`unsupported path type: ${type}`);
  }
}

export function getOhosPaths(
  context: common.Context,
  type: string,
  directory: string
): string[] {
  if (type === 'externalCache') {
    return [context.cacheDir];
  }
  if (type === 'externalStorageDir') {
    const name = directory.replace(/[^a-zA-Z0-9_-]/g, '');
    if (name.length === 0) {
      return [context.filesDir];
    }
    return [ensureDir(`${context.filesDir}/${name}`)];
  }
  return [getOhosPath(context, type)];
}
