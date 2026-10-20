// AegisClaw Headless WKWebView DOM & Accessibility Tree Distiller
(function() {
    const interactiveSelectors = 'a[href], button, input, select, textarea, [role="button"], [role="link"], [onclick]';
    const elements = Array.from(document.querySelectorAll(interactiveSelectors));
    let idCounter = 1;
    const interactiveMap = [];

    elements.forEach((el) => {
        const rect = el.getBoundingClientRect();
        if (rect.width === 0 || rect.height === 0) return;
        const aegisId = idCounter++;
        el.setAttribute('data-aegis-id', String(aegisId));
        const label = (el.innerText || el.getAttribute('aria-label') || el.getAttribute('placeholder') || el.value || '').trim().slice(0, 80);
        interactiveMap.push({
            id: aegisId,
            tag: el.tagName.toLowerCase(),
            type: el.getAttribute('type') || '',
            label: label,
            href: el.getAttribute('href') || ''
        });
    });

    const bodyText = (document.body ? document.body.innerText : '').replace(/\n{3,}/g, '\n\n').slice(0, 6000);
    return JSON.stringify({
        title: document.title || '',
        url: window.location.href,
        textPreview: bodyText,
        interactiveElements: interactiveMap.slice(0, 75)
    });
})();
