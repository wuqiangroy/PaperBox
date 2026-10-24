import { VpnExtensionAbility, vpnExtension } from '@kit.NetworkKit';
import Want from '@ohos.app.ability.Want';
import connection from '@ohos.net.connection';
import common from '@ohos.app.ability.common';
import fs from '@ohos.file.fs';
import commonEventManager from '@ohos.commonEventManager';
import http from '@ohos.net.http';
import BusinessError from '@ohos.base';
import { Profile, AppSettings } from '../model/Profile';
import { initStore, loadProfiles, loadGroups, loadSettings, getPendingProfileId, setPendingProfileId, clearPendingProfileId, getRunningProfileId, setRunningProfileId, mutateProfiles, LogStore } from '../model/Store';
import { buildCoreConfig, effectiveIpv6Mode } from '../core/ConfigBuilder';
import { loadRouteRules, RouteRule, loadRemoteRuleSets, RemoteRuleSet } from '../model/RouteRule';
import { CoreManager } from '../core/CoreManager';
import { publishVpnLog, publishVpnStatus, publishVpnTraffic, VPN_EVENT_LATENCY, VPN_EVENT_APP_FOREGROUND } from '../core/VpnIpc';
import { geoReady, geoSitePath as geoSiteFile, geoIpPath as geoIpFile } from '../utils/GeoAssets';
import { fetchTrafficTotals } from '../utils/TrafficStats';

/**
 * VPN 扩展能力 — 真正的 VPN 生命周期在这里:
 *
 *   onCreate / onConnect(哪个触发都接管)→ 读待启动 Profile
 *     → 解析服务器 IP(加排除路由防回环)→ vpnConnection.create(config) 拿 TUN fd
 *     → 生成 sing-box 配置 → NAPI fork/exec 内核子进程(fd 被子进程继承)
 *   onDisconnect / onDestroy → 结束内核子进程、销毁隧道
 *
 * 每一步都写日志;关键等待有超时,卡住时能在「日志」页定位。
 */

const VPN_TUN_IFNAME = 'vpn-tun';
/** 长时任务保活探测地址:优先百度 robots(支持 Range,返回正好 1KB),失败轮换到兜底地址。
 *  这些地址只用来产生真实字节,响应内容直接丢弃,不落盘。 */
const KEEP_ALIVE_URLS: Array<string> = [
  'http://www.baidu.com/robots.txt',
  'http://connectivitycheck.platform.hicloud.com/generate_204',
  'http://www.msftconnecttest.com/connecttest.txt'
];

function withTimeout<T>(promise: Promise<T>, ms: number, what: string): Promise<T> {
  return new Promise<T>((resolve, reject) => {
    const timer = setTimeout(() => {
      reject(new Error(`${what} 超时(${Math.round(ms / 1000)}s)`));
    }, ms);
    promise.then((v: T) => {
      clearTimeout(timer);
      resolve(v);
    }, (e: Object) => {
      clearTimeout(timer);
      reject(e as Error);
    });
  });
}

export default class VpnExtAbility extends VpnExtensionAbility {
  private vpnConnection: vpnExtension.VpnConnection | null = null;
  private starting: boolean = false;
  private started: boolean = false;
  private currentRunId: string = '';
  private currentNodeName: string = '';
  private latencySubscribed: boolean = false;
  private foregroundSubscribed: boolean = false;
  private teardownPromise: Promise<void> | null = null;
  private lifecycleGeneration: number = 0;
  private restartRequested: boolean = false;
  private latestRequestedProfileId: string = '';
  private forceRestartRequested: boolean = false;
  /** 会话流量轮询:只负责把实时速率/累计流量推给 UI 进程(仪表盘用),不再发通知。
   *  通知栏只剩系统长时任务那一条(由 UI 进程申请,内容由系统托管)。 */
  private trafficTimer: number = -1;
  private trafficGeneration: number = 0;
  private trafficLastUp: number = 0;
  private trafficLastDown: number = 0;
  private trafficLastAt: number = 0;
  private trafficUpSpeed: number = 0;
  private trafficDownSpeed: number = 0;
  private sessionTotalUp: number = 0;
  private sessionTotalDown: number = 0;
  private trafficSettings: AppSettings | null = null;
  /** 防重入:轮询间隔小于请求耗时(本地 API 被内核 GC 卡住时)不能叠加并发请求 */
  private trafficInFlight: boolean = false;
  /** 上一次已推送给 UI 的数值:完全相同就不再跨进程发,空闲时省掉 1Hz 的 IPC/解析 */
  private publishedUp: number = -1;
  private publishedDown: number = -1;
  private publishedTotalUp: number = -1;
  private publishedTotalDown: number = -1;
  /** 心跳定时器:每 5s 重播一次「已连接」状态。扩展被系统回收时没有任何回调,
   *  UI 端只能靠"收不到心跳"判定 VPN 已死并复位界面状态。 */
  private heartbeatTimer: number = -1;
  /** DATA_TRANSFER 长时任务的业务凭证:每 5 分钟拉 1KB 真实字节,满足系统一致性校验。
   *  跑在扩展进程(已 protectProcessNet),走物理网卡而不是隧道,节点挂了也能完成。 */
  private keepAliveTimer: number = -1;
  private keepAliveClient: http.HttpRequest | null = null;
  private keepAliveUrlIndex: number = 0;
  private keepAliveInFlight: boolean = false;
  private keepAliveLogged: boolean = false;
  // 网络变化重置连接(功能对齐安卓 networkChangeResetConnections,2.0.2 起默认关)
  private netConnection: connection.NetConnection | null = null;
  private netChangeGeneration: number = 0;
  /** 两次网络变化强制重连的最小间隔(ms):即便用户显式打开该开关,也为共存兜底,
   *  防止被其他 VPN 应用建/拆隧道触发的网络事件连环拉进抢槽位互踢环。 */
  private lastForcedResetAt: number = 0;

