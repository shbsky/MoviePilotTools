import { AppTheme, Palette, Metrics, withAlpha } from '../../common/Theme';
import { Endpoint, EndpointMode, newUuid } from '../../model/Models';
import { MpServer } from '../../model/MpModels';
import { MpViewModel } from '../../vm/MpViewModel';
import { ToastHub } from '../../vm/StoreBase';
import { BasicField, FieldLabel, DialogHost, Dot } from '../components/Common';

/**
 * MoviePilot 服务器列表 / 编辑（对应安卓 ui/moviepilot/MpServerScreens.kt）。
 *
 * 编辑页从「整页 NavDestination」改成弹窗，样式对齐「设置 → 音乐服务」：
 * 居中卡片、高度按内容收缩、字段多时内容区自己滚。
 * 一个只有 4~5 个字段的表单占满整屏、还要按返回键才能退出，用起来比弹窗重得多。
 */

@Component
export struct MpServerListPage {
  @Consume('oiiTheme') theme: AppTheme;
  @Consume('navStack') navStack: NavPathStack;
  private vm: MpViewModel = MpViewModel.getInstance();
  @State state: MpStateRef = new MpStateRef();
  // 编辑弹窗：editOpen 控制开关，editId 为空 = 新增
  @State editOpen: boolean = false;
  @State editId: string = '';
  private listener: () => void = (): void => {
    this.state.syncFrom(this.vm.state);
  };

  aboutToAppear(): void {
    this.vm.subscribe(this.listener);
    this.state.syncFrom(this.vm.state);
  }

  aboutToDisappear(): void {
    this.vm.unsubscribe(this.listener);
  }

  private openEdit(id: string): void {
    this.editId = id;
    this.editOpen = true;
  }

