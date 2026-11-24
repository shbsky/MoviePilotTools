import { TOAST_SHORT_MS, TOAST_LONG_MS } from '../common/AppConstants';

/**
 * VM 基座：listener 注册 + 通知。VM 是 App 级单例，与页面生命周期解耦——
 * 切 Tab 不断播/不断轮询的关键（架构 §1.2）。
 * 页面在 aboutToAppear 订阅、aboutToDisappear 注销，
 * 回调里把 VM 的不可变快照赋给 @State。
 */
export class ObservableStore {
  private listeners: Array<() => void> = [];

  subscribe(listener: () => void): void {
    if (!this.listeners.includes(listener)) {
      this.listeners.push(listener);
    }
  }

  unsubscribe(listener: () => void): void {
    const idx: number = this.listeners.indexOf(listener);
    if (idx >= 0) {
      this.listeners.splice(idx, 1);
    }
  }

  protected notify(): void {
    const snapshot: Array<() => void> = this.listeners.slice(0);
    for (const l of snapshot) {
      l();
    }
  }

  listenerCount(): number {
    return this.listeners.length;
  }
}

/**
 * 全局 Toast 体系（PRD #41）：统一 2.2~2.4s 自动消失，各 VM 共用。
 * Index 的 ToastHost 订阅这里。
 */
export class ToastHub {
  private static inst: ToastHub | null = null;

  static getInstance(): ToastHub {
    if (ToastHub.inst === null) {
      ToastHub.inst = new ToastHub();
    }
    return ToastHub.inst;
  }

  private listeners: Array<() => void> = [];
  message: string = '';
  seq: number = 0;

  show(msg: string, long: boolean = false): void {
    this.message = msg;
    this.seq++;
    this.durationMs = long ? TOAST_LONG_MS : TOAST_SHORT_MS;
    this.notify();
  }

  durationMs: number = TOAST_SHORT_MS;

  subscribe(listener: () => void): void {
    if (!this.listeners.includes(listener)) {
      this.listeners.push(listener);
    }
  }

  unsubscribe(listener: () => void): void {
    const idx: number = this.listeners.indexOf(listener);
    if (idx >= 0) {
      this.listeners.splice(idx, 1);
    }
  }

  private notify(): void {
    const snapshot: Array<() => void> = this.listeners.slice(0);
    for (const l of snapshot) {
      l();
    }
  }
}
