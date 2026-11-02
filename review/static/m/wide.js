/* One capability check shared by both pages. Touch-only tablets keep the phone layout. */
(() => {
  'use strict';
  const query = matchMedia('(min-width: 1100px) and (hover: hover) and (pointer: fine)');
  window.cbWide = () => query.matches;
  const update = () => {
    document.documentElement.classList.toggle('wide', query.matches);
    window.dispatchEvent(new Event('cbwidechange'));
  };
  query.addEventListener('change', update);
  update();
})();