  build() {
    NavDestination() {
      Stack() {
        Column() {
          // 头部
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
            Blank().width(10)
            Text('MoviePilot 服务器')
              .fontSize(this.theme.fs(17))
              .fontWeight(FontWeight.Medium)
              .fontColor(this.theme.colors.textPrimary)
            Blank()
            Text('＋ 添加')
              .fontSize(this.theme.fs(13))
              .fontColor(this.theme.colors.accent)
              .padding({ left: 6, right: 2, top: 6, bottom: 6 })
              .onClick((): void => {
                this.openEdit('');
              })
          }
          .width('100%')
          .padding({ left: Metrics.pagePadding, right: Metrics.pagePadding, top: 10, bottom: 10 })
          .alignItems(VerticalAlign.Center)

          if (this.state.servers.length === 0) {
            Column() {
              Text('🖧').fontSize(36)
              Blank().height(10)
              Text('还没有配置 MoviePilot')
                .fontSize(this.theme.fs(15))
                .fontColor(this.theme.colors.textSecondary)
              Blank().height(14)
              Text('＋ 添加 MoviePilot')
                .fontSize(this.theme.fs(13))
                .fontColor(0xFFFFFFFF)
                .backgroundColor(Palette.blue)
                .borderRadius(16)
                .padding({ left: 18, right: 18, top: 8, bottom: 8 })
                .onClick((): void => {
                  this.openEdit('');
                })
            }
            .width('100%')
            .layoutWeight(1)
            .justifyContent(FlexAlign.Center)
            .alignItems(HorizontalAlign.Center)
          } else {
            Scroll() {
              Column() {
                Blank().height(4)
                ForEach(this.state.servers, (server: MpServer): void => {
                  this.ServerRow(server)
                }, (server: MpServer): string => server.id)
                Blank().height(20)
              }
              .width('100%')
              .padding({ left: Metrics.pagePadding, right: Metrics.pagePadding })
              .alignItems(HorizontalAlign.Start)
            }
            .layoutWeight(1)
            .width('100%')
            .scrollBar(BarState.Off)
            .align(Alignment.Top)
          }
        }
        .width('100%')
        .height('100%')
        .backgroundColor(this.theme.colors.background)

        if (this.editOpen) {
          MpServerEditDialog({
            serverId: this.editId,
            onClose: (): void => {
              this.editOpen = false;
              this.state.syncFrom(this.vm.state);
            }
          })
        }
      }
      .width('100%')
      .height('100%')
    }
    .hideTitleBar(true)
    .onBackPressed((): boolean => {
      if (this.editOpen) {
        this.editOpen = false;
        return true;
      }
      return false;
    })
  }

  @Builder
  ServerRow(server: MpServer) {
    Row() {
      // 与下载器列表同款的图标块（那边是 qb/tr 缩写，这边统一 MP）
      Stack() {
        Circle().width(32).height(32).fill(withAlpha(Palette.blue, 0x26))
        Text('MP')
          .fontSize(12)
          .fontWeight(FontWeight.Bold)
          .fontColor(Palette.blue)
      }
      .width(32)
      .height(32)
      Blank().width(11)

      Column() {
        Row() {
          Text(server.displayName())
            .fontSize(this.theme.fs(15))
            .fontWeight(FontWeight.Medium)
            .fontColor(this.theme.colors.textPrimary)
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .layoutWeight(1)
          Blank().width(6)
          // 绿点 = 当前在用且没报错；红点 = 当前在用但拉数据失败；灰点 = 未启用
          Dot({ color: this.dotColorOf(server), sizeVp: 7 })
        }
        .width('100%')
        .alignItems(VerticalAlign.Center)

        // 地址：一行一个，最多两行（多出来的收成「共 N 个地址」）
        Blank().height(3)
        ForEach(this.addressLines(server), (line: string, idx: number): void => {
          Text(line)
            .fontSize(this.theme.fs(11))
            .fontColor(idx === 0 ? this.theme.colors.textSecondary : Palette.blue)
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .width('100%')
            .margin({ top: idx === 0 ? 0 : 2 })
        }, (line: string, idx: number): string => `${server.id}-addr${idx}-${line}`)

        if (server.apiToken.trim().length === 0) {
          Text('缺少 API Token')
            .fontSize(this.theme.fs(10))
            .fontColor(Palette.red)
            .margin({ top: 2 })
        }
      }
      .layoutWeight(1)
      .alignItems(HorizontalAlign.Start)

      SymbolGlyph($r('sys.symbol.chevron_right'))
        .fontSize(14)
        .fontColor([this.theme.colors.textSecondary])
    }
    .width('100%')
    .borderRadius(14)
    .backgroundColor(this.theme.colors.card)
    .padding(13)
    .margin({ bottom: 9 })
    .alignItems(VerticalAlign.Center)
    .onClick((): void => {
      this.openEdit(server.id);
    })
  }

  /** 状态点：当前在用 + 无错误 = 绿；当前在用但报错 = 红；没启用 = 灰 */
  private dotColorOf(server: MpServer): number {
    if (server.id !== this.state.activeId) {
      return withAlpha(this.theme.colors.textSecondary, 0x73);
    }
    return this.state.error.length === 0 ? Palette.green : Palette.red;
  }

  /** 地址按行拆：第一行主地址，第二行次地址或「共 N 个地址」提示 */
  private addressLines(server: MpServer): string[] {
    const eps: Endpoint[] = server.activeEndpoints();
    if (eps.length === 0) {
      return ['未设置地址'];
    }
    const lines: string[] = [eps[0].display()];
    if (eps.length === 2) {
      lines.push(eps[1].display());
    } else if (eps.length > 2) {
      lines.push(`共 ${eps.length} 个地址 · 自动切换`);
    }
    return lines;
  }

}

/** MpViewModel 状态的轻量读取视图 */
class MpStateRef {
  servers: MpServer[] = [];
  activeId: string = '';
  /** 全局错误：当前服务器拉数据失败时非空，用来点红点 */
  error: string = '';

  syncFrom(state: Object): void {
    const s: MpStateSrc = state as MpStateSrc;
    this.servers = s.servers;
    this.activeId = s.activeServerId !== null ? s.activeServerId : '';
    this.error = s.error;
  }
}

interface MpStateSrc {
  servers: MpServer[];
  activeServerId: string | null;
  error: string;
}

/**
 * 添加 / 编辑 MoviePilot（弹窗）。
 * 字段与校验逻辑沿用原页面：名称、API Token、可选账号密码、多端点、选路方式、测试连接、删除。
 */
@Component
export struct MpServerEditDialog {
  @Consume('oiiTheme') theme: AppTheme;
  private vm: MpViewModel = MpViewModel.getInstance();
  /** 空字符串 = 新增 */
  serverId: string = '';
  onClose: () => void = (): void => {
  };

