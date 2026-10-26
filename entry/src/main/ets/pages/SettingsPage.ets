import common from '@ohos.app.ability.common';
import bundle from '@ohos.bundle';
import promptAction from '@ohos.promptAction';
import { UiSpec } from '../common/UiSpec';
import ConfigurationConstant from '@ohos.app.ability.ConfigurationConstant';
import { AppSettings } from '../model/Profile';
import { initStore, loadSettings, saveSettings, LogStore } from '../model/Store';
import { geoReady, ensureBundledGeoAssets, restoreBundledGeoAssets, checkGeoAssets, checkGeoAsset, importGeoAssetFromFile, geoAssetInfos, deleteGeoAsset, GeoAssetInfo } from '../utils/GeoAssets';
import { formatBytes } from '../utils/TrafficStats';
import { getClipboardText, setClipboardText } from '../utils/ClipboardHelper';
import { VpnService } from '../core/VpnService';
import { pressLightEffect } from '../common/Effects';
import window from '@ohos.window';

const APP_MODES: Array<string> = ['off', 'exclude', 'include'];
const APP_MODE_LABELS: Array<Resource> = [$r('app.string.per_app_off'), $r('app.string.per_app_exclude'), $r('app.string.per_app_include')];

const STACKS: Array<string> = ['system'];
const MODES: Array<string> = ['rule', 'global', 'direct'];
const MODE_LABELS: Array<Resource> = [$r('app.string.mode_rule'), $r('app.string.mode_global'), $r('app.string.mode_direct')];
const MODE_SWITCH_TOASTS: Array<Resource> = [$r('app.string.settings_mode_switched_rule'), $r('app.string.settings_mode_switched_global'), $r('app.string.settings_mode_switched_direct')];
const LOG_LEVELS: Array<string> = ['trace', 'debug', 'info', 'warn', 'error'];
const SNIFF_MODES: Array<string> = ['off', 'route', 'override'];
const LATENCY_TEST_VALUES: Array<string> = ['url', 'tcp'];
const LATENCY_TEST_LABELS: Array<Resource> = [$r('app.string.latency_test_url'), $r('app.string.latency_test_tcp')];
const SNIFF_LABELS: Array<Resource> = [$r('app.string.sniff_off'), $r('app.string.sniff_route'), $r('app.string.sniff_override')];
const STRATEGIES: Array<string> = ['', 'auto', 'prefer_ipv4', 'prefer_ipv6', 'ipv4_only', 'ipv6_only'];
const STRATEGY_LABELS: Array<Resource> = [$r('app.string.strategy_default'), $r('app.string.strategy_auto'), $r('app.string.strategy_prefer_ipv4'), $r('app.string.strategy_prefer_ipv6'), $r('app.string.strategy_ipv4_only'), $r('app.string.strategy_ipv6_only')];
// Android IPv6Mode 四档(values/arrays.xml ipv6_mode)
const IPV6_MODES: Array<string> = ['disable', 'enable', 'prefer', 'only'];
const IPV6_MODE_LABELS: Array<Resource> = [$r('app.string.ipv6_mode_disable'), $r('app.string.ipv6_mode_enable'), $r('app.string.ipv6_mode_prefer'), $r('app.string.ipv6_mode_only')];

class InstalledAppItem {
  bundleName: string = '';
  label: string = '';

  constructor(bundleName: string, label: string) {
    this.bundleName = bundleName;
    this.label = label;
  }
}

@Component
export struct SettingsPage {
  @State s: AppSettings = new AppSettings();
  @State geoOk: boolean = false;
  @State geoLoading: boolean = false;
  @State geoInfos: Array<GeoAssetInfo> = [];
  @State loading: boolean = true;
  @State loadError: string = '';
  @State installedApps: Array<InstalledAppItem> = [];
  @State appSearch: string = '';
  @State appListLoading: boolean = false;
  @State appListError: ResourceStr = '';
  @State dirty: boolean = false;
  /** 已保存设置的快照:用于判断"是否真的改过" */
  private baselineJson: string = '';
  @State proxyExpanded: boolean = false;
  @State generalExpanded: boolean = false;
  @State networkExpanded: boolean = false;
  @State dnsExpanded: boolean = false;
  @State inboundExpanded: boolean = false;
  @State appearanceExpanded: boolean = false;
  @State apiExpanded: boolean = false;
  @State perAppExpanded: boolean = false;
  /**
   * HDS 点按光效的"当前光源 key":同一时刻只有一个宿主处于按下态。
   * 口径与 Index.ets 的 `litKey` 一致(按下写 key、抬起/取消清空),不挂常亮光源
   * —— 官方明确"点光源位置不跟组件位移变化,不建议在滚动组件里常亮"。
   */
  @State litKey: string = '';
  /** 顶部让位(vp):由壳层实测的 HDS 顶栏底边传入,列表顶部占位与订阅页一致 */
  @Prop contentTopInset: number = 90;
  /** 底部让位(vp):由壳层传入(悬浮胶囊 + 底部安全区),最后一项能停在胶囊上方 */
  @Prop bottomInset: number = 118;
  /** 保存动作由壳层顶栏按钮触发:壳层每点一次把 saveTick + 1 */
  @Prop @Watch('onSaveTickRequest') saveTick: number = 0;
  /** dirty 变化上报壳层:顶栏保存按钮据此灰/蓝 */
  onDirtyChange: (dirty: boolean) => void = (_dirty: boolean) => {};
  /** 滚动器由壳层传入并交给 HdsNavigation.bindToScrollable:滚动时顶栏才有沉浸光感 */
  scroller: Scroller = new Scroller();
  private context: common.UIAbilityContext = getContext(this) as common.UIAbilityContext;
  onSettingsChanged: (settings: AppSettings) => void = (_settings: AppSettings) => {};

  aboutToAppear(): void {
    this.load();
  }

  aboutToDisappear(): void {
    this.onDirtyChange(false);
  }

  /** 壳层顶栏点保存 */
  private onSaveTickRequest(): void {
    void this.save();
  }

  /** 统一改写 dirty 并同步壳层按钮状态 */
  private setDirty(value: boolean): void {
    this.dirty = value;
    this.onDirtyChange(value);
  }

  async load(): Promise<void> {
    this.loading = true;
    this.loadError = '';
    try {
      await initStore(this.context);
      this.s = await loadSettings();
      this.baselineJson = JSON.stringify(this.s);
      this.setDirty(false);
      ensureBundledGeoAssets(this.context);
      this.geoOk = geoReady(this.context);
      this.refreshGeoInfos();
    } catch (e) {
      this.loadError = e instanceof Error ? e.message : `${e}`;
    } finally {
      this.loading = false;
    }
  }

  private refreshGeoInfos(): void {
    this.geoInfos = geoAssetInfos(this.context);
  }

  /** 全量下载比对:内容相同提示已最新,不同才替换(约 90KB)。 */
  async checkGeo(): Promise<void> {
    if (this.geoLoading) {
      return;
    }
    this.geoLoading = true;
    promptAction.showToast({ message: $r('app.string.geo_checking') });
    try {
      const updated = await checkGeoAssets(this.context);
      this.geoOk = geoReady(this.context);
      this.refreshGeoInfos();
      promptAction.showToast({
        message: updated.updated > 0 ? $r('app.string.geo_update_complete') : $r('app.string.geo_up_to_date')
      });
    } catch (e) {
      const msg = e instanceof Error ? e.message : `${e}`;
      promptAction.showToast({ message: $r('app.string.download_failed_reason', msg) });
    } finally {
      this.geoLoading = false;
    }
  }

  /** 恢复内置库(用户删除后手动触发) */
  restoreGeo(): void {
    if (this.geoLoading) {
      return;
    }
    this.geoLoading = true;
    try {
      restoreBundledGeoAssets(this.context);
      this.geoOk = geoReady(this.context);
      this.refreshGeoInfos();
      promptAction.showToast({ message: $r('app.string.geo_restore_complete') });
    } catch (e) {
      const msg = e instanceof Error ? e.message : `${e}`;
      promptAction.showToast({ message: $r('app.string.geo_restore_failed', msg) });
    } finally {
      this.geoLoading = false;
    }
  }

