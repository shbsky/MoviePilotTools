/**
 * 页面内部层级的返回拦截注册表。
 *
 * 背景：鸿蒙这版把「订阅列表 / 编辑订阅 / 选择器 / 面板」都做成 Tab 页内部的覆盖层
 * （@State 控制显隐），它们不在 NavPathStack 里。系统返回键只到 Index.onBackPress，
 * 那边看不到这些状态，于是直接 currentTab = 0 跳回仪表盘 —— 编辑订阅按返回直接回仪表盘。
 *
 * 做法：Tab 页在 aboutToAppear 注册一个 handler，Index 收到返回键时先问注册表；
 * handler 内部按自己的渲染优先级逐层关闭，关掉一层就返回 true（消费掉这次返回）。
 * 没人消费才继续走 NavPathStack / 切回首页 Tab / 退出 App。
 *
 * 注册的是「动态判断」的闭包而不是某一层的固定回调，所以不用给每个 @State 挂 @Watch。
 */
export type LayerBack = () => boolean;

export class BackStack {
  private static instance: BackStack | null = null;
  private keys: string[] = [];
  private tabs: number[] = [];
  private handlers: Map<string, LayerBack> = new Map<string, LayerBack>();

  static get(): BackStack {
    if (BackStack.instance === null) {
      BackStack.instance = new BackStack();
    }
    return BackStack.instance;
  }

  /**
   * @param key   唯一标识（每个 Tab 页一个）
   * @param tab   这个页面所属的 Tab 序号，返回键只在当前 Tab 上生效
   * @param handler 动态判断并关闭自己内部层级，关掉一层返回 true
   */
  push(key: string, tab: number, handler: LayerBack): void {
    const i: number = this.keys.indexOf(key);
    if (i < 0) {
      this.keys.push(key);
      this.tabs.push(tab);
    } else {
      this.tabs[i] = tab;
    }
    this.handlers.set(key, handler);
  }

  remove(key: string): void {
    const i: number = this.keys.indexOf(key);
    if (i >= 0) {
      this.keys.splice(i, 1);
      this.tabs.splice(i, 1);
      this.handlers.delete(key);
    }
  }

  /**
   * 只问当前 Tab 的页面（从最近注册的往下问），谁消费了返回 true。
   * 别的 Tab 的覆盖层即使还开着也不该抢当前 Tab 的返回键。
   */
  dispatch(tab: number): boolean {
    for (let i: number = this.keys.length - 1; i >= 0; i--) {
      if (this.tabs[i] !== tab) {
        continue;
      }
      const handler: LayerBack | undefined = this.handlers.get(this.keys[i]);
      if (handler !== undefined && handler()) {
        return true;
      }
    }
    return false;
  }
}