  @State existingId: string = '';
  @State name: string = 'MoviePilot';
  @State apiToken: string = '';
  @State username: string = '';
  @State password: string = '';
  @State modeIdx: number = 0;
  @State pinned: number = 0;
  @State testing: boolean = false;
  @State testResult: string = '';
  @State confirmDelete: boolean = false;
  @State saveError: string = '';
  @State endpoints: Endpoint[] = [];

  /** 这台是不是当前正在用的那台 */
  private isActiveServer(): boolean {
    const active: string | null = this.vm.state.activeServerId as string | null;
    return active !== null && active === this.existingId;
  }

  aboutToAppear(): void {
    const id: string = this.serverId;
    this.existingId = id;
    let existing: MpServer | null = null;
    if (id.length > 0) {
      for (const s of this.vm.state.servers) {
        if (s.id === id) {
          existing = s;
          break;
        }
      }
    }
    this.name = existing !== null ? existing.name : 'MoviePilot';
    this.apiToken = existing !== null ? existing.apiToken : '';
    this.username = existing !== null ? existing.username : '';
    this.password = existing !== null ? existing.password : '';
    this.modeIdx = existing !== null && existing.endpointMode === EndpointMode.MANUAL ? 1 : 0;
    this.pinned = existing !== null ? existing.pinnedEndpointIndex : 0;
    if (existing !== null && existing.endpoints.length > 0) {
      this.endpoints = existing.endpoints.slice(0);
    } else {
      this.endpoints = [new Endpoint('', 3000, false, '', '内网')];
    }
  }

  private endpointMode(): EndpointMode {
    return this.modeIdx === 1 ? EndpointMode.MANUAL : EndpointMode.AUTO;
  }

  /** 保存时会丢掉空地址行，手动固定的序号必须按过滤后的有效地址算，否则会指错地址 */
  private pinTargets(): Endpoint[] {
    const out: Endpoint[] = [];
    for (const ep of this.endpoints) {
      const n: Endpoint = ep.normalized();
      if (n.host.trim().length > 0) {
        out.push(n);
      }
    }
    return out;
  }

  private buildServer(): MpServer {
    const s: MpServer = new MpServer();
    s.id = this.existingId.length > 0 ? this.existingId : newUuid();
    s.name = this.name.trim();
    // 允许整段粘贴 http(s)://host:port/path，保存时统一拆成 host/port/子路径
    const eps: Endpoint[] = [];
    for (const ep of this.endpoints) {
      const n: Endpoint = ep.normalized();
      if (n.host.trim().length > 0) {
        eps.push(n);
      }
    }
    s.endpoints = eps;
    s.apiToken = this.apiToken.trim();
    s.username = this.username.trim();
    s.password = this.password;
    s.endpointMode = this.endpointMode();
    s.pinnedEndpointIndex = Math.max(0, Math.min(this.pinned, eps.length - 1));
    return s;
  }

  private save(): void {
    const candidate: MpServer = this.buildServer();
    if (candidate.activeEndpoints().length === 0) {
      this.saveError = '最少填一条访问地址（域名或 IP）。端口可以留空，https 走 443、http 走 80。';
      return;
    }
    if (candidate.apiToken.trim().length === 0) {
      this.saveError = '请填写 API Token，否则无法调用 MoviePilot 接口。';
      return;
    }
    this.vm.upsertServer(candidate);
    this.onClose();
  }

  private testConnection(): void {
    this.testing = true;
    this.testResult = '';
    this.vm.testServer(this.buildServer()).then((msg: string): void => {
      this.testing = false;
      this.testResult = msg;
    }).catch((err: Error): void => {
      this.testing = false;
      this.testResult = err.message.length > 0 ? err.message : '连接失败';
    });
  }

  private updateEndpoint(index: number, apply: (ep: Endpoint) => Endpoint): void {
    const next: Endpoint[] = this.endpoints.slice(0);
    next[index] = apply(next[index]);
    this.endpoints = next;
  }