  onCreate(want: Want): void {
    this.hookLifecycle('onCreate', want);
  }

  /** 本 SDK 上 startVpnExtensionAbility 实际走的是 onRequest(hilog 已证实) */
  onRequest(want: Want, startId: number): void {
    this.hookLifecycle(`onRequest(startId=${startId})`, want);
  }

  async onConnect(want: Want): Promise<void> {
    this.hookLifecycle('onConnect', want);
  }

  private hookLifecycle(name: string, want: Want): void {
    LogStore.addLog(`[vpn] 扩展 ${name}`);
    // 节点 ID 经 want 参数直达（跨进程 Preferences 缓存不刷新，不可靠）
    if (want !== undefined && want.parameters !== undefined) {
      const params = want.parameters as Record<string, Object>;
      const wantProfileId = params['profileId'];
      if (wantProfileId !== undefined && `${wantProfileId}`.length > 0) {
        this.latestRequestedProfileId = `${wantProfileId}`;
        setPendingProfileId(this.latestRequestedProfileId);
      }
      if (`${params['forceRestart']}` === 'true') {
        this.forceRestartRequested = true;
      }
    }
    LogStore.setPublisher((line: string) => {
      publishVpnLog(line);
    });
    this.subscribeLatencyEvents();
    this.subscribeForegroundEvents();
    this.registerNetworkChange();
    this.tryStart();
  }

  /**
   * 网络变化时重置连接(功能对齐安卓 networkChangeResetConnections,2.0.2 起默认关):
   * Wi-Fi/移动数据切换会造成旧 socket 全部失效,重启隧道恢复连通性。
   * 鸿蒙上其它 VPN 应用建/拆隧道也会触发本回调,因此叠加 15s 最小间隔合并突发
   * 事件(真机实证:共存互踢环的放大器就是这条链路,故默认值同步翻转为关)。
   * 短时间多次网络变化由 generation 去重,只在最后一次变化后重连一次。
   * 本 SDK 的回调挂在 NetConnection 对象上(需 register),没有自由函数 on/off。
   */
  private registerNetworkChange(): void {
    if (this.netConnection !== null) {
      return;
    }
    try {
      const conn = connection.createNetConnection();
      conn.on('netAvailable', () => {
        this.handleNetworkChange('网络可用');
      });
      conn.on('netLost', () => {
        this.handleNetworkChange('网络丢失');
      });
      conn.on('netCapabilitiesChange', () => {
        this.handleNetworkChange('网络能力变化');
      });
      conn.register((err: BusinessError) => {
        if (err) {
          LogStore.addLog(`[vpn] 注册网络变化监听失败: ${err.message}`);
        }
      });
      this.netConnection = conn;
    } catch (e) {
      LogStore.addLog(`[vpn] 创建网络监听对象失败: ${e}`);
    }
  }

  private handleNetworkChange(reason: string): void {
    if (!this.started || this.starting) {
      return;
    }
    const generation = ++this.netChangeGeneration;
    setTimeout(() => {
      if (generation !== this.netChangeGeneration) {
        // 期间又发生了网络变化,等最后一次再处理
        return;
      }
      void this.resetConnectionsAfterNetworkChange(reason);
    }, 1500);
  }

  private async resetConnectionsAfterNetworkChange(reason: string): Promise<void> {
    try {
      const settings = await loadSettings();
      if (!settings.networkChangeResetConnections) {
        return;
      }
      if (!this.started || this.starting) {
        return;
      }
      const profileId = this.currentRunId;
      if (profileId.length === 0) {
        return;
      }
      const now = Date.now();
      if (now - this.lastForcedResetAt < 15000) {
        return; // 15s 窗口内的连环网络事件(常见于另一款 VPN 应用建/拆隧道)直接合并忽略
      }
      this.lastForcedResetAt = now;
      LogStore.addLog(`[vpn] ${reason},重置连接…`);
      setPendingProfileId(profileId);
      this.forceRestartRequested = true;
      await this.teardown(true);
      await this.tryStart();
    } catch (e) {
      const msg = e instanceof Error ? e.message : `${e}`;
      LogStore.addLog(`[vpn] 网络变化重连失败: ${msg}`);
    }
  }

