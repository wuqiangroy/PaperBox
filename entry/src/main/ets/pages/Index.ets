import common from '@ohos.app.ability.common';
import router from '@ohos.router';
import promptAction from '@ohos.promptAction';
import bundleManager from '@ohos.bundle.bundleManager';
import picker from '@ohos.file.picker';
import fs from '@ohos.file.fs';
import BusinessError from '@ohos.base';
import zlib from '@ohos.zlib';
import image from '@ohos.multimedia.image';
import { scanBarcode, scanCore, generateBarcode } from '@kit.ScanKit';
import window from '@ohos.window';
import hidebug from '@ohos.hidebug';
/* HDS 标题栏：自带"渐变模糊"(IMMERSIVE_GRADIENT_BLUR) 与沉浸光感材质 —— 不要自己画渐变) */
import {
  BlurStrategy,
  HdsNavigation,
  HdsNavigationTitleBarOptions,
  HdsNavigationTitleMode,
  HdsTabs,
  HdsTabsController,
  ScrollEffectType,
  hdsMaterial
} from '@kit.UIDesignKit';
import { UiSpec } from '../common/UiSpec';
import { illuminatedEffect, pressLightEffect } from '../common/Effects';
import { GlowIconButton } from '../common/components/GlowIconButton';
import { HdsMenu, MenuItemData } from '../common/components/FlowMenu';
import { SettingsPage } from './SettingsPage';
import { GroupPage } from './GroupPage';
import { ToolsPage } from './ToolsPage';
import { AboutPage } from './AboutPage';
import { RouteRulesPanel } from './RouteRulesPage';
import { LogPanel } from './LogPage';

import { Profile, ProfileGroup, AppSettings, profileTypeLabel } from '../model/Profile';
import { initStore, loadProfiles, saveProfiles, loadGroups, loadSettings, saveSettings, readPrefString, writePrefString, ensureGroupByName, LogStore } from '../model/Store';
import { VpnService } from '../core/VpnService';
import { parseShareText } from '../utils/LinkParser';
import { getClipboardText, setClipboardText } from '../utils/ClipboardHelper';
import { fetchSubscriptionWithInfo, looksLikeClashYaml, parseClashProxies, looksLikeSingBoxJson, parseSingBoxConfig, ClashParseResult, subErrorText, unwrapSubscriptionLink, isSagerNetSubscriptionContainer } from '../utils/Subscription';
import { testProfiles, urlTestProfiles } from '../utils/LatencyTester';
import { SubInfo, listSubs, upsertSub, needAutoUpdate, updateSubscription, setAppContext, subNameOf, markSubSuccess, markSubFailure } from '../core/Subscriptions';
import { fetchTrafficTotals, formatSpeed, formatBytes } from '../utils/TrafficStats';
import { fetchCurrentProxyDelay } from '../utils/ClashApi';
import { exportProfileLink } from '../utils/LinkExporter';
import { buildOutboundJson } from '../core/ConfigBuilder';
import { publishVpnLatency } from '../core/VpnIpc';

const OUTBOUND_MODES: Array<string> = ['rule', 'global', 'direct'];
const OUTBOUND_MODE_LABELS: Array<Resource> = [$r('app.string.mode_rule'), $r('app.string.mode_global'), $r('app.string.mode_direct')];
/** 底部 Tab 栏内容高(不含手势条让位) */
const TAB_BAR_CONTENT_HEIGHT: number = 58;

/** 底部 Tab(顺序即 activeTab 下标):[文案, 系统符号] */
const TAB_LABELS: Array<Resource> = [
  $r('app.string.tab_proxy'),
  $r('app.string.tab_subscriptions'),
  $r('app.string.tab_settings')
];
const TAB_SYMBOLS: Array<Resource> = [
  $r('sys.symbol.list_square'),
  $r('sys.symbol.square_and_arrow_down'),
  $r('sys.symbol.gearshape')
];
/** 设置页二级分区(顺序即列表顺序):[标识, 文案, 描述, 系统符号] */
const SETTINGS_SECTION_IDS: Array<string> = ['general', 'groups', 'route', 'logs', 'tools', 'about'];
const SETTINGS_SECTION_LABELS: Array<Resource> = [
  $r('app.string.settings_hub_general'),
  $r('app.string.settings_hub_groups'),
  $r('app.string.settings_hub_route'),
  $r('app.string.settings_hub_logs'),
  $r('app.string.settings_hub_tools'),
  $r('app.string.settings_hub_about')
];
const SETTINGS_SECTION_DESCS: Array<Resource> = [
  $r('app.string.settings_hub_general_desc'),
  $r('app.string.settings_hub_groups_desc'),
  $r('app.string.settings_hub_route_desc'),
  $r('app.string.settings_hub_logs_desc'),
  $r('app.string.settings_hub_tools_desc'),
  $r('app.string.settings_hub_about_desc')
];
const SETTINGS_SECTION_SYMBOLS: Array<Resource> = [
  $r('sys.symbol.gearshape'),
  $r('sys.symbol.folder'),
  $r('sys.symbol.arrow_up_left_and_arrow_down_right'),
  $r('sys.symbol.doc_text'),
  $r('sys.symbol.wand_and_stars'),
  $r('sys.symbol.info_circle')
];
/** 顶栏 ⋮ 的菜单锚点 id(沉浸光感菜单靠它定位,必须在某个真实组件上用 .id() 挂上) */
const OVERFLOW_MENU_ANCHOR: string = 'nbOverflowAnchor';
/** 订阅页"本地/未分组"分区的 key */
const LOCAL_SECTION_KEY: string = 'local';

/** 订阅页折叠列表的行模型:kind = header(订阅标题) / node(节点卡) */
class AccordionRow {
  kind: string = 'node';
  key: string = '';
  title: ResourceStr = '';
  subtitle: string = '';
  count: number = 0;
  sourceKey: string = '';
  profile: Profile = new Profile();

  static ofProfile(p: Profile): AccordionRow {
    const row = new AccordionRow();
    row.kind = 'node';
    row.key = `p:${p.id}`;
    row.profile = p;
    return row;
  }
}

@Entry
@Component
struct Index {
  @State profiles: Array<Profile> = [];
  @State groups: Array<ProfileGroup> = [];
  @State selectedId: string = '';
  @State latencies: Record<string, number> = {};
  @State testing: boolean = false;
  @State settings: AppSettings = new AppSettings();
  @State subscriptions: Array<SubInfo> = [];
  /** 订阅页正在更新的订阅 URL("更新"按钮的忙碌态) */
  @State updatingSubUrl: string = '';
  @State activeConfigUrl: string = '';
  @State activeTab: number = 0;          // 0 代理 / 1 订阅 / 2 设置
  /** 设置页当前二级分区(空串 = 设置首页入口列表) */
  @State settingsSection: string = '';
  @State uiUptime: number = 0;
  @State nodeSearch: string = '';
  @State searchVisible: boolean = false;
  /** 节点展示方式:'list' 列表 / 'grid' 块状(参考 FlClash,两种视图都可选) */
  @State nodeViewMode: string = 'list';
  /** 块状视图列数:按窗口宽度自适应(手机 2 列,平板 3~4 列) */
  @State gridColumns: number = 2;
  /** 订阅页折叠状态:存**已折叠**的 key(缺省全部展开,更接近"节点直接可见") */
  @State collapsedKeys: Array<string> = [];
  /** 首页仪表盘:当前应用占用内存(MB),定时刷新 */
  @State memMb: number = 0;
  /** 当前被按下的元素 key(底部 Tab / 节点卡 / 模式按钮 / FAB):"按下才亮"靠它逐颗判断 */
  @State litKey: string = '';
  /** 配置页列表的滚动器(列表滚动位置复位 / 分组切换后回到顶部都靠它) */
  private configScroller: Scroller = new Scroller();
  /** 块状视图的滚动器(同一个 Scroller 不能同时绑 List 和 Grid) */
  private gridScroller: Scroller = new Scroller();
  /** 内存占用轮询定时器(首页仪表盘) */
  private memTimer: number = -1;
  /** 顶栏 ⋮ 的沉浸光感菜单(照 RzdSchool HdsMenu:openMenu + 自绘面板 + 模糊背板 + 自适应取色) */
  private overflowMenu: HdsMenu = new HdsMenu();
  /** HdsNavigation 的宿主栈（本工程二级页走 router，这里只当标题栏宿主用） */
  private pathStack: NavPathStack = new NavPathStack();
  /** 底部沉浸光感胶囊 Tab 的控制器(与 activeTab 双向同步) */
  private tabsController: HdsTabsController = new HdsTabsController();
  /** 底部导航条/手势条高度(vp,运行时实测) —— 列表与 FAB 的底部让位用 */
  @State navBottomVp: number = 24;
  /** 内容区顶部让位(vp):运行时用探针量「顶栏底边 − 内容区原点」得到,不再靠猜常数 */
  @State contentTopInset: number = 96;
  /** 当前选中的分组(配置页顶部分类条;空串 = 未分组) */
  @State selectedGroupId: string = '';
  @State appVersion: string = '';
  @StorageLink('uiBreakpoint') uiBreakpoint: string = 'compact';
  @StorageLink('vpnRunning') @Watch('onRunningChange') isRunning: boolean = false;
  @StorageLink('vpnStatus') statusText: string = 'disconnected';
  @StorageLink('vpnUpSpeed') upSpeed: number = 0;
  @StorageLink('vpnDownSpeed') downSpeed: number = 0;
  @StorageLink('vpnTotalUp') totalUp: number = 0;
  @StorageLink('vpnTotalDown') totalDown: number = 0;
  private context: common.UIAbilityContext = getContext(this) as common.UIAbilityContext;
  private switching: boolean = false;
  private speedTimer: number = -1;
  private speedPollGeneration: number = 0;
  private lastUp: number = 0;
  private lastDown: number = 0;
  private lastTrafficAt: number = 0;
  private uptimeTimer: number = -1;

  aboutToAppear(): void {
    setAppContext(this.context);
    try {
      this.appVersion = bundleManager.getBundleInfoForSelfSync(
        bundleManager.BundleFlag.GET_BUNDLE_INFO_DEFAULT).versionName;
    } catch (e) {
      this.appVersion = '';
    }
    /* 智感握姿已移除(用户 2026-10-23):底部 Tab 胶囊固定居中 */
    this.computeInsets();
    this.startMemoryPoll();
    this.refresh();
    this.autoUpdateSubs();
    this.autoConnect();
    if (this.isRunning) {
      this.startSpeedPoller();
      this.startUptimeTimer();
    }
  }

  /** 运行时实测**底部**导航条/手势条高度(照 RzdVideo HomePage.computeSafeTop 的做法):
   *  列表与 FAB 的底部让位都用它,不写死 —— 写死就会在别的机型上留出死空白或被手势条压住。 */
  private computeInsets(): void {
    try {
      const ctx = this.getUIContext().getHostContext();
      if (ctx === undefined) {
        return;
      }
      window.getLastWindow(ctx).then((win: window.Window) => {
        const ui = this.getUIContext();
        const nav = win.getWindowAvoidArea(window.AvoidAreaType.TYPE_NAVIGATION_INDICATOR);
        const bottomVp = ui.px2vp(nav.bottomRect.height);
        if (bottomVp > 0) {
          this.navBottomVp = bottomVp;
        }
        /* 块状视图列数随窗口宽度走:窄屏 2 列、平板 3 列、更宽的 4 列 */
        const widthVp = ui.px2vp(win.getWindowProperties().windowRect.width);
        this.gridColumns = widthVp >= 840 ? 4 : (widthVp >= 600 ? 3 : 2);
      }).catch(() => {
      });
    } catch (e) {
    }
  }
  /** 首页仪表盘的内存占用:每 5s 轮询一次(hidebug.getPss 返回 KB) */
  private startMemoryPoll(): void {
    this.refreshMemory();
    if (this.memTimer >= 0) {
      clearInterval(this.memTimer);
    }
    this.memTimer = setInterval(() => {
      this.refreshMemory();
    }, 5000);
  }

  private refreshMemory(): void {
    try {
      const kb = Number(hidebug.getPss());
      if (kb > 0) {
        this.memMb = Math.round(kb / 1024);
      }
    } catch (e) {
      // 读取失败保持上一次的值
    }
  }

  /**
   * 系统返回键(对齐安卓 onBackPressedDispatcher):
   * 设置二级页 → 回设置首页;非代理页 → 回代理页;代理页 → 退到桌面(VPN 继续运行)。
   * 本 SDK 下该回调只对 @Entry 组件生效。
   */
  onBackPress(): boolean {
    if (this.activeTab === 2 && this.settingsSection.length > 0) {
      this.settingsSection = '';
      return true;
    }
    if (this.activeTab !== 0) {
      this.activeTab = 0;
      return true;
    }
    this.context.moveAbilityToBackground();
    return true;
  }

  /** 节点搜索输入防抖计时器(见 configFragment 里 TextInput 的 onChange) */
  private searchDebounceTimer: number = -1;

  private scheduleSearchFilter(v: string): void {
    this.cancelSearchFilterTimer();
    this.searchDebounceTimer = setTimeout(() => {
      this.searchDebounceTimer = -1;
      this.nodeSearch = v;
    }, 250);
  }

  private cancelSearchFilterTimer(): void {
    if (this.searchDebounceTimer >= 0) {
      clearTimeout(this.searchDebounceTimer);
      this.searchDebounceTimer = -1;
    }
  }

  /** 关闭节点搜索(「取消」按钮与再次点搜索图标共用):清未触发的防抖 + 清空关键词 */
  private closeNodeSearch(): void {
    this.cancelSearchFilterTimer();
    this.nodeSearch = '';
    this.searchVisible = false;
  }

  aboutToDisappear(): void {
    if (this.memTimer >= 0) {
      clearInterval(this.memTimer);
      this.memTimer = -1;
    }
    this.cancelSearchFilterTimer();
    this.stopSpeedPoller();
    if (this.uptimeTimer >= 0) {
      clearInterval(this.uptimeTimer);
      this.uptimeTimer = -1;
    }
  }

  // 从编辑页 router.back() 回来时刷新列表(否则新保存的节点不显示)
  onPageShow(): void {
    this.refresh();
    void this.reconcileVpnState();
  }

  /** 回到前台时核对 VPN 状态:UI 进程可能被系统回收重建而扩展进程实际已死。
   *  以 clash API 探测为准,无响应则把 UI 重置回断开态,避免按钮停在「运行中」。 */
  private async reconcileVpnState(): Promise<void> {
    const running: boolean = AppStorage.get<boolean>('vpnRunning') ?? false;
    const status: string = AppStorage.get<string>('vpnStatus') ?? '';
    if (!running || !status.startsWith('connected:') || !this.settings.clashApiEnabled) {
      return;
    }
    try {
      const totals = await fetchTrafficTotals(this.settings.clashApiPort, this.settings.clashApiSecret);
      if (totals === null) {
        LogStore.addLog('[ui] 前台探测:VPN 扩展无响应(clash API 不可达),重置为断开状态');
        AppStorage.setOrCreate('vpnRunning', false);
        AppStorage.setOrCreate('vpnRunningProfileId', '');
        AppStorage.setOrCreate('vpnStatus', 'disconnected');
      }
    } catch (e) {
      // 探测异常不改变 UI 状态
    }
  }

  onRunningChange(): void {
    if (this.isRunning) {
      this.startSpeedPoller();
      this.startUptimeTimer();
    } else {
      this.stopSpeedPoller();
      this.stopUptimeTimer();
    }
    this.refresh();
  }