  build() {
    Stack() {
      DialogHost({
        // 删除确认 / 校验提示叠上来时先收起主表单，不做「被子弹窗当背景」
        visible: this.saveError.length === 0 && !this.confirmDelete,
        title: this.existingId.length > 0 ? '编辑 MoviePilot' : '添加 MoviePilot',
        confirmText: '保存',
        contentMaxHeight: 400,
        onCancel: (): void => {
          this.onClose();
        },
        onConfirm: (): void => {
          this.save();
        }
      }) {
        this.Content()
      }

      // 删除确认（再叠一层，避免误触）
      DialogHost({
        visible: this.confirmDelete,
        title: '删除这台 MoviePilot？',
        confirmText: '删除',
        destructive: true,
        onCancel: (): void => {
          this.confirmDelete = false;
        },
        onConfirm: (): void => {
          this.confirmDelete = false;
          this.vm.deleteServer(this.existingId);
          this.onClose();
        }
      }) {
        Text('只删除 App 里的配置，不影响 MP 本身。')
          .fontSize(this.theme.fs(14))
          .fontColor(this.theme.colors.textPrimary)
      }

      // 保存校验错误
      DialogHost({
        visible: this.saveError.length > 0,
        title: '还不能保存',
        confirmText: '知道了',
        showCancel: false,
        onCancel: (): void => {
          this.saveError = '';
        },
        onConfirm: (): void => {
          this.saveError = '';
        }
      }) {
        Text(this.saveError)
          .fontSize(this.theme.fs(14))
          .fontColor(this.theme.colors.textPrimary)
      }
    }
    .width('100%')
    .height('100%')
  }

