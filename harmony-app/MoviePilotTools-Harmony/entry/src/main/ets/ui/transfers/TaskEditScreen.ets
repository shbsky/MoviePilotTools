import { AppTheme, Palette, withAlpha } from '../../common/Theme';
import { TorrentTask } from '../../model/Models';
import { AppViewModel } from '../../vm/AppViewModel';
import { BasicField, DialogHost, FieldLabel, SelectChip } from '../components/Common';

/**
 * 单任务编辑（对应安卓 ui/transfers/TaskActionsScreen.kt 里的 TaskEditScreen）。
 *
 * 原来是一个 NavDestination 全屏页，现在改成居中弹窗。
 * 理由：这些操作（重命名 / 分类 / 分享率…）大多只有 1~3 个字段，
 * 全屏页会把 90% 的屏幕留白，还得让用户「返回」一次；弹窗高度按内容收缩，
 * 字段多时内容区自己滚，跟「设置 → 音乐服务」用的是同一个 DialogHost。
 */

export enum TaskEditMode {
  RENAME,
  LOCATION,
  CATEGORY,
  TAGS,
  LIMITS,
  RATIO
}

export function taskEditTitle(mode: TaskEditMode): string {
  switch (mode) {
    case TaskEditMode.RENAME:
      return '重命名';
    case TaskEditMode.LOCATION:
      return '更改保存位置';
    case TaskEditMode.CATEGORY:
      return '分类';
    case TaskEditMode.TAGS:
      return '标签';
    case TaskEditMode.LIMITS:
      return '限速设置';
    case TaskEditMode.RATIO:
      return '分享率设置';
    default:
      return '编辑';
  }
}

@Component
export struct TaskEditDialog {
  @Consume('oiiTheme') theme: AppTheme;
  /** 由调用方在弹窗打开时传入；组件在 if 分支内创建，每次打开都是新实例 */
  task: TorrentTask = new TorrentTask();
  mode: TaskEditMode = TaskEditMode.RENAME;
  onClose: () => void = (): void => {
  };
  /** 提交成功后先回调父级（父级据此收起上一层操作面板），再 onClose 关自己 */
  onSaved: () => void = (): void => {
  };
  private vm: AppViewModel = AppViewModel.getInstance();

  @State submitting: boolean = false;
  @State error: string = '';

  @State nameInput: string = '';
  @State pathInput: string = '';
  @State categoryInput: string = '';
  @State newCategory: string = '';
  @State newCategoryPath: string = '';
  @State categories: string[] = [];
  @State tags: string[] = [];
  @State selectedTags: string[] = [];
  @State newTag: string = '';
  @State downloadKb: string = '';
  @State uploadKb: string = '';
  @State ratioMode: number = -2;
  @State ratioLimit: string = '';

  aboutToAppear(): void {
    const t: TorrentTask = this.task;
    this.nameInput = t.name;
    this.pathInput = t.savePath;
    this.categoryInput = t.category;
    this.selectedTags = t.tags.slice(0);
    // 限速：内部统一 bytes/s，界面上按 KB/s 编辑；0 显示为空（= 不限）
    this.downloadKb = t.downloadLimit > 0 ? `${Math.round(t.downloadLimit / 1024)}` : '';
    this.uploadKb = t.uploadLimit > 0 ? `${Math.round(t.uploadLimit / 1024)}` : '';
    this.ratioMode = t.ratioMode === -1 ? -1 : (t.ratioMode > 0 ? t.ratioMode : -2);
    this.ratioLimit = t.ratioLimit > 0 ? `${t.ratioLimit}` : '';
    if (this.mode === TaskEditMode.CATEGORY) {
      this.vm.listCategories(t.serverId).then((list: string[]): void => {
        this.categories = list;
      }).catch((): void => {
        this.categories = [];
      });
    }
    if (this.mode === TaskEditMode.TAGS) {
      this.vm.listTags(t.serverId).then((list: string[]): void => {
        this.tags = list;
      }).catch((): void => {
        this.tags = [];
      });
    }
  }

  private parseKb(text: string): number {
    const v: number = parseInt(text.trim(), 10);
    if (isNaN(v) || v <= 0) {
      return 0;
    }
    return v * 1024;
  }

  private canSubmit(): boolean {
    if (this.submitting) {
      return false;
    }
    if (this.mode === TaskEditMode.RATIO && this.ratioMode > 0) {
      const limit: number = parseFloat(this.ratioLimit);
      return !isNaN(limit) && limit > 0;
    }
    return true;
  }

