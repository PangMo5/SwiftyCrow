// SPDX-FileCopyrightText: 2026 PangMo5 and contributors
// SPDX-License-Identifier: AGPL-3.0-only
(() => {
  const container = document.querySelector('[data-document-src]');
  if (!container) return;
  const labels = container.dataset;
  const escapeHTML = s => s.replace(/[&<>"]/g, c => ({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;'}[c]));

  function failure() {
    container.replaceChildren();
    const message = document.createElement('p');
    message.className = 'state';
    message.textContent = labels.loadError + ' ';
    const link = document.createElement('a');
    link.href = labels.sourceUrl;
    link.textContent = labels.sourceLabel;
    message.appendChild(link);
    container.appendChild(message);
  }

  function releases(markdown) {
    const entries = [];
    let current = null;
    let pendingAnchor = '';
    let fence = '';
    for (const line of markdown.split('\n')) {
      const marker = line.match(/^\s*(`{3,}|~{3,})/);
      if (marker) fence = fence === marker[1][0] ? '' : marker[1][0];
      const anchor = !fence && line.match(/^<a id="([^"]+)"><\/a>$/);
      if (anchor) { pendingAnchor = anchor[1]; continue; }
      const heading = !fence && line.match(/^##\s+(.+?)\s*$/);
      if (heading) {
        if (current) entries.push(current);
        current = {head: heading[1], anchor: pendingAnchor, body: []};
      } else if (current) {
        if (pendingAnchor && line.trim()) current.body.push('<a id="' + pendingAnchor + '"></a>');
        current.body.push(line);
      }
      if (line.trim()) pendingAnchor = '';
    }
    if (current) entries.push(current);
    if (!entries.length) throw new Error('Empty release history');
    container.replaceChildren();
    for (const entry of entries) {
      const unreleased = entry.anchor === 'unreleased' || /^\d+-unreleased$/.test(entry.anchor) || entry.head.toLowerCase() === 'unreleased';
      const match = entry.head.match(/^(v?\d+\.\d+\.\d+(?:[-.][\w.]+)?)(?:\s+\((\d{4}-\d{2}-\d{2})\))?$/) ||
        (unreleased && entry.head.match(/^(v?\d+\.\d+\.\d+)\s*[（(].*[）)]$/));
      if (!unreleased && !match) throw new Error('Invalid release heading');
      const title = match ? match[1] : entry.head;
      const tag = match ? 'v' + match[1].replace(/^v/, '') : '';
      const date = match?.[2] ? new Intl.DateTimeFormat(document.documentElement.lang, {
        year: 'numeric', month: 'long', day: 'numeric', timeZone: 'UTC'
      }).format(new Date(match[2] + 'T12:00:00Z')) : '';
      const article = document.createElement('article');
      article.className = 'release';
      article.id = entry.anchor;
      article.innerHTML = '<div class="release-top"><h2>' + escapeHTML(title) + '</h2>' +
        (unreleased ? '<span class="release-tag">' + escapeHTML(labels.unreleasedLabel) + '</span>' :
          '<a class="release-tag" href="https://github.com/PangMo5/SwiftyCrow/releases/tag/' + encodeURIComponent(tag) + '">' + escapeHTML(tag) + '</a>') +
        (date ? '<span class="release-date">' + escapeHTML(date) + '</span>' : '') + '</div>' +
        '<div class="md">' + DOMPurify.sanitize(marked.parse(entry.body.join('\n').trim() || labels.noNotes)) + '</div>';
      container.appendChild(article);
    }
  }

  function reference(markdown) {
    container.innerHTML = DOMPurify.sanitize(marked.parse(markdown));
    const side = document.getElementById('side-nav');
    if (!side) return;
    side.replaceChildren();
    const headings = container.querySelectorAll('h2,h3');
    headings.forEach((heading, index) => {
      const previous = heading.previousElementSibling;
      const anchor = previous?.tagName === 'A' ? previous :
        previous?.tagName === 'P' && previous.children.length === 1 && !previous.textContent.trim() ? previous.firstElementChild : null;
      const id = anchor?.tagName === 'A' && anchor.id ? anchor.id : 'section-' + index;
      // Keep the explicit English anchor unique while giving the heading its ID.
      if (anchor?.id === id) anchor.removeAttribute('id');
      heading.id = id;
      const link = document.createElement('a');
      link.href = '#' + id;
      link.textContent = heading.textContent;
      link.className = heading.tagName === 'H3' ? 'lvl-3' : 'lvl-2';
      link.dataset.target = id;
      side.appendChild(link);
    });
    if (headings.length) document.getElementById('side').hidden = false;
    const links = Array.from(side.querySelectorAll('a'));
    const observer = new IntersectionObserver(entries => {
      for (const entry of entries) if (entry.isIntersecting) {
        links.forEach(link => link.classList.toggle('active', link.dataset.target === entry.target.id));
      }
    }, {rootMargin: '-64px 0px -70% 0px', threshold: 0});
    headings.forEach(heading => observer.observe(heading));
  }

  async function load() {
    if (typeof marked === 'undefined' || typeof DOMPurify === 'undefined') return failure();
    try {
      const response = await fetch(labels.documentSrc);
      if (!response.ok) throw new Error(response.status);
      const markdown = await response.text();
      if (labels.mode === 'releases') releases(markdown);
      else reference(markdown);
      if (location.hash) document.getElementById(decodeURIComponent(location.hash.slice(1)))?.scrollIntoView();
    } catch { failure(); }
  }
  load();
})();