  private subscribeLatencyEvents(): void {
    if (this.latencySubscribed) {
      return;
    }
    this.latencySubscribed = true;
    const info: commonEventManager.CommonEventSubscribeInfo = { events: [VPN_EVENT_LATENCY] };
    commonEventManager.createSubscriber(info).then((subscriber: commonEventManager.CommonEventSubscriber) => {
      commonEventManager.subscribe(subscriber,
        (err: BusinessError, data: commonEventManager.CommonEventData) => {
          if (err || data === undefined || data.data === undefined || data.event !== VPN_EVENT_LATENCY) {
            return;
          }
          try {
            const payload = JSON.parse(data.data) as Record<string, Object>;
            const profileId: string = payload['profileId'] === undefined ? '' : `${payload['profileId']}`;
            if (!this.started || profileId !== this.currentRunId) {
              return;
            }
            const nodeName: string = payload['nodeName'] === undefined
              ? this.currentNodeName : `${payload['nodeName']}`;
            this.currentNodeName = nodeName;
          } catch (e) {
            // 忽略格式错误的测速事件
          }
        });
    }).catch((e: Object) => {
      this.latencySubscribed = false;
      LogStore.addLog(`[vpn] 延迟事件订阅失败: ${e}`);
    });
  }

  /**
   * 应用回到前台时重置连接(对齐安卓 wakeResetConnections):
   * 安卓在设备退出 Doze 闲置模式时重置;鸿蒙 SDK 无屏幕亮灭事件订阅,
   * 退而用「应用回到前台」近似(用户唤醒设备后通常会打开应用)。
   * 需手动在设置里开启,默认关闭。
   */
  private subscribeForegroundEvents(): void {
    if (this.foregroundSubscribed) {
      return;
    }
    this.foregroundSubscribed = true;
    const info: commonEventManager.CommonEventSubscribeInfo = { events: [VPN_EVENT_APP_FOREGROUND] };
    commonEventManager.createSubscriber(info).then((subscriber: commonEventManager.CommonEventSubscriber) => {
      commonEventManager.subscribe(subscriber,
        (err: BusinessError, data: commonEventManager.CommonEventData) => {
          if (err || data === undefined || data.event !== VPN_EVENT_APP_FOREGROUND) {
            return;
          }
          void this.resetConnectionsAfterWake();
        });
    }).catch((e: Object) => {
      this.foregroundSubscribed = false;
      LogStore.addLog(`[vpn] 前台事件订阅失败: ${e}`);
    });
  }

  private unsubscribeForegroundEvents(): void {
    // 与延迟事件一致:订阅随扩展生命周期存在,此处仅占位,实际注销在进程退出时由系统回收
  }

  private async resetConnectionsAfterWake(): Promise<void> {
    try {
      if (!this.started || this.starting) {
        return;
      }
      const settings = await loadSettings();
      if (!settings.wakeResetConnections) {
        return;
      }
      const profileId = this.currentRunId;
      if (profileId.length === 0) {
        return;
      }
      LogStore.addLog('[vpn] 应用回到前台,重置连接…');
      setPendingProfileId(profileId);
      this.forceRestartRequested = true;
      await this.teardown(true);
      await this.tryStart();
    } catch (e) {
      const msg = e instanceof Error ? e.message : `${e}`;
      LogStore.addLog(`[vpn] 唤醒重连失败: ${msg}`);
    }
  }

  onDisconnect(want: Want): void {
    LogStore.addLog('[vpn] 扩展 onDisconnect');
    this.lifecycleGeneration++;
    this.stopTrafficReporter();
    this.unregisterNetworkChange();
    this.unsubscribeForegroundEvents();
    this.teardown();
  }

  onDestroy(): void {
    LogStore.addLog('[vpn] 扩展 onDestroy');
    this.lifecycleGeneration++;
    this.stopTrafficReporter();
    this.unregisterNetworkChange();
    this.unsubscribeForegroundEvents();
    this.teardown();
  }

  private unregisterNetworkChange(): void {
    if (this.netConnection === null) {
      return;
    }
    const conn = this.netConnection;
    this.netConnection = null;
    try {
      conn.unregister((err: BusinessError) => {
        // 注销失败不阻断退出
      });
    } catch (e) {
      // 对象已销毁
    }
  }

  private teardown(silent: boolean = false): Promise<void> {
    if (this.teardownPromise !== null) {
      return this.teardownPromise;
    }
    this.teardownPromise = this.doTeardown(silent).finally(() => {
      this.teardownPromise = null;
    });
    return this.teardownPromise;
  }