  /** 单库检查更新(对齐安卓资产列表点击单库更新) */
  async checkSingleGeo(kind: string): Promise<void> {
    if (this.geoLoading) {
      return;
    }
    this.geoLoading = true;
    try {
      const updated = await checkGeoAsset(this.context, kind);
      this.geoOk = geoReady(this.context);
      this.refreshGeoInfos();
      promptAction.showToast({
        message: updated
          ? $r('app.string.settings_geo_updated', kind === 'site' ? 'geosite-cn.srs' : 'geoip-cn.srs')
          : $r('app.string.geo_up_to_date')
      });
    } catch (e) {
      const msg = e instanceof Error ? e.message : `${e}`;
      promptAction.showToast({ message: $r('app.string.download_failed_reason', msg) });
    } finally {
      this.geoLoading = false;
    }
  }

  /** 删除单库(对齐安卓资产左滑删除;二次确认) */
  confirmDeleteGeo(info: GeoAssetInfo): void {
    AlertDialog.show({
      message: $r('app.string.settings_geo_delete_confirm', info.fileName),
      primaryButton: { value: $r('app.string.cancel'), action: () => {} },
      secondaryButton: {
        value: $r('app.string.delete'),
        fontColor: $r('app.color.error'),
        action: () => {
          try {
            deleteGeoAsset(this.context, info.kind);
            this.geoOk = geoReady(this.context);
            this.refreshGeoInfos();
            promptAction.showToast({ message: $r('app.string.settings_geo_deleted', info.fileName) });
          } catch (e) {
            const msg = e instanceof Error ? e.message : `${e}`;
            promptAction.showToast({ message: $r('app.string.settings_geo_delete_failed', msg) });
          }
        }
      }
    });
  }

  /** 导入用户自选的 geo .db(对齐安卓 AssetsActivity 的 action_import_file) */
  async importGeo(): Promise<void> {
    if (this.geoLoading) {
      return;
    }
    this.geoLoading = true;
    try {
      const path = await importGeoAssetFromFile(this.context);
      if (path === null) {
        // 用户取消选择,不报错
        return;
      }
      this.geoOk = geoReady(this.context);
      this.refreshGeoInfos();
      promptAction.showToast({ message: $r('app.string.geo_import_complete', path) });
    } catch (e) {
      const msg = e instanceof Error ? e.message : `${e}`;
      promptAction.showToast({ message: $r('app.string.geo_import_failed', msg) });
    } finally {
      this.geoLoading = false;
    }
  }

  modeIndex(): number {
    const i = MODES.indexOf(this.s.mode);
    return i < 0 ? 0 : i;
  }

  private colorToString(color: number): string {
    return `#${(color >>> 0).toString(16).padStart(8, '0').toUpperCase()}`;
  }

  private async applyAppearance(): Promise<void> {
    try {
      await saveSettings(this.s);
      this.baselineJson = JSON.stringify(this.s);
      this.setDirty(false);
      const colorMode = this.s.appearance === 'dark'
        ? ConfigurationConstant.ColorMode.COLOR_MODE_DARK
        : (this.s.appearance === 'light'
          ? ConfigurationConstant.ColorMode.COLOR_MODE_LIGHT
          : ConfigurationConstant.ColorMode.COLOR_MODE_NOT_SET);
      this.context.setColorMode(colorMode);
      /* 窗口底色与系统栏颜色**不要在这里写**（真机 2026-10-17：切换深浅色时状态栏不实时变深）。
         原来这里 setColorMode 后立刻 getColorSync 读资源 —— 色彩模式是异步生效的，那一刻读到的
         还是旧模式的颜色，把过时的浅色写回状态栏，且落在 EntryAbility.onConfigurationUpdate →
         syncWindowAppearance 的正确写入**之后**（竞态，过时写入赢）⇒ 状态栏保持白色，直到切走
         应用再回来（onForeground 重跑一次）才变深。
         现在只下发 setColorMode，窗口/系统栏统一由 onConfigurationUpdate → syncWindowAppearance
         实时收敛（深色下状态栏直接用主题底色实色，见 EntryAbility 的注释）。 */
      this.onSettingsChanged(this.s);
    } catch (e) {
      const message = e instanceof Error ? e.message : `${e}`;
      LogStore.addLog(`[ui] 即时应用主题失败: ${message}`);
      promptAction.showToast({ message: $r('app.string.save_failed_reason', message) });
    }
  }

  private markDirty(): void {
    /* 与已保存内容比对,避免控件初始化/重新展开触发的同值 onChange 把按钮误点亮 */
    this.setDirty(JSON.stringify(this.s) !== this.baselineJson);
  }

  async save(quiet: boolean = false): Promise<void> {
    try {
      await saveSettings(this.s);
      this.baselineJson = JSON.stringify(this.s);
      this.setDirty(false);
      this.onSettingsChanged(this.s);
      if (!quiet) {
        promptAction.showToast({ message: $r('app.string.saved_reconnect_vpn') });
      }
    } catch (e) {
      promptAction.showToast({ message: $r('app.string.save_failed_reason', e instanceof Error ? e.message : `${e}`) });
    }
  }

  private async switchMode(mode: string, toast: Resource): Promise<void> {
    if (this.s.mode === mode) {
      return;
    }
    this.s.mode = mode;
    try {
      await saveSettings(this.s);
      this.baselineJson = JSON.stringify(this.s);
      this.setDirty(false);
      this.onSettingsChanged(this.s);
      promptAction.showToast({ message: toast });
      const running: boolean = AppStorage.get<boolean>('vpnRunning') ?? false;
      const profileId: string = AppStorage.get<string>('vpnRunningProfileId') ?? '';
      if (running && profileId.length > 0) {
        AppStorage.setOrCreate('vpnStatus', 'switching');
        LogStore.addLog(`[ui] 出站模式切换为 ${mode}，自动重启 VPN`);
        await VpnService.switchTo(this.context, profileId);
      }
    } catch (e) {
      const message = e instanceof Error ? e.message : `${e}`;
      promptAction.showToast({ message: $r('app.string.save_failed_reason', message) });
    }
  }

  private selectedAppSet(): Set<string> {
    const result = new Set<string>();
    const parts = this.s.perAppList.split(',');
    for (const part of parts) {
      const bundleName = part.trim();
      if (bundleName.length > 0) {
        result.add(bundleName);
      }
    }
    return result;
  }

  private isAppSelected(bundleName: string): boolean {
    return this.selectedAppSet().has(bundleName);
  }

  private toggleInstalledApp(bundleName: string, selected: boolean): void {
    const chosen = this.selectedAppSet();
    if (selected) {
      chosen.add(bundleName);
    } else {
      chosen.delete(bundleName);
    }
    this.s.perAppList = Array.from(chosen).sort().join(',');
    this.markDirty();
  }

  private filteredInstalledApps(): Array<InstalledAppItem> {
    const query = this.appSearch.trim().toLowerCase();
    if (query.length === 0) {
      return this.installedApps;
    }
    return this.installedApps.filter((item: InstalledAppItem) =>
      item.label.toLowerCase().includes(query) || item.bundleName.toLowerCase().includes(query));
  }

  /** 反选已加载的应用(对齐安卓 action_invert_selections) */
  async invertAppSelections(): Promise<void> {
    const chosen = this.selectedAppSet();
    for (const item of this.installedApps) {
      if (chosen.has(item.bundleName)) {
        chosen.delete(item.bundleName);
      } else {
        chosen.add(item.bundleName);
      }
    }
    this.s.perAppList = Array.from(chosen).sort().join(',');
    await this.persistPerAppList('反选应用列表');
  }

  /** 清除全部已选应用(对齐安卓 action_clear_selections) */
  async clearAppSelections(): Promise<void> {
    if (this.s.perAppList.length === 0) {
      return;
    }
    this.s.perAppList = '';
    await this.persistPerAppList('清除应用列表');
  }

  /**
   * 导出已选应用列表到剪贴板(对齐安卓 AppListActivity.action_export_clipboard):
   * 格式为 "false\n<包名,逗号分隔>"(首行 false = 非 bypass 语义标记)。
   */
  async exportAppListToClipboard(): Promise<void> {
    const payload = `false\n${this.s.perAppList}`;
    try {
      await setClipboardText(payload);
      promptAction.showToast({ message: $r('app.string.action_export_msg') });
    } catch (e) {
      promptAction.showToast({ message: $r('app.string.action_export_err') });
    }
  }

