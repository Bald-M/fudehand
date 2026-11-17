/// 注入画框网页的脚本：收集控制台输出，以及供 Agent 读取页面、执行基础交互。
enum FramePageScripts {
    /// 页面世界、document start 注入：包装 console.* 并监听未捕获错误，经 atlasConsole 发回 App。
    static let console = """
    (() => {
      const format = value => {
        if (typeof value === 'string') return value;
        if (value instanceof Error) return value.stack ? `${value}\\n${value.stack}` : String(value);
        try { const text = JSON.stringify(value); if (text !== undefined) return text; } catch {}
        return String(value);
      };
      const post = (level, source, parts) => {
        try { window.webkit.messageHandlers.atlasConsole.postMessage({ level, source, message: parts.map(format).join(' ') }); } catch {}
      };
      for (const level of ['log', 'info', 'warn', 'error', 'debug']) {
        const original = console[level];
        console[level] = function (...args) { post(level, 'console', args); return original.apply(this, args); };
      }
      window.addEventListener('error', event => {
        post('error', 'exception', [event.error ?? `${event.message} (${event.filename}:${event.lineno}:${event.colno})`]);
      });
      window.addEventListener('unhandledrejection', event => post('error', 'exception', ['未处理的 Promise 拒绝：', event.reason]));
    })();
    """

    /// 共用的辅助函数：可见性、可读名称和稳定的 CSS 选择器。
    private static let helpers = """
    const clean = text => (text ?? '').replace(/\\s+/g, ' ').trim();
    const unique = id => id && document.querySelectorAll('#' + CSS.escape(id)).length === 1;
    const selectorOf = element => {
      const parts = [];
      for (let node = element; node && node.nodeType === 1 && node !== document.documentElement; node = node.parentElement) {
        if (unique(node.id)) { parts.unshift('#' + CSS.escape(node.id)); break; }
        let part = node.localName;
        const parent = node.parentElement;
        if (parent) {
          const same = [...parent.children].filter(child => child.localName === node.localName);
          if (same.length > 1) part += `:nth-of-type(${same.indexOf(node) + 1})`;
        }
        parts.unshift(part);
      }
      return parts.join(' > ');
    };
    const nameOf = element => clean(element.getAttribute('aria-label') || element.labels?.[0]?.innerText
      || (['INPUT', 'TEXTAREA', 'SELECT'].includes(element.tagName) ? element.placeholder || element.name : element.innerText)
      || element.title || element.alt || '').slice(0, 120);
    """

    /// 隔离世界中执行，返回 { url, title, outline, truncated }。
    static let read = helpers + """
    const limit = 20000;
    const lines = [];
    let size = 0, truncated = false;
    const skipped = new Set(['SCRIPT', 'STYLE', 'NOSCRIPT', 'TEMPLATE', 'HEAD', 'META', 'LINK', 'svg']);
    const sections = new Set(['header', 'nav', 'main', 'section', 'article', 'aside', 'footer', 'form', 'dialog', 'ul', 'ol', 'table']);
    const interactive = 'a[href],button,input,textarea,select,summary,[role=button],[role=link],[role=checkbox],[role=tab],[role=menuitem],[contenteditable=""],[contenteditable=true]';
    const push = (depth, text) => {
      if (truncated) return;
      const line = '  '.repeat(depth) + text;
      if (size + line.length > limit) { truncated = true; return; }
      lines.push(line);
      size += line.length + 1;
    };
    const describe = element => {
      const tag = element.localName;
      let text = element.getAttribute('role') || tag;
      if (tag === 'input') text += `[type=${element.type}]`;
      text += ` "${nameOf(element)}"`;
      if (['input', 'textarea', 'select'].includes(tag) && !['checkbox', 'radio', 'button', 'submit'].includes(element.type)) {
        text += ` = "${element.type === 'password' && element.value ? '••••' : clean(element.value).slice(0, 200)}"`;
      }
      if (element.checked) text += ' 已选中';
      if (element.disabled) text += ' 已禁用';
      return `${text} → ${selectorOf(element)}`;
    };
    const walk = (node, depth) => {
      for (const child of node.childNodes) {
        if (truncated) return;
        if (child.nodeType === 3) {
          const text = clean(child.textContent);
          if (text) push(depth, text.slice(0, 300));
          continue;
        }
        if (child.nodeType !== 1 || skipped.has(child.tagName) || skipped.has(child.localName)) continue;
        const style = getComputedStyle(child);
        if (style.display === 'none' || style.visibility === 'hidden' || child.hidden) continue;
        const tag = child.localName;
        if (tag === 'label' && child.control) continue;
        if (child.matches(interactive)) { push(depth, describe(child)); continue; }
        if (/^h[1-6]$/.test(tag)) { push(depth, `${tag} ${clean(child.innerText).slice(0, 200)}`); continue; }
        if (tag === 'img') { if (child.alt) push(depth, `img "${clean(child.alt)}"`); continue; }
        let inner = depth;
        if (sections.has(tag)) { push(depth, tag); inner = depth + 1; }
        if (child.shadowRoot) walk(child.shadowRoot, inner);
        walk(child, inner);
      }
    };
    if (document.body) walk(document.body, 0);
    return { url: location.href, title: document.title, outline: lines.join('\\n'), truncated };
    """

