/**
 * 将可信的本地预览连接到界面图鉴。外壳主机名或端口改变时，需显式传入来源地址。
 * 返回的函数用于移除监听器。
 */
export function installPreviewBridge(
  shellOrigin = "http://127.0.0.1:4400",
): () => void {
  const origin = new URL(shellOrigin).origin;
  if (window.parent === window) return () => {};

  const onKeydown = (event: KeyboardEvent) => {
    if (
      event.key === "Escape" &&
      !event.defaultPrevented &&
      !document.querySelector("dialog[open]")
    ) {
      window.parent.postMessage({ type: "ui-atlas:exit-preview" }, origin);
    }
  };
  window.addEventListener("keydown", onKeydown);
  return () => window.removeEventListener("keydown", onKeydown);
}