  async refresh(): Promise<void> {
    try {
      await initStore(this.context);
      this.profiles = await loadProfiles();
      this.groups = await loadGroups();
      this.settings = await loadSettings();
      this.subscriptions = await listSubs();
      this.activeConfigUrl = await readPrefString('active_config_url', '');
      if (this.activeConfigUrl.length > 0 && !this.subscriptions.some((sub: SubInfo) => sub.url === this.activeConfigUrl)) {
        this.activeConfigUrl = '';
        await writePrefString('active_config_url', '');
      }
      const savedNodeId = await readPrefString('selected_profile_id', '');
      if (savedNodeId.length > 0 && this.profiles.some((profile: Profile) => profile.id === savedNodeId)) {
        this.selectedId = savedNodeId;
      } else if (this.selectedId.length === 0 && this.profiles.length > 0) {
        this.selectedId = this.profiles[0].id;
      }
      /* 分组分类条:分组/节点变化后校正选中项(被删/被合并时回落到第一个) */
      this.ensureSelectedGroup();
    } catch (e) {
      LogStore.addLog(`[ui] 加载节点失败: ${e}`);
    }
  }

  /** 启动时自动更新超过设定间隔的订阅 */
  async autoUpdateSubs(): Promise<void> {
    try {
      await initStore(this.context);
      if (!this.settings.autoUpdateSubs) {
        return;
      }
      const stale = await needAutoUpdate();
      for (const sub of stale) {
        try {
          const r = await updateSubscription(sub.url);
          await markSubSuccess(sub.url);
          LogStore.addLog(`[app] 订阅 ${sub.name} 自动更新:新增 ${r.added},移除 ${r.removed}`);
          this.refresh();
        } catch (e) {
          await markSubFailure(sub.url);
          LogStore.addLog(`[app] 订阅 ${sub.name} 自动更新失败: ${subErrorText(e as Object)}`);
        }
      }
    } catch (e) {
      // ignore
    }
  }

  /** 启动时自动连接已选中的节点(对齐安卓 isAutoConnect;默认关闭) */
  async autoConnect(): Promise<void> {
    try {
      if (!this.settings.autoConnect) {
        return;
      }
      if (this.isRunning) {
        return;
      }
      if (this.selectedId.length === 0) {
        return;
      }
      LogStore.addLog('[app] 自动连接已启用,正在启动 VPN…');
      await VpnService.connect(this.context, this.selectedId);
    } catch (e) {
      LogStore.addLog(`[app] 自动连接失败: ${subErrorText(e as Object)}`);
    }
  }

  // ---------------------------------------------------------------- 速度/计时轮询

  private startSpeedPoller(): void {
    this.stopSpeedPoller();
    if (!this.isRunning || !this.settings.clashApiEnabled) {
      return;
    }
    this.lastUp = 0;
    this.lastDown = 0;
    this.lastTrafficAt = 0;
    AppStorage.setOrCreate('vpnUpSpeed', 0);
    AppStorage.setOrCreate('vpnDownSpeed', 0);
    const generation = ++this.speedPollGeneration;
    const poll = async (): Promise<void> => {
      const startedAt = Date.now();
      const t = await fetchTrafficTotals(this.settings.clashApiPort, this.settings.clashApiSecret);
      if (generation !== this.speedPollGeneration || !this.isRunning || !this.settings.clashApiEnabled || t === null) {
        return;
      }
      if (this.lastTrafficAt <= 0) {
        this.lastUp = t.up;
        this.lastDown = t.down;
        this.lastTrafficAt = startedAt;
        AppStorage.setOrCreate('vpnUpSpeed', 0);
        AppStorage.setOrCreate('vpnDownSpeed', 0);
      } else {
        const elapsedSeconds = Math.max(0.001, (startedAt - this.lastTrafficAt) / 1000);
        AppStorage.setOrCreate('vpnUpSpeed', Math.max(0, Math.round((t.up - this.lastUp) / elapsedSeconds)));
        AppStorage.setOrCreate('vpnDownSpeed', Math.max(0, Math.round((t.down - this.lastDown) / elapsedSeconds)));
        this.lastUp = t.up;
        this.lastDown = t.down;
        this.lastTrafficAt = startedAt;
      }
      AppStorage.setOrCreate('vpnTotalUp', t.up);
      AppStorage.setOrCreate('vpnTotalDown', t.down);
    };
    void poll();
    this.speedTimer = setInterval(() => { void poll(); }, 1000);
  }

  private startUptimeTimer(): void {
    this.stopUptimeTimer();
    const stored: number = AppStorage.get<number>('uiUptimeStart') ?? 0;
    const startedAt = stored > 0 ? stored : Date.now();
    AppStorage.setOrCreate('uiUptimeStart', startedAt);
    this.uiUptime = Math.max(0, Math.floor((Date.now() - startedAt) / 1000));
    AppStorage.setOrCreate('uiUptime', this.uiUptime);
    this.uptimeTimer = setInterval(() => {
      this.uiUptime = Math.max(0, Math.floor((Date.now() - startedAt) / 1000));
      AppStorage.setOrCreate('uiUptime', this.uiUptime);
    }, 1000);
  }

  private stopUptimeTimer(): void {
    if (this.uptimeTimer >= 0) {
      clearInterval(this.uptimeTimer);
      this.uptimeTimer = -1;
    }
    this.uiUptime = 0;
    AppStorage.setOrCreate('uiUptime', 0);
    AppStorage.setOrCreate('uiUptimeStart', 0);
  }

  private stopSpeedPoller(): void {
    this.speedPollGeneration++;
    if (this.speedTimer >= 0) {
      clearInterval(this.speedTimer);
      this.speedTimer = -1;
    }
    this.lastUp = 0;
    this.lastDown = 0;
    this.lastTrafficAt = 0;
    AppStorage.setOrCreate('vpnUpSpeed', 0);
    AppStorage.setOrCreate('vpnDownSpeed', 0);
  }

  // ---------------------------------------------------------------- 连接控制

  private uptimeText(): string {
    const hours = Math.floor(this.uiUptime / 3600);
    const minutes = Math.floor((this.uiUptime % 3600) / 60);
    const seconds = this.uiUptime % 60;
    const pad = (value: number): string => value < 10 ? `0${value}` : `${value}`;
    return `${pad(hours)}:${pad(minutes)}:${pad(seconds)}`;
  }

  statusDisplay(): ResourceStr {
    const s = this.statusText;
    if (s === 'connecting') {
      return $r('app.string.status_connecting');
    }
    if (s === 'disconnecting') {
      return $r('app.string.status_disconnecting');
    }
    if (s === 'disconnected') {
      return $r('app.string.status_disconnected');
    }
    if (s === 'switching') {
      return $r('app.string.status_switching');
    }
    if (s === 'start_timeout') {
      return $r('app.string.status_start_timeout');
    }
    if (s === 'awaiting_auth') {
      return $r('app.string.status_awaiting_auth');
    }
    if (s.startsWith('connected:')) {
      return $r('app.string.status_connected_node', s.substring('connected:'.length));
    }
    if (s.startsWith('start_failed:')) {
      return $r('app.string.status_start_failed', s.substring('start_failed:'.length));
    }
    if (s.startsWith('connect_failed:')) {
      return $r('app.string.status_connect_failed', s.substring('connect_failed:'.length));
    }
    return s;
  }

  async connectTo(p: Profile): Promise<void> {
    if (this.isRunning) {
      promptAction.showToast({ message: $r('app.string.disconnect_first') });
      return;
    }
    this.selectedId = p.id;
    await writePrefString('selected_profile_id', p.id);
    try {
      await VpnService.connect(this.context, p.id);
    } catch (e) {
      // 状态已在 VpnService 中更新
    }
  }

  async disconnect(): Promise<void> {
    await VpnService.disconnect(this.context);
  }

  private selectedProfile(): Profile | undefined {
    return this.profiles.find((profile: Profile) => profile.id === this.selectedId);
  }

  async toggleVpn(): Promise<void> {
    if (this.isRunning) {
      await this.disconnect();
      return;
    }
    const target = this.selectedProfile();
    if (target === undefined) {
      promptAction.showToast({ message: $r('app.string.select_or_create_profile') });
      return;
    }
    await this.connectTo(target);
  }

  /** 点击节点:未运行则选中;运行中点其他节点 = 热切换 */
  async onNodeTap(p: Profile): Promise<void> {
    this.selectedId = p.id;
    await writePrefString('selected_profile_id', p.id);
    if (!this.isRunning) {
      return;
    }
    if (this.switching) {
      promptAction.showToast({ message: $r('app.string.switching_wait') });
      return;
    }
    const runningId = AppStorage.get<string>('vpnRunningProfileId') ?? '';
    if (runningId.length > 0 && runningId === p.id) {
      return;
    }
    this.switching = true;
    try {
      promptAction.showToast({ message: $r('app.string.switching_to_name', p.name) });
      await VpnService.switchTo(this.context, p.id);
    } finally {
      this.switching = false;
    }
  }

  async switchOutboundMode(mode: string): Promise<void> {
    if (!OUTBOUND_MODES.includes(mode) || this.settings.mode === mode) {
      return;
    }
    this.settings.mode = mode;
    await saveSettings(this.settings);
    if (this.isRunning) {
      const profileId: string = AppStorage.get<string>('vpnRunningProfileId') ?? this.selectedId;
      if (profileId.length > 0) {
        await VpnService.connect(this.context, profileId, true);
      }
    }
  }

  // ---------------------------------------------------------------- 测速

  /** 测速一组节点(用户 2026-10-17:不再支持全量)。缺省 = 当前选中分组;
   *  分组条长按"测速本组"传被按的那个组 id。 */
  async runSpeedTest(groupId: string = this.selectedGroupId): Promise<void> {
    await this.runSpeedTestFor(this.profiles.filter((item: Profile) => item.groupId === groupId));
  }

  /** 对一组指定节点测速(订阅页按订阅/未分组各测各的) */
  async runSpeedTestFor(targets: Array<Profile>): Promise<void> {
    if (this.testing) {
      // 之前是静默 return:测速进行中再点测速毫无反馈,像"点了没反应"
      promptAction.showToast({ message: $r('app.string.index_test_in_progress') });
      return;
    }
    if (targets.length === 0) {
      promptAction.showToast({ message: $r('app.string.speed_test_group_empty') });
      return;
    }
    /* 只清掉本组节点的旧延迟显示(其它组的历史结果保留),让本组测速中显示"…" */
    const targetIds = new Set<string>(targets.map((item: Profile) => item.id));
    const kept: Record<string, number> = {};
    for (const k of Object.keys(this.latencies)) {
      if (!targetIds.has(k)) {
        kept[k] = this.latencies[k];
      }
    }
    this.latencies = kept;
    promptAction.showToast({ message: $r('app.string.index_testing_count', targets.length) });
    await this.runProfilesTest(targets);
  }

  async runGroupSpeedTest(groupId: string): Promise<void> {
    await this.runSpeedTest(groupId);
  }

  private async runProfilesTest(snapshot: Array<Profile>): Promise<void> {
    this.testing = true;
    /* 结果不能逐条写 @State:每张节点卡的延迟文本都依赖 latencies,逐条写会
       把主页整页重渲染 N 次,节点多时 UI 线程被刷爆 —— 表现为"测速中页面卡死、
       点搜索/点按钮都没反应"。结果先进缓冲,每 300ms 合并刷一次,测完补最后一次。 */
    let pending: Record<string, number> = {};
    let flushTimer = -1;
    const flushPending = (): void => {
      if (flushTimer >= 0) {
        clearTimeout(flushTimer);
        flushTimer = -1;
      }
      const keys = Object.keys(pending);
      if (keys.length === 0) {
        return;
      }
      const next: Record<string, number> = {};
      for (const k of Object.keys(this.latencies)) {
        next[k] = this.latencies[k];
      }
      for (const k of keys) {
        next[k] = pending[k];
      }
      this.latencies = next;
      pending = {};
    };
    const onOne = (id: string, ms: number): void => {
      pending[id] = ms;
      const profile = this.profiles.find((item: Profile) => item.id === id);
      if (profile !== undefined) {
        profile.latencyMs = ms;
        profile.latencyTestedAt = Date.now();
        const runningProfileId: string = AppStorage.get<string>('vpnRunningProfileId') ?? '';
        if (this.isRunning && runningProfileId === id) {
          publishVpnLatency(id, profile.name, ms);
        }
      }
      if (flushTimer < 0) {
        flushTimer = setTimeout(flushPending, 300);
      }
    };
    try {
      if (this.settings.latencyTestMode === 'tcp') {
        await testProfiles(snapshot, onOne, this.settings.testConcurrent);
      } else {
        /* 上游签名：urlTestProfiles(targets, allProfiles, settings, context, onResult, concurrency, groups)
           —— 超时由 settings.testTimeoutMs 决定（不再传 5000），返回 LatencyRunReport。 */
        const report = await urlTestProfiles(snapshot, this.profiles, this.settings, this.context,
          onOne, this.settings.testConcurrent, this.groups);
        if (report.degraded) {
          // 内核测速起不来而回退 TCPing 时,数值含义完全变了(只反映握手耗时),
          // 必须明示,否则用户拿着假数据对比 Clash
          promptAction.showToast({ message: $r('app.string.speed_test_degraded', report.degradeReason) });
        }
      }
      flushPending();
      await saveProfiles(this.profiles);
      this.profiles = this.profiles.slice();
      promptAction.showToast({ message: $r('app.string.speed_test_complete') });
    } finally {
      flushPending();
      this.testing = false;
    }
  }

  /** 清除当前分组测试结果 */
  async clearTestResults(groupId: string): Promise<void> {
    let changed = false;
    for (const p of this.profiles) {
      if ((groupId === '__all__' || p.groupId === groupId) && p.latencyMs !== 0) {
        p.latencyMs = 0;
        p.latencyTestedAt = 0;
        changed = true;
      }
    }
    const next: Record<string, number> = {};
    this.latencies = next;
    if (changed) {
      await saveProfiles(this.profiles);
      this.profiles = this.profiles.slice();
      promptAction.showToast({ message: $r('app.string.test_results_cleared') });
    }
  }

  /** 去重(当前分组,按 名称+类型+服务器+端口+凭据) */
  async dedupGroup(groupId: string): Promise<void> {
    const seen = new Set<string>();
    const kept: Array<Profile> = [];
    let removed = 0;
    for (const p of this.profiles) {
      if (groupId !== '__all__' && p.groupId !== groupId) {
        kept.push(p);
        continue;
      }
      const key = `${p.name}\u001f${p.type}\u001f${p.server}\u001f${p.serverPort}\u001f${p.uuid}\u001f${p.password}`;
      if (seen.has(key)) {
        removed++;
        continue;
      }
      seen.add(key);
      kept.push(p);
    }
    if (removed > 0) {
      this.profiles = kept;
      await saveProfiles(kept);
      promptAction.showToast({ message: $r('app.string.dedup_done', removed) });
    } else {
      promptAction.showToast({ message: $r('app.string.dedup_none') });
    }
  }

