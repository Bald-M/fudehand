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

describe("preview Escape bridge", () => {
  it("leaves the first Escape to an open native dialog, then exits after it closes", () => {
    const environment = previewEnvironment();
    const dialog = { open: true };
    environment.querySelector.mockReturnValue(dialog);
    installPreviewBridge();

    environment.keydown();
    expect(environment.querySelector).toHaveBeenCalledWith("dialog[open]");
    expect(environment.postMessage).not.toHaveBeenCalled();

    // The browser handles dialog cancellation after keydown dispatch.
    environment.querySelector.mockReturnValue(null);
    environment.keydown();
    expect(environment.postMessage).toHaveBeenCalledExactlyOnceWith(
      { type: "ui-atlas:exit-preview" },
      "http://127.0.0.1:4400",
    );
  });

  it("respects locally consumed Escape and ignores unrelated keys", () => {
    const environment = previewEnvironment();
    installPreviewBridge();
    environment.keydown("Escape", true);
    environment.keydown("Enter");
    expect(environment.postMessage).not.toHaveBeenCalled();
    expect(environment.querySelector).not.toHaveBeenCalled();
  });

  it("targets the configured origin and removes its listener on cleanup", () => {
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

  it("does not intercept keys when the case is opened outside a frame", () => {
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
