import common from '@ohos.app.ability.common';
import bundleManager from '@ohos.bundle.bundleManager';
import http from '@ohos.net.http';
import promptAction from '@ohos.promptAction';
import { UiSpec } from '../common/UiSpec';
import { pressLightEffect } from '../common/Effects';
import { setClipboardText } from '../utils/ClipboardHelper';

const CORE_VERSION = 'sing-box 1.14.0 (OHOS c-shared)';
const GITHUB_URL = 'https://github.com/wuqiangroy/NekoBox4Harmony';
const RELEASES_API = 'https://api.github.com/repos/wuqiangroy/NekoBox4Harmony/releases/latest';

/**
 * 关于页(对齐 NekoBoxForAndroid AboutFragment):
 * 版本、内核版本、检查更新、项目主页、开源许可。
 */
@Component
export struct AboutPage {
  @State appVersion: string = '';
  @State checking: boolean = false;
  /** 检查更新结果 / 项目主页地址:都在页内展示,不跳转 */
  @State hasUpdateMessage: boolean = false;
  @State updateMessage: ResourceStr = '';
  @State showGithub: boolean = false;
  /** 当前被按下的元素 key(检查更新 / 项目主页):"按下才亮"靠它逐颗判断 */
  @State litKey: string = '';
  private context: common.UIAbilityContext = getContext(this) as common.UIAbilityContext;

  aboutToAppear(): void {
    try {
      const info = bundleManager.getBundleInfoForSelfSync(bundleManager.BundleFlag.GET_BUNDLE_INFO_DEFAULT);
      this.appVersion = info.versionName;
    } catch (e) {
      this.appVersion = '';
    }
  }

  /** 复制项目主页地址(不跳转,点击后只写系统剪贴板并提示) */
  async copyGithub(): Promise<void> {
    try {
      await setClipboardText(GITHUB_URL);
      promptAction.showToast({ message: $r('app.string.copy_action'), duration: 1500 });
    } catch (e) {
      promptAction.showToast({ message: `${e}`, duration: 2000 });
    }
  }

  async checkUpdate(): Promise<void> {
    if (this.checking) {
      return;
    }
    this.checking = true;
    try {
      const client = http.createHttp();
      let latest = '';
      try {
        const resp = await client.request(RELEASES_API, {
          method: http.RequestMethod.GET,
          connectTimeout: 10000,
          readTimeout: 15000,
          header: { 'User-Agent': 'PaperBox' } as Record<string, string>,
          expectDataType: http.HttpDataType.STRING
        });
        if (resp.responseCode === 200) {
          const json = JSON.parse(`${resp.result}`) as Record<string, Object>;
          latest = `${json['tag_name'] ?? ''}`.replace(/^v/, '');
        }
      } finally {
        client.destroy();
      }
      if (latest.length === 0) {
        this.updateMessage = $r('app.string.check_update_failed');
      } else if (this.appVersion.length > 0 && latest === this.appVersion) {
        this.updateMessage = $r('app.string.check_update_latest');
      } else {
        this.updateMessage = $r('app.string.check_update_new', latest);
      }
    } catch (e) {
      this.updateMessage = $r('app.string.check_update_failed');
    } finally {
      this.checking = false;
      this.hasUpdateMessage = true;
    }
  }