  /** 删除当前分组不可用节点(最近测速失败) */
  deleteUnavailable(groupId: string): void {
    const dead = this.profiles.filter((p: Profile) => (groupId === '__all__' || p.groupId === groupId) && p.latencyMs === -1);
    if (dead.length === 0) {
      promptAction.showToast({ message: $r('app.string.no_unavailable_nodes') });
      return;
    }
    AlertDialog.show({
      message: $r('app.string.confirm_delete_unavailable', dead.length),
      primaryButton: { value: $r('app.string.cancel'), action: () => {} },
      secondaryButton: {
        value: $r('app.string.delete'),
        fontColor: $r('app.color.error'),
        action: async () => {
          const deadIds = new Set<string>(dead.map((p: Profile) => p.id));
          this.profiles = this.profiles.filter((p: Profile) => !deadIds.has(p.id));
          await saveProfiles(this.profiles);
          promptAction.showToast({ message: $r('app.string.dedup_done', dead.length) });
        }
      }
    });
  }

  async setSortMode(mode: string): Promise<void> {
    this.settings.profileSortMode = mode;
    await saveSettings(this.settings);
    this.profiles = this.profiles.slice();
  }

  /** 更新当前选中节点所属的订阅(对齐安卓 action_update_subscription) */
  async updateCurrentSubscription(): Promise<void> {
    const selected = this.profiles.find((p: Profile) => p.id === this.selectedId);
    const url = selected !== undefined ? selected.subUrl : this.activeConfigUrl;
    if (url.length === 0) {
      promptAction.showToast({ message: $r('app.string.current_subscription_missing') });
      return;
    }
    promptAction.showToast({ message: $r('app.string.fetching_subscription') });
    try {
      const r = await updateSubscription(url);
      await this.refresh();
      promptAction.showToast({ message: $r('app.string.sub_update_result', r.added, r.removed) });
    } catch (e) {
      promptAction.showToast({ message: $r('app.string.update_failed_reason', subErrorText(e as Object)) });
    }
  }

  /** 订阅页:更新单个订阅(标题行「更新」按钮) */
  async updateSubByUrl(url: string): Promise<void> {
    if (this.updatingSubUrl.length > 0) {
      return;
    }
    this.updatingSubUrl = url;
    promptAction.showToast({ message: $r('app.string.fetching_subscription') });
    try {
      const r = await updateSubscription(url);
      await markSubSuccess(url);
      await this.refresh();
      promptAction.showToast({ message: $r('app.string.sub_update_result', r.added, r.removed) });
    } catch (e) {
      await markSubFailure(url);
      promptAction.showToast({ message: $r('app.string.update_failed_reason', subErrorText(e as Object)) });
    } finally {
      this.updatingSubUrl = '';
    }
  }

  /** 清除累计流量统计(对齐安卓 action_clear_traffic_statistics) */
  clearTrafficStatistics(): void {
    this.lastUp = 0;
    this.lastDown = 0;
    this.lastTrafficAt = 0;
    AppStorage.setOrCreate('vpnTotalUp', 0);
    AppStorage.setOrCreate('vpnTotalDown', 0);
    promptAction.showToast({ message: $r('app.string.traffic_stats_cleared') });
  }

  // ---------------------------------------------------------------- 分组/节点数据

  sortedProfiles(): Array<Profile> {
    return this.profiles.slice().sort((a: Profile, b: Profile) => {
      if (a.pinned !== b.pinned) {
        return a.pinned ? -1 : 1;
      }
      if (a.groupId !== b.groupId) {
        return 0;
      }
      if (this.settings.profileSortMode === 'name') {
        return a.name.localeCompare(b.name);
      }
      if (this.settings.profileSortMode === 'latency') {
        const aLatency = this.latencyValueOf(a);
        const bLatency = this.latencyValueOf(b);
        return aLatency - bLatency;
      }
      if (a.sortOrder !== b.sortOrder) {
        return a.sortOrder - b.sortOrder;
      }
      return this.latencyValueOf(a) - this.latencyValueOf(b);
    });
  }

  private latencyValueOf(p: Profile): number {
    const ms = this.latencies[p.id];
    if (ms !== undefined) {
      return ms < 0 ? Number.MAX_SAFE_INTEGER : ms;
    }
    if (p.latencyMs < 0) {
      return Number.MAX_SAFE_INTEGER;
    }
    return p.latencyMs === 0 ? Number.MAX_SAFE_INTEGER : p.latencyMs;
  }

  profilesInGroup(groupId: string): Array<Profile> {
    return this.sortedProfiles().filter((p: Profile) => p.groupId === groupId);
  }

  sortedGroupIds(): Array<string> {
    const ids: Array<string> = [];
    const sortedGroups = this.groups.slice().sort((a: ProfileGroup, b: ProfileGroup) => a.sortOrder - b.sortOrder);
    for (const group of sortedGroups) {
      if (this.profiles.some((profile: Profile) => profile.groupId === group.id)) {
        ids.push(group.id);
      }
    }
    if (this.profiles.some((profile: Profile) => profile.groupId.length === 0)) {
      ids.push('');
    }
    return ids;
  }

  private visibleProfiles(groupId: string): Array<Profile> {
    const query = this.nodeSearch.trim().toLowerCase();
    const profiles = this.profilesInGroup(groupId);
    if (query.length === 0) {
      return profiles;
    }
    return profiles.filter((profile: Profile) =>
      profile.name.toLowerCase().includes(query)
      || profile.server.toLowerCase().includes(query));
  }

  // ---------------------------------------------------------------- 分组折叠列表(对齐安卓分组展示)

  displayGroupIds(): Array<string> {
    const ids = this.sortedGroupIds();
    if (this.nodeSearch.trim().length === 0) {
      return ids;
    }
    return ids.filter((groupId: string) => this.visibleProfiles(groupId).length > 0);
  }

  /** 组内最优延迟(仅计成功值;无有效值返回 -1) */
  private groupMinLatency(groupId: string): number {
    let min = -1;
    for (const p of this.profilesInGroup(groupId)) {
      let ms = this.latencies[p.id];
      if (ms === undefined && p.latencyMs !== 0) {
        ms = p.latencyMs;
      }
      if (ms !== undefined && ms > 0 && (min < 0 || ms < min)) {
        min = ms;
      }
    }
    return min;
  }

  private latencyColorOfMs(ms: number): ResourceColor {
    if (ms < 0) {
      return $r('app.color.error');
    }
    if (ms < 150) {
      return $r('app.color.success');
    }
    if (ms < 400) {
      return $r('app.color.warning');
    }
    return $r('app.color.error');
  }

  groupName(groupId: string): ResourceStr {
    if (groupId.length === 0) {
      return $r('app.string.ungrouped');
    }
    const group = this.groups.find((item: ProfileGroup) => item.id === groupId);
    return group === undefined ? $r('app.string.ungrouped') : group.name;
  }

  async moveProfile(p: Profile, delta: number): Promise<void> {
    const peers = this.profilesInGroup(p.groupId).filter((item: Profile) => item.pinned === p.pinned);
    const index = peers.findIndex((item: Profile) => item.id === p.id);
    const targetIndex = index + delta;
    if (index < 0 || targetIndex < 0 || targetIndex >= peers.length) {
      return;
    }
    for (let i = 0; i < peers.length; i++) {
      peers[i].sortOrder = i;
    }
    const target = peers[targetIndex];
    const currentOrder = p.sortOrder;
    p.sortOrder = target.sortOrder;
    target.sortOrder = currentOrder;
    await saveProfiles(this.profiles);
    this.profiles = this.profiles.slice();
  }

  async togglePinned(p: Profile): Promise<void> {
    p.pinned = !p.pinned;
    await saveProfiles(this.profiles);
    this.profiles = this.profiles.slice();
  }

  /** 移动到分组(对齐安卓多选择"移动"/节点编辑分组选择) */
  private moveDialog: CustomDialogController | undefined = undefined;

  openMoveToGroup(p: Profile): void {
    this.moveDialog = new CustomDialogController({
      builder: MoveToGroupDialog({
        groups: this.groups,
        currentGroupId: p.groupId,
        profileName: p.name,
        onPick: async (groupId: string) => {
          if (this.moveDialog !== undefined) {
            this.moveDialog.close();
          }
          if (p.groupId === groupId) {
            return;
          }
          p.groupId = groupId;
          await saveProfiles(this.profiles);
          this.profiles = this.profiles.slice();
          promptAction.showToast({ message: $r('app.string.move_to_group_done') });
        }
      }),
      autoCancel: true
    });
    this.moveDialog.open();
  }

  latencyText(p: Profile): ResourceStr {
    let ms = this.latencies[p.id];
    if (ms === undefined && p.latencyMs !== 0) {
      ms = p.latencyMs;
    }
    if (this.testing && ms === undefined) {
      return '…';
    }
    if (ms === undefined) {
      return '';
    }
    return ms < 0 ? $r('app.string.timeout') : `${ms}ms`;
  }

  latencyColor(p: Profile): ResourceColor {
    let ms = this.latencies[p.id];
    if (ms === undefined && p.latencyMs !== 0) {
      ms = p.latencyMs;
    }
    if (ms === undefined) {
      return $r('app.color.text_3');
    }
    if (ms < 0) {
      return $r('app.color.error');
    }
    if (ms < 150) {
      return $r('app.color.success');
    }
    if (ms < 400) {
      return $r('app.color.warning');
    }
    return $r('app.color.error');
  }

  async runUrlTest(p: Profile): Promise<void> {
    if (!this.isRunning) {
      promptAction.showToast({ message: $r('app.string.url_test_requires_connection') });
      return;
    }
    const runningId = AppStorage.get<string>('vpnRunningProfileId') ?? '';
    if (runningId !== p.id) {
      promptAction.showToast({ message: $r('app.string.url_test_current_profile_only') });
      return;
    }
    try {
      const delay = await fetchCurrentProxyDelay(5000, this.settings.clashApiPort, this.settings.testUrl);
      const next: Record<string, number> = {};
      for (const key of Object.keys(this.latencies)) {
        next[key] = this.latencies[key];
      }
      next[p.id] = delay;
      this.latencies = next;
      promptAction.showToast({ message: $r('app.string.url_test_result', delay) });
    } catch (e) {
      const message = e instanceof Error ? e.message : `${e}`;
      promptAction.showToast({ message });
    }
  }

  deleteProfile(p: Profile): void {
    AlertDialog.show({
      message: $r('app.string.confirm_delete_profile_name', p.name),
      primaryButton: {
        value: $r('app.string.cancel'), action: () => {
        }
      },
      secondaryButton: {
        value: $r('app.string.delete'), fontColor: $r('app.color.error'), action: () => {
          this.profiles = this.profiles.filter(x => x.id !== p.id);
          saveProfiles(this.profiles);
        }
      }
    });
  }

  // ---------------------------------------------------------------- 分享/导出

  @State shareText: string = '';
  @State shareQr: image.PixelMap | null = null;
  private shareDialog: CustomDialogController = new CustomDialogController({
    builder: ShareTextDialog({
      text: $shareText,
      qrPixelMap: $shareQr,
      onCopy: async (text: string) => {
        await setClipboardText(text);
        promptAction.showToast({ message: $r('app.string.share_link_copied') });
      }
    }),
    autoCancel: true
  });

  async openProfileShare(p: Profile): Promise<void> {
    const link = exportProfileLink(p);
    if (link.length === 0) {
      promptAction.showToast({ message: $r('app.string.protocol_export_unsupported') });
      return;
    }
    this.shareText = link;
    // 生成二维码(对齐安卓分享界面展示二维码);失败时弹窗退化为纯文本+复制
    this.shareQr = null;
    try {
      const options: generateBarcode.CreateOptions = {
        scanType: scanCore.ScanType.QR_CODE,
        width: 440,
        height: 440
      };
      this.shareQr = await generateBarcode.createBarcode(link, options);
    } catch (e) {
      LogStore.addLog(`[ui] 二维码生成失败,降级为文本分享: ${e}`);
    }
    this.shareDialog.open();
  }

  async copyProfileLink(p: Profile): Promise<void> {
    const link = exportProfileLink(p);
    if (link.length === 0) {
      promptAction.showToast({ message: $r('app.string.protocol_export_unsupported') });
      return;
    }
    await setClipboardText(link);
    promptAction.showToast({ message: $r('app.string.profile_link_copied') });
  }

  /** 导出节点为 sing-box 出站 JSON(对齐安卓「导出配置」) */
  async exportProfileConfig(p: Profile): Promise<void> {
    try {
      const json = buildOutboundJson(p, this.settings);
      await setClipboardText(json);
      promptAction.showToast({ message: $r('app.string.outbound_config_copied') });
    } catch (e) {
      promptAction.showToast({ message: $r('app.string.export_failed_generic', e instanceof Error ? e.message : `${e}`) });
    }
  }

  /** 把节点 sing-box 出站 JSON 写入用户选择的文件(对齐安卓 action_config_export_file) */
  async exportProfileConfigFile(p: Profile): Promise<void> {
    try {
      const json = buildOutboundJson(p, this.settings);
      const documentPicker = new picker.DocumentViewPicker(this.context);
      const fileName = `${p.name.length > 0 ? p.name : p.id}.json`;
      const uris = await documentPicker.save({
        newFileNames: [fileName],
        fileSuffixChoices: ['JSON|.json']
      });
      if (uris.length === 0) {
        promptAction.showToast({ message: $r('app.string.backup_export_cancelled') });
        return;
      }
      const file = fs.openSync(uris[0], fs.OpenMode.WRITE_ONLY | fs.OpenMode.TRUNC);
      try {
        fs.writeSync(file.fd, json);
      } finally {
        fs.closeSync(file);
      }
      promptAction.showToast({ message: $r('app.string.outbound_config_exported') });
    } catch (e) {
      promptAction.showToast({ message: $r('app.string.export_failed_generic', e instanceof Error ? e.message : `${e}`) });
    }
  }

  @Builder
  profileContextMenu(p: Profile) {
    Column() {
      MenuItem({ content: p.pinned ? $r('app.string.unpin') : $r('app.string.pin') })
        .onClick(() => this.togglePinned(p))
      if (this.settings.profileSortMode === 'manual') {
        MenuItem({ content: $r('app.string.move_up') })
          .onClick(() => this.moveProfile(p, -1))
        MenuItem({ content: $r('app.string.move_down') })
          .onClick(() => this.moveProfile(p, 1))
      }
      MenuItem({ content: $r('app.string.url_test') })
        .onClick(() => this.runUrlTest(p))
      MenuItem({ content: $r('app.string.copy_share_link') })
        .onClick(() => this.copyProfileLink(p))
      MenuItem({ content: $r('app.string.share_profile') })
        .onClick(() => this.openProfileShare(p))
      MenuItem({ content: $r('app.string.export_outbound_config') })
        .onClick(() => this.exportProfileConfig(p))
      MenuItem({ content: $r('app.string.export_outbound_config_file') })
        .onClick(() => this.exportProfileConfigFile(p))
      MenuItem({ content: $r('app.string.profile_edit_title') })
        .onClick(() => {
          AppStorage.setOrCreate('editProfileId', p.id);
          router.pushUrl({ url: 'pages/ProfileEdit' });
        })
      MenuItem({ content: $r('app.string.move_to_group') })
        .onClick(() => this.openMoveToGroup(p))
      if (p.subUrl.length > 0) {
        MenuItem({ content: $r('app.string.view_subscription') })
          .onClick(() => router.pushUrl({ url: 'pages/SubDetailPage', params: { url: p.subUrl } }))
      }
      MenuItem({ content: $r('app.string.delete'), labelInfo: $r('app.string.irreversible') })
        .onClick(() => this.deleteProfile(p))
    }
  }

  // ---------------------------------------------------------------- 导入