  @Builder
  Content() {
    Column() {
      FieldLabel({ text: '名称' })
      Blank().height(6)
      BasicField({
        value: this.name,
        placeholder: '例如 家里的 MoviePilot',
        onValueChanged: (v: string): void => {
          this.name = v;
        }
      })

      this.Label('API Token')
      BasicField({
        value: this.apiToken,
        placeholder: 'MP → 设置 → 系统 → API Token',
        secret: true,
        onValueChanged: (v: string): void => {
          this.apiToken = v;
        }
      })
      Blank().height(4)
      Text('必填。它让 App 能调用 MP 的发现、搜索、投递、订阅接口。')
        .fontSize(this.theme.fs(10))
        .fontColor(this.theme.colors.textSecondary)
        .lineHeight(this.theme.fs(15))

      this.Label('MP 用户名 / 密码（可选）')
      BasicField({
        value: this.username,
        placeholder: '登录名',
        onValueChanged: (v: string): void => {
          this.username = v;
        }
      })
      Blank().height(8)
      BasicField({
        value: this.password,
        placeholder: '密码',
        secret: true,
        onValueChanged: (v: string): void => {
          this.password = v;
        }
      })
      Blank().height(4)
      Text('填了才能用「边搜边显示」的渐进式资源搜索，否则要等所有站点搜完才出结果。')
        .fontSize(this.theme.fs(10))
        .fontColor(this.theme.colors.textSecondary)
        .lineHeight(this.theme.fs(15))

      // ---- 访问地址 ----
      Blank().height(16)
      Row() {
        Text('访问地址')
          .fontSize(this.theme.fs(13))
          .fontWeight(FontWeight.Medium)
          .fontColor(this.theme.colors.textPrimary)
        Blank().width(8)
        Text('可填多条')
          .fontSize(this.theme.fs(10))
          .fontColor(this.theme.colors.textSecondary)
        Blank()
        Text('＋ 添加')
          .fontSize(this.theme.fs(12))
          .fontColor(this.theme.colors.accent)
          .padding({ left: 6, right: 2, top: 4, bottom: 4 })
          .onClick((): void => {
            const next: Endpoint[] = this.endpoints.slice(0);
            next.push(new Endpoint('', 3000));
            this.endpoints = next;
          })
      }
      .width('100%')
      .alignItems(VerticalAlign.Center)
      Blank().height(8)

      ForEach(this.endpoints, (ep: Endpoint, index: number): void => {
        this.EndpointCard(ep, index)
        // key 必须稳定（只用 index）：hostKey 含 host，输入时 key 变化会导致
        // 卡片销毁重建、焦点跳到名称框（地址内容串进名称的 BUG）
      }, (ep: Endpoint, index: number): string => `ep${index}-${ep.https ? 1 : 0}`)

      this.Label('选路方式')
      Row() {
        Text('自动选择')
          .fontSize(this.theme.fs(12))
          .fontColor(this.modeIdx === 0 ? 0xFFFFFFFF : this.theme.colors.textPrimary)
          .textAlign(TextAlign.Center)
          .layoutWeight(1)
          .borderRadius(10)
          .backgroundColor(this.modeIdx === 0 ? this.theme.colors.accent
            : withAlpha(this.theme.colors.textPrimary, 0x0F))
          .padding({ top: 10, bottom: 10 })
          .margin({ right: 8 })
          .onClick((): void => {
            this.modeIdx = 0;
          })
        Text('手动固定')
          .fontSize(this.theme.fs(12))
          .fontColor(this.modeIdx === 1 ? 0xFFFFFFFF : this.theme.colors.textPrimary)
          .textAlign(TextAlign.Center)
          .layoutWeight(1)
          .borderRadius(10)
          .backgroundColor(this.modeIdx === 1 ? this.theme.colors.accent
            : withAlpha(this.theme.colors.textPrimary, 0x0F))
          .padding({ top: 10, bottom: 10 })
          .onClick((): void => {
            this.modeIdx = 1;
          })
      }
      .alignItems(VerticalAlign.Center)

      if (this.modeIdx === 1) {
        Blank().height(8)
        Flex({ wrap: FlexWrap.Wrap }) {
          ForEach(this.pinTargets(), (ep: Endpoint, index: number): void => {
            Text(`地址 ${index + 1}`)
              .fontSize(this.theme.fs(11))
              .fontColor(this.pinned === index ? 0xFFFFFFFF : this.theme.colors.textSecondary)
              .borderRadius(9)
              .backgroundColor(this.pinned === index ? this.theme.colors.accent
                : withAlpha(this.theme.colors.textPrimary, 0x0F))
              .padding({ left: 12, right: 12, top: 7, bottom: 7 })
              .margin({ right: 6, bottom: 6 })
              .onClick((): void => {
                this.pinned = index;
              })
          }, (ep: Endpoint, index: number): string => `pin${index}-${this.pinned === index ? 1 : 0}`)
        }
        .width('100%')
      }

      Blank().height(14)
      Row() {
        Text(this.testing ? '测试中…' : '测试连接')
          .fontSize(this.theme.fs(13))
          .fontColor(Palette.blue)
          .textAlign(TextAlign.Center)
          .layoutWeight(1)
          .borderRadius(11)
          .backgroundColor(withAlpha(Palette.blue, 0x1F))
          .padding({ top: 11, bottom: 11 })
          .onClick((): void => {
            if (!this.testing) {
              this.testConnection();
            }
          })
        if (this.existingId.length > 0) {
          Blank().width(10)
          Text('删除服务器')
            .fontSize(this.theme.fs(13))
            .fontColor(Palette.red)
            .textAlign(TextAlign.Center)
            .layoutWeight(1)
            .borderRadius(11)
            .backgroundColor(withAlpha(Palette.red, 0x1F))
            .padding({ top: 11, bottom: 11 })
            .onClick((): void => {
              this.confirmDelete = true;
            })
        }
      }
      .alignItems(VerticalAlign.Center)

      // 列表行不再放「使用」按钮（统一成下载器那种卡片 + 状态点），切换入口放这里
      if (this.existingId.length > 0 && !this.isActiveServer()) {
        Blank().height(8)
        Text('设为当前使用')
          .fontSize(this.theme.fs(13))
          .fontColor(this.theme.colors.textPrimary)
          .textAlign(TextAlign.Center)
          .width('100%')
          .borderRadius(11)
          .backgroundColor(withAlpha(this.theme.colors.textPrimary, 0x0F))
          .padding({ top: 11, bottom: 11 })
          .onClick((): void => {
            this.vm.selectServer(this.existingId);
            ToastHub.getInstance().show('已切换 MoviePilot 服务器');
            this.onClose();
          })
      }

      if (this.testResult.length > 0) {
        Blank().height(8)
        Text(this.testResult)
          .fontSize(this.theme.fs(11))
          .fontColor(this.testResult.startsWith('连接成功') ? Palette.green : Palette.red)
          .lineHeight(this.theme.fs(16))
          .width('100%')
      }
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
  }

  @Builder
  Label(text: string) {
    Text(text)
      .fontSize(this.theme.fs(12))
      .fontColor(this.theme.colors.textSecondary)
      .width('100%')
      .margin({ top: 14, bottom: 6 })
  }

  @Builder
  EndpointCard(ep: Endpoint, index: number) {
    Column() {
      Row() {
        Text(`地址 ${index + 1}`)
          .fontSize(this.theme.fs(12))
          .fontColor(this.theme.colors.textSecondary)
        Blank()
        if (this.endpoints.length > 1) {
          Text('🗑')
            .fontSize(15)
            .padding({ left: 6, right: 2, top: 2, bottom: 2 })
            .onClick((): void => {
              const next: Endpoint[] = this.endpoints.slice(0);
              next.splice(index, 1);
              this.endpoints = next;
            })
        }
      }
      .width('100%')
      .alignItems(VerticalAlign.Center)

      Blank().height(8)
      BasicField({
        value: ep.host,
        placeholder: '192.168.1.10 或 mp.example.com',
        onValueChanged: (v: string): void => {
          // 不在输入过程中 trim：保存时 normalized() 统一清理，避免回写差异重置输入框
          this.updateEndpoint(index, (e: Endpoint): Endpoint =>
            new Endpoint(v, e.port, e.https, e.basePath, e.label, e.enabled));
        }
      })
      Blank().height(8)
      Row() {
        Column() {
          BasicField({
            value: ep.port >= 1 && ep.port <= 65535 ? String(ep.port) : '',
            placeholder: '端口（空=默认）',
            onValueChanged: (v: string): void => {
              const digits: string = v.replace(/[^0-9]/g, '').substring(0, 5);
              const port: number = digits.length > 0 ? parseInt(digits, 10) : 0;
              this.updateEndpoint(index, (e: Endpoint): Endpoint =>
                new Endpoint(e.host, isNaN(port) ? 0 : port, e.https, e.basePath, e.label, e.enabled));
            }
          })
        }
        .layoutWeight(1)
        Blank().width(8)
        Column() {
          BasicField({
            value: ep.basePath,
            placeholder: '子路径 /mp（可空）',
            onValueChanged: (v: string): void => {
              this.updateEndpoint(index, (e: Endpoint): Endpoint =>
                new Endpoint(e.host, e.port, e.https, v, e.label, e.enabled));
            }
          })
        }
        .layoutWeight(1.4)
      }
      .alignItems(VerticalAlign.Center)

      Blank().height(8)
      Row() {
        Column() {
          BasicField({
            value: ep.label,
            placeholder: '备注：家里 / 外网',
            onValueChanged: (v: string): void => {
              this.updateEndpoint(index, (e: Endpoint): Endpoint =>
                new Endpoint(e.host, e.port, e.https, e.basePath, v, e.enabled));
            }
          })
        }
        .layoutWeight(1)
        Blank().width(8)
        Text(ep.https ? 'https' : 'http')
          .fontSize(this.theme.fs(11))
          .fontColor(ep.https ? Palette.green : this.theme.colors.textSecondary)
          .borderRadius(9)
          .backgroundColor(ep.https ? withAlpha(Palette.green, 0x26)
            : withAlpha(this.theme.colors.textPrimary, 0x0F))
          .padding({ left: 10, right: 10, top: 8, bottom: 8 })
          .onClick((): void => {
            this.updateEndpoint(index, (e: Endpoint): Endpoint =>
              new Endpoint(e.host, e.port, !e.https, e.basePath, e.label, e.enabled));
          })
      }
      .alignItems(VerticalAlign.Center)

      if (ep.host.length > 0) {
        Blank().height(6)
        Text(this.endpointPreviewText(ep))
          .fontSize(this.theme.fs(10))
          .fontColor(this.endpointPreviewOk(ep) ? this.theme.colors.textSecondary : Palette.red)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .width('100%')
      }
    }
    .width('100%')
    .borderRadius(12)
    .backgroundColor(withAlpha(this.theme.colors.textPrimary, 0x08))
    .padding(12)
    .margin({ bottom: 10 })
    .alignItems(HorizontalAlign.Start)
  }

  private endpointPreviewOk(ep: Endpoint): boolean {
    return ep.normalized().isValid();
  }

  private endpointPreviewText(ep: Endpoint): string {
    const preview: Endpoint = ep.normalized();
    if (preview.isValid()) {
      return `实际请求：${preview.display()}`;
    }
    return '地址格式不对，检查是否填了多余字符';
  }
}
