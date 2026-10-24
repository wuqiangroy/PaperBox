import vpnExtension from '@ohos.net.vpnExtension';
import Want from '@ohos.app.ability.Want';
import common from '@ohos.app.ability.common';
import backgroundTaskManager from '@ohos.resourceschedule.backgroundTaskManager';
import wantAgent from '@ohos.app.ability.wantAgent';
import { setPendingProfileId, clearPendingProfileId, setVpnDesired, LogStore } from '../model/Store';

/**
 * UI 进程侧的 VPN 开关:只负责把请求转给 VpnExtensionAbility。
 * 真正的 TUN/内核生命周期在 VpnExtAbility.ets 中完成。
 */

function wantFor(context: common.UIAbilityContext, profileId: string = '', forceRestart: boolean = false): Want {
  const w: Want = {
    bundleName: context.abilityInfo.bundleName,
    abilityName: 'VpnExtAbility'
  };
  // 节点 ID 和强制重启标记经 Want 直达扩展，避免依赖跨进程 Preferences 缓存。
  if (profileId.length > 0 || forceRestart) {
    const params: Record<string, Object> = {
      'profileId': profileId,
      'forceRestart': forceRestart
    };
    w.parameters = params;
  }
  return w;
}

export class VpnService {
  private static operation: Promise<void> = Promise.resolve();
  private static generation: number = 0;
  private static evidenceWatchdog: number = -1;
  private static timeoutWatchdog: number = -1;
  /** 长时任务(连续任务)状态。当前只给「后台订阅更新」用 —— 那是真实的下载任务。
   *  VPN 不再申请它:系统对 DATA_TRANSFER 有「10 分钟内必须更新实况窗进度」的校验,
   *  空闲 VPN 会被暂停/取消;而 VPN 数据面跑在 :vpn 扩展进程里,不依赖这条任务。
   *  注意:接入规范禁止在系统取消/暂停后立即重新申请,这里不再自动补申请。 */
  private static taskRunning: boolean = false;
  private static taskStarting: boolean = false;
  private static taskOwner: string = '';
  private static taskCancelSubscribed: boolean = false;

  private static clearWatchdogs(): void {
    if (VpnService.evidenceWatchdog >= 0) {
      clearTimeout(VpnService.evidenceWatchdog);
      VpnService.evidenceWatchdog = -1;
    }
    if (VpnService.timeoutWatchdog >= 0) {
      clearTimeout(VpnService.timeoutWatchdog);
      VpnService.timeoutWatchdog = -1;
    }
  }

  /**
   * 订阅长时任务事件(取消 / 暂停 / 恢复),只做诊断和状态校正。幂等。
   *
   * 系统对 DATA_TRANSFER 会做业务一致性校验:第一次判定不达标时先 suspend
   * (通知消失、应用退后台被挂起),持续不达标才 cancel。这两种都只影响
   * 「后台订阅更新」这类任务;VPN 数据面在 :vpn 扩展进程里,不受影响。
   * 另外接入规范禁止在系统取消/暂停后立即重新申请,所以这里不自动补申请。
   */
  static subscribeContinuousTaskEvents(): void {
    if (VpnService.taskCancelSubscribed) {
      return;
    }
    VpnService.taskCancelSubscribed = true;
    try {
      backgroundTaskManager.on('continuousTaskCancel',
        (info: backgroundTaskManager.ContinuousTaskCancelInfo) => {
          VpnService.taskRunning = false;
          VpnService.taskOwner = '';
          LogStore.addLog(`[app] 长时任务被取消(reason=${info.reason}),系统通知已消失`);
        });
      backgroundTaskManager.on('continuousTaskSuspend',
        (info: backgroundTaskManager.ContinuousTaskSuspendInfo) => {
          VpnService.taskRunning = false;
          VpnService.taskOwner = '';
          LogStore.addLog(`[app] 长时任务被系统暂停(reason=${info.suspendReason}),通知消失;VPN 数据面不受影响`);
        });
      backgroundTaskManager.on('continuousTaskActive',
        (info: backgroundTaskManager.ContinuousTaskActiveInfo) => {
          VpnService.taskRunning = true;
          LogStore.addLog('[app] 长时任务已恢复(回到前台自动激活)');
        });
    } catch (e) {
      VpnService.taskCancelSubscribed = false;
      LogStore.addLog(`[app] 订阅长时任务事件失败: ${e}`);
    }
  }