  @State importText: string = '';
  @State importName: string = '';
  private importDialog: CustomDialogController = new CustomDialogController({
    builder: ImportDialog({
      text: $importText,
      name: $importName,
      onImport: (t: string, name: string) => {
        this.doImport(t, name);
      },
      onPickClipboard: () => {
        this.fillDialogFromClipboard();
      }
    }),
    autoCancel: true
  });

  private addEntryDialog: CustomDialogController = new CustomDialogController({
    builder: AddEntryDialog({
      onNewProfile: () => {
        AppStorage.setOrCreate('editProfileId', '');
        router.pushUrl({ url: 'pages/ProfileEdit' });
      },
      onImportSubscription: () => {
        this.openImportDialog();
      },
      onImportClipboard: () => {
        this.quickImportClipboard();
      },
      onScan: () => {
        this.scanImport();
      },
      onImportFile: () => {
        this.importFromFile();
      }
    }),
    autoCancel: true
  });

  /**
   * 扫码导入(对齐安卓 ScannerActivity):系统扫描 UI,无需相机权限声明。
   * 结果复用 doImport 管道(订阅容器/订阅链接/分享链接 + 导入确认对话框)。
   * 12900010 = 用户取消,静默返回。
   */
  async scanImport(): Promise<void> {
    try {
      const options: scanBarcode.ScanOptions = {
        scanTypes: [scanCore.ScanType.QR_CODE],
        enableMultiMode: false,
        enableAlbum: true
      };
      const result: scanBarcode.ScanResult = await scanBarcode.startScanForResult(this.context, options);
      const value = result.originalValue.trim();
      if (value.length === 0) {
        promptAction.showToast({ message: $r('app.string.scan_no_content') });
        return;
      }
      LogStore.addLog(`[ui] 扫码导入: ${value.substring(0, 40)}…`);
      await this.doImport(value, '');
    } catch (e) {
      const err = e as BusinessError;
      // 1000500002 = 扫描服务取消;12900010 = 用户主动取消(部分版本)
      if (err !== undefined && (err.code === 1000500002 || err.code === 12900010)) {
        return;
      }
      const msg = e instanceof Error ? e.message : `${e}`;
      LogStore.addLog(`[ui] 扫码失败: ${msg}`);
      promptAction.showToast({ message: $r('app.string.scan_failed_use_paste', msg) });
    }
  }

  /**
   * 从文件导入(对齐安卓 ConfigurationFragment.action_import_file → GetContent + parseRaw):
   * 普通文本文件(.txt/.json/.conf/订阅 base64)读取内容后复用 doImport 全管道;
   * .zip 按 WireGuard 导出包解析(对齐安卓 zip 分支,逐 entry 解析、entry 名作节点名)。
   */
  async importFromFile(): Promise<void> {
    try {
      const documentPicker = new picker.DocumentViewPicker(this.context);
      const uris: Array<string> = await documentPicker.select({ maxSelectNumber: 1 });
      if (uris.length === 0) {
        return;
      }
      const uri = uris[0];
      const fileName = decodeURIComponent(uri.split('/').pop() ?? '');
      // 复制到缓存后用路径读取(picker URI 与 readTextSync 路径语义更稳)
      const cachePath = `${this.context.cacheDir}/import_${Date.now()}_${fileName}`;
      fs.copyFileSync(uri, cachePath);
      if (fileName.toLowerCase().endsWith('.zip')) {
        await this.importWireGuardZip(cachePath);
        try {
          fs.unlinkSync(cachePath);
        } catch (e) {
          // 清理失败不影响导入结果
        }
        return;
      }
      const text = fs.readTextSync(cachePath);
      try {
        fs.unlinkSync(cachePath);
      } catch (e) {
        // 同上
      }
      if (text.trim().length === 0) {
        promptAction.showToast({ message: $r('app.string.no_proxies_found_in_file') });
        return;
      }
      await this.doImport(text, '');
    } catch (e) {
      const msg = e instanceof Error ? e.message : `${e}`;
      LogStore.addLog(`[ui] 文件导入失败: ${msg}`);
      promptAction.showToast({ message: $r('app.string.import_file_failed', msg) });
    }
  }

  /** 解析 WireGuard zip 导出包并批量导入(zlib 解压 → 逐文件 parseShareText → 单次确认) */
  async importWireGuardZip(zipPath: string): Promise<void> {
    const outDir = `${this.context.cacheDir}/wg_zip_${Date.now()}`;
    fs.mkdirSync(outDir, true);
    await zlib.decompressFile(zipPath, outDir);
    const collected: Array<Profile> = [];
    for (const name of fs.listFileSync(outDir)) {
      const entryPath = `${outDir}/${name}`;
      try {
        if (fs.statSync(entryPath).isDirectory()) {
          continue;
        }
      } catch (e) {
        continue;
      }
      let text = '';
      try {
        text = fs.readTextSync(entryPath);
      } catch (e) {
        // 二进制/无法按 UTF-8 读取的 entry 跳过(对齐安卓 parseRaw 返回 null)
        continue;
      }
      if (text.trim().length === 0) {
        continue;
      }
      const baseName = name.replace(/\.(conf|txt|json)$/i, '');
      for (const p of parseShareText(text)) {
        if (p.name.trim().length === 0) {
          p.name = baseName;
        }
        collected.push(p);
      }
    }
    try {
      fs.rmdirSync(outDir);
    } catch (e) {
      // 清理失败忽略
    }
    if (collected.length === 0) {
      promptAction.showToast({ message: $r('app.string.no_proxies_found_in_file') });
      return;
    }
    const confirmed: boolean = await new Promise<boolean>((resolve: (v: boolean) => void) => {
      AlertDialog.show({
        message: $r('app.string.import_file_message', collected.length),
        primaryButton: {
          value: $r('app.string.cancel'),
          action: () => {
            resolve(false);
          }
        },
        secondaryButton: {
          value: $r('app.string.import_confirm'),
          action: () => {
            resolve(true);
          }
        }
      });
    });
    if (!confirmed) {
      return;
    }
    await initStore(this.context);
    const profiles = await loadProfiles();
    for (const p of collected) {
      p.id = this.genId();
      p.updatedAt = Date.now();
      profiles.push(p);
    }
    await saveProfiles(profiles);
    this.profiles = profiles;
    promptAction.showToast({ message: $r('app.string.imported_count', collected.length) });
    this.refresh();
  }

  /**
   * 导入前确认(对齐安卓 importSubscription/importProfile 的 MaterialAlertDialog):
   * 订阅带安全提示(来源不可信会泄漏 IP),单节点仅确认名称。
   * 返回 true 表示用户同意导入。
   */
  confirmImport(isSubscription: boolean, name: string): Promise<boolean> {
    return new Promise<boolean>((resolve: (v: boolean) => void) => {
      const message = isSubscription
        ? $r('app.string.subscription_import_message', name)
        : $r('app.string.profile_import_message', name);
      AlertDialog.show({
        message: message,
        primaryButton: {
          value: $r('app.string.cancel'),
          action: () => { resolve(false); }
        },
        secondaryButton: {
          value: $r('app.string.import_confirm'),
          action: () => { resolve(true); }
        }
      });
    });
  }

  async openImportDialog(): Promise<void> {    this.importText = '';
    await initStore(this.context);
    this.importName = await readPrefString('recent_subscription_group', '');
    this.importDialog.open();
  }

  async quickImportClipboard(): Promise<void> {
    const t = await getClipboardText();
    if (t.trim().length === 0) {
      promptAction.showToast({ message: $r('app.string.clipboard_empty_paste_manually') });
      return;
    }
    await this.openImportDialog();
    this.importText = t;
  }

  async fillDialogFromClipboard(): Promise<void> {
    const t = await getClipboardText();
    this.importText = t;
    if (t.trim().length === 0) {
      promptAction.showToast({ message: $r('app.string.clipboard_empty_paste_manually') });
    }
  }

  async doImport(raw: string, requestedName: string): Promise<void> {
    try {
      const text = raw === undefined || raw === null ? '' : raw;
      if (text.trim().length === 0) {
        promptAction.showToast({ message: $r('app.string.paste_subscription_or_profile_link') });
        return;
      }
      const firstLine = text.trim().split(/[\r\n]+/)[0].trim();
      // 订阅容器 Scheme(对齐安卓 SubscriptionFoundException → importSubscription)
      if (isSagerNetSubscriptionContainer(firstLine)) {
        LogStore.addLog('[ui] 收到 sn://subscription 容器链接,该格式为 SagerNet 私有序列化,当前无法解包');
        promptAction.showToast({ message: $r('app.string.subscription_container_unsupported') });
        return;
      }
      const container = unwrapSubscriptionLink(firstLine);
      // clash://install-config 解包出的真实订阅地址;名称为空时沿用调用方传入的名称
      const importName = container !== null && container.name.length > 0 ? container.name : requestedName;
      const subscriptionUrl = container !== null ? container.url : firstLine;
      let parsed: Array<Profile> = [];
      let subUrl = '';
      let subUserinfo = '';
      if (subscriptionUrl.startsWith('http://') || subscriptionUrl.startsWith('https://')) {
        // 订阅链接:先弹确认(对齐安卓 subscription_import_message 的安全提示),再下载解析
        const confirmName = importName.trim().length > 0 ? importName.trim() : subNameOf(subscriptionUrl);
        const confirmed = await this.confirmImport(true, confirmName);
        if (!confirmed) {
          return;
        }
        promptAction.showToast({ message: $r('app.string.fetching_subscription') });
        subUrl = subscriptionUrl;
        const fetched = await fetchSubscriptionWithInfo(subscriptionUrl, this.settings.subAllowInsecure);
        const content = fetched.content;
        subUserinfo = fetched.userinfo;
        if (looksLikeClashYaml(content)) {
          const r: ClashParseResult = parseClashProxies(content);
          parsed = r.profiles;
          if (parsed.length === 0) {
            promptAction.showToast({
              message: $r('app.string.clash_skipped_count', r.skipped)
            });
            return;
          }
        } else if (looksLikeSingBoxJson(content)) {
          const r: ClashParseResult = parseSingBoxConfig(content);
          parsed = r.profiles;
          if (parsed.length === 0) {
            promptAction.showToast({
              message: $r('app.string.clash_skipped_count', r.skipped)
            });
            return;
          }
        } else {
          parsed = parseShareText(content);
        }
      } else {
        // 分享链接:解析后弹确认(对齐安卓 profile_import_message)
        parsed = parseShareText(text);
        if (parsed.length > 0) {
          const previewName = parsed.length === 1 ? parsed[0].name : '';
          const confirmed = await this.confirmImport(false, previewName);
          if (!confirmed) {
            return;
          }
        }
      }
      if (parsed.length === 0) {
        promptAction.showToast({ message: $r('app.string.no_recognizable_profiles') });
        return;
      }
      await initStore(this.context);
      const profiles = await loadProfiles();
      // 一订阅一分组:订阅导入的节点自动归入以订阅名命名的分组(不存在则创建)
      let subGroupId = '';
      if (subUrl.length > 0) {
        const nameForGroup = importName.trim().length > 0 ? importName.trim() : subNameOf(subUrl);
        subGroupId = await ensureGroupByName(nameForGroup);
      }
      for (const p of parsed) {
        p.id = this.genId();
        p.subUrl = subUrl;
        p.groupId = subGroupId;
        p.updatedAt = Date.now();
        profiles.push(p);
      }
      await saveProfiles(profiles);
      this.profiles = profiles;
      if (subUrl.length > 0) {
        await upsertSub(subUrl, subUserinfo, importName);
        this.activeConfigUrl = subUrl;
        await writePrefString('active_config_url', subUrl);
        const normalizedName = importName.trim();
        if (normalizedName.length > 0) {
          await writePrefString('recent_subscription_group', normalizedName);
        }
        const displayName = normalizedName.length > 0 ? normalizedName : subNameOf(subUrl);
        promptAction.showToast({ message: $r('app.string.imported_from_sub', parsed.length, displayName) });
      } else {
        promptAction.showToast({ message: $r('app.string.imported_count', parsed.length) });
      }
      this.refresh();
    } catch (e) {
      const msg = subErrorText(e as Object);
      LogStore.addLog(`[ui] 导入失败: ${msg}`);
      promptAction.showToast({ message: $r('app.string.import_failed_reason', msg) });
    }
  }

  private genId(): string {
    return `${Date.now()}_${Math.floor(Math.random() * 100000)}`;
  }

  // ---------------------------------------------------------------- 底部 Tab 导航

  /** 单个 Tab 的胶囊内单元(图标 + 文案):选中态用品牌色,按下带 HDS 点按光效 */
  @Builder
  private tabBarItem(index: number) {
    Column({ space: 3 }) {
      SymbolGlyph(TAB_SYMBOLS[index])
        .fontSize(21)
        .fontColor([this.activeTab === index ? $r('app.color.primary') : $r('app.color.text_3')])
      Text(TAB_LABELS[index])
        .fontSize(10.5)
        .fontWeight(this.activeTab === index ? 700 : 400)
        .fontColor(this.activeTab === index ? $r('app.color.primary') : $r('app.color.text_3'))
    }
    .width('100%')
    .height('100%')
    .justifyContent(FlexAlign.Center)
    /* 去掉点 Tab 时系统焦点框(蓝框)与 HDS 按压光源(按住时那条蓝框其实是点光效果) */
    .focusable(false)
    .focusOnTouch(false)
    .scale({
      x: this.litKey === `tabbar:${index}` ? 0.94 : 1.0,
      y: this.litKey === `tabbar:${index}` ? 0.94 : 1.0
    })
    .onTouch((event: TouchEvent) => {
      if (event.type === TouchType.Down) {
        this.litKey = `tabbar:${index}`;
      } else if (event.type === TouchType.Up || event.type === TouchType.Cancel) {
        this.litKey = '';
      }
      /* 按下抬起就先把 activeTab 切过去:标题文字、右上角动作按钮与内容同帧更新。
         以前靠 HdsTabs 的 onChange 回填,切换动画期间标题栏还是旧状态 ——
         表现为「切到订阅页后 + / 视图切换按钮才补画出来」,反方向则晚一拍消失。 */
      if (event.type === TouchType.Up && this.activeTab !== index) {
        /* 离开订阅页时把列表退回顶部:HDS 标题栏的「渐变模糊」是跟滚动偏移联动的,
           偏移退不回去,切到设置页后标题栏仍停在"已模糊"状态,
           首张卡片会被那层材质盖成灰雾。 */
        if (this.activeTab === 1) {
          this.resetSubscriptionScroll();
        }
        this.activeTab = index;
        if (index !== 2) {
          this.settingsSection = '';
        }
      }
    })
  }

  /** 把订阅页的列表/网格滚回顶部(两个子页各绑一个 Scroller,只会有一个挂载) */
  private resetSubscriptionScroll(): void {
    try {
      this.configScroller.scrollEdge(Edge.Top);
    } catch (e) {
      // 当前不在列表视图,Scroller 未绑定
    }
    try {
      this.gridScroller.scrollEdge(Edge.Top);
    } catch (e) {
      // 当前不在块状视图,Scroller 未绑定
    }
  }



  // ---------------------------------------------------------------- 配置页(对齐安卓 ConfigurationFragment)


