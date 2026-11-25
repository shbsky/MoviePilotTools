import { AppTheme, Palette, Metrics, withAlpha } from '../../common/Theme';
import { ServerType, Endpoint, EndpointMode, ServerConfig, serverTypeLabel,
  serverTypeFromIndex, newUuid } from '../../model/Models';
import { AppViewModel } from '../../vm/AppViewModel';
import { ToastHub } from '../../vm/StoreBase';
import { BasicField, FieldLabel, DialogHost, ServerBadge, Dot } from '../components/Common';

/**
 * 下载器服务器列表 / 编辑（对应安卓 ui/settings/ServerScreens.kt）。
 *
 * 改版（用户要求与 MoviePilot 服务器页统一）：
 *  - **列表回到整页**：打开「下载器设置」不再弹窗，和 MP 服务器页一样，只显示已配置的服务器；
 *  - **只有「添加 / 编辑」才弹窗**：表单字段多，弹窗里可滚动，比再压一层整页更好用。
 * 上一版把列表也做成弹窗，结果「列表弹窗里再开编辑弹窗」，一层套一层很重。
 */

@Component
export struct ServerListPage {
  @Consume('oiiTheme') theme: AppTheme;
  @Consume('navStack') navStack: NavPathStack;
  private vm: AppViewModel = AppViewModel.getInstance();
  @State state: AppStateLike = new AppStateLike();
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
            Text('下载器设置')
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