  private submit(): void {
    if (!this.canSubmit()) {
      this.error = '自定义分享率需要填一个大于 0 的数字';
      return;
    }
    this.error = '';
    this.submitting = true;
    const task: TorrentTask = this.task;
    let job: Promise<void>;
    if (this.mode === TaskEditMode.RENAME) {
      if (this.nameInput.trim().length === 0) {
        this.submitting = false;
        this.error = '名称不能为空';
        return;
      }
      job = this.vm.renameTask(task, this.nameInput.trim());
    } else if (this.mode === TaskEditMode.LOCATION) {
      if (this.pathInput.trim().length === 0) {
        this.submitting = false;
        this.error = '保存位置不能为空';
        return;
      }
      job = this.vm.setTaskLocation(task, this.pathInput.trim());
    } else if (this.mode === TaskEditMode.CATEGORY) {
      job = this.doCategory(task);
    } else if (this.mode === TaskEditMode.TAGS) {
      const merged: string[] = [];
      for (const t of task.tags) {
        merged.push(t);
      }
      for (const t of this.selectedTags) {
        if (merged.indexOf(t) < 0) {
          merged.push(t);
        }
      }
      job = this.vm.setTaskTags(task, merged);
    } else if (this.mode === TaskEditMode.LIMITS) {
      job = this.vm.setTaskLimits(task, this.parseKb(this.downloadKb), this.parseKb(this.uploadKb));
    } else {
      const limit: number = this.ratioMode > 0 ? parseFloat(this.ratioLimit) : 0;
      job = this.vm.setTaskRatio(task, this.ratioMode, limit);
    }
    job.then((): void => {
      this.submitting = false;
      this.onSaved();
      this.onClose();
    }).catch((e: Error): void => {
      this.submitting = false;
      this.error = e.message.length > 0 ? e.message : '操作失败';
    });
  }

  private doCategory(task: TorrentTask): Promise<void> {
    const name: string = this.newCategory.trim();
    if (name.length === 0) {
      return this.vm.setTaskCategory(task, this.categoryInput.trim());
    }
    // 新建分类再套用：两步串起来做，用户不用先建再选
    return this.vm.createCategory(task.serverId, name, this.newCategoryPath)
      .then((): Promise<void> => this.vm.setTaskCategory(task, name));
  }

  private toggleTag(tag: string): void {
    const next: string[] = this.selectedTags.slice(0);
    const idx: number = next.indexOf(tag);
    if (idx >= 0) {
      next.splice(idx, 1);
    } else {
      next.push(tag);
    }
    this.selectedTags = next;
  }

  private addNewTag(): void {
    const g: string = this.newTag.trim();
    if (g.length === 0) {
      return;
    }
    if (this.selectedTags.indexOf(g) < 0) {
      const next: string[] = this.selectedTags.slice(0);
      next.push(g);
      this.selectedTags = next;
    }
    this.newTag = '';
  }

  build() {
    DialogHost({
      visible: true,
      title: taskEditTitle(this.mode),
      subtitle: this.task.name,
      confirmText: this.mode === TaskEditMode.RATIO ? '确定' : '提交',
      busy: this.submitting,
      confirmDisabled: !this.canSubmit(),
      contentMaxHeight: 380,
      onCancel: (): void => {
        if (!this.submitting) {
          this.onClose();
        }
      },
      onConfirm: (): void => {
        this.submit();
      }
    }) {
      this.Content()
    }
  }