  @Builder
  private modeSwitchRow() {
    Row({ space: 8 }) {
      ForEach(OUTBOUND_MODES, (mode: string, index: number) => {
        Button(OUTBOUND_MODE_LABELS[index])
          .layoutWeight(1)
          .height(28)
          .fontSize(12.5)
          /* 选中 = 品牌色实心胶囊 + 表面色文字(原来只有下缘一条细线,用户看不出选中) */
          .backgroundColor(this.settings.mode === mode ? $r('app.color.primary') : Color.Transparent)
          .fontColor(this.settings.mode === mode ? $r('app.color.surface') : $r('app.color.text_3'))
          .fontWeight(this.settings.mode === mode ? 700 : 400)
          .borderRadius(14)
          .visualEffect(pressLightEffect(this.litKey === `mode:${mode}`, true))
          .onTouch((event: TouchEvent) => {
            if (event.type === TouchType.Down) {
              this.litKey = `mode:${mode}`;
            } else if (event.type === TouchType.Up || event.type === TouchType.Cancel) {
              this.litKey = '';
            }
          })
          .onClick(() => { void this.switchOutboundMode(mode); })
      }, (mode: string) => mode)
    }
    .width('100%')
    .padding({ left: UiSpec.PAGE_PADDING, right: UiSpec.PAGE_PADDING, top: 0 })
    /* ⚠️ 这里**不要**挂 illuminatedEffect():点光的受光边框是**矩形**(不吃 borderRadius),
       整条模式行会被画成一个无圆角的方框(用户实测嫌难看) */
  }

  @Builder
  private groupContextMenu(groupId: string) {
    Column() {
      MenuItem({ content: $r('app.string.test_current_group') })
        .onClick(() => this.runGroupSpeedTest(groupId))
      MenuItem({ content: $r('app.string.clear_test_results') })
        .onClick(() => this.clearTestResults(groupId))
      MenuItem({ content: $r('app.string.dedup_action') })
        .onClick(() => this.dedupGroup(groupId))
      MenuItem({ content: $r('app.string.delete_unavailable') })
        .onClick(() => this.deleteUnavailable(groupId))
    }
  }

  @Builder
  private nodeCard(p: Profile) {
    // 对齐安卓 layout_profile:圆角卡片 + 选中描边 + 类型徽标 + 延迟着色
    Column({ space: 5 }) {
      Row({ space: 6 }) {
        if (p.pinned) {
          /* 原来是 emoji 📌:emoji 的字形/配色由系统字体决定,深浅色与多设备下观感不可控 ⇒ 换系统符号 */
          SymbolGlyph($r('sys.symbol.star_fill'))
            .fontSize(11)
            .fontColor([$r('app.color.warning')])
        }
        Text(p.name)
          .fontSize(14.5)
          .fontWeight(this.selectedId === p.id ? 800 : 600)
          .fontColor($r('app.color.text_1'))
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .layoutWeight(1)
        Text(this.latencyText(p).toString().length === 0 ? '—' : this.latencyText(p))
          .fontSize(12.5)
          .fontColor(this.latencyColor(p))
      }
      .width('100%')

      Row({ space: 6 }) {
        Text(profileTypeLabel(p.type))
          .fontSize(10)
          .fontWeight(600)
          .fontColor($r('app.color.mono'))
          .padding({ left: 6, right: 6, top: 2, bottom: 2 })
          .borderRadius(6)
          .backgroundColor($r('app.color.surface_selected'))
        if (this.settings.alwaysShowAddress) {
          Text(p.server)
            .fontSize(10.5)
            .fontColor($r('app.color.text_3'))
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .layoutWeight(1)
        } else {
          // 空白占位,保证徽标行与「始终显示地址」模式对齐
          Text('').layoutWeight(1)
        }
        if (this.settings.profileTrafficStatistics && (p.rx > 0 || p.tx > 0)) {
          // 历史累计流量(对齐安卓节点卡流量显示):↓接收 ↑发送
          Text(`↓${formatBytes(p.rx)} ↑${formatBytes(p.tx)}`)
            .fontSize(10)
            .fontColor($r('app.color.text_3'))
            .maxLines(1)
        }
      }
      .width('100%')
    }
    .alignItems(HorizontalAlign.Start)
    .width('100%')
    .padding({ left: 14, right: 14, top: 11, bottom: 11 })
    .backgroundColor($r('app.color.surface'))
    .borderRadius(14)
    .border({ width: 1.5, color: this.selectedId === p.id ? $r('app.color.primary') : Color.Transparent })
    .shadow({ radius: 6, color: $r('app.color.shadow_color'), offsetY: 1 })
    /* 点按光效:节点卡在 List 里(会跟滚动跑位),按官方"不要在滚动组件里用常亮光源"的口径,
       只让它在**按下那一刻**成为光源(此刻内容是静止的),不挂常亮光源、也不挂受光(卡片自身有 border,
       受光会被 border 覆盖掉,配了也看不见)。 */
    .visualEffect(pressLightEffect(this.litKey === `node:${p.id}`, false))
    .onTouch((event: TouchEvent) => {
      if (event.type === TouchType.Down) {
        this.litKey = `node:${p.id}`;
      } else if (event.type === TouchType.Up || event.type === TouchType.Cancel) {
        this.litKey = '';
      }
    })
    .onClick(() => this.onNodeTap(p))
    .bindContextMenu(this.profileContextMenu(p), ResponseType.LongPress, {
          /* 光感背板：系统菜单窗口自己那层底太素(纯色板)，给它换成 HDS 同族的毛玻璃 */
          backgroundBlurStyle: BlurStyle.COMPONENT_THICK,
          backgroundBlurStyleOptions: {
            colorMode: ThemeColorMode.SYSTEM,
            adaptiveColor: AdaptiveColor.AVERAGE
          }
        })
  }

  /**
   * 块状视图的节点卡(参考 FlClash 的网格卡):名称 + 协议 + 延迟,选中态描边 + 右上角勾。
   * 与列表卡共用同一套点按光效/长按菜单/点击逻辑,只是尺寸更紧凑、固定等高便于对齐。
   */
  @Builder
  private gridNodeCard(p: Profile) {
    Column({ space: 4 }) {
      Row({ space: 4 }) {
        if (p.pinned) {
          SymbolGlyph($r('sys.symbol.star_fill'))
            .fontSize(10)
            .fontColor([$r('app.color.warning')])
        }
        Text(p.name)
          .fontSize(13)
          .fontWeight(this.selectedId === p.id ? 700 : 600)
          .fontColor($r('app.color.text_1'))
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .layoutWeight(1)
        if (this.selectedId === p.id) {
          SymbolGlyph($r('sys.symbol.checkmark_circle_fill'))
            .fontSize(14)
            .fontColor([$r('app.color.primary')])
        }
      }
      .width('100%')

      Text(profileTypeLabel(p.type))
        .fontSize(10)
        .fontColor($r('app.color.text_3'))
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })

      Blank()

