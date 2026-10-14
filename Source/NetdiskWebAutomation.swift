import Foundation

enum NetdiskWebAutomation {
    // Only visible filename elements and selection/download controls are read.
    // Passwords, login fields and cookies are never inspected by this script.
    static let script = #"""
    (() => {
      if (window.__fontFinderScanner) return;
      window.__fontFinderScanner = true;
      window.__fontFinderTried = new Set();
      const visible = e => e.getClientRects().length > 0;
      const supported = name => /\.(ttf|otf|ttc|zip)$/i.test(name);
      window.fontFinderScan = () => {
        if (location.hostname !== 'pan.baidu.com') return [];
        const found = [];
        for (const element of document.querySelectorAll('[data-filename],.file-name,.filename,.file-name-text,[title]')) {
          if (!visible(element)) continue;
          const name = (element.getAttribute('data-filename') || element.getAttribute('title') || element.textContent || '').trim();
          if (name.length <= 240 && supported(name) && !found.some(v => v.name === name)) found.push({name, element});
          if (found.length >= 1000) break;
        }
        window.webkit?.messageHandlers?.fontFinder?.postMessage({kind:'files', names:found.map(v=>v.name)});
        // This attempts ordinary page controls, never private Baidu endpoints.
        // If the page requires a user gesture, client app or verification, the
        // user can perform that step in the same page or import its download.
        if (window.__fontFinderAuto) {
          const next = found.find(v => !window.__fontFinderTried.has(v.name));
          if (next) {
            const row = next.element.closest('tr,[data-fsid],.list-item,.wp-s-pan-table__body-row');
            const checkbox = row?.querySelector('input[type=checkbox],[role=checkbox],.checkbox,.wp-s-pan-table__check');
            const buttons = [...document.querySelectorAll('button,a,[role=button]')];
            const download = buttons.find(v => visible(v) && /^(下载|下载文件)$/.test((v.textContent||v.getAttribute('title')||'').trim()));
            if (checkbox && download) {
              window.__fontFinderTried.add(next.name);
              if (checkbox.getAttribute('aria-checked') !== 'true' && !checkbox.checked) checkbox.click();
              setTimeout(() => download.click(), 250);
            }
          }
        }
        return found.map(v=>v.name);
      };
      setInterval(() => window.fontFinderScan(), 3000);
      window.fontFinderScan();
    })();
    """#
}