  private async doTeardown(silent: boolean): Promise<void> {
    this.stopHeartbeat();
    this.stopTrafficReporter();
    this.stopKeepAliveHeartbeat();
    try {
      // 内核长时间闲置后可能无响应,stopCore 回调若永不触发会卡死 starting,
      // 导致之后所有启动请求被队列吞掉——这里必须带超时兜底。
      await withTimeout(CoreManager.stopCore(), 8000, '停止内核超时');
    } catch (e) {
      const msg = e instanceof Error ? e.message : `${e}`;
      LogStore.addLog(`[vpn] 停止内核失败,继续销毁隧道: ${msg}`);
    }
    if (this.vpnConnection !== null) {
      try {
        await withTimeout(this.vpnConnection.destroy(), 5000, '销毁隧道超时');
      } catch (e) {
        const msg = e instanceof Error ? e.message : `${e}`;
        LogStore.addLog(`[vpn] 销毁隧道失败: ${msg}`);
      }
      this.vpnConnection = null;
    }
    this.currentRunId = '';
    await setRunningProfileId('');
    this.started = false;
    this.starting = false;
    if (!silent) {
      publishVpnStatus('disconnected', false);
    }
  }

  private async tryStart(): Promise<void> {
    if (this.starting) {
      this.restartRequested = true;
      LogStore.addLog('[vpn] 正在启动中,记录最新请求并在当前操作结束后处理');
      return;
    }
    // 防重入标记必须在任何一个 await 之前同步置位:
    // onCreate/onRequest 会在同一瞬间连发,否则会出现双重启动互拆
    this.starting = true;
    this.restartRequested = false;
    const generation = ++this.lifecycleGeneration;
    try {
      const context: common.Context = this.context;
      await initStore(context);
      let pendingId = this.latestRequestedProfileId.length > 0
        ? this.latestRequestedProfileId : await getPendingProfileId();
      /* 自愈(对齐 FlClash 的重连语义):扩展若是被系统回收后重新拉起,
         不会有人再带 profileId 进来。此时 running_profile_id 还留着 —— 说明上一次
         会话不是正常断开 —— 直接用它恢复连接,而不是"保持待命"让 VPN 静默消失。 */
      if (pendingId.length === 0 && !this.started) {
        const lastRunningId = await getRunningProfileId();
        if (lastRunningId.length > 0) {
          pendingId = lastRunningId;
          LogStore.addLog('[vpn] 检测到上次会话未正常结束,自动恢复连接');
        }
      }
      if (this.started) {
        if (pendingId.length === 0) {
          // UI 进程可能刚被系统回收重建(AppStorage 已重置),必须重播当前状态,
          // 否则 UI 永远停在「连接中」——这是闲置后无法启动的主要根因。
          LogStore.addLog('[vpn] 已在运行且没有新的启动目标,忽略重复触发并重播已连接状态');
          publishVpnStatus(`connected:${this.currentNodeName}`, true, this.currentRunId);
          return;
        }
        if (pendingId === this.currentRunId && !this.forceRestartRequested) {
          LogStore.addLog('[vpn] 已在运行且节点未变化,忽略重复触发并重播已连接状态');
          publishVpnStatus(`connected:${this.currentNodeName}`, true, this.currentRunId);
          await clearPendingProfileId();
          return;
        }
        const restartReason: string = pendingId === this.currentRunId ? '模式变更' : '节点切换';
        this.forceRestartRequested = false;
        LogStore.addLog(`[vpn] 检测到${restartReason},串行重启内核…`);
        publishVpnStatus('switching', true, pendingId);
        await this.teardown(true);
        this.starting = true;
        await this.startVpn(context, pendingId, generation);
      } else {
        await this.startVpn(context, pendingId, generation);
      }
    } catch (e) {
      const msg = e instanceof Error ? e.message : `${e}`;
      LogStore.addLog(`[vpn] 启动失败: ${msg}`);
      this.stopTrafficReporter();
      await clearPendingProfileId();
      await this.teardown(true);
      publishVpnStatus(`connect_failed:${msg}`, false);
    } finally {
      this.starting = false;
      if (this.restartRequested) {
        this.restartRequested = false;
        LogStore.addLog('[vpn] 继续处理启动期间收到的最新请求');
        this.tryStart();
      }
    }
  }