      Text(this.latencyText(p))
        .fontSize(12)
        .fontColor(this.latencyColor(p))
    }
    .alignItems(HorizontalAlign.Start)
    .width('100%')
    .height(96)
    .padding({ left: 12, right: 12, top: 10, bottom: 10 })
    .backgroundColor(this.selectedId === p.id ? $r('app.color.surface_selected') : $r('app.color.surface'))
    .borderRadius(14)
    .border({ width: 1.5, color: this.selectedId === p.id ? $r('app.color.primary') : Color.Transparent })
    .shadow({ radius: 6, color: $r('app.color.shadow_color'), offsetY: 1 })
    .visualEffect(pressLightEffect(this.litKey === `node:${p.id}`, false))
    .onTouch((event: TouchEvent) => {
      if (event.type === TouchType.Down) {
        this.litKey = `node:${p.id}`;
      } else if (event.type === TouchType.Up || event.type === TouchType.Cancel) {
        this.litKey = '';
      }
    })
    .onClick(() => this.onNodeTap(p))
    .bindContextMenu(this.profileContextMenu(p), ResponseType.LongPress, {
      backgroundBlurStyle: BlurStyle.COMPONENT_THICK,
      backgroundBlurStyleOptions: {
        colorMode: ThemeColorMode.SYSTEM,
        adaptiveColor: AdaptiveColor.AVERAGE
      }
    })
  }

  /** 块状视图的列模板(按 gridColumns 拼 1fr) */
  private gridTemplate(): string {
    let template = '1fr';
    for (let i = 1; i < this.gridColumns; i++) {
      template += ' 1fr';
    }
    return template;
  }

  /** 块状视图:顶部同样垫占位项,让卡片能滚到顶栏后面 */
  @Builder
  private nodeGrid() {
    Grid(this.gridScroller) {
      GridItem() {
        Row()
          .width('100%')
          .height(Math.max(0, this.contentTopInset - 8))
      }
      .columnStart(0)
      .columnEnd(this.gridColumns - 1)

      ForEach(this.visibleProfiles(this.selectedGroupId), (profile: Profile) => {
        GridItem() {
          this.gridNodeCard(profile)
        }
      }, (profile: Profile) => profile.id)
    }
    .columnsTemplate(this.gridTemplate())
    .columnsGap(8)
    .rowsGap(8)
    .edgeEffect(EdgeEffect.Spring)
    .scrollBar(BarState.Off)
    .layoutWeight(1)
    .width('100%')
    .padding({ left: 14, right: 14, top: 0, bottom: 0 })
    .clip(false)
    .id('nbLegacyGridProbe')
  }

  /** 搜索态输入行:画在 HDS 顶栏 bottomBuilder 里,与分组条**同一条带互换**
   *  (用户点名位置:动作按钮行之下、模式行之上);总高 32,凑底部带恒 68 */
  @Builder
  private searchInputRow() {
    Row({ space: 2 }) {
      TextInput({ text: this.nodeSearch, placeholder: $r('app.string.search_nodes') })
        .id('nodeSearchInput')
        .layoutWeight(1).height(32)
        .padding({ top: 4, bottom: 4 })
        .backgroundColor(Color.Transparent)
        .border({ width: { bottom: UiSpec.HAIRLINE_WIDTH }, color: $r('app.color.hairline') })
        /* 输入防抖 250ms:每敲一个字就全量重筛 + 重建节点列表,大订阅会越打越卡 */
        .onChange((v: string) => { this.scheduleSearchFilter(v); })
      Text($r('app.string.cancel'))
        .fontSize(13).fontColor($r('app.color.text_2')).padding(6)
        .onClick(() => {
          this.closeNodeSearch();
        })
    }
    .width('100%')
    .height(32)
    .alignItems(VerticalAlign.Center)
    .padding({ left: UiSpec.PAGE_PADDING - 10, right: UiSpec.PAGE_PADDING - 10 })
  }

  @Builder
  private configFragment() {
    Column() {
      /* 原 configToolbar(连接/搜索/添加/更多)整排提进了 HDS 顶栏(stackBuilder 自绘 + ⋮ bindMenu)。
         搜索态输入行(用户点名放在动作按钮行与模式行之间)也画在顶栏 bottomBuilder 里,
         见 titleBottomBuilder()/searchInputRow();这里不再重复渲染。 */

      if (this.profiles.length === 0) {
        Column({ space: 10 }) {
          Text($r('app.string.no_profiles_title'))
            .fontSize(15).fontWeight(600).fontColor($r('app.color.text_2'))
          Text($r('app.string.no_profiles_hint'))
            .fontSize(12).fontColor($r('app.color.text_3'))
          Button($r('app.string.import_link_subscription'))
            .height(38)
            .backgroundColor($r('app.color.primary'))
            .fontColor($r('app.color.surface'))
            .onClick(() => this.openImportDialog())
        }
        .width('100%')
        .layoutWeight(1)
        .justifyContent(FlexAlign.Center)
      } else if (this.nodeViewMode === 'grid') {
        /* 块状(网格)视图:参考 FlClash,一屏多卡 */
        this.nodeGrid()
      } else {
        List({ space: 8, scroller: this.configScroller }) {
          /* ★ 顶部占位项 = 顶栏高度(自校准值):列表的**框**铺满整屏(含状态栏),
             内容最前面垫一块占位 ⇒ 滚动时条目能**穿到顶栏后面**去(RzdMusic 那种沉浸感)。
             ⚠️ 不要用 List.contentStartOffset / 容器 padding:那两样会把内容**裁在**顶栏下方,永远滚不上去 */
          ListItem() {
            Row()
              .width('100%')
              /* space:8 已经贡献 8vp,这里减掉,避免首卡与顶栏之间多一条缝。
                 搜索态下顶栏 bottomBuilder 多了一行搜索框,探针量出的 contentTopInset
                 会自动变大,占位项跟着长高,列表首卡始终落在搜索行下方 */
              .height(Math.max(0, this.contentTopInset - 8))
          }
          .selectable(false)
          ForEach(this.visibleProfiles(this.selectedGroupId), (profile: Profile) => {
            ListItem() {
              this.nodeCard(profile)
            }
          }, (profile: Profile) => profile.id)
        }
        .edgeEffect(EdgeEffect.Spring)
        .layoutWeight(1)
        .width('100%')
        .padding({ left: 14, right: 14, top: 0, bottom: 0 })
        /* 列表不裁剪自己的内容 ⇒ 条目能画到盒子顶边以外(状态栏那一段)。
           RzdVideo 首页的 `Scroll` / RzdMusic 首页的 `Scroll` 都是 `.clip(false)`(它们的内容才能顶到 y=0)。 */
        .clip(false)
        /* 探针（仅诊断用，无逻辑依赖）：hdc hilog 里可核对列表视口是否真的在窗口顶 */
        .id('nbLegacyListProbe')
      }
    }
    .width('100%')
    .height('100%')
  }

  /** 分组分类条的显示顺序(订阅分组在前、未分组殿后),与原列表口径一致 */
  private groupTabIds(): Array<string> {
    return this.displayGroupIds();
  }

  /** 选中分组失效(被删/被合并/搜索无匹配)时回落到第一个 */
  private ensureSelectedGroup(): void {
    const ids = this.groupTabIds();
    if (ids.length === 0) {
      this.selectedGroupId = '';
      return;
    }
    if (!ids.includes(this.selectedGroupId)) {
      this.selectedGroupId = ids[0];
    }
  }

  /** 分组分类条:单独一行、横向左右切换;长按弹原分组的动作菜单(测速/清空/去重/删除失效) */
  @Builder
  private groupTabBar() {
    if (this.groupTabIds().length > 0) {
      Scroll() {
        Row({ space: 8 }) {
          ForEach(this.groupTabIds(), (groupId: string) => {
            /* 宿主用 Row(不是 Button):Button + .border() 会把 borderRadius 覆盖成 0(真机踩到,chip 变方框);
               Row 加 borderRadius 才真的圆角,而且**不加 border** —— 受光(点光 BORDER_CONTENT)才不被 border 覆盖 */
            Row({ space: 6 }) {
              Text(this.groupName(groupId))
                .fontSize(14)
                .fontWeight(this.selectedGroupId === groupId ? 700 : 400)
                .fontColor(this.selectedGroupId === groupId ? $r('app.color.primary') : $r('app.color.text_2'))
                .maxLines(1)
                .textOverflow({ overflow: TextOverflow.Ellipsis })
                .constraintSize({ maxWidth: 140 })
              Text($r('app.string.group_node_count', this.visibleProfiles(groupId).length))
                .fontSize(11.5)
                .fontColor($r('app.color.text_3'))
              if (this.groupMinLatency(groupId) >= 0) {
                Text($r('app.string.group_latency_minimum', this.groupMinLatency(groupId)))
                  .fontSize(11)
                  .fontColor(this.latencyColorOfMs(this.groupMinLatency(groupId)))
              }
            }
            .alignItems(VerticalAlign.Center)
            .height(32)
            .padding({ left: 14, right: 14 })
            .borderRadius(18)
            .backgroundColor(this.selectedGroupId === groupId
              ? $r('app.color.surface_selected')
              : $r('app.color.surface'))
            /* 按下发光 + 常挂受光(周围被点亮时它也会亮),无 border ⇒ 光效不被覆盖 */
            .visualEffect(pressLightEffect(this.litKey === `tab:${groupId}`, false))
            .onTouch((event: TouchEvent) => {
              if (event.type === TouchType.Down) {
                this.litKey = `tab:${groupId}`;
              } else if (event.type === TouchType.Up) {
                this.litKey = '';
                this.selectedGroupId = groupId;
              } else if (event.type === TouchType.Cancel) {
                this.litKey = '';
              }
            })
            .bindContextMenu(this.groupContextMenu(groupId), ResponseType.LongPress, {
          backgroundBlurStyle: BlurStyle.COMPONENT_THICK,
          backgroundBlurStyleOptions: {
            colorMode: ThemeColorMode.SYSTEM,
            adaptiveColor: AdaptiveColor.AVERAGE
          }
        })
          }, (groupId: string) => groupId)
        }
        .padding({ left: UiSpec.PAGE_PADDING - 10, right: UiSpec.PAGE_PADDING - 10, top: 0, bottom: 0 })
      }
      .scrollable(ScrollDirection.Horizontal)
      .scrollBar(BarState.Off)
      .width('100%')
      .align(Alignment.Start)
    }
  }

  // ---------------------------------------------------------------- 底部 StatsBar + FAB(对齐安卓)

  @Builder
  private statsBar() {
    Row({ space: 12 }) {
      Text(`↑ ${formatSpeed(this.upSpeed)}`)
        .fontSize(12).fontColor($r('app.color.text_2'))
        .fontFamily('monospace')
      Text(`↓ ${formatSpeed(this.downSpeed)}`)
        .fontSize(12).fontColor($r('app.color.text_2'))
        .fontFamily('monospace')
      Row({ space: 6 }) {
        Circle()
          .width(7).height(7)
          .fill(this.isRunning ? $r('app.color.dot_live') : $r('app.color.text_3'))
        Text(this.statusDisplay())
          .fontSize(12).fontColor($r('app.color.text_2'))
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
      }
      .layoutWeight(1)
      .justifyContent(FlexAlign.End)
    }
    .width('100%')
    .height(44)
    .padding({ left: UiSpec.PAGE_PADDING, right: UiSpec.PAGE_PADDING })
    .border({ width: { top: UiSpec.HAIRLINE_WIDTH }, color: $r('app.color.hairline') })
    /* 节点列表挂着 .clip(false),滚动时卡片会画到本条底部边界之外 ⇒ 无背景时
       速率文字和列表文字直接重叠。半透明底色 + 组件级毛玻璃:透出的是模糊光斑,
       文字不再互相干扰,且深浅色都由资源控制 */
    .backgroundBlurStyle(BlurStyle.COMPONENT_THICK)
    .backgroundColor($r('app.color.statsbar_bg'))
    .visualEffect(pressLightEffect(this.litKey === 'statsbar', false))
    .onTouch((event: TouchEvent) => {
      if (event.type === TouchType.Down) {
        this.litKey = 'statsbar';
      } else if (event.type === TouchType.Up || event.type === TouchType.Cancel) {
        this.litKey = '';
      }
    })
    .onClick(() => {
      const target = this.selectedProfile();
      if (target !== undefined && this.isRunning) {
        this.runUrlTest(target);
      }
    })
  }

  // ---------------------------------------------------------------- HDS 顶栏(对齐 HDS 设计系统)

  /** 顶栏主标题:代理 / 订阅 / 设置(设置二级页显示分区名) */
  private sectionTitle(): ResourceStr {
    if (this.activeTab === 1) {
      return $r('app.string.tab_subscriptions');
    }
    if (this.activeTab === 2) {
      if (this.settingsSection.length > 0) {
        const index = SETTINGS_SECTION_IDS.indexOf(this.settingsSection);
        if (index >= 0) {
          return SETTINGS_SECTION_LABELS[index];
        }
      }
      return $r('app.string.tab_settings');
    }
    return $r('app.string.tab_proxy');
  }

  /** 顶栏内容(自绘):标题 + 右侧动作;设置二级页左侧带返回键 */
  @Builder
  private titleStackBuilder() {
    Row({ space: 4 }) {
      if (this.activeTab === 2 && this.settingsSection.length > 0) {
        GlowIconButton({
          symbol: $r('sys.symbol.chevron_left'),
          iconSize: 22,
          iconColor: $r('app.color.text_1'),
          onTap: () => {
            this.settingsSection = '';
          }
        })
      }
      Text(this.sectionTitle())
        .fontSize(22)
        .fontWeight(FontWeight.Bold)
        .fontColor($r('app.color.text_1'))
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .layoutWeight(1)
      this.titleActionCluster()
    }
    .width('100%')
    /* 对齐官方 App:标题左边距与页面卡片一致(列表左右 14vp),右侧图标留 6vp 呼吸位。
       HDS 的自绘 stackBuilder 不会替我们补边距,不加就会顶到屏幕边缘。 */
    .padding({ left: 14, right: 6 })
    .alignItems(VerticalAlign.Center)
    .id('nbTitleProbe')
  }

  /** 顶栏动作按钮组:代理页 = 溢出菜单;订阅页 = 新增订阅 + 列表/块状切换 */
  @Builder
  private titleActionCluster() {
    Row({ space: 4 }) {
      if (this.activeTab === 1) {
        GlowIconButton({
          symbol: $r('sys.symbol.plus'),
          iconSize: 22,
          iconColor: $r('app.color.text_1'),
          onTap: () => {
            this.addEntryDialog.open();
          }
        })
        /* 列表 / 块状视图切换(参考 FlClash):图标显示"将要切到的视图" */
        GlowIconButton({
          symbol: this.nodeViewMode === 'grid' ? $r('sys.symbol.list_square') : $r('sys.symbol.square_grid_2x2'),
          iconSize: 20,
          iconColor: $r('app.color.text_1'),
          onTap: () => {
            this.nodeViewMode = this.nodeViewMode === 'grid' ? 'list' : 'grid';
          }
        })
      }
    }
    .alignItems(VerticalAlign.Center)
  }

  /** 溢出动作（顶栏 ⋮ 的沉浸光感菜单；与改造前同一批，一个不少；排序项带当前选中勾） */
  private overflowActions(): Array<MenuItemData> {
    const items: Array<MenuItemData> = [];
    const add = (label: ResourceStr, value: string, selected: boolean): void => {
      const it: MenuItemData = new MenuItemData();
      it.label = label;
      it.value = value;
      it.selected = selected;
      items.push(it);
    };
    add($r('app.string.update_current_subscription'), 'update_sub', false);
    add($r('app.string.clear_traffic_statistics'), 'clear_traffic', false);
    add($r('app.string.clear_test_results'), 'clear_results', false);
    add($r('app.string.dedup_action'), 'dedup', false);
    add($r('app.string.delete_unavailable'), 'delete_unavailable', false);
    add($r('app.string.sort_manual'), 'sort_manual', this.settings.profileSortMode === 'manual');
    add($r('app.string.sort_latency'), 'sort_latency', this.settings.profileSortMode === 'latency');
    add($r('app.string.sort_name'), 'sort_name', this.settings.profileSortMode === 'name');
    return items;
  }

  /** 打开顶栏 ⋮ 的沉浸光感菜单（RzdSchool HdsMenu：系统菜单窗口 + 自绘面板 + 模糊背板 + 自适应取色） */
  private openOverflowMenu(): void {
    const items: Array<MenuItemData> = this.overflowActions();
    this.overflowMenu.open(this.getUIContext(), OVERFLOW_MENU_ANCHOR, items, (index: number): void => {
      if (index < 0 || index >= items.length) {
        return;
      }
      const value: string = items[index].value;
      if (value === 'update_sub') {
        this.updateCurrentSubscription();
      } else if (value === 'clear_traffic') {
        this.clearTrafficStatistics();
      } else if (value === 'clear_results') {
        this.clearTestResults('__all__');
      } else if (value === 'dedup') {
        this.dedupGroup('__all__');
      } else if (value === 'delete_unavailable') {
        this.deleteUnavailable('__all__');
      } else if (value === 'sort_manual') {
        this.setSortMode('manual');
      } else if (value === 'sort_latency') {
        this.setSortMode('latency');
      } else if (value === 'sort_name') {
        this.setSortMode('name');
      }
    });
  }
  // ---------------------------------------------------------------- 内容切换 + 骨架

  // ---------------------------------------------------------------- 首页仪表盘(连接 / 当前节点 / 内存 / 模式)

  private currentNodeName(): ResourceStr {
    const p = this.selectedProfile();
    return p === undefined ? $r('app.string.home_no_node') : p.name;
  }

  private currentNodeMeta(): string {
    const p = this.selectedProfile();
    if (p === undefined) {
      return '';
    }
    const type = profileTypeLabel(p.type);
    return p.server.length > 0 ? `${type} · ${p.server}` : type;
  }

  /** 中央大连接键:连接中显示转圈,运行时显示暂停图标 */
  @Builder
  private connectOrb() {
    Button({ type: ButtonType.Circle, stateEffect: false }) {
      Stack() {
        if (this.statusText === 'connecting' || this.statusText === 'switching') {
          LoadingProgress()
            .width(38)
            .height(38)
            .color($r('app.color.surface'))
        } else {
          SymbolGlyph(this.isRunning ? $r('sys.symbol.pause_fill') : $r('sys.symbol.play_fill'))
            .fontSize(this.isRunning ? 40 : 36)
            .fontColor([$r('app.color.surface')])
        }
      }
    }
    .width(116)
    .height(116)
    .backgroundColor(this.isRunning ? $r('app.color.fab_running') : $r('app.color.fab_bg'))
    .shadow({ radius: 24, color: 'rgba(0,0,0,0.22)', offsetY: 8 })
    .visualEffect(pressLightEffect(this.litKey === 'home:connect', true))
    .scale({ x: this.litKey === 'home:connect' ? 0.94 : 1.0, y: this.litKey === 'home:connect' ? 0.94 : 1.0 })
    .onTouch((event: TouchEvent) => {
      if (event.type === TouchType.Down) {
        this.litKey = 'home:connect';
      } else if (event.type === TouchType.Up || event.type === TouchType.Cancel) {
        this.litKey = '';
      }
    })
    .onClick(() => {
      this.toggleVpn();
    })
  }

  @Builder
  private homeDashboard() {
    Column() {
      Column({ space: 12 }) {
        Text($r('app.string.home_current_node'))
          .fontSize(12)
          .fontColor($r('app.color.text_3'))
        Text(this.currentNodeName())
          .fontSize(19)
          .fontWeight(700)
          .fontColor($r('app.color.text_1'))
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .padding({ left: 20, right: 20 })
        if (this.currentNodeMeta().length > 0) {
          Text(this.currentNodeMeta())
            .fontSize(11.5)
            .fontColor($r('app.color.text_3'))
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .padding({ left: 20, right: 20 })
        }
        this.connectOrb()
        Text(this.statusDisplay())
          .fontSize(13)
          .fontColor($r('app.color.text_2'))
      }
      .width('100%')
      .layoutWeight(1)
      .justifyContent(FlexAlign.Center)

      /* 内存占用 + 出站模式:两张信息卡(参考 FlClash);
         出站模式直接列出三档可点,内存卡用图标填补纵向空间 */
      Row({ space: 10 }) {
        Column({ space: 4 }) {
          Text($r('app.string.home_memory_label'))
            .fontSize(11.5)
            .fontColor($r('app.color.text_3'))
            .width('100%')
            .textAlign(TextAlign.Center)
          Blank()
          SymbolGlyph($r('sys.symbol.memory_module'))
            .fontSize(38)
            .fontColor([$r('app.color.text_3')])
          Blank()
          Text(`${this.memMb} MB`)
            .fontSize(20)
            .fontWeight(700)
            .fontColor($r('app.color.text_1'))
            .width('100%')
            .textAlign(TextAlign.Center)
        }
        .alignItems(HorizontalAlign.Center)
        .layoutWeight(1)
        .height(166)
        .padding({ left: 14, right: 14, top: 12, bottom: 12 })
        .backgroundColor($r('app.color.surface'))
        .borderRadius(16)
        .shadow({ radius: 6, color: $r('app.color.shadow_color'), offsetY: 1 })

        Column({ space: 6 }) {
          Text($r('app.string.outbound_mode'))
            .fontSize(11.5)
            .fontColor($r('app.color.text_3'))
          ForEach(OUTBOUND_MODES, (mode: string, index: number) => {
            Row({ space: 8 }) {
              Text(OUTBOUND_MODE_LABELS[index])
                .fontSize(14.5)
                .fontWeight(this.settings.mode === mode ? 700 : 500)
                .fontColor(this.settings.mode === mode ? $r('app.color.primary') : $r('app.color.text_1'))
                .layoutWeight(1)
              if (this.settings.mode === mode) {
                SymbolGlyph($r('sys.symbol.checkmark'))
                  .fontSize(15)
                  .fontColor([$r('app.color.primary')])
              }
            }
            .width('100%')
            .height(34)
            .padding({ left: 10, right: 10 })
            .borderRadius(10)
            .backgroundColor(this.settings.mode === mode ? $r('app.color.surface_selected') : Color.Transparent)
            .visualEffect(pressLightEffect(this.litKey === `homemode:${mode}`, false))
            .onTouch((event: TouchEvent) => {
              if (event.type === TouchType.Down) {
                this.litKey = `homemode:${mode}`;
              } else if (event.type === TouchType.Up || event.type === TouchType.Cancel) {
                this.litKey = '';
              }
            })
            .onClick(() => {
              if (this.settings.mode !== mode) {
                this.switchOutboundMode(mode);
              }
            })
          }, (mode: string) => mode)
        }
        .alignItems(HorizontalAlign.Start)
        .layoutWeight(1.45)
        .height(166)
        .padding({ left: 12, right: 12, top: 12, bottom: 12 })
        .backgroundColor($r('app.color.surface'))
        .borderRadius(16)
        .shadow({ radius: 6, color: $r('app.color.shadow_color'), offsetY: 1 })
      }
      .width('100%')
      /* 整体上移:让开底部悬浮胶囊并留出呼吸位 */
      .padding({
        left: UiSpec.PAGE_PADDING,
        right: UiSpec.PAGE_PADDING,
        top: 12,
        bottom: TAB_BAR_CONTENT_HEIGHT + this.navBottomVp + 46
      })
    }
    .width('100%')
    .height('100%')
  }

  /** 当前出站模式文案 */
  private currentModeLabel(): Resource {
    const index = OUTBOUND_MODES.indexOf(this.settings.mode);
    return index < 0 ? OUTBOUND_MODE_LABELS[0] : OUTBOUND_MODE_LABELS[index];
  }


  // ---------------------------------------------------------------- 订阅页(按订阅折叠展示节点)

  private isCollapsed(key: string): boolean {
    return this.collapsedKeys.includes(key);
  }

  private toggleCollapsed(key: string): void {
    const next = this.collapsedKeys.slice();
    const index = next.indexOf(key);
    if (index >= 0) {
      next.splice(index, 1);
    } else {
      next.push(key);
    }
    this.collapsedKeys = next;
  }

  /** 订阅内排序:延迟升序(未测/失败的排最后),同延迟按节点名 */
  private sortLatencyOf(p: Profile): number {
    let ms = this.latencies[p.id];
    if (ms === undefined && p.latencyMs !== 0) {
      ms = p.latencyMs;
    }
    if (ms === undefined || ms <= 0) {
      return Number.MAX_SAFE_INTEGER;
    }
    return ms;
  }

  private compareNode(a: Profile, b: Profile): number {
    const la = this.sortLatencyOf(a);
    const lb = this.sortLatencyOf(b);
    if (la !== lb) {
      return la - lb;
    }
    return a.name.localeCompare(b.name);
  }

  /** 订阅页的行模型:header = 订阅/未分组标题行,node = 节点卡 */
  private accordionRows(): Array<AccordionRow> {
    const rows: Array<AccordionRow> = [];
    for (const sub of this.subscriptions) {
      const nodes = this.profiles
        .filter((p: Profile) => p.subUrl === sub.url)
        .sort((a: Profile, b: Profile) => this.compareNode(a, b));
      const header = new AccordionRow();
      header.kind = 'header';
      header.key = `sub:${sub.url}`;
      header.title = sub.name.length > 0 ? sub.name : sub.url;
      header.subtitle = sub.url;
      header.count = nodes.length;
      header.sourceKey = sub.url;
      rows.push(header);
      if (!this.isCollapsed(header.key)) {
        for (const p of nodes) {
          rows.push(AccordionRow.ofProfile(p));
        }
      }
    }

    /* 本地/未分组节点(不属于任何订阅) */
    const locals = this.profiles
      .filter((p: Profile) => p.subUrl.length === 0)
      .sort((a: Profile, b: Profile) => this.compareNode(a, b));
    if (locals.length > 0) {
      const localHeader = new AccordionRow();
      localHeader.kind = 'header';
      localHeader.key = LOCAL_SECTION_KEY;
      localHeader.title = $r('app.string.home_local_section');
      localHeader.count = locals.length;
      localHeader.sourceKey = '';
      rows.push(localHeader);
      if (!this.isCollapsed(localHeader.key)) {
        for (const p of locals) {
          rows.push(AccordionRow.ofProfile(p));
        }
      }
    }
    return rows;
  }

  /** 标题行对应的一组节点(测速用) */
  private rowTargets(row: AccordionRow): Array<Profile> {
    if (row.key === LOCAL_SECTION_KEY) {
      return this.profiles.filter((p: Profile) => p.subUrl.length === 0);
    }
    return this.profiles.filter((p: Profile) => p.subUrl === row.sourceKey);
  }

  @Builder
  private accordionHeader(row: AccordionRow) {
    Row({ space: 10 }) {
      Column({ space: 3 }) {
        Row({ space: 6 }) {
          Text(row.title)
            .fontSize(15)
            .fontWeight(700)
            .fontColor($r('app.color.text_1'))
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .constraintSize({ maxWidth: '70%' })
          Text($r('app.string.group_node_count', row.count))
            .fontSize(11.5)
            .fontColor($r('app.color.text_3'))
        }
        .width('100%')

        if (row.subtitle.length > 0) {
          Text(row.subtitle)
            .fontSize(10.5)
            .fontColor($r('app.color.text_3'))
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .width('100%')
        }
      }
      .layoutWeight(1)
      .alignItems(HorizontalAlign.Start)

      /* 单个订阅:更新 + 独立测速 */
      if (row.key !== LOCAL_SECTION_KEY) {
        Text(this.updatingSubUrl === row.sourceKey
          ? $r('app.string.updating')
          : $r('app.string.update_action'))
          .fontSize(12.5)
          .fontWeight(600)
          .fontColor($r('app.color.text_2'))
          .padding({ left: 6, right: 6, top: 6, bottom: 6 })
          .onClick(() => {
            this.updateSubByUrl(row.sourceKey);
          })
      }

      Text(this.testing ? $r('app.string.speed_testing') : $r('app.string.speed_test'))
        .fontSize(12.5)
        .fontWeight(600)
        .fontColor($r('app.color.mono'))
        .padding({ left: 6, right: 6, top: 6, bottom: 6 })
        .onClick(() => {
          this.runSpeedTestFor(this.rowTargets(row));
        })

      SymbolGlyph(this.isCollapsed(row.key) ? $r('sys.symbol.chevron_down') : $r('sys.symbol.chevron_up'))
        .fontSize(16)
        .fontColor([$r('app.color.text_3')])
    }
    .width('100%')
    .padding({ left: 14, right: 12, top: 12, bottom: 12 })
    .backgroundColor($r('app.color.surface'))
    .borderRadius(14)
    .visualEffect(pressLightEffect(this.litKey === `acc:${row.key}`, false))
    .onTouch((event: TouchEvent) => {
      if (event.type === TouchType.Down) {
        this.litKey = `acc:${row.key}`;
      } else if (event.type === TouchType.Up || event.type === TouchType.Cancel) {
        this.litKey = '';
      }
    })
    .onClick(() => {
      this.toggleCollapsed(row.key);
    })
  }

  @Builder
  private subscriptionsFragment() {
    Column() {
      if (this.profiles.length === 0) {
        Column({ space: 10 }) {
          Text($r('app.string.no_profiles_title'))
            .fontSize(15).fontWeight(600).fontColor($r('app.color.text_2'))
          Text($r('app.string.no_profiles_hint'))
            .fontSize(12).fontColor($r('app.color.text_3'))
        }
        .width('100%')
        .layoutWeight(1)
        .justifyContent(FlexAlign.Center)
      } else if (this.nodeViewMode === 'grid') {
        Grid(this.gridScroller) {
          GridItem() {
            Row().width('100%').height(Math.max(0, this.contentTopInset - 8))
          }
          .columnStart(0)
          .columnEnd(this.gridColumns - 1)

          ForEach(this.accordionRows(), (row: AccordionRow) => {
            if (row.kind === 'header') {
              GridItem() {
                this.accordionHeader(row)
              }
              .columnStart(0)
              .columnEnd(this.gridColumns - 1)
            } else {
              GridItem() {
                this.gridNodeCard(row.profile)
              }
            }
          }, (row: AccordionRow) => row.key)

          /* 尾部占位:让最后一张卡能滑到悬浮胶囊上方,同时滚动时条目从胶囊后面滑出 */
          GridItem() {
            Row()
              .width('100%')
              .height(TAB_BAR_CONTENT_HEIGHT + this.navBottomVp + 24)
          }
          .columnStart(0)
          .columnEnd(this.gridColumns - 1)
        }
        .columnsTemplate(this.gridTemplate())
        .columnsGap(8)
        .rowsGap(8)
        .edgeEffect(EdgeEffect.Spring)
        .scrollBar(BarState.Off)
        .layoutWeight(1)
        .width('100%')
        .padding({ left: 14, right: 14 })
        .clip(false)
        .id('nbGridProbe')
      } else {
        List({ space: 8, scroller: this.configScroller }) {
          ListItem() {
            Row().width('100%').height(Math.max(0, this.contentTopInset - 8))
          }
          .selectable(false)

          ForEach(this.accordionRows(), (row: AccordionRow) => {
            ListItem() {
              if (row.kind === 'header') {
                this.accordionHeader(row)
              } else {
                this.nodeCard(row.profile)
              }
            }
          }, (row: AccordionRow) => row.key)

          /* 尾部占位:最后一张卡能滚到胶囊上方,滚动时条目从胶囊后面滑出 */
          ListItem() {
            Row()
              .width('100%')
              .height(TAB_BAR_CONTENT_HEIGHT + this.navBottomVp + 24)
          }
          .selectable(false)
        }
        .edgeEffect(EdgeEffect.Spring)
        .scrollBar(BarState.Off)
        .layoutWeight(1)
        .width('100%')
        .padding({ left: 14, right: 14 })
        .clip(false)
        .id('nbListProbe')
      }
    }
    .width('100%')
    .height('100%')
  }

  /** 每个 Tab 的内容壳:顶部让位 + 底部让位(悬浮胶囊) */
  @Builder
  private pageShell(tab: number) {
    Column() {
      Column() {
        if (tab === 0) {
          this.homeDashboard()
        } else if (tab === 1) {
          this.subscriptionsFragment()
        } else {
          this.settingsContent()
        }
      }
      .width('100%')
      .layoutWeight(1)
      .id(`nbBodyProbe${tab}`)
      /* 首页用实测让位;订阅页用列表占位项让位;设置页比实测再上提 10vp,与其它页观感对齐 */
      .padding({ top: tab === 0 ? this.contentTopInset : (tab === 2 ? Math.max(0, this.contentTopInset - 10) : 0) })
      .onAreaChange((_oldArea: Area, _newArea: Area) => {
        this.calibrateTopInset();
      })
    }
    .width('100%')
    .height('100%')
    /* 订阅页要让条目从底部胶囊后面滑出来 ⇒ 不在这里留白,改由列表尾部占位项让位 */
    .padding({ bottom: tab === 2 ? TAB_BAR_CONTENT_HEIGHT + this.navBottomVp + 24 : 0 })
  }

  /** 设置 Tab:二级分区页 + 入口首页 */
  @Builder
  private settingsContent() {
    if (this.settingsSection === 'general') {
      Column() {
        SettingsPage({
          onSettingsChanged: (settings: AppSettings) => {
            this.settings = settings;
          }
        })
      }
      .width('100%')
      .height('100%')
      .transition(this.settingsPaneTransition())
    } else if (this.settingsSection === 'groups') {
      Column() {
        GroupPage({
          onDataChanged: () => {
            this.refresh();
          },
          onAddSubscription: () => {
            this.addEntryDialog.open();
          }
        })
      }
      .width('100%')
      .height('100%')
      .transition(this.settingsPaneTransition())
    } else if (this.settingsSection === 'route') {
      Column() {
        RouteRulesPanel()
      }
      .width('100%')
      .height('100%')
      .transition(this.settingsPaneTransition())
    } else if (this.settingsSection === 'logs') {
      Column() {
        LogPanel()
      }
      .width('100%')
      .height('100%')
      .transition(this.settingsPaneTransition())
    } else if (this.settingsSection === 'tools') {
      Column() {
        ToolsPage()
      }
      .width('100%')
      .height('100%')
      .transition(this.settingsPaneTransition())
    } else if (this.settingsSection === 'about') {
      Column() {
        AboutPage()
      }
      .width('100%')
      .height('100%')
      .transition(this.settingsPaneTransition())
    } else {
      Column() {
        this.settingsHub()
      }
      .width('100%')
      .height('100%')
      .transition(this.settingsPaneTransition())
    }
  }

  /** 设置页二级分区切换的过渡:淡入 + 轻微上浮(来回都是同一套,不区分方向) */
  private settingsPaneTransition(): TransitionEffect {
    return TransitionEffect.OPACITY
      .animation({ duration: 180, curve: Curve.FastOutSlowIn })
      .combine(TransitionEffect.translate({ y: 12 })
        .animation({ duration: 220, curve: Curve.FastOutSlowIn }));
  }

  /** 设置首页:把原抽屉里的配置/分组/路由/日志/工具/关于收敛成二级入口 */
  @Builder
  private settingsHub() {
    Scroll() {
      Column({ space: 10 }) {
        ForEach(SETTINGS_SECTION_IDS, (id: string, index: number) => {
          Row({ space: 14 }) {
            Row() {
              SymbolGlyph(SETTINGS_SECTION_SYMBOLS[index])
                .fontSize(19)
                .fontColor([$r('app.color.primary')])
            }
            .width(38)
            .height(38)
            .justifyContent(FlexAlign.Center)
            .borderRadius(11)
            .backgroundColor($r('app.color.surface_selected'))

            Column({ space: 3 }) {
              Text(SETTINGS_SECTION_LABELS[index])
                .fontSize(15)
                .fontWeight(600)
                .fontColor($r('app.color.text_1'))
                .width('100%')
              Text(SETTINGS_SECTION_DESCS[index])
                .fontSize(11.5)
                .fontColor($r('app.color.text_3'))
                .maxLines(1)
                .textOverflow({ overflow: TextOverflow.Ellipsis })
                .width('100%')
            }
            .alignItems(HorizontalAlign.Start)
            .layoutWeight(1)

            SymbolGlyph($r('sys.symbol.chevron_right'))
              .fontSize(16)
              .fontColor([$r('app.color.text_3')])
          }
          .width('100%')
          .padding({ left: 14, right: 14, top: 12, bottom: 12 })
          .backgroundColor($r('app.color.surface'))
          .borderRadius(14)
          .shadow({ radius: 6, color: $r('app.color.shadow_color'), offsetY: 1 })
          .visualEffect(pressLightEffect(this.litKey === `settings:${id}`, false))
          .scale({
            x: this.litKey === `settings:${id}` ? 0.98 : 1.0,
            y: this.litKey === `settings:${id}` ? 0.98 : 1.0
          })
          .onTouch((event: TouchEvent) => {
            if (event.type === TouchType.Down) {
              this.litKey = `settings:${id}`;
            } else if (event.type === TouchType.Up || event.type === TouchType.Cancel) {
              this.litKey = '';
            }
          })
          /* 用 onClick 而不是「TouchType.Up 里跳转」:列表滚动时 Up 也会到这一行,
             按住条目一滑再松手就会被误判成点击直接进二级页。onClick 在滚动手势
             接管后不会触发,只有真正的点按才进。 */
          .onClick(() => {
            this.settingsSection = id;
          })
        }, (id: string) => id)

        Text(this.appVersion.length > 0 ? `PaperBox v${this.appVersion}` : 'PaperBox')
          .fontSize(10.5)
          .fontColor($r('app.color.text_3'))
          .width('100%')
          .textAlign(TextAlign.Center)
          .padding({ top: 10, bottom: 6 })
      }
      .width('100%')
      .padding({ left: 14, right: 14, top: 4 })
    }
    .scrollBar(BarState.Off)
    .edgeEffect(EdgeEffect.Spring)
    .width('100%')
    .height('100%')
    /* Scroll 默认把内容垂直居中(容器比内容高时),设置首页条目少就会整体沉到屏幕中间;
       与其它页一致,内容一律贴顶。 */
    .align(Alignment.Top)
  }

  @Builder
  private titleBottomBuilder() {
    /* 代理模式已挪到首页仪表盘、分组折叠条已挪到订阅页 ⇒ 标题栏不再挂底部带。
       高度在 shellTitleBar 里固定为 0(不再需要 nbBarBottomProbe)。 */
  }

  /**
   * HDS 标题栏配置 —— **那层"渐变模糊"是 HDS 自带的，不要自己画**（用户 2026-10-17 明确要求）：
   *  · `blurStrategy: ENABLE` + `scrollEffectOpts: IMMERSIVE_GRADIENT_BLUR`
   *    ⇒ 官方"滚动渐变模糊背板"：滚动时顶栏从透明渐变到模糊；
   *  · `systemMaterialEffect: IMMERSIVE + EXQUISITE` ⇒ 沉浸光感材质（与 RzdSchool 设置页同档）；
   *  · `avoidLayoutSafeArea: **false**` ⇒ HDS 把**背景材质**铺进状态栏，而**标题内容**仍落在状态栏下方。
   *    （RzdMusic RecommendPage 的实测注释：设成 true 会把标题再退一个状态栏 ⇒ 38..94 → 76..132vp）
   *  · 内容自绘：标题行 `content.stackBuilder`，模式行 + 分组条 `content.bottomBuilder`。
   */
  private shellTitleBar(): HdsNavigationTitleBarOptions {
    return {
      /* ★ true：整条标题栏（材质 + 内容）**再退一个状态栏高度** ⇒ 落在时钟下方。
         RzdMusic 的注释里 false 时标题在 38..94vp，是因为它的外壳根节点本来就落在安全区里；
         本工程根 Stack 挂了 ignoreLayoutSafeArea 铺满整窗 ⇒ false 会把标题排到 y=0、与状态栏文字重叠。 */
      avoidLayoutSafeArea: true,
      style: {
        blurStrategy: BlurStrategy.ENABLE,
        scrollEffectOpts: {
          scrollEffectType: ScrollEffectType.IMMERSIVE_GRADIENT_BLUR
        },
        originalStyle: {
          backgroundStyle: { backgroundColor: Color.Transparent },
          contentStyle: {
            titleStyle: { mainTitleColor: $r('app.color.text_1') },
            menuStyle: { iconColor: $r('app.color.text_1'), textColor: $r('app.color.text_1') }
          }
        },
        scrollEffectStyle: {
          contentStyle: {
            titleStyle: { mainTitleColor: $r('app.color.text_1') },
            menuStyle: { iconColor: $r('app.color.text_1'), textColor: $r('app.color.text_1') }
          }
        },
        systemMaterialEffect: {
          materialType: hdsMaterial.MaterialType.IMMERSIVE,
          materialLevel: hdsMaterial.MaterialLevel.EXQUISITE
        }
      },
      content: {
        /* ⚠️ 这里不要再自己补 padding.top：HDS 给标题行的是**固定高度的槽位**，
           自己加 44vp 会让内容溢出槽位、与 bottomBuilder 的模式行叠在一起（2.0.27 真机"上面错位"就是这个）。
           让位交给 HDS：avoidLayoutSafeArea:false 的语义 = 材质伸进状态栏、内容留在状态栏下方。 */
        stackBuilder: (): void => {
          this.titleStackBuilder();
        },
        bottomBuilder: {
          builder: (): void => {
            this.titleBottomBuilder();
          },
          /* 底部带已取消(模式行在首页、分组条在订阅页) ⇒ 高度恒 0 */
          height: 0
        }
      }
    };
  }

  /** 列表顶部占位 = HDS 标题栏底边（窗口坐标）+ 8。纯几何，不打日志。
   *  +8(用户 2026-10-17):首卡与底部带(分组条)的间距 = 节点卡间距(List space 8),
   *  占位项公式是 inset-8 再加列表 space 8 ⇒ inset 必须是 probeBottom+8 才落出 8vp 缝。 */
  private calibrateTopInset(): void {
    try {
      const ui = this.getUIContext();
      const utils = ui.getComponentUtils();
      let bar = utils.getRectangleById('nbBarBottomProbe');
      let bottomPx = bar.windowOffset.y + bar.size.height;
      if (bottomPx <= 0) {
        bar = utils.getRectangleById('nbTitleProbe');
        bottomPx = bar.windowOffset.y + bar.size.height;
      }
      const inset = Math.round(ui.px2vp(bottomPx) + 8);
      if (inset > 0 && inset < 400 && Math.abs(inset - this.contentTopInset) >= 2) {
        this.contentTopInset = inset;
      }
    } catch (e) {
    }
  }

  build() {
    /* 外壳：**HdsNavigation 开着官方标题栏**（它自带渐变模糊 + 沉浸光感材质），
       内容走 matchParent + ignoreLayoutSafeArea 铺满整窗 ⇒ 列表能从标题栏后面滚过去；
       连接 FAB 是根 Stack 的兄弟（在 Navigation 之后）⇒ 盖住内容。
       底部 Tab 用 **HdsTabs.barFloatingStyle**：官方悬浮胶囊 + 沉浸光感材质
       （systemMaterialEffect: IMMERSIVE + EXQUISITE，与顶栏同一视觉语言）。 */
    Stack({ alignContent: Alignment.TopStart }) {
      HdsNavigation(this.pathStack) {
        HdsTabs({ barPosition: BarPosition.End, index: this.activeTab, controller: this.tabsController }) {
          TabContent() {
            this.pageShell(0)
          }
          .tabBar(this.tabBarItem(0))

          TabContent() {
            this.pageShell(1)
          }
          .tabBar(this.tabBarItem(1))

          TabContent() {
            this.pageShell(2)
          }
          .tabBar(this.tabBarItem(2))
        }
        .width(LayoutPolicy.matchParent)
        .height(LayoutPolicy.matchParent)
        .barMode(BarMode.Fixed)
        .barHeight(TAB_BAR_CONTENT_HEIGHT)
        .scrollable(false)
        /* 内容从胶囊后面滚过 ⇒ 玻璃材质才有"透出内容"的沉浸感 */
        .barOverlap(true)
        .barBackgroundColor(Color.Transparent)
        /* 悬浮胶囊:固定宽度 + 左右/底部留白 + HDS 沉浸光感材质 */
        .barFloatingStyle({
          barWidth: { smallWidth: 300, mediumWidth: 320, largeWidth: 340 },
          barSideMargin: 24,
          barBottomMargin: this.navBottomVp + 10,
          systemMaterialEffect: {
            materialType: hdsMaterial.MaterialType.IMMERSIVE,
            materialLevel: hdsMaterial.MaterialLevel.EXQUISITE
          },
          /* 智感握姿已移除:胶囊固定底部居中 */
          adaptToHandedness: false,
          lightColor: $r('app.color.primary')
        })
        .onChange((index: number) => {
          if (this.activeTab === index) {
            return;
          }
          /* 兜底路径(非点击触发的切换)同样要把订阅列表退回顶部,避免标题栏模糊状态带到别的页 */
          if (this.activeTab === 1) {
            this.resetSubscriptionScroll();
          }
          this.activeTab = index;
          /* 离开设置时回到入口首页,避免下次进来还停在上次的分区 */
          this.settingsSection = '';
        })
        .ignoreLayoutSafeArea([LayoutSafeAreaType.SYSTEM], [LayoutSafeAreaEdge.TOP, LayoutSafeAreaEdge.BOTTOM])
        .backgroundColor($r('app.color.bg_page'))
        .expandSafeArea([SafeAreaType.SYSTEM, SafeAreaType.CUTOUT], [SafeAreaEdge.TOP, SafeAreaEdge.BOTTOM])
      }
      .titleMode(HdsNavigationTitleMode.MINI)
      .mode(NavigationMode.Stack)
      .titleBar(this.shellTitleBar())
      /* 顶栏渐变模糊要跟着列表滚 ⇒ 必须把列表的 Scroller 交给它(列表/块状各一个) */
      .bindToScrollable([this.configScroller, this.gridScroller])
      /* 左上角 HDS 自带的返回箭头没用（本页是根页面，栈里没有上一级）⇒ 关掉 */
      .hideBackButton(true)
      .hideToolBar(true)
      /* ⚠️ 这里**不再**挂 ignoreLayoutSafeArea：挂上整条标题栏会顶到 y=0，标题与状态栏文字重叠。
         现在 Navigation 的盒子落在安全区里 ⇒ 标题落在时钟下方；内容层自己有
         matchParent + ignoreLayoutSafeArea ⇒ 列表仍铺满整窗、能从标题栏后面滚过去。 */
      .height('100%')
      .backgroundColor($r('app.color.bg_page'))
    }
    .width('100%')
    .height('100%')
    .backgroundColor($r('app.color.bg_page'))
    .expandSafeArea([SafeAreaType.SYSTEM, SafeAreaType.CUTOUT], [SafeAreaEdge.TOP, SafeAreaEdge.BOTTOM])
    .ignoreLayoutSafeArea([LayoutSafeAreaType.SYSTEM], [LayoutSafeAreaEdge.TOP, LayoutSafeAreaEdge.BOTTOM])
  }
}