  /**
   * 申请长时任务。当前只给「后台订阅更新」使用(真实下载,符合 DATA_TRANSFER 场景)。
   * 已有任务时不重复申请,避免通知栏出现多条系统通知。
   */
  static async acquireContinuousTask(context: common.UIAbilityContext, owner: string): Promise<void> {
    if (VpnService.taskRunning || VpnService.taskStarting) {
      return;
    }
    VpnService.taskStarting = true;
    try {
      const agent = await wantAgent.getWantAgent({
        wants: [{
          bundleName: context.abilityInfo.bundleName,
          abilityName: 'EntryAbility'
        }],
        actionType: wantAgent.OperationType.START_ABILITY,
        requestCode: 1004,
        actionFlags: [wantAgent.WantAgentFlags.UPDATE_PRESENT_FLAG]
      });
      await backgroundTaskManager.startBackgroundRunning(
        context,
        backgroundTaskManager.BackgroundMode.DATA_TRANSFER,
        agent);
      VpnService.taskRunning = true;
      VpnService.taskOwner = owner;
      LogStore.addLog('[app] 后台下载长时任务已开启,通知由系统托管');
    } catch (e) {
      LogStore.addLog(`[app] 长时任务开启失败(${owner}): ${e}`);
    } finally {
      VpnService.taskStarting = false;
    }
  }

  /** 释放长时任务(系统通知随之消失)。owner 为空表示强制释放。 */
  static async releaseContinuousTask(context: common.UIAbilityContext, owner: string = ''): Promise<void> {
    if (!VpnService.taskRunning) {
      return;
    }
    if (owner.length > 0 && VpnService.taskOwner !== owner) {
      return;
    }
    VpnService.taskRunning = false;
    VpnService.taskOwner = '';
    try {
      await backgroundTaskManager.stopBackgroundRunning(context);
      LogStore.addLog('[app] 长时任务已释放,系统通知随之消失');
    } catch (e) {
      LogStore.addLog(`[app] 长时任务释放失败: ${e}`);
    }
  }

  static isContinuousTaskRunning(): boolean {
    return VpnService.taskRunning;
  }