  private async startVpn(context: common.Context, pendingId: string, generation: number): Promise<void> {
    // ---- 0. 待启动节点 ----
    if (pendingId.length === 0) {
      // 保持扩展待命:下一次 startVpnExtensionAbility 会带着新节点再次进入
      LogStore.addLog('[vpn] 暂无待启动节点,扩展保持待命');
      this.stopHeartbeat();
      this.stopTrafficReporter();
      return;
    }
    const profiles = await loadProfiles();
    let profile: Profile | null = null;
    for (const p of profiles) {
      if (p.id === pendingId) {
        profile = p;
        break;
      }
    }
    if (profile === null) {
      throw new Error('找不到待启动的节点');
    }
    const node: Profile = profile;
    const settings = await loadSettings();
    const groups = await loadGroups();
    this.trafficSettings = settings;
    LogStore.addLog(`[vpn] 准备连接: ${node.name} (${node.server}:${node.serverPort}) [mode=${settings.mode} mtu=${settings.mtu} stack=${settings.stack} mixed=${settings.mixedPort}]`);

    // ---- 1. 防回环策略 ----
    // 不再往 VpnConfig 加"服务器 IP/32 → wlan0"排除路由:实测该路由不带网关,
    // 对公网地址无法完成 ARP(死路由),反而遮蔽默认路由导致 no route to host。
    // 防回环完全依赖 protectProcessNet(创建隧道后调用,对本进程后续 socket 生效,
    // 进程内内核的 socket 均在其中)。
    let ifname = '';
    try {
      const net: connection.NetHandle = await withTimeout(connection.getDefaultNet(), 10000, '获取默认网络');
      const props: connection.ConnectionProperties =
        await withTimeout(connection.getConnectionProperties(net), 10000, '获取网卡信息');
      ifname = props.interfaceName;
      LogStore.addLog(`[vpn] 物理网卡: ${ifname}`);
    } catch (e) {
      const msg = e instanceof Error ? e.message : `${e}`;
      LogStore.addLog(`[vpn] 获取物理网卡失败: ${msg}`);
    }
    if (settings.mode === 'global' && ifname.length === 0) {
      throw new Error('全局模式无法获取物理网卡,为防止整机断网已取消启动');
    }

    // ---- 2. VpnConfig(LinkAddress.address 是嵌套的 NetAddress 对象) ----
    // 路由只有"默认 → TUN",防回环靠 protectProcessNet。
    // 平台 VPN 与内核 TUN 是两层,规则不同(安卓 VpnService.kt:100-124):
    //   - 平台层**始终**保留 IPv4 地址/路由(含 ONLY),只有 IPv6 段随模式增删;
    //   - 内核 TUN 层则由 ConfigBuilder 按模式给出 v4-only / v6-only / 双栈。
    // 此前把内核语义套到平台层,ONLY 下删掉 IPv4 地址与路由,与安卓不一致。
    const ipv6Mode = effectiveIpv6Mode(settings);
    const dualStackOrV6Only = ipv6Mode !== 'disable';
    const addresses: Array<connection.LinkAddress> = [linkAddr('172.19.0.1', 30)];
    if (dualStackOrV6Only) {
      addresses.push(linkAddr('fdfe:dcba:9876::1', 126));
    }
    const routes: Array<vpnExtension.RouteInfo> = [buildRoute(VPN_TUN_IFNAME, '0.0.0.0', 0, true)];
    if (dualStackOrV6Only) {
      routes.push(buildRoute(VPN_TUN_IFNAME, '::', 0, true));
    }
    const config: vpnExtension.VpnConfig = {
      addresses: addresses,
      routes: routes,
      dnsAddresses: [dnsAddressForApps(settings)],
      mtu: settings.mtu,
      isIPv4Accepted: true,
      isIPv6Accepted: dualStackOrV6Only
    };
    // ---- 2.5 分应用代理(VPN 框架原生支持) ----
    const perAppList: Array<string> = settings.perAppList.split(',')
      .map((s: string) => s.trim())
      .filter((s: string) => s.length > 0);
    if (settings.perAppMode === 'exclude' && perAppList.length > 0) {
      config.blockedApplications = perAppList; // 这些应用不走 VPN
      LogStore.addLog(`[vpn] 分应用(排除): ${perAppList.join(', ')}`);
    } else if (settings.perAppMode === 'include' && perAppList.length > 0) {
      config.trustedApplications = perAppList; // 仅这些应用走 VPN
      LogStore.addLog(`[vpn] 分应用(仅这些): ${perAppList.join(', ')}`);
    }

    // ---- 3. 生成配置文件(内核日志写 log.output 文件,由日志页直读) ----
    const logPath = CoreManager.resetLogFile(context);
    let geositePath = '';
    let geoIpPath = '';
    if (settings.mode === 'rule') {
      try {
        if (geoReady(context)) {
          geositePath = geoSiteFile(context);
          geoIpPath = geoIpFile(context);
          LogStore.addLog('[vpn] Geo 分流数据就绪,cn 直连分流已启用');
        } else {
          LogStore.addLog('[vpn] Geo 数据未下载,规则模式仅私网/自定义直连');
        }
      } catch (e) {
        // ignore
      }
    }
    // 自定义路由规则(仅追加注入,不改变 DNS 与出站结构)
    let customRules: Array<RouteRule> = [];
    try {
      customRules = await loadRouteRules();
      const enabledCount = customRules.filter((r: RouteRule) => r.enabled).length;
      if (enabledCount > 0) {
        LogStore.addLog(`[vpn] 注入自定义路由规则 ${enabledCount} 条`);
      }
    } catch (e) {
      LogStore.addLog('[vpn] 读取自定义路由规则失败,本次连接忽略');
    }
    let remoteRuleSets: Array<RemoteRuleSet> = [];
    try {
      remoteRuleSets = await loadRemoteRuleSets();
      const enabledRuleSetCount = remoteRuleSets.filter((item: RemoteRuleSet) => item.enabled).length;
      if (enabledRuleSetCount > 0) {
        LogStore.addLog(`[vpn] 注入远程规则集 ${enabledRuleSetCount} 个`);
      }
    } catch (e) {
      LogStore.addLog('[vpn] 读取远程规则集失败,本次连接忽略');
    }
    const cachePath = logPath.length > 0 ? logPath.substring(0, logPath.lastIndexOf('/') + 1) + 'cache.db' : '';
    const configJson = buildCoreConfig(node, settings, ifname, logPath, geositePath, geoIpPath,
      customRules, remoteRuleSets, cachePath, profiles, groups);
    const configPath = CoreManager.writeConfigFile(context, configJson);
    LogStore.addLog(`[vpn] sing-box 配置已写入 ${configPath}`);

    // ---- 4. 创建 TUN ----
    if (this.vpnConnection === null) {
      this.vpnConnection = vpnExtension.createVpnConnection(this.context);
    }
    try {
      await this.vpnConnection.destroy();
      LogStore.addLog('[vpn] 已清理残留隧道');
    } catch (e) {
      // 正常情况:没有残留
    }
    LogStore.addLog('[vpn] 正在创建 VPN 隧道(如弹出授权框请点「允许」)…');
    publishVpnStatus('awaiting_auth', false);
    const tunFd: number = await withTimeout(this.vpnConnection.create(config), 60000,
      '创建 TUN 超时:未收到系统 VPN 授权,或系统 VPN 服务无响应');
    LogStore.addLog(`[vpn] TUN fd = ${tunFd}`);
    if (generation !== this.lifecycleGeneration) {
      throw new Error('VPN 启动已取消');
    }

    // ---- 4.5 保护本进程后续 socket 不走 VPN(防回环,API 22+) ----
    // 必须在启动内核前完成。protectProcessNet 只保护随后创建的 socket,
    // 因此 proxy outbound 和 DNS bootstrap 都会稳定走底层物理网络。
    try {
      await withTimeout(this.vpnConnection.protectProcessNet(), 10000, '防回环保护超时');
      LogStore.addLog('[vpn] protectProcessNet 成功:内核 socket 将绕过 VPN');
    } catch (e) {
      const msg = e instanceof Error ? e.message : `${e}`;
      LogStore.addLog(`[vpn] protectProcessNet 失败,终止启动并回滚 TUN: ${msg}`);
      throw new Error(`防回环保护失败: ${msg}`);
    }

    // ---- 5. 启动内核(进程内 c-shared 库,无 exec) ----
    await withTimeout(new Promise<void>((resolve, reject) => {
      CoreManager.startCore(configPath, tunFd, (err: string) => {
        if (err.length > 0) {
          LogStore.addLog(`[vpn] 内核启动失败: ${err}`);
          reject(new Error(err));
          return;
        }
        resolve();
      });
    }), 15000, 'sing-box 内核启动');
    if (!this.starting || generation !== this.lifecycleGeneration) {
      throw new Error('VPN 启动已取消');
    }
    LogStore.addLog('[vpn] 内核已启动(进程内)');
    this.started = true;
    this.currentRunId = pendingId;
    this.currentNodeName = node.name;
    await setRunningProfileId(pendingId);
    this.startTrafficReporter();
    this.startHeartbeat();
    this.startKeepAliveHeartbeat();
    publishVpnStatus(`connected:${node.name}`, true, pendingId);
    await clearPendingProfileId();
  }