  /**
   * 从剪贴板导入应用列表(对齐安卓 action_import_clipboard):
   * 期望 "false\n<包名列表>" 格式;无换行则报错,有换行取首行之后全部。
   */
  async importAppListFromClipboard(): Promise<void> {
    const clip = await getClipboardText();
    const nl = clip.indexOf('\n');
    if (clip.trim().length === 0 || nl < 0) {
      promptAction.showToast({ message: $r('app.string.action_import_err') });
      return;
    }
    const apps = clip.substring(nl + 1).trim();
    this.s.perAppList = apps;
    await this.persistPerAppList('从剪贴板导入应用列表');
    promptAction.showToast({ message: $r('app.string.action_import_msg') });
  }

  private async persistPerAppList(reason: string): Promise<void> {
    this.markDirty();
    await this.save(true);
    const running: boolean = AppStorage.get<boolean>('vpnRunning') ?? false;
    const profileId: string = AppStorage.get<string>('vpnRunningProfileId') ?? '';
    if (running && profileId.length > 0) {
      LogStore.addLog(`[ui] ${reason}，自动重启 VPN 使配置生效`);
      await VpnService.switchTo(this.context, profileId);
    }
  }

  async loadInstalledApps(): Promise<void> {
    if (this.appListLoading) {
      return;
    }
    this.appListLoading = true;
    this.appListError = '';
    try {
      const infos = await bundle.getAllBundleInfo(bundle.BundleFlag.GET_BUNDLE_DEFAULT);
      const apps: Array<InstalledAppItem> = [];
      for (const info of infos) {
        const bundleName: string = info.name;
        const label: string = info.appInfo === undefined || info.appInfo.label.length === 0
          ? bundleName : info.appInfo.label;
        apps.push(new InstalledAppItem(bundleName, label));
      }
      apps.sort((a: InstalledAppItem, b: InstalledAppItem) => a.label.localeCompare(b.label));
      this.installedApps = apps;
      if (apps.length === 0) {
        this.appListError = $r('app.string.no_installed_apps_manual');
      }
    } catch (e) {
      const message = e instanceof Error ? e.message : `${e}`;
      this.installedApps = [];
      this.appListError = $r('app.string.app_list_failed_reason', message);
      LogStore.addLog(`[ui] 枚举已安装应用失败，降级为手动输入: ${message}`);
    } finally {
      this.appListLoading = false;
    }
  }

  /** 可折叠分组章节头:与设置首页二级入口同款(淡蓝圆角图标 + 标题/描述 + 箭头) */
  @Builder
  private sectionHeader(icon: Resource, title: ResourceStr, desc: ResourceStr, expanded: boolean, onToggle: () => void) {
    Row({ space: 14 }) {
      Row() {
        SymbolGlyph(icon)
          .fontSize(19)
          .fontColor([$r('app.color.primary')])
      }
      .width(38)
      .height(38)
      .justifyContent(FlexAlign.Center)
      .borderRadius(11)
      .backgroundColor($r('app.color.surface_selected'))

      Column({ space: 3 }) {
        Text(title)
          .fontSize(15)
          .fontWeight(600)
          .fontColor($r('app.color.text_1'))
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .width('100%')
        Text(desc)
          .fontSize(11.5)
          .fontColor($r('app.color.text_3'))
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .width('100%')
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1)

      SymbolGlyph(expanded ? $r('sys.symbol.chevron_up') : $r('sys.symbol.chevron_down'))
        .fontSize(16)
        .fontColor([$r('app.color.text_3')])
    }
    .width('100%')
    .padding({ top: 12, bottom: 12 })
    .border({ width: { bottom: expanded ? UiSpec.HAIRLINE_WIDTH : 0 }, color: $r('app.color.hairline') })
    /* HDS 点按光效:这一行本来就可点(onClick(onToggle)),只补"按下那一刻发光"。
       光源宿主白名单里有 Row、没有 Text —— 所以宿主保持 Row(图标 Text 已换成 SymbolGlyph)。
       key 用 icon.id(Resource.id 是必填 number,每个章节的符号资源 id 唯一)。 */
    .visualEffect(pressLightEffect(this.litKey === `sec:${icon.id}`, false))
    .onTouch((event: TouchEvent) => {
      if (event.type === TouchType.Down) {
        this.litKey = `sec:${icon.id}`;
      } else if (event.type === TouchType.Up || event.type === TouchType.Cancel) {
        this.litKey = '';
      }
    })
    .onClick(onToggle)
  }

