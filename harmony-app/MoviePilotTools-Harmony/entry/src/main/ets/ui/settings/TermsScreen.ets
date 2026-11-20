import { AppTheme, Metrics } from '../../common/Theme';

/**
 * 用户协议（对应安卓 ui/settings/TermsScreen.kt + 仓库 TERMS.md）。
 *
 * 纯静态文本：正文里不放任何 markdown 符号（#、**、>、---），
 * 上一版安卓就在这里露过 `## 四、` 这种源码符号，被用户当场发现。
 * 标题加粗交给 fontWeight，分段交给段落间距，不依赖任何渲染器。
 */

class TermsSection {
  heading: string = '';
  paragraphs: string[] = [];

  constructor(heading: string, paragraphs: string[]) {
    this.heading = heading;
    this.paragraphs = paragraphs;
  }
}

const TERMS_INTRO: string[] = [
  'MoviePilotTools · 多服务远端管理工具',
  '适用场景：对接用户自行部署的 MoviePilot、Transmission、qBittorrent、Songloft 等后端服务，APP 仅做远程状态查看与指令下发。',
  '重要提醒：APP 本地不产生、不存储、不分发任何媒体 / 种子资源。',
  '注意：本协议属于风险隔离的书面声明，无法 100% 免除法律风险；核心风控是：软件本身不内置资源、不内置种子、不托管 PT 站点、不主动引导资源下载。'
];

const TERMS_SECTIONS: TermsSection[] = [
  new TermsSection('一、软件定义', [
    '本软件【MoviePilotTools】是第三方远程管理客户端工具。',
    '本软件本身不生产、不存储、不托管、不分发任何视频、音频、种子、影视资源文件，也不提供资源检索、资源下载、资源分享服务。',
    '所有功能仅通过网络 API，连接用户自行部署、自行维护的后端服务（包含但不限于 MoviePilot、Transmission、qBittorrent、Songloft），向用户自有后端下发控制指令、展示后端返回的状态数据。',
    '所有媒体信息、种子任务、站点数据、音乐内容，全部来源于用户自己搭建的后端服务，不由本 APP 生成或提供。'
  ]),
  new TermsSection('二、用户承诺', [
    '1. 用户保证：自行拥有所部署后端服务器、存储文件的相关权限，仅使用本工具管理自身拥有合法著作权 / 使用权的媒体、文件与资源。',
    '2. 用户承诺，不会利用本工具及后端服务，未经著作权人许可，实施下载、订阅、抓取、上传、做种、分享受版权保护的影视、音乐等作品。未经授权传播版权作品属于侵权行为，严重时将涉及行政处罚乃至刑事责任。',
    '3. 用户知晓：PT 站点、BT 做种等相关操作存在版权风险，所有站点账号、流量、种子任务均由用户独立管理，与本软件开发者无关。'
  ]),
  new TermsSection('三、免责与责任划分', [
    '1. 本工具仅提供远程管理的技术通道，无法审查、识别、判断用户后端服务中的文件、种子、媒体内容是否侵权；开发者无法访问、查看用户后端内的私有文件。',
    '2. 用户利用本软件、搭配后端服务实施的任何侵权、违法操作，全部法律责任由用户独立承担，软件开发者不承担任何连带、补充责任。',
    '3. 因用户服务器故障、网络异常、第三方 Tracker / PT 站点、MoviePilot / qB / Tr / Songloft 后端本身产生的数据丢失、账号封禁、版权投诉、行政处罚、民事索赔等全部损失，均由用户自行承担。',
    '4. 在法律允许最大范围内，开发者不承担任何间接损失、衍生损害赔偿责任。若版权权利人向开发者提交有效侵权通知，开发者可配合转达通知，但无义务审查用户私有后端内的内容。'
  ]),
  new TermsSection('四、软件使用约定', [
    '1. 本工具不内置种子库、资源广场、PT 站点入口、资源推荐等功能；APP 仅作为连接用户自有后端的控制器。',
    '2. 禁止用户利用本软件从事违反中华人民共和国法律法规的行为，一旦违规，开发者有权终止使用权限。',
    '3. 软件内展示的影视海报、影片名称、评分等元数据，均是用户后端 MoviePilot 服务拉取返回的数据，并非本 APP 内置资源。'
  ])
];

