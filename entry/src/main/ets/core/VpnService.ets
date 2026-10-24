import vpnExtension from '@ohos.net.vpnExtension';
import Want from '@ohos.app.ability.Want';
import common from '@ohos.app.ability.common';
import backgroundTaskManager from '@ohos.resourceschedule.backgroundTaskManager';
import wantAgent from '@ohos.app.ability.wantAgent';
import { setPendingProfileId, clearPendingProfileId, LogStore } from '../model/Store';

/**
 * UI 进程侧的 VPN 开关:只负责把请求转给 VpnExtensionAbility。
 * 真正的 TUN/内核生命周期在 VpnExtAbility.ets 中完成。
 */

/** 长时任务保活心跳间隔。系统对 DATA_TRANSFER 长时任务有「长时间不更新进度即取消」的规则
 *  (见 SDK 注释:超过 10 分钟没有更新会撤销任务,通知随之消失),这里每 4 分钟刷新一次。 */
const TASK_KEEPALIVE_MS: number = 4 * 60 * 1000;

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
  /** 长时任务(连续任务)状态。这是鸿蒙上唯一能让进程后台不被挂起的机制,
   *  代价是系统会在通知栏挂一条托管通知(内容不可自定义、不能单独关闭,
   *  用户删除通知即等于停止任务)。VPN 与后台订阅更新共用这一份任务。 */
  private static taskRunning: boolean = false;
  private static taskStarting: boolean = false;
  private static taskOwner: string = '';
  /** 用户手动删除保活通知:本次连接内不再重新申请(接入规范禁止用户停止后立刻重申请) */
  private static taskUserCancelled: boolean = false;
  private static taskCancelAt: number = 0;
  private static taskCancelSubscribed: boolean = false;
  /** 长时任务保活心跳(防止系统按「长时间未更新」撤销 DATA_TRANSFER 任务) */
  private static keepAliveTimer: number = -1;
  /** 最近一次可用的 UIAbilityContext:系统撤销任务后用它重新申请 */
  private static taskContext: common.UIAbilityContext | null = null;
  /** 重新申请任务的防重入/节流 */
  private static reacquiring: boolean = false;
  private static lastReacquireAt: number = 0;
  private static reacquireCount: number = 0;
  /** 申请进行中又来了 VPN 请求:成功后把 owner 直接定成 'vpn' */
  private static preferVpnOwner: boolean = false;

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

  /** 订阅长时任务取消事件(用户删除通知 / 系统回收)。幂等。 */
  static subscribeContinuousTaskCancel(context: common.UIAbilityContext): void {
    VpnService.taskContext = context;
    if (VpnService.taskCancelSubscribed) {
      return;
    }
    VpnService.taskCancelSubscribed = true;
    try {
      backgroundTaskManager.on('continuousTaskCancel',
        (info: backgroundTaskManager.ContinuousTaskCancelInfo) => {
          VpnService.taskRunning = false;
          VpnService.taskOwner = '';
          VpnService.stopTaskKeepAlive();
          const byUser: boolean =
            info.reason === backgroundTaskManager.ContinuousTaskCancelReason.USER_CANCEL ||
              info.reason === backgroundTaskManager.ContinuousTaskCancelReason.USER_CANCEL_REMOVE_NOTIFICATION;
          if (byUser) {
            VpnService.taskUserCancelled = true;
            VpnService.taskCancelAt = Date.now();
            LogStore.addLog('[app] 用户关闭了保活通知:本次连接不再申请长时任务');
          } else {
            LogStore.addLog(`[app] 长时任务被系统取消(reason=${info.reason}),稍后自动补申请`);
            /* 系统撤销(常见于 DATA_TRANSFER 长时间无流量)不等于用户拒绝:
               VPN 仍在运行就必须把任务补回来,否则进程会被冻结、VPN 随之失联。 */
            VpnService.scheduleReacquire();
          }
        });
    } catch (e) {
      VpnService.taskCancelSubscribed = false;
      LogStore.addLog(`[app] 订阅长时任务取消事件失败: ${e}`);
    }
  }

  /** 长时任务被系统撤销后的补申请(2s 后;VPN 已停/用户主动关闭通知则放弃) */
  private static scheduleReacquire(): void {
    const ctx = VpnService.taskContext;
    if (ctx === null || VpnService.reacquiring || VpnService.taskUserCancelled) {
      return;
    }
    const profileId: string = AppStorage.get<string>('vpnRunningProfileId') ?? '';
    if (profileId.length === 0) {
      return;
    }
    const now = Date.now();
    /* 系统若因「低速率」反复撤销,补申请要退避,否则会和系统形成 2s 一次的拉锯 */
    if (now - VpnService.lastReacquireAt < 60000) {
      return;
    }
    if (VpnService.reacquireCount >= 5) {
      LogStore.addLog('[app] 长时任务被系统连续撤销,已停止补申请;VPN 可能随之被冻结');
      return;
    }
    VpnService.lastReacquireAt = now;
    VpnService.reacquireCount++;
    VpnService.reacquiring = true;
    setTimeout(() => {
      VpnService.reacquiring = false;
      if (VpnService.taskRunning) {
        return;
      }
      const stillRunning: string = AppStorage.get<string>('vpnRunningProfileId') ?? '';
      if (stillRunning.length === 0) {
        return;
      }
      void VpnService.acquireContinuousTask(ctx, 'vpn');
    }, 2000);
  }

  /** 保活心跳:每 4 分钟 updateBackgroundRunning 一次,刷新系统的「进度更新」计时 */
  private static startTaskKeepAlive(context: common.UIAbilityContext): void {
    VpnService.stopTaskKeepAlive();
    VpnService.taskContext = context;
    VpnService.keepAliveTimer = setInterval(() => {
      if (!VpnService.taskRunning) {
        return;
      }
      backgroundTaskManager.updateBackgroundRunning(context, ['dataTransfer'])
        .then(() => {
        })
        .catch((e: Object) => {
          LogStore.addLog(`[app] 长时任务心跳失败: ${e}`);
          VpnService.taskRunning = false;
          VpnService.taskOwner = '';
          VpnService.stopTaskKeepAlive();
          VpnService.scheduleReacquire();
        });
    }, TASK_KEEPALIVE_MS);
  }

  private static stopTaskKeepAlive(): void {
    if (VpnService.keepAliveTimer >= 0) {
      clearInterval(VpnService.keepAliveTimer);
      VpnService.keepAliveTimer = -1;
    }
  }

  /**
   * 申请长时任务。owner:'vpn' = VPN 保活,'subs' = 后台订阅更新。
   * 已有任务时不重复申请(共用一份,避免通知栏出现多条系统通知)。
   */
  static async acquireContinuousTask(context: common.UIAbilityContext, owner: string): Promise<void> {
    VpnService.taskContext = context;
    if (VpnService.taskRunning || VpnService.taskStarting) {
      /* 已有一份任务在跑:VPN 加入时把 owner 升级为 'vpn',
         否则后台订阅更新结束时 releaseContinuousTask('subs') 会把 VPN 的通知一起撤掉。 */
      if (owner === 'vpn') {
        if (VpnService.taskRunning) {
          VpnService.taskOwner = 'vpn';
        } else {
          VpnService.preferVpnOwner = true;
        }
      }
      return;
    }
    if (owner === 'vpn') {
      /* 用户主动重新连接(比手动关闭通知更晚)时允许重新申请;自动拉起不算 */
      const userConnectAt: number = AppStorage.get<number>('vpnUserConnectAt') ?? 0;
      if (userConnectAt > VpnService.taskCancelAt) {
        VpnService.taskUserCancelled = false;
      }
      if (VpnService.taskUserCancelled) {
        return;
      }
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
      VpnService.taskOwner = (owner === 'vpn' || VpnService.preferVpnOwner) ? 'vpn' : owner;
      VpnService.preferVpnOwner = false;
      VpnService.startTaskKeepAlive(context);
      LogStore.addLog(`[app] 长时任务已开启(${owner === 'vpn' ? 'VPN 保活' : '后台任务'}),通知由系统托管`);
    } catch (e) {
      VpnService.preferVpnOwner = false;
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
    VpnService.preferVpnOwner = false;
    VpnService.stopTaskKeepAlive();
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
   * @param userInitiated true = 用户在界面上主动连接(允许重新申请保活长时任务);
   *                      false = 看门狗自动拉起(不得在用户删掉保活通知后立刻重申请)。
   */
  static async connect(context: common.UIAbilityContext, profileId: string,
    forceRestart: boolean = false, userInitiated: boolean = true): Promise<void> {
    const generation = ++VpnService.generation;
    VpnService.clearWatchdogs();
    if (userInitiated) {
      AppStorage.setOrCreate('vpnUserConnectAt', Date.now());
      /* 用户主动连接:重新给补申请机会(此前可能因系统连续撤销而停止) */
      VpnService.reacquireCount = 0;
      VpnService.lastReacquireAt = 0;
    }
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
    /* 通知要在点下连接的瞬间出现,不能等内核启动完成(用户 2026-10-24:过几秒才显示)。
       先记下是否已有任务,连接失败时只释放本次新申请的那份。 */
    const hadTask: boolean = VpnService.taskRunning;
    const ownerBefore: string = VpnService.taskOwner;
    if (userInitiated) {
      await VpnService.acquireContinuousTask(context, 'vpn');
    }
    try {
      await vpnExtension.startVpnExtensionAbility(wantFor(context, profileId, forceRestart));
      LogStore.addLog('[app] startVpnExtensionAbility 已调用,等待扩展回调…');
    } catch (e) {
      await clearPendingProfileId();
      AppStorage.setOrCreate('vpnRunning', false);
      if (!hadTask) {
        await VpnService.releaseContinuousTask(context, 'vpn');
      } else if (ownerBefore === 'subs') {
        /* 任务原本属于后台订阅更新:把 owner 还回去,别让通知跟着这次失败的连接一直挂着 */
        VpnService.taskOwner = 'subs';
      }
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
        /* 连接没成功,通知不该继续挂在通知栏 */
        void VpnService.releaseContinuousTask(context, 'vpn');
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
    /* 通知与保活任务分开管理:用户关 VPN 就立即释放长时任务,
       系统那条保活通知随之消失,不再等扩展的 onDisconnect(它可能已被回收)。 */
    await VpnService.releaseContinuousTask(context);
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
