import { afterEach, describe, expect, it, vi } from "vitest";
import { installPreviewBridge } from "../packages/preview-bridge/index";

function previewEnvironment() {
  const postMessage = vi.fn();
  const listeners = new Map<string, (event: KeyboardEvent) => void>();
  const iframeWindow = {
    parent: { postMessage },
    addEventListener: vi.fn(
      (type: string, listener: (event: KeyboardEvent) => void) =>
        listeners.set(type, listener),
    ),
    removeEventListener: vi.fn((type: string) => listeners.delete(type)),
  };
  const querySelector = vi.fn<() => object | null>(() => null);
  vi.stubGlobal("window", iframeWindow);
  vi.stubGlobal("document", { querySelector });
  const keydown = (key = "Escape", defaultPrevented = false) => {
    listeners.get("keydown")?.({ key, defaultPrevented } as KeyboardEvent);
  };
  return { iframeWindow, postMessage, querySelector, keydown };
}

afterEach(() => vi.unstubAllGlobals());

describe("预览 Esc 通信桥", () => {
  it("首次 Esc 交给已打开的原生弹窗处理，关闭后再次按下才退出", () => {
    const environment = previewEnvironment();
    const dialog = { open: true };
    environment.querySelector.mockReturnValue(dialog);
    installPreviewBridge();

    environment.keydown();
    expect(environment.querySelector).toHaveBeenCalledWith("dialog[open]");
    expect(environment.postMessage).not.toHaveBeenCalled();

    // 浏览器在分发 keydown 事件后处理弹窗取消。
    environment.querySelector.mockReturnValue(null);
    environment.keydown();
    expect(environment.postMessage).toHaveBeenCalledExactlyOnceWith(
      { type: "ui-atlas:exit-preview" },
      "http://127.0.0.1:4400",
    );
  });

  it("尊重案例已处理的 Esc，并忽略无关按键", () => {
    const environment = previewEnvironment();
    installPreviewBridge();
    environment.keydown("Escape", true);
    environment.keydown("Enter");
    expect(environment.postMessage).not.toHaveBeenCalled();
    expect(environment.querySelector).not.toHaveBeenCalled();
  });

  it("向配置的来源发送消息，并在清理时移除监听器", () => {
    const environment = previewEnvironment();
    const cleanup = installPreviewBridge("http://127.0.0.1:5500/canvas");
    environment.keydown();
    expect(environment.postMessage).toHaveBeenCalledExactlyOnceWith(
      { type: "ui-atlas:exit-preview" },
      "http://127.0.0.1:5500",
    );
    cleanup();
    environment.keydown();
    expect(environment.postMessage).toHaveBeenCalledTimes(1);
    expect(environment.iframeWindow.removeEventListener).toHaveBeenCalledWith(
      "keydown",
      expect.any(Function),
    );
  });

  it("案例在画框外打开时不拦截按键", () => {
    const environment = previewEnvironment();
    Object.assign(environment.iframeWindow, {
      parent: environment.iframeWindow,
    });
    installPreviewBridge();
    environment.keydown();
    expect(environment.iframeWindow.addEventListener).not.toHaveBeenCalled();
    expect(environment.postMessage).not.toHaveBeenCalled();
  });
});