const TERMS_OUTRO: string[] = [
  '继续使用本软件即表示你已阅读、理解并同意上述全部条款。若不同意，请停止使用并卸载。',
  '最后更新：2026-11-16'
];

@Component
export struct TermsScreen {
  @Consume('oiiTheme') theme: AppTheme;
  @Consume('navStack') navStack: NavPathStack;

  build() {
    NavDestination() {
      Column() {
        // ---- 头部 ----
        Row() {
          Stack() {
            Circle().width(34).height(34).fill(this.theme.colors.card)
            Text('←').fontSize(18).fontColor(this.theme.colors.textPrimary)
          }
          .width(34)
          .height(34)
          .onClick((): void => {
            this.navStack.pop();
          })
          Blank()
          Text('用户协议')
            .fontSize(this.theme.fs(17))
            .fontWeight(FontWeight.Medium)
            .fontColor(this.theme.colors.textPrimary)
          Blank()
          // 与左侧返回键等宽，保证标题真正居中
          Column().width(34).height(34)
        }
        .width('100%')
        .padding({ left: Metrics.pagePadding, right: Metrics.pagePadding, top: 10, bottom: 10 })
        .alignItems(VerticalAlign.Center)

        List() {
          // ---- 抬头 ----
          ListItem() {
            Column() {
              Text('用户协议')
                .fontSize(this.theme.fs(20))
                .fontWeight(FontWeight.Bold)
                .fontColor(this.theme.colors.textPrimary)
              ForEach(TERMS_INTRO, (line: string, idx: number): void => {
                Text(line)
                  .fontSize(this.theme.fs(13))
                  .fontColor(idx === 0 ? this.theme.colors.textPrimary : this.theme.colors.textSecondary)
                  .fontWeight(idx === 0 ? FontWeight.Medium : FontWeight.Normal)
                  .lineHeight(this.theme.fs(20))
                  .margin({ top: idx === 0 ? 10 : 8 })
                  .width('100%')
              }, (line: string, idx: number): string => `i${idx}`)
            }
            .width('100%')
            .alignItems(HorizontalAlign.Start)
            .padding(14)
            .borderRadius(14)
            .backgroundColor(this.theme.colors.card)
          }

          // ---- 正文四节 ----
          ForEach(TERMS_SECTIONS, (section: TermsSection): void => {
            ListItem() {
              Column() {
                Text(section.heading)
                  .fontSize(this.theme.fs(15))
                  .fontWeight(FontWeight.Bold)
                  .fontColor(this.theme.colors.textPrimary)
                  .width('100%')
                ForEach(section.paragraphs, (p: string, idx: number): void => {
                  Text(p)
                    .fontSize(this.theme.fs(13))
                    .fontColor(this.theme.colors.textSecondary)
                    .lineHeight(this.theme.fs(21))
                    .margin({ top: 8 })
                    .width('100%')
                }, (p: string, idx: number): string => `${section.heading}-${idx}`)
              }
              .width('100%')
              .alignItems(HorizontalAlign.Start)
              .padding(14)
              .borderRadius(14)
              .backgroundColor(this.theme.colors.card)
            }
            .margin({ top: 10 })
          }, (section: TermsSection): string => section.heading)

          // ---- 结尾 ----
          ListItem() {
            Column() {
              ForEach(TERMS_OUTRO, (line: string, idx: number): void => {
                Text(line)
                  .fontSize(this.theme.fs(12))
                  .fontColor(this.theme.colors.textSecondary)
                  .lineHeight(this.theme.fs(19))
                  .margin({ top: idx === 0 ? 0 : 10 })
                  .width('100%')
              }, (line: string, idx: number): string => `o${idx}`)
            }
            .width('100%')
            .alignItems(HorizontalAlign.Start)
            .padding({ top: 14, bottom: 30 })
          }
        }
        .layoutWeight(1)
        .width('100%')
        .padding({ left: Metrics.pagePadding, right: Metrics.pagePadding, top: 4 })
        .scrollBar(BarState.Off)
        .edgeEffect(EdgeEffect.Spring)
      }
      .width('100%')
      .height('100%')
      .backgroundColor(this.theme.colors.background)
    }
    .hideTitleBar(true)
    .width('100%')
    .height('100%')
    .backgroundColor(this.theme.colors.background)
  }
}