  /**
   * @param userInitiated true = 用户在界面上主动连接(会持久化“期望连接”标记);
   *                      false = 看门狗自动拉起 / 启动自检恢复(不改标记)。
   */
  static async connect(context: common.UIAbilityContext, profileId: string,
    forceRestart: boolean = false, userInitiated: boolean = true): Promise<void> {
    const generation = ++VpnService.generation;
    VpnService.clearWatchdogs();
    AppStorage.setOrCreate('vpnUpSpeed', 0);
    AppStorage.setOrCreate('vpnDownSpeed', 0);
    AppStorage.setOrCreate('vpnTotalUp', 0);
    AppStorage.setOrCreate('vpnTotalDown', 0);
    const previous = VpnService.operation;
    VpnService.operation = (async (): Promise<void> => {
      try {
        await previous;
      } catch (e) {
        // A failed previous operation must not block later user requests.
      }
    await setPendingProfileId(profileId);
    AppStorage.setOrCreate('vpnStatus', 'connecting');
    if (userInitiated) {
      /* 记录用户意图:应用被系统回收后重新打开时据此自动恢复连接 */
      await setVpnDesired(true);
    }
    try {
      await vpnExtension.startVpnExtensionAbility(wantFor(context, profileId, forceRestart));
      LogStore.addLog('[app] startVpnExtensionAbility 已调用,等待扩展回调…');
    } catch (e) {
      await clearPendingProfileId();
      AppStorage.setOrCreate('vpnRunning', false);
      const msg = e instanceof Error ? e.message : `${e}`;
      AppStorage.setOrCreate('vpnStatus', `start_failed:${msg}`);
      LogStore.addLog(`[app] startVpnExtensionAbility 失败: ${msg}`);
      throw new Error(msg);
    }
    // 看门狗只报告控制面状态丢失，不再主动断开可能已经正常工作的 VPN。
    // 真机日志已证明 CommonEvent 丢失时 TUN、DNS 和代理数据面仍可能完全可用。
    VpnService.evidenceWatchdog = setTimeout(() => {
      VpnService.evidenceWatchdog = -1;
      if (generation !== VpnService.generation) {
        return;
      }
      const running: boolean = AppStorage.get<boolean>('vpnRunning') ?? false;
      const status: string = AppStorage.get<string>('vpnStatus') ?? '';
      if (!running && status === 'connecting') {
        const upSpeed: number = AppStorage.get<number>('vpnUpSpeed') ?? 0;
        const downSpeed: number = AppStorage.get<number>('vpnDownSpeed') ?? 0;
        const totalUp: number = AppStorage.get<number>('vpnTotalUp') ?? 0;
        const totalDown: number = AppStorage.get<number>('vpnTotalDown') ?? 0;
        const hasDataPlaneEvidence = upSpeed > 0 || downSpeed > 0 || totalUp > 0 || totalDown > 0;
        if (hasDataPlaneEvidence) {
          AppStorage.setOrCreate('vpnRunning', true);
          AppStorage.setOrCreate('vpnRunningProfileId', profileId);
          // 保持与 UI 状态机约定一致：已连接状态必须使用 connected:<描述> 格式。
          AppStorage.setOrCreate('vpnStatus', 'connected:running');
          LogStore.addLog('[app] VPN 状态回调缺失，但已检测到流量，按数据面状态恢复为已连接');
        }
      }
    }, 60000);
    // 长时间闲置后扩展可能对启动请求完全无响应(进程被回收/冻结残留),
    // 120s 仍停留在 connecting 就明确报错并解锁按钮,避免永远转圈。
    VpnService.timeoutWatchdog = setTimeout(() => {
      VpnService.timeoutWatchdog = -1;
      if (generation !== VpnService.generation) {
        return;
      }
      const running: boolean = AppStorage.get<boolean>('vpnRunning') ?? false;
      const status: string = AppStorage.get<string>('vpnStatus') ?? '';
      if (!running && status === 'connecting') {
        AppStorage.setOrCreate('vpnStatus', 'connect_failed:启动超时,VPN 扩展无响应,请重试或重启应用');
        AppStorage.setOrCreate('vpnRunning', false);
        LogStore.addLog('[app] 启动 120s 超时:扩展始终无状态回调,已解锁重试');
      }
    }, 120000);
    })();
    return VpnService.operation;
  }

  static async disconnect(context: common.UIAbilityContext): Promise<void> {
    ++VpnService.generation;
    VpnService.clearWatchdogs();
    const previous = VpnService.operation;
    VpnService.operation = (async (): Promise<void> => {
      try {
        await previous;
      } catch (e) {
        // Continue with teardown even if startup failed.
      }
    AppStorage.setOrCreate('vpnStatus', 'disconnecting');
    /* 用户主动断开:清掉“期望连接”标记,下次启动不再自动恢复 */
    await setVpnDesired(false);
    try {
      await vpnExtension.stopVpnExtensionAbility(wantFor(context));
    } catch (e) {
      LogStore.addLog(`[app] stopVpnExtensionAbility 失败: ${e}`);
    }
    await clearPendingProfileId();
    AppStorage.setOrCreate('vpnRunning', false);
    AppStorage.setOrCreate('vpnRunningProfileId', '');
    AppStorage.setOrCreate('vpnStatus', 'disconnected');
    })();
    return VpnService.operation;
  }

  /** 运行中切换节点:把目标节点交给扩展，由扩展在同一实例内串行重启。 */
  static async switchTo(context: common.UIAbilityContext, profileId: string): Promise<void> {
    AppStorage.setOrCreate('vpnStatus', 'switching');
    LogStore.addLog('[app] 切换节点:交由扩展串行重启');
    await VpnService.connect(context, profileId, true);
  }
}