  build() {
    Column() {
      /* 标题与抽屉入口都在壳层的 HDS 顶栏里(Index.shellTitleBar),这里不再自带页头 */

      Scroll() {
        Column({ space: 14 }) {
          Column({ space: 10 }) {
            Text($r('app.string.brand_name'))
              .fontSize(20).fontWeight(800).fontColor($r('app.color.text_1')).width('100%')
            this.InfoRow($r('app.string.settings_about_version'), this.appVersion.length > 0 ? this.appVersion : '—')
            this.InfoRow($r('app.string.about_core_version'), CORE_VERSION)
            Row() {
              Button(this.checking ? $r('app.string.checking_update') : $r('app.string.check_update'))
                .layoutWeight(1)
                .height(UiSpec.BTN_HEIGHT)
                .backgroundColor($r('app.color.surface_selected'))
                .fontColor($r('app.color.primary'))
                /* 卡片在 Scroll 里(会跟滚动跑位)⇒ 只"按下才亮",不挂常亮光源、不加 scale */
                .visualEffect(pressLightEffect(this.litKey === 'about:check', true))
                .onTouch((event: TouchEvent) => {
                  if (event.type === TouchType.Down) {
        this.litKey = 'about:check';
      } else if (event.type === TouchType.Up || event.type === TouchType.Cancel) {
        this.litKey = '';
      }
                })
                .onClick(() => this.checkUpdate())
              Button($r('app.string.about_github'))
                .layoutWeight(1)
                .height(UiSpec.BTN_HEIGHT)
                .backgroundColor($r('app.color.surface_selected'))
                .fontColor($r('app.color.text_1'))
                .visualEffect(pressLightEffect(this.litKey === 'about:github', true))
                .onTouch((event: TouchEvent) => {
                  if (event.type === TouchType.Down) {
        this.litKey = 'about:github';
      } else if (event.type === TouchType.Up || event.type === TouchType.Cancel) {
        this.litKey = '';
      }
                })
                .onClick(() => {
                  this.showGithub = !this.showGithub;
                })
            }.width('100%')

            /* 检查更新结果 / 项目主页地址就地展示 */
            if (this.hasUpdateMessage) {
              Text(this.updateMessage)
                .fontSize(12.5)
                .fontColor($r('app.color.text_2'))
                .width('100%')
            }
            if (this.showGithub) {
              Row({ space: 8 }) {
                Text(GITHUB_URL)
                  .fontSize(12.5)
                  .fontColor($r('app.color.mono'))
                  .copyOption(CopyOptions.LocalDevice)
                  .maxLines(1)
                  .textOverflow({ overflow: TextOverflow.Ellipsis })
                  .layoutWeight(1)
                Text($r('app.string.copy_action'))
                  .fontSize(12.5)
                  .fontWeight(600)
                  .fontColor($r('app.color.primary'))
                  .padding({ left: 8, right: 8, top: 4, bottom: 4 })
                  .borderRadius(8)
                  .backgroundColor($r('app.color.surface_selected'))
                  .visualEffect(pressLightEffect(this.litKey === 'about:copy', false))
                  .onTouch((event: TouchEvent) => {
                    if (event.type === TouchType.Down) {
                      this.litKey = 'about:copy';
                    } else if (event.type === TouchType.Up || event.type === TouchType.Cancel) {
                      this.litKey = '';
                    }
                  })
                  .onClick(() => {
                    this.copyGithub();
                  })
              }
              .width('100%')
            }
          }
          .alignItems(HorizontalAlign.Start)
          .width('100%')
          .padding(UiSpec.GAP_MD)
          .borderRadius(UiSpec.CARD_RADIUS)
          .backgroundColor($r('app.color.surface'))

          Column({ space: 6 }) {
            Text($r('app.string.about_license_title'))
              .fontSize(13).fontWeight(700).fontColor($r('app.color.text_2')).width('100%')
            Text($r('app.string.about_license_body'))
              .fontSize(11.5).fontColor($r('app.color.text_secondary')).width('100%')
          }
          .alignItems(HorizontalAlign.Start)
          .width('100%')
          .padding(UiSpec.GAP_MD)
          .borderRadius(UiSpec.CARD_RADIUS)
          .backgroundColor($r('app.color.surface'))
        }
        .width('100%')
        .padding({ left: UiSpec.PAGE_PADDING, right: UiSpec.PAGE_PADDING, top: 8, bottom: 20 })
      }
        .edgeEffect(EdgeEffect.Spring)
      .layoutWeight(1)
      .align(Alignment.Top)
    }
    .width('100%')
    .height('100%')
  }

  @Builder
  InfoRow(label: ResourceStr, value: string) {
    Row() {
      Text(label).fontSize(12.5).fontColor($r('app.color.text_2')).layoutWeight(1)
      Text(value)
        .fontSize(12.5).fontWeight(600).fontColor($r('app.color.text_1'))
        .fontFamily('monospace')
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
    }.width('100%')
  }
}