  @Builder
  Content() {
    Column() {
      if (this.mode === TaskEditMode.RENAME) {
        FieldLabel({ text: '新名称' })
        Blank().height(6)
        BasicField({
          value: this.nameInput,
          placeholder: '输入新的种子名称',
          onValueChanged: (v: string): void => {
            this.nameInput = v;
          }
        })
      } else if (this.mode === TaskEditMode.LOCATION) {
        FieldLabel({ text: '保存位置' })
        Blank().height(6)
        BasicField({
          value: this.pathInput,
          placeholder: '例如 /downloads/电影',
          onValueChanged: (v: string): void => {
            this.pathInput = v;
          }
        })
        Blank().height(6)
        Text('会同时移动已经下载的文件（Transmission 传 move=true）')
          .fontSize(this.theme.fs(10))
          .fontColor(this.theme.colors.textSecondary)
          .lineHeight(this.theme.fs(15))
      } else if (this.mode === TaskEditMode.CATEGORY) {
        FieldLabel({ text: '分类名（留空 = 不分类）' })
        Blank().height(6)
        BasicField({
          value: this.categoryInput,
          placeholder: '例如 电影',
          onValueChanged: (v: string): void => {
            this.categoryInput = v;
          }
        })
        if (this.categories.length > 0) {
          this.Label('已有分类')
          Flex({ wrap: FlexWrap.Wrap }) {
            ForEach(this.categories, (c: string): void => {
              SelectChip({
                label: c,
                active: this.categoryInput === c,
                onTap: (): void => {
                  this.categoryInput = this.categoryInput === c ? '' : c;
                }
              })
            }, (c: string): string => `c-${c}-${this.categoryInput === c ? 1 : 0}`)
          }
          .width('100%')
        }
        this.Label('或新建分类')
        BasicField({
          value: this.newCategory,
          placeholder: '新分类名称',
          onValueChanged: (v: string): void => {
            this.newCategory = v;
          }
        })
        Blank().height(8)
        BasicField({
          value: this.newCategoryPath,
          placeholder: '新分类的保存位置（可空）',
          onValueChanged: (v: string): void => {
            this.newCategoryPath = v;
          }
        })
      } else if (this.mode === TaskEditMode.TAGS) {
        FieldLabel({ text: '已有标签（点一下加入 / 移出）' })
        if (this.tags.length === 0) {
          Blank().height(6)
          Text('这个下载器还没有标签')
            .fontSize(this.theme.fs(11))
            .fontColor(this.theme.colors.textSecondary)
        } else {
          Blank().height(8)
          Flex({ wrap: FlexWrap.Wrap }) {
            ForEach(this.tags, (g: string): void => {
              SelectChip({
                label: g,
                active: this.selectedTags.indexOf(g) >= 0,
                onTap: (): void => {
                  this.toggleTag(g);
                }
              })
            }, (g: string): string => `t-${g}-${this.selectedTags.indexOf(g) >= 0 ? 1 : 0}`)
          }
          .width('100%')
        }
        this.Label('新增标签')
        Row() {
          Row() {
            TextInput({ text: this.newTag, placeholder: '输入标签后点「加入」' })
              .fontSize(this.theme.fs(13))
              .fontColor(this.theme.colors.textPrimary)
              .placeholderColor(this.theme.colors.textSecondary)
              .placeholderFont({ size: this.theme.fs(13) })
              .backgroundColor(Color.Transparent)
              .padding({ left: 4, right: 4, top: 4, bottom: 4 })
              .layoutWeight(1)
              .onChange((v: string): void => {
                this.newTag = v;
              })
              .onSubmit((): void => {
                this.addNewTag();
              })
          }
          .layoutWeight(1)
          .height(38)
          .padding({ left: 8, right: 8 })
          .borderRadius(9)
          .backgroundColor(this.theme.colors.background)
          .alignItems(VerticalAlign.Center)

          Blank().width(8)
          Text('加入')
            .fontSize(this.theme.fs(13))
            .fontColor(Palette.blue)
            .padding({ left: 8, right: 4, top: 6, bottom: 6 })
            .onClick((): void => {
              this.addNewTag();
            })
        }
        .width('100%')
        .alignItems(VerticalAlign.Center)
      } else if (this.mode === TaskEditMode.LIMITS) {
        FieldLabel({ text: '下载限速（KB/s，0 或留空 = 不限）' })
        Blank().height(6)
        BasicField({
          value: this.downloadKb,
          placeholder: '例如 1024',
          onValueChanged: (v: string): void => {
            this.downloadKb = v;
          }
        })
        this.Label('上传限速（KB/s，0 或留空 = 不限）')
        BasicField({
          value: this.uploadKb,
          placeholder: '例如 512',
          onValueChanged: (v: string): void => {
            this.uploadKb = v;
          }
        })
      } else {
        FieldLabel({ text: '分享率策略' })
        Blank().height(8)
        this.RatioRow('跟随全局设置', this.ratioMode === -2, (): void => {
          this.ratioMode = -2;
        })
        this.RatioRow('不限制（无限）', this.ratioMode === -1, (): void => {
          this.ratioMode = -1;
        })
        this.RatioRow('自定义比值', this.ratioMode > 0, (): void => {
          if (this.ratioMode <= 0) {
            this.ratioMode = 2;
            if (this.ratioLimit.length === 0) {
              this.ratioLimit = '2.0';
            }
          }
        })
        if (this.ratioMode > 0) {
          this.Label('比值（例如 2 表示 2.0）')
          BasicField({
            value: this.ratioLimit,
            placeholder: '2.0',
            onValueChanged: (v: string): void => {
              this.ratioLimit = v;
            }
          })
        }
      }

      if (this.error.length > 0) {
        Text(this.error)
          .fontSize(this.theme.fs(11))
          .fontColor(Palette.red)
          .lineHeight(this.theme.fs(16))
          .margin({ top: 12 })
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
      .margin({ top: 12, bottom: 6 })
  }

  @Builder
  RatioRow(label: string, selected: boolean, onTap: () => void) {
    Row() {
      Text(label)
        .fontSize(this.theme.fs(14))
        .fontColor(this.theme.colors.textPrimary)
        .layoutWeight(1)
      Text(selected ? '✓' : '')
        .fontSize(this.theme.fs(14))
        .fontColor(Palette.blue)
    }
    .width('100%')
    .padding({ left: 12, right: 12, top: 11, bottom: 11 })
    .borderRadius(9)
    .backgroundColor(selected ? withAlpha(Palette.blue, 0x1A) : this.theme.colors.background)
    .margin({ top: 6 })
    .alignItems(VerticalAlign.Center)
    .onClick((): void => {
      onTap();
    })
  }
}