/** 分享弹窗:展示二维码(对齐安卓分享界面)+ URI 文本与复制降级入口。 */
@CustomDialog
struct ShareTextDialog {
  controller?: CustomDialogController;
  @Link text: string;
  @Link qrPixelMap: image.PixelMap | null;
  onCopy: (text: string) => void = (text: string) => {};

  build() {
    Column({ space: 12 }) {
      Text($r('app.string.share_link_title'))
        .fontSize(16)
        .fontWeight(700)
        .width('100%')
      if (this.qrPixelMap !== null) {
        Image(this.qrPixelMap)
          .width(220)
          .height(220)
          .margin({ top: 4, bottom: 4 })
          .interpolation(ImageInterpolation.None)
      }
      Text(this.text)
        .fontSize(12)
        .fontColor($r('app.color.text_secondary'))
        .copyOption(CopyOptions.LocalDevice)
        .maxLines(3)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .width('100%')
      Row({ space: 8 }) {
        Button($r('app.string.cancel'))
          .layoutWeight(1)
          .backgroundColor($r('app.color.surface'))
          .fontColor($r('app.color.text_primary'))
          .onClick(() => {
            if (this.controller !== undefined) {
              this.controller.close();
            }
          })
        Button($r('app.string.copy_share_link'))
          .layoutWeight(1)
          .backgroundColor($r('app.color.primary'))
          .onClick(() => this.onCopy(this.text))
      }
      .width('100%')
    }
    .padding(16)
    .width('100%')
  }
}