  /** 心跳:只想让 UI 进程知道「扩展还活着」,内容与当前状态一致,不改变 UI 显示。 */
  private startHeartbeat(): void {
    this.stopHeartbeat();
    this.heartbeatTimer = setInterval(() => {
      if (!this.started) {
        return;
      }
      publishVpnStatus(`connected:${this.currentNodeName}`, true, this.currentRunId);
    }, 5000);
  }

  private stopHeartbeat(): void {
    if (this.heartbeatTimer >= 0) {
      clearInterval(this.heartbeatTimer);
      this.heartbeatTimer = -1;
    }
  }

  /**
   * DATA_TRANSFER 长时任务的业务凭证。
   *
   * 系统会校验 DATA_TRANSFER 任务是否真的在传数据,空闲约 10 分钟就暂停/撤销任务
   * (通知随之消失、进程失去后台豁免)。所以每 5 分钟拉 1KB 真实字节:
   *   - 百度 robots.txt 支持 Range: bytes=0-1023,返回 206 + 正好 1024 字节;
   *   - 响应直接丢弃,不落盘;
   *   - 跑在扩展进程里(已在启动时调用 protectProcessNet),socket 走物理网卡,
   *     不经过 VPN 隧道,节点不可用时心跳仍然成立。
   * 失败就轮换到兜底地址,连续失败也不会主动停(任务交给系统判定)。
   */
  private startKeepAliveHeartbeat(): void {
    this.stopKeepAliveHeartbeat();
    this.keepAliveLogged = false;
    this.keepAliveUrlIndex = 0;
    this.keepAliveTick();
    this.keepAliveTimer = setInterval(() => {
      this.keepAliveTick();
    }, 5 * 60 * 1000);
  }