    /// 隔离世界中执行，参数 action、selector、value、deltaX、deltaY。失败时返回 { error }。
    static let interact = helpers + """
    const find = () => {
      let element;
      try { element = document.querySelector(selector); } catch { throw `选择器无效：${selector}`; }
      if (!element) throw `找不到元素：${selector}`;
      return element;
    };
    const label = element => `${element.localName}${element.id ? '#' + element.id : ''} "${nameOf(element)}"`;
    const settle = () => new Promise(done => setTimeout(done, 50));
    try {
      let target = null;
      if (action === 'click') {
        target = find();
        const link = target.closest('a[href]');
        if (link) {
          const url = new URL(link.href, location.href);
          if (url.origin !== location.origin) throw `不能点击指向其他站点的链接：${url.href}`;
          if (link.target && link.target !== '_self') throw `不能点击在新窗口打开的链接：${url.href}`;
        }
        target.scrollIntoView({ block: 'center', inline: 'center', behavior: 'instant' });
        const rect = target.getBoundingClientRect();
        const init = { bubbles: true, cancelable: true, composed: true, button: 0,
                       clientX: rect.left + rect.width / 2, clientY: rect.top + rect.height / 2 };
        const pointer = { ...init, pointerId: 1, isPrimary: true, pointerType: 'mouse' };
        target.dispatchEvent(new PointerEvent('pointerdown', pointer));
        target.dispatchEvent(new MouseEvent('mousedown', init));
        target.focus?.();
        target.dispatchEvent(new PointerEvent('pointerup', pointer));
        target.dispatchEvent(new MouseEvent('mouseup', init));
        target.click();
      } else if (action === 'fill') {
        target = find();
        const fillable = ['TEXTAREA', 'SELECT'].includes(target.tagName)
          || (target.tagName === 'INPUT' && !['checkbox', 'radio', 'file', 'button', 'submit', 'reset', 'image', 'hidden'].includes(target.type));
        if (!fillable && !target.isContentEditable) throw `元素不能填写：${selector}`;
        target.focus?.();
        if (target.isContentEditable) target.textContent = value;
        else target.value = value;
        target.dispatchEvent(new InputEvent('input', { bubbles: true, composed: true, inputType: 'insertText', data: value }));
        target.dispatchEvent(new Event('change', { bubbles: true }));
      } else if (selector) {
        target = find();
        if (deltaX || deltaY) target.scrollBy({ left: deltaX, top: deltaY, behavior: 'instant' });
        else target.scrollIntoView({ block: 'center', behavior: 'instant' });
      } else {
        (document.scrollingElement || document.documentElement).scrollBy({ left: deltaX, top: deltaY, behavior: 'instant' });
      }
      await settle();
      return { action, target: target && label(target), url: location.href, scrollX, scrollY };
    } catch (error) {
      return { error: typeof error === 'string' ? error : `页面脚本出错：${error}` };
    }
    """
}
