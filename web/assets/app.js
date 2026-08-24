// TetherShot site — light interactions.

// Mobile nav toggle
document.querySelectorAll('[data-nav-toggle]').forEach((btn) => {
  btn.addEventListener('click', () => btn.closest('.nav').classList.toggle('open'));
});

// Copy-to-clipboard buttons
document.querySelectorAll('[data-copy]').forEach((btn) => {
  btn.addEventListener('click', async () => {
    try {
      await navigator.clipboard.writeText(btn.getAttribute('data-copy'));
      const prev = btn.textContent;
      btn.textContent = 'copied ✓';
      btn.classList.add('copied');
      setTimeout(() => { btn.textContent = prev; btn.classList.remove('copied'); }, 1600);
    } catch (_) {}
  });
});

// Scroll reveal
const reduceMotion = window.matchMedia('(prefers-reduced-motion: reduce)').matches;
if (reduceMotion || !('IntersectionObserver' in window)) {
  document.querySelectorAll('.reveal').forEach((el) => el.classList.add('in'));
} else {
  const io = new IntersectionObserver((entries) => {
    entries.forEach((e) => { if (e.isIntersecting) { e.target.classList.add('in'); io.unobserve(e.target); } });
  }, { threshold: 0.12 });
  document.querySelectorAll('.reveal').forEach((el) => io.observe(el));
}

// Resolve the signed DMG from the latest GitHub release when it exists.
const dmgLink = document.querySelector('[data-dmg-link]');
if (dmgLink) {
  fetch('https://api.github.com/repos/apoorvdarshan/TetherShot/releases/latest', {
    headers: { Accept: 'application/vnd.github+json' }
  })
    .then((response) => response.ok ? response.json() : Promise.reject(new Error('No release')))
    .then((release) => {
      const asset = release.assets?.find((item) => item.name.toLowerCase().endsWith('.dmg'));
      if (!asset) return;
      dmgLink.href = asset.browser_download_url;
      dmgLink.classList.remove('is-pending');
      const label = dmgLink.querySelector('[data-dmg-label]');
      if (label) label.textContent = `Signed & notarized · ${release.tag_name}`;
    })
    .catch(() => {});
}

// Docs sidebar active-section highlight
const links = [...document.querySelectorAll('.sidebar a[href^="#"]')];
if (links.length) {
  const map = new Map(links.map((a) => [a.getAttribute('href').slice(1), a]));
  const so = new IntersectionObserver((entries) => {
    entries.forEach((e) => {
      if (e.isIntersecting) {
        links.forEach((a) => a.classList.remove('active'));
        map.get(e.target.id)?.classList.add('active');
      }
    });
  }, { rootMargin: '-40% 0px -55% 0px' });
  document.querySelectorAll('.prose h2[id]').forEach((h) => so.observe(h));
}

// Footer year
document.querySelectorAll('[data-year]').forEach((el) => (el.textContent = new Date().getFullYear()));