  private stopKeepAliveHeartbeat(): void {
    if (this.keepAliveTimer >= 0) {
      clearInterval(this.keepAliveTimer);
      this.keepAliveTimer = -1;
    }
    if (this.keepAliveClient !== null) {
      this.keepAliveClient.destroy();
      this.keepAliveClient = null;
    }
  }

  private async keepAliveTick(): Promise<void> {
    if (this.keepAliveInFlight || !this.started) {
      return;
    }
    this.keepAliveInFlight = true;
    const url = KEEP_ALIVE_URLS[this.keepAliveUrlIndex % KEEP_ALIVE_URLS.length];
    try {
      if (this.keepAliveClient === null) {
        this.keepAliveClient = http.createHttp();
      }
      const resp = await this.keepAliveClient.request(url, {
        method: http.RequestMethod.GET,
        header: { 'Range': 'bytes=0-1023' },
        connectTimeout: 8000,
        readTimeout: 10000,
        expectDataType: http.HttpDataType.ARRAY_BUFFER
      });
      if (resp.responseCode < 200 || resp.responseCode >= 400) {
        throw new Error(`HTTP ${resp.responseCode}`);
      }
      this.keepAliveUrlIndex = 0;
      if (!this.keepAliveLogged) {
        this.keepAliveLogged = true;
        LogStore.addLog(`[vpn] 长时任务保活请求成功(${url})`);
      }
    } catch (e) {
      this.keepAliveUrlIndex = (this.keepAliveUrlIndex + 1) % KEEP_ALIVE_URLS.length;
      LogStore.addLog(`[vpn] 长时任务保活请求失败,切换地址: ${e}`);
    } finally {
      this.keepAliveInFlight = false;
    }
  }

  private startTrafficReporter(): void {
    this.stopTrafficReporter();
    const settings = this.trafficSettings;
    if (!this.started || settings === null || !settings.clashApiEnabled) {
      return;
    }
    this.trafficLastUp = 0;
    this.trafficLastDown = 0;
    this.trafficLastAt = 0;
    this.trafficUpSpeed = 0;
    this.trafficDownSpeed = 0;
    this.sessionTotalUp = 0;
    this.sessionTotalDown = 0;
    const generation = ++this.trafficGeneration;
    const poll = async (): Promise<void> => {
      if (this.trafficInFlight) {
        return;
      }
      this.trafficInFlight = true;
      try {
        const startedAt = Date.now();
        const totals = await fetchTrafficTotals(settings.clashApiPort, settings.clashApiSecret);
        if (generation !== this.trafficGeneration || !this.started || totals === null) {
          return;
        }
        if (this.trafficLastAt > 0) {
          const elapsedSeconds = Math.max(0.001, (startedAt - this.trafficLastAt) / 1000);
          this.trafficUpSpeed = Math.max(0,
            Math.round((totals.up - this.trafficLastUp) / elapsedSeconds));
          this.trafficDownSpeed = Math.max(0,
            Math.round((totals.down - this.trafficLastDown) / elapsedSeconds));
        }
        this.trafficLastUp = totals.up;
        this.trafficLastDown = totals.down;
        this.trafficLastAt = startedAt;
        this.sessionTotalUp = totals.up;
        this.sessionTotalDown = totals.down;
        /* 完全没变化就不发:空闲 VPN 不再每秒做一次 JSON + CommonEvent + UI 更新 */
        if (this.trafficUpSpeed === this.publishedUp
          && this.trafficDownSpeed === this.publishedDown
          && this.sessionTotalUp === this.publishedTotalUp
          && this.sessionTotalDown === this.publishedTotalDown) {
          return;
        }
        this.publishedUp = this.trafficUpSpeed;
        this.publishedDown = this.trafficDownSpeed;
        this.publishedTotalUp = this.sessionTotalUp;
        this.publishedTotalDown = this.sessionTotalDown;
        publishVpnTraffic(this.trafficUpSpeed, this.trafficDownSpeed,
          this.sessionTotalUp, this.sessionTotalDown);
      } finally {
        this.trafficInFlight = false;
      }
    };
    void poll();
    // 仪表盘刷新间隔(对齐安卓 speedInterval,默认 1000ms,允许 500ms~10s)
    const rawMs = settings.speedIntervalMs;
    const intervalMs = rawMs >= 500 && rawMs <= 10000 ? rawMs : 1000;
    this.trafficTimer = setInterval(() => { void poll(); }, intervalMs);
  }