/** 导入弹窗:手动粘贴订阅链接 / 节点链接 / base64 订阅内容 */
@CustomDialog
struct ImportDialog {
  controller?: CustomDialogController;
  @Link text: string;
  @Link name: string;
  onImport: (t: string, name: string) => void = (t: string, name: string) => {
  };
  onPickClipboard: () => void = () => {
  };

  build() {
    Column({ space: 10 }) {
      Text($r('app.string.import_link_subscription'))
        .fontSize(16)
        .fontWeight(700)
      TextInput({
        text: this.name,
        placeholder: $r('app.string.subscription_name_optional')
      })
        .height(UiSpec.BTN_HEIGHT)
        .onChange((v: string) => {
          this.name = v;
        })
      TextArea({
        text: this.text,
        placeholder: $r('app.string.import_content_placeholder')
      })
        .height(120)
        .onChange((v: string) => {
          this.text = v;
        })
      Row({ space: 8 }) {
        Button($r('app.string.cancel'))
          .backgroundColor($r('app.color.surface'))
          .fontColor($r('app.color.text_primary'))
          .onClick(() => {
            if (this.controller !== undefined) {
              this.controller.close();
            }
          })
        Blank()
        Button($r('app.string.read_from_clipboard'))
          .backgroundColor($r('app.color.surface'))
          .fontColor($r('app.color.text_primary'))
          .onClick(() => this.onPickClipboard())
        Button($r('app.string.import_action'))
          .backgroundColor($r('app.color.primary'))
          .onClick(() => {
            const t = this.text;
            if (this.controller !== undefined) {
              this.controller.close();
            }
            this.onImport(t, this.name);
          })
      }
      .width('100%')
    }
    .padding(16)
    .width('100%')
  }
}

/** 统一添加入口弹窗:导入订阅 / 扫码添加 / 剪贴板导入 / 从文件导入 / 新建节点(顺序对齐安卓 add_profile_menu) */
@CustomDialog
struct AddEntryDialog {
  controller?: CustomDialogController;
  onNewProfile: () => void = () => {
  };
  onImportSubscription: () => void = () => {
  };
  onImportClipboard: () => void = () => {
  };
  onScan: () => void = () => {
  };
  onImportFile: () => void = () => {
  };

  build() {
    Column({ space: UiSpec.GAP_SM }) {
      Button($r('app.string.import_link_subscription'))
        .width('100%')
        .height(UiSpec.BTN_HEIGHT)
        .backgroundColor($r('app.color.primary'))
        .fontColor($r('app.color.surface'))
        .onClick(() => {
          if (this.controller !== undefined) {
            this.controller.close();
          }
          this.onImportSubscription();
        })
      Button($r('app.string.add_profile_methods_scan_qr_code'))
        .width('100%')
        .height(UiSpec.BTN_HEIGHT)
        .backgroundColor($r('app.color.surface'))
        .fontColor($r('app.color.text_primary'))
        .onClick(() => {
          if (this.controller !== undefined) {
            this.controller.close();
          }
          this.onScan();
        })
      Button($r('app.string.import_from_clipboard'))
        .width('100%')
        .height(UiSpec.BTN_HEIGHT)
        .backgroundColor($r('app.color.surface'))
        .fontColor($r('app.color.text_primary'))
        .onClick(() => {
          if (this.controller !== undefined) {
            this.controller.close();
          }
          this.onImportClipboard();
        })
      Button($r('app.string.action_import_file'))
        .width('100%')
        .height(UiSpec.BTN_HEIGHT)
        .backgroundColor($r('app.color.surface'))
        .fontColor($r('app.color.text_primary'))
        .onClick(() => {
          if (this.controller !== undefined) {
            this.controller.close();
          }
          this.onImportFile();
        })
      Button($r('app.string.profile_new_title'))
        .width('100%')
        .height(UiSpec.BTN_HEIGHT)
        .backgroundColor($r('app.color.surface'))
        .fontColor($r('app.color.text_primary'))
        .onClick(() => {
          if (this.controller !== undefined) {
            this.controller.close();
          }
          this.onNewProfile();
        })
    }
    .padding(UiSpec.PAGE_PADDING)
    .width('100%')
  }
}

/** 移动到分组弹窗:未分组 + 全部分组,当前分组高亮 */
@CustomDialog
struct MoveToGroupDialog {
  controller?: CustomDialogController;
  groups: Array<ProfileGroup> = [];
  currentGroupId: string = '';
  profileName: string = '';
  onPick: (groupId: string) => void = (groupId: string) => {};

  build() {
    Column({ space: 10 }) {
      Text($r('app.string.move_to_group_title'))
        .fontSize(16)
        .fontWeight(700)
        .width('100%')
      if (this.profileName.length > 0) {
        Text(this.profileName)
          .fontSize(12)
          .fontColor($r('app.color.text_secondary'))
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .width('100%')
      }
      Scroll() {
        Column({ space: 6 }) {
          Text($r('app.string.ungrouped'))
            .fontSize(13.5)
            .padding(8)
            .borderRadius(8)
            .width('100%')
            .backgroundColor(this.currentGroupId.length === 0 ? $r('app.color.primary') : $r('app.color.surface_selected'))
            .fontColor(this.currentGroupId.length === 0 ? $r('app.color.surface') : $r('app.color.text_primary'))
            .onClick(() => this.onPick(''))
          ForEach(this.groups, (g: ProfileGroup) => {
            Text(g.name)
              .fontSize(13.5)
              .padding(8)
              .borderRadius(8)
              .width('100%')
              .backgroundColor(this.currentGroupId === g.id ? $r('app.color.primary') : $r('app.color.surface_selected'))
              .fontColor(this.currentGroupId === g.id ? $r('app.color.surface') : $r('app.color.text_primary'))
              .onClick(() => this.onPick(g.id))
          }, (g: ProfileGroup) => g.id)
        }
        .width('100%')
      }
      .constraintSize({ maxHeight: 280 })
      Row({ space: 8 }) {
        Button($r('app.string.cancel'))
          .layoutWeight(1)
          .backgroundColor($r('app.color.surface'))
          .fontColor($r('app.color.text_primary'))
          .onClick(() => {
            if (this.controller !== undefined) {
              this.controller.close();
            }
          })
      }
      .width('100%')
    }
    .padding(16)
    .width('100%')
  }
}