          if (this.state.serverCount() === 0) {
            Column() {
              Text('🖧').fontSize(36)
              Blank().height(10)
              Text('还没有下载器')
                .fontSize(this.theme.fs(15))
                .fontColor(this.theme.colors.textSecondary)
              Blank().height(14)
              Text('＋ 添加下载器')
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
                ForEach(this.state.servers, (server: ServerConfig): void => {
                  this.ServerRow(server)
                }, (server: ServerConfig): string => server.id)
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

        // 添加 / 编辑：唯一的弹窗
        if (this.editOpen) {
          ServerEditDialog({
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
    .width('100%')
    .height('100%')
    .onBackPressed((): boolean => {
      if (this.editOpen) {
        this.editOpen = false;
        return true;
      }
      return false;
    })
  }

  @Builder
  ServerRow(server: ServerConfig) {
    Row() {
      ServerBadge({ type: server.type, sizeVp: 32 })
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
          Dot({ color: this.dotColorOf(server.id), sizeVp: 7 })
        }
        .width('100%')
        .alignItems(VerticalAlign.Center)
        Blank().height(3)
        Text(this.firstEndpointDisplay(server))
          .fontSize(this.theme.fs(11))
          .fontColor(this.theme.colors.textSecondary)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .width('100%')
        if (server.activeEndpoints().length > 1) {
          Blank().height(2)
          Text(`共 ${server.activeEndpoints().length} 个地址 · 自动切换`)
            .fontSize(this.theme.fs(10))
            .fontColor(Palette.blue)
            .width('100%')
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

  private dotColorOf(serverId: string): number {
    const snap = this.state.snapshotOf(serverId);
    if (snap === null) {
      return Palette.orange;
    }
    return snap.online ? Palette.green : Palette.red;
  }

  private firstEndpointDisplay(server: ServerConfig): string {
    const eps: Endpoint[] = server.activeEndpoints();
    if (eps.length === 0) {
      return '未配置地址';
    }
    return eps[0].display();
  }
}

/** AppViewModel 状态的轻量读取视图（避免整包 @State 深比较） */
class AppStateLike {
  servers: ServerConfig[] = [];
  snapshots: Map<string, ServerSnapshotLike> = new Map<string, ServerSnapshotLike>();

  syncFrom(state: Object): void {
    const s = state as AppStateSrc;
    this.servers = s.servers;
    this.snapshots = s.snapshots;
  }

  serverCount(): number {
    return this.servers.length;
  }

  snapshotOf(id: string): ServerSnapshotLike | null {
    const v = this.snapshots.get(id);
    return v === undefined ? null : v;
  }
}

interface AppStateSrc {
  servers: ServerConfig[];
  snapshots: Map<string, ServerSnapshotLike>;
}

interface ServerSnapshotLike {
  online: boolean;
}

/**
 * 添加 / 编辑下载器（弹窗）。
 * 字段与校验逻辑沿用原页面：名称、类型、多端点行、选路方式、认证双通道、rpcPath、测试连接、删除。
 */
@Component
export struct ServerEditDialog {
  @Consume('oiiTheme') theme: AppTheme;
  private vm: AppViewModel = AppViewModel.getInstance();
  /** 空字符串 = 新增 */
  serverId: string = '';
  onClose: () => void = (): void => {
  };

  @State existingId: string = '';
  @State name: string = '';
  @State typeIdx: number = 0;
  @State username: string = '';
  @State password: string = '';
  @State apiKey: string = '';
  @State useApiKey: boolean = false;
  @State rpcPath: string = '/transmission/rpc';
  @State modeIdx: number = 0;
  @State pinned: number = 0;
  @State endpoints: Endpoint[] = [];
  @State testResult: string = '';
  @State testing: boolean = false;
  @State confirmDelete: boolean = false;
  @State saveError: string = '';

  aboutToAppear(): void {
    this.initFrom(this.serverId);
  }

  private initFrom(existingId: string): void {
    this.existingId = existingId;
    const existing: ServerConfig | null = existingId.length > 0
      ? this.vm.state.serverById(existingId) : null;
    this.name = existing !== null ? existing.name : '';
    this.typeIdx = existing !== null ? existing.type : 0;
    this.username = existing !== null ? existing.username : '';
    this.password = existing !== null ? existing.password : '';
    this.apiKey = existing !== null ? existing.apiKey : '';
    this.useApiKey = existing !== null ? existing.useApiKey : false;
    this.rpcPath = existing !== null && existing.rpcPath.length > 0 ? existing.rpcPath : '/transmission/rpc';
    this.modeIdx = existing !== null ? existing.endpointMode : 0;
    this.pinned = existing !== null ? existing.pinnedEndpointIndex : 0;
    if (existing !== null && existing.endpoints.length > 0) {
      this.endpoints = existing.endpoints.slice(0);
    } else {
      const port: number = this.typeIdx === 1 ? 9091 : 8080;
      this.endpoints = [new Endpoint('', port)];
    }
  }

  private serverType(): ServerType {
    return serverTypeFromIndex(this.typeIdx);
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

  private buildConfig(): ServerConfig {
    const c: ServerConfig = new ServerConfig();
    c.id = this.existingId.length > 0 ? this.existingId : newUuid();
    c.name = this.name.trim();
    c.type = this.serverType();
    const eps: Endpoint[] = [];
    for (const ep of this.endpoints) {
      const n: Endpoint = ep.normalized();
      if (n.host.trim().length > 0) {
        eps.push(n);
      }
    }
    c.endpoints = eps;
    c.username = this.username;
    c.password = this.password;
    c.apiKey = this.apiKey;
    c.useApiKey = this.useApiKey;
    c.rpcPath = this.rpcPath.trim().length > 0 ? this.rpcPath : '/transmission/rpc';
    c.endpointMode = this.endpointMode();
    c.pinnedEndpointIndex = Math.max(0, Math.min(this.pinned, eps.length - 1));
    return c;
  }

  private save(): void {
    const candidate: ServerConfig = this.buildConfig();
    if (candidate.activeEndpoints().length === 0) {
      this.saveError = '至少填一条访问地址（域名或 IP）。端口可以留空，https 走 443、http 走 80。';
      return;
    }
    this.vm.upsertServer(candidate);
    ToastHub.getInstance().show('已保存');
    this.onClose();
  }

  private testConnection(): void {
    this.testing = true;
    this.testResult = '';
    const config: ServerConfig = this.buildConfig();
    this.vm.testConnection(config).then((msg: string): void => {
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
        visible: this.saveError.length === 0 && !this.confirmDelete,
        title: this.existingId.length > 0 ? '编辑下载器' : '添加下载器',
        confirmText: '保存',
        contentMaxHeight: 440,
        onCancel: (): void => {
          this.onClose();
        },
        onConfirm: (): void => {
          this.save();
        }
      }) {
        this.Content()
      }

      // 删除确认（再叠一层，避免误触；主弹窗同时收起，不当背景）
      DialogHost({
        visible: this.confirmDelete,
        title: '删除下载器',
        confirmText: '删除',
        destructive: true,
        onCancel: (): void => {
          this.confirmDelete = false;
        },
        onConfirm: (): void => {
          this.confirmDelete = false;
          this.vm.deleteServer(this.existingId);
          ToastHub.getInstance().show('已删除');
          this.onClose();
        }
      }) {
        Text(`确定删除「${this.deleteTargetName()}」？该操作不可恢复。`)
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
        placeholder: '例如 家里的 NAS',
        onValueChanged: (v: string): void => {
          this.name = v;
        }
      })

      Blank().height(14)
      FieldLabel({ text: '类型' })
      Blank().height(6)
      Row() {
        ForEach([0, 1], (idx: number): void => {
          Text(serverTypeLabel(serverTypeFromIndex(idx)))
            .fontSize(this.theme.fs(13))
            .fontColor(this.typeIdx === idx ? 0xFFFFFFFF : this.theme.colors.textPrimary)
            .fontWeight(this.typeIdx === idx ? FontWeight.Medium : FontWeight.Normal)
            .textAlign(TextAlign.Center)
            .layoutWeight(1)
            .borderRadius(10)
            .backgroundColor(this.typeIdx === idx ? this.theme.colors.accent
              : withAlpha(this.theme.colors.textPrimary, 0x0F))
            .padding({ top: 10, bottom: 10 })
            .margin({ right: idx === 0 ? 8 : 0 })
            .onClick((): void => {
              this.typeIdx = idx;
              // 默认端口联动
              const wantPort: number = idx === 1 ? 9091 : 8080;
              const next: Endpoint[] = this.endpoints.slice(0);
              for (let i = 0; i < next.length; i++) {
                if (next[i].port === 8080 || next[i].port === 9091) {
                  next[i] = new Endpoint(next[i].host, wantPort, next[i].https,
                    next[i].basePath, next[i].label, next[i].enabled);
                }
              }
              this.endpoints = next;
            })
        }, (idx: number): string => `t${idx}-${this.typeIdx === idx ? 1 : 0}`)
      }
      .alignItems(VerticalAlign.Center)

      Blank().height(16)
      Row() {
        Text('访问地址')
          .fontSize(this.theme.fs(13))
          .fontWeight(FontWeight.Medium)
          .fontColor(this.theme.colors.textPrimary)
        Blank().width(8)
        Text('可填多个，自动挑能通的')
          .fontSize(this.theme.fs(10))
          .fontColor(this.theme.colors.textSecondary)
        Blank()
        Text('＋ 添加')
          .fontSize(this.theme.fs(12))
          .fontColor(this.theme.colors.accent)
          .onClick((): void => {
            const port: number = this.typeIdx === 1 ? 9091 : 8080;
            const next: Endpoint[] = this.endpoints.slice(0);
            next.push(new Endpoint('', port));
            this.endpoints = next;
          })
      }
      .width('100%')
      .alignItems(VerticalAlign.Center)
      Blank().height(8)

      ForEach(this.endpoints, (ep: Endpoint, index: number): void => {
        this.EndpointCard(ep, index)
        // key 必须稳定（只用 index）：含 host 会让输入时卡片重建、焦点跳到名称框
      }, (ep: Endpoint, index: number): string => `ep${index}`)

      Blank().height(6)
      FieldLabel({ text: '选路方式' })
      Blank().height(6)
      Row() {
        Text('自动切换')
          .fontSize(this.theme.fs(12))
          .fontColor(this.modeIdx === 0 ? 0xFFFFFFFF : this.theme.colors.textPrimary)
          .textAlign(TextAlign.Center)
          .layoutWeight(1)
          .borderRadius(10)
          .backgroundColor(this.modeIdx === 0 ? this.theme.colors.accent
            : withAlpha(this.theme.colors.textPrimary, 0x0F))
          .padding({ top: 9, bottom: 9 })
          .margin({ right: 8 })
          .onClick((): void => {
            this.modeIdx = 0;
          })
        Text('固定地址')
          .fontSize(this.theme.fs(12))
          .fontColor(this.modeIdx === 1 ? 0xFFFFFFFF : this.theme.colors.textPrimary)
          .textAlign(TextAlign.Center)
          .layoutWeight(1)
          .borderRadius(10)
          .backgroundColor(this.modeIdx === 1 ? this.theme.colors.accent
            : withAlpha(this.theme.colors.textPrimary, 0x0F))
          .padding({ top: 9, bottom: 9 })
          .onClick((): void => {
            this.modeIdx = 1;
          })
      }
      .alignItems(VerticalAlign.Center)

      if (this.modeIdx === 1) {
        Blank().height(8)
        ForEach(this.pinTargets(), (ep: Endpoint, index: number): void => {
          Row() {
            Circle()
              .width(15)
              .height(15)
              .fill(this.pinned === index ? Palette.blue : this.theme.colors.separator)
            Blank().width(8)
            Text(ep.display())
              .fontSize(this.theme.fs(12))
              .fontColor(this.theme.colors.textSecondary)
              .maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
              .layoutWeight(1)
          }
          .width('100%')
          .padding({ top: 7, bottom: 7 })
          .alignItems(VerticalAlign.Center)
          .onClick((): void => {
            this.pinned = index;
          })
        }, (ep: Endpoint, index: number): string => `pin${index}-${this.pinned === index ? 1 : 0}`)
      }

      Blank().height(16)
      FieldLabel({ text: '认证' })
      Blank().height(6)
      if (this.typeIdx === 0) {
        Row() {
          Text('使用 API Key（qBittorrent 5.2+）')
            .fontSize(this.theme.fs(12))
            .fontColor(this.theme.colors.textPrimary)
            .layoutWeight(1)
          Text(this.useApiKey ? '已启用' : '未启用')
            .fontSize(this.theme.fs(11))
            .fontColor(this.useApiKey ? Palette.blue : this.theme.colors.textSecondary)
            .borderRadius(8)
            .backgroundColor(this.useApiKey ? withAlpha(Palette.blue, 0x26)
              : withAlpha(this.theme.colors.textPrimary, 0x0F))
            .padding({ left: 10, right: 10, top: 6, bottom: 6 })
            .onClick((): void => {
              this.useApiKey = !this.useApiKey;
            })
        }
        .width('100%')
        .alignItems(VerticalAlign.Center)
        Blank().height(8)
      }

      if (this.useApiKey && this.typeIdx === 0) {
        BasicField({
          value: this.apiKey,
          placeholder: '粘贴 API Key',
          secret: true,
          onValueChanged: (v: string): void => {
            this.apiKey = v;
          }
        })
      } else {
        BasicField({
          value: this.username,
          placeholder: '用户名',
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
      }

      if (this.typeIdx === 1) {
        Blank().height(14)
        FieldLabel({ text: 'RPC 路径' })
        Blank().height(6)
        BasicField({
          value: this.rpcPath,
          placeholder: '/transmission/rpc',
          onValueChanged: (v: string): void => {
            this.rpcPath = v;
          }
        })
      }

      Blank().height(16)
      Text(this.testing ? '正在测试…' : '测试连接')
        .fontSize(this.theme.fs(13))
        .fontWeight(FontWeight.Medium)
        .fontColor(Palette.blue)
        .textAlign(TextAlign.Center)
        .width('100%')
        .borderRadius(10)
        .backgroundColor(withAlpha(Palette.blue, 0x1F))
        .padding({ top: 11, bottom: 11 })
        .onClick((): void => {
          if (!this.testing) {
            this.testConnection();
          }
        })
      if (this.testResult.length > 0) {
        Blank().height(8)
        Text(this.testResult)
          .fontSize(this.theme.fs(11))
          .fontColor(this.testResult.startsWith('连接成功') ? Palette.green : Palette.red)
          .width('100%')
      }

      if (this.existingId.length > 0) {
        Blank().height(12)
        Text('删除下载器')
          .fontSize(this.theme.fs(13))
          .fontColor(Palette.red)
          .textAlign(TextAlign.Center)
          .width('100%')
          .borderRadius(10)
          .backgroundColor(withAlpha(Palette.red, 0x1A))
          .padding({ top: 11, bottom: 11 })
          .onClick((): void => {
            this.confirmDelete = true;
          })
      }
      Blank().height(4)
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
  }

  private deleteTargetName(): string {
    const s: ServerConfig | null = this.vm.state.serverById(this.existingId);
    return s !== null ? s.displayName() : '下载器';
  }

  @Builder
  EndpointCard(ep: Endpoint, index: number): void {
    Column() {
      Row() {
        Text(`地址 ${index + 1}`)
          .fontSize(this.theme.fs(11))
          .fontColor(this.theme.colors.textSecondary)
        Blank()
        if (this.endpoints.length > 1) {
          Text('🗑')
            .fontSize(14)
            .onClick((): void => {
              const next: Endpoint[] = this.endpoints.slice(0);
              next.splice(index, 1);
              this.endpoints = next;
            })
        }
      }
      .width('100%')
      .alignItems(VerticalAlign.Center)

      Blank().height(6)
      BasicField({
        value: ep.host,
        placeholder: '192.168.1.10 或 qb.example.com',
        onValueChanged: (v: string): void => {
          // 不在输入过程中 trim：保存时 normalized() 统一清理，避免回写差异重置输入框
          this.updateEndpoint(index, (e: Endpoint): Endpoint =>
            new Endpoint(v, e.port, e.https, e.basePath, e.label, e.enabled));
        }
      })
      Blank().height(6)
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
            placeholder: '子路径 /qb（可空）',
            onValueChanged: (v: string): void => {
              this.updateEndpoint(index, (e: Endpoint): Endpoint =>
                new Endpoint(e.host, e.port, e.https, v, e.label, e.enabled));
            }
          })
        }
        .layoutWeight(1.4)
      }
      .alignItems(VerticalAlign.Center)

      Blank().height(6)
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
        Text('HTTPS')
          .fontSize(this.theme.fs(11))
          .fontColor(ep.https ? Palette.blue : this.theme.colors.textSecondary)
          .borderRadius(8)
          .backgroundColor(ep.https ? withAlpha(Palette.blue, 0x29)
            : withAlpha(this.theme.colors.textPrimary, 0x0F))
          .padding({ left: 9, right: 9, top: 7, bottom: 7 })
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
    .padding(10)
    .margin({ bottom: 8 })
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