  private stopTrafficReporter(): void {
    this.trafficGeneration++;
    this.trafficInFlight = false;
    this.publishedUp = -1;
    this.publishedDown = -1;
    this.publishedTotalUp = -1;
    this.publishedTotalDown = -1;
    if (this.trafficTimer >= 0) {
      clearInterval(this.trafficTimer);
      this.trafficTimer = -1;
    }
    // 会话流量累加到节点历史统计(对齐安卓 TrafficLooper.stop 的 finally traffic post)
    void this.persistSessionTraffic();
    this.trafficLastUp = 0;
    this.trafficLastDown = 0;
    this.trafficLastAt = 0;
    this.trafficUpSpeed = 0;
    this.trafficDownSpeed = 0;
    this.sessionTotalUp = 0;
    this.sessionTotalDown = 0;
  }

  /**
   * 把本次会话的上下行累计写入节点记录(对齐安卓 profileTrafficStatistics):
   * 鸿蒙无内核级按出站统计,单出站场景下会话总量即当前节点流量。
   * 开关关闭则跳过;累加后通知 UI 进程刷新节点卡显示。
   */
  private async persistSessionTraffic(): Promise<void> {
    try {
      const up = this.sessionTotalUp;
      const down = this.sessionTotalDown;
      const profileId = this.currentRunId;
      if (profileId.length === 0 || (up <= 0 && down <= 0)) {
        return;
      }
      const settings = await loadSettings();
      if (!settings.profileTrafficStatistics) {
        return;
      }
      await mutateProfiles((profiles: Array<Profile>): Array<Profile> => {
        for (let i = 0; i < profiles.length; i++) {
          if (profiles[i].id === profileId) {
            profiles[i].rx = Math.max(0, profiles[i].rx) + down;
            profiles[i].tx = Math.max(0, profiles[i].tx) + up;
            profiles[i].updatedAt = Date.now();
            break;
          }
        }
        return profiles;
      });
      publishVpnTraffic(0, 0, up, down);
    } catch (e) {
      const msg = e instanceof Error ? e.message : `${e}`;
      LogStore.addLog(`[vpn] 会话流量持久化失败: ${msg}`);
    }
  }

  private async stopSelf(): Promise<void> {
    await clearPendingProfileId();
    await this.teardown();
    LogStore.addLog('[vpn] 扩展自退出清理完成');
  }
}

function isIpLiteral(s: string): boolean {
  if (s.includes(':')) {
    return /^[0-9a-fA-F:]+$/.test(s);
  }
  const parts = s.split('.');
  if (parts.length !== 4) {
    return false;
  }
  for (const p of parts) {
    const n = Number(p);
    if (isNaN(n) || n < 0 || n > 255 || `${n}` !== p) {
      return false;
    }
  }
  return true;
}

function linkAddr(ip: string, prefix: number): connection.LinkAddress {
  const na: connection.NetAddress = { address: ip };
  const la: connection.LinkAddress = { address: na, prefixLength: prefix };
  return la;
}

function buildRoute(ifname: string, ip: string, prefix: number, isDefault: boolean): vpnExtension.RouteInfo {
  const gw: connection.NetAddress = { address: '0.0.0.0' };
  const r: vpnExtension.RouteInfo = {
    interface: ifname,
    destination: linkAddr(ip, prefix),
    gateway: gw,
    hasGateway: false,
    isDefaultRoute: isDefault
  };
  return r;
}

function hostOf(dnsUrl: string): string {
  let s = dnsUrl.trim();
  const scheme = s.indexOf('://');
  if (scheme >= 0) {
    s = s.substring(scheme + 3);
  }
  const path = s.indexOf('/');
  if (path >= 0) {
    s = s.substring(0, path);
  }
  if (s.startsWith('[')) {
    // [IPv6]:port
    const end = s.indexOf(']');
    return end > 0 ? s.substring(1, end) : s;
  }
  if (s.split(':').length === 2) {
    // host:port(IPv6 裸地址场景请用方括号书写)
    s = s.substring(0, s.indexOf(':'));
  }
  return s;
}

/** 系统在 VPN 内下发的 DNS:指向 remote(经代理),由 dns-out 劫持,防泄漏 */
function dnsAddressForApps(s: AppSettings): string {
  const h = hostOf(s.remoteDns);
  if (isIpLiteral(h)) {
    return h;
  }
  return '8.8.8.8';
}
