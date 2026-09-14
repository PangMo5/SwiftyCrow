// SPDX-FileCopyrightText: 2026 PangMo5 and contributors
// SPDX-License-Identifier: AGPL-3.0-only
(() => {
  const collections = [];
  document.querySelectorAll('.demo-gallery').forEach(gallery => {
    const slides = [...gallery.querySelectorAll('.demo-slide')];
    const tabs = [...gallery.querySelectorAll('.demo-tab')];
    const count = gallery.querySelector('.demo-count');
    const tablist = gallery.querySelector('.demo-tabs');
    const narrow = matchMedia('(max-width: 900px)');
    const orient = () => tablist.setAttribute('aria-orientation', narrow.matches ? 'horizontal' : 'vertical');
    orient();
    narrow.addEventListener('change', orient);
    const previous = gallery.querySelector('.demo-prev');
    const next = gallery.querySelector('.demo-next');
    let selected = 0;
    function select(index, {play = false, focus = false, updateURL = false} = {}) {
      selected = Math.max(0, Math.min(index, slides.length - 1));
      slides.forEach((slide, i) => {
        const active = i === selected;
        slide.hidden = !active;
        slide.setAttribute('role', 'tabpanel');
        tabs[i].setAttribute('aria-selected', String(active));
        tabs[i].tabIndex = active ? 0 : -1;
        if (!active) slide.querySelector('video').pause();
      });
      const panelOffset = slides[selected].getBoundingClientRect().top - gallery.getBoundingClientRect().top;
      slides[selected].style.scrollMarginTop = `${72 + Math.max(0, panelOffset)}px`;
      count.textContent = `${selected + 1} / ${slides.length}`;
      previous.disabled = selected === 0;
      next.disabled = selected === slides.length - 1;
      if (focus) tabs[selected].focus({preventScroll:true});
      if (focus || updateURL) tabs[selected].scrollIntoView({block:'nearest', inline:'nearest'});
      if (updateURL) history.replaceState(null, '', `#${slides[selected].id}`);
      if (play) {
        gallery.scrollIntoView({block:'start'});
        slides[selected].querySelector('video').play().catch(() => {
          count.textContent = `${selected + 1} / ${slides.length} · ${gallery.dataset.playHint}`;
        });
      }
    }
    tabs.forEach((tab, index) => {
      tab.addEventListener('click', () => select(index, {play:true, updateURL:true}));
      tab.addEventListener('keydown', event => {
        const target = {ArrowLeft:selected-1, ArrowUp:selected-1, ArrowRight:selected+1, ArrowDown:selected+1, Home:0, End:slides.length-1}[event.key];
        if (target !== undefined) { event.preventDefault(); select(target, {focus:true, updateURL:true}); }
      });
    });
    previous.addEventListener('click', () => select(selected-1, {play:!slides[selected].querySelector('video').paused, updateURL:true}));
    next.addEventListener('click', () => select(selected+1, {play:!slides[selected].querySelector('video').paused, updateURL:true}));
    gallery.classList.add('demo-gallery-ready');
    collections.push({slides, select});
    select(0);
  });
  function reveal() {
    const id = location.hash.slice(1);
    collections.forEach(({slides, select}) => {
      const index = slides.findIndex(slide => slide.id === id);
      if (index >= 0) {
        select(index);
        requestAnimationFrame(() => {
          document.getElementById(slides[index].getAttribute('aria-labelledby')).scrollIntoView({block:'nearest', inline:'nearest', behavior:'instant'});
          slides[index].closest('.demo-gallery').scrollIntoView({block:'start', behavior:'instant'});
        });
      }
    });
  }
  reveal();
  addEventListener('hashchange', reveal);
  addEventListener('load', reveal, {once:true});
  document.querySelectorAll('video').forEach(video => video.addEventListener('play', () => {
    document.querySelectorAll('video').forEach(other => {if (other !== video) other.pause();});
  }));
})();