  build() {
    Scroll(this.scroller) {
      Column({ space: 12 }) {
        /* 顶部让位:内容从 HDS 顶栏后面滚出来 —— 与订阅页同一套滚动沉浸光感。
           (高度扣掉 Column 的 space,首项仍落在顶栏底边下方) */
        Row().width('100%').height(Math.max(0, this.contentTopInset - 14))
        if (this.loading) {
          Column({ space: 10 }) {
            LoadingProgress()
              .width(32)
              .height(32)
              .color($r('app.color.primary'))
            Text($r('app.string.loading_settings'))
              .fontSize(13)
              .fontColor($r('app.color.text_secondary'))
          }
          .width('100%')
          .padding({ top: 36, bottom: 20 })
        } else if (this.loadError.length > 0) {
          Column({ space: 8 }) {
            Text($r('app.string.settings_load_failed'))
              .fontSize(16)
              .fontWeight(500)
              .fontColor($r('app.color.text_primary'))
            Text(this.loadError)
              .fontSize(13)
              .fontColor($r('app.color.error'))
            Button($r('app.string.reload'))
              .height(36)
              .backgroundColor($r('app.color.primary'))
              .visualEffect(pressLightEffect(this.litKey === 'reload', true))
              .onTouch((event: TouchEvent) => {
                if (event.type === TouchType.Down) {
          this.litKey = 'reload';
        } else if (event.type === TouchType.Up || event.type === TouchType.Cancel) {
          this.litKey = '';
        }
              })
              .onClick(() => this.load())
          }
          .width('100%')
          .padding({ top: 28, bottom: 20 })
        }
          // 常规(对齐 Android General 组)
          Column({ space: 16 }) {
          this.sectionHeader($r('sys.symbol.gearshape'), $r('app.string.settings_general'), $r('app.string.settings_general_desc'), this.generalExpanded, () => { this.generalExpanded = !this.generalExpanded; })
          if (this.generalExpanded) {
          Column({ space: 16 }) {
            Row() {
              Column({ space: 2 }) {
                Text($r('app.string.settings_auto_connect')).fontSize(15).fontColor($r('app.color.text_1'))
                Text($r('app.string.settings_auto_connect_desc')).fontSize(12).lineHeight(18).fontColor($r('app.color.text_secondary'))
              }.alignItems(HorizontalAlign.Start).layoutWeight(1)
              Toggle({ type: ToggleType.Switch, isOn: this.s.autoConnect })
                .onChange((v: boolean) => {
                  this.s.autoConnect = v;
                  this.markDirty();
                })
            }.width('100%')

            Column({ space: 8 }) {
              Text($r('app.string.settings_log_level')).fontSize(14).fontColor($r('app.color.text_1')).width('100%')
              Select(LOG_LEVELS.map((t: string) => ({ value: t } as SelectOption)))
                .selected(LOG_LEVELS.indexOf(this.s.logLevel) < 0 ? 2 : LOG_LEVELS.indexOf(this.s.logLevel))
                .value(this.s.logLevel)
                .controlSize(ControlSize.SMALL)
                .onSelect((index: number) => {
                  this.s.logLevel = LOG_LEVELS[index];
                  this.markDirty();
                })
            }.alignItems(HorizontalAlign.Start).width('100%')

            Column({ space: 8 }) {
              Text($r('app.string.latency_test_mode')).fontSize(14).fontColor($r('app.color.text_1')).width('100%')
              Select(LATENCY_TEST_LABELS.map((t: Resource, i: number) => ({ value: t } as SelectOption)))
                .selected(LATENCY_TEST_VALUES.indexOf(this.s.latencyTestMode) < 0 ? 0 : LATENCY_TEST_VALUES.indexOf(this.s.latencyTestMode))
                .value(LATENCY_TEST_LABELS[LATENCY_TEST_VALUES.indexOf(this.s.latencyTestMode) < 0 ? 0 : LATENCY_TEST_VALUES.indexOf(this.s.latencyTestMode)])
                .controlSize(ControlSize.SMALL)
                .onSelect((index: number) => {
                  this.s.latencyTestMode = LATENCY_TEST_VALUES[index];
                  this.markDirty();
                })
              Text($r('app.string.latency_test_mode_desc'))
                .fontSize(12).lineHeight(18).fontColor($r('app.color.text_secondary')).width('100%')
            }.alignItems(HorizontalAlign.Start).width('100%')

            Column({ space: 8 }) {
              Text($r('app.string.settings_test_url')).fontSize(14).fontColor($r('app.color.text_1')).width('100%')
              TextInput({ text: this.s.testUrl })
                .width('100%').height(40)
                .onChange((v: string) => {
                  this.s.testUrl = v;
                  this.markDirty();
                })
              Text($r('app.string.settings_test_url_desc'))
                .fontSize(12).lineHeight(18).fontColor($r('app.color.text_secondary')).width('100%')
            }.alignItems(HorizontalAlign.Start).width('100%')

            Column({ space: 8 }) {
              Text($r('app.string.settings_test_concurrent')).fontSize(14).fontColor($r('app.color.text_1')).width('100%')
              TextInput({ text: `${this.s.testConcurrent}` })
                .type(InputType.Number).width('100%').height(40)
                .onChange((v: string) => {
                  const n = parseInt(v);
                  this.s.testConcurrent = isNaN(n) ? 10 : Math.max(1, Math.min(32, n));
                  this.markDirty();
                })
            }.alignItems(HorizontalAlign.Start).width('100%')

            Column({ space: 8 }) {
              Text($r('app.string.settings_global_custom_config')).fontSize(14).fontColor($r('app.color.text_1')).width('100%')
              TextArea({ text: this.s.globalCustomConfig, placeholder: '{"log":{"level":"info"}}' })
                .height(90)
                .fontSize(12)
                .fontFamily('monospace')
                .width('100%')
                .onChange((v: string) => {
                  this.s.globalCustomConfig = v;
                  this.markDirty();
                })
              Text($r('app.string.settings_global_custom_config_desc'))
                .fontSize(12).lineHeight(18).fontColor($r('app.color.text_secondary')).width('100%')
            }.alignItems(HorizontalAlign.Start).width('100%')

            Row() {
              Text($r('app.string.settings_always_show_address')).fontSize(15).fontColor($r('app.color.text_1')).layoutWeight(1)
              Toggle({ type: ToggleType.Switch, isOn: this.s.alwaysShowAddress })
                .onChange((v: boolean) => {
                  this.s.alwaysShowAddress = v;
                  this.markDirty();
                })
            }.width('100%')

            Row() {
              Text($r('app.string.show_bottom_bar')).fontSize(15).fontColor($r('app.color.text_1')).layoutWeight(1)
              Toggle({ type: ToggleType.Switch, isOn: this.s.showBottomBar })
                .onChange((v: boolean) => {
                  this.s.showBottomBar = v;
                  this.markDirty();
                })
            }.width('100%')

            Row() {
              Column({ space: 2 }) {
                Text($r('app.string.settings_speed_interval')).fontSize(15).fontColor($r('app.color.text_1')).width('100%')
                Text($r('app.string.settings_speed_interval_sum'))
                  .fontSize(12).lineHeight(18).fontColor($r('app.color.text_secondary')).width('100%')
              }.alignItems(HorizontalAlign.Start).layoutWeight(1)
              TextInput({ text: `${this.s.speedIntervalMs}`, placeholder: '1000' })
                .type(InputType.Number).width(110).height(36)
                .onChange((v: string) => {
                  const n = parseInt(v, 10);
                  this.s.speedIntervalMs = isNaN(n) ? 1000 : n;
                  this.markDirty();
                })
            }.width('100%')

            Row() {
              Column({ space: 2 }) {
                Text($r('app.string.settings_insecure_tls')).fontSize(15).fontColor($r('app.color.text_1'))
                Text($r('app.string.settings_insecure_tls_desc')).fontSize(12).lineHeight(18).fontColor($r('app.color.text_secondary'))
              }.alignItems(HorizontalAlign.Start).layoutWeight(1)
              Toggle({ type: ToggleType.Switch, isOn: this.s.allowInsecureAll })
                .onChange((v: boolean) => {
                  this.s.allowInsecureAll = v;
                  this.markDirty();
                })
            }.width('100%')

            Row() {
              Column({ space: 2 }) {
                Text($r('app.string.settings_sub_allow_insecure')).fontSize(15).fontColor($r('app.color.text_1'))
                Text($r('app.string.settings_sub_allow_insecure_desc')).fontSize(12).lineHeight(18).fontColor($r('app.color.text_secondary'))
              }.alignItems(HorizontalAlign.Start).layoutWeight(1)
              Toggle({ type: ToggleType.Switch, isOn: this.s.subAllowInsecure })
                .onChange((v: boolean) => {
                  this.s.subAllowInsecure = v;
                  this.markDirty();
                })
            }.width('100%')
          }.alignItems(HorizontalAlign.Start).width('100%')
          }
          }
          .width('100%')
          .padding({ left: 14, right: 14, bottom: this.generalExpanded ? 16 : 0 })
          .backgroundColor($r('app.color.surface'))
          .borderRadius(14)
          .shadow({ radius: 6, color: $r('app.color.shadow_color'), offsetY: 1 })

          // 路由
          Column({ space: 16 }) {
          this.sectionHeader($r('sys.symbol.arrow_up_left_and_arrow_down_right'), $r('app.string.settings_route'), $r('app.string.settings_route_desc'), this.networkExpanded, () => { this.networkExpanded = !this.networkExpanded; })
          if (this.networkExpanded) {
          if (this.s.mode === 'rule') {
            Column({ space: 20 }) {
              Column({ space: 8 }) {
                Text($r('app.string.settings_direct_domain_suffix')).fontSize(14).fontColor($r('app.color.text_1')).width('100%')
                TextInput({ text: this.s.directDomains, placeholder: 'baidu.com,qq.com,163.com' })
                  .width('100%').height(40)
                  .onChange((v: string) => {
                    this.s.directDomains = v;
                    this.markDirty();
                  })
              }.alignItems(HorizontalAlign.Start).width('100%')

              Column({ space: 8 }) {
                Text($r('app.string.settings_direct_cidr')).fontSize(14).fontColor($r('app.color.text_1')).width('100%')
                TextInput({ text: this.s.directIpCidrs, placeholder: '114.114.114.114/32' })
                  .width('100%').height(40)
                  .onChange((v: string) => {
                    this.s.directIpCidrs = v;
                    this.markDirty();
                  })
              }.alignItems(HorizontalAlign.Start).width('100%')

              /* Geo 资源:独立成块,按官方设置项节奏排布(上下 12vp、行间 1vp 分隔线)。
                 块内只保留一个实心主按钮,导入/更新/删除降级为文字按钮,避免按钮抢视觉。 */
              Column({ space: 0 }) {
                Row({ space: 12 }) {
                  Text(this.geoOk ? $r('app.string.settings_geo_ready')
                    : $r('app.string.settings_geo_missing'))
                    .fontSize(14)
                    .fontColor(this.geoOk ? $r('app.color.success') : $r('app.color.text_1'))
                    .layoutWeight(1)
                    .maxLines(2)
                  Button(this.geoLoading ? $r('app.string.settings_geo_checking') : (this.geoOk ? $r('app.string.settings_geo_check_update') : $r('app.string.settings_geo_restore')))
                    .height(32)
                    .fontSize(14)
                    .padding({ left: 12, right: 12 })
                    .backgroundColor(this.geoLoading ? $r('app.color.control_disabled') : $r('app.color.primary'))
                    .visualEffect(pressLightEffect(this.litKey === 'geo:check', true))
                    .onTouch((event: TouchEvent) => {
                      if (event.type === TouchType.Down) {
                        this.litKey = 'geo:check';
                      } else if (event.type === TouchType.Up || event.type === TouchType.Cancel) {
                        this.litKey = '';
                      }
                    })
                    .onClick(() => {
                      if (this.geoOk) {
                        void this.checkGeo();
                      } else {
                        this.restoreGeo();
                      }
                    })
                }
                .width('100%')
                .padding({ top: 12, bottom: 12 })

                Row({ space: 12 }) {
                  Text($r('app.string.settings_geo_import_hint'))
                    .fontSize(14)
                    .fontColor($r('app.color.text_1'))
                    .layoutWeight(1)
                    .maxLines(2)
                  Button($r('app.string.settings_geo_import'))
                    .height(32)
                    .fontSize(14)
                    .padding({ left: 8, right: 8 })
                    .backgroundColor(Color.Transparent)
                    .fontColor($r('app.color.primary'))
                    .enabled(!this.geoLoading)
                    .visualEffect(pressLightEffect(this.litKey === 'geo:import', true))
                    .onTouch((event: TouchEvent) => {
                      if (event.type === TouchType.Down) {
                        this.litKey = 'geo:import';
                      } else if (event.type === TouchType.Up || event.type === TouchType.Cancel) {
                        this.litKey = '';
                      }
                    })
                    .onClick(() => { void this.importGeo(); })
                }
                .width('100%')
                .padding({ top: 12, bottom: 12 })
                .border({ width: { top: UiSpec.HAIRLINE_WIDTH }, color: $r('app.color.hairline') })

                // 资产列表(对齐安卓 AssetsActivity:每库名称/大小/版本 + 单库更新/删除)
                ForEach(this.geoInfos, (info: GeoAssetInfo, index: number) => {
                  Row({ space: 8 }) {
                    Column({ space: 2 }) {
                      Text(info.kind === 'site' ? $r('app.string.settings_geo_site') : $r('app.string.settings_geo_ip'))
                        .fontSize(15).fontColor($r('app.color.text_1')).width('100%')
                      Text(info.size > 0
                        ? (info.bundled
                          ? $r('app.string.geo_asset_bundled_status', formatBytes(info.size))
                          : $r('app.string.geo_asset_status', formatBytes(info.size), info.version))
                        : $r('app.string.geo_asset_absent'))
                        .fontSize(12).fontColor($r('app.color.text_3')).width('100%')
                    }.alignItems(HorizontalAlign.Start).layoutWeight(1)

                    Button(this.geoLoading ? $r('app.string.settings_geo_checking') : $r('app.string.settings_geo_update_one'))
                      .height(32)
                      .fontSize(14)
                      .padding({ left: 8, right: 8 })
                      .backgroundColor(Color.Transparent)
                      .fontColor(this.geoLoading ? $r('app.color.text_3') : $r('app.color.primary'))
                      .enabled(!this.geoLoading)
                      .visualEffect(pressLightEffect(this.litKey === `geo:update:${info.kind}`, true))
                      .onTouch((event: TouchEvent) => {
                        if (event.type === TouchType.Down) {
                          this.litKey = `geo:update:${info.kind}`;
                        } else if (event.type === TouchType.Up || event.type === TouchType.Cancel) {
                          this.litKey = '';
                        }
                      })
                      .onClick(() => { void this.checkSingleGeo(info.kind); })
                    if (info.size > 0) {
                      Button($r('app.string.settings_geo_delete'))
                        .height(32)
                        .fontSize(14)
                        .padding({ left: 8, right: 8 })
                        .backgroundColor(Color.Transparent)
                        .fontColor($r('app.color.error'))
                        .enabled(!this.geoLoading)
                        .visualEffect(pressLightEffect(this.litKey === `geo:delete:${info.kind}`, true))
                        .onTouch((event: TouchEvent) => {
                          if (event.type === TouchType.Down) {
                            this.litKey = `geo:delete:${info.kind}`;
                          } else if (event.type === TouchType.Up || event.type === TouchType.Cancel) {
                            this.litKey = '';
                          }
                        })
                        .onClick(() => this.confirmDeleteGeo(info))
                    }
                  }
                  .width('100%')
                  .padding({ top: 12, bottom: 12 })
                  .border({ width: { top: UiSpec.HAIRLINE_WIDTH }, color: $r('app.color.hairline') })
                }, (info: GeoAssetInfo) => `${info.kind}_${info.size}_${info.version}`)
              }
              .width('100%')
              .border({ width: { top: UiSpec.HAIRLINE_WIDTH }, color: $r('app.color.hairline') })
            }.alignItems(HorizontalAlign.Start).width('100%')
          }

          Column({ space: 8 }) {
            Text($r('app.string.settings_tun_mtu')).fontSize(14).fontColor($r('app.color.text_1')).width('100%')
            TextInput({ text: `${this.s.mtu}`, placeholder: '9000' })
              .type(InputType.Number).width('100%').height(40)
              .onChange((v: string) => {
                const n = parseInt(v);
                this.s.mtu = isNaN(n) ? 9000 : n;
                this.markDirty();
              })
          }.alignItems(HorizontalAlign.Start).width('100%')

          Column({ space: 8 }) {
            Text($r('app.string.settings_tun_stack')).fontSize(14).fontColor($r('app.color.text_1')).width('100%')
            Select(STACKS.map((t: string) => ({ value: t } as SelectOption)))
              .selected(STACKS.indexOf(this.s.stack) < 0 ? 0 : STACKS.indexOf(this.s.stack))
              .value(this.s.stack)
              .controlSize(ControlSize.SMALL)
              .onSelect((index: number) => {
                this.s.stack = STACKS[index];
                this.markDirty();
              })
          }.alignItems(HorizontalAlign.Start).width('100%')

          Column({ space: 8 }) {
            Text($r('app.string.settings_enable_ipv6')).fontSize(14).fontColor($r('app.color.text_1')).width('100%')
            Select(IPV6_MODES.map((t: string, i: number) => ({ value: IPV6_MODE_LABELS[i] } as SelectOption)))
              .selected(IPV6_MODES.indexOf(this.s.ipv6Mode) < 0 ? (this.s.ipv6 ? 1 : 0) : IPV6_MODES.indexOf(this.s.ipv6Mode))
              .value(IPV6_MODE_LABELS[(IPV6_MODES.indexOf(this.s.ipv6Mode) < 0 ? (this.s.ipv6 ? 1 : 0) : IPV6_MODES.indexOf(this.s.ipv6Mode))])
              .controlSize(ControlSize.SMALL)
              .onSelect((index: number) => {
                this.s.ipv6Mode = IPV6_MODES[index];
                this.markDirty();
              })
          }.alignItems(HorizontalAlign.Start).width('100%')

          Row() {
            Column({ space: 2 }) {
              Text($r('app.string.settings_bypass_lan')).fontSize(15).fontColor($r('app.color.text_1'))
              Text($r('app.string.settings_bypass_lan_desc')).fontSize(12).lineHeight(18).fontColor($r('app.color.text_secondary'))
            }.alignItems(HorizontalAlign.Start).layoutWeight(1)
            Toggle({ type: ToggleType.Switch, isOn: this.s.bypassLan })
              .onChange((v: boolean) => {
                this.s.bypassLan = v;
                this.markDirty();
              })
          }.width('100%')

          Column({ space: 8 }) {
            Text($r('app.string.settings_sniff')).fontSize(14).fontColor($r('app.color.text_1')).width('100%')
            Row({ space: 8 }) {
              ForEach(SNIFF_MODES, (m: string, idx: number) => {
                Button(SNIFF_LABELS[idx])
                  .layoutWeight(1)
                  .height(32)
                  .fontSize(14)
                  .backgroundColor(this.s.sniffMode === m ? $r('app.color.primary') : $r('app.color.app_background'))
                  .fontColor(this.s.sniffMode === m ? $r('app.color.surface') : $r('app.color.text_primary'))
                  .visualEffect(pressLightEffect(this.litKey === `sniff:${m}`, true))
                  .onTouch((event: TouchEvent) => {
                    if (event.type === TouchType.Down) {
                      this.litKey = `sniff:${m}`;
                    } else if (event.type === TouchType.Up || event.type === TouchType.Cancel) {
                      this.litKey = '';
                    }
                  })
                  .onClick(() => {
                    this.s.sniffMode = m;
                    this.markDirty();
                  })
              }, (m: string) => m)
            }.width('100%')
          }.alignItems(HorizontalAlign.Start).width('100%')

          Row() {
            Column({ space: 2 }) {
              Text($r('app.string.settings_resolve_destination')).fontSize(15).fontColor($r('app.color.text_1'))
              Text($r('app.string.settings_resolve_destination_desc')).fontSize(12).lineHeight(18).fontColor($r('app.color.text_secondary'))
            }.alignItems(HorizontalAlign.Start).layoutWeight(1)
            Toggle({ type: ToggleType.Switch, isOn: this.s.resolveDestination })
              .onChange((v: boolean) => {
                this.s.resolveDestination = v;
                this.markDirty();
              })
          }.width('100%')
          }
          }
          .width('100%')
          .padding({ left: 14, right: 14, bottom: this.networkExpanded ? 16 : 0 })
          .backgroundColor($r('app.color.surface'))
          .borderRadius(14)
          .shadow({ radius: 6, color: $r('app.color.shadow_color'), offsetY: 1 })

          // DNS(对齐 Android DNS 组)
          Column({ space: 16 }) {
          this.sectionHeader($r('sys.symbol.cloud'), $r('app.string.settings_dns'), $r('app.string.settings_dns_desc'), this.dnsExpanded, () => { this.dnsExpanded = !this.dnsExpanded; })
          if (this.dnsExpanded) {
          Column({ space: 16 }) {
            Column({ space: 8 }) {
              Text($r('app.string.settings_remote_dns')).fontSize(14).fontColor($r('app.color.text_1')).width('100%')
              TextInput({ text: this.s.remoteDns })
                .width('100%').height(40)
                .onChange((v: string) => {
                  this.s.remoteDns = v;
                  this.markDirty();
                })
              Text($r('app.string.settings_remote_dns_hint'))
                .fontSize(12).lineHeight(18).fontColor($r('app.color.text_secondary')).width('100%')
            }.alignItems(HorizontalAlign.Start).width('100%')

            Column({ space: 8 }) {
              Text($r('app.string.settings_remote_dns_strategy')).fontSize(14).fontColor($r('app.color.text_1')).width('100%')
              Select(STRATEGIES.map((t: string, i: number) => ({ value: STRATEGY_LABELS[i] } as SelectOption)))
                .selected(STRATEGIES.indexOf(this.s.remoteDnsStrategy) < 0 ? 0 : STRATEGIES.indexOf(this.s.remoteDnsStrategy))
                .value(STRATEGY_LABELS[STRATEGIES.indexOf(this.s.remoteDnsStrategy) < 0 ? 0 : STRATEGIES.indexOf(this.s.remoteDnsStrategy)])
                .controlSize(ControlSize.SMALL)
                .onSelect((index: number) => {
                  this.s.remoteDnsStrategy = STRATEGIES[index];
                  this.markDirty();
                })
            }.alignItems(HorizontalAlign.Start).width('100%')

            Column({ space: 8 }) {
              Text($r('app.string.settings_direct_dns')).fontSize(14).fontColor($r('app.color.text_1')).width('100%')
              TextInput({ text: this.s.directDns })
                .width('100%').height(40)
                .onChange((v: string) => {
                  this.s.directDns = v;
                  this.markDirty();
                })
            }.alignItems(HorizontalAlign.Start).width('100%')

            Column({ space: 8 }) {
              Text($r('app.string.settings_direct_dns_strategy')).fontSize(14).fontColor($r('app.color.text_1')).width('100%')
              Select(STRATEGIES.map((t: string, i: number) => ({ value: STRATEGY_LABELS[i] } as SelectOption)))
                .selected(STRATEGIES.indexOf(this.s.directDnsStrategy) < 0 ? 0 : STRATEGIES.indexOf(this.s.directDnsStrategy))
                .value(STRATEGY_LABELS[STRATEGIES.indexOf(this.s.directDnsStrategy) < 0 ? 0 : STRATEGIES.indexOf(this.s.directDnsStrategy)])
                .controlSize(ControlSize.SMALL)
                .onSelect((index: number) => {
                  this.s.directDnsStrategy = STRATEGIES[index];
                  this.markDirty();
                })
            }.alignItems(HorizontalAlign.Start).width('100%')

            Column({ space: 8 }) {
              Text($r('app.string.settings_server_dns_strategy')).fontSize(14).fontColor($r('app.color.text_1')).width('100%')
              Select(STRATEGIES.map((t: string, i: number) => ({ value: STRATEGY_LABELS[i] } as SelectOption)))
                .selected(STRATEGIES.indexOf(this.s.serverDnsStrategy) < 0 ? 0 : STRATEGIES.indexOf(this.s.serverDnsStrategy))
                .value(STRATEGY_LABELS[STRATEGIES.indexOf(this.s.serverDnsStrategy) < 0 ? 0 : STRATEGIES.indexOf(this.s.serverDnsStrategy)])
                .controlSize(ControlSize.SMALL)
                .onSelect((index: number) => {
                  this.s.serverDnsStrategy = STRATEGIES[index];
                  this.markDirty();
                })
              Text($r('app.string.settings_server_dns_strategy_hint'))
                .fontSize(12).lineHeight(18).fontColor($r('app.color.text_secondary')).width('100%')
            }.alignItems(HorizontalAlign.Start).width('100%')

            Row() {
              Column({ space: 2 }) {
                Text($r('app.string.settings_dns_routing')).fontSize(15).fontColor($r('app.color.text_1'))
                Text($r('app.string.settings_dns_routing_desc')).fontSize(12).lineHeight(18).fontColor($r('app.color.text_secondary'))
              }.alignItems(HorizontalAlign.Start).layoutWeight(1)
              Toggle({ type: ToggleType.Switch, isOn: this.s.dnsRouting })
                .onChange((v: boolean) => {
                  this.s.dnsRouting = v;
                  this.markDirty();
                })
            }.width('100%')

            Row() {
              Column({ space: 2 }) {
                Text($r('app.string.settings_fakedns')).fontSize(15).fontColor($r('app.color.text_1'))
                Text($r('app.string.settings_fakedns_desc')).fontSize(12).lineHeight(18).fontColor($r('app.color.text_secondary'))
              }.alignItems(HorizontalAlign.Start).layoutWeight(1)
              Toggle({ type: ToggleType.Switch, isOn: this.s.fakeDns })
                .onChange((v: boolean) => {
                  this.s.fakeDns = v;
                  this.markDirty();
                })
            }.width('100%')
          }.alignItems(HorizontalAlign.Start).width('100%')
          }
          }
          .width('100%')
          .padding({ left: 14, right: 14, bottom: this.dnsExpanded ? 16 : 0 })
          .backgroundColor($r('app.color.surface'))
          .borderRadius(14)
          .shadow({ radius: 6, color: $r('app.color.shadow_color'), offsetY: 1 })

          // 入站(对齐 Android Inbound 组)
          Column({ space: 16 }) {
          this.sectionHeader($r('sys.symbol.square_and_arrow_down'), $r('app.string.settings_inbound'), $r('app.string.settings_inbound_desc'), this.inboundExpanded, () => { this.inboundExpanded = !this.inboundExpanded; })
          if (this.inboundExpanded) {
          Column({ space: 16 }) {
            Column({ space: 8 }) {
              Text($r('app.string.settings_mixed_port')).fontSize(14).fontColor($r('app.color.text_1')).width('100%')
              TextInput({ text: `${this.s.mixedPort > 0 ? this.s.mixedPort : ''}`, placeholder: $r('app.string.settings_mixed_port_hint') })
                .type(InputType.Number).width('100%').height(40)
                .onChange((v: string) => {
                  const n = parseInt(v);
                  this.s.mixedPort = isNaN(n) ? 0 : Math.max(0, Math.min(65535, n));
                  this.markDirty();
                })
            }.alignItems(HorizontalAlign.Start).width('100%')

            Row() {
              Column({ space: 2 }) {
                Text($r('app.string.settings_allow_access')).fontSize(15).fontColor($r('app.color.text_1'))
                Text($r('app.string.settings_allow_access_desc')).fontSize(12).lineHeight(18).fontColor($r('app.color.text_secondary'))
              }.alignItems(HorizontalAlign.Start).layoutWeight(1)
              Toggle({ type: ToggleType.Switch, isOn: this.s.allowAccess })
                .onChange((v: boolean) => {
                  this.s.allowAccess = v;
                  this.markDirty();
                })
            }.width('100%')
            Text($r('app.string.settings_reconnect_note'))
              .fontSize(12).fontColor($r('app.color.error')).width('100%')
          }.alignItems(HorizontalAlign.Start).width('100%')
          }
          }
          .width('100%')
          .padding({ left: 14, right: 14, bottom: this.inboundExpanded ? 16 : 0 })
          .backgroundColor($r('app.color.surface'))
          .borderRadius(14)
          .shadow({ radius: 6, color: $r('app.color.shadow_color'), offsetY: 1 })

          // 外观与交互
          Column({ space: 16 }) {
          this.sectionHeader($r('sys.symbol.brightness'), $r('app.string.appearance_and_interaction'), $r('app.string.settings_appearance_desc'), this.appearanceExpanded, () => { this.appearanceExpanded = !this.appearanceExpanded; })
          if (this.appearanceExpanded) {
          Column({ space: 16 }) {
            Row({ space: 8 }) {
              ForEach(['system', 'light', 'dark'], (mode: string) => {
                Button(mode === 'system' ? $r('app.string.appearance_follow_system') : (mode === 'light' ? $r('app.string.appearance_light') : $r('app.string.appearance_dark')))
                  .layoutWeight(1)
                  .height(32)
                  .fontSize(14)
                  .backgroundColor(this.s.appearance === mode ? $r('app.color.primary') : $r('app.color.app_background'))
                  .fontColor(this.s.appearance === mode ? $r('app.color.surface') : $r('app.color.text_primary'))
                  .visualEffect(pressLightEffect(this.litKey === `appearance:${mode}`, true))
                  .onTouch((event: TouchEvent) => {
                    if (event.type === TouchType.Down) {
                      this.litKey = `appearance:${mode}`;
                    } else if (event.type === TouchType.Up || event.type === TouchType.Cancel) {
                      this.litKey = '';
                    }
                  })
                  .onClick(() => {
                    this.s.appearance = mode;
                    this.applyAppearance();
                    this.markDirty();
                  })
              }, (mode: string) => mode)
            }.width('100%')
            Text($r('app.string.profile_sort_mode')).fontSize(14).fontColor($r('app.color.text_1')).width('100%')
            Row({ space: 8 }) {
              ForEach(['manual', 'latency', 'name'], (mode: string) => {
                Button(mode === 'manual' ? $r('app.string.sort_manual') : (mode === 'latency' ? $r('app.string.sort_latency') : $r('app.string.sort_name')))
                  .layoutWeight(1)
                  .height(32)
                  .fontSize(14)
                  .backgroundColor(this.s.profileSortMode === mode ? $r('app.color.primary') : $r('app.color.app_background'))
                  .fontColor(this.s.profileSortMode === mode ? $r('app.color.surface') : $r('app.color.text_primary'))
                  .visualEffect(pressLightEffect(this.litKey === `sort:${mode}`, true))
                  .onTouch((event: TouchEvent) => {
                    if (event.type === TouchType.Down) {
                      this.litKey = `sort:${mode}`;
                    } else if (event.type === TouchType.Up || event.type === TouchType.Cancel) {
                      this.litKey = '';
                    }
                  })
                  .onClick(() => {
                    this.s.profileSortMode = mode;
                    this.markDirty();
                  })
              }, (mode: string) => mode)
            }.width('100%')
            Row() {
              Text($r('app.string.haptic_feedback')).fontSize(15).fontColor($r('app.color.text_1')).layoutWeight(1)
              Toggle({ type: ToggleType.Switch, isOn: this.s.hapticFeedback })
                .onChange((v: boolean) => {
                  this.s.hapticFeedback = v;
                  this.markDirty();
                })
            }.width('100%')
            Row() {
              Text($r('app.string.liquid_glass')).fontSize(15).fontColor($r('app.color.text_1')).layoutWeight(1)
              Toggle({ type: ToggleType.Switch, isOn: this.s.liquidGlass })
                .onChange((v: boolean) => {
                  this.s.liquidGlass = v;
                  this.markDirty();
                })
            }.width('100%')
            Row() {
              Column({ space: 2 }) {
                Text($r('app.string.network_change_reset_connections')).fontSize(15).fontColor($r('app.color.text_1')).width('100%')
                Text($r('app.string.network_change_reset_connections_sum'))
                  .fontSize(12).lineHeight(18).fontColor($r('app.color.text_secondary')).width('100%')
              }.alignItems(HorizontalAlign.Start).layoutWeight(1)
              Toggle({ type: ToggleType.Switch, isOn: this.s.networkChangeResetConnections })
                .onChange((v: boolean) => {
                  this.s.networkChangeResetConnections = v;
                  this.markDirty();
                })
            }.width('100%')
            Row() {
              Column({ space: 2 }) {
                Text($r('app.string.wake_reset_connections')).fontSize(15).fontColor($r('app.color.text_1')).width('100%')
                Text($r('app.string.wake_reset_connections_sum'))
                  .fontSize(12).lineHeight(18).fontColor($r('app.color.text_secondary')).width('100%')
              }.alignItems(HorizontalAlign.Start).layoutWeight(1)
              Toggle({ type: ToggleType.Switch, isOn: this.s.wakeResetConnections })
                .onChange((v: boolean) => {
                  this.s.wakeResetConnections = v;
                  this.markDirty();
                })
            }.width('100%')
            Row() {
              Column({ space: 2 }) {
                Text($r('app.string.profile_traffic_statistics')).fontSize(15).fontColor($r('app.color.text_1')).width('100%')
                Text($r('app.string.profile_traffic_statistics_sum'))
                  .fontSize(12).lineHeight(18).fontColor($r('app.color.text_secondary')).width('100%')
              }.alignItems(HorizontalAlign.Start).layoutWeight(1)
              Toggle({ type: ToggleType.Switch, isOn: this.s.profileTrafficStatistics })
                .onChange((v: boolean) => {
                  this.s.profileTrafficStatistics = v;
                  this.markDirty();
                })
            }.width('100%')
            Text($r('app.string.settings_theme_note'))
              .fontSize(12).lineHeight(18).fontColor($r('app.color.text_secondary')).width('100%')
          }.alignItems(HorizontalAlign.Start).width('100%')
          }
          }
          .width('100%')
          .padding({ left: 14, right: 14, bottom: this.appearanceExpanded ? 16 : 0 })
          .backgroundColor($r('app.color.surface'))
          .borderRadius(14)
          .shadow({ radius: 6, color: $r('app.color.shadow_color'), offsetY: 1 })

          // Clash API 连接统计
          Column({ space: 16 }) {
          this.sectionHeader($r('sys.symbol.arrow_2_circlepath'), $r('app.string.clash_api_settings'), $r('app.string.settings_api_desc'), this.apiExpanded, () => { this.apiExpanded = !this.apiExpanded; })
          if (this.apiExpanded) {
          Column({ space: 16 }) {
            Row() {
              Text($r('app.string.clash_api_enabled')).fontSize(15).fontColor($r('app.color.text_1')).layoutWeight(1)
              Toggle({ type: ToggleType.Switch, isOn: this.s.clashApiEnabled })
                .onChange((value: boolean) => {
                  this.s.clashApiEnabled = value;
                  this.markDirty();
                })
            }.width('100%')
            Column({ space: 8 }) {
              Text($r('app.string.clash_api_port')).fontSize(14).fontColor($r('app.color.text_1')).width('100%')
              TextInput({ text: `${this.s.clashApiPort}` })
                .width('100%')
                .height(40)
                .type(InputType.Number)
                .onChange((value: string) => {
                  const port = parseInt(value);
                  if (!isNaN(port)) {
                    this.s.clashApiPort = Math.max(1024, Math.min(65535, port));
                    this.markDirty();
                  }
                })
            }.alignItems(HorizontalAlign.Start).width('100%')
            Column({ space: 8 }) {
              Text($r('app.string.clash_api_secret')).fontSize(14).fontColor($r('app.color.text_1')).width('100%')
              TextInput({ text: this.s.clashApiSecret })
                .width('100%')
                .height(40)
                .type(InputType.Password)
                .onChange((value: string) => {
                  this.s.clashApiSecret = value;
                  this.markDirty();
                })
            }.alignItems(HorizontalAlign.Start).width('100%')
            Text($r('app.string.clash_api_reconnect_hint'))
              .fontSize(12).lineHeight(18).fontColor($r('app.color.text_secondary')).width('100%')
          }.alignItems(HorizontalAlign.Start).width('100%')
          }
          }
          .width('100%')
          .padding({ left: 14, right: 14, bottom: this.apiExpanded ? 16 : 0 })
          .backgroundColor($r('app.color.surface'))
          .borderRadius(14)
          .shadow({ radius: 6, color: $r('app.color.shadow_color'), offsetY: 1 })

          // 分应用代理
          Column({ space: 16 }) {
          this.sectionHeader($r('sys.symbol.dot_grid_2x2'), $r('app.string.per_app_proxy'), $r('app.string.settings_per_app_desc'), this.perAppExpanded, () => { this.perAppExpanded = !this.perAppExpanded; })
          if (this.perAppExpanded) {
          Column({ space: 16 }) {
            Row({ space: 8 }) {
              ForEach(APP_MODES, (m: string, idx: number) => {
                Button(APP_MODE_LABELS[idx])
                  .layoutWeight(1)
                  .height(32)
                  .fontSize(14)
                  .backgroundColor(this.s.perAppMode === m ? $r('app.color.primary') : $r('app.color.app_background'))
                  .fontColor(this.s.perAppMode === m ? $r('app.color.surface') : $r('app.color.text_primary'))
                  .visualEffect(pressLightEffect(this.litKey === `perapp:${m}`, true))
                  .onTouch((event: TouchEvent) => {
                    if (event.type === TouchType.Down) {
                      this.litKey = `perapp:${m}`;
                    } else if (event.type === TouchType.Up || event.type === TouchType.Cancel) {
                      this.litKey = '';
                    }
                  })
                  .onClick(async () => {
                    this.s.perAppMode = m;
                    this.markDirty();
                    await this.save(true);
                    const running: boolean = AppStorage.get<boolean>('vpnRunning') ?? false;
                    const profileId: string = AppStorage.get<string>('vpnRunningProfileId') ?? '';
                    if (running && profileId.length > 0) {
                      LogStore.addLog('[ui] 分应用代理模式已变更，自动重启 VPN 使配置生效');
                      await VpnService.switchTo(this.context, profileId);
                    }
                  })
              }, (m: string) => m)
            }.width('100%')
            if (this.s.perAppMode !== 'off') {
              Row({ space: 8 }) {
                TextInput({ text: this.appSearch, placeholder: $r('app.string.search_apps') })
                  .layoutWeight(1).height(40)
                  .onChange((value: string) => { this.appSearch = value; })
                Button(this.appListLoading ? $r('app.string.reading_apps') : $r('app.string.read_apps'))
                  .enabled(!this.appListLoading)
                  .visualEffect(pressLightEffect(this.litKey === 'perapp:load', true))
                  .onTouch((event: TouchEvent) => {
                    if (event.type === TouchType.Down) {
        this.litKey = 'perapp:load';
      } else if (event.type === TouchType.Up || event.type === TouchType.Cancel) {
        this.litKey = '';
      }
                  })
                  .onClick(() => this.loadInstalledApps())
              }.width('100%')

              Row({ space: 8 }) {
                Button($r('app.string.invert_selections'))
                  .layoutWeight(1).height(UiSpec.BTN_HEIGHT)
                  .enabled(this.installedApps.length > 0 && !this.appListLoading)
                  .backgroundColor($r('app.color.app_background'))
                  .fontColor($r('app.color.text_primary'))
                  .visualEffect(pressLightEffect(this.litKey === 'perapp:invert', true))
                  .onTouch((event: TouchEvent) => {
                    if (event.type === TouchType.Down) {
        this.litKey = 'perapp:invert';
      } else if (event.type === TouchType.Up || event.type === TouchType.Cancel) {
        this.litKey = '';
      }
                  })
                  .onClick(() => this.invertAppSelections())
                Button($r('app.string.clear_selections'))
                  .layoutWeight(1).height(UiSpec.BTN_HEIGHT)
                  .enabled(this.s.perAppList.length > 0)
                  .backgroundColor($r('app.color.app_background'))
                  .fontColor($r('app.color.text_primary'))
                  .visualEffect(pressLightEffect(this.litKey === 'perapp:clear', true))
                  .onTouch((event: TouchEvent) => {
                    if (event.type === TouchType.Down) {
        this.litKey = 'perapp:clear';
      } else if (event.type === TouchType.Up || event.type === TouchType.Cancel) {
        this.litKey = '';
      }
                  })
                  .onClick(() => this.clearAppSelections())
              }.width('100%')

              // 包名列表剪贴板导出/导入(对齐安卓 per_app_proxy_menu 的 export/import clipboard)
              Row({ space: 8 }) {
                Button($r('app.string.export_selections_clipboard'))
                  .layoutWeight(1).height(UiSpec.BTN_HEIGHT)
                  .enabled(this.s.perAppList.length > 0)
                  .backgroundColor($r('app.color.app_background'))
                  .fontColor($r('app.color.text_primary'))
                  .visualEffect(pressLightEffect(this.litKey === 'perapp:export', true))
                  .onTouch((event: TouchEvent) => {
                    if (event.type === TouchType.Down) {
        this.litKey = 'perapp:export';
      } else if (event.type === TouchType.Up || event.type === TouchType.Cancel) {
        this.litKey = '';
      }
                  })
                  .onClick(() => { void this.exportAppListToClipboard(); })
                Button($r('app.string.import_selections_clipboard'))
                  .layoutWeight(1).height(UiSpec.BTN_HEIGHT)
                  .backgroundColor($r('app.color.app_background'))
                  .fontColor($r('app.color.text_primary'))
                  .visualEffect(pressLightEffect(this.litKey === 'perapp:import', true))
                  .onTouch((event: TouchEvent) => {
                    if (event.type === TouchType.Down) {
        this.litKey = 'perapp:import';
      } else if (event.type === TouchType.Up || event.type === TouchType.Cancel) {
        this.litKey = '';
      }
                  })
                  .onClick(() => { void this.importAppListFromClipboard(); })
              }.width('100%')

              if (this.appListError !== '') {
                Text(this.appListError)
                  .fontSize(12).fontColor($r('app.color.error')).width('100%')
              }

              if (this.installedApps.length > 0) {
                List({ space: 4 }) {
                  ForEach(this.filteredInstalledApps(), (item: InstalledAppItem) => {
                    ListItem() {
                      Row({ space: 8 }) {
                        Column({ space: 2 }) {
                          Text(item.label).fontSize(15).fontColor($r('app.color.text_1')).width('100%')
                          Text(item.bundleName)
                            .fontSize(12).lineHeight(18).fontColor($r('app.color.text_secondary')).width('100%')
                        }.alignItems(HorizontalAlign.Start).layoutWeight(1)
                        Toggle({ type: ToggleType.Checkbox, isOn: this.isAppSelected(item.bundleName) })
                          .onChange((selected: boolean) => {
                            this.toggleInstalledApp(item.bundleName, selected);
                          })
                      }.width('100%').padding({ top: 6, bottom: 6 })
                    }
                  }, (item: InstalledAppItem) => item.bundleName)
                }.width('100%').height(240)
              }

              TextInput({
                text: this.s.perAppList,
                placeholder: this.s.perAppMode === 'exclude'
                  ? $r('app.string.settings_per_app_hint_exclude')
                  : $r('app.string.settings_per_app_hint_include')
              })
                .width('100%').height(40)
                .onChange((value: string) => {
                  this.s.perAppList = value;
                  this.markDirty();
                })
                .onSubmit(async () => {
                  await this.save(true);
                  const running: boolean = AppStorage.get<boolean>('vpnRunning') ?? false;
                  const profileId: string = AppStorage.get<string>('vpnRunningProfileId') ?? '';
                  if (running && profileId.length > 0) {
                    LogStore.addLog('[ui] 分应用代理列表已保存，自动重启 VPN 使配置生效');
                    await VpnService.switchTo(this.context, profileId);
                  }
                })
              Text($r('app.string.settings_per_app_manual_note'))
                .fontSize(12).lineHeight(18).fontColor($r('app.color.text_secondary')).width('100%')
            }
          }.alignItems(HorizontalAlign.Start).width('100%')
          }
          }
          .width('100%')
          .padding({ left: 14, right: 14, bottom: this.perAppExpanded ? 16 : 0 })
          .backgroundColor($r('app.color.surface'))
          .borderRadius(14)
          .shadow({ radius: 6, color: $r('app.color.shadow_color'), offsetY: 1 })

        }
        .width('100%')
        .padding({ left: 14, right: 14, top: 0, bottom: this.bottomInset })
      }
      .scrollBar(BarState.Off)
      .edgeEffect(EdgeEffect.Spring)
      .width('100%')
      .height('100%')
      .align(Alignment.Top)
  }
}
