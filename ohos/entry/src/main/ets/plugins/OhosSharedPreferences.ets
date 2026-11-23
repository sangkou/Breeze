import common from '@ohos.app.ability.common';
import dataPreferences from '@ohos.data.preferences';

const PREFERENCES_NAME = 'FlutterSharedPreferences';

/// OHOS SharedPreferences 存储：替代 third_party shared_preferences_ohos。
///
/// key 与旧插件保持一致，已有用户设置可直接沿用。
export class OhosSharedPreferences {
  private context: common.Context;
  private preferences: dataPreferences.Preferences | null = null;

  constructor(context: common.Context) {
    this.context = context;
  }

  private async store(): Promise<dataPreferences.Preferences> {
    if (this.preferences === null) {
      this.preferences = await dataPreferences.getPreferences(
        this.context,
        PREFERENCES_NAME
      );
    }
    return this.preferences;
  }

  async getAll(prefix: string, allowList: string[]): Promise<Map<string, Object>> {
    const store = await this.store();
    const raw = await store.getAll() as Record<string, ESObject>;
    const result = new Map<string, Object>();
    for (const key of Object.keys(raw)) {
      if (!key.startsWith(prefix)) {
        continue;
      }
      if (allowList.length > 0 && allowList.indexOf(key) < 0) {
        continue;
      }
      result.set(key, this.normalize(raw[key]));
    }
    return result;
  }

  async set(key: string, value: dataPreferences.ValueType): Promise<boolean> {
    const store = await this.store();
    await store.put(key, value);
    await store.flush();
    return true;
  }

  async remove(key: string): Promise<boolean> {
    const store = await this.store();
    await store.delete(key);
    await store.flush();
    return true;
  }

  async clear(prefix: string, allowList: string[]): Promise<boolean> {
    const store = await this.store();
    const raw = await store.getAll() as Record<string, ESObject>;
    for (const key of Object.keys(raw)) {
      if (!key.startsWith(prefix)) {
        continue;
      }
      if (allowList.length > 0 && allowList.indexOf(key) < 0) {
        continue;
      }
      await store.delete(key);
    }
    await store.flush();
    return true;
  }

  private normalize(value: ESObject): ESObject {
    if (typeof value === 'bigint') {
      return Number(value);
    }
    return value;
  }
}
